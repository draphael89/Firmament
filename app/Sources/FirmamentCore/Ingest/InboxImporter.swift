import Foundation

/// Watched-folder importer (plan §3 durability conventions): writers land
/// files as `*.partial` then rename; the importer additionally waits a
/// quiescence window (iCloud Drive syncs are not atomic); dedup rides the
/// vault's content-hash check; malformed files quarantine visibly instead of
/// failing silently. Files are removed after successful import — the vault
/// owns the bytes from then on.
public struct InboxImporter: Sendable {
    public struct ScanReport: Equatable, Sendable {
        public var imported: [(entryID: String, revisionID: String)] = []
        public var duplicates: Int = 0
        public var skipped: Int = 0
        public var quarantined: [String] = []

        public static func == (lhs: ScanReport, rhs: ScanReport) -> Bool {
            lhs.imported.map(\.entryID) == rhs.imported.map(\.entryID)
                && lhs.duplicates == rhs.duplicates
                && lhs.skipped == rhs.skipped
                && lhs.quarantined == rhs.quarantined
        }
    }

    static let textMimes: [String: String] = [
        "txt": "text/plain", "md": "text/markdown", "text": "text/plain",
    ]
    static let mediaMimes: [String: String] = [
        "m4a": "audio/mp4", "mp3": "audio/mpeg", "wav": "audio/wav",
        "aiff": "audio/aiff", "caf": "audio/x-caf",
    ]

    let vault: VaultStore
    let sourceID: String
    let inboxURL: URL
    let quarantineURL: URL
    let quiescence: TimeInterval

    public init(vault: VaultStore, sourceID: String, inboxURL: URL,
                quiescence: TimeInterval = 5) throws {
        self.vault = vault
        self.sourceID = sourceID
        self.inboxURL = inboxURL
        self.quarantineURL = inboxURL.appendingPathComponent("quarantine", isDirectory: true)
        self.quiescence = quiescence
        try FileManager.default.createDirectory(
            at: inboxURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: quarantineURL, withIntermediateDirectories: true)
    }

    /// One pass over the inbox. Call from the service's poll loop or a
    /// directory-change source; every pass is safe to repeat.
    public func scanOnce(now: Date = Date()) throws -> ScanReport {
        var report = ScanReport()
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: inboxURL, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])

        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(".partial") { continue }
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }

            // Quiescence: a file still being written (or synced) waits.
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) < quiescence {
                report.skipped += 1
                continue
            }

            let ext = url.pathExtension.lowercased()
            guard let (mime, isText) =
                Self.textMimes[ext].map({ ($0, true) })
                ?? Self.mediaMimes[ext].map({ ($0, false) })
            else {
                try quarantine(url, reason: "unsupported type .\(ext)", report: &report)
                continue
            }

            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                try quarantine(url, reason: "unreadable or empty", report: &report)
                continue
            }
            var searchable: String?
            if isText {
                guard let text = String(data: data, encoding: .utf8) else {
                    try quarantine(url, reason: "not valid UTF-8", report: &report)
                    continue
                }
                searchable = text
            }

            let metadata = try JSONEncoder().encode(["originalFilename": name])
            switch try vault.importEntry(
                sourceID: sourceID, facet: .selfFacet, data: data, mime: mime,
                metadata: metadata, searchableText: searchable) {
            case .created(let entryID, let revisionID):
                report.imported.append((entryID, revisionID))
            case .duplicate:
                report.duplicates += 1
            }
            try fm.removeItem(at: url)
        }
        return report
    }

    private func quarantine(
        _ url: URL, reason: String, report: inout ScanReport
    ) throws {
        let destination = quarantineURL.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: url, to: destination)
        try "\(Date()): \(reason)\n".write(
            to: destination.appendingPathExtension("reason"),
            atomically: true, encoding: .utf8)
        report.quarantined.append(url.lastPathComponent)
    }
}
