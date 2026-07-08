import SwiftUI
import WidgetKit

@main
struct FirmamentWidgets: WidgetBundle {
    var body: some Widget {
        LockScreenCaptureWidget()
        RecordingLiveActivity()
    }
}

struct LockScreenCaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FirmamentCapture", provider: CaptureProvider()) { _ in
            Image(systemName: "mic.fill")
        }
        .configurationDisplayName("Capture")
        .description("Start a Firmament voice capture.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct CaptureProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
