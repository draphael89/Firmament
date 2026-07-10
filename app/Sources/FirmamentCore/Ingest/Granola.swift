import Foundation
import GRDB

/// Transport seam so the connector is testable against fixtures.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - API client (documented shapes: docs.granola.ai)

public struct GranolaNote: Codable, Sendable {
    public struct Speaker: Codable, Sendable {
        public var source: String?
        public var diarizationLabel: String?
        enum CodingKeys: String, CodingKey {
            case source
            case diarizationLabel = "diarization_label"
        }
    }
    public struct Turn: Codable, Sendable {
        public var speaker: Speaker?
        public var text: String?
    }
    public struct Person: Codable, Sendable {
        public var name: String?
        public var email: String?
    }
    public var id: String
    public var title: String?
    public var summary: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var owner: Person?
    public var transcript: [Turn]?

    enum CodingKeys: String, CodingKey {
        case id, title, summary, owner, transcript
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct GranolaClient: Sendable {
    public struct NotesPage: Codable, Sendable {
        public var notes: [GranolaNote]
        public var hasMore: Bool?
        public var cursor: String?

        enum CodingKeys: String, CodingKey {
            case notes, hasMore, cursor, hasMoreSnake = "has_more",
                 nextCursor = "next_cursor"
        }

        /// Tolerant pagination decode: docs say camelCase, siblings are
        /// snake_case — accept either so a wire drift degrades to nothing
        /// worse than an explicit test failure, not a silent one-page sync.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notes = try c.decodeIfPresent([GranolaNote].self, forKey: .notes) ?? []
            hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
                ?? c.decodeIfPresent(Bool.self, forKey: .hasMoreSnake)
            cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
                ?? c.decodeIfPresent(String.self, forKey: .nextCursor)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(notes, forKey: .notes)
            try c.encodeIfPresent(hasMore, forKey: .hasMore)
            try c.encodeIfPresent(cursor, forKey: .cursor)
        }
    }

    let apiKey: String
    let baseURL: URL
    let transport: HTTPTransport

    public init(apiKey: String,
                baseURL: URL = URL(string: "https://public-api.granola.ai/v1")!,
                transport: HTTPTransport = URLSessionTransport()) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transport = transport
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
    }

    public func listNotes(cursor: String? = nil) async throws -> NotesPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("notes"), resolvingAgainstBaseURL: false)!
        if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        let (data, status) = try await transport.get(components.url!, headers: headers)
        guard status == 200 else { throw GranolaError.http(status) }
        return try JSONDecoder().decode(NotesPage.self, from: data)
    }

    /// Full note with transcript. Returns nil for 404 — Granola 404s notes
    /// that are still processing or have no summary yet; skip and retry on a
    /// later sync.
    public func note(id: String) async throws -> GranolaNote? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("notes/\(id)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "include", value: "transcript")]
        let (data, status) = try await transport.get(components.url!, headers: headers)
        if status == 404 { return nil }
        guard status == 200 else { throw GranolaError.http(status) }
        return try JSONDecoder().decode(GranolaNote.self, from: data)
    }
}

public enum GranolaError: Error, Equatable {
    case http(Int)
}

// MARK: - Connector

/// Others-facet connector (plan §3): cursor-based polling, revision-aware.
/// A remote edit becomes a new revision (content-hash change detection rides
/// addRevision); unchanged notes are no-ops.
public struct GranolaConnector: Sendable {
    public struct SyncReport: Equatable, Sendable {
        public var created: [(entryID: String, revisionID: String)] = []
        public var revised: [(entryID: String, revisionID: String)] = []
        public var unchanged = 0
        public var skippedProcessing = 0

        public static func == (lhs: SyncReport, rhs: SyncReport) -> Bool {
            lhs.created.map(\.entryID) == rhs.created.map(\.entryID)
                && lhs.revised.map(\.entryID) == rhs.revised.map(\.entryID)
                && lhs.unchanged == rhs.unchanged
                && lhs.skippedProcessing == rhs.skippedProcessing
        }
    }

    let vault: VaultStore
    let sourceID: String
    let client: GranolaClient

    public init(vault: VaultStore, sourceID: String, client: GranolaClient) {
        self.vault = vault
        self.sourceID = sourceID
        self.client = client
    }

    public func syncOnce() async throws -> SyncReport {
        var report = SyncReport()
        var cursor = try storedCursor()

        while true {
            let page = try await client.listNotes(cursor: cursor)
            for stub in page.notes {
                guard let note = try await client.note(id: stub.id) else {
                    report.skippedProcessing += 1
                    continue
                }
                try ingest(note, into: &report)
            }
            if let next = page.cursor { cursor = next }
            // hasMore without a fresh cursor would spin on the same page.
            if page.hasMore != true || page.cursor == nil { break }
        }
        try storeCursor(cursor)
        return report
    }

    func ingest(_ note: GranolaNote, into report: inout SyncReport) throws {
        let text = Self.render(note)
        let data = Data(text.utf8)
        let metadata = try JSONEncoder().encode(["granolaID": note.id])

        if let entryID = try vault.entryID(sourceID: sourceID, externalID: note.id) {
            if let revisionID = try vault.addRevision(
                entryID: entryID, data: data, mime: "text/markdown",
                metadata: metadata, searchableText: text) {
                try replaceSegments(revisionID: revisionID, note: note)
                report.revised.append((entryID, revisionID))
            } else {
                report.unchanged += 1
            }
            return
        }

        switch try vault.importEntry(
            sourceID: sourceID, facet: .others, data: data, mime: "text/markdown",
            metadata: metadata, searchableText: text, externalID: note.id) {
        case .created(let entryID, let revisionID):
            try replaceSegments(revisionID: revisionID, note: note)
            report.created.append((entryID, revisionID))
        case .duplicate:
            report.unchanged += 1
        }
    }

    private func replaceSegments(revisionID: String, note: GranolaNote) throws {
        guard let turns = note.transcript, !turns.isEmpty else { return }
        try vault.pool.write { db in
            for (index, turn) in turns.enumerated() {
                guard let text = turn.text, !text.isEmpty else { continue }
                try TranscriptSegment(
                    revisionID: revisionID, idx: index,
                    speaker: Self.speakerLabel(turn.speaker), text: text
                ).insert(db)
            }
        }
    }

    static func speakerLabel(_ speaker: GranolaNote.Speaker?) -> String? {
        guard let speaker else { return nil }
        if let label = speaker.diarizationLabel { return label }
        switch speaker.source {
        case "microphone": return "me"
        case "speaker": return "them"
        default: return speaker.source
        }
    }

    static func render(_ note: GranolaNote) -> String {
        var out: [String] = []
        out.append("# \(note.title ?? "Untitled meeting")")
        var meta = ["Granola \(note.id)"]
        if let created = note.createdAt { meta.append(created) }
        if let owner = note.owner?.name ?? note.owner?.email { meta.append("owner: \(owner)") }
        out.append(meta.joined(separator: " · "))
        if let summary = note.summary, !summary.isEmpty {
            out.append("")
            out.append("## Summary")
            out.append(summary)
        }
        if let turns = note.transcript, !turns.isEmpty {
            out.append("")
            out.append("## Transcript")
            for turn in turns {
                guard let text = turn.text, !text.isEmpty else { continue }
                let label = speakerLabel(turn.speaker) ?? "?"
                out.append("\(label): \(text)")
            }
        }
        return out.joined(separator: "\n")
    }

    // Cursor persists on the source row across syncs.
    private func storedCursor() throws -> String? {
        try vault.pool.read { db in
            try Source.fetchOne(db, key: sourceID)?.cursor
        }
    }

    private func storeCursor(_ cursor: String?) throws {
        try vault.pool.write { db in
            guard var source = try Source.fetchOne(db, key: sourceID) else { return }
            source.cursor = cursor
            try source.update(db)
        }
    }
}
