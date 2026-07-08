import Foundation

/// Chain verification + export used identically by the CLI (U8), the crash
/// harness (U11), and tests. Verification re-hashes stored bytes only
/// (KTD1); it never re-serializes.
public enum LedgerVerifier {
    public struct Outcome: Sendable, Equatable {
        public var lines: [String]
        /// 0 = every chain intact (or empty); 1 = corruption (hash mismatch);
        /// 2 = incomplete (linkage holes — indistinguishable from sync lag,
        /// never reported as corrupt).
        public var exitCode: Int32
    }

    public static func verify(store: LedgerStore) throws -> Outcome {
        let events = try store.fetchAll()
        var lines = [String]()
        var exitCode: Int32 = 0

        for device in DeviceID.allCases {
            let status = HashChain.verify(events, deviceID: device)
            let checkpointNote = latestCheckpointNote(events: events, device: device)
            switch status {
            case .empty:
                lines.append("\(device.rawValue): empty")
            case .intact(let head, let count):
                lines.append("\(device.rawValue): intact — \(count) event(s), head \(head.hexEncoded.prefix(12))…\(checkpointNote)")
            case .incomplete(let gaps, let head, let count):
                lines.append("\(device.rawValue): INCOMPLETE — \(count) event(s), \(gaps.count) gap(s) at \(gaps.map { $0.uuidString.lowercased() }.joined(separator: ", ")); head \(head.hexEncoded.prefix(12))…\(checkpointNote)")
                lines.append("  (holes are indistinguishable from sync lag; not corruption)")
                exitCode = max(exitCode, 2)
            case .corrupt(let firstBad, let reason):
                lines.append("\(device.rawValue): CORRUPT — first bad event \(firstBad.uuidString.lowercased()) (\(reason))")
                exitCode = 1
            }
        }
        return Outcome(lines: lines, exitCode: exitCode)
    }

    /// The most recent sync.checkpoint's recorded head — distinguishes lag
    /// (checkpoint agrees with what we hold) from loss (checkpoint claims a
    /// head we never reached).
    static func latestCheckpointNote(events: [Event], device: DeviceID) -> String {
        let checkpoints = events
            .filter { $0.kind == .syncCheckpoint && $0.deviceID == device }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard let latest = checkpoints.last,
              let payload = try? SyncCheckpointPayload(canonical: latest.decodedPayload()) else {
            return ""
        }
        return "; checkpoint \(payload.day) head \(payload.chainHead.prefix(12))…"
    }

    /// Canonical export: every event, timeline (id) order, one canonical
    /// JSON object per line. The hostage-proofing escape hatch (SPEC §5.5).
    public static func export(store: LedgerStore) throws -> String {
        try EventNDJSON.encode(try store.fetchAll())
    }
}
