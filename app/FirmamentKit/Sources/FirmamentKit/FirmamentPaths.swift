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

    /// The iOS App Group (SPEC §5.2, plan KTD11): audio + ledger shared
    /// between the app and its extensions. Falls back to app support in
    /// development builds without the entitlement.
    public static let appGroupIdentifier = "group.com.davidraphael.firmament"

    public static func sharedContainer() -> URL {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? applicationSupport()
    }

    #if os(macOS)
    /// `~/Firmament/Vault/` — the human escape hatch. Mac-only: the phone
    /// never materializes Lenses (SPEC §5.5).
    public static func defaultVault() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Firmament", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
    }
    #endif
}
