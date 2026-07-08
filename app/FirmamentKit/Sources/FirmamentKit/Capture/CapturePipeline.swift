import Foundation

/// The capture front door (SPEC §9.2): file first, envelope second, both
/// fsynced. Platform adapters (U5 Mac shell, U10 phone) feed frames in and
/// call the completion paths; nothing here touches AVFoundation.
public struct CapturePipeline: Sendable {
    public let ledger: Ledger
    public let audioStore: AudioFileStore

    public init(ledger: Ledger, audioStore: AudioFileStore) {
        self.ledger = ledger
        self.audioStore = audioStore
    }

    /// Text capture: append-only, no sidecar. M0 surfaces stamp `.personal`
    /// by default; the Sanctum gesture is deferred until its app-level
    /// encryption ships (plan Scope Boundaries).
    @discardableResult
    public func captureText(
        body: String,
        sourcePlane: SourcePlane,
        origin: String? = nil,
        tier: Tier = .personal,
        occurredAt: Int64 = UUIDv7Generator.currentMS()
    ) async throws -> Event {
        try await ledger.append(
            kind: .captureText,
            occurredAt: occurredAt,
            author: .human,
            tier: tier,
            payload: CaptureTextPayload(body: body, sourcePlane: sourcePlane, origin: origin).canonical
        )
    }

    /// Audio capture completion — the sacred ordering's second half. The
    /// handle's bytes are finalized (full-fsync → rename → dir-fsync)
    /// *before* the event row is appended; a crash between the two leaves an
    /// orphan file the Reconciler adopts, never a dangling row.
    @discardableResult
    public func completeAudioCapture(
        _ handle: AudioFileStore.RecordingHandle,
        durationMS: Int64,
        context: [String: String] = [:],
        tier: Tier = .personal,
        interrupted: Bool = false
    ) async throws -> Event {
        let (fileHash, _, _) = try audioStore.finalize(handle)
        return try await ledger.append(
            kind: .captureAudio,
            occurredAt: handle.startedAtMS,
            author: .human,
            tier: tier,
            payload: CaptureAudioPayload(
                fileHash: fileHash,
                durationMS: durationMS,
                context: context,
                interrupted: interrupted
            ).canonical
        )
    }
}
