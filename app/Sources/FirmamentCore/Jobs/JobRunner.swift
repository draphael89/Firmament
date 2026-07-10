import Foundation
import GRDB

/// Executes durable jobs with at-least-once semantics (plan §4): claims are
/// serialized through the vault's single writer; failures are either
/// provider outages (wait, don't burn attempts), retryable (bounded backoff),
/// or terminal and visible. Assumes one runner per vault (the core service).
public actor JobRunner {
    public typealias Handler = @Sendable (Job) async throws -> Void

    private let vault: VaultStore
    private var handlers: [String: Handler] = [:]
    private let maxAttempts: Int
    private var loopTask: Task<Void, Never>?

    public init(vault: VaultStore, maxAttempts: Int = 5) {
        self.vault = vault
        self.maxAttempts = maxAttempts
    }

    public func register(kind: String, handler: @escaping Handler) {
        handlers[kind] = handler
    }

    /// Jobs stuck in `running` from a previous process death go back to
    /// pending. Call once at service start, before the poll loop.
    public func recoverStuckJobs() throws {
        try vault.pool.write { db in
            try db.execute(
                sql: "UPDATE job SET status = ?, updatedAt = ? WHERE status = ?",
                arguments: [JobStatus.pending, Date(), JobStatus.running])
        }
    }

    /// Claims and runs due jobs until none remain. Returns the number run.
    @discardableResult
    public func runPendingOnce() async -> Int {
        var processed = 0
        while true {
            let job: Job?
            do {
                job = try claimNext()
            } catch {
                // Claim failures end the drain; the poll loop retries. Say so.
                FileHandle.standardError.write(
                    Data("job claim failed: \(error)\n".utf8))
                break
            }
            guard let job else { break }
            await run(job)
            processed += 1
        }
        return processed
    }

    /// Polls until cancelled. One poll loop per vault.
    public func start(pollInterval: Duration = .seconds(5)) {
        guard loopTask == nil else { return }
        loopTask = Task {
            try? recoverStuckJobs()
            while !Task.isCancelled {
                await runPendingOnce()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func claimNext() throws -> Job? {
        try vault.pool.write { db in
            guard var job = try Job
                .filter([JobStatus.pending, .failedRetryable].contains(Column("status")))
                .filter(Column("runAfter") <= Date())
                .order(Column("createdAt"))
                .fetchOne(db)
            else { return nil }
            job.status = .running
            job.updatedAt = Date()
            try job.update(db)
            return job
        }
    }

    private func run(_ job: Job) async {
        guard let handler = handlers[job.kind] else {
            try? finish(job, status: .failedTerminal,
                        error: "no handler registered for kind '\(job.kind)'")
            return
        }
        do {
            try await handler(job)
            try? finish(job, status: .done, error: nil)
        } catch let error as ReasoningError {
            handleReasoningFailure(job, error: error)
        } catch {
            retryOrFail(job, message: "\(error)")
        }
    }

    private func handleReasoningFailure(_ job: Job, error: ReasoningError) {
        switch error {
        case .usageLimitExceeded(let retryAfter):
            // Provider outage, not the job's fault: wait, attempts unchanged.
            try? reschedule(job, runAfter: retryAfter ?? Date().addingTimeInterval(30 * 60),
                            error: "usage limit exceeded")
        case .providerUnavailable(let message):
            try? reschedule(job, runAfter: Date().addingTimeInterval(2 * 60), error: message)
        case .authExpired(let message):
            // Needs the operator; park generously rather than terminally.
            try? reschedule(job, runAfter: Date().addingTimeInterval(30 * 60),
                            error: "auth expired: \(message)")
        case .invalidOutput(let message), .turnFailed(let message):
            retryOrFail(job, message: message)
        }
    }

    private func retryOrFail(_ job: Job, message: String) {
        let attempts = job.attempts + 1
        if attempts >= maxAttempts {
            try? finish(job, status: .failedTerminal, error: message, attempts: attempts)
        } else {
            let backoff = TimeInterval(30 * (1 << attempts))
            try? update(job, status: .failedRetryable, error: message,
                        attempts: attempts, runAfter: Date().addingTimeInterval(backoff))
        }
    }

    private func reschedule(_ job: Job, runAfter: Date, error: String) throws {
        try update(job, status: .pending, error: error,
                   attempts: job.attempts, runAfter: runAfter)
    }

    private func finish(
        _ job: Job, status: JobStatus, error: String?, attempts: Int? = nil
    ) throws {
        try update(job, status: status, error: error,
                   attempts: attempts ?? job.attempts, runAfter: job.runAfter)
    }

    private func update(
        _ job: Job, status: JobStatus, error: String?, attempts: Int, runAfter: Date
    ) throws {
        try vault.pool.write { db in
            // The job may have been purged with its entry mid-run; that wins.
            guard var current = try Job.fetchOne(db, key: job.id) else { return }
            current.status = status
            current.lastError = error
            current.attempts = attempts
            current.runAfter = runAfter
            current.updatedAt = Date()
            try current.update(db)
        }
    }
}
