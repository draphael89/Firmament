import Foundation
import GRDB

/// Public read surface for browsing clients (the Mac app). Keeps GRDB and
/// the pool fully encapsulated; clients get plain values.
public struct BrowseRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var facet: Facet
    public var title: String
    public var summary: String
    public var createdAt: Date
    public var localOnly: Bool
    public var trashed: Bool
    public var hasOpenQuestion: Bool
}

public struct QuestionSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var entryID: String
    public var text: String
    public var rationale: String?
    public var entryTitle: String
}

public struct EntryDetail: Equatable, Sendable {
    public var row: BrowseRow
    public var rawText: String?
    public var mime: String
    public var revisionCount: Int
    public var people: [String]
    public var projects: [String]
    public var topics: [String]
    public var question: QuestionSummary?
}

public enum BrowseScope: Hashable, Sendable {
    case all
    case facet(Facet)
    case trash
}

extension VaultStore {

    public func browse(
        scope: BrowseScope, matching query: String? = nil, limit: Int = 400
    ) throws -> [BrowseRow] {
        let searchIDs: Set<String>? = try query
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            .map { Set(try search($0, includeLocalOnly: true, limit: limit)) }

        return try pool.read { db in
            var request = Entry.order(Column("createdAt").desc).limit(limit)
            switch scope {
            case .all:
                request = request.filter(Column("trashedAt") == nil)
            case .facet(let facet):
                request = request
                    .filter(Column("trashedAt") == nil)
                    .filter(Column("facet") == facet)
            case .trash:
                request = request.filter(Column("trashedAt") != nil)
            }
            var entries = try request.fetchAll(db)
            if let searchIDs { entries = entries.filter { searchIDs.contains($0.id) } }

            let projections = try EntryProjection
                .fetchAll(db, keys: entries.map(\.id))
                .reduce(into: [String: EntryProjection]()) { $0[$1.entryID] = $1 }
            let openQuestionEntryIDs = Set(try Question
                .filter(Column("status") == QuestionStatus.open)
                .select(Column("entryID"), as: String.self)
                .fetchAll(db))

            return try entries.map { entry in
                let projection = projections[entry.id]
                return BrowseRow(
                    id: entry.id, facet: entry.facet,
                    title: try projection?.title ?? fallbackTitle(db: db, entry: entry),
                    summary: projection?.summary ?? "",
                    createdAt: entry.createdAt,
                    localOnly: entry.localOnly,
                    trashed: entry.trashedAt != nil,
                    hasOpenQuestion: openQuestionEntryIDs.contains(entry.id))
            }
        }
    }

    /// Pre-projection fallback: first line of the raw text (local-only
    /// entries are never processed, so this is their permanent title), or a
    /// mime hint for media.
    private func fallbackTitle(db: Database, entry: Entry) throws -> String {
        guard let revision = try Self.currentRevision(db, entryID: entry.id) else {
            return "Untitled"
        }
        if revision.mime.hasPrefix("audio/") { return "Audio — awaiting transcription" }
        if revision.mime.hasPrefix("text/"),
           let raw = try? contentStore.data(for: revision.contentHash),
           let text = String(data: raw, encoding: .utf8) {
            let firstLine = text.split(separator: "\n", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            if !firstLine.isEmpty { return String(firstLine.prefix(72)) }
        }
        return "Untitled — processing"
    }

    public func openQuestions() throws -> [QuestionSummary] {
        try pool.read { db in
            let questions = try Question
                .filter(Column("status") == QuestionStatus.open)
                .order(Column("createdAt").desc)
                .fetchAll(db)
            let projections = try EntryProjection
                .fetchAll(db, keys: questions.map(\.entryID))
                .reduce(into: [String: EntryProjection]()) { $0[$1.entryID] = $1 }
            return questions.map {
                QuestionSummary(
                    id: $0.id, entryID: $0.entryID, text: $0.text,
                    rationale: $0.rationale,
                    entryTitle: projections[$0.entryID]?.title ?? "an entry")
            }
        }
    }

    public func entryDetail(id: String) throws -> EntryDetail? {
        guard let entry = try entry(id: id),
              let revision = try currentRevision(entryID: id) else { return nil }
        let rawText: String? = revision.mime.hasPrefix("text/")
            ? (try? rawContent(revision: revision))
                .flatMap { String(data: $0, encoding: .utf8) }
            : nil

        return try pool.read { db in
            let projection = try EntryProjection.fetchOne(db, key: id)
            let question = try Question
                .filter(Column("entryID") == id)
                .filter(Column("status") == QuestionStatus.open)
                .fetchOne(db)
            func list(_ data: Data?) -> [String] {
                data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            }
            let row = BrowseRow(
                id: entry.id, facet: entry.facet,
                title: projection?.title ?? "Untitled — processing",
                summary: projection?.summary ?? "",
                createdAt: entry.createdAt, localOnly: entry.localOnly,
                trashed: entry.trashedAt != nil, hasOpenQuestion: question != nil)
            return EntryDetail(
                row: row, rawText: rawText, mime: revision.mime,
                revisionCount: try EntryRevision
                    .filter(Column("entryID") == id).fetchCount(db),
                people: list(projection?.people),
                projects: list(projection?.projects),
                topics: list(projection?.topics),
                question: question.map {
                    QuestionSummary(id: $0.id, entryID: id, text: $0.text,
                                    rationale: $0.rationale,
                                    entryTitle: projection?.title ?? "")
                })
        }
    }
}
