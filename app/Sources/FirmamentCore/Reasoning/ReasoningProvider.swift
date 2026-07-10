import Foundation

/// One structured-output request to a reasoning model.
public struct ReasoningRequest: Sendable {
    public var prompt: String
    public var model: String
    public var effort: String?
    /// JSON Schema the reply must match (codex app-server enforces natively).
    public var outputSchema: Data?

    public init(prompt: String, model: String, effort: String? = nil,
                outputSchema: Data? = nil) {
        self.prompt = prompt; self.model = model
        self.effort = effort; self.outputSchema = outputSchema
    }
}

/// Failure taxonomy the job queue acts on (plan §11: outages degrade
/// gracefully — jobs wait, they don't burn attempts on provider downtime).
public enum ReasoningError: Error, Sendable {
    /// Subscription window exhausted; retry after the given date if known.
    case usageLimitExceeded(retryAfter: Date?)
    /// Auth needs the operator (surfaces as a notification, never a stall).
    case authExpired(String)
    /// Provider process/protocol trouble — retryable.
    case providerUnavailable(String)
    /// The model answered but not in the required shape.
    case invalidOutput(String)
    /// The turn failed for a model-side reason.
    case turnFailed(String)
}

/// The seam every intelligence call goes through (plan §4): codex app-server
/// under subscription auth today, a local model tomorrow.
public protocol ReasoningProvider: Sendable {
    /// Returns the final agent message text (JSON when outputSchema is set).
    func complete(_ request: ReasoningRequest) async throws -> String
}
