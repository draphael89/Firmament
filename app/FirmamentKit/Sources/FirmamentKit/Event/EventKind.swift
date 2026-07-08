/// The closed dozen (SPEC §5.2). Adding a thirteenth requires a spec
/// amendment; extensibility lives inside payloads, not here.
public enum EventKind: String, CaseIterable, Sendable, Codable {
    case captureAudio = "capture.audio"
    case captureText = "capture.text"
    case transcript
    case annotation
    case assertion
    case ratification
    case distillation
    case grant
    case agentAccess = "agent.access"
    case escalation
    case tombstone
    case syncCheckpoint = "sync.checkpoint"
}

/// Sensitivity tiers (SPEC §5.4) — stamped at capture, immutable thereafter.
/// Stored as INTEGER in SQLite; rendered as a string in the canonical envelope.
public enum Tier: Int, Sendable, Codable, Comparable {
    case open = 0
    case personal = 1
    case sanctum = 2

    public var canonicalString: String {
        switch self {
        case .open: "open"
        case .personal: "personal"
        case .sanctum: "sanctum"
        }
    }

    public init?(canonicalString: String) {
        switch canonicalString {
        case "open": self = .open
        case "personal": self = .personal
        case "sanctum": self = .sanctum
        default: return nil
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Event provenance (SPEC §5.1).
public enum Author: Sendable, Equatable, Hashable {
    case human
    case dream
    case system
    case agent(grantID: String)

    public var canonicalString: String {
        switch self {
        case .human: "human"
        case .dream: "dream"
        case .system: "system"
        case .agent(let grantID): "agent:\(grantID)"
        }
    }

    public init?(canonicalString: String) {
        switch canonicalString {
        case "human": self = .human
        case "dream": self = .dream
        case "system": self = .system
        default:
            guard canonicalString.hasPrefix("agent:") else { return nil }
            let grantID = String(canonicalString.dropFirst("agent:".count))
            guard !grantID.isEmpty else { return nil }
            self = .agent(grantID: grantID)
        }
    }
}

/// Chain provenance (SPEC §5.1) — each device appends to its own chain.
public enum DeviceID: String, Sendable, Codable, CaseIterable {
    case mac
    case phone
}
