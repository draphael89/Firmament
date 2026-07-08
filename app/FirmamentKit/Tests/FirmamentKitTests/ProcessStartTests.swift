import Foundation
import Testing

@testable import FirmamentKit

/// `ProcessStart` is the press-anchor for the KTD11 cold-start measurement
/// (SPEC §9.2). Its contract is narrow: a stable, real, already-past epoch-ms
/// timestamp. If it ever returned "now", the cold-start term would silently
/// read as zero and the Action Button would look free.
@Suite("ProcessStart")
struct ProcessStartTests {
    @Test("reads a real spawn time, not the current instant")
    func spawnTimePrecedesNow() {
        let spawn = ProcessStart.epochMS
        let now = UUIDv7Generator.currentMS()

        #expect(spawn > 0)
        #expect(spawn <= now)
        // The test process has done real work (loading, discovery) before
        // reaching here, so a genuine sysctl read is measurably in the past.
        // A silent fallback to `currentMS()` would land within a millisecond.
        #expect(now - spawn >= 1, "spawn time collapsed onto now — sysctl likely failed")
        // Sanity: the process is not older than a day.
        #expect(now - spawn < 86_400_000)
    }

    @Test("is stable across reads")
    func stableAcrossReads() {
        #expect(ProcessStart.epochMS == ProcessStart.epochMS)
    }

    @Test("process age at capture start is non-negative and bounds cold start")
    func processAgeIsNonNegative() {
        // The arithmetic PhoneRecorder performs when stamping the context.
        let startedAtMS = UUIDv7Generator.currentMS()
        let processAge = startedAtMS - ProcessStart.epochMS
        #expect(processAge >= 0)
    }
}
