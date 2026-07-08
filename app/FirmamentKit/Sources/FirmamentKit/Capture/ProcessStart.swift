import Foundation

/// Wall-clock time this process was spawned, in epoch milliseconds.
///
/// The Action Button (KTD11) launches the app to service the intent, so a
/// capture's `startLatencyMS` — measured from `RecorderStateMachine.start()`,
/// which runs inside `perform()` — excludes the dominant term: process spawn,
/// App Intents resolution, and composition-root construction. SPEC §9.2
/// budgets *press-to-first-sample*, and "missing the first two seconds of a
/// thought is a product-killing bug".
///
/// The press precedes the spawn, so this is the earliest anchor observable
/// from inside the process, and `firstBuffer - epochMS` is therefore a lower
/// bound on the true press-to-first-sample cost of a cold launch.
public enum ProcessStart {
    /// Read once via `swift_once`; the value cannot change during the process.
    public static let epochMS: Int64 = readStartTimeMS()

    private static func readStartTimeMS() -> Int64 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            // Losing the anchor must never lose the capture: report a zero-age
            // process rather than a negative or wildly skewed measurement.
            return UUIDv7Generator.currentMS()
        }
        let started = info.kp_proc.p_starttime
        return Int64(started.tv_sec) * 1000 + Int64(started.tv_usec) / 1000
    }
}
