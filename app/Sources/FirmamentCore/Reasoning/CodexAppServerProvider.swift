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
        guard let threadID = threadResult["threadId"]?.stringValue else {
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

        let outcome = try await awaitTurn(id: turnID)
        defer { agentText[threadID] = nil }

        if outcome.failed {
            let message = outcome.errorMessage ?? "turn failed"
            switch outcome.errorInfo {
            case "usageLimitExceeded":
                throw ReasoningError.usageLimitExceeded(retryAfter: nil)
            case "unauthorized", "authExpired":
                throw ReasoningError.authExpired(message)
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
        self.connection = conn
        startPump(conn)

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
            await teardown()
            throw ReasoningError.providerUnavailable("initialize failed: \(error)")
        }
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
                  item["type"]?.stringValue == "agentMessage",
                  let threadID = notification.params["threadId"]?.stringValue
                    ?? item["threadId"]?.stringValue,
                  let text = item["text"]?.stringValue else { return }
            agentText[threadID] = text
        case "turn/completed", "turn/failed":
            guard let turn = notification.params["turn"],
                  let turnID = turn["id"]?.stringValue else { return }
            let error = turn["error"]
            let outcome = TurnOutcome(
                failed: notification.method == "turn/failed" || error != nil
                    && turn["status"]?.stringValue != "completed",
                errorMessage: error?["message"]?.stringValue,
                errorInfo: error?["codexErrorInfo"]?.stringValue)
            turnWaiters.removeValue(forKey: turnID)?.resume(returning: outcome)
        default:
            break
        }
    }

    private func awaitTurn(id: String) async throws -> TurnOutcome {
        let timeout = turnTimeout
        return try await withThrowingTaskGroup(of: TurnOutcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Task { await self.addWaiter(id: id, continuation: continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ReasoningError.providerUnavailable("turn timed out after \(timeout)")
            }
            guard let outcome = try await group.next() else {
                throw ReasoningError.providerUnavailable("turn wait aborted")
            }
            group.cancelAll()
            return outcome
        }
    }

    private func addWaiter(
        id: String, continuation: CheckedContinuation<TurnOutcome, Never>
    ) {
        turnWaiters[id] = continuation
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
