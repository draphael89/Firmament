import Foundation
import GRDB

public enum ImportResult: Equatable, Sendable {
    case created(entryID: String, revisionID: String)
    /// Same raw bytes already in the vault (global content-hash dedup, plan §3).
    case duplicate(entryID: String)
}

public struct PurgeReport: Equatable, Sendable {
    public var entryID: String
    public var revisionsPurged: Int
    public var objectsDeleted: [String]
    public var jobsCanceled: Int
    public var assertionsDowngraded: Int
    public var assertionsRetracted: Int
}

/// The vault: sole owner of the SQLite database and content store.
/// All writes funnel through here (single-writer discipline, plan §4).
public final class VaultStore: Sendable {
    public let pool: DatabasePool
    public let contentStore: ContentStore

    /// Opens (creating if needed) a vault rooted at `directoryURL`:
    /// `vault.sqlite` + `objects/` live inside it.
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
    }

    // MARK: - Import

    /// Imports raw bytes as a new entry (or dedupes on content hash).
    /// The object is written to the content store first; the row transaction
    /// follows — a crash in between leaves an orphan object, never a
    /// dangling row.
    public func importEntry(
        sourceID: String,
        facet: Facet,
        data: Data,
        mime: String,
        metadata: Data? = nil,
        localOnly: Bool = false,
        searchableText: String? = nil
    ) throws -> ImportResult {
        let hash = try contentStore.put(data)
        return try pool.write { db in
            if let existing = try EntryRevision
                .filter(Column("contentHash") == hash)
                .fetchOne(db) {
                return .duplicate(entryID: existing.entryID)
            }
            var entry = Entry(sourceID: sourceID, facet: facet, localOnly: localOnly)
            let revision = EntryRevision(
                entryID: entry.id, seq: 1, contentHash: hash,
                mime: mime, metadata: metadata)
            entry.currentRevisionID = revision.id
            try entry.insert(db)
            try revision.insert(db)
            if let text = searchableText {
                try Self.replaceSearchRow(
                    db, entryID: entry.id, title: "", summary: "", body: text)
            }
            return .created(entryID: entry.id, revisionID: revision.id)
        }
    }

    /// Adds a new revision to an existing entry (e.g. a Granola remote edit).
    /// Returns nil if the content is unchanged from the current revision.
    public func addRevision(
        entryID: String, data: Data, mime: String, metadata: Data? = nil
    ) throws -> String? {
        let hash = try contentStore.put(data)
        return try pool.write { db in
            guard var entry = try Entry.fetchOne(db, key: entryID) else {
                throw VaultError.entryNotFound(entryID)
            }
            let current = try EntryRevision
                .filter(Column("entryID") == entryID)
                .order(Column("seq").desc)
                .fetchOne(db)
            if current?.contentHash == hash { return nil }
            let revision = EntryRevision(
                entryID: entryID, seq: (current?.seq ?? 0) + 1,
                parentRevisionID: current?.id, contentHash: hash,
                mime: mime, metadata: metadata)
            try revision.insert(db)
            entry.currentRevisionID = revision.id
            try entry.update(db)
            return revision.id
        }
    }

    // MARK: - Search

    /// Replaces the FTS row for an entry. Called in the same transaction as
    /// projection updates so index and truth never diverge.
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

    public func search(_ query: String, limit: Int = 50) throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else { return [] }
        return try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT entryID FROM entrySearch
                    WHERE entrySearch MATCH ?
                    ORDER BY rank LIMIT ?
                    """,
                arguments: [pattern, limit])
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

    /// Delete Now (plan §4): one transaction purges rows, FTS, and questions,
    /// cancels the entry's pending jobs, and downgrades assertions that lose
    /// evidence (remaining → tentative, none → retracted). Content-store
    /// objects are unlinked after commit iff no surviving revision references
    /// their hash.
    @discardableResult
    public func purgeEntry(entryID: String) throws -> PurgeReport {
        let (hashes, report) = try pool.write { db -> ([String], PurgeReport) in
            guard let entry = try Entry.fetchOne(db, key: entryID) else {
                throw VaultError.entryNotFound(entryID)
            }
            let revisions = try EntryRevision
                .filter(Column("entryID") == entryID).fetchAll(db)
            let revisionIDs = revisions.map(\.id)
            let hashes = revisions.map(\.contentHash)

            // Assertions whose evidence cites these revisions.
            var affectedAssertionIDs: [String] = []
            if !revisionIDs.isEmpty {
                let marks = databaseQuestionMarks(count: revisionIDs.count)
                affectedAssertionIDs = try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT assertionID FROM assertionEvidence WHERE revisionID IN (\(marks))",
                    arguments: StatementArguments(revisionIDs))
                try db.execute(
                    sql: "DELETE FROM assertionEvidence WHERE revisionID IN (\(marks))",
                    arguments: StatementArguments(revisionIDs))
            }

            var downgraded = 0, retracted = 0
            for assertionID in affectedAssertionIDs {
                guard var assertion = try ProfileAssertion.fetchOne(db, key: assertionID)
                else { continue }
                let remaining = try AssertionEvidence
                    .filter(Column("assertionID") == assertionID)
                    .fetchCount(db)
                assertion.status = remaining > 0 ? .tentative : .retracted
                assertion.updatedAt = Date()
                try assertion.update(db)
                if remaining > 0 { downgraded += 1 } else { retracted += 1 }
            }

            // Cancel unfinished jobs for this entry.
            let jobsCanceled = try Job
                .filter(Column("entryID") == entryID)
                .filter([JobStatus.pending, .running, .failedRetryable]
                    .contains(Column("status")))
                .deleteAll(db)

            try db.execute(
                sql: "DELETE FROM entrySearch WHERE entryID = ?",
                arguments: [entryID])
            // Cascades take segments, analysis runs, questions, projection,
            // and revisions with the entry row.
            try entry.delete(db)

            return (hashes, PurgeReport(
                entryID: entryID, revisionsPurged: revisions.count,
                objectsDeleted: [], jobsCanceled: jobsCanceled,
                assertionsDowngraded: downgraded, assertionsRetracted: retracted))
        }

        // Post-commit: unlink objects nothing references anymore.
        var deleted: [String] = []
        for hash in Set(hashes) {
            let stillReferenced = try pool.read { db in
                try EntryRevision.filter(Column("contentHash") == hash)
                    .fetchCount(db) > 0
            }
            if !stillReferenced {
                try contentStore.delete(hash)
                deleted.append(hash)
            }
        }
        var final = report
        final.objectsDeleted = deleted
        return final
    }

    // MARK: - Egress boundary

    /// The ONLY entry selector provider payloads and bridge packets may use.
    /// Excludes local-only and trashed entries structurally (plan §4).
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
