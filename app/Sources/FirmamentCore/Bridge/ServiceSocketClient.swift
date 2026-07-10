import Foundation

/// Client side of the service socket: one JSON-RPC response line per request
/// line, reconnecting on failure. Shared by the MCP adapter and the Mac app
/// (which routes all writes through the service to preserve the sole-writer
/// invariant).
public final class ServiceSocketClient: @unchecked Sendable {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 0
    private let lock = NSLock()
    public let path: String

    public init(path: String) { self.path = path }

    public func call(method: String, params: [String: Any]) throws -> Any {
        lock.lock(); defer { lock.unlock() }
        try connectIfNeeded()
        nextID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": nextID, "method": method, "params": params,
        ]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count else {
            disconnect()
            throw ServiceClientError.unavailable("write to service failed")
        }
        let line = try readResponseLine()
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ServiceClientError.protocolError("unparseable service response")
        }
        if let error = obj["error"] as? [String: Any] {
            throw ServiceClientError.remote(error["message"] as? String ?? "unknown service error")
        }
        return obj["result"] ?? [:]
    }

    private func connectIfNeeded() throws {
        guard fd < 0 else { return }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ServiceClientError.unavailable("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            _ = path.utf8CString.withUnsafeBytes { src in
                memcpy(dest.baseAddress!, src.baseAddress!, min(src.count, dest.count))
            }
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            throw ServiceClientError.unavailable(
                "firmament-service is not running (no socket at \(path)). Start it and retry.")
        }
        fd = sock
    }

    private func readResponseLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                disconnect()
                throw ServiceClientError.unavailable("service connection closed")
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        buffer.removeAll()
    }
}

public enum ServiceClientError: Error {
    case unavailable(String), remote(String), protocolError(String)

    public var message: String {
        switch self {
        case .unavailable(let m), .remote(let m), .protocolError(let m): return m
        }
    }
}
