import Foundation
import Testing

@testable import FirmamentKit

/// A partial on disk is ambiguous: it is either a crashed process's orphan
/// (adopt it — never lose a thought) or *this* process's live recording
/// (leave it alone — the recorder still holds the fd).
///
/// The Action Button path makes the second case reachable. `PhoneModel.init()`
/// enqueues `launchSequence()`, then `perform()` starts the recorder before
/// the MainActor frees. Reconciliation therefore runs *during* the recording
/// it was never meant to see.
@Suite("Live recording vs. reconciliation")
struct LiveRecordingAdoptionTests {
    private func makePipeline() throws -> (CapturePipeline, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-live-\(UUID().uuidString)")
        let store = try AudioFileStore(root: root)
        let ledger = try Ledger(store: LedgerStore.inMemory(), deviceID: .phone)
        return (CapturePipeline(ledger: ledger, audioStore: store), root)
    }

    @Test("reconciliation during a live recording neither adopts nor moves the partial")
    func liveRecordingSurvivesReconciliation() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        // The adapter path: the recorder reserves a temp path and streams into it.
        let live = store.reserveTemporaryPath()
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: live)

        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .phone)

        #expect(report.adoptedPartials.isEmpty, "the live recording was adopted out from under the recorder")
        #expect(report.collectedEmptyTemps == 0)
        #expect(FileManager.default.fileExists(atPath: live.path), "the live partial was moved away mid-recording")
        let events = try pipeline.ledger.store.fetchAll()
        #expect(events.isEmpty, "a spurious interrupted capture was appended for a recording still in progress")
    }

    @Test("the recording still finalizes normally after a concurrent reconciliation")
    func finalizeSucceedsAfterReconciliation() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        let live = store.reserveTemporaryPath()
        let frames = Data((0..<2048).map { UInt8($0 % 97) })
        try frames.write(to: live)
        _ = try await Reconciler().run(pipeline: pipeline, deviceID: .phone)

        // The recorder stops, exactly as PhoneRecorder.finalize does.
        let event = try await pipeline.completeAudioCapture(
            temporaryFile: live, startedAtMS: 1_780_000_000_000, durationMS: 11_000,
            context: ["source": "actionButton"], interrupted: false)

        let payload = try CaptureAudioPayload(canonical: event.decodedPayload())
        #expect(payload.interrupted == false)
        #expect(payload.durationMS == 11_000)
        #expect(try Data(contentsOf: store.fileURL(forHash: payload.fileHash)) == frames)
        #expect(try pipeline.ledger.store.fetchAll().count == 1, "the capture landed exactly once")
    }

    @Test("a partial this process never reserved is still adopted — crash recovery is preserved")
    func orphanFromAPreviousProcessIsAdopted() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        // No reservation: this is what a partial from a killed process looks like.
        let orphan = store.tempDirectory.appendingPathComponent("\(UUID().uuidString).partial")
        try Data((0..<1024).map { UInt8($0 % 31) }).write(to: orphan)

        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .phone)

        #expect(report.adoptedPartials.count == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let payload = try CaptureAudioPayload(canonical: pipeline.ledger.store.fetchAll()[0].decodedPayload())
        #expect(payload.interrupted == true)
        #expect(payload.context["recovery"] == "partial")
    }

    @Test("finalizing releases the reservation, so a later crash-orphan of the same path adopts")
    func reservationIsReleasedOnFinalize() async throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        let path = store.reserveTemporaryPath()
        try Data([1, 2, 3, 4]).write(to: path)
        _ = try await pipeline.completeAudioCapture(
            temporaryFile: path, startedAtMS: 1, durationMS: 1)

        // Same path re-appears on disk with no live writer (the recorder is gone).
        try Data([9, 9, 9, 9]).write(to: path)
        let report = try await Reconciler().run(pipeline: pipeline, deviceID: .phone)
        #expect(report.adoptedPartials.count == 1, "a stale reservation permanently shadowed an orphan")
    }

    @Test("a dropped handle releases its reservation — an aborted recording is adoptable")
    func reservationIsReleasedWhenHandleDeallocates() throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        var tempURL: URL?
        do {
            let handle = try store.beginRecording()
            tempURL = handle.tempURL
            try store.append(Data([1, 2, 3, 4]), to: handle)
            #expect(try store.partialFiles().isEmpty, "an open recording is not an orphan")
        }  // handle deallocates: nobody can be writing it any more

        #expect(FileManager.default.fileExists(atPath: tempURL!.path))
        #expect(try store.partialFiles().count == 1, "an aborted recording stayed shadowed forever")
    }

    @Test("a discarded recording's reservation is released")
    func reservationIsReleasedOnDiscard() throws {
        let (pipeline, root) = try makePipeline()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = pipeline.audioStore

        let handle = try store.beginRecording()
        #expect(try store.partialFiles().isEmpty, "an open recording is not an orphan")
        store.discard(handle)
        try Data([7]).write(to: handle.tempURL)
        #expect(try store.partialFiles().count == 1)
    }
}
