import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Content-addressed audio storage with the KTD2 crash ordering:
/// frames stream to a durable temp path with periodic flush during capture;
/// finalize runs full-fsync(file) → rename to `audio/<sha256>.caf` →
/// full-fsync(directory) — only after all of which may the event row land.
/// A crash at any point leaves a recoverable partial or an orphan file,
/// never an event without its file.
public struct AudioFileStore: Sendable {
    public let root: URL

    public var audioDirectory: URL { root.appendingPathComponent("audio", isDirectory: true) }
    public var tempDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    // MARK: Live reservations

    /// Temp paths this process is actively writing. On disk a live recording
    /// and a crashed process's orphan are the same thing — a non-empty
    /// `.partial` — and only the owning process can tell them apart. The
    /// Action Button path makes that distinction load-bearing: `PhoneModel`
    /// reconciles on launch *while* the intent's recording is already running.
    ///
    /// Held in memory on purpose. A crash clears it, which is exactly right:
    /// the partial genuinely is an orphan then, and adoption must resume.
    ///
    /// Keyed by filename, not path. Temp names are UUIDs, so they collide
    /// with nothing; paths would, because `contentsOfDirectory` hands back
    /// `/private/var/…` while a reserved-but-not-yet-created file still reads
    /// `/var/…` — `resolvingSymlinksInPath()` only resolves what exists.
    private static let liveReservations = Mutex<Set<String>>([])

    private static func reserve(_ url: URL) {
        liveReservations.withLock { _ = $0.insert(url.lastPathComponent) }
    }

    private static func release(_ url: URL) {
        liveReservations.withLock { _ = $0.remove(url.lastPathComponent) }
    }

    static func isLive(_ url: URL) -> Bool {
        liveReservations.withLock { $0.contains(url.lastPathComponent) }
    }

    // MARK: Recording lifecycle

    public final class RecordingHandle {
        public let tempURL: URL
        public let startedAtMS: Int64
        let descriptor: Int32
        var closed = false

        init(tempURL: URL, startedAtMS: Int64, descriptor: Int32) {
            self.tempURL = tempURL
            self.startedAtMS = startedAtMS
            self.descriptor = descriptor
        }

        deinit {
            if !closed { close(descriptor) }
            // A handle nobody holds cannot still be recording; its partial is
            // an orphan the next reconciliation should adopt. (No-op after
            // finalize/discard, which already released.)
            AudioFileStore.release(tempURL)
        }
    }

    public enum StoreError: Error, Equatable {
        case cannotOpen(String)
        case syncFailed(String)
        case handleClosed
        case emptyRecording
    }

    /// Open a durable temp file for streaming frames.
    public func beginRecording(startedAtMS: Int64 = UUIDv7Generator.currentMS()) throws -> RecordingHandle {
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).partial")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw StoreError.cannotOpen(url.lastPathComponent) }
        Self.reserve(url)
        return RecordingHandle(tempURL: url, startedAtMS: startedAtMS, descriptor: fd)
    }

    /// Append raw frames. The adapter layer owns the audio container format;
    /// the core treats bytes.
    public func append(_ data: Data, to handle: RecordingHandle) throws {
        guard !handle.closed else { throw StoreError.handleClosed }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(handle.descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw StoreError.syncFailed("write") }
                offset += written
            }
        }
    }

    /// Periodic in-capture flush (KTD2): a crash mid-recording preserves
    /// everything up to the last flush.
    public func flush(_ handle: RecordingHandle) throws {
        guard !handle.closed else { throw StoreError.handleClosed }
        try Self.fullSync(descriptor: handle.descriptor)
    }

    /// The finalize half of the sacred ordering. Returns the content hash
    /// and final URL; the caller then appends the event row.
    public func finalize(_ handle: RecordingHandle) throws -> (fileHash: String, url: URL, byteCount: Int64) {
        guard !handle.closed else { throw StoreError.handleClosed }
        // Released even if adoption throws: the bytes are on disk and durable,
        // so the partial should be adoptable by the next reconciliation pass.
        defer { Self.release(handle.tempURL) }
        try Self.fullSync(descriptor: handle.descriptor)
        handle.closed = true
        close(handle.descriptor)
        return try adopt(temporaryFile: handle.tempURL)
    }

    /// Hash → rename → dir-fsync for an already-durable file. Shared by
    /// finalize and by the Reconciler's partial-adoption path.
    public func adopt(temporaryFile url: URL) throws -> (fileHash: String, url: URL, byteCount: Int64) {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw StoreError.emptyRecording }
        let hash = Data(SHA256.hash(data: data)).hexEncoded
        let final = fileURL(forHash: hash)
        if FileManager.default.fileExists(atPath: final.path) {
            // Duplicate content: the canonical file already exists.
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.moveItem(at: url, to: final)
        }
        try Self.fullSync(directory: audioDirectory)
        return (hash, final, Int64(data.count))
    }

    // MARK: Adapter path (AVAudioFile owns the container writing)

    /// Reserve a temp path for an adapter-managed writer (AVAudioFile on the
    /// app targets). The Reconciler adopts leftovers here exactly like
    /// fd-streamed partials; AVAudioFile's CAF keeps its audio-data chunk
    /// size open until close, so partials stay prefix-recoverable.
    public func reserveTemporaryPath() -> URL {
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).partial")
        Self.reserve(url)
        return url
    }

    /// Periodic in-capture durability for adapter-written files: full-fsync
    /// through a fresh descriptor (fsync flushes the file, not the fd).
    ///
    /// `O_RDONLY` is deliberate. Neither `fsync(2)` nor `F_FULLFSYNC` requires
    /// write access — they flush the vnode, not the descriptor — and a
    /// directory (which `fullSync(directory:)` must sync to make the rename
    /// durable) cannot be opened `O_RDWR` at all: it returns `EISDIR`.
    /// Pinned by `fullSyncThroughReadOnlyDescriptor`.
    public func flush(path: URL) throws {
        let fd = open(path.path, O_RDONLY)
        guard fd >= 0 else { throw StoreError.cannotOpen(path.lastPathComponent) }
        defer { close(fd) }
        try Self.fullSync(descriptor: fd)
    }

    /// Finalize an adapter-written temp file: full-fsync → hash → rename →
    /// dir-fsync (the same sacred ordering as `finalize(_:)`).
    public func finalize(temporaryFile url: URL) throws -> (fileHash: String, url: URL, byteCount: Int64) {
        defer { Self.release(url) }
        try flush(path: url)
        return try adopt(temporaryFile: url)
    }

    public func discard(_ handle: RecordingHandle) {
        if !handle.closed {
            handle.closed = true
            close(handle.descriptor)
        }
        Self.release(handle.tempURL)
        try? FileManager.default.removeItem(at: handle.tempURL)
    }

    // MARK: Lookup

    public func fileURL(forHash hash: String) -> URL {
        audioDirectory.appendingPathComponent("\(hash).caf")
    }

    public func fileExists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forHash: hash).path)
    }

    public func completeFileHashes() throws -> Set<String> {
        let contents = try FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: nil)
        return Set(contents.filter { $0.pathExtension == "caf" }
            .map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Orphaned partials only — temp files no live recording in this process
    /// owns. Adopting a partial moves it out from under its writer, so the
    /// Reconciler must never see one that is still being written.
    public func partialFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: tempDirectory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { !Self.isLive($0) }
    }

    // MARK: fsync discipline

    /// F_FULLFSYNC — plain fsync on Apple platforms does not force the drive
    /// to flush (fsync(2) man page); the capture path pays for the real thing.
    public static func fullSync(descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            guard fsync(descriptor) == 0 else { throw StoreError.syncFailed("fsync") }
        }
    }

    public static func fullSync(directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw StoreError.cannotOpen(directory.lastPathComponent) }
        defer { close(fd) }
        try fullSync(descriptor: fd)
    }
}
