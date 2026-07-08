import CryptoKit
import Foundation
import Testing
@testable import FirmamentKit

@Suite("Capture pipeline")
struct CapturePipelineTests {
    private func makePipeline() throws -> (CapturePipeline, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-capture-\(UUID().uuidString)")
        let store = try AudioFileStore(root: root)
        let ledger = try Ledger(store: LedgerStore.inMemory(), deviceID: .mac)
        return (CapturePipeline(ledger: ledger, audioStore: store), root)
    }

    @Test("audio capture writes file + event; payload hash matches file content")
    func happyPath() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let handle = try pipeline.audioStore.beginRecording(startedAtMS: 1_780_000_000_000)
        let frames = Data((0..<4096).map { UInt8($0 % 251) })
        try pipeline.audioStore.append(frames, to: handle)
        try pipeline.audioStore.flush(handle)
        let event = try await pipeline.completeAudioCapture(handle, durationMS: 2_000)

        let payload = try CaptureAudioPayload(canonical: event.decodedPayload())
        let fileURL = pipeline.audioStore.fileURL(forHash: payload.fileHash)
        let onDisk = try Data(contentsOf: fileURL)
        #expect(Data(SHA256.hash(data: onDisk)).hexEncoded == payload.fileHash)
        #expect(onDisk == frames)
        #expect(payload.interrupted == false)
        #expect(event.occurredAt == 1_780_000_000_000)
    }

    @Test("text capture round-trips every source plane; tiers store identically")
    func textPlanesAndTiers() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, plane) in SourcePlane.allCases.enumerated() {
            let tier: Tier = [.open, .personal, .sanctum][index % 3]
            let event = try await pipeline.captureText(
                body: "body via \(plane.rawValue)", sourcePlane: plane, tier: tier)
            let payload = try CaptureTextPayload(canonical: event.decodedPayload())
            #expect(payload.sourcePlane == plane)
            #expect(event.tier == tier)
        }
        guard case .intact(_, let count) = try pipeline.ledger.store.verifyChains()[.mac] else {
            Issue.record("chain not intact")
            return
        }
        #expect(count == SourcePlane.allCases.count)
    }

    @Test("duplicate content: two events reference one file; reconciler leaves it")
    func duplicateContent() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = Data("identical audio".utf8)
        for _ in 0..<2 {
            let handle = try pipeline.audioStore.beginRecording()
            try pipeline.audioStore.append(frames, to: handle)
            try await pipeline.completeAudioCapture(handle, durationMS: 500)
        }
        #expect(try pipeline.audioStore.completeFileHashes().count == 1)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report == Reconciler.Report())
        #expect(try pipeline.audioStore.completeFileHashes().count == 1)
    }

    @Test("foreign event pending its asset is expected, not a breach")
    func foreignPendingAsset() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        // A phone event synced in whose CKAsset hasn't downloaded yet.
        let draft = Event.Draft(
            kind: .captureAudio, occurredAt: 1, recordedAt: 1,
            deviceID: .phone, author: .human, tier: .personal,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "a", count: 64), durationMS: 100
            ).canonical
        )
        let foreign = try Event.seal(draft, prevHash: HashChain.genesis(for: .phone))
        try await pipeline.ledger.ingest(foreign)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report.pendingForeignAssets == [foreign.id])
        #expect(report.fatalDanglingLocal.isEmpty)
    }

    @Test("local event with a missing file is a loud fatal breach")
    func fatalDanglingLocal() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = try await pipeline.ledger.append(
            kind: .captureAudio, occurredAt: 1, author: .human,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "b", count: 64), durationMS: 100
            ).canonical
        )
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report.fatalDanglingLocal == [event.id])
    }

    /// Static analysis keeps flagging `open(…, O_RDONLY)` before `F_FULLFSYNC`
    /// as a write-permission bug. It is not: both flush the vnode, not the
    /// descriptor. Switching to `O_RDWR` as "fixed" would break the directory
    /// sync outright — `open(dir, O_RDWR)` returns `EISDIR` — and that sync is
    /// what makes the rename durable (KTD2).
    @Test("full-fsync succeeds through a read-only descriptor, for files and directories")
    func fullSyncThroughReadOnlyDescriptor() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        let url = store.reserveTemporaryPath()
        try Data("durable bytes".utf8).write(to: url)
        try store.flush(path: url)  // opens O_RDONLY, then F_FULLFSYNC

        // The rename's durability barrier: a directory has no writable fd.
        try AudioFileStore.fullSync(directory: store.audioDirectory)
        #expect(open(store.audioDirectory.path, O_RDWR) == -1, "directories are not O_RDWR openable")

        // And the whole finalize path still lands the event.
        let event = try await pipeline.completeAudioCapture(
            temporaryFile: url, startedAtMS: 1, durationMS: 1)
        let payload = try CaptureAudioPayload(canonical: event.decodedPayload())
        #expect(store.fileExists(hash: payload.fileHash))
    }

    @Test("empty temp files are garbage-collected; non-empty are adopted")
    func partialAdoption() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        // What a killed process leaves behind: partials on disk with no live
        // writer. (Abandoning a handle *in this process* is not a crash — the
        // store still knows it is being written. See LiveRecordingAdoptionTests.)
        let temp = pipeline.audioStore.tempDirectory
        // Empty partial — provably no audio lost, GC.
        FileManager.default.createFile(
            atPath: temp.appendingPathComponent("\(UUID().uuidString).partial").path, contents: nil)
        // Non-empty partial — interrupted capture, adopt.
        let flushed = Data("frames up to the flush point".utf8)
        try flushed.write(to: temp.appendingPathComponent("\(UUID().uuidString).partial"))

        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report.collectedEmptyTemps == 1)
        #expect(report.adoptedPartials.count == 1)

        let adopted = try pipeline.ledger.store.fetchEvent(id: report.adoptedPartials[0])
        let payload = try CaptureAudioPayload(canonical: adopted!.decodedPayload())
        #expect(payload.interrupted == true)
        let survived = try Data(contentsOf: pipeline.audioStore.fileURL(forHash: payload.fileHash))
        #expect(survived == flushed)
        // Second run converges: nothing left to adopt.
        let second = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(second == Reconciler.Report())
    }
}
