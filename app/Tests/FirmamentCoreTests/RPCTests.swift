import Foundation
import Testing
@testable import FirmamentCore

private func makeHandler() throws -> (BridgeRPCHandler, VaultStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("firmament-rpc-tests-\(UUID().uuidString)")
    let vault = try VaultStore(directoryURL: dir)
    let sourceID = try vault.ensureSource(kind: .claudeCode, name: "sessions")
    _ = try vault.importEntry(
        sourceID: sourceID, facet: .selfFacet,
        data: Data("I prefer boring technology for infrastructure".utf8),
        mime: "text/plain",
        searchableText: "I prefer boring technology for infrastructure")
    let bridge = BridgeService(
        vault: vault, identityURL: dir.appendingPathComponent("identity.md"))
    let handler = BridgeRPCHandler(
        bridge: bridge, agentSourceIDs: [.claudeCode: sourceID])
    return (handler, vault)
}

@Suite("Bridge RPC")
struct RPCTests {

    @Test("Full round trip: prepare → ask → outcome → health over the protocol")
    func roundTrip() throws {
        let (handler, _) = try makeHandler()

        let packet = try handler.handle(
            method: "prepare_session",
            params: .object([
                "task": .string("choose an infrastructure stack"),
                "client": .string("claude_code"),
            ]))
        guard let sessionID = packet["sessionID"]?.stringValue else {
            Issue.record("no session id"); return
        }
        #expect(packet["rendered"]?.stringValue?.contains("boring technology") == true)

        let answer = try handler.handle(
            method: "ask_glia",
            params: .object([
                "sessionID": .string(sessionID),
                "question": .string("infrastructure preferences"),
            ]))
        #expect(answer["status"]?.stringValue == "supported")

        let outcome = try handler.handle(
            method: "record_outcome",
            params: .object([
                "sessionID": .string(sessionID),
                "summary": .string("Picked postgres over the shiny thing"),
            ]))
        #expect(outcome["entryID"]?.stringValue != nil)

        let health = try handler.handle(method: "health", params: nil)
        #expect(health["protocolVersion"]?.stringValue == "firmament/1")
        // The outcome entry landed in the agents facet.
        if case .number(let agents)? = health["entryCounts"]?["agents"] {
            #expect(agents == 1)
        } else {
            Issue.record("missing agents count")
        }
    }

    @Test("Unknown methods and bad params are structured errors")
    func errors() throws {
        let (handler, _) = try makeHandler()
        #expect(throws: RPCError.self) {
            _ = try handler.handle(method: "nonsense", params: nil)
        }
        #expect(throws: RPCError.self) {
            _ = try handler.handle(method: "ask_glia", params: .object([:]))
        }
    }

    @Test("Socket wire format: result and error envelopes")
    func wireFormat() throws {
        let (handler, _) = try makeHandler()

        let good = SocketServer.respond(
            to: #"{"jsonrpc":"2.0","id":7,"method":"health"}"#, handler: handler)
        #expect(good["id"] == .number(7))
        #expect(good["result"]?["protocolVersion"]?.stringValue == "firmament/1")

        let bad = SocketServer.respond(to: "not json", handler: handler)
        #expect(bad["error"] != nil)

        let unknown = SocketServer.respond(
            to: #"{"jsonrpc":"2.0","id":8,"method":"nope"}"#, handler: handler)
        #expect(unknown["id"] == .number(8))
        #expect(unknown["error"] != nil)
    }
}
