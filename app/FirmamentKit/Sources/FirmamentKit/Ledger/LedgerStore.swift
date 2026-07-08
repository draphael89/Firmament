import Foundation
import GRDB

/// The persistent Ledger (SPEC §5.3, A7 types). One SQLite file per device.
/// The event table is INSERT-only — no UPDATE or DELETE statement against it
/// exists anywhere in the codebase (Tenet 1); tombstones are new events that
/// Lenses honor.
public struct LedgerStore: Sendable {
    public let writer: any DatabaseWriter

    /// App configuration: WAL pool, single serialized writer, snapshot readers.
    public static func pool(at path: String) throws -> LedgerStore {
        try LedgerStore(writer: DatabasePool(path: path, configuration: configuration()))
    }

    /// CLI configuration: a queue is enough — but it gets the same explicit
    /// durability pragmas (DatabaseQueue does not default to WAL; plan KTD6).
    public static func queue(at path: String) throws -> LedgerStore {
        try LedgerStore(writer: DatabaseQueue(path: path, configuration: configuration()))
    }

    public static func inMemory() throws -> LedgerStore {
        try LedgerStore(writer: DatabaseQueue())
    }

    static func configuration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            // Explicit for every writable connection so CLI-created ledgers
            // share the app's durability semantics (SPEC §5.3, plan KTD6).
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrate()
    }

    private func migrate() throws {
        try writer.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS event (
                  id BLOB PRIMARY KEY,
                  kind TEXT NOT NULL,
                  occurred_at INTEGER NOT NULL,
                  recorded_at INTEGER NOT NULL,
                  device TEXT NOT NULL,
                  author TEXT NOT NULL,
                  tier INTEGER NOT NULL,
                  parent_id BLOB,
                  payload BLOB NOT NULL,
                  payload_hash BLOB NOT NULL,
                  prev_hash BLOB NOT NULL,
                  hash BLOB NOT NULL
                ) STRICT
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS event_kind_time ON event(kind, occurred_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS event_parent ON event(parent_id)")
            // Contentless FTS keyed by the event rowid, populated inside the
            // append transaction (plan U3/A7). INSERT-only tables never need
            // the contentless-delete dance.
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(text, content='')")
        }
    }

    // MARK: Append / ingest

    public enum StoreError: Error, Equatable {
        case duplicateID(UUID)
    }

    /// Insert a sealed event (and its FTS text) in one transaction.
    /// Idempotent by id: re-inserting an identical event is a no-op; the
    /// sync ingest path depends on this.
    /// - Returns: true when the row was inserted, false when it already existed.
    @discardableResult
    public func insert(_ event: Event) throws -> Bool {
        try writer.write { db in
            try Self.insert(event, in: db)
        }
    }

    static func insert(_ event: Event, in db: Database) throws -> Bool {
        let existing = try Row.fetchOne(
            db, sql: "SELECT 1 FROM event WHERE id = ?", arguments: [event.id.blob])
        if existing != nil { return false }
        try db.execute(
            sql: """
            INSERT INTO event
              (id, kind, occurred_at, recorded_at, device, author, tier,
               parent_id, payload, payload_hash, prev_hash, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                event.id.blob, event.kind.rawValue, event.occurredAt, event.recordedAt,
                event.deviceID.rawValue, event.author.canonicalString, event.tier.rawValue,
                event.parentID?.blob, event.payload, event.payloadHash,
                event.prevHash, event.hash,
            ])
        if let text = Self.ftsText(for: event) {
            let rowid = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO event_fts(rowid, text) VALUES (?, ?)",
                arguments: [rowid, text])
        }
        return true
    }

    /// Human text worth indexing at M0: capture bodies and transcript text.
    static func ftsText(for event: Event) -> String? {
        guard event.kind == .captureText || event.kind == .transcript else { return nil }
        guard let value = try? event.decodedPayload() else { return nil }
        switch event.kind {
        case .captureText: return value["body"]?.stringValue
        case .transcript: return value["text"]?.stringValue
        default: return nil
        }
    }

    // MARK: Reads

    public func fetchAll() throws -> [Event] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM event ORDER BY id").map(Self.event(from:))
        }
    }

    public func fetch(after rowID: Int64) throws -> [(rowID: Int64, event: Event)] {
        try writer.read { db in
            try Row.fetchAll(
                db, sql: "SELECT rowid, * FROM event WHERE rowid > ? ORDER BY rowid",
                arguments: [rowID]
            ).map { row in (row["rowid"] as Int64, try Self.event(from: row)) }
        }
    }

    public func fetchEvent(id: UUID) throws -> Event? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM event WHERE id = ?", arguments: [id.blob])
                .map(Self.event(from:))
        }
    }

    public func eventCount() throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
        }
    }

    /// Full-text (BM25) candidates — event ids ranked by match quality.
    public func searchText(_ query: String, limit: Int = 20) throws -> [UUID] {
        try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT event.id AS id
                FROM event_fts JOIN event ON event.rowid = event_fts.rowid
                WHERE event_fts MATCH ?
                ORDER BY bm25(event_fts) LIMIT ?
                """,
                arguments: [query, limit]
            ).compactMap { row in UUID(blob: row["id"]) }
        }
    }

    /// Chain head (hash of the newest event) per device, or genesis.
    public func chainHead(for deviceID: DeviceID) throws -> Data {
        try writer.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT hash FROM event WHERE device = ? ORDER BY id DESC LIMIT 1",
                arguments: [deviceID.rawValue])
            return row.map { $0["hash"] as Data } ?? HashChain.genesis(for: deviceID)
        }
    }

    public func verifyChains() throws -> [DeviceID: HashChain.Status] {
        let events = try fetchAll()
        var result = [DeviceID: HashChain.Status]()
        for device in DeviceID.allCases {
            result[device] = HashChain.verify(events, deviceID: device)
        }
        return result
    }

    static func event(from row: Row) throws -> Event {
        guard let id = UUID(blob: row["id"]),
              let kind = EventKind(rawValue: row["kind"]),
              let device = DeviceID(rawValue: row["device"]),
              let author = Author(canonicalString: row["author"]),
              let tier = Tier(rawValue: row["tier"]) else {
            throw CanonicalJSONError.malformed("unreadable event row")
        }
        let parentBlob: Data? = row["parent_id"]
        return Event(
            id: id, kind: kind,
            occurredAt: row["occurred_at"], recordedAt: row["recorded_at"],
            deviceID: device, author: author, tier: tier,
            parentID: parentBlob.flatMap(UUID.init(blob:)),
            payload: row["payload"], payloadHash: row["payload_hash"],
            prevHash: row["prev_hash"], hash: row["hash"]
        )
    }
}

extension UUID {
    /// 16 raw bytes, big-endian field order — BLOB memcmp order equals
    /// UUIDv7 timeline order, so `ORDER BY id` is the chain order.
    public var blob: Data {
        let u = uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                     u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    public init?(blob: Data) {
        guard blob.count == 16 else { return nil }
        let b = [UInt8](blob)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                         b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
