import ActivityKit
import FirmamentKit
import SwiftUI
import WidgetKit

/// The mandatory recording Live Activity (KTD11): status + live timer while
/// an AudioRecordingIntent records. Stopping happens via the Action Button
/// toggle or the app; the activity is display-only at M0.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                Text("Recording")
                    .font(.headline)
                Spacer()
                Text(startDate(context.state), style: .timer)
                    .font(.title3.monospacedDigit())
                    .frame(maxWidth: 64, alignment: .trailing)
            }
            .padding(14)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Recording").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(startDate(context.state), style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 56, alignment: .trailing)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.red)
            } compactTrailing: {
                Text(startDate(context.state), style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.red)
            }
        }
    }

    private func startDate(_ state: RecordingActivityAttributes.ContentState) -> Date {
        Date(timeIntervalSince1970: Double(state.startedAtMS) / 1000)
    }
}
