import Foundation

/// Newline-delimited JSON encoding of events — the export escape hatch
/// (SPEC §5.5) and the golden-fixture format. One canonical-JSON object per
/// line: envelope fields plus the payload embedded as a value. The embedded
/// payload re-serializes through the same canonical serializer that produced
/// the stored bytes, so `payloadHash` must verify on decode — any drift is
/// corruption, loudly.
public enum EventNDJSON {
    public enum CodecError: Error, Equatable {
        case missingField(String)
        case invalidField(String)
        case payloadHashMismatch(UUID)
    }

    public static func encodeLine(_ event: Event) throws -> String {
        let payloadValue = try event.decodedPayload()
        let object: CanonicalValue = .object([
            "author": .string(event.author.canonicalString),
            "device": .string(event.deviceID.rawValue),
            "hash": .string(event.hash.hexEncoded),
            "id": .string(event.id.uuidString.lowercased()),
            "kind": .string(event.kind.rawValue),
            "occurredAt": .int(event.occurredAt),
            "parentID": event.parentID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "payload": payloadValue,
            "payloadHash": .string(event.payloadHash.hexEncoded),
            "prevHash": .string(event.prevHash.hexEncoded),
            "recordedAt": .int(event.recordedAt),
            "tier": .string(event.tier.canonicalString),
        ])
        return String(decoding: try object.serialized(), as: UTF8.self)
    }

    public static func encode(_ events: [Event]) throws -> String {
        try events.map(encodeLine).joined(separator: "\n") + (events.isEmpty ? "" : "\n")
    }

    public static func decodeLine(_ line: String) throws -> Event {
        let value = try CanonicalValue.parse(Data(line.utf8))
        func string(_ key: String) throws -> String {
            guard let s = value[key]?.stringValue else { throw CodecError.missingField(key) }
            return s
        }
        func int(_ key: String) throws -> Int64 {
            guard let i = value[key]?.intValue else { throw CodecError.missingField(key) }
            return i
        }
        guard let id = UUID(uuidString: try string("id").uppercased()) else {
            throw CodecError.invalidField("id")
        }
        guard let kind = EventKind(rawValue: try string("kind")) else {
            throw CodecError.invalidField("kind")
        }
        guard let device = DeviceID(rawValue: try string("device")) else {
            throw CodecError.invalidField("device")
        }
        guard let author = Author(canonicalString: try string("author")) else {
            throw CodecError.invalidField("author")
        }
        guard let tier = Tier(canonicalString: try string("tier")) else {
            throw CodecError.invalidField("tier")
        }
        var parentID: UUID?
        if let parentValue = value["parentID"], parentValue != .null {
            guard let raw = parentValue.stringValue, let parsed = UUID(uuidString: raw.uppercased()) else {
                throw CodecError.invalidField("parentID")
            }
            parentID = parsed
        }
        guard let payloadValue = value["payload"] else { throw CodecError.missingField("payload") }
        guard let payloadHash = Data(hexEncoded: try string("payloadHash")),
              let prevHash = Data(hexEncoded: try string("prevHash")),
              let hash = Data(hexEncoded: try string("hash")) else {
            throw CodecError.invalidField("hashes")
        }
        let payloadBytes = try payloadValue.serialized()
        let event = Event(
            id: id, kind: kind,
            occurredAt: try int("occurredAt"), recordedAt: try int("recordedAt"),
            deviceID: device, author: author, tier: tier, parentID: parentID,
            payload: payloadBytes, payloadHash: payloadHash,
            prevHash: prevHash, hash: hash
        )
        guard Event.sha256(payloadBytes) == payloadHash else {
            throw CodecError.payloadHashMismatch(id)
        }
        return event
    }

    public static func decode(_ ndjson: String) throws -> [Event] {
        try ndjson.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decodeLine(String($0)) }
    }
}
