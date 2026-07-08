import Foundation
import GRDB

/// Durable sync bookkeeping. Two kinds of state, both derived (the Ledger
/// stays the durability boundary — plan KTD7):
/// - the CKSyncEngine state serialization, persisted on every `stateUpdate`
///   and handed back at engine init so the engine resumes without a full
///   re-sync;
/// - the sent-marker table, so pending uploads re-enqueue from the Ledger
///   after a crash (CKSyncEngine's in-memory queue is not trusted —
///   apple/sample-cloudkit-sync-engine issue #5).
public struct SyncStateStore: Sendable {
    private let directory: URL
    private let ledgerStore: LedgerStore

    public init(directory: URL, ledgerStore: LedgerStore) throws {
        self.directory = directory
        self.ledgerStore = ledgerStore
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ledgerStore.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sync_sent (
                  id BLOB PRIMARY KEY
                ) STRICT
                """)
        }
    }

    // MARK: Engine state serialization

    private var stateURL: URL { directory.appendingPathComponent("cksyncengine-state.data") }

    public func saveEngineState(_ data: Data) throws {
        try data.write(to: stateURL, options: .atomic)
    }

    public func loadEngineState() -> Data? {
        try? Data(contentsOf: stateURL)
    }

    /// Account switch / encrypted-data reset: forget the engine state (and
    /// the sent markers — everything re-uploads from the Ledger).
    public func reset() throws {
        try? FileManager.default.removeItem(at: stateURL)
        try ledgerStore.writer.write { db in
            try db.execute(sql: "DELETE FROM sync_sent")
        }
    }

    // MARK: Sent markers

    public func markSent(_ ids: [UUID]) throws {
        try ledgerStore.writer.write { db in
            for id in ids {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO sync_sent (id) VALUES (?)",
                    arguments: [id.blob])
            }
        }
    }

    public func isSent(_ id: UUID) throws -> Bool {
        try ledgerStore.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT 1 FROM sync_sent WHERE id = ?", arguments: [id.blob]) != nil
        }
    }

    /// Local events not yet marked sent AND ready per the upload gate,
    /// timeline order — what re-enqueues at engine start and after appends.
    public func pendingUploads(deviceID: DeviceID, audioStore: AudioFileStore) throws -> [Event] {
        let sent = try ledgerStore.writer.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT id FROM sync_sent")
                .compactMap { UUID(blob: $0["id"]) })
        }
        return try ledgerStore.fetchAll().filter { event in
            event.deviceID == deviceID
                && !sent.contains(event.id)
                && UploadGate.isReadyToUpload(event, audioStore: audioStore)
        }
    }
}

/// The daily `sync.checkpoint` clerk (SPEC §5.5, plan U12): one per device
/// per day, day boundary under the pinned Firmament timezone (same constant
/// as the Vault fold — plan U7).
public enum CheckpointClerk {
    /// Appends a checkpoint when today (pinned tz) doesn't have one yet.
    @discardableResult
    public static func emitIfDue(
        ledger: Ledger,
        nowMS: Int64 = UUIDv7Generator.currentMS()
    ) async throws -> Event? {
        let today = FirmamentTime.dayString(epochMS: nowMS)
        let events = try ledger.store.fetchAll()
        let existing = events.filter { $0.kind == .syncCheckpoint && $0.deviceID == ledger.deviceID }
        for checkpoint in existing {
            if let payload = try? SyncCheckpointPayload(canonical: checkpoint.decodedPayload()),
               payload.day == today {
                return nil
            }
        }
        let head = await ledger.currentChainHead()
        let count = events.filter { $0.deviceID == ledger.deviceID }.count
        return try await ledger.append(
            kind: .syncCheckpoint,
            occurredAt: nowMS,
            recordedAt: nowMS,
            author: .system,
            tier: .open,
            payload: SyncCheckpointPayload(
                chainHead: head.hexEncoded,
                eventCount: Int64(count),
                day: today
            ).canonical
        )
    }
}
