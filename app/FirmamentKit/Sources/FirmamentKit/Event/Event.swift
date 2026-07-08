import CryptoKit
import Foundation

/// The event envelope (SPEC §5.1, amended by A7). The hash covers the
/// canonical envelope, with the payload represented inside it by its
/// SHA-256 digest — so crypto-shredding a payload later removes the bytes
/// while the envelope chain still verifies. Payload bytes are stored
/// verbatim; verification re-hashes stored bytes, never a re-serialization.
public struct Event: Sendable, Equatable, Identifiable {
    public let id: UUID                 // UUIDv7 — time-ordered
    public let kind: EventKind
    public let occurredAt: Int64        // event time (world), epoch ms
    public let recordedAt: Int64        // system time (device append), epoch ms
    public let deviceID: DeviceID
    public let author: Author
    public let tier: Tier
    public let parentID: UUID?
    public let payload: Data            // canonical JSON bytes, verbatim
    public let payloadHash: Data        // SHA256(payload)
    public let prevHash: Data           // previous event on THIS device's chain
    public let hash: Data               // SHA256(canonical envelope)

    public struct Draft: Sendable {
        public var id: UUID
        public var kind: EventKind
        public var occurredAt: Int64
        public var recordedAt: Int64
        public var deviceID: DeviceID
        public var author: Author
        public var tier: Tier
        public var parentID: UUID?
        public var payload: CanonicalValue

        public init(
            id: UUID = .firmamentV7(),
            kind: EventKind,
            occurredAt: Int64,
            recordedAt: Int64,
            deviceID: DeviceID,
            author: Author,
            tier: Tier = .personal,
            parentID: UUID? = nil,
            payload: CanonicalValue
        ) {
            self.id = id
            self.kind = kind
            self.occurredAt = occurredAt
            self.recordedAt = recordedAt
            self.deviceID = deviceID
            self.author = author
            self.tier = tier
            self.parentID = parentID
            self.payload = payload
        }
    }

    /// Seal a draft onto a chain: serialize the payload, digest it, and
    /// hash the canonical envelope with `prevHash` linking the device chain.
    public static func seal(_ draft: Draft, prevHash: Data) throws -> Event {
        let payloadBytes = try draft.payload.serialized()
        return try seal(draft, payloadBytes: payloadBytes, prevHash: prevHash)
    }

    /// Seal with pre-serialized payload bytes (sync ingest re-seals nothing —
    /// this path exists for fixture and test construction).
    public static func seal(_ draft: Draft, payloadBytes: Data, prevHash: Data) throws -> Event {
        let payloadHash = sha256(payloadBytes)
        let envelope = canonicalEnvelope(
            id: draft.id, kind: draft.kind, occurredAt: draft.occurredAt,
            recordedAt: draft.recordedAt, deviceID: draft.deviceID,
            author: draft.author, tier: draft.tier, parentID: draft.parentID,
            payloadHash: payloadHash, prevHash: prevHash
        )
        let hash = sha256(try envelope.serialized())
        return Event(
            id: draft.id, kind: draft.kind, occurredAt: draft.occurredAt,
            recordedAt: draft.recordedAt, deviceID: draft.deviceID,
            author: draft.author, tier: draft.tier, parentID: draft.parentID,
            payload: payloadBytes, payloadHash: payloadHash,
            prevHash: prevHash, hash: hash
        )
    }

    /// Reconstruct an event from stored/synced fields, verbatim. No hashes
    /// are recomputed here — integrity is checked separately so tampering
    /// is detected rather than masked.
    public init(
        id: UUID, kind: EventKind, occurredAt: Int64, recordedAt: Int64,
        deviceID: DeviceID, author: Author, tier: Tier, parentID: UUID?,
        payload: Data, payloadHash: Data, prevHash: Data, hash: Data
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.deviceID = deviceID
        self.author = author
        self.tier = tier
        self.parentID = parentID
        self.payload = payload
        self.payloadHash = payloadHash
        self.prevHash = prevHash
        self.hash = hash
    }

    /// Self-integrity: stored bytes hash to `payloadHash`, and the canonical
    /// envelope hashes to `hash`. Chain linkage is verified separately.
    public func verifySelfIntegrity() -> Bool {
        guard Event.sha256(payload) == payloadHash else { return false }
        let envelope = Event.canonicalEnvelope(
            id: id, kind: kind, occurredAt: occurredAt, recordedAt: recordedAt,
            deviceID: deviceID, author: author, tier: tier, parentID: parentID,
            payloadHash: payloadHash, prevHash: prevHash
        )
        guard let bytes = try? envelope.serialized() else { return false }
        return Event.sha256(bytes) == hash
    }

    /// The A7 hash preimage. Field set and encodings are permanent chain
    /// format — never change without a spec amendment and chain migration.
    static func canonicalEnvelope(
        id: UUID, kind: EventKind, occurredAt: Int64, recordedAt: Int64,
        deviceID: DeviceID, author: Author, tier: Tier, parentID: UUID?,
        payloadHash: Data, prevHash: Data
    ) -> CanonicalValue {
        .object([
            "author": .string(author.canonicalString),
            "device": .string(deviceID.rawValue),
            "id": .string(id.uuidString.lowercased()),
            "kind": .string(kind.rawValue),
            "occurredAt": .int(occurredAt),
            "parentID": parentID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "payloadHash": .string(payloadHash.hexEncoded),
            "prevHash": .string(prevHash.hexEncoded),
            "recordedAt": .int(recordedAt),
            "tier": .string(tier.canonicalString),
        ])
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Decode the payload bytes back into the canonical value model.
    public func decodedPayload() throws -> CanonicalValue {
        try CanonicalValue.parse(payload)
    }
}

extension Data {
    public var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
