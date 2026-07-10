import Foundation

/// Shared path derivations for the service and its clients.
public enum ServicePaths {
    /// Unix socket paths are capped (~104 bytes on macOS). Prefer the vault
    /// home; fall back to a short /tmp path derived deterministically from
    /// the home path so server and client always agree without a rendezvous
    /// file.
    public static func socketPath(home: URL) -> String {
        let candidate = home.appendingPathComponent("service.sock").path
        if candidate.utf8.count <= 100 { return candidate }
        let digest = ContentStore.hash(of: Data(home.path.utf8)).prefix(12)
        return "/tmp/firmament-\(digest).sock"
    }

    /// One place that knows how to fill a sockaddr_un (bind and connect
    /// sides had drifted copies of this unsafe dance).
    static func unixSockaddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLength else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            _ = path.utf8CString.withUnsafeBytes { src in
                memcpy(dest.baseAddress!, src.baseAddress!, min(src.count, dest.count))
            }
        }
        return addr
    }
}
