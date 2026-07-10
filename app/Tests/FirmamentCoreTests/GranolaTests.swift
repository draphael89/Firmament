import Foundation
import Synchronization
import Testing
@testable import FirmamentCore

/// Scripted transport: maps URL substrings to (status, body) responses.
private final class FixtureTransport: HTTPTransport, @unchecked Sendable {
    private struct State {
        var routes: [(match: String, status: Int, body: String)]
        var requested: [String] = []
    }
    private let state: Mutex<State>

    init(routes: [(match: String, status: Int, body: String)]) {
        state = Mutex(State(routes: routes))
    }

    var routes: [(match: String, status: Int, body: String)] {
        get { state.withLock { $0.routes } }
        set { state.withLock { $0.routes = newValue } }
    }
    var requested: [String] { state.withLock { $0.requested } }

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        state.withLock { $0.requested.append(url.absoluteString) }
        guard headers["Authorization"]?.hasPrefix("Bearer grn_") == true else {
            return (Data(), 401)
        }
        for route in routes where url.absoluteString.contains(route.match) {
            return (Data(route.body.utf8), route.status)
        }
        return (Data(), 404)
    }
}

private func makeVaultAndSource() throws -> (VaultStore, String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("firmament-granola-tests-\(UUID().uuidString)")
    let vault = try VaultStore(directoryURL: dir)
    let sourceID = try vault.ensureSource(kind: .granola, name: "granola")
    return (vault, sourceID)
}

private let notesListPage = """
    {"notes": [{"id": "not_abc", "title": "Roadmap sync"},
               {"id": "not_def", "title": "1:1 with Sam"},
               {"id": "not_processing", "title": "Still cooking"}],
     "hasMore": false, "cursor": "cur_1"}
    """

private func noteBody(id: String, title: String, summary: String) -> String {
    """
    {"id": "\(id)", "title": "\(title)", "created_at": "2026-07-09T15:00:00Z",
     "owner": {"name": "David", "email": "d@example.com"},
     "summary": "\(summary)",
     "transcript": [
       {"speaker": {"source": "microphone"}, "text": "Let us cut scope to ship Friday"},
       {"speaker": {"source": "speaker"}, "text": "Agreed, drop the importer"}
     ]}
    """
}

@Suite("Granola connector")
struct GranolaTests {

    private func makeConnector(routes: [(String, Int, String)])
        throws -> (GranolaConnector, VaultStore, FixtureTransport) {
        let (vault, sourceID) = try makeVaultAndSource()
        let transport = FixtureTransport(routes: routes.map {
            (match: $0.0, status: $0.1, body: $0.2)
        })
        let client = GranolaClient(apiKey: "grn_test", transport: transport)
        return (GranolaConnector(vault: vault, sourceID: sourceID, client: client),
                vault, transport)
    }

    @Test("First sync imports notes as Others entries with segments and cursor")
    func firstSync() async throws {
        let (connector, vault, _) = try makeConnector(routes: [
            ("notes/not_abc", 200, noteBody(id: "not_abc", title: "Roadmap sync",
                                            summary: "Cut scope; ship Friday.")),
            ("notes/not_def", 200, noteBody(id: "not_def", title: "1:1 with Sam",
                                            summary: "Growth path discussion.")),
            // not_processing falls through to 404 (still processing).
            ("notes/not_", 404, ""),
            ("/notes", 200, notesListPage),
        ])

        let report = try await connector.syncOnce()
        #expect(report.created.count == 2)
        #expect(report.skippedProcessing == 1)

        let entry = try vault.entry(id: report.created[0].entryID)
        #expect(entry?.facet == .others)
        #expect(entry?.externalID == "not_abc")

        // Multi-speaker turns landed as segments with speaker labels.
        let segments = try await vault.pool.read { try TranscriptSegment.fetchAll($0) }
        #expect(segments.count == 4)
        #expect(Set(segments.compactMap(\.speaker)) == ["me", "them"])

        // Searchable, and the cursor persisted for the next incremental sync.
        #expect(try vault.search("ship Friday").count == 2)
        let cursor = try await vault.pool.read { try Source.fetchAll($0).first?.cursor }
        #expect(cursor == "cur_1")
    }

    @Test("Unchanged notes are no-ops; edits become new revisions")
    func revisionAwareness() async throws {
        let routes: [(String, Int, String)] = [
            ("notes/not_abc", 200, noteBody(id: "not_abc", title: "Roadmap sync",
                                            summary: "Cut scope; ship Friday.")),
            ("notes/not_def", 200, noteBody(id: "not_def", title: "1:1 with Sam",
                                            summary: "Growth path discussion.")),
            ("notes/not_", 404, ""),
            ("/notes", 200, notesListPage),
        ]
        let (connector, vault, transport) = try makeConnector(routes: routes)
        _ = try await connector.syncOnce()

        // Same content again: everything unchanged.
        let second = try await connector.syncOnce()
        #expect(second.created.isEmpty)
        #expect(second.unchanged == 2)

        // Remote edit: summary changes → revision 2 on the same entry.
        transport.routes = [
            ("notes/not_abc", 200, noteBody(id: "not_abc", title: "Roadmap sync",
                                            summary: "Scope restored after pushback.")),
            ("notes/not_def", 200, noteBody(id: "not_def", title: "1:1 with Sam",
                                            summary: "Growth path discussion.")),
            ("notes/not_", 404, ""),
            ("/notes", 200, notesListPage),
        ]
        let third = try await connector.syncOnce()
        #expect(third.revised.count == 1)
        #expect(third.unchanged == 1)

        let entryID = third.revised[0].entryID
        let current = try vault.currentRevision(entryID: entryID)
        #expect(current?.seq == 2)
        #expect(try vault.search("pushback").first == entryID)
    }

    @Test("Pagination follows cursors until hasMore is false")
    func pagination() async throws {
        let page1 = """
            {"notes": [{"id": "not_1"}], "hasMore": true, "cursor": "cur_next"}
            """
        let page2 = """
            {"notes": [{"id": "not_2"}], "hasMore": false, "cursor": "cur_final"}
            """
        let (connector, _, transport) = try makeConnector(routes: [
            ("notes/not_1", 200, noteBody(id: "not_1", title: "A", summary: "s1")),
            ("notes/not_2", 200, noteBody(id: "not_2", title: "B", summary: "s2")),
            ("cursor=cur_next", 200, page2),
            ("/notes", 200, page1),
        ])
        let report = try await connector.syncOnce()
        #expect(report.created.count == 2)
        #expect(transport.requested.contains { $0.contains("cursor=cur_next") })
    }

    @Test("Non-200 list responses surface as errors, not silent empty syncs")
    func httpErrors() async throws {
        let (connector, _, _) = try makeConnector(routes: [("/notes", 500, "boom")])
        await #expect(throws: GranolaError.self) {
            _ = try await connector.syncOnce()
        }
    }
}
