import CryptoKit
import Foundation

/// Per-device hash chains (SPEC §5.1, plan KTD3). Genesis is chain-specific
/// so a forged sub-chain from another device cannot be spliced in.
public enum HashChain {
    public static func genesis(for deviceID: DeviceID) -> Data {
        let seed = "\(deviceID.rawValue)|firmament-genesis-v1"
        return Data(SHA256.hash(data: Data(seed.utf8)))
    }

    /// Chain status for one device's events.
    public enum Status: Sendable, Equatable {
        /// Every event self-verifies and links contiguously from genesis.
        case intact(head: Data, count: Int)
        /// Every present event self-verifies, but linkage has holes —
        /// indistinguishable from sync lag, reported as incomplete (never
        /// as corrupt). `gaps` are the events whose prevHash didn't match
        /// the running head.
        case incomplete(gaps: [UUID], head: Data, count: Int)
        /// An event fails self-integrity (payload or envelope hash mismatch).
        case corrupt(firstBad: UUID, reason: String)
        /// No events for this device.
        case empty
    }

    /// Verify one device's chain. `events` may contain any mix of devices;
    /// only `deviceID`'s events are considered, ordered by UUIDv7 id (the
    /// timeline order events were sealed in).
    public static func verify(_ events: [Event], deviceID: DeviceID) -> Status {
        let chain = events
            .filter { $0.deviceID == deviceID }
            .sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
        guard !chain.isEmpty else { return .empty }

        var expectedPrev = genesis(for: deviceID)
        var gaps = [UUID]()
        for event in chain {
            guard event.verifySelfIntegrity() else {
                let reason = Event.sha256(event.payload) == event.payloadHash
                    ? "envelope hash mismatch"
                    : "payload hash mismatch"
                return .corrupt(firstBad: event.id, reason: reason)
            }
            if event.prevHash != expectedPrev {
                gaps.append(event.id)
            }
            expectedPrev = event.hash
        }
        if gaps.isEmpty {
            return .intact(head: expectedPrev, count: chain.count)
        }
        return .incomplete(gaps: gaps, head: expectedPrev, count: chain.count)
    }
}
