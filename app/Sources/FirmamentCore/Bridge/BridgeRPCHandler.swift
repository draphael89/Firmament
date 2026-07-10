import Foundation

/// Dispatch layer for the versioned local socket protocol ("firmament/1"):
/// line-delimited JSON-RPC methods → BridgeService operations. Lives in core
/// so the protocol surface is unit-testable without sockets.
public struct BridgeRPCHandler: Sendable {
    public static let protocolVersion = "firmament/1"

    let bridge: BridgeService
    /// Source rows for filing outcomes per client (bootstrapped by the service).
    let agentSourceIDs: [AgentClient: String]
    /// Source for operator-authored content (in-app capture, question answers).
    let captureSourceID: String?
    /// Called after any import so the service can enqueue processing.
    let onImported: (@Sendable (_ entryID: String, _ revisionID: String) -> Void)?

    public init(bridge: BridgeService, agentSourceIDs: [AgentClient: String],
                captureSourceID: String? = nil,
                onImported: (@Sendable (String, String) -> Void)? = nil) {
        self.bridge = bridge
        self.agentSourceIDs = agentSourceIDs
        self.captureSourceID = captureSourceID
        self.onImported = onImported
    }

    struct PrepareParams: Codable {
        var task: String
        var client: String?
        var prd: String?
    }
    struct AskParams: Codable {
        var sessionID: String
        var question: String
    }
    struct ExplainParams: Codable { var sessionID: String }
    struct OutcomeParams: Codable {
        var sessionID: String
        var summary: String
        var rating: Int?
    }

    public func handle(method: String, params: JSONValue?) throws -> JSONValue {
        switch method {
        case "prepare_session":
            let p: PrepareParams = try decode(params)
            let client = p.client.flatMap(AgentClient.init(rawValue:)) ?? .claudeCode
            return try encode(bridge.prepareSession(
                task: p.task, client: client, prd: p.prd))
        case "ask_glia":
            let p: AskParams = try decode(params)
            return try encode(bridge.askGlia(sessionID: p.sessionID, question: p.question))
        case "explain_session":
            let p: ExplainParams = try decode(params)
            return try encode(bridge.explainSession(sessionID: p.sessionID))
        case "record_outcome":
            let p: OutcomeParams = try decode(params)
            let client = try clientForSession(p.sessionID)
            guard let sourceID = agentSourceIDs[client] else {
                throw RPCError.misconfigured("no source for client \(client.rawValue)")
            }
            let entryID = try bridge.recordOutcome(
                sessionID: p.sessionID, summary: p.summary,
                rating: p.rating, agentSourceID: sourceID)
            return .object(["entryID": .string(entryID)])
        case "health":
            return try encode(bridge.health())

        // App write surface (the app reads the vault directly read-only;
        // every mutation funnels through the service).
        case "trash_entry":
            let p: EntryParams = try decode(params)
            try bridge.vault.trash(entryID: p.entryID)
            return .object(["ok": .bool(true)])
        case "untrash_entry":
            let p: EntryParams = try decode(params)
            try bridge.vault.untrash(entryID: p.entryID)
            return .object(["ok": .bool(true)])
        case "purge_entry":
            let p: EntryParams = try decode(params)
            let report = try bridge.vault.purgeEntry(entryID: p.entryID)
            return try encode(report)
        case "capture_note":
            let p: CaptureParams = try decode(params)
            guard let sourceID = captureSourceID else {
                throw RPCError.misconfigured("no capture source configured")
            }
            let result = try bridge.vault.importEntry(
                sourceID: sourceID, facet: .selfFacet,
                data: Data(p.text.utf8), mime: "text/plain",
                localOnly: p.localOnly ?? false, searchableText: p.text)
            if case .created(let entryID, let revisionID) = result {
                onImported?(entryID, revisionID)
                return .object(["entryID": .string(entryID)])
            }
            if case .duplicate(let entryID) = result {
                return .object(["entryID": .string(entryID)])
            }
            throw RPCError.misconfigured("unreachable")
        case "answer_question":
            let p: AnswerParams = try decode(params)
            guard let sourceID = captureSourceID else {
                throw RPCError.misconfigured("no capture source configured")
            }
            let entryID = try answerQuestion(
                questionID: p.questionID, answer: p.answer, sourceID: sourceID)
            return .object(["entryID": .string(entryID)])
        case "dismiss_question":
            let p: QuestionParams = try decode(params)
            try resolveQuestion(id: p.questionID, status: .dismissed)
            return .object(["ok": .bool(true)])

        default:
            throw RPCError.unknownMethod(method)
        }
    }

    struct EntryParams: Codable { var entryID: String }
    struct CaptureParams: Codable {
        var text: String
        var localOnly: Bool?
    }
    struct AnswerParams: Codable {
        var questionID: String
        var answer: String
    }
    struct QuestionParams: Codable { var questionID: String }

    /// The answer becomes a linked Self entry (plan §6: answers are new
    /// evidence; they never silently mutate anything).
    private func answerQuestion(
        questionID: String, answer: String, sourceID: String
    ) throws -> String {
        guard let question = try bridge.vault.pool.read({ db in
            try Question.fetchOne(db, key: questionID)
        }) else {
            throw RPCError.badParams("unknown question \(questionID)")
        }
        let text = "Q: \(question.text)\n\nA: \(answer)"
        let result = try bridge.vault.importEntry(
            sourceID: sourceID, facet: .selfFacet,
            data: Data(text.utf8), mime: "text/plain",
            metadata: try JSONEncoder().encode(["answersQuestionID": questionID]),
            searchableText: text)
        try resolveQuestion(id: questionID, status: .answered)
        switch result {
        case .created(let entryID, let revisionID):
            onImported?(entryID, revisionID)
            return entryID
        case .duplicate(let entryID):
            return entryID
        }
    }

    private func resolveQuestion(id: String, status: QuestionStatus) throws {
        try bridge.vault.pool.write { db in
            guard var question = try Question.fetchOne(db, key: id) else {
                throw RPCError.badParams("unknown question \(id)")
            }
            question.status = status
            question.resolvedAt = Date()
            try question.update(db)
        }
    }

    private func clientForSession(_ sessionID: String) throws -> AgentClient {
        try bridge.vault.pool.read { db in
            guard let session = try AgentSession.fetchOne(db, key: sessionID) else {
                throw BridgeError.unknownSession(sessionID)
            }
            return session.client
        }
    }

    private func decode<T: Decodable>(_ params: JSONValue?) throws -> T {
        guard let params else { throw RPCError.badParams("missing params") }
        let data = try JSONEncoder().encode(params)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RPCError.badParams("\(error)")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

public enum RPCError: Error, Equatable {
    case unknownMethod(String)
    case badParams(String)
    case misconfigured(String)
}
