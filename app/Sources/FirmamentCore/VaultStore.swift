import Foundation
import GRDB

public enum ImportResult: Equatable, Sendable {
    case created(entryID: String, revisionID: String)
    /// Same raw bytes already in the vault (global content-hash dedup, plan §3).
    /// The existing entry keeps its first-import provenance (facet, source);
    /// a `localOnly: true` re-import escalates the existing entry's privacy.
    case duplicate(entryID: String)
}

public struct PurgeReport: Equatable, Sendable {
    public var revisionsPurged: Int
    public var objectsDeleted: Int
    public var jobsDeleted: Int
    public var assertionsDowngraded: Int
    public var assertionsRetracted: Int
}

/// The vault: sole owner of the SQLite database and content store. The pool
/// and content store are internal — outside this module, VaultStore's methods
/// are the only read/write path, which is what makes the egress and deletion
/// invariants structural rather than conventional (plan §4).
public final class VaultStore: Sendable {
    let pool: DatabasePool
    let contentStore: ContentStore

    /// Opens (creating if needed) a vault rooted at `directoryURL`:
    /// `vault.sqlite` + `objects/` live inside it. Assumes one process owns
    /// the vault (the core service); open-time sweep reclaims objects
    /// orphaned by crashes between a commit and its filesystem work.
    public init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(
            path: directoryURL.appendingPathComponent("vault.sqlite").path,
            configuration: config)
        contentStore = try ContentStore(
            rootURL: directoryURL.appendingPathComponent("objects", isDirectory: true))
        try Migrations.migrator().migrate(pool)
        try sweepOrphanedObjects()
    }

    // MARK: - Import

    /// Imports raw bytes as a new entry (or dedupes on content hash).
    /// The object is written before the row transaction and re-verified after
    /// it, so a concurrent purge's unlink can never leave a committed
    /// revision without its bytes.
    public func importEntry(
        sourceID: String,
        facet: Facet,
        data: Data,
        mime: String,
        metadata: Data? = nil,
        localOnly: Bool = false,
        searchableText: String? = nil,
        externalID: String? = nil
    ) throws -> ImportResult {
        let hash = try contentStore.put(data)
        let result = try pool.write { db -> ImportResult in
            if let existing = try EntryRevision
                .filter(Column("contentHash") == hash)
                .fetchOne(db) {
                // Privacy escalation is one-way: a local-only re-import makes
                // the existing entry local-only; the reverse never happens.
                if localOnly {
                    try db.execute(
                        sql: "UPDATE entry SET localOnly = 1 WHERE id = ?",
                        arguments: [existing.entryID])
                }
                return .duplicate(entryID: existing.entryID)
            }
            let entry = Entry(sourceID: sourceID, facet: facet,
                              localOnly: localOnly, externalID: externalID)
            let revision = EntryRevision(
                entryID: entry.id, seq: 1, contentHash: hash,
                mime: mime, metadata: metadata)
            try entry.insert(db)
            try revision.insert(db)
            if let text = searchableText {
                try Self.replaceSearchRow(
                    db, entryID: entry.id, title: "", summary: "", body: text)
            }
            return .created(entryID: entry.id, revisionID: revision.id)
        }
        try healObjectIfMissing(hash: hash, data: data)
        return result
    }

    /// Adds a new revision to an existing entry (e.g. a Granola remote edit).
    /// Returns nil if the content is unchanged from the current revision.
    public func addRevision(
        entryID: String, data: Data, mime: String, metadata: Data? = nil,
        searchableText: String? = nil
    ) throws -> String? {
        let hash = try contentStore.put(data)
        let revisionID = try pool.write { db -> String? in
            guard try Entry.exists(db, key: entryID) else {
                throw VaultError.entryNotFound(entryID)
            }
            let current = try Self.currentRevision(db, entryID: entryID)
            if current?.contentHash == hash { return nil }
            let revision = EntryRevision(
                entryID: entryID, seq: (current?.seq ?? 0) + 1,
                parentRevisionID: current?.id, contentHash: hash,
                mime: mime, metadata: metadata)
            try revision.insert(db)
            if let text = searchableText {
                let projection = try EntryProjection.fetchOne(db, key: entryID)
                try Self.replaceSearchRow(
                    db, entryID: entryID,
                    title: projection?.title ?? "",
                    summary: projection?.summary ?? "",
                    body: text)
            }
            return revision.id
        }
        try healObjectIfMissing(hash: hash, data: data)
        return revisionID
    }

    /// The latest revision (max seq) — the entry's current content.
    public func currentRevision(entryID: String) throws -> EntryRevision? {
        try pool.read { try Self.currentRevision($0, entryID: entryID) }
    }

    static func currentRevision(_ db: Database, entryID: String) throws -> EntryRevision? {
        try EntryRevision
            .filter(Column("entryID") == entryID)
            .order(Column("seq").desc)
            .fetchOne(db)
    }

    /// Import/addRevision write the object before their row transaction; a
    /// purge running in between can see it unreferenced and unlink it. The
    /// bytes are still in hand here, so re-materialize.
    private func healObjectIfMissing(hash: String, data: Data) throws {
        if !contentStore.contains(hash) {
            try contentStore.put(data)
        }
    }

    // MARK: - Sources

    /// Finds or creates the source row for a connector, keyed by kind+name.
    public func ensureSource(kind: SourceKind, name: String) throws -> String {
        try pool.write { db in
            if let existing = try Source
                .filter(Column("kind") == kind)
                .filter(Column("name") == name)
                .fetchOne(db) {
                return existing.id
            }
            let source = Source(kind: kind, name: name)
            try source.insert(db)
            return source.id
        }
    }

    // MARK: - Reading

    public func entry(id: String) throws -> Entry? {
        try pool.read { try Entry.fetchOne($0, key: id) }
    }

    /// Connector identity lookup: the entry previously imported for an
    /// external id (e.g. a Granola note), if any.
    public func entryID(sourceID: String, externalID: String) throws -> String? {
        try pool.read { db in
            try Entry
                .filter(Column("sourceID") == sourceID)
                .filter(Column("externalID") == externalID)
                .fetchOne(db)?.id
        }
    }

    public func rawContent(revision: EntryRevision) throws -> Data {
        try contentStore.data(for: revision.contentHash)
    }

    // MARK: - Search

    /// Replaces the FTS row for an entry, in the same transaction as its
    /// source rows. Deletion is covered by the entrySearch cleanup trigger.
    static func replaceSearchRow(
        _ db: Database, entryID: String, title: String, summary: String, body: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM entrySearch WHERE entryID = ?", arguments: [entryID])
        try db.execute(
            sql: "INSERT INTO entrySearch (entryID, title, summary, body) VALUES (?, ?, ?, ?)",
            arguments: [entryID, title, summary, body])
    }

    public func updateProjection(
        _ projection: EntryProjection, searchBody: String
    ) throws {
        try pool.write { db in
            try projection.save(db)
            try Self.replaceSearchRow(
                db, entryID: projection.entryID, title: projection.title,
                summary: projection.summary, body: searchBody)
        }
    }

    /// Full-text search. Trashed entries never match; local-only entries only
    /// match when `includeLocalOnly` is set (UI yes, egress paths never).
    public func search(
        _ query: String, includeLocalOnly: Bool = false, limit: Int = 50
    ) throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        return try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT s.entryID FROM entrySearch s
                    JOIN entry e ON e.id = s.entryID
                    WHERE entrySearch MATCH ?
                      AND e.trashedAt IS NULL
                      AND (e.localOnly = 0 OR ?)
                    ORDER BY rank LIMIT ?
                    """,
                arguments: [pattern, includeLocalOnly, limit])
        }
    }

    // MARK: - Jobs

    /// Enqueues a job, deduping on idempotencyKey (at-least-once discipline:
    /// re-enqueueing the same work is a no-op). Returns true if enqueued.
    @discardableResult
    public func enqueueJob(
        kind: String, idempotencyKey: String, entryID: String? = nil,
        payload: Data? = nil, runAfter: Date = Date()
    ) throws -> Bool {
        try pool.write { db in
            let job = Job(kind: kind, idempotencyKey: idempotencyKey,
                          entryID: entryID, payload: payload, runAfter: runAfter)
            try job.insert(db, onConflict: .ignore)
            return db.changesCount > 0
        }
    }

    // MARK: - Trash & Delete Now

    public func trash(entryID: String) throws {
        try setTrashed(entryID: entryID, date: Date())
    }

    public func untrash(entryID: String) throws {
        try setTrashed(entryID: entryID, date: nil)
    }

    private func setTrashed(entryID: String, date: Date?) throws {
        try pool.write { db in
            guard var entry = try Entry.fetchOne(db, key: entryID) else {
                throw VaultError.entryNotFound(entryID)
            }
            entry.trashedAt = date
            try entry.update(db)
        }
    }

    /// Delete Now (plan §4): one transaction purges the entry's rows, every
    /// job that references it (payloads can carry entry content), and
    /// reconciles assertions that lost evidence. The FTS row falls to the
    /// cleanup trigger with the entry row. Content-store objects are
    /// unlinked after commit iff the transaction proved them unreferenced.
    @discardableResult
    public func purgeEntry(entryID: String) throws -> PurgeReport {
        let (orphanHashes, report) = try pool.write { db -> ([String], PurgeReport) in
            guard let entry = try Entry.fetchOne(db, key: entryID) else {
                throw VaultError.entryNotFound(entryID)
            }
            let revisions = try EntryRevision
                .filter(Column("entryID") == entryID).fetchAll(db)
            let revisionIDs = revisions.map(\.id)
            let hashes = Set(revisions.map(\.contentHash))

            let affectedAssertionIDs = try String.fetchAll(
                db,
                AssertionEvidence
                    .filter(revisionIDs.contains(Column("revisionID")))
                    .select(Column("assertionID"), as: String.self)
                    .distinct())
            try AssertionEvidence
                .filter(revisionIDs.contains(Column("revisionID")))
                .deleteAll(db)

            let jobsDeleted = try Job
                .filter(Column("entryID") == entryID)
                .deleteAll(db)

            // Cascades take revisions, segments, analysis runs, questions,
            // and the projection; the trigger takes the entrySearch row.
            try entry.delete(db)

            let (downgraded, retracted) = try Self.reconcileAssertions(
                db, assertionIDs: affectedAssertionIDs)

            let stillReferenced = try Set(String.fetchAll(
                db,
                EntryRevision
                    .filter(hashes.contains(Column("contentHash")))
                    .select(Column("contentHash"), as: String.self)
                    .distinct()))
            let orphans = hashes.subtracting(stillReferenced)

            return (Array(orphans), PurgeReport(
                revisionsPurged: revisions.count,
                objectsDeleted: orphans.count,
                jobsDeleted: jobsDeleted,
                assertionsDowngraded: downgraded,
                assertionsRetracted: retracted))
        }

        for hash in orphanHashes {
            try contentStore.delete(hash)
        }
        return report
    }

    /// Recomputes assertion status from surviving evidence, stance-aware:
    /// none → retracted; any contradicting → conflicted; supports-only →
    /// tentative (evidence loss always demands re-verification). Every
    /// evidence-mutation path funnels through here (plan §4).
    static func reconcileAssertions(
        _ db: Database, assertionIDs: [String]
    ) throws -> (downgraded: Int, retracted: Int) {
        guard !assertionIDs.isEmpty else { return (0, 0) }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT assertionID,
                       SUM(CASE WHEN stance = 'supports' THEN 1 ELSE 0 END) AS supports,
                       SUM(CASE WHEN stance = 'contradicts' THEN 1 ELSE 0 END) AS contradicts
                FROM assertionEvidence
                WHERE assertionID IN (\(databaseQuestionMarks(count: assertionIDs.count)))
                GROUP BY assertionID
                """,
            arguments: StatementArguments(assertionIDs))
        var counts: [String: (supports: Int, contradicts: Int)] = [:]
        for row in rows {
            counts[row["assertionID"]] = (row["supports"], row["contradicts"])
        }

        var downgraded = 0, retracted = 0
        for id in assertionIDs {
            let evidence = counts[id] ?? (supports: 0, contradicts: 0)
            let status: AssertionStatus
            if evidence.supports == 0 && evidence.contradicts == 0 {
                status = .retracted; retracted += 1
            } else if evidence.contradicts > 0 {
                status = .conflicted; downgraded += 1
            } else {
                status = .tentative; downgraded += 1
            }
            try db.execute(
                sql: "UPDATE profileAssertion SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [status, Date(), id])
        }
        return (downgraded, retracted)
    }

    /// Reclaims content-store objects no revision references — the crash
    /// window between a commit and its post-commit filesystem work leaks
    /// objects, and nothing else would ever revisit them. Runs at open.
    @discardableResult
    public func sweepOrphanedObjects() throws -> Int {
        let referenced = try pool.read { db in
            try Set(String.fetchAll(
                db, EntryRevision.select(Column("contentHash"), as: String.self).distinct()))
        }
        var swept = 0
        for hash in try contentStore.allObjectHashes() where !referenced.contains(hash) {
            try contentStore.delete(hash)
            swept += 1
        }
        return swept
    }

    // MARK: - Egress boundary

    /// The ONLY entry selector provider payloads and bridge packets may use.
    /// Excludes local-only and trashed entries structurally (plan §4); the
    /// internal pool means no code outside this module can select otherwise.
    public func entriesEligibleForEgress(
        facet: Facet? = nil, limit: Int = 200
    ) throws -> [Entry] {
        try pool.read { db in
            var request = Entry
                .filter(Column("localOnly") == false)
                .filter(Column("trashedAt") == nil)
            if let facet { request = request.filter(Column("facet") == facet) }
            return try request
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }
}

public enum VaultError: Error, Equatable {
    case entryNotFound(String)
}
