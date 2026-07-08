import Foundation
import Synchronization

/// RFC 9562 UUID version 7 — 48-bit big-endian Unix milliseconds, then
/// version/variant bits, then 74 random bits. Foundation has no v7 yet
/// (SF-0041 was still in review mid-2026); the API mirrors its shape so a
/// later migration is mechanical.
public enum UUIDv7 {
    /// Pure constructor — fully deterministic given its inputs. Used by the
    /// monotonic generator and by fixture builders.
    public static func make(timestampMS: Int64, randomA: UInt16, randomB: UInt64) -> UUID {
        precondition(timestampMS >= 0, "UUIDv7 timestamps are unsigned milliseconds")
        let ts = UInt64(timestampMS) & 0xFFFF_FFFF_FFFF
        var b = [UInt8](repeating: 0, count: 16)
        b[0] = UInt8((ts >> 40) & 0xFF)
        b[1] = UInt8((ts >> 32) & 0xFF)
        b[2] = UInt8((ts >> 24) & 0xFF)
        b[3] = UInt8((ts >> 16) & 0xFF)
        b[4] = UInt8((ts >> 8) & 0xFF)
        b[5] = UInt8(ts & 0xFF)
        b[6] = 0x70 | UInt8((randomA >> 8) & 0x0F)
        b[7] = UInt8(randomA & 0xFF)
        b[8] = 0x80 | UInt8((randomB >> 56) & 0x3F)
        b[9] = UInt8((randomB >> 48) & 0xFF)
        b[10] = UInt8((randomB >> 40) & 0xFF)
        b[11] = UInt8((randomB >> 32) & 0xFF)
        b[12] = UInt8((randomB >> 24) & 0xFF)
        b[13] = UInt8((randomB >> 16) & 0xFF)
        b[14] = UInt8((randomB >> 8) & 0xFF)
        b[15] = UInt8(randomB & 0xFF)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The 48-bit millisecond timestamp embedded in a v7 UUID.
    public static func timestampMS(of uuid: UUID) -> Int64 {
        let u = uuid.uuid
        let ts = (UInt64(u.0) << 40) | (UInt64(u.1) << 32) | (UInt64(u.2) << 24)
            | (UInt64(u.3) << 16) | (UInt64(u.4) << 8) | UInt64(u.5)
        return Int64(ts)
    }

    public static func version(of uuid: UUID) -> Int {
        Int(uuid.uuid.6 >> 4)
    }

    public static func variantBits(of uuid: UUID) -> UInt8 {
        uuid.uuid.8 >> 6
    }
}

/// Process-wide monotonic v7 generator. Within one millisecond, `rand_a`
/// acts as a 12-bit counter so IDs stay strictly ordered; on counter
/// overflow (or a clock step backwards) the timestamp is nudged forward.
public final class UUIDv7Generator: Sendable {
    private struct State {
        var lastMS: Int64 = 0
        var lastRandA: UInt16 = 0
        var primed = false
    }

    private let state = Mutex(State())

    public static let shared = UUIDv7Generator()

    public init() {}

    public func next(nowMS: Int64 = UUIDv7Generator.currentMS()) -> UUID {
        var rng = SystemRandomNumberGenerator()
        return next(nowMS: nowMS, using: &rng)
    }

    public func next(nowMS: Int64, using rng: inout some RandomNumberGenerator) -> UUID {
        let randomB = rng.next() & 0x3FFF_FFFF_FFFF_FFFF
        let freshA = UInt16(truncatingIfNeeded: rng.next()) & 0x0FFF
        let (ms, randA): (Int64, UInt16) = state.withLock { s in
            var ms = max(nowMS, s.lastMS)
            var randA = freshA
            if s.primed && ms == s.lastMS {
                if s.lastRandA >= 0x0FFF {
                    ms += 1
                } else {
                    randA = s.lastRandA + 1
                }
            }
            s.lastMS = ms
            s.lastRandA = randA
            s.primed = true
            return (ms, randA)
        }
        return UUIDv7.make(timestampMS: ms, randomA: randA, randomB: randomB)
    }

    public static func currentMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

extension UUID {
    /// Firmament's event-ID constructor (SPEC §5.1).
    public static func firmamentV7() -> UUID {
        UUIDv7Generator.shared.next()
    }
}
