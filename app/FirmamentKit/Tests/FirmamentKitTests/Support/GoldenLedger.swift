import Foundation
@testable import FirmamentKit

/// Deterministic golden-Ledger builder (plan U2): ~200 events across both
/// device chains, out-of-order arrival, tombstones, all three tiers.
/// The checked-in NDJSON is the byte-stable fixture every determinism test
/// (chain verification here; Vault folds in U7) asserts against — any
/// change to these bytes is reviewed like a migration (SPEC §16).
enum GoldenLedger {
    static let seed: UInt64 = 0xF1A_A5CE_D001
    static let baseTimestampMS: Int64 = 1_780_000_000_000

    static let words = [
        "sky", "ledger", "vault", "walk", "dog", "signal", "sanctum",
        "graph", "star", "morning", "dream", "capture", "atlas", "gate",
        "penn", "skan", "onyx", "pepper", "multiplier", "alberta",
    ]

    /// Events in *arrival order* (deterministically shuffled — adversarial
    /// ordering for folds and verification, which must sort per chain).
    static func build() throws -> [Event] {
        var rng = SplitMix64(seed: seed)
        let generator = UUIDv7Generator()
        var heads: [DeviceID: Data] = [
            .mac: HashChain.genesis(for: .mac),
            .phone: HashChain.genesis(for: .phone),
        ]
        var clock = baseTimestampMS
        var events = [Event]()
        var audioAwaitingTranscript = [(id: UUID, device: DeviceID, ts: Int64)]()

        func sentence(_ rng: inout SplitMix64, count: Int) -> String {
            (0..<count).map { _ in words[Int(rng.next() % UInt64(words.count))] }
                .joined(separator: " ")
        }

        func tier(_ rng: inout SplitMix64) -> Tier {
            switch rng.next() % 10 {
            case 0: .open
            case 1: .sanctum
            default: .personal
            }
        }

        func append(_ draft: Event.Draft) throws {
            var draft = draft
            draft.id = generator.next(nowMS: draft.recordedAt, using: &rng)
            let event = try Event.seal(draft, prevHash: heads[draft.deviceID]!)
            heads[draft.deviceID] = event.hash
            events.append(event)
        }

        for index in 0..<180 {
            clock += Int64(30_000 + rng.next() % 3_600_000)
            let device: DeviceID = rng.next() % 3 == 0 ? .phone : .mac
            let occurred = clock - Int64(rng.next() % 600_000) // offline lag
            switch rng.next() % 5 {
            case 0: // voice capture + transcript pair
                let audioTS = occurred
                let payload = CaptureAudioPayload(
                    fileHash: String(format: "%064x", rng.next()),
                    durationMS: Int64(5_000 + rng.next() % 120_000),
                    context: index % 4 == 0 ? ["motion": "walking"] : [:]
                )
                let draft = Event.Draft(
                    kind: .captureAudio, occurredAt: audioTS, recordedAt: clock,
                    deviceID: device, author: .human, tier: tier(&rng),
                    payload: payload.canonical
                )
                try append(draft)
                audioAwaitingTranscript.append((events.last!.id, device, clock))
            case 1 where !audioAwaitingTranscript.isEmpty: // transcript for pending audio
                let pending = audioAwaitingTranscript.removeFirst()
                let text = sentence(&rng, count: 12)
                let payload = TranscriptPayload(
                    text: text,
                    segments: [.init(startMS: 0, endMS: 4_000, text: text)],
                    asrModel: "whisperkit:golden-fixture-v1"
                )
                let parent = events.first { $0.id == pending.id }!
                let draft = Event.Draft(
                    kind: .transcript, occurredAt: pending.ts, recordedAt: clock,
                    deviceID: pending.device, author: .system, tier: parent.tier,
                    parentID: pending.id, payload: payload.canonical
                )
                try append(draft)
            case 2 where index > 20 && index % 37 == 0: // occasional tombstone
                let target = events[Int(rng.next() % UInt64(events.count))]
                let payload = TombstonePayload(targets: [target.id], reason: "golden tombstone")
                let draft = Event.Draft(
                    kind: .tombstone, occurredAt: clock, recordedAt: clock,
                    deviceID: device, author: .human, tier: .personal,
                    payload: payload.canonical
                )
                try append(draft)
            default: // text capture
                let planes = SourcePlane.allCases
                let payload = CaptureTextPayload(
                    body: sentence(&rng, count: 3 + Int(rng.next() % 20)) + " é\u{0301}dge",
                    sourcePlane: planes[Int(rng.next() % UInt64(planes.count))]
                )
                let draft = Event.Draft(
                    kind: .captureText, occurredAt: occurred, recordedAt: clock,
                    deviceID: device, author: .human, tier: tier(&rng),
                    payload: payload.canonical
                )
                try append(draft)
            }
        }

        // Daily checkpoints close each chain.
        for device in DeviceID.allCases {
            let payload = SyncCheckpointPayload(
                chainHead: heads[device]!.hexEncoded,
                eventCount: Int64(events.filter { $0.deviceID == device }.count),
                day: "2026-05-29"
            )
            clock += 1_000
            try append(Event.Draft(
                kind: .syncCheckpoint, occurredAt: clock, recordedAt: clock,
                deviceID: device, author: .system, tier: .open,
                payload: payload.canonical
            ))
        }

        // Adversarial arrival order: deterministic shuffle.
        var shuffleRNG = SplitMix64(seed: seed ^ 0xDEAD)
        events.shuffle(using: &shuffleRNG)
        return events
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support/
            .deletingLastPathComponent()  // FirmamentKitTests/
            .appendingPathComponent("Fixtures/golden-ledger.ndjson")
    }
}
