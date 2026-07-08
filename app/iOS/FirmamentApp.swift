import FirmamentKit
import SwiftUI

@main
struct FirmamentPhoneApp: App {
    var body: some Scene {
        // Capture screen, intent wiring, and transcription land with U10.
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Firmament \(FirmamentKit.version)")
                    .font(.footnote.monospaced())
            }
        }
    }
}
