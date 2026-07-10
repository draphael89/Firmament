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
        let triggers = try vault.pool.read { db in
            try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
        }
        #expect(triggers.contains("entrySearchCleanup"))
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

        let hash = ContentStore.hash(of: data)
        #expect(try vault.contentStore.data(for: hash) == data)

        let second = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        #expect(second == .duplicate(entryID: entryID))
        #expect(try vault.pool.read { try Entry.fetchCount($0) } == 1)

        let revision = try vault.pool.read { try EntryRevision.fetchOne($0, key: revisionID) }
        #expect(revision?.entryID == entryID)
        #expect(revision?.seq == 1)
        #expect(revision?.contentHash == hash)
    }

    @Test("Duplicate import with localOnly escalates the existing entry's privacy — one-way")
    func duplicatePrivacyEscalation() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("sensitive thought".utf8)

        guard case .created(let entryID, _) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        else { Issue.record("expected creation"); return }
        #expect(try vault.entriesEligibleForEgress().map(\.id) == [entryID])

        // Re-import marked local-only: entry becomes local-only.
        _ = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain",
            localOnly: true)
        #expect(try vault.entriesEligibleForEgress().isEmpty)

        // Re-import without the flag: escalation never reverses.
        _ = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        #expect(try vault.entriesEligibleForEgress().isEmpty)
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

        #expect(try vault.addRevision(entryID: entryID, data: v1, mime: "text/plain") == nil)

        let secondRevID = try vault.addRevision(entryID: entryID, data: v2, mime: "text/plain")
        #expect(secondRevID != nil)
        let current = try vault.currentRevision(entryID: entryID)
        #expect(current?.id == secondRevID)
        #expect(current?.seq == 2)
        #expect(current?.parentRevisionID == firstRevID)
    }

    @Test("addRevision reindexes search so results track current content")
    func revisionReindex() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault, kind: .granola)

        guard case .created(let entryID, _) = try vault.importEntry(
            sourceID: source.id, facet: .others,
            data: Data("quarterly budget review".utf8), mime: "text/plain",
            searchableText: "quarterly budget review")
        else { Issue.record("expected creation"); return }
        #expect(try vault.search("budget") == [entryID])

        _ = try vault.addRevision(
            entryID: entryID, data: Data("pivot to roadmap planning".utf8),
            mime: "text/plain", searchableText: "pivot to roadmap planning")
        #expect(try vault.search("budget").isEmpty)
        #expect(try vault.search("roadmap") == [entryID])
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
        #expect(try vault.search("granola").isEmpty)

        try vault.purgeEntry(entryID: entryID)
        #expect(try vault.search("consciousness").isEmpty)
    }

    @Test("Search excludes trashed entries always, local-only unless asked")
    func searchRespectsBoundaries() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)

        guard case .created(let hidden, _) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet,
            data: Data("private lament".utf8), mime: "text/plain",
            localOnly: true, searchableText: "private lament"),
            case .created(let doomed, _) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data("trashed lament".utf8), mime: "text/plain",
                searchableText: "trashed lament")
        else { Issue.record("expected creations"); return }

        try vault.trash(entryID: doomed)

        // Egress-safe default: neither shows up.
        #expect(try vault.search("lament").isEmpty)
        // UI opt-in sees local-only but still never trashed.
        #expect(try vault.search("lament", includeLocalOnly: true) == [hidden])
    }

    @Test("Delete Now purges rows, index, all jobs, and raw bytes — provably")
    func purgeSemantics() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("delete me completely".utf8)
        let hash = ContentStore.hash(of: data)

        guard case .created(let entryID, let revisionID) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        else { Issue.record("expected creation"); return }

        try vault.updateProjection(
            EntryProjection(entryID: entryID, title: "Doomed", summary: "Gone soon."),
            searchBody: "delete me completely")
        try vault.pool.write { db in
            try TranscriptSegment(revisionID: revisionID, idx: 0, text: "delete me").insert(db)
            try AnalysisRun(revisionID: revisionID, provider: "codex",
                            model: "gpt-5.6-terra", promptVersion: "v1",
                            status: .succeeded).insert(db)
            try Question(entryID: entryID, text: "Why delete?").insert(db)
            // Jobs in every status — completed/terminal jobs carry payloads
            // derived from entry content and must not survive the purge.
            try Job(kind: "extract", idempotencyKey: "\(revisionID):extract:v1",
                    entryID: entryID, status: .pending).insert(db)
            try Job(kind: "extract", idempotencyKey: "\(revisionID):extract:v0",
                    entryID: entryID, payload: Data("excerpt".utf8),
                    status: .done).insert(db)
            try Job(kind: "question", idempotencyKey: "\(revisionID):question:v1",
                    entryID: entryID, status: .failedTerminal).insert(db)
        }

        let report = try vault.purgeEntry(entryID: entryID)
        #expect(report.revisionsPurged == 1)
        #expect(report.jobsDeleted == 3)
        #expect(report.objectsDeleted == 1)

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

    @Test("Purge reconciles assertions stance-aware: tentative / conflicted / retracted")
    func assertionReconciliation() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)

        func imported(_ text: String) throws -> (entry: String, revision: String) {
            guard case .created(let e, let r) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data(text.utf8), mime: "text/plain")
            else { throw VaultError.entryNotFound("import failed") }
            return (e, r)
        }
        let a = try imported("I deeply value craftsmanship")
        let b = try imported("Craftsmanship matters more than speed to me")
        let c = try imported("Honestly I ship fast and loose these days")

        let assertion = ProfileAssertion(
            kind: .value, text: "Values craftsmanship over speed", status: .verified)
        try vault.pool.write { db in
            try assertion.insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: a.revision,
                                  quote: "I deeply value craftsmanship").insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: b.revision,
                                  quote: "Craftsmanship matters more than speed").insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: c.revision,
                                  quote: "I ship fast and loose",
                                  stance: .contradicts).insert(db)
        }
        func status() throws -> AssertionStatus? {
            try vault.pool.read { try ProfileAssertion.fetchOne($0, key: assertion.id)?.status }
        }

        // Mixed evidence survives → conflicted (not clobbered to tentative).
        _ = try vault.purgeEntry(entryID: a.entry)
        #expect(try status() == .conflicted)

        // Only the contradicting evidence survives → still conflicted.
        _ = try vault.purgeEntry(entryID: b.entry)
        #expect(try status() == .conflicted)

        // No evidence left → retracted.
        let final = try vault.purgeEntry(entryID: c.entry)
        #expect(final.assertionsRetracted == 1)
        #expect(try status() == .retracted)
    }

    @Test("Supports-only evidence loss downgrades even a verified assertion to tentative")
    func assertionDowngradeToTentative() throws {
        let (vault, _) = try makeVault()
        let source = try makeSource(vault)

        guard case .created(let entryA, let revA) = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet,
            data: Data("first supporting note".utf8), mime: "text/plain"),
            case .created(_, let revB) = try vault.importEntry(
                sourceID: source.id, facet: .selfFacet,
                data: Data("second supporting note".utf8), mime: "text/plain")
        else { Issue.record("expected creations"); return }

        let assertion = ProfileAssertion(kind: .goal, text: "Ship Firmament", status: .verified)
        try vault.pool.write { db in
            try assertion.insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: revA,
                                  quote: "first").insert(db)
            try AssertionEvidence(assertionID: assertion.id, revisionID: revB,
                                  quote: "second").insert(db)
        }

        let report = try vault.purgeEntry(entryID: entryA)
        #expect(report.assertionsDowngraded == 1)
        let status = try vault.pool.read {
            try ProfileAssertion.fetchOne($0, key: assertion.id)?.status
        }
        #expect(status == .tentative)
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

        // Simulate a second entry referencing the same object.
        let entryB = Entry(sourceID: source.id, facet: .selfFacet)
        try vault.pool.write { db in
            try entryB.insert(db)
            try EntryRevision(entryID: entryB.id, seq: 1, contentHash: hash,
                              mime: "text/plain").insert(db)
        }

        let report = try vault.purgeEntry(entryID: entryA)
        #expect(report.objectsDeleted == 0)
        #expect(vault.contentStore.contains(hash))

        let report2 = try vault.purgeEntry(entryID: entryB.id)
        #expect(report2.objectsDeleted == 1)
        #expect(!vault.contentStore.contains(hash))
    }

    @Test("Orphaned objects are swept at open; duplicate import self-heals bytes")
    func orphanRecovery() throws {
        let (vault, dir) = try makeVault()
        let source = try makeSource(vault)
        let data = Data("real entry bytes".utf8)
        let hash = ContentStore.hash(of: data)
        guard case .created = try vault.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        else { Issue.record("expected creation"); return }

        // Simulate a crash-leaked orphan: bytes on disk, no referencing row.
        let orphan = try vault.contentStore.put(Data("crash leftover".utf8))
        #expect(vault.contentStore.contains(orphan))

        // Reopen: sweep reclaims the orphan, keeps the referenced object.
        let reopened = try VaultStore(directoryURL: dir)
        #expect(!reopened.contentStore.contains(orphan))
        #expect(reopened.contentStore.contains(hash))

        // Self-heal: bytes vanish out-of-band, duplicate import restores them.
        try reopened.contentStore.delete(hash)
        let result = try reopened.importEntry(
            sourceID: source.id, facet: .selfFacet, data: data, mime: "text/plain")
        guard case .duplicate = result else { Issue.record("expected duplicate"); return }
        #expect(reopened.contentStore.contains(hash))
    }

    @Test("Job enqueue dedupes on idempotency key")
    func jobIdempotency() throws {
        let (vault, _) = try makeVault()
        #expect(try vault.enqueueJob(kind: "extract", idempotencyKey: "rev1:extract:v1"))
        #expect(try !vault.enqueueJob(kind: "extract", idempotencyKey: "rev1:extract:v1"))
        #expect(try vault.pool.read { try Job.fetchCount($0) } == 1)
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
        try vault.contentStore.delete(h1)
    }
}
