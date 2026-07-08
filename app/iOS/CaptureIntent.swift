#if os(iOS)
import AppIntents
import FirmamentKit

/// The Action Button front door (SPEC §9.2, KTD11): recording starts before
/// any UI exists. `AudioRecordingIntent` (iOS 18+) records without
/// foregrounding the app, on the condition that a Live Activity runs while
/// recording — PhoneModel starts one. Pressing the Action Button again
/// toggles stop.
///
/// The U1 latency spike (operator-assisted, physical device) measures
/// press-to-first-sample on this path; if it misses the budget the fallback
/// is a persistent warm audio session (plan Risks).
struct ToggleCaptureIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Firmament Capture"
    static let description = IntentDescription("Start or stop a Firmament voice capture.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = PhoneModel.shared else {
            throw CaptureIntentError.notReady
        }
        model.toggleCapture(fromIntent: true)
        return .result()
    }
}

enum CaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        "Firmament could not open its ledger."
    }
}

struct FirmamentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleCaptureIntent(),
            phrases: ["Capture a thought in \(.applicationName)"],
            shortTitle: "Capture",
            systemImageName: "mic.fill")
    }
}
#endif
