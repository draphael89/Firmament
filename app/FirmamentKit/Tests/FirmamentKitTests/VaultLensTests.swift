import Foundation
import Testing
@testable import FirmamentKit

@Suite("Vault lens")
struct VaultLensTests {
    struct Fixture {
        let store: LedgerStore
        let ledger: Ledger
        let vault: VaultLens
        let folder: Folder
        let root: URL

        static func make(git: Bool = false) throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("firmament-vault-\(UUID().uuidString)")
            let store = try LedgerStore.inMemory()
            let ledger = try Ledger(store: store, deviceID: .mac)
            let vault = try VaultLens(root: root, gitEnabled: git)
            let folder = try Folder(store: store, lenses: [vault])
            return Fixture(store: store, ledger: ledger, vault: vault, folder: folder, root: root)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func vaultSnapshot() throws -> [String: String] {
            try VaultLensTests.markdownFiles(under: root)
        }
    }

    /// Synchronous directory walk — NSEnumerator iteration is unavailable
    /// from async test bodies.
    static func markdownFiles(under root: URL) throws -> [String: String] {
        var snapshot = [String: String]()
        let rootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return snapshot }
        while let entry = enumerator.nextObject() as? URL {
            guard entry.pathExtension == "md" else { continue }
            let entryPath = entry.resolvingSymlinksInPath().path
            guard entryPath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(entryPath.dropFirst(rootPath.count + 1))
            snapshot[relative] = try String(contentsOf: entry, encoding: .utf8)
        }
        return snapshot
    }

    // A timestamp solidly inside a single pinned-timezone day (midday UTC).
    static let noonMS: Int64 = 1_780_000_000_000

    @Test("golden ledger folds to byte-identical golden-vault fixtures")
    func goldenVault() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        for event in try EventNDJSON.decode(ndjson) {
            try fixture.store.insert(event)
        }
        try await fixture.folder.foldPending()
        let snapshot = try fixture.vaultSnapshot()

        let goldenDir = GoldenLedger.fixtureURL.deletingLastPathComponent()
            .appendingPathComponent("golden-vault")
        if ProcessInfo.processInfo.environment["REGENERATE_GOLDEN"] == "1" {
            try? FileManager.default.removeItem(at: goldenDir)
            for (relative, content) in snapshot {
                let url = goldenDir.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url)
            }
        }

        let golden = try Self.markdownFiles(under: goldenDir)
        #expect(!snapshot.isEmpty)
        #expect(snapshot == golden, "golden-vault drift — review like a migration")
    }

    @Test("R3: reset + refold from genesis is byte-identical")
    func rebuildDeterminism() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let ndjson = try String(contentsOf: GoldenLedger.fixtureURL, encoding: .utf8)
        for event in try EventNDJSON.decode(ndjson) {
            try fixture.store.insert(event)
        }
        try await fixture.folder.foldPending()
        let first = try fixture.vaultSnapshot()
        try await fixture.folder.rebuild(lensNamed: "vault")
        let second = try fixture.vaultSnapshot()
        #expect(first == second)
    }

    @Test("idempotency: folding with nothing new changes nothing")
    func idempotent() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human,
            payload: CaptureTextPayload(body: "hello vault", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()
        let first = try fixture.vaultSnapshot()
        let counts = try await fixture.folder.foldPending()
        #expect(counts["vault"] == 0)
        #expect(try fixture.vaultSnapshot() == first)
    }

    @Test("late arrival refolds the affected day")
    func lateArrival() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human,
            payload: CaptureTextPayload(body: "today's note", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()

        // A synced event lands with yesterday's occurredAt.
        let yesterday = Self.noonMS - 86_400_000
        let draft = Event.Draft(
            kind: .captureText, occurredAt: yesterday, recordedAt: Self.noonMS + 1000,
            deviceID: .phone, author: .human, tier: .personal,
            payload: CaptureTextPayload(body: "yesterday, from the phone", sourcePlane: .composer).canonical)
        try await fixture.ledger.ingest(try Event.seal(draft, prevHash: HashChain.genesis(for: .phone)))
        try await fixture.folder.foldPending()

        let snapshot = try fixture.vaultSnapshot()
        let yesterdayFile = "journal/\(FirmamentTime.dayString(epochMS: yesterday)).md"
        let todayFile = "journal/\(FirmamentTime.dayString(epochMS: Self.noonMS)).md"
        #expect(snapshot[yesterdayFile]?.contains("yesterday, from the phone") == true)
        #expect(snapshot[todayFile]?.contains("today's note") == true)
    }

    @Test("multi-transcript dedup: capture's own device wins, else earliest id")
    func transcriptDedup() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let capture = try await fixture.ledger.append(
            kind: .captureAudio, occurredAt: Self.noonMS, author: .human,
            payload: CaptureAudioPayload(fileHash: String(repeating: "d", count: 64), durationMS: 900).canonical)
        // Foreign transcript arrives first, local second.
        let foreignDraft = Event.Draft(
            kind: .transcript, occurredAt: Self.noonMS, recordedAt: Self.noonMS + 10,
            deviceID: .phone, author: .system, tier: .personal, parentID: capture.id,
            payload: TranscriptPayload(text: "phone words", segments: [], asrModel: "p@1").canonical)
        try await fixture.ledger.ingest(try Event.seal(foreignDraft, prevHash: HashChain.genesis(for: .phone)))
        try await fixture.ledger.append(
            kind: .transcript, occurredAt: Self.noonMS, author: .system, parentID: capture.id,
            payload: TranscriptPayload(text: "mac words", segments: [], asrModel: "m@1").canonical)

        try await fixture.folder.foldPending()
        let file = "journal/\(FirmamentTime.dayString(epochMS: Self.noonMS)).md"
        let content = try fixture.vaultSnapshot()[file]
        #expect(content?.contains("mac words") == true)
        #expect(content?.contains("phone words") == false)
    }

    @Test("tombstoned capture disappears; other events unaffected")
    func tombstoneHonored() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let keep = try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human,
            payload: CaptureTextPayload(body: "keep me", sourcePlane: .composer).canonical)
        let drop = try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS + 60_000, author: .human,
            payload: CaptureTextPayload(body: "delete me", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()

        try await fixture.ledger.append(
            kind: .tombstone, occurredAt: Self.noonMS + 120_000, author: .human,
            payload: TombstonePayload(targets: [drop.id], reason: "test").canonical)
        try await fixture.folder.foldPending()

        let file = "journal/\(FirmamentTime.dayString(epochMS: Self.noonMS)).md"
        let content = try fixture.vaultSnapshot()[file]
        #expect(content?.contains("keep me") == true)
        #expect(content?.contains("delete me") == false)
        #expect(content?.contains(keep.id.uuidString.lowercased()) == true)
        #expect(content?.contains(drop.id.uuidString.lowercased()) == false)
    }

    @Test("sanctum events render only under the hidden .sanctum dot-directory")
    func sanctumSeparation() async throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human, tier: .sanctum,
            payload: CaptureTextPayload(body: "2am health note", sourcePlane: .composer).canonical)
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human, tier: .personal,
            payload: CaptureTextPayload(body: "ordinary note", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()

        let day = FirmamentTime.dayString(epochMS: Self.noonMS)
        let snapshot = try fixture.vaultSnapshot()
        #expect(snapshot["journal/\(day).md"]?.contains("ordinary note") == true)
        #expect(snapshot["journal/\(day).md"]?.contains("2am health note") == false)
        #expect(snapshot[".sanctum/journal/\(day).md"]?.contains("2am health note") == true)
    }

    @Test("git auto-commit: one commit per changing fold pass; .sanctum untracked")
    func gitCommits() async throws {
        let fixture = try Fixture.make(git: true)
        defer { fixture.cleanup() }
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human,
            payload: CaptureTextPayload(body: "committed note", sourcePlane: .composer).canonical)
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS, author: .human, tier: .sanctum,
            payload: CaptureTextPayload(body: "sanctum note", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()
        try await fixture.ledger.append(
            kind: .captureText, occurredAt: Self.noonMS + 60_000, author: .human,
            payload: CaptureTextPayload(body: "second pass", sourcePlane: .composer).canonical)
        try await fixture.folder.foldPending()

        let log = try VaultLens.run(["git", "log", "--oneline"], in: fixture.root)
        #expect(log.split(separator: "\n").count == 2)
        let tracked = try VaultLens.run(["git", "ls-files"], in: fixture.root)
        #expect(!tracked.contains(".sanctum"))
        #expect(tracked.contains("journal/"))
    }
}
