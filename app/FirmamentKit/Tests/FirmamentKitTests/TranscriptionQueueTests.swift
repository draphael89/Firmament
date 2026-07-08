import Foundation
import Testing
@testable import FirmamentKit

@Suite("Transcription queue")
struct TranscriptionQueueTests {
    final class MockASR: ASRProviding, @unchecked Sendable {
        let modelIdentity = "mock:test-v1"
        var failHashes: Set<String> = []
        var transcribedURLs: [URL] = []

        struct MockFailure: Error {}

        func transcribe(audioAt url: URL) async throws -> ASRResult {
            transcribedURLs.append(url)
            let hash = url.deletingPathExtension().lastPathComponent
            if failHashes.contains(hash) { throw MockFailure() }
            return ASRResult(
                text: "transcribed \(hash.prefix(8))",
                segments: [.init(startMS: 0, endMS: 1000, text: "transcribed")]
            )
        }
    }

    struct Fixture {
        let pipeline: CapturePipeline
        let asr: MockASR
        let queue: TranscriptionQueue
        let root: URL

        func addAudioCapture(_ bytes: String) async throws -> Event {
            let handle = try pipeline.audioStore.beginRecording()
            try pipeline.audioStore.append(Data(bytes.utf8), to: handle)
            return try await pipeline.completeAudioCapture(handle, durationMS: 1000)
        }
    }

    private func makeFixture(maxAttempts: Int = 3) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-tq-\(UUID().uuidString)")
        let audioStore = try AudioFileStore(root: root)
        let ledger = try Ledger(store: LedgerStore.inMemory(), deviceID: .mac)
        let asr = MockASR()
        let queue = TranscriptionQueue(
            ledger: ledger, audioStore: audioStore, asr: asr, maxAttempts: maxAttempts)
        return Fixture(
            pipeline: CapturePipeline(ledger: ledger, audioStore: audioStore),
            asr: asr, queue: queue, root: root)
    }

    @Test("launch scan transcribes pending local captures with correct stamps")
    func launchScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let capture = try await fixture.addAudioCapture("hello")
        let appended = try await fixture.queue.processPending()

        #expect(appended.count == 1)
        let transcript = appended[0]
        #expect(transcript.parentID == capture.id)
        #expect(transcript.kind == .transcript)
        #expect(transcript.author == .system)
        #expect(transcript.tier == capture.tier)
        let payload = try TranscriptPayload(canonical: transcript.decodedPayload())
        #expect(payload.asrModel == "mock:test-v1")
    }

    @Test("already-transcribed captures are skipped")
    func skipsTranscribed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.addAudioCapture("one")
        #expect(try await fixture.queue.processPending().count == 1)
        #expect(try await fixture.queue.processPending().isEmpty)
        #expect(fixture.asr.transcribedURLs.count == 1)
    }

    @Test("foreign captures are never queued (deviceID scope, sync race)")
    func foreignScope() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // A phone capture whose audio asset already arrived, but whose
        // transcript record hasn't yet — the Mac must NOT transcribe it.
        let handle = try fixture.pipeline.audioStore.beginRecording()
        try fixture.pipeline.audioStore.append(Data("phone audio".utf8), to: handle)
        let (hash, _, _) = try fixture.pipeline.audioStore.finalize(handle)
        let draft = Event.Draft(
            kind: .captureAudio, occurredAt: 1, recordedAt: 1,
            deviceID: .phone, author: .human, tier: .personal,
            payload: CaptureAudioPayload(fileHash: hash, durationMS: 500).canonical
        )
        let foreign = try Event.seal(draft, prevHash: HashChain.genesis(for: .phone))
        try await fixture.pipeline.ledger.ingest(foreign)

        #expect(try await fixture.queue.processPending().isEmpty)
        #expect(fixture.asr.transcribedURLs.isEmpty)
    }

    @Test("failure retries then parks; newer captures still process")
    func failureParking() async throws {
        let fixture = try makeFixture(maxAttempts: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bad = try await fixture.addAudioCapture("corrupt")
        let badPayload = try CaptureAudioPayload(canonical: bad.decodedPayload())
        fixture.asr.failHashes = [badPayload.fileHash]
        _ = try await fixture.addAudioCapture("good")

        // Attempt 1: bad fails, good transcribes.
        let first = try await fixture.queue.processPending()
        #expect(first.count == 1)
        // Attempt 2: bad fails again and parks.
        #expect(try await fixture.queue.processPending().isEmpty)
        let parked = await fixture.queue.parkedFailures
        #expect(parked.map(\.captureID) == [bad.id])
        #expect(parked[0].attempts == 2)
        // Parked captures are not retried.
        _ = try await fixture.queue.processPending()
        #expect(fixture.asr.transcribedURLs.filter { $0.path.contains(badPayload.fileHash) }.count == 2)
    }

    @Test("capture whose file is missing is not offered to ASR")
    func missingFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.pipeline.ledger.append(
            kind: .captureAudio, occurredAt: 1, author: .human,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "c", count: 64), durationMS: 100).canonical
        )
        #expect(try await fixture.queue.processPending().isEmpty)
        #expect(fixture.asr.transcribedURLs.isEmpty)
    }
}
