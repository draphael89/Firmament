import Foundation
import GRDB
import Testing
@testable import FirmamentCore

/// Fresh vault in a unique temp directory per test.
private func makeVault() throws -> (VaultStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("firmament-tests-\(UUID().uuidString)")
    let vault = try VaultStore(directoryURL: dir)
    return (vault, dir)
}

private func makeSource(_ vault: VaultStore, kind: SourceKind = .capture) throws -> Source {
    let source = Source(kind: kind, name: "test-source")
    try vault.pool.write { try source.insert($0) }
    return source
}

@Suite("Vault storage")
struct VaultStoreTests {

    @Test("Migration creates the full schema")
    func schema() throws {
        let (vault, _) = try makeVault()
        let tables = try vault.pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') ORDER BY name")
        }
        for expected in ["source", "entry", "entryRevision", "transcriptSegment",
                         "analysisRun", "entryProjection", "profileAssertion",
                         "assertionEvidence", "question", "job", "agentSession",
                         "entrySearch"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test("Import stores raw bytes content-addressed and dedupes by hash")
    func importAndDedup() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("a voice note about consciousness".utf8)

        let first = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        guard case .created(let entryID, let revisionID) = first else {
            Issue.record("expected creation"); return
        }

        // Raw bytes are retrievable by hash.
        let hash = ContentStore.hash(of: data)
        #expect(try vault.contentStore.data(for: hash) == data)

        // Same bytes again → duplicate, no new entry.
        let second = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        #expect(second == .duplicate(entryID: entryID))
        let entryCount = try vault.pool.read { try Entry.fetchCount($0) }
        #expect(entryCount == 1)

        // Revision points at the entry with seq 1.
        let revision = try vault.pool.read { try EntryRevision.fetchOne($0, key: revisionID) }
        #expect(revision?.entryID == entryID)
        #expect(revision?.seq == 1)
        #expect(revision?.contentHash == hash)
    }

    @Test("Revisions chain with ancestry; unchanged content adds nothing")
    func revisionChain() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault, kind: .granola)
        let v1 = Data("meeting notes v1".utf8)
        let v2 = Data("meeting notes v2 — edited remotely".utf8)

        guard case .created(let entryID, let firstRevID) = try vault.importEntry(
            sourceID: source.id, facet: .others, data: v1, mime: "text/plain")
        else { Issue.record("expected creation"); return }

        // Same content → nil, no new revision.
        #expect(try vault.addRevision(entryID: entryID, data: v1, mime: "text/plain") == nil)

        // New content → revision 2 with parent pointer, currentRevisionID advances.
        let secondRevID = try vault.addRevision(entryID: entryID, data: v2, mime: "text/plain")
        #expect(secondRevID != nil)
        let (entry, second) = try vault.pool.read { db in
            (try Entry.fetchOne(db, key: entryID),
             try EntryRevision.fetchOne(db, key: secondRevID!))
        }
        #expect(entry?.currentRevisionID == secondRevID)
        #expect(second?.seq == 2)
        #expect(second?.parentRevisionID == firstRevID)
    }

    @Test("FTS search finds projected entries and respects purge")
    func searchLifecycle() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        guard case .created(let entryID, _) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet,
            data: Data("thinking about emergence and consciousness".utf8),
            mime: "text/plain")
        else { Issue.record("expected creation"); return }

        try vault.updateProjection(
            EntryProjection(entryID: entryID, title: "On consciousness",
                            summary: "A note about emergence."),
            searchBody: "thinking about emergence and consciousness")

        #expect(try vault.search("consciousness") == [entryID])
        #expect(try vault.search("emergence") == [entryID])
        #expect(try vault.search("granola").isEmpty)

        try vault.purgeEntry(entryID: entryID)
        #expect(try vault.search("consciousness").isEmpty)
    }

    @Test("Delete Now purges rows, index, jobs, and raw bytes — provably")
    func purgeSemantics() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("delete me completely".utf8)
        let hash = ContentStore.hash(of: data)

        guard case .created(let entryID, let revisionID) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        else { Issue.record("expected creation"); return }

        // Populate every derived surface.
        try vault.updateProjection(
            EntryProjection(entryID: entryID, title: "Doomed", summary: "Gone soon."),
            searchBody: "delete me completely")
        try vault.pool.write { db in
            try TranscriptSegment(revisionID: revisionID, idx: 0, text: "delete me").insert(db)
            try AnalysisRun(revisionID: revisionID, provider: "codex",
                            model: "gpt-5.6-terra", promptVersion: "v1",
                            status: .succeeded).insert(db)
            try Question(entryID: entryID, text: "Why delete?").insert(db)
            try Job(kind: "extract", idempotencyKey: "\(revisionID):extract:v1",
                    entryID: entryID).insert(db)
        }

        let report = try vault.purgeEntry(entryID: entryID)
        #expect(report.revisionsPurged == 1)
        #expect(report.jobsCanceled == 1)
        #expect(report.objectsDeleted == [hash])

        // Rows: gone. Index: gone. Bytes: gone.
        try vault.pool.read { db in
            #expect(try Entry.fetchCount(db) == 0)
            #expect(try EntryRevision.fetchCount(db) == 0)
            #expect(try TranscriptSegment.fetchCount(db) == 0)
            #expect(try AnalysisRun.fetchCount(db) == 0)
            #expect(try Question.fetchCount(db) == 0)
            #expect(try EntryProjection.fetchCount(db) == 0)
            #expect(try Job.fetchCount(db) == 0)
            let ftsRows = try Int.fetchOne(db, sql: "SELECT count(*) FROM entrySearch") ?? -1
            #expect(ftsRows == 0)
        }
        #expect(!vault.contentStore.contains(hash))
    }

    @Test("Purge downgrades assertions: remaining evidence → tentative, none → retracted")
    func assertionDowngrade() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)

        guard case .created(let entryA, let revA) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet,
            data: Data("I deeply value craftsmanship".utf8), mime: "text/plain"),
            case .created(let entryB, let revB) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data("Craftsmanship matters more than speed to me".utf8),
                mime: "text/plain")
        else { Issue.record("expected creations"); return }

        let assertion = ProfileAssertion(
            kind: .value, text: "Values craftsmanship over speed", status: .verified)
        try vault.pool.write { db in
            try assertion.insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: revA,
                                  quote: "I deeply value craftsmanship").insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: revB,
                                  quote: "Craftsmanship matters more than speed").insert(db)
        }

        // Purge one evidence source → downgrade to tentative (even from verified).
        let report1 = try vault.purgeEntry(entryID: entryA)
        #expect(report1.assertionsDowngraded == 1)
        #expect(report1.assertionsRetracted == 0)
        var current = try vault.pool.read { try ProfileAssertion.fetchOne($0, key: assertion.id) }
        #expect(current?.status == .tentative)

        // Purge the last evidence source → retracted.
        let report2 = try vault.purgeEntry(entryID: entryB)
        #expect(report2.assertionsRetracted == 1)
        current = try vault.pool.read { try ProfileAssertion.fetchOne($0, key: assertion.id) }
        #expect(current?.status == .retracted)
    }

    @Test("Shared content-store objects survive purge of one referencing entry")
    func sharedObjectRetained() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("shared bytes".utf8)
        let hash = ContentStore.hash(of: data)

        guard case .created(let entryA, _) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        else { Issue.record("expected creation"); return }

        // Simulate a second entry referencing the same object (importer
        // dedupes, so wire the rows directly — e.g. a future re-link path).
        let entryB = Entry(sourceID: source.id, facet: .selfFacet)
        try vault.pool.write { db in
            try entryB.insert(db)
            try EntryRevision(entryID: entryB.id, seq: 1, contentHash: hash,
                              mime: "text/plain").insert(db)
        }

        let report = try vault.purgeEntry(entryID: entryA)
        #expect(report.objectsDeleted.isEmpty)
        #expect(vault.contentStore.contains(hash))

        let report2 = try vault.purgeEntry(entryID: entryB.id)
        #expect(report2.objectsDeleted == [hash])
        #expect(!vault.contentStore.contains(hash))
    }

    @Test("local_only and trashed entries are structurally excluded from egress")
    func egressBoundary() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)

        guard case .created(let visible, _) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet,
            data: Data("shareable thought".utf8), mime: "text/plain"),
            case .created(let hidden, _) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data("never leaves this machine".utf8), mime: "text/plain",
                localOnly: true),
            case .created(let trashed, _) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data("in the trash".utf8), mime: "text/plain")
        else { Issue.record("expected creations"); return }
        try vault.trash(entryID: trashed)

        let eligible = try vault.entriesEligibleForEgress().map(\.id)
        #expect(eligible == [visible])
        #expect(!eligible.contains(hidden))
        #expect(!eligible.contains(trashed))

        // Untrash restores egress eligibility; local_only never does.
        try vault.untrash(entryID: trashed)
        let after = Set(try vault.entriesEligibleForEgress().map(\.id))
        #expect(after == [visible, trashed])
    }

    @Test("Content store writes are idempotent and content-addressed")
    func contentStore() throws {
        let (vault, _) = try makeVault()
        let data = Data("some raw audio bytes".utf8)
        let h1 = try vault.contentStore.put(data)
        let h2 = try vault.contentStore.put(data)
        #expect(h1 == h2)
        #expect(h1 == ContentStore.hash(of: data))
        #expect(try vault.contentStore.data(for: h1) == data)
        try vault.contentStore.delete(h1)
        #expect(!vault.contentStore.contains(h1))
        // Deleting a missing object is a no-op, not an error.
        try vault.contentStore.delete(h1)
    }
}
