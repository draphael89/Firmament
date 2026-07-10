import Foundation
import GRDB

// MARK: - Enums

/// Provenance facet, assigned by origin (plan §3). One primary facet per entry.
public enum Facet: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case selfFacet = "self"
    case others
    case agents
}

public enum SourceKind: String, Codable, Sendable, DatabaseValueConvertible {
    case capture            // in-app text/voice capture
    case inbox              // watched iCloud Drive folder
    case granola
    case claudeCode = "claude_code"
    case codex
    case migration          // gbrain corpus / psyche.md seed import
}

public enum AssertionKind: String, Codable, Sendable, DatabaseValueConvertible {
    case fact, value, preference, goal, constraint
}

/// Trust status of a profile assertion (plan §5). Deletion downgrades:
/// remaining evidence → tentative; none → retracted.
public enum AssertionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case tentative, supported, verified, conflicted, retracted
}

public enum EvidenceStance: String, Codable, Sendable, DatabaseValueConvertible {
    case supports, contradicts
}

public enum QuestionStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case open, answered, snoozed, dismissed, expired
}

public enum AnalysisStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running, succeeded, failed
}

/// Job lifecycle (plan §4): at-least-once with idempotency keys; failures are
/// either retryable (bounded backoff) or terminal and *visible*.
public enum JobStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case pending, running, failedRetryable = "failed_retryable",
         failedTerminal = "failed_terminal", done, canceled
}

public enum AgentClient: String, Codable, Sendable, DatabaseValueConvertible {
    case claudeCode = "claude_code"
    case codex
}

// MARK: - Records

public struct Source: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source"
    public var id: String
    public var kind: SourceKind
    public var name: String
    public var config: Data?
    public var cursor: String?
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), kind: SourceKind,
                name: String, config: Data? = nil, cursor: String? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.name = name
        self.config = config; self.cursor = cursor; self.createdAt = createdAt
    }
}

public struct Entry: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "entry"
    public var id: String
    public var sourceID: String
    public var facet: Facet
    /// Structural egress boundary (plan §4): local-only entries are excluded
    /// from provider payloads, packets, and projections at query construction.
    public var localOnly: Bool
    public var createdAt: Date
    public var trashedAt: Date?
    public var currentRevisionID: String?

    public init(id: String = UUID().uuidString.lowercased(), sourceID: String,
                facet: Facet, localOnly: Bool = false, createdAt: Date = Date(),
                trashedAt: Date? = nil, currentRevisionID: String? = nil) {
        self.id = id; self.sourceID = sourceID; self.facet = facet
        self.localOnly = localOnly; self.createdAt = createdAt
        self.trashedAt = trashedAt; self.currentRevisionID = currentRevisionID
    }
}

/// One immutable imported version of an entry. Raw truth: never mutated,
/// only superseded by a new revision (explicit ancestry via parentRevisionID).
public struct EntryRevision: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "entryRevision"
    public var id: String
    public var entryID: String
    public var seq: Int
    public var parentRevisionID: String?
    /// SHA-256 of the raw imported bytes; also the content-store key.
    public var contentHash: String
    public var mime: String
    public var metadata: Data?
    public var importedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), entryID: String,
                seq: Int, parentRevisionID: String? = nil, contentHash: String,
                mime: String, metadata: Data? = nil, importedAt: Date = Date()) {
        self.id = id; self.entryID = entryID; self.seq = seq
        self.parentRevisionID = parentRevisionID; self.contentHash = contentHash
        self.mime = mime; self.metadata = metadata; self.importedAt = importedAt
    }
}

public struct TranscriptSegment: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transcriptSegment"
    public var id: String
    public var revisionID: String
    public var idx: Int
    public var speaker: String?
    public var startMS: Int?
    public var endMS: Int?
    public var text: String

    public init(id: String = UUID().uuidString.lowercased(), revisionID: String,
                idx: Int, speaker: String? = nil, startMS: Int? = nil,
                endMS: Int? = nil, text: String) {
        self.id = id; self.revisionID = revisionID; self.idx = idx
        self.speaker = speaker; self.startMS = startMS; self.endMS = endMS
        self.text = text
    }
}

/// Audit of one provider call: model, prompt version, and output — derived
/// data is reprocessable, so runs accumulate rather than overwrite.
public struct AnalysisRun: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysisRun"
    public var id: String
    public var revisionID: String
    public var provider: String
    public var model: String
    public var promptVersion: String
    public var status: AnalysisStatus
    public var output: Data?
    public var error: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), revisionID: String,
                provider: String, model: String, promptVersion: String,
                status: AnalysisStatus, output: Data? = nil, error: String? = nil,
                startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.revisionID = revisionID; self.provider = provider
        self.model = model; self.promptVersion = promptVersion
        self.status = status; self.output = output; self.error = error
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

/// The *current* human-readable projection of an entry (title, description,
/// classification) — always rebuildable from analysis runs.
public struct EntryProjection: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "entryProjection"
    public var entryID: String
    public var title: String
    public var summary: String
    public var people: Data?
    public var projects: Data?
    public var topics: Data?
    public var analysisRunID: String?
    public var updatedAt: Date

    public init(entryID: String, title: String, summary: String,
                people: Data? = nil, projects: Data? = nil, topics: Data? = nil,
                analysisRunID: String? = nil, updatedAt: Date = Date()) {
        self.entryID = entryID; self.title = title; self.summary = summary
        self.people = people; self.projects = projects; self.topics = topics
        self.analysisRunID = analysisRunID; self.updatedAt = updatedAt
    }
}

public struct ProfileAssertion: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profileAssertion"
    public var id: String
    public var kind: AssertionKind
    public var text: String
    public var status: AssertionStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), kind: AssertionKind,
                text: String, status: AssertionStatus = .tentative,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// Exact source span grounding an assertion. Assertions never exist without
/// evidence rows; deletion of evidence downgrades the assertion (plan §4).
public struct AssertionEvidence: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "assertionEvidence"
    public var id: String
    public var assertionID: String
    public var revisionID: String
    public var quote: String
    public var spanStart: Int?
    public var spanEnd: Int?
    public var stance: EvidenceStance
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), assertionID: String,
                revisionID: String, quote: String, spanStart: Int? = nil,
                spanEnd: Int? = nil, stance: EvidenceStance = .supports,
                createdAt: Date = Date()) {
        self.id = id; self.assertionID = assertionID; self.revisionID = revisionID
        self.quote = quote; self.spanStart = spanStart; self.spanEnd = spanEnd
        self.stance = stance; self.createdAt = createdAt
    }
}

/// One deepening question per entry, or none — abstention is first-class.
public struct Question: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "question"
    public var id: String
    public var entryID: String
    public var text: String
    public var rationale: String?
    public var status: QuestionStatus
    public var evidence: Data?
    public var createdAt: Date
    public var resolvedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), entryID: String,
                text: String, rationale: String? = nil,
                status: QuestionStatus = .open, evidence: Data? = nil,
                createdAt: Date = Date(), resolvedAt: Date? = nil) {
        self.id = id; self.entryID = entryID; self.text = text
        self.rationale = rationale; self.status = status; self.evidence = evidence
        self.createdAt = createdAt; self.resolvedAt = resolvedAt
    }
}

public struct Job: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
    public var id: String
    public var kind: String
    /// entryRevision + stage + prompt version — the at-least-once dedupe key.
    public var idempotencyKey: String
    public var entryID: String?
    public var payload: Data?
    public var status: JobStatus
    public var attempts: Int
    public var lastError: String?
    public var runAfter: Date
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString.lowercased(), kind: String,
                idempotencyKey: String, entryID: String? = nil,
                payload: Data? = nil, status: JobStatus = .pending,
                attempts: Int = 0, lastError: String? = nil,
                runAfter: Date = Date(), createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.idempotencyKey = idempotencyKey
        self.entryID = entryID; self.payload = payload; self.status = status
        self.attempts = attempts; self.lastError = lastError
        self.runAfter = runAfter; self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentSession: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agentSession"
    public var id: String
    public var client: AgentClient
    public var task: String?
    public var packet: Data?
    public var outcome: Data?
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), client: AgentClient,
                task: String? = nil, packet: Data? = nil, outcome: Data? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil) {
        self.id = id; self.client = client; self.task = task
        self.packet = packet; self.outcome = outcome
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}
