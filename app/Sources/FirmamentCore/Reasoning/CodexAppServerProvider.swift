import Foundation

/// ReasoningProvider backed by `codex app-server` (stdio JSON-RPC) under the
/// operator's ChatGPT subscription — the Gate 0 spike's flow, productionized:
/// initialize → ephemeral read-only thread per request → turn/start with a
/// native outputSchema → await turn completion notifications.
///
/// Failure taxonomy is mapped from the server's structured errors so the job
/// queue can distinguish "wait for the usage window" from "this job is bad".
public actor CodexAppServerProvider: ReasoningProvider {
    private var process: Process?
    private var connection: JSONRPCConnection?
    private var pumpTask: Task<Void, Never>?

    /// Latest agent message text per thread (each request owns its thread).
    private var agentText: [String: String] = [:]
    private var turnWaiters: [String: CheckedContinuation<TurnOutcome, Never>] = [:]
    /// Outcomes that arrived before their waiter registered (the turn/start
    /// response and the completion notification race on fast failures).
    private var earlyOutcomes: [String: TurnOutcome] = [:]

    private struct TurnOutcome: Sendable {
        var failed: Bool
        var errorMessage: String?
        var errorInfo: String?
    }

    private let executable: String
    private let turnTimeout: Duration

    public init(executable: String = "codex", turnTimeout: Duration = .seconds(600)) {
        self.executable = executable
        self.turnTimeout = turnTimeout
    }

    public func complete(_ request: ReasoningRequest) async throws -> String {
        let conn = try await ensureStarted()

        let threadResult: JSONValue
        do {
            threadResult = try await conn.request("thread/start", params: .object([
                "ephemeral": .bool(true),
                "sandbox": .string("read-only"),
                "cwd": .string(FileManager.default.temporaryDirectory.path),
            ]))
        } catch {
            await teardown()
            throw ReasoningError.providerUnavailable("thread/start: \(error)")
        }
        // The wire shape has varied across app-server versions: top-level
        // threadId or a nested thread object (the spike saw both).
        guard let threadID = threadResult["threadId"]?.stringValue
            ?? threadResult["thread"]?["id"]?.stringValue else {
            throw ReasoningError.providerUnavailable("thread/start returned no threadId")
        }

        var turnParams: [String: JSONValue] = [
            "threadId": .string(threadID),
            "model": .string(request.model),
            "input": .array([.object([
                "type": .string("text"), "text": .string(request.prompt),
            ])]),
        ]
        if let effort = request.effort { turnParams["effort"] = .string(effort) }
        if let schema = request.outputSchema {
            turnParams["outputSchema"] = try JSONDecoder().decode(JSONValue.self, from: schema)
        }

        let turnResult: JSONValue
        do {
            turnResult = try await conn.request("turn/start", params: .object(turnParams))
        } catch {
            await teardown()
            throw ReasoningError.providerUnavailable("turn/start: \(error)")
        }
        guard let turnID = turnResult["turn"]?["id"]?.stringValue else {
            throw ReasoningError.providerUnavailable("turn/start returned no turn id")
        }

        let outcome = await awaitTurn(id: turnID)
        defer { agentText[threadID] = nil }

        if outcome.failed {
            let message = outcome.errorMessage ?? "turn failed"
            switch outcome.errorInfo {
            case "usageLimitExceeded":
                throw ReasoningError.usageLimitExceeded(retryAfter: nil)
            case "unauthorized", "authExpired":
                throw ReasoningError.authExpired(message)
            case "connectionClosed", "timeout":
                // Transport trouble, not the job's fault — parks, never
                // burns retry attempts (plan §11).
                throw ReasoningError.providerUnavailable(message)
            default:
                if message.localizedCaseInsensitiveContains("log in")
                    || message.localizedCaseInsensitiveContains("auth") {
                    throw ReasoningError.authExpired(message)
                }
                throw ReasoningError.turnFailed(message)
            }
        }
        guard let text = agentText[threadID], !text.isEmpty else {
            throw ReasoningError.invalidOutput("turn completed with no agent message")
        }
        return text
    }

    // MARK: - Lifecycle

    private func ensureStarted() async throws -> JSONRPCConnection {
        if let connection, process?.isRunning == true { return connection }
        await teardown()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw ReasoningError.providerUnavailable("cannot launch \(executable): \(error)")
        }

        let conn = JSONRPCConnection(
            readHandle: stdout.fileHandleForReading,
            writeHandle: stdin.fileHandleForWriting)
        self.process = process
        startPump(conn)

        // Drain stderr or the pipe buffer fills and stalls the server.
        let stderrHandle = stderr.fileHandleForReading
        Task.detached {
            while let data = try? stderrHandle.read(upToCount: 65536),
                  !data.isEmpty {}
        }

        do {
            _ = try await conn.request("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("firmament-core"),
                    "title": .string("Firmament"),
                    "version": .string("0.1.0"),
                ])
            ]))
            try await conn.notify("initialized")
        } catch {
            await conn.close()
            await teardown()
            throw ReasoningError.providerUnavailable("initialize failed: \(error)")
        }
        // Published only after the handshake: a second complete() during
        // startup must not race thread/start ahead of initialize.
        self.connection = conn
        return conn
    }

    /// Consumes server notifications: collects agent messages per thread and
    /// resolves turn waiters on completion. Ends when the connection closes,
    /// failing any waiters left behind.
    private func startPump(_ conn: JSONRPCConnection) {
        pumpTask = Task { [weak self] in
            for await notification in conn.notifications {
                await self?.handle(notification)
            }
            await self?.connectionClosed()
        }
    }

    private func handle(_ notification: JSONRPCConnection.Notification) {
        switch notification.method {
        case "item/completed":
            guard let item = notification.params["item"],
                  let type = item["type"]?.stringValue,
                  type == "agentMessage" || type == "agent_message",
                  let threadID = notification.params["threadId"]?.stringValue
                    ?? item["threadId"]?.stringValue,
                  let text = item["text"]?.stringValue else { return }
            agentText[threadID] = text
        case "turn/completed", "turn/failed":
            // Hedge both wire shapes (nested turn.id / flat turnId) — the
            // experimental protocol has shipped both.
            let turn = notification.params["turn"] ?? .object([:])
            guard let turnID = turn["id"]?.stringValue
                ?? notification.params["turnId"]?.stringValue else { return }
            // JSON "error": null decodes to .null, which is a non-nil
            // JSONValue — normalize it away before judging failure.
            let error = turn["error"].flatMap { $0 == .null ? nil : $0 }
            let outcome = TurnOutcome(
                failed: notification.method == "turn/failed"
                    || turn["status"]?.stringValue == "failed"
                    || error != nil,
                errorMessage: error?["message"]?.stringValue,
                errorInfo: error?["codexErrorInfo"]?.stringValue)
            if let waiter = turnWaiters.removeValue(forKey: turnID) {
                waiter.resume(returning: outcome)
            } else {
                earlyOutcomes[turnID] = outcome
            }
        default:
            break
        }
    }

    /// Deadlock-free wait: one continuation, resumed by exactly one of the
    /// notification pump, the timeout task, or connection loss — whichever
    /// removes it from the waiter map first.
    private func awaitTurn(id: String) async -> TurnOutcome {
        if let early = earlyOutcomes.removeValue(forKey: id) { return early }
        let timeoutTask = Task { [turnTimeout] in
            try? await Task.sleep(for: turnTimeout)
            await self.resolveTurn(id: id, with: TurnOutcome(
                failed: true,
                errorMessage: "turn timed out after \(turnTimeout)",
                errorInfo: "timeout"))
        }
        defer {
            timeoutTask.cancel()
            // If timeout and completion raced, the loser parked an outcome
            // for a turn nobody will await again — don't leak it.
            earlyOutcomes.removeValue(forKey: id)
        }
        return await withCheckedContinuation { continuation in
            if let early = earlyOutcomes.removeValue(forKey: id) {
                continuation.resume(returning: early)
            } else {
                turnWaiters[id] = continuation
            }
        }
    }

    private func resolveTurn(id: String, with outcome: TurnOutcome) {
        if let waiter = turnWaiters.removeValue(forKey: id) {
            waiter.resume(returning: outcome)
        } else {
            earlyOutcomes[id] = outcome
        }
    }

    private func connectionClosed() {
        for (_, waiter) in turnWaiters {
            waiter.resume(returning: TurnOutcome(
                failed: true, errorMessage: "app-server connection closed",
                errorInfo: "connectionClosed"))
        }
        turnWaiters.removeAll()
        connection = nil
    }

    private func teardown() async {
        pumpTask?.cancel()
        pumpTask = nil
        if let connection { await connection.close() }
        connection = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
