import AppKit
import SwiftUI

/// The floating glass capture panel (SPEC §9.2, plan KTD10): Spotlight-like
/// — non-activating (never steals the frontmost app's focus), joins every
/// Space, floats above fullscreen apps.
final class CapturePanel: NSPanel {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        contentView = NSHostingView(rootView: content)
    }

    // Text input inside a nonactivating panel requires key status.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = frame.size
            setFrameOrigin(NSPoint(
                x: frame.origin.x + (size.width - self.frame.width) / 2,
                y: frame.origin.y + size.height * 0.72))
        }
        orderFrontRegardless()
        makeKey()
    }
}

/// Panel anatomy (SPEC §9.2 minus the deferred Sanctum gesture): waveform,
/// elapsed, stop. The walk is for thinking — nothing else on screen.
struct CapturePanelView: View {
    let recorder: MacRecorder
    let onDismiss: () -> Void

    @State private var elapsed = "0:00"

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                WaveformView(levels: recorder.levels)
                    .frame(height: 36)
                Text(elapsed)
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                if case .failed(let message) = recorder.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("personal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(recorder.isRecording ? "Stop" : "Close") {
                    if recorder.isRecording {
                        recorder.stop()
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .task {
            while !Task.isCancelled {
                if case .recording(let startedAtMS) = recorder.status {
                    let seconds = max(0, (FirmamentKitClock.nowMS() - startedAtMS) / 1000)
                    elapsed = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private enum FirmamentKitClock {
    static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.primary.opacity(0.7))
                    .frame(width: 3, height: max(3, CGFloat(level) * 36))
            }
            if levels.isEmpty {
                Rectangle().fill(.clear).frame(width: 3, height: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}
