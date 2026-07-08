import Foundation
import Testing
@testable import FirmamentKit

/// Real-model integration (plan U6, tagged slow): downloads the pinned
/// phone-class model on first run (~150 MB) — gated behind
/// FIRMAMENT_SLOW_TESTS=1 so the CI fast tier never pays for it.
@Suite("WhisperKit integration",
       .enabled(if: ProcessInfo.processInfo.environment["FIRMAMENT_SLOW_TESTS"] == "1"))
struct WhisperKitIntegrationTests {
    @Test("a spoken sample transcribes to text containing an expected word")
    func realTranscription() async throws {
        // Synthesize a deterministic 3-second sample.
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-asr-sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "the ledger holds the sky"]
        try say.run()
        say.waitUntilExit()
        #expect(say.terminationStatus == 0)

        let asr = WhisperKitASR(modelName: ASRModelPins.phoneASRModel)
        let result = try await asr.transcribe(audioAt: wav)
        #expect(result.text.lowercased().contains("ledger") || result.text.lowercased().contains("sky"),
                "unexpected transcription: \(result.text)")
        #expect(!result.segments.isEmpty)
    }
}
