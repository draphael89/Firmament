#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress recording (plan KTD11).
/// Defined in the Kit because both the app (starts the activity — mandatory
/// while an AudioRecordingIntent records) and the widget extension (renders
/// it) need the type.
public struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Recording start, epoch ms — the activity renders a live timer.
        public var startedAtMS: Int64

        public init(startedAtMS: Int64) {
            self.startedAtMS = startedAtMS
        }
    }

    public init() {}
}
#endif
