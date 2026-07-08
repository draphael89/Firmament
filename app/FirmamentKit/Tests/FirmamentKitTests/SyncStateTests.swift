import Foundation
import Testing
@testable import FirmamentKit

@Suite("Sync state + checkpoints")
struct SyncStateTests {
    struct Fixture {
        let store: LedgerStore
        let ledger: Ledger
        let audioStore: AudioFileStore
        let stateStore: SyncStateStore
        let root: URL

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("firmament-sync-\(UUID().uuidString)")
            let store = try LedgerStore.inMemory()
            return Fixture(
                store: store,
                ledger: try Ledger(store: store, deviceID: .mac),
                audioStore: try AudioFileStore(root: root.appendingPathComponent("media")),
                stateStore: try SyncStateStore(
                    directory: root.appendingPathComponent("sync"), ledgerStore: store),
                root: root)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("engine state serialization round-trips across a simulated relaunch")
    func stateRoundTrip() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        #expect(fixture.stateStore.loadEngineState() == nil)
        let blob = Data("engine-state-blob".utf8)
        try fixture.stateStore.saveEngineState(blob)
        // Simulated relaunch: a fresh store over the same directory.
        let reopened = try SyncStateStore(
            directory: fixture.root.appendingPathComponent("sync"), ledgerStore: fixture.store)
        #expect(reopened.loadEngineState() == blob)
        try reopened.reset()
        #expect(reopened.loadEngineState() == nil)
    }

    @Test("pending uploads re-derive from the Ledger and honor the upload gate")
    func pendingUploads() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let pipeline = CapturePipeline(ledger: fixture.ledger, audioStore: fixture.audioStore)
        let text = try await pipeline.captureText(body: "pending", sourcePlane: .composer)
        // A local audio event with no staged file (should be gated out).
        let gated = try await fixture.ledger.append(
            kind: .captureAudio, occurredAt: 1, author: .human,
            payload: CaptureAudioPayload(
                fileHash: String(repeating: "9", count: 64), durationMS: 100).canonical)
        // A foreign event (never uploaded by this device).
        let foreignDraft = Event.Draft(
            kind: .captureText, occurredAt: 2, recordedAt: 2,
            deviceID: .phone, author: .human, tier: .personal,
            payload: CaptureTextPayload(body: "foreign", sourcePlane: .composer).canonical)
        try await fixture.ledger.ingest(
            try Event.seal(foreignDraft, prevHash: HashChain.genesis(for: .phone)))

        let pending = try fixture.stateStore.pendingUploads(
            deviceID: .mac, audioStore: fixture.audioStore)
        #expect(pending.map(\.id) == [text.id])
        #expect(!pending.contains { $0.id == gated.id })

        // Marked sent → drops out; crash-safe by table, not memory.
        try fixture.stateStore.markSent([text.id])
        let after = try fixture.stateStore.pendingUploads(
            deviceID: .mac, audioStore: fixture.audioStore)
        #expect(after.isEmpty)
        #expect(try fixture.stateStore.isSent(text.id))
    }

    @Test("checkpoint clerk: exactly one per device per pinned-timezone day")
    func checkpointOncePerDay() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let noon: Int64 = 1_780_000_000_000
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: noon, author: .human,
            payload: CaptureTextPayload(body: "day content", sourcePlane: .composer).canonical)

        let first = try await CheckpointClerk.emitIfDue(ledger: fixture.ledger, nowMS: noon)
        #expect(first != nil)
        let payload = try SyncCheckpointPayload(canonical: first!.decodedPayload())
        #expect(payload.day == FirmamentTime.dayString(epochMS: noon))
        #expect(payload.eventCount == 1)

        // Same day, later hour: no second checkpoint.
        let second = try await CheckpointClerk.emitIfDue(
            ledger: fixture.ledger, nowMS: noon + 3_600_000)
        #expect(second == nil)

        // Next pinned-timezone day: a new one.
        let third = try await CheckpointClerk.emitIfDue(
            ledger: fixture.ledger, nowMS: noon + 86_400_000)
        #expect(third != nil)
        guard case .intact = try fixture.store.verifyChains()[.mac] else {
            Issue.record("chain broke across checkpoints")
            return
        }
    }

    @Test("checkpoint head matches the device chain head")
    func checkpointHead() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let noon: Int64 = 1_780_000_000_000
        let last = try await fixture.ledger.append(
            kind: .captureText, occurredAt: noon, author: .human,
            payload: CaptureTextPayload(body: "head anchor", sourcePlane: .composer).canonical)
        let checkpoint = try await CheckpointClerk.emitIfDue(ledger: fixture.ledger, nowMS: noon)
        let payload = try SyncCheckpointPayload(canonical: checkpoint!.decodedPayload())
        #expect(payload.chainHead == last.hash.hexEncoded)
    }
}
