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

    /// `<group>/Library/Application Support/Firmament/` — mirrors the Mac
    /// layout (SPEC §5.3). Files at the group *root* are outside the
    /// inspectable container domains and violate Apple's layout convention.
    public static func sharedContainer() -> URL {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return applicationSupport()
        }
        return group
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Firmament", isDirectory: true)
    }

    /// One-time move of a legacy group-root layout into `sharedContainer()`.
    /// Runs before any store opens; no-op once migrated.
    public static func migrateLegacyGroupRootIfNeeded() {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return }
        let destination = sharedContainer()
        let fm = FileManager.default
        for name in ["ledger.sqlite", "ledger.sqlite-wal", "ledger.sqlite-shm", "media", "sync"] {
            let legacy = group.appendingPathComponent(name)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: legacy, to: target)
            }
        }
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
