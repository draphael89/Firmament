import Foundation

/// The pinned Firmament timezone (plan U7/U12): day bucketing for the Vault
/// and the daily sync checkpoint never consults the host timezone — R3's
/// byte-for-byte rebuild must not depend on where the machine happens to be.
/// Changing this constant is a Vault Lens version bump + refold.
public enum FirmamentTime {
    public static let dayBucketTimeZoneID = "America/New_York"

    public static let dayBucketTimeZone = TimeZone(identifier: dayBucketTimeZoneID)!

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayBucketTimeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// "YYYY-MM-DD" under the pinned timezone.
    public static func dayString(epochMS: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMS) / 1000)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// "HH:mm" under the pinned timezone — Vault section headers.
    public static func timeString(epochMS: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMS) / 1000)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }
}
