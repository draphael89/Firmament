#if os(iOS)
import AVFoundation
import FirmamentKit
import Observation

/// Thin AVAudioSession/engine adapter over the platform-free recorder core.
/// Interruptions (phone call, route loss) finalize the partial through the
/// same path — saved, never lost (U4).
@MainActor
@Observable
final class PhoneRecorder {
    enum Status: Equatable {
        case idle
        case recording(startedAtMS: Int64)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var levels: [Float] = []
    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }

    /// Set by the Action Button intent so the capture records which entry
    /// path it came through — the two have different warm-up costs.
    var launchedFromIntent = false

    /// True when the intent found no `PhoneModel` yet, i.e. iOS spawned the
    /// process to serve this press. The exact cold/warm signal for KTD11 —
    /// far better than inferring it from process age.
    var coldLaunch = false

    private var machine = RecorderStateMachine()
    private var engine: AVAudioEngine?
    private var tapWriter: AudioTapWriter?
    private var fileURL: URL?
    private var flushTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private let pipeline: CapturePipeline
    private let onCaptureComplete: @MainActor () -> Void

    init(pipeline: CapturePipeline, onCaptureComplete: @escaping @MainActor () -> Void = {}) {
        self.pipeline = pipeline
        self.onCaptureComplete = onCaptureComplete
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleInterruption()
            }
        }
    }

    /// `nowMS` is injected so the caller can stamp the capture's start *before*
    /// it raises the Live Activity, which must exist before the audio session
    /// goes active on the Action Button path.
    func start(nowMS: Int64 = UUIDv7Generator.currentMS()) {
        guard case .beginCapture(let startedAtMS) = machine.start(nowMS: nowMS) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            try beginEngine()
            status = .recording(startedAtMS: startedAtMS)
        } catch {
            _ = machine.stop()
            // The domain/code separates "no background grant" (AVAudioSession
            // !int / !rec) from a permission or hardware failure — the message
            // alone reads the same for all three.
            let ns = error as NSError
            status = .failed("microphone unavailable: \(error.localizedDescription) [\(ns.domain) \(ns.code)]")
        }
    }

    func stop() {
        guard case .finalizeCapture(let startedAtMS, let interrupted) = machine.stop() else { return }
        finalize(startedAtMS: startedAtMS, interrupted: interrupted)
    }

    private func handleInterruption() {
        guard case .finalizeCapture(let startedAtMS, _) = machine.interruption() else { return }
        finalize(startedAtMS: startedAtMS, interrupted: true)
    }

    private func beginEngine() throws {
        let url = pipeline.audioStore.reserveTemporaryPath()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false)

        // The tap runs on CoreAudio's realtime queue — it must carry no
        // actor isolation (the executor assertion crash). AudioTapWriter is
        // nonisolated; levels hop to the main actor explicitly.
        let writer = AudioTapWriter(file: file) { [weak self] level in
            Task { @MainActor [weak self] in
                self?.pushLevel(level)
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: writer.handle)
        try engine.start()
        self.engine = engine
        self.tapWriter = writer
        self.fileURL = url
        levels = []

        flushTask = Task { [pipeline, url] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                try? pipeline.audioStore.flush(path: url)
            }
        }
    }

    private func finalize(startedAtMS: Int64, interrupted: Bool) {
        flushTask?.cancel()
        flushTask = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // The gap from button-press to first sample is KTD11's gate (SPEC §9.2).
        let firstBufferAtMS = tapWriter?.firstBufferAtMS
        tapWriter = nil // Releases the AVAudioFile → closes and completes the CAF header.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = fileURL else {
            status = .idle
            return
        }
        fileURL = nil
        let durationMS = UUIDv7Generator.currentMS() - startedAtMS
        var context = ["source": launchedFromIntent ? "actionButton" : "app"]
        if let firstBufferAtMS {
            context["startLatencyMS"] = String(max(0, firstBufferAtMS - startedAtMS))
        }
        // Cold Action Button presses spend most of their budget before
        // `start()` ever runs (spawn, intent resolution, PhoneModel init).
        // Record the two halves separately rather than a classified total —
        // facts on the hot path, judgment at read time (Tenet 8).
        context["processAgeAtStartMS"] = String(max(0, startedAtMS - ProcessStart.epochMS))
        if launchedFromIntent {
            context["coldLaunch"] = coldLaunch ? "true" : "false"
        }
        launchedFromIntent = false
        coldLaunch = false
        status = .idle
        Task {
            do {
                try await pipeline.completeAudioCapture(
                    temporaryFile: url,
                    startedAtMS: startedAtMS,
                    durationMS: durationMS,
                    context: context,
                    interrupted: interrupted)
                await MainActor.run { self.onCaptureComplete() }
            } catch {
                await MainActor.run { self.status = .failed("capture failed: \(error)") }
            }
        }
    }

    private func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > 48 {
            levels.removeFirst(levels.count - 48)
        }
    }
}
#endif
