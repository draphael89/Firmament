import Foundation

/// The ASR seam (SPEC §9.3, plan KTD9): WhisperKit at M0, SpeechAnalyzer as
/// a later fallback conforming to the same protocol. Batch file
/// transcription only — no streaming in M0.
public protocol ASRProviding: Sendable {
    /// Pinned model identity stamped into every transcript event,
    /// e.g. "whisperkit:openai_whisper-large-v3-v20240930_626MB".
    var modelIdentity: String { get }

    func transcribe(audioAt url: URL) async throws -> ASRResult
}

public struct ASRResult: Sendable, Equatable {
    public var text: String
    public var segments: [TranscriptPayload.Segment]

    public init(text: String, segments: [TranscriptPayload.Segment]) {
        self.text = text
        self.segments = segments
    }
}

/// Exact date-versioned model pins (plan KTD9): per-device, may share a
/// value when hardware allows. Changing a pin is a deliberate, visible act —
/// transcripts stamp the identity per event, and re-transcription of old
/// audio is a versioned act on retained originals (SPEC §9.3).
public enum ASRModelPins {
    /// Mac: large-class, quality-first (SPEC §7.1 fill guidance).
    public static let macASRModel = "openai_whisper-large-v3-v20240930_626MB"
    /// iPhone: validated for memory/latency in the U1 spike before Phase B
    /// hardening; base-class until the spike says otherwise.
    public static let phoneASRModel = "openai_whisper-base"

    public static func model(for deviceID: DeviceID) -> String {
        switch deviceID {
        case .mac: macASRModel
        case .phone: phoneASRModel
        }
    }
}
