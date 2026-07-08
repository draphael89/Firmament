import AVFoundation
import FirmamentKit
import Observation

/// Thin AVAudioEngine adapter over the platform-free recorder core (U4):
/// state logic and crash-safety live in FirmamentKit; this class owns the
/// microphone tap, the AVAudioFile writer, periodic durability flushes, and
/// level metering for the panel's waveform.
@MainActor
@Observable
final class MacRecorder {
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

    private var machine = RecorderStateMachine()
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var flushTask: Task<Void, Never>?

    private let pipeline: CapturePipeline
    private let onCaptureComplete: @MainActor () -> Void

    init(pipeline: CapturePipeline, onCaptureComplete: @escaping @MainActor () -> Void = {}) {
        self.pipeline = pipeline
        self.onCaptureComplete = onCaptureComplete
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        let nowMS = UUIDv7Generator.currentMS()
        guard case .beginCapture(let startedAtMS) = machine.start(nowMS: nowMS) else { return }
        do {
            try beginEngine(startedAtMS: startedAtMS)
            status = .recording(startedAtMS: startedAtMS)
        } catch {
            _ = machine.stop()
            status = .failed("microphone unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard case .finalizeCapture(let startedAtMS, let interrupted) = machine.stop() else { return }
        finalize(startedAtMS: startedAtMS, interrupted: interrupted)
    }

    private func beginEngine(startedAtMS: Int64) throws {
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

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Audio-thread callback: write, then hand the level to the UI.
            try? file.write(from: buffer)
            let level = Self.rmsLevel(of: buffer)
            Task { @MainActor [weak self] in
                self?.pushLevel(level)
            }
        }
        try engine.start()

        self.engine = engine
        self.file = file
        self.fileURL = url
        levels = []

        // Periodic durability flush (KTD2): a crash preserves everything up
        // to the last flush; the Reconciler adopts the partial on relaunch.
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
        file = nil // AVAudioFile closes (and completes the CAF header) on release.
        guard let url = fileURL else {
            status = .idle
            return
        }
        fileURL = nil
        let durationMS = UUIDv7Generator.currentMS() - startedAtMS
        status = .idle
        Task {
            do {
                try await pipeline.completeAudioCapture(
                    temporaryFile: url,
                    startedAtMS: startedAtMS,
                    durationMS: durationMS,
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

    private nonisolated static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            sum += data[index] * data[index]
        }
        return min(1, (sum / Float(frames)).squareRoot() * 6)
    }
}
