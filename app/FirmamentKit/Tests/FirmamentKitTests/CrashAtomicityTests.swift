import Darwin
import Foundation
import Testing
@testable import FirmamentKit

/// Exit tests (ST-0008): the child process runs one leg of the capture
/// ordering and SIGKILLs itself at a chosen boundary; the parent reopens the
/// on-disk state and asserts the KTD2 invariants — an interrupted recording
/// survives as an adopted event, and a dangling row never exists. macOS
/// test target only (exit tests cannot spawn on iOS).
@Suite("Crash atomicity", .serialized)
struct CrashAtomicityTests {
    /// Fixed, process-independent workspace per scenario — exit-test bodies
    /// run in a fresh process and cannot capture test state.
    static func workspace(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-crash-\(name)")
    }

    static func freshWorkspace(_ name: String) throws -> URL {
        let url = workspace(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func pipeline(at root: URL) throws -> CapturePipeline {
        let store = try AudioFileStore(root: root.appendingPathComponent("media"))
        let ledgerStore = try LedgerStore.pool(at: root.appendingPathComponent("ledger.sqlite").path)
        let ledger = try Ledger(store: ledgerStore, deviceID: .mac)
        return CapturePipeline(ledger: ledger, audioStore: store)
    }

    static let frames = Data("audio frames flushed before the crash".utf8)

    @Test("kill mid-recording: flushed audio survives as an adopted interrupted capture")
    func killMidRecording() async throws {
        let root = try Self.freshWorkspace("mid-recording")
        await #expect(processExitsWith: .signal(SIGKILL)) {
            let pipeline = try Self.pipeline(at: Self.workspace("mid-recording"))
            let handle = try pipeline.audioStore.beginRecording()
            try pipeline.audioStore.append(Self.frames, to: handle)
            try pipeline.audioStore.flush(handle)
            kill(getpid(), SIGKILL) // dies while recording — no finalize, no event
        }
        let pipeline = try Self.pipeline(at: root)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report.adoptedPartials.count == 1)
        #expect(report.fatalDanglingLocal.isEmpty)
        let adopted = try pipeline.ledger.store.fetchEvent(id: report.adoptedPartials[0])
        let payload = try CaptureAudioPayload(canonical: adopted!.decodedPayload())
        #expect(payload.interrupted)
        #expect(try Data(contentsOf: pipeline.audioStore.fileURL(forHash: payload.fileHash)) == Self.frames)
        guard case .intact = try pipeline.ledger.store.verifyChains()[.mac] else {
            Issue.record("chain not intact after adoption")
            return
        }
    }

    @Test("kill between rename and append: orphan complete file is adopted, never a dangling row")
    func killBeforeAppend() async throws {
        let root = try Self.freshWorkspace("before-append")
        await #expect(processExitsWith: .signal(SIGKILL)) {
            let pipeline = try Self.pipeline(at: Self.workspace("before-append"))
            let handle = try pipeline.audioStore.beginRecording()
            try pipeline.audioStore.append(Self.frames, to: handle)
            _ = try pipeline.audioStore.finalize(handle) // file renamed + dir-fsynced
            kill(getpid(), SIGKILL) // dies before the event row
        }
        let pipeline = try Self.pipeline(at: root)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report.adoptedCompletes.count == 1)
        #expect(report.fatalDanglingLocal.isEmpty)
        #expect(report.adoptedPartials.isEmpty)
        guard case .intact = try pipeline.ledger.store.verifyChains()[.mac] else {
            Issue.record("chain not intact after adoption")
            return
        }
    }

    @Test("kill after full completion: nothing to reconcile, chain verifies")
    func killAfterCompletion() async throws {
        let root = try Self.freshWorkspace("after-complete")
        await #expect(processExitsWith: .signal(SIGKILL)) {
            let pipeline = try Self.pipeline(at: Self.workspace("after-complete"))
            let handle = try pipeline.audioStore.beginRecording()
            try pipeline.audioStore.append(Self.frames, to: handle)
            try await pipeline.completeAudioCapture(handle, durationMS: 1_000)
            kill(getpid(), SIGKILL) // dies after the sacred ordering completed
        }
        let pipeline = try Self.pipeline(at: root)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .mac)
        #expect(report == Reconciler.Report())
        #expect(try pipeline.ledger.store.eventCount() == 1)
        guard case .intact(_, 1) = try pipeline.ledger.store.verifyChains()[.mac] else {
            Issue.record("expected a 1-event intact chain")
            return
        }
    }
}
