import Foundation
import Testing
@testable import FirmamentKit

@Suite("CLI verify + export")
struct CLITests {
    private func storeWithGoldenFixture() throws -> LedgerStore {
        let store = try LedgerStore.inMemory()
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        for event in try EventNDJSON.decode(ndjson) {
            try store.insert(event)
        }
        return store
    }

    @Test("verify: green on the golden fixture")
    func verifyGreen() throws {
        let outcome = try LedgerVerifier.verify(store: try storeWithGoldenFixture())
        #expect(outcome.exitCode == 0)
        #expect(outcome.lines.allSatisfy { $0.contains("intact") })
        // Checkpoint heads surface in the report.
        #expect(outcome.lines.allSatisfy { $0.contains("checkpoint") })
    }

    @Test("verify: empty ledger is green")
    func verifyEmpty() throws {
        let outcome = try LedgerVerifier.verify(store: try LedgerStore.inMemory())
        #expect(outcome.exitCode == 0)
        #expect(outcome.lines == ["mac: empty", "phone: empty"])
    }

    @Test("verify: a flipped payload byte reports that event id and exits 1")
    func verifyCorrupt() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        // Build a small chain, then re-insert a tampered copy into a fresh store.
        var events = [Event]()
        for index in 0..<5 {
            events.append(try await ledger.append(
                kind: .captureText, occurredAt: Int64(1_780_000_000_000 + index * 1000),
                author: .human,
                payload: CaptureTextPayload(body: "cli \(index)", sourcePlane: .composer).canonical))
        }
        let victim = events[2]
        let victimID = victim.id
        var bytes = Data(victim.payload)
        bytes[0] ^= 0xFF
        let tampered = Event(
            id: victim.id, kind: victim.kind, occurredAt: victim.occurredAt,
            recordedAt: victim.recordedAt, deviceID: victim.deviceID,
            author: victim.author, tier: victim.tier, parentID: victim.parentID,
            payload: bytes, payloadHash: victim.payloadHash,
            prevHash: victim.prevHash, hash: victim.hash)
        let corrupted = try LedgerStore.inMemory()
        for event in events where event.id != victim.id {
            try corrupted.insert(event)
        }
        try corrupted.insert(tampered)

        let outcome = try LedgerVerifier.verify(store: corrupted)
        #expect(outcome.exitCode == 1)
        #expect(outcome.lines.contains { $0.contains("CORRUPT") && $0.contains(victimID.uuidString.lowercased()) })
    }

    @Test("verify: a gapped chain reports incomplete (exit 2), never corrupt")
    func verifyGap() async throws {
        let store = try LedgerStore.inMemory()
        let ledger = try Ledger(store: store, deviceID: .mac)
        var events = [Event]()
        for index in 0..<5 {
            events.append(try await ledger.append(
                kind: .captureText, occurredAt: Int64(index) * 1000, author: .human,
                payload: CaptureTextPayload(body: "g\(index)", sourcePlane: .composer).canonical))
        }
        let gapped = try LedgerStore.inMemory()
        for event in events where event.id != events[2].id {
            try gapped.insert(event)
        }
        let outcome = try LedgerVerifier.verify(store: gapped)
        #expect(outcome.exitCode == 2)
        #expect(outcome.lines.contains { $0.contains("INCOMPLETE") })
        #expect(!outcome.lines.contains { $0.contains("CORRUPT") })
    }

    @Test("export round-trip: import of an export re-exports identically")
    func exportRoundTrip() throws {
        let first = try LedgerVerifier.export(store: try storeWithGoldenFixture())
        let reimported = try LedgerStore.inMemory()
        for event in try EventNDJSON.decode(first) {
            try reimported.insert(event)
        }
        let second = try LedgerVerifier.export(store: reimported)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("CLI reads (queue) while the app holds the writer (pool) on one file")
    func crossProcessStyleRead() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmament-cli-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let appStore = try LedgerStore.pool(at: path)
        let ledger = try Ledger(store: appStore, deviceID: .mac)
        for index in 0..<10 {
            try await ledger.append(
                kind: .captureText, occurredAt: Int64(index), author: .human,
                payload: CaptureTextPayload(body: "shared \(index)", sourcePlane: .composer).canonical)
        }
        // A second connection on the same WAL file, CLI-style.
        let cliStore = try LedgerStore.queue(at: path)
        let outcome = try LedgerVerifier.verify(store: cliStore)
        #expect(outcome.exitCode == 0)
        #expect(outcome.lines.contains { $0.contains("intact — 10") })
    }
}
