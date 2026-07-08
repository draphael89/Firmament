#if os(iOS)
import ActivityKit
import FirmamentKit
import Observation
import UIKit

/// Composition root for the satellite (SPEC §12): capture, on-device
/// transcription, sync. No Vault fold — the phone never materializes
/// Lenses (SPEC §5.5). Shared so the Action Button intent and the UI drive
/// one recorder.
@MainActor
@Observable
final class PhoneModel {
    static let shared = try? PhoneModel()

    let pipeline: CapturePipeline
    let transcriptionQueue: TranscriptionQueue
    let syncEngine: SyncEngine
    private(set) var recorder: PhoneRecorder!
    private(set) var lastError: String?

    private var activity: Activity<RecordingActivityAttributes>?

    init() throws {
        FirmamentPaths.migrateLegacyGroupRootIfNeeded()
        let container = FirmamentPaths.sharedContainer()
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let store = try LedgerStore.pool(at: container.appendingPathComponent("ledger.sqlite").path)
        let ledger = try Ledger(store: store, deviceID: .phone)
        let audioStore = try AudioFileStore(root: container.appendingPathComponent("media"))
        let pipeline = CapturePipeline(ledger: ledger, audioStore: audioStore)
        let queue = TranscriptionQueue(
            ledger: ledger,
            audioStore: audioStore,
            asr: WhisperKitASR(modelName: ASRModelPins.phoneASRModel))
        let stateStore = try SyncStateStore(
            directory: container.appendingPathComponent("sync"), ledgerStore: store)

        self.pipeline = pipeline
        self.transcriptionQueue = queue
        self.syncEngine = SyncEngine(ledger: ledger, audioStore: audioStore, stateStore: stateStore)
        self.recorder = PhoneRecorder(pipeline: pipeline) { [weak self] in
            self?.captureLanded()
        }

        // CloudKit delivers server-change pushes as remote notifications;
        // CKSyncEngine consumes them internally once the app is registered.
        UIApplication.shared.registerForRemoteNotifications()

        Task { await launchSequence() }
    }

    /// Foreground nudge: flush anything the Ledger says is unsent and pull
    /// whatever the other device wrote (SPEC §5.5 — sync is transport, the
    /// Ledger is truth).
    func syncNow() {
        Task {
            do {
                try await syncEngine.syncNow()
                lastError = try await syncEngine.status()
            } catch {
                lastError = "sync: \(error.localizedDescription)"
            }
        }
    }

    private func launchSequence() async {
        do {
            _ = try await Reconciler().run(pipeline: pipeline, deviceID: .phone)
            _ = try await transcriptionQueue.processPending()
            try await CheckpointClerk.emitIfDue(ledger: pipeline.ledger)
        } catch {
            lastError = "launch: \(error)"
        }
        do {
            try await syncEngine.start()
        } catch {
            lastError = "sync unavailable: \(error.localizedDescription)"
        }
    }

    /// The Action Button entry (KTD11): toggles capture; the Live Activity
    /// is mandatory while an AudioRecordingIntent records and doubles as the
    /// status surface.
    func toggleCapture() {
        if recorder.isRecording {
            recorder.stop()
            endLiveActivity()
        } else {
            recorder.start()
            if case .recording(let startedAtMS) = recorder.status {
                startLiveActivity(startedAtMS: startedAtMS)
            }
        }
    }

    private func startLiveActivity(startedAtMS: Int64) {
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(),
            content: .init(
                state: RecordingActivityAttributes.ContentState(startedAtMS: startedAtMS),
                staleDate: nil))
    }

    private func endLiveActivity() {
        guard let activity else { return }
        self.activity = nil
        // Activity is not Sendable in this SDK; ownership is handed to one
        // detached task and never touched again.
        nonisolated(unsafe) let ended = activity
        Task.detached {
            await ended.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func captureLanded() {
        Task {
            // Airplane mode is indistinguishable from online at capture time
            // (SPEC §9.2): transcription is local; sync queues until
            // connectivity returns.
            _ = try? await transcriptionQueue.processPending()
            try? await syncEngine.enqueueUnsent()
        }
    }
}
#endif
