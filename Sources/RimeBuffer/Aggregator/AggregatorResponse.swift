import Foundation

/// What the dialogue area draws. Deliberately four cases: these are the ones
/// RIMES owns and can render for any model without knowing which model it is.
/// Anything richer belongs in the raw pane, where a vendor's own envelope
/// cannot break the surface it is shown in.
enum AggregatorRenderFormat: String, Equatable {
    case plain
    case markdown
    case json
    /// One or more artifact URLs. Images draw inline; video and audio get a
    /// link and an open action, because an embedded player is where a pane
    /// like this stops being maintainable.
    case artifactURL
}

struct AggregatorRenderedResponse: Equatable {
    let format: AggregatorRenderFormat
    let text: String
    let artifacts: [String]
    /// Present when the reply is a job receipt rather than a result.
    let taskID: String?

    var isPendingJob: Bool { taskID != nil && artifacts.isEmpty }
}

enum AggregatorResponseReader {
    private static let artifactKeys = ["url", "video_url", "audio_url",
                                       "image_url", "download_url", "output"]
    private static let taskKeys = ["task_id", "taskId", "id", "job_id", "jobId"]

    /// Classifies a reply without consulting the model, its type, or its
    /// vendor — none of which the catalog reports reliably. Shape alone
    /// decides, so a model the catalog knows nothing about still renders.
    static func read(_ payload: Data,
                     adapter: AggregatorAdapter) -> AggregatorRenderedResponse {
        guard let root = try? JSONSerialization.jsonObject(with: payload) else {
            let text = String(decoding: payload, as: UTF8.self)
            return AggregatorRenderedResponse(format: .plain,
                                              text: text,
                                              artifacts: [],
                                              taskID: nil)
        }
        let artifacts = artifactURLs(in: root)
        if !artifacts.isEmpty {
            return AggregatorRenderedResponse(format: .artifactURL,
                                              text: prettyPrinted(root, payload: payload),
                                              artifacts: artifacts,
                                              taskID: taskID(in: root))
        }
        if let assistant = assistantText(in: root), !assistant.isEmpty {
            return AggregatorRenderedResponse(
                format: looksLikeMarkdown(assistant) ? .markdown : .plain,
                text: assistant,
                artifacts: [],
                taskID: nil
            )
        }
        // A submit that answered with nothing but an identifier is a job
        // receipt; the pane must show it as working, not as finished-and-empty.
        if adapter.deliveryMode == .asyncJob, let id = taskID(in: root) {
            return AggregatorRenderedResponse(format: .json,
                                              text: prettyPrinted(root, payload: payload),
                                              artifacts: [],
                                              taskID: id)
        }
        return AggregatorRenderedResponse(format: .json,
                                          text: prettyPrinted(root, payload: payload),
                                          artifacts: [],
                                          taskID: taskID(in: root))
    }

    /// OpenAI chat, Responses, Anthropic Messages and Gemini all bury the
    /// assistant's prose at a different depth. Walk the known shapes rather
    /// than asking the caller which provider it used.
    static func assistantText(in root: Any) -> String? {
        guard let object = root as? [String: Any] else { return nil }
        if let choices = object["choices"] as? [[String: Any]] {
            let joined = choices.compactMap { choice -> String? in
                if let message = choice["message"] as? [String: Any] {
                    return flattenContent(message["content"])
                }
                return flattenContent(choice["text"])
            }.joined()
            if !joined.isEmpty { return joined }
        }
        // Anthropic Messages: top-level content blocks.
        if let content = object["content"] as? [[String: Any]] {
            let joined = content.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        // Responses API: output items carrying content parts.
        if let output = object["output"] as? [[String: Any]] {
            let joined = output.compactMap { item -> String? in
                flattenContent(item["content"])
            }.joined()
            if !joined.isEmpty { return joined }
        }
        if let text = object["output_text"] as? String, !text.isEmpty {
            return text
        }
        // Gemini: candidates → content → parts.
        if let candidates = object["candidates"] as? [[String: Any]] {
            let joined = candidates.compactMap { candidate -> String? in
                guard let content = candidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    return nil
                }
                return parts.compactMap { $0["text"] as? String }.joined()
            }.joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func flattenContent(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        guard let parts = value as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { part -> String? in
            part["text"] as? String
        }.joined()
        return joined.isEmpty ? nil : joined
    }

    static func artifactURLs(in root: Any) -> [String] {
        var found: [String] = []
        walk(root) { key, value in
            guard artifactKeys.contains(key), let text = value as? String,
                  text.hasPrefix("http") else { return }
            if !found.contains(text) { found.append(text) }
        }
        return found
    }

    static func taskID(in root: Any) -> String? {
        guard let object = root as? [String: Any] else { return nil }
        for key in taskKeys {
            if let value = object[key] as? String, !value.isEmpty { return value }
            if let value = object[key] as? Int { return String(value) }
        }
        if let data = object["data"] as? [String: Any] { return taskID(in: data) }
        return nil
    }

    private static func walk(_ node: Any, visit: (String, Any) -> Void) {
        if let object = node as? [String: Any] {
            for (key, value) in object {
                visit(key, value)
                walk(value, visit: visit)
            }
        } else if let array = node as? [Any] {
            for value in array { walk(value, visit: visit) }
        }
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        text.contains("```") || text.contains("\n- ") || text.contains("\n# ")
            || text.contains("\n## ") || text.contains("**")
    }

    private static func prettyPrinted(_ root: Any, payload: Data) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return String(decoding: payload, as: UTF8.self) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The raw pane is worth keeping across restarts — a saved response is what
/// answers "why did this model do that" a week later. Inline base64 is not:
/// one image reply can carry megabytes, and the Mailbox store is a text
/// transcript, not a blob store.
enum AggregatorRawBodyRetention {
    static let maximumBytes = 256 * 1024
    static let elidedMarker = "\"<base64 elided by RIMES>\""

    static func retained(_ body: String,
                         maximumBytes: Int = maximumBytes) -> String {
        var text = elideBase64(body)
        guard text.utf8.count > maximumBytes else { return text }
        var truncated = Data(text.utf8).prefix(maximumBytes)
        // Never split a UTF-8 scalar: back off until the prefix decodes.
        while !truncated.isEmpty,
              String(data: truncated, encoding: .utf8) == nil {
            truncated = truncated.dropLast()
        }
        text = String(decoding: truncated, as: UTF8.self)
        return text + "\n… 响应体已截断（超过 \(maximumBytes / 1024) KB）"
    }

    /// Replaces the value of any `b64_json`/`b64`/`data` field that holds a
    /// long base64 payload, leaving the surrounding envelope readable.
    static func elideBase64(_ body: String) -> String {
        let keys = ["b64_json", "b64", "base64", "image_base64"]
        var result = body
        for key in keys {
            var searchRange = result.startIndex..<result.endIndex
            while let keyRange = result.range(of: "\"\(key)\"",
                                              range: searchRange) {
                guard let colon = result[keyRange.upperBound...]
                        .firstIndex(of: ":"),
                      let openQuote = result[result.index(after: colon)...]
                        .firstIndex(of: "\"") else {
                    searchRange = keyRange.upperBound..<result.endIndex
                    break
                }
                var cursor = result.index(after: openQuote)
                while cursor < result.endIndex, result[cursor] != "\"" {
                    cursor = result.index(after: cursor)
                }
                guard cursor < result.endIndex else { break }
                let valueRange = openQuote...cursor
                let length = result.distance(from: openQuote, to: cursor)
                guard length > 256 else {
                    searchRange = result.index(after: cursor)..<result.endIndex
                    continue
                }
                result.replaceSubrange(valueRange, with: elidedMarker)
                guard let resumeIndex = result.range(of: elidedMarker)?.upperBound,
                      resumeIndex < result.endIndex else { return result }
                searchRange = resumeIndex..<result.endIndex
            }
        }
        return result
    }
}
