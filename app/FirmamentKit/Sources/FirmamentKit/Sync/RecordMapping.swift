import CloudKit
import Foundation

/// Event ↔ CKRecord mapping (plan KTD7). The record carries the complete
/// envelope — including `payloadHash`, `prevHash`, and `hash`, stored
/// verbatim on ingest so a device can verify a foreign chain entirely from
/// synced records (recomputing hashes would mask tampering). Canonical
/// payload bytes ride `encryptedValues`; oversized payloads spill
/// transport-side to a CKAsset and are re-hashed against `payloadHash` on
/// ingest. Records are immutable: never modified, never deleted.
public enum RecordMapping {
    public static let recordType = "LedgerEvent"
    public static let zoneName = "Events"

    /// Conservative cap under CloudKit's ~1 MB record limit.
    public static let payloadSpillThreshold = 600_000

    public enum Field {
        static let kind = "kind"
        static let occurredAt = "occurredAt"
        static let recordedAt = "recordedAt"
        static let device = "device"
        static let author = "author"
        static let tier = "tier"
        static let parentID = "parentID"
        static let payload = "payload"
        static let payloadHash = "payloadHash"
        static let prevHash = "prevHash"
        static let hash = "hash"
        /// Transport-side spill for oversized payload bytes.
        static let payloadAsset = "payloadAsset"
        /// The capture's audio file (encrypted by default as an asset).
        static let audio = "audio"
    }

    public enum MappingError: Error, Equatable {
        case missingField(String)
        case invalidField(String)
        case payloadHashMismatch(UUID)
        case notAnEventRecord(String)
    }

    public static func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func recordID(for eventID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "event:\(eventID.uuidString.lowercased())", zoneID: zoneID())
    }

    public static func eventID(from recordID: CKRecord.ID) -> UUID? {
        guard recordID.recordName.hasPrefix("event:") else { return nil }
        return UUID(uuidString: String(recordID.recordName.dropFirst("event:".count)).uppercased())
    }

    /// Build the outgoing record. `audioFileURL` attaches the capture's
    /// audio asset (the caller gates upload on the asset being staged —
    /// see `UploadGate`). `spillDirectory` receives temp files for
    /// oversized payload bytes.
    public static func record(
        for event: Event,
        audioFileURL: URL? = nil,
        spillDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(for: event.id))
        record.encryptedValues[Field.kind] = event.kind.rawValue
        record.encryptedValues[Field.occurredAt] = event.occurredAt
        record.encryptedValues[Field.recordedAt] = event.recordedAt
        record.encryptedValues[Field.device] = event.deviceID.rawValue
        record.encryptedValues[Field.author] = event.author.canonicalString
        record.encryptedValues[Field.tier] = event.tier.rawValue
        if let parentID = event.parentID {
            record.encryptedValues[Field.parentID] = parentID.uuidString.lowercased()
        }
        record.encryptedValues[Field.payloadHash] = event.payloadHash
        record.encryptedValues[Field.prevHash] = event.prevHash
        record.encryptedValues[Field.hash] = event.hash

        if event.payload.count > payloadSpillThreshold {
            let spill = spillDirectory.appendingPathComponent("spill-\(event.id.uuidString.lowercased()).bin")
            try event.payload.write(to: spill, options: .atomic)
            record[Field.payloadAsset] = CKAsset(fileURL: spill)
        } else {
            record.encryptedValues[Field.payload] = event.payload
        }

        if let audioFileURL {
            record[Field.audio] = CKAsset(fileURL: audioFileURL)
        }
        return record
    }

    /// Decode an incoming record verbatim, verifying the payload bytes
    /// against the envelope's `payloadHash` (transport spill included).
    /// Returns the audio asset's local temp URL when present — the caller
    /// must copy it out before the delegate callback returns.
    public static func event(from record: CKRecord) throws -> (event: Event, audioAssetURL: URL?) {
        guard record.recordType == recordType, let id = eventID(from: record.recordID) else {
            throw MappingError.notAnEventRecord(record.recordID.recordName)
        }
        func string(_ field: String) throws -> String {
            guard let value = record.encryptedValues[field] as? String else {
                throw MappingError.missingField(field)
            }
            return value
        }
        func int(_ field: String) throws -> Int64 {
            guard let value = record.encryptedValues[field] as? Int64 else {
                throw MappingError.missingField(field)
            }
            return value
        }
        func data(_ field: String) throws -> Data {
            guard let value = record.encryptedValues[field] as? Data else {
                throw MappingError.missingField(field)
            }
            return value
        }
        guard let kind = EventKind(rawValue: try string(Field.kind)) else {
            throw MappingError.invalidField(Field.kind)
        }
        guard let device = DeviceID(rawValue: try string(Field.device)) else {
            throw MappingError.invalidField(Field.device)
        }
        guard let author = Author(canonicalString: try string(Field.author)) else {
            throw MappingError.invalidField(Field.author)
        }
        guard let tierRaw = record.encryptedValues[Field.tier] as? Int64,
              let tier = Tier(rawValue: Int(tierRaw)) else {
            throw MappingError.invalidField(Field.tier)
        }
        var parentID: UUID?
        if let raw = record.encryptedValues[Field.parentID] as? String {
            guard let parsed = UUID(uuidString: raw.uppercased()) else {
                throw MappingError.invalidField(Field.parentID)
            }
            parentID = parsed
        }

        let payload: Data
        if let direct = record.encryptedValues[Field.payload] as? Data {
            payload = direct
        } else if let asset = record[Field.payloadAsset] as? CKAsset, let url = asset.fileURL {
            payload = try Data(contentsOf: url)
        } else {
            throw MappingError.missingField(Field.payload)
        }

        let event = Event(
            id: id, kind: kind,
            occurredAt: try int(Field.occurredAt), recordedAt: try int(Field.recordedAt),
            deviceID: device, author: author, tier: tier, parentID: parentID,
            payload: payload,
            payloadHash: try data(Field.payloadHash),
            prevHash: try data(Field.prevHash),
            hash: try data(Field.hash)
        )
        guard Event.sha256(payload) == event.payloadHash else {
            throw MappingError.payloadHashMismatch(id)
        }
        let audioURL = (record[Field.audio] as? CKAsset)?.fileURL
        return (event, audioURL)
    }
}

/// Upload gating (KTD7): a `capture.audio` record uploads only once its
/// asset is staged — transcript/text records go first, preserving SPEC
/// §5.5's asset-lag allowance without ever modifying a record.
public enum UploadGate {
    public static func isReadyToUpload(_ event: Event, audioStore: AudioFileStore) -> Bool {
        guard event.kind == .captureAudio else { return true }
        guard let payload = try? CaptureAudioPayload(canonical: event.decodedPayload()) else {
            return false
        }
        return audioStore.fileExists(hash: payload.fileHash)
    }

    /// The staged audio URL for a ready capture.audio event.
    public static func audioFileURL(for event: Event, audioStore: AudioFileStore) -> URL? {
        guard event.kind == .captureAudio,
              let payload = try? CaptureAudioPayload(canonical: event.decodedPayload()),
              audioStore.fileExists(hash: payload.fileHash) else { return nil }
        return audioStore.fileURL(forHash: payload.fileHash)
    }
}

/// serverRecordChanged policy (KTD7): expected on redundant re-uploads of
/// immutable records. Identical content → adopt the server's system fields
/// and drop the pending save; differing content → loud integrity alarm,
/// never an overwrite.
public enum ConflictPolicy {
    public enum Resolution: Equatable, Sendable {
        case adoptServer
        case integrityAlarm(eventID: UUID)
    }

    public static func resolveServerRecordChanged(local: Event, server: Event) -> Resolution {
        if local.id == server.id,
           local.payload == server.payload,
           local.hash == server.hash,
           local.prevHash == server.prevHash {
            return .adoptServer
        }
        return .integrityAlarm(eventID: local.id)
    }
}
