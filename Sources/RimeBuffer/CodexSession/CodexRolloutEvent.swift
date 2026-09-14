import Foundation

/// One entry of a codex session as the CLI records it. Codex writes a durable
/// JSONL rollout per session under `~/.codex/sessions/<yyyy>/<mm>/<dd>/`,
/// carrying the whole run: what it said, what it ran, what it changed. The
/// text provider reads one field of this stream (`AgentMessage`) and drops the
/// rest; a session pane needs all of it.
enum CodexRolloutItem: Equatable {
    /// Prose the model wrote for the user.
    case agentMessage(text: String, phase: String?)
    /// The reasoning summary. `raw_content` and `encrypted_content` are
    /// deliberately not modelled: one is usually absent, the other is opaque.
    case reasoning(summary: String)
    case userMessage(text: String)
    case plan(text: String)
    case commandExecution(command: String,
                          cwd: String?,
                          exitCode: Int?,
                          status: String?)
    case fileChange(paths: [String], status: String?)
    case toolCall(server: String?, tool: String, status: String?)
    /// Recorded so the pane can show that something happened without
    /// pretending to understand it.
    case other(kind: String)

    var kindLabel: String {
        switch self {
        case .agentMessage: return "AgentMessage"
        case .reasoning: return "Reasoning"
        case .userMessage: return "UserMessage"
        case .plan: return "Plan"
        case .commandExecution: return "CommandExecution"
        case .fileChange: return "FileChange"
        case .toolCall: return "ToolCall"
        case let .other(kind): return kind
        }
    }
}

struct CodexRolloutEvent: Equatable {
    let ordinal: Int?
    let timestamp: String?
    let item: CodexRolloutItem
}

/// Session identity, taken from the rollout's own header rather than from the
/// filename, so the pane can prove which run it is following.
struct CodexSessionHeader: Equatable {
    let sessionID: String
    let cwd: String?
    let cliVersion: String?
    let model: String?
}

enum CodexRolloutParser {
    /// Reads one JSONL line. Unknown records return nil rather than throwing:
    /// a rollout written by a newer CLI must not stop the pane, and codex adds
    /// item types over time.
    static func event(from line: Data) -> CodexRolloutEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
              let payload = root["payload"] as? [String: Any] else { return nil }
        let ordinal = root["ordinal"] as? Int
        let timestamp = root["timestamp"] as? String
        guard let item = item(fromPayload: payload) else { return nil }
        return CodexRolloutEvent(ordinal: ordinal,
                                 timestamp: timestamp,
                                 item: item)
    }

    static func header(from line: Data) -> CodexSessionHeader? {
        guard let root = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any] else { return nil }
        let sessionID = (payload["session_id"] as? String)
            ?? (payload["id"] as? String)
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return CodexSessionHeader(
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            cliVersion: payload["cli_version"] as? String,
            model: (payload["model_provider"] as? String)
        )
    }

    private static func item(fromPayload payload: [String: Any])
        -> CodexRolloutItem? {
        // The high-level item stream is the one to read. `response_item`
        // records carry the same turns in raw model form, including developer
        // instructions that must never reach a pane the user is reading.
        guard payload["type"] as? String == "item_completed",
              let raw = payload["item"] as? [String: Any],
              let kind = raw["type"] as? String else { return nil }
        switch kind {
        case "AgentMessage":
            let text = concatenatedText(raw["content"])
            guard !text.isEmpty else { return nil }
            return .agentMessage(text: text, phase: raw["phase"] as? String)
        case "Reasoning":
            let summary = concatenatedText(raw["summary_text"])
            guard !summary.isEmpty else { return nil }
            return .reasoning(summary: summary)
        case "UserMessage":
            let text = concatenatedText(raw["content"])
            guard !text.isEmpty else { return nil }
            return .userMessage(text: text)
        case "Plan":
            guard let text = raw["text"] as? String, !text.isEmpty else {
                return nil
            }
            return .plan(text: text)
        case "CommandExecution":
            let command: String
            if let parts = raw["command"] as? [String] {
                command = parts.joined(separator: " ")
            } else {
                command = raw["command"] as? String ?? ""
            }
            guard !command.isEmpty else { return nil }
            return .commandExecution(command: command,
                                     cwd: raw["cwd"] as? String,
                                     exitCode: raw["exit_code"] as? Int,
                                     status: raw["status"] as? String)
        case "FileChange":
            let paths = (raw["changes"] as? [String: Any])?.keys.sorted() ?? []
            return .fileChange(paths: paths, status: raw["status"] as? String)
        case "McpToolCall", "CollabAgentToolCall":
            guard let tool = raw["tool"] as? String ?? raw["name"] as? String
            else { return .other(kind: kind) }
            return .toolCall(server: raw["server"] as? String,
                             tool: tool,
                             status: raw["status"] as? String)
        default:
            return .other(kind: kind)
        }
    }

    /// Content arrives as an array of typed parts whose text key is uniform
    /// even though the part type is not (`Text`, `text`, `summary_text`).
    private static func concatenatedText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let parts = value as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            return (part as? [String: Any])?["text"] as? String
        }.joined()
    }
}

/// What may be rewritten into another language, and what may not.
///
/// Translating a codex session is not translating its screen. Commands, paths
/// and diffs are not prose — rewriting `git status --short` produces something
/// that looks like a command and is not one, and a translated diff no longer
/// applies. Only what the model wrote for a human reader is eligible.
enum CodexEventTranslationRules {
    static func translatableText(in item: CodexRolloutItem) -> String? {
        switch item {
        case let .agentMessage(text, _): return text
        case let .reasoning(summary): return summary
        case let .plan(text): return text
        case .userMessage:
            // The user wrote it; they can already read it.
            return nil
        case .commandExecution, .fileChange, .toolCall, .other:
            return nil
        }
    }

    static func isTranslatable(_ item: CodexRolloutItem) -> Bool {
        translatableText(in: item) != nil
    }
}
