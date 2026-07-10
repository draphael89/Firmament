import Foundation
import GRDB
import Testing
@testable import FirmamentCore

// MARK: - Fixtures

private func makeVault() throws -> VaultStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("firmament-pipeline-tests-\(UUID().uuidString)")
    return try VaultStore(directoryURL: dir)
}

private func makeEntry(
    _ vault: VaultStore, text: String, localOnly: Bool = false
) throws -> (entryID: String, revisionID: String) {
    let source = Source(kind: .capture, name: "test")
    try vault.pool.write { try source.insert($0) }
    guard case .created(let entryID, let revisionID) = try vault.importEntry(
        sourceID: source.id, facet: .selfFacet, data: Data(text.utf8),
        mime: "text/plain", localOnly: localOnly)
    else { throw VaultError.entryNotFound("import failed") }
    return (entryID, revisionID)
}

/// Scripted provider: returns canned responses in order, records requests.
private actor FakeProvider: ReasoningProvider {
    var requests: [ReasoningRequest] = []
    private var script: [Result<String, ReasoningError>]

    init(script: [Result<String, ReasoningError>]) { self.script = script }

    func complete(_ request: ReasoningRequest) async throws -> String {
        requests.append(request)
        guard !script.isEmpty else {
            throw ReasoningError.providerUnavailable("script exhausted")
        }
        return try script.removeFirst().get()
    }
}

private let goodExtraction = """
    {"title": "On craftsmanship", "summary": "A reflection on quality.",
     "people": [], "projects": ["Firmament"], "topics": ["craftsmanship"],
     "decisions": ["ship the vault first"], "open_loops": [],
     "question": {"abstain": false, "text": "What does finished mean to you?",
                  "rationale": "probes the author's quality bar",
                  "evidence": ["quality is the whole point"]}}
    """

private let abstainingExtraction = """
    {"title": "Grocery list", "summary": "Routine shopping items.",
     "people": [], "projects": [], "topics": ["errands"],
     "decisions": [], "open_loops": [],
     "question": {"abstain": true, "text": null, "rationale": null, "evidence": []}}
    """

private let inconsistentQuestionExtraction = """
    {"title": "Inconsistent question", "summary": "The model contradicted itself.",
     "people": [], "projects": [], "topics": [],
     "decisions": [], "open_loops": [],
     "question": {"abstain": false, "text": null, "rationale": null, "evidence": []}}
    """

// MARK: - JobRunner

@Suite("Job runner")
struct JobRunnerTests {

    @Test("Runs a due job to done exactly once per enqueue")
    func happyPath() async throws {
        let vault = try makeVault()
        let runner = JobRunner(vault: vault)
        let counter = Counter()
        await runner.register(kind: "noop") { _ in await counter.increment() }

        #expect(try vault.enqueueJob(kind: "noop", idempotencyKey: "n:1"))
        #expect(try !vault.enqueueJob(kind: "noop", idempotencyKey: "n:1"))
        let processed = await runner.runPendingOnce()
        #expect(processed == 1)
        #expect(await counter.value == 1)
        let job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .done)
    }

    @Test("Generic failures back off, then land terminal and visible")
    func retryToTerminal() async throws {
        let vault = try makeVault()
        let runner = JobRunner(vault: vault, maxAttempts: 2)
        await runner.register(kind: "explode") { _ in
            throw PipelineError.unreadableContent
        }
        try vault.enqueueJob(kind: "explode", idempotencyKey: "e:1")

        await runner.runPendingOnce()
        var job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .failedRetryable)
        #expect(job?.attempts == 1)
        #expect(job!.runAfter > Date())

        // Force the backoff window open, run again → terminal.
        try await vault.pool.write { db in
            try db.execute(sql: "UPDATE job SET runAfter = ?", arguments: [Date(timeIntervalSinceNow: -1)])
        }
        await runner.runPendingOnce()
        job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .failedTerminal)
        #expect(job?.lastError != nil)
    }

    @Test("Usage-limit outages park the job without burning attempts")
    func usageLimitParks() async throws {
        let vault = try makeVault()
        let runner = JobRunner(vault: vault)
        let resumeAt = Date(timeIntervalSinceNow: 3600)
        await runner.register(kind: "limited") { _ in
            throw ReasoningError.usageLimitExceeded(retryAfter: resumeAt)
        }
        try vault.enqueueJob(kind: "limited", idempotencyKey: "l:1")

        await runner.runPendingOnce()
        let job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .pending)
        #expect(job?.attempts == 0)
        #expect(abs(job!.runAfter.timeIntervalSince(resumeAt)) < 1)

        // Parked in the future: nothing to claim now.
        #expect(await runner.runPendingOnce() == 0)
    }

    @Test("Jobs stuck running from a dead process recover to pending")
    func stuckRecovery() async throws {
        let vault = try makeVault()
        try await vault.pool.write { db in
            try Job(kind: "extract", idempotencyKey: "s:1", status: .running).insert(db)
        }
        let runner = JobRunner(vault: vault)
        try await runner.recoverStuckJobs()
        let job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .pending)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}

// MARK: - Extraction pipeline

@Suite("Extraction pipeline")
struct ExtractionPipelineTests {

    @Test("Structured-output schema requires every declared question field")
    func strictQuestionSchema() throws {
        guard let schema = try JSONSerialization.jsonObject(
            with: ExtractionPipeline.outputSchema) as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              let question = properties["question"] as? [String: Any],
              let questionProperties = question["properties"] as? [String: Any],
              let required = question["required"] as? [String] else {
            Issue.record("Extraction schema is missing the question contract")
            return
        }

        #expect(Set(required) == Set(questionProperties.keys))
    }

    @Test("Extraction writes projection, analysis run, question, and search index")
    func happyPath() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(
            vault, text: "quality is the whole point of the craft")
        let provider = FakeProvider(script: [.success(goodExtraction)])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let runner = JobRunner(vault: vault)
        await pipeline.register(on: runner)

        try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
        await runner.runPendingOnce()

        let (projection, run, question) = try await vault.pool.read { db in
            (try EntryProjection.fetchOne(db, key: entryID),
             try AnalysisRun.fetchAll(db).first,
             try Question.fetchAll(db).first)
        }
        #expect(projection?.title == "On craftsmanship")
        #expect(run?.status == .succeeded)
        #expect(run?.promptVersion == ExtractionPipeline.promptVersion)
        #expect(question?.text == "What does finished mean to you?")
        #expect(question?.status == .open)
        #expect(try vault.search("craftsmanship") == [entryID])
        // Raw body is searchable too, not just projected fields.
        #expect(try vault.search("whole point") == [entryID])
    }

    @Test("Abstention is honored: no question row")
    func abstention() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(vault, text: "milk, eggs, bread")
        let provider = FakeProvider(script: [.success(abstainingExtraction)])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let runner = JobRunner(vault: vault)
        await pipeline.register(on: runner)

        try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
        await runner.runPendingOnce()

        #expect(try await vault.pool.read { try Question.fetchCount($0) } == 0)
        let projection = try await vault.pool.read { try EntryProjection.fetchOne($0, key: entryID) }
        #expect(projection?.title == "Grocery list")
    }

    @Test("local_only entries never reach the provider")
    func localOnlySkipsProvider() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(
            vault, text: "never send this anywhere", localOnly: true)
        let provider = FakeProvider(script: [.success(goodExtraction)])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let runner = JobRunner(vault: vault)
        await pipeline.register(on: runner)

        try pipeline.enqueue(revisionID: revisionID, entryID: entryID)
        await runner.runPendingOnce()

        #expect(await provider.requests.isEmpty)
        let job = try await vault.pool.read { try Job.fetchAll($0).first }
        #expect(job?.status == .done)
        #expect(try await vault.pool.read { try EntryProjection.fetchCount($0) } == 0)
    }

    @Test("Reprocessing replaces the open question instead of stacking")
    func reprocessReplacesQuestion() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(
            vault, text: "quality is the whole point of the craft")
        let second = goodExtraction.replacingOccurrences(
            of: "What does finished mean to you?", with: "Who taught you craft?")
        let provider = FakeProvider(script: [.success(goodExtraction), .success(second)])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)

        let job = Job(kind: ExtractionPipeline.jobKind, idempotencyKey: "direct",
                      entryID: entryID,
                      payload: try JSONEncoder().encode(["revisionID": revisionID]))
        try await pipeline.run(job)
        #expect(try await vault.pool.read { try Question.fetchCount($0) } == 1)
        try await pipeline.run(job)

        let questions = try await vault.pool.read { try Question.fetchAll($0) }
        #expect(questions.count == 1)
        #expect(questions.first?.text == "Who taught you craft?")
    }

    @Test("Reprocessing to abstention removes the prior open question")
    func reprocessAbstains() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(
            vault, text: "quality is the whole point of the craft")
        let provider = FakeProvider(script: [
            .success(goodExtraction), .success(abstainingExtraction),
        ])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let job = Job(
            kind: ExtractionPipeline.jobKind, idempotencyKey: "direct",
            entryID: entryID,
            payload: try JSONEncoder().encode(["revisionID": revisionID]))

        try await pipeline.run(job)
        #expect(try await vault.pool.read { try Question.fetchCount($0) } == 1)
        try await pipeline.run(job)

        let questions = try await vault.pool.read { try Question.fetchAll($0) }
        #expect(questions.isEmpty)
    }

    @Test("A non-abstaining result without question text preserves the prior question")
    func inconsistentQuestionPreservesPrior() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(
            vault, text: "quality is the whole point of the craft")
        let provider = FakeProvider(script: [
            .success(goodExtraction), .success(inconsistentQuestionExtraction),
        ])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let job = Job(
            kind: ExtractionPipeline.jobKind, idempotencyKey: "direct",
            entryID: entryID,
            payload: try JSONEncoder().encode(["revisionID": revisionID]))

        try await pipeline.run(job)
        await #expect(throws: ReasoningError.self) {
            try await pipeline.run(job)
        }

        let (questions, runs) = try await vault.pool.read { db in
            (try Question.fetchAll(db), try AnalysisRun.fetchAll(db))
        }
        #expect(questions.count == 1)
        #expect(questions.first?.text == "What does finished mean to you?")
        #expect(runs.filter { $0.status == .succeeded }.count == 1)
        #expect(runs.filter { $0.status == .failed }.count == 1)
    }

    @Test("Unparseable model output records a failed run and throws")
    func invalidOutput() async throws {
        let vault = try makeVault()
        let (entryID, revisionID) = try makeEntry(vault, text: "some note")
        let provider = FakeProvider(script: [.success("not json at all")])
        let pipeline = ExtractionPipeline(vault: vault, provider: provider)
        let job = Job(kind: ExtractionPipeline.jobKind, idempotencyKey: "direct",
                      entryID: entryID,
                      payload: try JSONEncoder().encode(["revisionID": revisionID]))

        await #expect(throws: ReasoningError.self) {
            try await pipeline.run(job)
        }
        let run = try await vault.pool.read { try AnalysisRun.fetchAll($0).first }
        #expect(run?.status == .failed)
        #expect(run?.error?.contains("unparseable") == true)
    }
}

// MARK: - JSON-RPC connection

@Suite("JSON-RPC connection")
struct JSONRPCConnectionTests {

    private func makePair() -> (JSONRPCConnection, serverIn: FileHandle, serverOut: FileHandle) {
        let toClient = Pipe()   // server → client
        let toServer = Pipe()   // client → server
        let conn = JSONRPCConnection(
            readHandle: toClient.fileHandleForReading,
            writeHandle: toServer.fileHandleForWriting)
        return (conn, toServer.fileHandleForReading, toClient.fileHandleForWriting)
    }

    private func readLine(_ handle: FileHandle) -> [String: JSONValue]? {
        var data = Data()
        while let byte = try? handle.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            data.append(byte)
        }
        guard case .object(let obj)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return obj
    }

    @Test("Requests correlate to responses by id")
    func requestResponse() async throws {
        let (conn, serverIn, serverOut) = makePair()

        async let result = conn.request("initialize", params: .object([:]))
        let received = readLine(serverIn)
        #expect(received?["method"]?.stringValue == "initialize")
        guard case .number(let id)? = received?["id"] else {
            Issue.record("no id on request"); return
        }
        let response = #"{"jsonrpc":"2.0","id":\#(Int(id)),"result":{"ok":true}}"# + "\n"
        serverOut.write(Data(response.utf8))

        let value = try await result
        #expect(value["ok"] == .bool(true))
        await conn.close()
    }

    @Test("Remote errors throw with code and message")
    func remoteError() async throws {
        let (conn, serverIn, serverOut) = makePair()

        let task = Task { try await conn.request("thread/start", params: nil) }
        guard case .number(let id)? = readLine(serverIn)?["id"] else {
            Issue.record("no id"); return
        }
        let response = #"{"jsonrpc":"2.0","id":\#(Int(id)),"error":{"code":-32600,"message":"bad"}}"# + "\n"
        serverOut.write(Data(response.utf8))

        await #expect(throws: JSONRPCConnection.ConnectionError.self) {
            _ = try await task.value
        }
        await conn.close()
    }

    @Test("Server notifications stream in order")
    func notifications() async throws {
        let (conn, _, serverOut) = makePair()
        let lines = [
            #"{"jsonrpc":"2.0","method":"turn/started","params":{"n":1}}"#,
            #"{"jsonrpc":"2.0","method":"turn/completed","params":{"n":2}}"#,
        ].joined(separator: "\n") + "\n"
        serverOut.write(Data(lines.utf8))

        var received: [String] = []
        for await notification in conn.notifications {
            received.append(notification.method)
            if received.count == 2 { break }
        }
        #expect(received == ["turn/started", "turn/completed"])
        await conn.close()
    }
}
