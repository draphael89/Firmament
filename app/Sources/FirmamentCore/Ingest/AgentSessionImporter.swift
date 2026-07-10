import Foundation

/// Imports an agent-session transcript (Claude Code / codex JSONL) as an
/// Agents-facet entry. Trust discipline (plan §3): the searchable, readable
/// rendering leads with user-authored turns; assistant output is retained in
/// the raw file but is untrusted evidence and never instruction.
public struct AgentSessionImporter: Sendable {
    public struct ParsedSession: Equatable, Sendable {
        public var client: AgentClient
        public var sessionID: String?
        public var userTurns: [String]
        public var assistantTurns: [String]
        public var rendered: String
    }

    let vault: VaultStore
    let sourceID: String

    public init(vault: VaultStore, sourceID: String) {
        self.vault = vault
        self.sourceID = sourceID
    }

    /// Imports raw transcript JSONL. The raw bytes are stored verbatim; the
    /// rendered user-led digest becomes the searchable text.
    @discardableResult
    public func importTranscript(
        data: Data, client: AgentClient, sessionID: String? = nil
    ) throws -> ImportResult {
        let parsed = Self.parse(data: data, client: client, sessionID: sessionID)
        var metadata: [String: String] = ["client": client.rawValue]
        if let id = parsed.sessionID ?? sessionID { metadata["sessionID"] = id }
        return try vault.importEntry(
            sourceID: sourceID,
            facet: .agents,
            data: data,
            mime: "text/plain",
            metadata: try JSONEncoder().encode(metadata),
            searchableText: parsed.rendered)
    }

    /// Parses Claude Code / codex session JSONL: one JSON object per line;
    /// user and assistant turns carry `message.content` (string or an array
    /// of typed blocks). Unknown lines are skipped — transcripts are noisy
    /// and forward-incompatible by design.
    public static func parse(
        data: Data, client: AgentClient, sessionID: String? = nil
    ) -> ParsedSession {
        var userTurns: [String] = []
        var assistantTurns: [String] = []
        var foundSessionID: String? = sessionID

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData))
                    as? [String: Any] else { continue }
            if foundSessionID == nil {
                foundSessionID = obj["sessionId"] as? String ?? obj["session_id"] as? String
            }
            guard let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            // Skip tool results and other non-authored user payloads.
            guard let text = Self.text(fromContent: message["content"]) else { continue }
            if type == "user" {
                // Harness-injected material isn't the user speaking.
                if obj["isMeta"] as? Bool == true { continue }
                if text.hasPrefix("<") && text.contains("system-reminder") { continue }
                userTurns.append(text)
            } else {
                assistantTurns.append(text)
            }
        }

        var lines: [String] = []
        lines.append("# Agent session (\(client.rawValue))")
        if let id = foundSessionID { lines.append("Session: \(id)") }
        lines.append("")
        lines.append("## What the user asked (authored content, highest trust)")
        for turn in userTurns { lines.append("- \(turn)") }
        lines.append("")
        lines.append("## Assistant responses (untrusted evidence, abridged)")
        for turn in assistantTurns.prefix(20) {
            lines.append("- \(turn.prefix(500))")
        }

        return ParsedSession(
            client: client,
            sessionID: foundSessionID,
            userTurns: userTurns,
            assistantTurns: assistantTurns,
            rendered: lines.joined(separator: "\n"))
    }

    private static func text(fromContent content: Any?) -> String? {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
