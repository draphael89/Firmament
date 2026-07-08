import FirmamentKit
import SwiftUI

@main
struct FirmamentMacApp: App {
    var body: some Scene {
        // Menu-bar presence only (LSUIElement). The capture panel, hotkey,
        // and composer land with U5.
        MenuBarExtra("Firmament", systemImage: "sparkles") {
            Text("Firmament \(FirmamentKit.version)")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
