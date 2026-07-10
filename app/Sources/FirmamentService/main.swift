import FirmamentCore
import Foundation

/// The Firmament core service: sole owner of the vault. Runs the job queue,
/// polls the import inboxes, and serves the bridge protocol on a local
/// socket. Designed to run whether or not the Mac app is open (plan §4).

let home = ProcessInfo.processInfo.environment["FIRMAMENT_HOME"]
    .map(URL.init(fileURLWithPath:))
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Firmament")

let vault = try VaultStore(directoryURL: home)
FileHandle.standardError.write(Data("firmament-service: vault at \(home.path)\n".utf8))

let inboxSourceID = try vault.ensureSource(kind: .inbox, name: "inbox")
let claudeSourceID = try vault.ensureSource(kind: .claudeCode, name: "claude-code-sessions")
let codexSourceID = try vault.ensureSource(kind: .codex, name: "codex-sessions")

// Processing: codex app-server behind the provider seam.
let provider = CodexAppServerProvider()
let pipeline = ExtractionPipeline(vault: vault, provider: provider)
let runner = JobRunner(vault: vault)
await pipeline.register(on: runner)
await runner.start()

// Ingestion pollers: the Self inbox and the agent-session inboxes.
let inbox = try InboxImporter(
    vault: vault, sourceID: inboxSourceID,
    inboxURL: home.appendingPathComponent("inbox"))
let agentInboxes: [(AgentClient, AgentSessionImporter, URL)] = [
    (.claudeCode, AgentSessionImporter(vault: vault, sourceID: claudeSourceID),
     home.appendingPathComponent("agent-inbox/claude_code")),
    (.codex, AgentSessionImporter(vault: vault, sourceID: codexSourceID),
     home.appendingPathComponent("agent-inbox/codex")),
]
for (_, _, url) in agentInboxes {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

// Granola (Others facet): syncs when a Business-plan API key is present,
// via env or a key file next to the vault.
let granolaKey = ProcessInfo.processInfo.environment["FIRMAMENT_GRANOLA_KEY"]
    ?? (try? String(contentsOf: home.appendingPathComponent("granola.key"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
if let granolaKey, !granolaKey.isEmpty {
    let granolaSourceID = try vault.ensureSource(kind: .granola, name: "granola")
    let connector = GranolaConnector(
        vault: vault, sourceID: granolaSourceID,
        client: GranolaClient(apiKey: granolaKey))
    Task {
        while !Task.isCancelled {
            do {
                let report = try await connector.syncOnce()
                for (entryID, revisionID) in report.created + report.revised {
                    try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
                }
            } catch {
                FileHandle.standardError.write(Data("granola sync error: \(error)\n".utf8))
            }
            try? await Task.sleep(for: .seconds(300))
        }
    }
    FileHandle.standardError.write(Data("firmament-service: granola sync enabled\n".utf8))
}

let ingestTask = Task {
    while !Task.isCancelled {
        do {
            let report = try inbox.scanOnce()
            for (entryID, revisionID) in report.imported {
                try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
            }
            for (client, importer, url) in agentInboxes {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let data = try? Data(contentsOf: file) else { continue }
                    if case .created(let entryID, let revisionID) =
                        try importer.importTranscript(data: data, client: client) {
                        try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
                    }
                    try? FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("ingest error: \(error)\n".utf8))
        }
        try? await Task.sleep(for: .seconds(5))
    }
}
_ = ingestTask

// Bridge socket.
let bridge = BridgeService(
    vault: vault, identityURL: home.appendingPathComponent("identity.md"))
let handler = BridgeRPCHandler(
    bridge: bridge,
    agentSourceIDs: [.claudeCode: claudeSourceID, .codex: codexSourceID])
let socketPath = ServicePaths.socketPath(home: home)

let server = try SocketServer(path: socketPath, handler: handler)
FileHandle.standardError.write(Data("firmament-service: listening on \(socketPath)\n".utf8))
await server.run()
