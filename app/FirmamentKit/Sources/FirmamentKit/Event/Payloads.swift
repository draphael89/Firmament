import Foundation

/// Typed payloads exist only for the kinds M0 produces; the remaining kinds
/// carry opaque canonical values until their milestone's planning pass
/// freezes their schemas (plan U2). Payload schema evolution is weak-schema:
/// readers tolerate absent optional fields.
public protocol CanonicalRepresentable: Sendable {
    init(canonical: CanonicalValue) throws
    var canonical: CanonicalValue { get }
}

public enum PayloadError: Error, Equatable {
    case missingField(String)
    case invalidField(String)
}

// MARK: capture.audio

public struct CaptureAudioPayload: CanonicalRepresentable, Equatable {
    /// SHA-256 hex of the audio file — the file's content address.
    public var fileHash: String
    public var durationMS: Int64
    /// Free-form capture context (motion, weather, …). String values only.
    public var context: [String: String]
    /// Set when launch reconciliation adopted a partial recording (KTD2).
    public var interrupted: Bool

    public init(fileHash: String, durationMS: Int64, context: [String: String] = [:], interrupted: Bool = false) {
        self.fileHash = fileHash
        self.durationMS = durationMS
        self.context = context
        self.interrupted = interrupted
    }

    public init(canonical: CanonicalValue) throws {
        guard let fileHash = canonical["fileHash"]?.stringValue else {
            throw PayloadError.missingField("fileHash")
        }
        guard let durationMS = canonical["durationMS"]?.intValue else {
            throw PayloadError.missingField("durationMS")
        }
        self.fileHash = fileHash
        self.durationMS = durationMS
        var context = [String: String]()
        if let object = canonical["context"]?.objectValue {
            for (key, value) in object {
                guard let string = value.stringValue else { throw PayloadError.invalidField("context.\(key)") }
                context[key] = string
            }
        }
        self.context = context
        self.interrupted = canonical["interrupted"]?.boolValue ?? false
    }

    public var canonical: CanonicalValue {
        var object: [String: CanonicalValue] = [
            "durationMS": .int(durationMS),
            "fileHash": .string(fileHash),
        ]
        if !context.isEmpty {
            object["context"] = .object(context.mapValues { .string($0) })
        }
        if interrupted {
            object["interrupted"] = .bool(true)
        }
        return .object(object)
    }
}

// MARK: capture.text

public enum SourcePlane: String, Sendable, CaseIterable {
    case composer
    case shareSheet
    case clipboard
    case fileDrop
}

public struct CaptureTextPayload: CanonicalRepresentable, Equatable {
    public var body: String
    public var sourcePlane: SourcePlane
    public var origin: String?

    public init(body: String, sourcePlane: SourcePlane, origin: String? = nil) {
        self.body = body
        self.sourcePlane = sourcePlane
        self.origin = origin
    }

    public init(canonical: CanonicalValue) throws {
        guard let body = canonical["body"]?.stringValue else {
            throw PayloadError.missingField("body")
        }
        guard let planeRaw = canonical["sourcePlane"]?.stringValue,
              let plane = SourcePlane(rawValue: planeRaw) else {
            throw PayloadError.missingField("sourcePlane")
        }
        self.body = body
        self.sourcePlane = plane
        self.origin = canonical["origin"]?.stringValue
    }

    public var canonical: CanonicalValue {
        var object: [String: CanonicalValue] = [
            "body": .string(body),
            "sourcePlane": .string(sourcePlane.rawValue),
        ]
        if let origin {
            object["origin"] = .string(origin)
        }
        return .object(object)
    }
}

// MARK: transcript

public struct TranscriptPayload: CanonicalRepresentable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var startMS: Int64
        public var endMS: Int64
        public var text: String

        public init(startMS: Int64, endMS: Int64, text: String) {
            self.startMS = startMS
            self.endMS = endMS
            self.text = text
        }
    }

    /// Verbatim ASR output — the raw words are evidence (SPEC §9.3).
    public var text: String
    public var segments: [Segment]
    /// Pinned model identity, e.g. "whisperkit:large-v3-v20240930_626MB".
    public var asrModel: String
    /// Lexicon version, when the M2 lexicon loop exists. Absent at M0.
    public var lexicon: String?

    public init(text: String, segments: [Segment], asrModel: String, lexicon: String? = nil) {
        self.text = text
        self.segments = segments
        self.asrModel = asrModel
        self.lexicon = lexicon
    }

    public init(canonical: CanonicalValue) throws {
        guard let text = canonical["text"]?.stringValue else {
            throw PayloadError.missingField("text")
        }
        guard let asrModel = canonical["asrModel"]?.stringValue else {
            throw PayloadError.missingField("asrModel")
        }
        self.text = text
        self.asrModel = asrModel
        self.lexicon = canonical["lexicon"]?.stringValue
        var segments = [Segment]()
        if let array = canonical["segments"]?.arrayValue {
            for item in array {
                guard let start = item["startMS"]?.intValue,
                      let end = item["endMS"]?.intValue,
                      let segText = item["text"]?.stringValue else {
                    throw PayloadError.invalidField("segments")
                }
                segments.append(Segment(startMS: start, endMS: end, text: segText))
            }
        }
        self.segments = segments
    }

    public var canonical: CanonicalValue {
        var object: [String: CanonicalValue] = [
            "asrModel": .string(asrModel),
            "text": .string(text),
        ]
        if !segments.isEmpty {
            object["segments"] = .array(segments.map {
                .object(["endMS": .int($0.endMS), "startMS": .int($0.startMS), "text": .string($0.text)])
            })
        }
        if let lexicon {
            object["lexicon"] = .string(lexicon)
        }
        return .object(object)
    }
}

// MARK: tombstone

public struct TombstonePayload: CanonicalRepresentable, Equatable {
    public var targets: [UUID]
    public var reason: String

    public init(targets: [UUID], reason: String) {
        self.targets = targets
        self.reason = reason
    }

    public init(canonical: CanonicalValue) throws {
        guard let array = canonical["targets"]?.arrayValue else {
            throw PayloadError.missingField("targets")
        }
        var targets = [UUID]()
        for item in array {
            guard let raw = item.stringValue, let uuid = UUID(uuidString: raw.uppercased()) else {
                throw PayloadError.invalidField("targets")
            }
            targets.append(uuid)
        }
        guard let reason = canonical["reason"]?.stringValue else {
            throw PayloadError.missingField("reason")
        }
        self.targets = targets
        self.reason = reason
    }

    public var canonical: CanonicalValue {
        .object([
            "reason": .string(reason),
            "targets": .array(targets.map { .string($0.uuidString.lowercased()) }),
        ])
    }
}

// MARK: sync.checkpoint

public struct SyncCheckpointPayload: CanonicalRepresentable, Equatable {
    /// The device chain's head hash at checkpoint time, hex.
    public var chainHead: String
    /// Events on this device's chain at checkpoint time.
    public var eventCount: Int64
    /// Day stamp under the pinned Firmament timezone (plan U7/U12).
    public var day: String

    public init(chainHead: String, eventCount: Int64, day: String) {
        self.chainHead = chainHead
        self.eventCount = eventCount
        self.day = day
    }

    public init(canonical: CanonicalValue) throws {
        guard let chainHead = canonical["chainHead"]?.stringValue else {
            throw PayloadError.missingField("chainHead")
        }
        guard let eventCount = canonical["eventCount"]?.intValue else {
            throw PayloadError.missingField("eventCount")
        }
        guard let day = canonical["day"]?.stringValue else {
            throw PayloadError.missingField("day")
        }
        self.chainHead = chainHead
        self.eventCount = eventCount
        self.day = day
    }

    public var canonical: CanonicalValue {
        .object([
            "chainHead": .string(chainHead),
            "day": .string(day),
            "eventCount": .int(eventCount),
        ])
    }
}
