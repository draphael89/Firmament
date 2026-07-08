import AppKit
import FirmamentKit
import Observation
import SwiftUI

/// Composition root for the Mac app (SPEC §11.7 actors, M0 subset):
/// Ledger + capture pipeline + Vault fold + transcription queue + sync,
/// wired at launch with reconciliation first.
@MainActor
@Observable
final class AppModel {
    let pipeline: CapturePipeline
    let folder: Folder
    let transcriptionQueue: TranscriptionQueue
    let syncEngine: SyncEngine
    private(set) var recorder: MacRecorder!
    private(set) var lastError: String?

    private var hotKey: HotKey?
    private var panel: CapturePanel?

    init() throws {
        let supportDir = FirmamentPaths.applicationSupport()
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let store = try LedgerStore.pool(at: FirmamentPaths.defaultLedger().path)
        let ledger = try Ledger(store: store, deviceID: .mac)
        let audioStore = try AudioFileStore(root: supportDir.appendingPathComponent("media"))
        let pipeline = CapturePipeline(ledger: ledger, audioStore: audioStore)
        let vault = try VaultLens(root: FirmamentPaths.defaultVault())
        let folder = try Folder(store: store, lenses: [vault])
        let queue = TranscriptionQueue(
            ledger: ledger,
            audioStore: audioStore,
            asr: WhisperKitASR(modelName: ASRModelPins.macASRModel))
        let stateStore = try SyncStateStore(
            directory: supportDir.appendingPathComponent("sync"), ledgerStore: store)
        let syncEngine = SyncEngine(
            ledger: ledger, audioStore: audioStore, stateStore: stateStore, folder: folder)

        self.pipeline = pipeline
        self.folder = folder
        self.transcriptionQueue = queue
        self.syncEngine = syncEngine
        self.recorder = MacRecorder(pipeline: pipeline) { [weak self] in
            self?.captureLanded()
        }

        self.hotKey = HotKey { [weak self] in
            self?.toggleCapturePanel()
        }

        Task { await self.launchSequence() }
    }

    /// Launch order (plan U4/U6/U7): adopt crash survivors, fold, transcribe
    /// anything pending, then start sync (best-effort — entitlements may be
    /// absent in development builds).
    private func launchSequence() async {
        do {
            let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
            if !report.fatalDanglingLocal.isEmpty {
                lastError = "integrity: \(report.fatalDanglingLocal.count) event(s) missing audio files"
            }
            try await folder.foldPending()
            _ = try await transcriptionQueue.processPending()
            try await folder.foldPending()
            try await CheckpointClerk.emitIfDue(ledger: pipeline.ledger)
        } catch {
            lastError = "launch: \(error)"
        }
        do {
            try await syncEngine.start()
        } catch {
            // Sync is best-effort at launch; capture never depends on it.
            lastError = "sync unavailable: \(error.localizedDescription)"
        }
    }

    func toggleCapturePanel() {
        if recorder.isRecording {
            recorder.stop()
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            panel = CapturePanel(content: CapturePanelView(recorder: recorder) { [weak self] in
                self?.panel?.orderOut(nil)
            })
        }
        recorder.start()
        panel?.show()
    }

    private func captureLanded() {
        Task {
            _ = try? await transcriptionQueue.processPending()
            try? await folder.foldPending()
            try? await syncEngine.enqueueUnsent()
        }
    }
}
