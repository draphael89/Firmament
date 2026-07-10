import Foundation
import Testing
@testable import FirmamentCore

private func makeVaultAndSource() throws -> (VaultStore, Source, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("firmament-ingest-tests-\(UUID().uuidString)")
    let vault = try VaultStore(directoryURL: dir)
    let source = Source(kind: .inbox, name: "test-inbox")
    try vault.pool.write { try source.insert($0) }
    return (vault, source, dir)
}

@Suite("Inbox importer")
struct InboxImporterTests {

    private func makeImporter(quiescence: TimeInterval = 0)
        throws -> (InboxImporter, VaultStore, URL) {
        let (vault, source, dir) = try makeVaultAndSource()
        let inbox = dir.appendingPathComponent("inbox")
        let importer = try InboxImporter(
            vault: vault, sourceID: source.id, inboxURL: inbox,
            quiescence: quiescence)
        return (importer, vault, inbox)
    }

    @Test("Imports text files, dedupes, and removes consumed files")
    func importsText() throws {
        let (importer, vault, inbox) = try makeImporter()
        let file = inbox.appendingPathComponent("note.md")
        try "a thought about emergence".write(to: file, atomically: true, encoding: .utf8)

        let report = try importer.scanOnce()
        #expect(report.imported.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try vault.search("emergence").count == 1)

        // Same bytes delivered again (Shortcut + manual drag): duplicate.
        try "a thought about emergence".write(to: file, atomically: true, encoding: .utf8)
        let second = try importer.scanOnce()
        #expect(second.imported.isEmpty)
        #expect(second.duplicates == 1)
    }

    @Test("Skips partials, dotfiles, and files inside the quiescence window")
    func skipsUnsettledFiles() throws {
        let (importer, _, inbox) = try makeImporter(quiescence: 60)
        try "syncing".write(
            to: inbox.appendingPathComponent("draft.md.partial"),
            atomically: true, encoding: .utf8)
        try "hidden".write(
            to: inbox.appendingPathComponent(".DS_Store"),
            atomically: true, encoding: .utf8)
        try "too fresh".write(
            to: inbox.appendingPathComponent("fresh.md"),
            atomically: true, encoding: .utf8)

        let report = try importer.scanOnce()
        #expect(report.imported.isEmpty)
        #expect(report.skipped == 1)          // fresh.md waits
        #expect(report.quarantined.isEmpty)   // partial/dotfile aren't errors

        // Once the window passes, the fresh file imports.
        let later = try importer.scanOnce(now: Date(timeIntervalSinceNow: 120))
        #expect(later.imported.count == 1)
    }

    @Test("Quarantines unsupported and undecodable files with a visible reason")
    func quarantines() throws {
        let (importer, _, inbox) = try makeImporter()
        try Data([0x00, 0x01]).write(to: inbox.appendingPathComponent("mystery.xyz"))
        try Data([0xFF, 0xFE, 0x00, 0xC1]).write(to: inbox.appendingPathComponent("bad.txt"))

        let report = try importer.scanOnce()
        #expect(Set(report.quarantined) == ["mystery.xyz", "bad.txt"])
        let quarantineDir = inbox.appendingPathComponent("quarantine")
        let contents = try FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)
        #expect(contents.contains("mystery.xyz"))
        #expect(contents.contains("mystery.xyz.reason"))
        #expect(contents.contains("bad.txt"))
    }

    @Test("Audio files import as media without searchable text")
    func audioImports() throws {
        let (importer, vault, inbox) = try makeImporter()
        try Data("fake audio bytes".utf8).write(to: inbox.appendingPathComponent("memo.m4a"))

        let report = try importer.scanOnce()
        #expect(report.imported.count == 1)
        let revision = try vault.currentRevision(entryID: report.imported[0].entryID)
        #expect(revision?.mime == "audio/mp4")
    }
}

@Suite("Agent session importer")
struct AgentSessionImporterTests {

    private let transcript = """
        {"type":"user","sessionId":"abc-123","message":{"role":"user","content":"Build me a to-do app with offline sync"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll start with the data model."}]}}
        {"type":"user","isMeta":true,"message":{"role":"user","content":"harness-injected context"}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"file contents"}]}}
        {"type":"user","message":{"role":"user","content":"Actually make sync optional, I mostly work offline"}}
        {"type":"summary","summary":"irrelevant"}
        """

    @Test("Parses user and assistant turns, skipping meta and tool results")
    func parsing() {
        let parsed = AgentSessionImporter.parse(
            data: Data(transcript.utf8), client: .claudeCode)
        #expect(parsed.sessionID == "abc-123")
        #expect(parsed.userTurns == [
            "Build me a to-do app with offline sync",
            "Actually make sync optional, I mostly work offline",
        ])
        #expect(parsed.assistantTurns == ["I'll start with the data model."])
        #expect(parsed.rendered.contains("highest trust"))
        #expect(parsed.rendered.contains("untrusted evidence"))
    }

    @Test("Imports a transcript as an Agents-facet entry with raw bytes intact")
    func importing() throws {
        let (vault, source, _) = try makeVaultAndSource()
        let importer = AgentSessionImporter(vault: vault, sourceID: source.id)

        let result = try importer.importTranscript(
            data: Data(transcript.utf8), client: .claudeCode)
        guard case .created(let entryID, _) = result else {
            Issue.record("expected creation"); return
        }
        let entry = try vault.entry(id: entryID)
        #expect(entry?.facet == .agents)

        // Raw transcript is preserved verbatim.
        let revision = try vault.currentRevision(entryID: entryID)
        #expect(try vault.rawContent(revision: revision!) == Data(transcript.utf8))

        // User-authored content is searchable.
        #expect(try vault.search("offline").count == 1)
    }
}
