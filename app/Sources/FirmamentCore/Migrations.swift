import Foundation
import GRDB

enum Migrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("config", .blob)
                t.column("cursor", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "entry") { t in
                t.primaryKey("id", .text)
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .restrict)
                t.column("facet", .text).notNull()
                t.column("localOnly", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("trashedAt", .datetime)
                // Connector-side identity (e.g. Granola note id) for
                // revision-aware sync.
                t.column("externalID", .text)
            }
            try db.create(indexOn: "entry", columns: ["sourceID"])
            try db.create(indexOn: "entry", columns: ["facet"])
            try db.execute(sql: """
                CREATE UNIQUE INDEX entryExternalID ON entry(sourceID, externalID)
                WHERE externalID IS NOT NULL
                """)
            // Serves the egress selector: newest-first over live, shareable
            // entries without a full scan.
            try db.execute(sql: """
                CREATE INDEX entryEgress ON entry(createdAt DESC)
                WHERE trashedAt IS NULL AND localOnly = 0
                """)

            try db.create(table: "entryRevision") { t in
                t.primaryKey("id", .text)
                t.column("entryID", .text).notNull()
                    .references("entry", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("parentRevisionID", .text)
                t.column("contentHash", .text).notNull()
                t.column("mime", .text).notNull()
                t.column("metadata", .blob)
                t.column("importedAt", .datetime).notNull()
                t.uniqueKey(["entryID", "seq"])
            }
            try db.create(indexOn: "entryRevision", columns: ["contentHash"])

            try db.create(table: "transcriptSegment") { t in
                t.primaryKey("id", .text)
                t.column("revisionID", .text).notNull()
                    .references("entryRevision", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("speaker", .text)
                t.column("startMS", .integer)
                t.column("endMS", .integer)
                t.column("text", .text).notNull()
            }
            try db.create(indexOn: "transcriptSegment", columns: ["revisionID"])

            try db.create(table: "analysisRun") { t in
                t.primaryKey("id", .text)
                t.column("revisionID", .text).notNull()
                    .references("entryRevision", onDelete: .cascade)
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("promptVersion", .text).notNull()
                t.column("status", .text).notNull()
                t.column("output", .blob)
                t.column("error", .text)
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
            try db.create(indexOn: "analysisRun", columns: ["revisionID"])

            try db.create(table: "entryProjection") { t in
                t.primaryKey("entryID", .text)
                    .references("entry", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("people", .blob)
                t.column("projects", .blob)
                t.column("topics", .blob)
                t.column("analysisRunID", .text)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "profileAssertion") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("status", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "assertionEvidence") { t in
                t.primaryKey("id", .text)
                t.column("assertionID", .text).notNull()
                    .references("profileAssertion", onDelete: .cascade)
                t.column("revisionID", .text).notNull()
                    .references("entryRevision", onDelete: .cascade)
                t.column("quote", .text).notNull()
                t.column("spanStart", .integer)
                t.column("spanEnd", .integer)
                t.column("stance", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "assertionEvidence", columns: ["assertionID"])
            try db.create(indexOn: "assertionEvidence", columns: ["revisionID"])

            try db.create(table: "question") { t in
                t.primaryKey("id", .text)
                t.column("entryID", .text).notNull()
                    .references("entry", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("rationale", .text)
                t.column("status", .text).notNull()
                t.column("evidence", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
            }
            try db.create(indexOn: "question", columns: ["entryID"])
            try db.create(indexOn: "question", columns: ["status"])

            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("idempotencyKey", .text).notNull().unique()
                t.column("entryID", .text)
                t.column("payload", .blob)
                t.column("status", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("runAfter", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "job", columns: ["status", "runAfter"])
            try db.create(indexOn: "job", columns: ["entryID"])

            try db.create(table: "agentSession") { t in
                t.primaryKey("id", .text)
                t.column("client", .text).notNull()
                t.column("task", .text)
                t.column("packet", .blob)
                t.column("outcome", .blob)
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }

            // FTS5 index over projected text + raw body. Inserts are synced
            // in-transaction by code; deletion is covered structurally by the
            // trigger below, so every deletion path (including FK cascades)
            // provably clears the index.
            try db.create(virtualTable: "entrySearch", using: FTS5()) { t in
                t.column("entryID").notIndexed()
                t.column("title")
                t.column("summary")
                t.column("body")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
            try db.execute(sql: """
                CREATE TRIGGER entrySearchCleanup AFTER DELETE ON entry
                BEGIN
                    DELETE FROM entrySearch WHERE entryID = old.id;
                END
                """)
        }

        return migrator
    }
}
