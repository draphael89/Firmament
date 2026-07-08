import Foundation
import Testing
@testable import FirmamentKit

@Suite("UUIDv7")
struct UUIDv7Tests {
    @Test("version and variant bits are correct")
    func bits() {
        var rng = SplitMix64(seed: 1)
        let generator = UUIDv7Generator()
        for _ in 0..<100 {
            let id = generator.next(nowMS: 1_780_000_000_000, using: &rng)
            #expect(UUIDv7.version(of: id) == 7)
            #expect(UUIDv7.variantBits(of: id) == 0b10)
        }
    }

    @Test("embedded timestamp is recoverable")
    func timestampRecovery() {
        let ts: Int64 = 1_780_000_123_456
        let id = UUIDv7.make(timestampMS: ts, randomA: 0x0ABC, randomB: 0x1234_5678_9ABC_DEF0)
        #expect(UUIDv7.timestampMS(of: id) == ts)
    }

    @Test("10k IDs within one millisecond stay strictly monotonic")
    func monotonicWithinMillisecond() {
        var rng = SplitMix64(seed: 42)
        let generator = UUIDv7Generator()
        var previous: String?
        for _ in 0..<10_000 {
            let id = generator.next(nowMS: 1_780_000_000_000, using: &rng)
            let current = id.uuidString.lowercased()
            if let previous {
                #expect(previous < current, "IDs must be strictly increasing")
            }
            previous = current
        }
    }

    @Test("clock stepping backwards never regresses IDs")
    func clockRollback() {
        var rng = SplitMix64(seed: 7)
        let generator = UUIDv7Generator()
        let a = generator.next(nowMS: 1_780_000_005_000, using: &rng)
        let b = generator.next(nowMS: 1_780_000_001_000, using: &rng) // clock went back
        #expect(a.uuidString.lowercased() < b.uuidString.lowercased())
        #expect(UUIDv7.timestampMS(of: b) >= UUIDv7.timestampMS(of: a))
    }

    @Test("deterministic constructor is stable")
    func deterministic() {
        let a = UUIDv7.make(timestampMS: 1_780_000_000_000, randomA: 1, randomB: 2)
        let b = UUIDv7.make(timestampMS: 1_780_000_000_000, randomA: 1, randomB: 2)
        #expect(a == b)
    }
}
