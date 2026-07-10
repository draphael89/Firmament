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
}
