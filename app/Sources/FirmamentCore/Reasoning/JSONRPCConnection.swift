import Foundation

/// Line-delimited JSON-RPC 2.0 over a pair of file handles — the codex
/// app-server wire format. Owns request-id correlation and fans server
/// notifications out to a single consumer stream.
actor JSONRPCConnection {
    struct Notification: Sendable {
        var method: String
        var params: [String: JSONValue]
    }

    enum ConnectionError: Error {
        case closed
        case remote(code: Int, message: String)
    }

    private let writeHandle: FileHandle
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var notificationContinuation: AsyncStream<Notification>.Continuation?
    private var readTask: Task<Void, Never>?
    private var closed = false

    /// Notifications arrive in wire order. Start consuming before sending
    /// requests whose completion is signaled by notification.
    nonisolated let notifications: AsyncStream<Notification>
    private nonisolated let notificationsSource: AsyncStream<Notification>.Continuation

    init(readHandle: FileHandle, writeHandle: FileHandle) {
        self.writeHandle = writeHandle
        var source: AsyncStream<Notification>.Continuation!
        notifications = AsyncStream { source = $0 }
        notificationsSource = source
        Task { await startReading(readHandle) }
    }

    private func startReading(_ readHandle: FileHandle) {
        guard !closed, readTask == nil else {
            try? readHandle.close()
            return
        }
        readTask = Task {
            do {
                for try await line in readHandle.bytes.lines {
                    await handleLine(line)
                }
            } catch {
                // fall through to close
            }
            try? readHandle.close()
            await readerDidFinish()
        }
    }

    private func readerDidFinish() {
        readTask = nil
        finishClose()
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = value else { return }

        if case .number(let id)? = msg["id"], msg["method"] == nil {
            // Response to one of our requests.
            guard let continuation = pending.removeValue(forKey: Int(id)) else { return }
            if case .object(let err)? = msg["error"] {
                let code = if case .number(let c)? = err["code"] { Int(c) } else { -1 }
                let message = if case .string(let m)? = err["message"] { m } else { "unknown" }
                continuation.resume(throwing: ConnectionError.remote(code: code, message: message))
            } else {
                continuation.resume(returning: msg["result"] ?? .null)
            }
        } else if case .string(let method)? = msg["method"] {
            let params: [String: JSONValue] =
                if case .object(let p)? = msg["params"] { p } else { [:] }
            notificationsSource.yield(Notification(method: method, params: params))
        }
    }

    func request(_ method: String, params: JSONValue?) async throws -> JSONValue {
        guard !closed else { throw ConnectionError.closed }
        nextID += 1
        let id = nextID
        var msg: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { msg["params"] = params }
        try write(msg)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    func notify(_ method: String, params: JSONValue? = nil) throws {
        guard !closed else { throw ConnectionError.closed }
        var msg: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "method": .string(method),
        ]
        if let params { msg["params"] = params }
        try write(msg)
    }

    private func write(_ message: [String: JSONValue]) throws {
        var data = try JSONEncoder().encode(JSONValue.object(message))
        data.append(0x0A)
        try writeHandle.write(contentsOf: data)
    }

    func close() {
        readTask?.cancel()
        finishClose()
    }

    private func finishClose() {
        guard !closed else { return }
        closed = true
        try? writeHandle.close()
        for (_, continuation) in pending {
            continuation.resume(throwing: ConnectionError.closed)
        }
        pending.removeAll()
        notificationsSource.finish()
    }
}

/// Minimal JSON value tree — the protocol surface is dynamic enough that
/// typed Codable structs per message would fight the (experimental) server.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
