import Foundation

/// Launch-time reconciliation (plan KTD2/U4). Distinguishes three states:
/// an orphan *partial* temp file (interrupted capture → adopt, never delete),
/// an orphan *complete* file (crash between rename and append → adopt), and
/// a local event without its file (fatal invariant breach — should be
/// impossible by construction). A foreign event whose CKAsset hasn't
/// downloaded yet is expected pending state, not a breach (KTD7).
public struct Reconciler: Sendable {
    public struct Report: Sendable, Equatable {
        /// capture.audio events appended for adopted partial recordings.
        public var adoptedPartials: [UUID] = []
        /// capture.audio events appended for orphaned complete files.
        public var adoptedCompletes: [UUID] = []
        /// Local capture.audio events whose file is missing — loud failure.
        public var fatalDanglingLocal: [UUID] = []
        /// Foreign capture.audio events awaiting asset download — expected.
        public var pendingForeignAssets: [UUID] = []
        /// Empty temp files garbage-collected (provably no audio lost).
        public var collectedEmptyTemps: Int = 0

        public init() {}
    }

    public init() {}

    public func run(pipeline: CapturePipeline, deviceID: DeviceID) async throws -> Report {
        var report = Report()
        let store = pipeline.audioStore
        let events = try pipeline.ledger.store.fetchAll()

        // Hashes referenced by any capture.audio event, split by locality.
        var referenced = Set<String>()
        for event in events where event.kind == .captureAudio {
            guard let payload = try? CaptureAudioPayload(canonical: event.decodedPayload()) else { continue }
            referenced.insert(payload.fileHash)
            if !store.fileExists(hash: payload.fileHash) {
                if event.deviceID == deviceID {
                    report.fatalDanglingLocal.append(event.id)
                } else {
                    report.pendingForeignAssets.append(event.id)
                }
            }
        }

        // Partial temp files: adopt non-empty ones as interrupted captures;
        // GC only provably-empty ones.
        for temp in try store.partialFiles() {
            let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size == 0 {
                try? FileManager.default.removeItem(at: temp)
                report.collectedEmptyTemps += 1
                continue
            }
            let modified = (try? temp.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Int64($0.timeIntervalSince1970 * 1000) } ?? UUIDv7Generator.currentMS()
            let (fileHash, _, _) = try store.adopt(temporaryFile: temp)
            if referenced.contains(fileHash) {
                // The event already landed (crash after append, before temp
                // cleanup) — adoption deduplicated the bytes; nothing to add.
                continue
            }
            let event = try await pipeline.ledger.append(
                kind: .captureAudio,
                occurredAt: modified,
                author: .human,
                tier: .personal,
                payload: CaptureAudioPayload(
                    fileHash: fileHash, durationMS: 0,
                    context: ["recovery": "partial"], interrupted: true
                ).canonical
            )
            referenced.insert(fileHash)
            report.adoptedPartials.append(event.id)
        }

        // Complete files no event references: crash landed between rename
        // and append — adopt (survival over tidiness, R10).
        for orphanHash in try store.completeFileHashes().subtracting(referenced) {
            let url = store.fileURL(forHash: orphanHash)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Int64($0.timeIntervalSince1970 * 1000) } ?? UUIDv7Generator.currentMS()
            let event = try await pipeline.ledger.append(
                kind: .captureAudio,
                occurredAt: modified,
                author: .human,
                tier: .personal,
                payload: CaptureAudioPayload(
                    fileHash: orphanHash, durationMS: 0,
                    context: ["recovery": "orphan"], interrupted: true
                ).canonical
            )
            report.adoptedCompletes.append(event.id)
        }

        return report
    }
}
