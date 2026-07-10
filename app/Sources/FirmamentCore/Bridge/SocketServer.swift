import Foundation

/// Unix-domain socket server for the bridge protocol: line-delimited
/// JSON-RPC, one response per request. The accept loop runs on a dedicated
/// thread (accept(2) blocks); each connection is served by a task.
public final class SocketServer: Sendable {
    private let listenFD: Int32
    private let handler: BridgeRPCHandler
    private let path: String

    public init(path: String, handler: BridgeRPCHandler) throws {
        self.handler = handler
        self.path = path
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketError.create(errno) }

        var addr = try ServicePaths.unixSockaddr(path: path)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw SocketError.bind(errno) }
        guard listen(listenFD, 8) == 0 else { throw SocketError.listen(errno) }
    }

    /// Accepts and serves connections until the process exits.
    public func run() async {
        let fd = listenFD
        let connections = AsyncStream<Int32> { continuation in
            let thread = Thread {
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    continuation.yield(client)
                }
                continuation.finish()
            }
            thread.name = "firmament-socket-accept"
            thread.start()
        }
        await withDiscardingTaskGroup { group in
            for await clientFD in connections {
                let handler = self.handler
                group.addTask { await Self.serve(clientFD, handler: handler) }
            }
        }
    }

    private static func serve(_ fd: Int32, handler: BridgeRPCHandler) async {
        let readHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let writeHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            for try await line in readHandle.bytes.lines {
                let response = respond(to: line, handler: handler)
                var data = try JSONEncoder().encode(response)
                data.append(0x0A)
                try writeHandle.write(contentsOf: data)
            }
        } catch {
            // Peer went away; nothing to clean up beyond the handle.
        }
    }

    static func respond(to line: String, handler: BridgeRPCHandler) -> JSONValue {
        let id: JSONValue
        let result: Result<JSONValue, Error>
        if let data = line.data(using: .utf8),
           let message = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object(let obj) = message,
           case .string(let method)? = obj["method"] {
            id = obj["id"] ?? .null
            result = Result { try handler.handle(method: method, params: obj["params"]) }
        } else {
            id = .null
            result = .failure(RPCError.badParams("unparseable request line"))
        }
        switch result {
        case .success(let value):
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
        case .failure(let error):
            let (code, message) = Self.wireError(error)
            return .object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object([
                    "code": .number(Double(code)),
                    "message": .string(message),
                ]),
            ])
        }
    }

    /// Distinct codes and human messages per error class — the wire contract
    /// is not a Swift debug dump.
    static func wireError(_ error: Error) -> (Int, String) {
        switch error {
        case RPCError.unknownMethod(let method):
            return (-32601, "method not found: \(method)")
        case RPCError.badParams(let detail):
            return (-32602, "invalid params: \(detail)")
        case RPCError.misconfigured(let detail):
            return (-32002, "service misconfigured: \(detail)")
        case BridgeError.unknownSession(let id):
            return (-32001, "unknown session: \(id)")
        case VaultError.entryNotFound(let id):
            return (-32001, "entry not found: \(id)")
        default:
            return (-32000, "internal error: \(error)")
        }
    }
}

public enum SocketError: Error {
    case create(Int32), bind(Int32), listen(Int32), pathTooLong
}
