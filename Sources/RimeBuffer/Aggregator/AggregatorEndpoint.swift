import Foundation

/// How a request's result arrives. The dialogue area needs this before the
/// first byte: a video submission is silent for a minute or more, and a pane
/// that only knows "streaming" and "done" renders that silence as a hang.
enum AggregatorDeliveryMode: String, Equatable {
    /// Server-sent events, token by token.
    case streaming
    /// One response body containing the finished result.
    case immediate
    /// Submit returns a job; the artifact is collected by a later request.
    case asyncJob
    /// A socket upgrade this surface does not speak.
    case unsupported
}

/// The adapter that knows how to build a body for an endpoint and read its
/// reply. Resolution is by `(method, path)` and never by the catalog's family
/// name: the published names include aliases (`openai` / `openai-chat`),
/// case and separator drift (`image-edit` / `image_editing`), and at least one
/// typo (`seedacne` for seedance) that all denote the same endpoint.
enum AggregatorAdapter: String, Equatable, CaseIterable {
    case chatCompletions
    case responses
    case anthropicMessages
    case geminiGenerateContent
    case imageGeneration
    case imageEdit
    case videoSubmit
    case videoResult
    case videoContent
    case vendorSubmit
    case realtime
    /// No adapter claims it. The request is sent as typed and the reply is
    /// shown verbatim, which is the whole point of keeping a raw pane.
    case rawPassthrough

    var deliveryMode: AggregatorDeliveryMode {
        switch self {
        case .chatCompletions, .responses, .anthropicMessages,
             .geminiGenerateContent:
            return .streaming
        case .imageGeneration, .imageEdit, .videoResult, .videoContent:
            return .immediate
        case .videoSubmit, .vendorSubmit:
            return .asyncJob
        case .realtime:
            return .unsupported
        case .rawPassthrough:
            return .immediate
        }
    }
}

struct AggregatorEndpoint: Equatable {
    let family: String
    let method: String
    let path: String

    var adapter: AggregatorAdapter {
        AggregatorEndpointRules.adapter(method: method, path: path)
    }
}

enum AggregatorEndpointRules {
    /// Catalog records that carry only a family name — 123 of 292 models at
    /// the time of writing — still identify their endpoint unambiguously,
    /// because every such name maps onto a path some other record spells out
    /// in full. Recovering them here is the difference between supporting
    /// half the catalog and nearly all of it.
    static let pathForFamily: [String: (method: String, path: String)] = [
        "openai": ("POST", "/v1/chat/completions"),
        "openai-chat": ("POST", "/v1/chat/completions"),
        "chat": ("POST", "/v1/chat/completions"),
        "openai-response": ("POST", "/v1/responses"),
        "openai-responses": ("POST", "/v1/responses"),
        "anthropic": ("POST", "/v1/messages"),
        "anthropic-messages": ("POST", "/v1/messages"),
        "gemini": ("POST", "/v1beta/models/{model}:{operator}"),
        "nano banana": ("POST", "/v1beta/models/{model}:generateContent"),
        "openai-image": ("POST", "/v1/images/generations"),
        "image-generation": ("POST", "/v1/images/generations"),
        "image_generation": ("POST", "/v1/images/generations"),
        "doubao-image": ("POST", "/v1/images/generations"),
        "openai-image-edit": ("POST", "/v1/images/edits"),
        "image-edit": ("POST", "/v1/images/edits"),
        "image-editing": ("POST", "/v1/images/edits"),
        "image_editing": ("POST", "/v1/images/edits"),
        "openai-video": ("POST", "/v1/videos"),
        "video-create": ("POST", "/v1/videos"),
    ]

    static func adapter(method: String, path: String) -> AggregatorAdapter {
        let verb = method.uppercased()
        let route = normalizedPath(path)
        switch (verb, route) {
        case ("POST", "/v1/chat/completions"): return .chatCompletions
        case ("POST", "/v1/responses"): return .responses
        case ("POST", "/v1/messages"): return .anthropicMessages
        case ("POST", "/v1/images/generations"): return .imageGeneration
        case ("POST", "/v1/images/edits"): return .imageEdit
        case ("POST", "/v1/videos"): return .videoSubmit
        case ("GET", "/v1/videos/{task_id}"): return .videoResult
        case ("GET", "/v1/videos/{task_id}/content"): return .videoContent
        case ("GET", "/v1/realtime"): return .realtime
        default: break
        }
        if verb == "POST", route.hasPrefix("/v1beta/models/") {
            return .geminiGenerateContent
        }
        // Everything a vendor routes through its own prefix submits a job and
        // answers in its own envelope: /bria/…, /flux/…, /mj/submit/…,
        // /grok/…, /replicate/….
        if verb == "POST",
           ["/bria/", "/flux/", "/mj/", "/grok/", "/replicate/"]
            .contains(where: route.hasPrefix) {
            return .vendorSubmit
        }
        return .rawPassthrough
    }

    private static func normalizedPath(_ path: String) -> String {
        var route = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !route.hasPrefix("/") { route = "/" + route }
        while route.count > 1, route.hasSuffix("/") { route.removeLast() }
        return route
    }
}

/// Catalog paths carry `{model}`, `{models}`, `{operator}` and `{task_id}`.
/// An unfilled placeholder must never reach the network as a literal, so
/// substitution reports what is still missing instead of guessing.
enum AggregatorPathTemplate {
    static func placeholders(in path: String) -> [String] {
        var found: [String] = []
        var pending: String?
        for character in path {
            if character == "{" { pending = ""; continue }
            if character == "}" {
                if let name = pending, !name.isEmpty, !found.contains(name) {
                    found.append(name)
                }
                pending = nil
                continue
            }
            if pending != nil { pending?.append(character) }
        }
        return found
    }

    enum Expansion: Equatable {
        case expanded(String)
        /// Reported rather than guessed: a literal `{task_id}` reaching the
        /// network is a request against a path that does not exist.
        case missing([String])
    }

    static func expand(_ path: String,
                       values: [String: String]) -> Expansion {
        var missing: [String] = []
        var result = path
        for name in placeholders(in: path) {
            guard let value = values[name],
                  !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                missing.append(name)
                continue
            }
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return missing.isEmpty ? .expanded(result) : .missing(missing)
    }
}
