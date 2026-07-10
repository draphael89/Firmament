import Foundation
import Testing
import Darwin
@testable import FirmamentCore

private func unboundUnixSocketDescriptors() -> Set<Int32> {
    let descriptorNames = (try? FileManager.default
        .contentsOfDirectory(atPath: "/dev/fd")) ?? []
    let openDescriptors = descriptorNames
        .compactMap(Int32.init)
        .filter { fcntl($0, F_GETFD) >= 0 }
    return Set(openDescriptors.compactMap { descriptor in
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let hasEmptyPath = withUnsafeBytes(of: address.sun_path) {
            $0.first == 0
        }
        return result == 0 && address.sun_family == AF_UNIX && hasEmptyPath
            ? descriptor : nil
    })
}

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
    let captureSourceID = try vault.ensureSource(kind: .capture, name: "capture")
    let handler = BridgeRPCHandler(
        bridge: bridge, agentSourceIDs: [.claudeCode: sourceID],
        captureSourceID: captureSourceID)
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

    @Test("App write surface: capture, trash cycle, question lifecycle, purge")
    func appWriteSurface() throws {
        let (handler, vault) = try makeHandler()

        // capture_note creates a Self entry and reports it.
        let captured = try handler.handle(
            method: "capture_note",
            params: .object(["text": .string("captured via the app"),
                             "localOnly": .bool(false)]))
        guard let entryID = captured["entryID"]?.stringValue else {
            Issue.record("no entryID"); return
        }
        #expect(try vault.entry(id: entryID)?.facet == .selfFacet)

        // trash / untrash round trip.
        _ = try handler.handle(
            method: "trash_entry", params: .object(["entryID": .string(entryID)]))
        #expect(try vault.entry(id: entryID)?.trashedAt != nil)
        _ = try handler.handle(
            method: "untrash_entry", params: .object(["entryID": .string(entryID)]))
        #expect(try vault.entry(id: entryID)?.trashedAt == nil)

        // answer_question files a linked Self entry and resolves the question.
        let question = Question(entryID: entryID, text: "Why capture this?")
        try vault.pool.write { try question.insert($0) }
        let answered = try handler.handle(
            method: "answer_question",
            params: .object(["questionID": .string(question.id),
                             "answer": .string("Because provenance matters")]))
        #expect(answered["entryID"]?.stringValue != nil)
        let resolved = try vault.pool.read { try Question.fetchOne($0, key: question.id) }
        #expect(resolved?.status == .answered)
        #expect(try vault.search("provenance matters").count == 1)

        // dismiss_question on an unknown id is a structured error.
        #expect(throws: RPCError.self) {
            _ = try handler.handle(
                method: "dismiss_question",
                params: .object(["questionID": .string("nope")]))
        }

        // purge_entry reports and removes.
        let report = try handler.handle(
            method: "purge_entry", params: .object(["entryID": .string(entryID)]))
        if case .number(let purged)? = report["revisionsPurged"] {
            #expect(purged == 1)
        } else {
            Issue.record("missing purge report")
        }
        #expect(try vault.entry(id: entryID) == nil)
    }

    @Test("Wire errors carry distinct codes per class")
    func wireErrorCodes() throws {
        #expect(SocketServer.wireError(RPCError.unknownMethod("x")).0 == -32601)
        #expect(SocketServer.wireError(RPCError.badParams("x")).0 == -32602)
        #expect(SocketServer.wireError(BridgeError.unknownSession("s")).0 == -32001)
        #expect(SocketServer.wireError(VaultError.entryNotFound("e")).0 == -32001)
        #expect(!SocketServer.wireError(BridgeError.unknownSession("s")).1.contains("("))
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

    @Test("Socket startup surfaces stale-path removal failures")
    func socketUnlinkFailure() throws {
        let (handler, _) = try makeHandler()
        let occupiedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-socket-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: occupiedPath, withIntermediateDirectories: true)

        do {
            _ = try SocketServer(path: occupiedPath.path, handler: handler)
            Issue.record("Expected socket-path removal to fail")
        } catch SocketError.unlink(let code) {
            #expect(code == EPERM)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Socket startup closes its descriptor when bind fails")
    func socketBindFailureClosesDescriptor() throws {
        let (handler, _) = try makeHandler()
        let socketPath = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("fm-missing-" + UUID().uuidString)
            .appendingPathComponent("service.sock")
        let before = unboundUnixSocketDescriptors()

        do {
            _ = try SocketServer(path: socketPath.path, handler: handler)
            Issue.record("Expected binding below a missing directory to fail")
        } catch SocketError.bind(let code) {
            #expect(code == ENOENT)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let leaked = unboundUnixSocketDescriptors().subtracting(before)
        #expect(leaked.isEmpty)
    }
}
