import Foundation

/// Dispatch layer for the versioned local socket protocol ("firmament/1"):
/// line-delimited JSON-RPC methods → BridgeService operations. Lives in core
/// so the protocol surface is unit-testable without sockets.
public struct BridgeRPCHandler: Sendable {
    public static let protocolVersion = "firmament/1"

    let bridge: BridgeService
    /// Source rows for filing outcomes per client (bootstrapped by the service).
    let agentSourceIDs: [AgentClient: String]

    public init(bridge: BridgeService, agentSourceIDs: [AgentClient: String]) {
        self.bridge = bridge
        self.agentSourceIDs = agentSourceIDs
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
        default:
            throw RPCError.unknownMethod(method)
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
