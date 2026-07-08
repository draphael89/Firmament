import Foundation
import WhisperKit

/// WhisperKit-backed ASR (SPEC §9.3). The model loads lazily on first use
/// (download is lazy with UI affordance at the app layer); the pin is exact
/// and date-versioned so transcripts are reproducible.
public actor WhisperKitASR: ASRProviding {
    private let modelName: String
    private var kit: WhisperKit?

    public nonisolated let modelIdentity: String

    public init(modelName: String) {
        self.modelName = modelName
        self.modelIdentity = "whisperkit:\(modelName)"
    }

    public func transcribe(audioAt url: URL) async throws -> ASRResult {
        let kit = try await loadedKit()
        let results = try await kit.transcribe(audioPath: url.path)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = [TranscriptPayload.Segment]()
        for result in results {
            for segment in result.segments {
                segments.append(TranscriptPayload.Segment(
                    startMS: Int64((segment.start * 1000).rounded()),
                    endMS: Int64((segment.end * 1000).rounded()),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        return ASRResult(text: text, segments: segments)
    }

    private func loadedKit() async throws -> WhisperKit {
        if let kit { return kit }
        let config = WhisperKitConfig(model: modelName)
        let loaded = try await WhisperKit(config)
        kit = loaded
        return loaded
    }
}
