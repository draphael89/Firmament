import Foundation
import Testing
@testable import FirmamentKit

@Suite("HashChain")
struct HashChainTests {
    private func makeChain(device: DeviceID, count: Int, seed: UInt64) throws -> [Event] {
        var rng = SplitMix64(seed: seed)
        let generator = UUIDv7Generator()
        var prev = HashChain.genesis(for: device)
        var events = [Event]()
        var ts: Int64 = 1_780_000_000_000
        for index in 0..<count {
            ts += Int64(rng.next() % 60_000)
            let draft = Event.Draft(
                id: generator.next(nowMS: ts, using: &rng),
                kind: .captureText,
                occurredAt: ts - Int64(rng.next() % 10_000),
                recordedAt: ts,
                deviceID: device,
                author: .human,
                tier: .personal,
                payload: CaptureTextPayload(body: "note \(index)", sourcePlane: .composer).canonical
            )
            let event = try Event.seal(draft, prevHash: prev)
            prev = event.hash
            events.append(event)
        }
        return events
    }

    @Test("genesis differs per device")
    func genesis() {
        #expect(HashChain.genesis(for: .mac) != HashChain.genesis(for: .phone))
        #expect(HashChain.genesis(for: .mac).count == 32)
    }

    @Test("a sealed chain verifies intact")
    func intact() throws {
        let events = try makeChain(device: .mac, count: 25, seed: 1)
        guard case .intact(let head, let count) = HashChain.verify(events, deviceID: .mac) else {
            Issue.record("expected intact chain")
            return
        }
        #expect(count == 25)
        #expect(head == events.last?.hash)
    }

    @Test("altering a stored payload byte is corrupt at exactly that event")
    func tamperedPayload() throws {
        var events = try makeChain(device: .mac, count: 10, seed: 2)
        let victim = events[4]
        var bytes = Data(victim.payload)
        bytes[bytes.count / 2] ^= 0xFF
        events[4] = Event(
            id: victim.id, kind: victim.kind, occurredAt: victim.occurredAt,
            recordedAt: victim.recordedAt, deviceID: victim.deviceID,
            author: victim.author, tier: victim.tier, parentID: victim.parentID,
            payload: bytes, payloadHash: victim.payloadHash,
            prevHash: victim.prevHash, hash: victim.hash
        )
        guard case .corrupt(let firstBad, let reason) = HashChain.verify(events, deviceID: .mac) else {
            Issue.record("expected corrupt chain")
            return
        }
        #expect(firstBad == victim.id)
        #expect(reason == "payload hash mismatch")
    }

    @Test("altering an envelope field is corrupt (envelope hash mismatch)")
    func tamperedEnvelope() throws {
        var events = try makeChain(device: .mac, count: 10, seed: 3)
        let victim = events[6]
        events[6] = Event(
            id: victim.id, kind: victim.kind, occurredAt: victim.occurredAt + 1,
            recordedAt: victim.recordedAt, deviceID: victim.deviceID,
            author: victim.author, tier: victim.tier, parentID: victim.parentID,
            payload: victim.payload, payloadHash: victim.payloadHash,
            prevHash: victim.prevHash, hash: victim.hash
        )
        guard case .corrupt(let firstBad, let reason) = HashChain.verify(events, deviceID: .mac) else {
            Issue.record("expected corrupt chain")
            return
        }
        #expect(firstBad == victim.id)
        #expect(reason == "envelope hash mismatch")
    }

    @Test("two interleaved device chains verify independently")
    func twoDevices() throws {
        let mac = try makeChain(device: .mac, count: 15, seed: 4)
        let phone = try makeChain(device: .phone, count: 12, seed: 5)
        var mixed = mac + phone
        var rng = SplitMix64(seed: 6)
        mixed.shuffle(using: &rng)
        guard case .intact(_, let macCount) = HashChain.verify(mixed, deviceID: .mac),
              case .intact(_, let phoneCount) = HashChain.verify(mixed, deviceID: .phone) else {
            Issue.record("expected both chains intact")
            return
        }
        #expect(macCount == 15)
        #expect(phoneCount == 12)
    }

    @Test("a missing middle event reports incomplete, never corrupt")
    func gap() throws {
        var events = try makeChain(device: .mac, count: 10, seed: 7)
        let removed = events.remove(at: 5)
        guard case .incomplete(let gaps, _, let count) = HashChain.verify(events, deviceID: .mac) else {
            Issue.record("expected incomplete chain")
            return
        }
        #expect(count == 9)
        #expect(gaps.count == 1)
        #expect(gaps.first != removed.id)
    }

    @Test("empty device chain reports empty")
    func empty() {
        #expect(HashChain.verify([], deviceID: .phone) == .empty)
    }
}
