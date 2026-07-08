import Foundation
import Testing
@testable import FirmamentKit

@Suite("Golden Ledger")
struct GoldenLedgerTests {
    @Test("checked-in fixture matches the deterministic generator byte-for-byte")
    func fixtureMatchesGenerator() throws {
        let events = try GoldenLedger.build()
        let ndjson = try EventNDJSON.encode(events)
        let url = GoldenLedger.fixtureURL

        if ProcessInfo.processInfo.environment["REGENERATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ndjson.utf8).write(to: url)
        }

        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == ndjson, "golden fixture drift — encoder or generator changed; review like a migration")
    }

    @Test("both device chains verify intact over the fixture")
    func chainsVerify() throws {
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        let events = try EventNDJSON.decode(ndjson)
        #expect(events.count > 150)
        for device in DeviceID.allCases {
            guard case .intact = HashChain.verify(events, deviceID: device) else {
                Issue.record("chain for \(device) not intact")
                return
            }
        }
    }

    @Test("NDJSON decode → encode is byte-identical (encoder-drift tripwire)")
    func ndjsonRoundTrip() throws {
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        let events = try EventNDJSON.decode(ndjson)
        let reEncoded = try EventNDJSON.encode(events)
        #expect(reEncoded == ndjson)
    }

    @Test("fixture exercises tiers, kinds, and out-of-order arrival")
    func fixtureCoverage() throws {
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        let events = try EventNDJSON.decode(ndjson)
        let tiers = Set(events.map(\.tier))
        #expect(tiers.contains(.open) && tiers.contains(.personal) && tiers.contains(.sanctum))
        let kinds = Set(events.map(\.kind))
        #expect(kinds.isSuperset(of: [.captureAudio, .captureText, .transcript, .tombstone, .syncCheckpoint]))
        // Arrival order differs from timeline order (adversarial shuffle).
        let ids = events.map { $0.id.uuidString.lowercased() }
        #expect(ids != ids.sorted())
    }

    @Test("M0 payload kinds round-trip through their typed structs")
    func typedPayloadRoundTrip() throws {
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        let events = try EventNDJSON.decode(ndjson)
        for event in events {
            let value = try event.decodedPayload()
            switch event.kind {
            case .captureAudio:
                let payload = try CaptureAudioPayload(canonical: value)
                #expect(try payload.canonical.serialized() == event.payload)
            case .captureText:
                let payload = try CaptureTextPayload(canonical: value)
                #expect(try payload.canonical.serialized() == event.payload)
            case .transcript:
                let payload = try TranscriptPayload(canonical: value)
                #expect(try payload.canonical.serialized() == event.payload)
            case .tombstone:
                let payload = try TombstonePayload(canonical: value)
                #expect(try payload.canonical.serialized() == event.payload)
            case .syncCheckpoint:
                let payload = try SyncCheckpointPayload(canonical: value)
                #expect(try payload.canonical.serialized() == event.payload)
            default:
                Issue.record("fixture contains a kind M0 does not produce: \(event.kind)")
            }
        }
    }
}
