import FirmamentKit
import SwiftUI

@main
struct FirmamentPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let model = PhoneModel.shared {
                CaptureView(model: model)
                    .onChange(of: scenePhase) { _, phase in
                        // Foreground time is when the phone gets to talk to
                        // CloudKit; flush whatever the Ledger says is unsent.
                        if phase == .active { model.syncNow() }
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Firmament could not open its ledger.")
                        .font(.footnote)
                }
            }
        }
    }
}

/// One screen deep (SPEC §12): waveform, elapsed, stop. Tier defaults
/// `.personal`; the Sanctum gesture ships with its encryption milestone.
struct CaptureView: View {
    let model: PhoneModel

    @State private var elapsed = "0:00"

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            WaveformView(levels: model.recorder.levels)
                .frame(height: 60)
                .padding(.horizontal, 32)
            Text(model.recorder.isRecording ? elapsed : "ready")
                .font(.system(.largeTitle, design: .monospaced))
                .foregroundStyle(model.recorder.isRecording ? .primary : .tertiary)
            Spacer()
            Button {
                model.toggleCapture()
            } label: {
                Image(systemName: model.recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .frame(width: 88, height: 88)
                    .background(model.recorder.isRecording ? Color.red.opacity(0.85) : Color.accentColor,
                                in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            if case .failed(let message) = model.recorder.status {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let error = model.lastError {
                Text(error).font(.caption2).foregroundStyle(.tertiary)
            }
            Text("personal · Action Button captures from anywhere")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .task {
            while !Task.isCancelled {
                if case .recording(let startedAtMS) = model.recorder.status {
                    let seconds = max(0, (UUIDv7Generator.currentMS() - startedAtMS) / 1000)
                    elapsed = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary.opacity(0.7))
                    .frame(width: 4, height: max(4, CGFloat(level) * 60))
            }
            if levels.isEmpty {
                Rectangle().fill(.clear).frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
