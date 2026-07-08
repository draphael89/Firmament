import FirmamentKit
import SwiftUI

@main
struct FirmamentMacApp: App {
    @State private var model: AppModel?
    @State private var startupError: String?

    var body: some Scene {
        // Menu-bar presence only (LSUIElement). ⌥Space toggles the capture
        // panel from anywhere in the OS (SPEC §11.2).
        MenuBarExtra("Firmament", systemImage: "sparkles") {
            if let model {
                Button(model.recorder.isRecording ? "Stop Capture" : "Start Capture   ⌥Space") {
                    model.toggleCapturePanel()
                }
                Button("Sync Now") { model.syncNow() }
                Divider()
                if let error = model.lastError {
                    Text(error).font(.caption)
                }
                Text("Firmament \(FirmamentKit.version)")
            } else {
                Text(startupError ?? "starting…")
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        // The composer window (SPEC §9.4) — opened via ⌘N or the menu bar.
        Window("New Note", id: "composer") {
            if let model {
                ComposerView(pipeline: model.pipeline)
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }

    init() {
        do {
            _model = State(initialValue: try AppModel())
        } catch {
            _startupError = State(initialValue: "startup failed: \(error)")
        }
    }
}
