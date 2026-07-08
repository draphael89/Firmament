import Foundation

/// Canonical on-disk locations (SPEC §5.3, §6.1).
public enum FirmamentPaths {
    /// `~/Library/Application Support/Firmament/`
    public static func applicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firmament", isDirectory: true)
    }

    public static func defaultLedger() -> URL {
        applicationSupport().appendingPathComponent("ledger.sqlite")
    }

    /// `~/Firmament/Vault/` — the human escape hatch.
    public static func defaultVault() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Firmament", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
    }
}
