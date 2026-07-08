import Foundation

/// Recoverable-async transcription (plan KTD9): any *local-device*
/// `capture.audio` without a child `transcript` re-queues on launch scan;
/// foreign captures arrive with their own transcripts by sync and are never
/// queued (a sync race must not mint duplicates). Failures retry with
/// backoff and never block newer captures; a capture that keeps failing is
/// parked and reported.
public actor TranscriptionQueue {
    public struct FailureRecord: Sendable, Equatable {
        public var captureID: UUID
        public var attempts: Int
        public var lastError: String
    }

    private let ledger: Ledger
    private let audioStore: AudioFileStore
    private let asr: any ASRProviding
    private let maxAttempts: Int

    private var attempts = [UUID: Int]()
    private var parked = [UUID: FailureRecord]()
    private var processing = false

    public init(
        ledger: Ledger,
        audioStore: AudioFileStore,
        asr: any ASRProviding,
        maxAttempts: Int = 3
    ) {
        self.ledger = ledger
        self.audioStore = audioStore
        self.asr = asr
        self.maxAttempts = maxAttempts
    }

    public var parkedFailures: [FailureRecord] {
        Array(parked.values)
    }

    /// Launch scan + notification entry point: find local untranscribed
    /// captures and process them serially. Reentrancy-safe.
    public func processPending() async throws -> [Event] {
        guard !processing else { return [] }
        processing = true
        defer { processing = false }

        var appended = [Event]()
        for capture in try pendingCaptures() {
            guard let payload = try? CaptureAudioPayload(canonical: capture.decodedPayload()) else { continue }
            let url = audioStore.fileURL(forHash: payload.fileHash)
            do {
                let result = try await asr.transcribe(audioAt: url)
                let transcript = try await ledger.append(
                    kind: .transcript,
                    occurredAt: capture.occurredAt,
                    author: .system,
                    tier: capture.tier,
                    parentID: capture.id,
                    payload: TranscriptPayload(
                        text: result.text,
                        segments: result.segments,
                        asrModel: asr.modelIdentity
                    ).canonical
                )
                appended.append(transcript)
                attempts[capture.id] = nil
            } catch {
                let count = (attempts[capture.id] ?? 0) + 1
                attempts[capture.id] = count
                if count >= maxAttempts {
                    parked[capture.id] = FailureRecord(
                        captureID: capture.id, attempts: count,
                        lastError: String(describing: error))
                }
                // Continue with newer captures — one bad file never blocks
                // the queue.
                continue
            }
        }
        return appended
    }

    /// Local-device `capture.audio` events with no child transcript, whose
    /// audio file is present, excluding parked failures. Timeline order.
    private func pendingCaptures() throws -> [Event] {
        let events = try ledger.store.fetchAll()
        let transcribed = Set(events.filter { $0.kind == .transcript }.compactMap(\.parentID))
        return events.filter { event in
            event.kind == .captureAudio
                && event.deviceID == ledger.deviceID
                && !transcribed.contains(event.id)
                && parked[event.id] == nil
                && fileExists(for: event)
        }
    }

    private func fileExists(for event: Event) -> Bool {
        guard let payload = try? CaptureAudioPayload(canonical: event.decodedPayload()) else { return false }
        return audioStore.fileExists(hash: payload.fileHash)
    }
}
