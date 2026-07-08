import Foundation
import GRDB
import Testing
@testable import FirmamentKit

@Suite("Ledger store")
struct LedgerTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-test-\(UUID().uuidString).sqlite").path
    }

    @Test("append N events, read back in id order, chain verifies")
    func appendAndVerify() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        for index in 0..<20 {
            try await ledger.append(
                kind: .captureText,
                occurredAt: 1_780_000_000_000 + Int64(index) * 1000,
                author: .human,
                payload: CaptureTextPayload(body: "note \(index)", sourcePlane: .composer).canonical
            )
        }
        let events = try store.fetchAll()
        #expect(events.count == 20)
        #expect(events.map(\.id.uuidString) == events.map(\.id.uuidString).sorted())
        guard case .intact(_, let count) = try store.verifyChains()[.mac] else {
            Issue.record("chain not intact")
            return
        }
        #expect(count == 20)
    }

    @Test("idempotent ingest: same id inserted twice is a no-op")
    func idempotentIngest() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        let event = try await ledger.append(
            kind: .captureText, occurredAt: 1_780_000_000_000, author: .human,
            payload: CaptureTextPayload(body: "once", sourcePlane: .composer).canonical
        )
        #expect(try await ledger.ingest(event) == false)
        #expect(try store.eventCount() == 1)
    }

    @Test("tombstone append leaves the target row intact")
    func tombstoneLeavesTarget() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        let target = try await ledger.append(
            kind: .captureText, occurredAt: 1_780_000_000_000, author: .human,
            payload: CaptureTextPayload(body: "to delete", sourcePlane: .composer).canonical
        )
        try await ledger.append(
            kind: .tombstone, occurredAt: 1_780_000_001_000, author: .human,
            payload: TombstonePayload(targets: [target.id], reason: "test").canonical
        )
        #expect(try store.fetchEvent(id: target.id) != nil)
        #expect(try store.eventCount() == 2)
    }

    @Test("FTS finds capture and transcript text; checkpoints are not indexed")
    func fts() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        let capture = try await ledger.append(
            kind: .captureText, occurredAt: 1, author: .human,
            payload: CaptureTextPayload(body: "the alberta multiplier belief", sourcePlane: .composer).canonical
        )
        let audio = try await ledger.append(
            kind: .captureAudio, occurredAt: 2, author: .human,
            payload: CaptureAudioPayload(fileHash: String(repeating: "0", count: 64), durationMS: 1000).canonical
        )
        let transcript = try await ledger.append(
            kind: .transcript, occurredAt: 2, author: .system, parentID: audio.id,
            payload: TranscriptPayload(text: "jonathan login event", segments: [], asrModel: "test@1").canonical
        )
        try await ledger.append(
            kind: .syncCheckpoint, occurredAt: 3, author: .system, tier: .open,
            payload: SyncCheckpointPayload(chainHead: "00", eventCount: 3, day: "2026-07-08").canonical
        )
        #expect(try store.searchText("alberta") == [capture.id])
        #expect(try store.searchText("jonathan") == [transcript.id])
        #expect(try store.searchText("chainHead").isEmpty)
    }

    @Test("CLI-style DatabaseQueue ledger is in WAL mode with synchronous=NORMAL")
    func cliDurabilityConfig() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LedgerStore.queue(at: path)
        let (journal, sync) = try store.writer.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?",
             try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1)
        }
        #expect(journal.lowercased() == "wal")
        #expect(sync == 1) // NORMAL
    }

    @Test("parallel readers during sustained appends see consistent snapshots")
    func concurrentReads() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LedgerStore.pool(at: path)
        let ledger = try Ledger(store: store, deviceID: .mac)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<200 {
                    try await ledger.append(
                        kind: .captureText, occurredAt: Int64(index), author: .human,
                        payload: CaptureTextPayload(body: "n\(index)", sourcePlane: .composer).canonical
                    )
                }
            }
            group.addTask {
                for _ in 0..<50 {
                    let events = try store.fetchAll()
                    // Snapshot consistency: whatever count we see, the chain
                    // over that snapshot verifies with no gaps.
                    if !events.isEmpty {
                        switch HashChain.verify(events, deviceID: .mac) {
                        case .intact, .empty: break
                        case .incomplete, .corrupt:
                            Issue.record("torn read: snapshot chain not intact")
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        guard case .intact(_, let count) = try store.verifyChains()[.mac] else {
            Issue.record("final chain not intact")
            return
        }
        #expect(count == 200)
    }

    @Test("golden fixture ingests and verifies through the store")
    func goldenThroughStore() throws {
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        let events = try EventNDJSON.decode(ndjson)
        let store = try LedgerStore.inMemory()
        for event in events {
            try store.insert(event)
        }
        for device in DeviceID.allCases {
            guard case .intact = try store.verifyChains()[device] else {
                Issue.record("fixture chain for \(device) not intact after store round-trip")
                return
            }
        }
    }
}
