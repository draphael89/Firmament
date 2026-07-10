import AppKit
import SwiftUI

@main
struct FirmamentApp: App {
    @State private var model = VaultModel()

    init() {
        // SPM executables launch without a bundle; claim a regular app role.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Firmament") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.violet)
                .task { model.startPolling() }
        }
        .windowStyle(.automatic)
    }
}

enum Theme {
    /// Carried from Glia's visual language: midnight field, violet accent.
    static let violet = Color(red: 0.58, green: 0.49, blue: 0.96)
    static let field = Color(red: 0.048, green: 0.055, blue: 0.10)
    static let panel = Color(red: 0.075, green: 0.085, blue: 0.15)
    static let faint = Color.white.opacity(0.45)
}
