import Foundation

public struct ProviderConfiguration: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var model: String
    public init(id: UUID = UUID(), name: String = "", baseURL: String = "", model: String = "") { self.id = id; self.name = name; self.baseURL = baseURL; self.model = model }
    public func endpoint(_ resource: String) throws -> URL {
        guard let u = URL(string: baseURL), u.scheme == "https", let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil else { throw CoreError.invalidEndpoint }
        return u.appendingPathComponent(resource)
    }
    public var consentIdentity: String { (try? endpoint("chat/completions").absoluteString) ?? "" }
}
public enum AIAction: String, CaseIterable, Identifiable {
    case polish, rewrite, translate
    public var id: String { rawValue }
    public var title: String { switch self { case .polish: return "润色 · Polish"; case .rewrite: return "改写 · Rewrite"; case .translate: return "翻译 · Translate" } }
    public func instruction(language: String) -> String {
        switch self {
        case .polish: return "Polish the supplied text without changing its meaning. Return only the polished text."
        case .rewrite: return "Rewrite the supplied text clearly and naturally without adding facts. Return only the rewritten text."
        case .translate: return "Translate the supplied text into \(language). Return only the translation."
        }
    }
}
public enum AIRequest {
    public static func make(provider: ProviderConfiguration, key: String, source: String, action: AIAction, language: String, consent: String) throws -> URLRequest {
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoreError.invalidEndpoint }
        let url = try provider.endpoint("chat/completions")
        guard consent == provider.consentIdentity else { throw CoreError.noConsent }
        guard source.utf8.count <= 64 * 1024 else { throw CoreError.tooLarge }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": provider.model, "stream": true, "messages": [["role": "system", "content": action.instruction(language: language)], ["role": "user", "content": source]]])
        return request
    }
}
public struct SSETextDecoder {
    private var pending = Data()
    private var eventData = [String]()
    private var eventBytes = 0
    public private(set) var text = ""
    public private(set) var finished = false
    private var successfulFinish = false
    public init() {}
    public mutating func append(_ data: Data) throws {
        guard pending.count + data.count <= 1024 * 1024, text.utf8.count <= 256 * 1024 else { throw CoreError.tooLarge }
        pending.append(data)
        while let i = pending.firstIndex(of: 10) {
            let bytes = pending[..<i]; pending.removeSubrange(...i)
            guard let s = String(data: bytes, encoding: .utf8) else { throw CoreError.incomplete }
            let line = s.hasSuffix("\r") ? String(s.dropLast()) : s
            if line.isEmpty { try event(); continue }
            if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                eventBytes += value.utf8.count + 1
                guard eventBytes <= 1024 * 1024 else { throw CoreError.tooLarge }
                eventData.append(value)
            }
        }
    }
    private mutating func event() throws {
        guard !eventData.isEmpty else { return }
        let payload = eventData.joined(separator: "\n"); eventData.removeAll(); eventBytes = 0
        if payload == "[DONE]" { guard successfulFinish else { throw CoreError.incomplete }; finished = true; return }
        guard !finished, let data = payload.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let choices = root["choices"] as? [[String: Any]] else { throw CoreError.incomplete }
        guard let first = choices.first else { return } // optional usage-only event
        if let reason = first["finish_reason"] as? String {
            guard reason == "stop" else { throw CoreError.incomplete }; successfulFinish = true
        }
        if let delta = first["delta"] as? [String: Any], let value = delta["content"] as? String { text += value }
        guard text.utf8.count <= 256 * 1024 else { throw CoreError.tooLarge }
    }
    public mutating func complete() throws -> String {
        if !pending.isEmpty { try append(Data("\n\n".utf8)) }
        try event()
        guard finished, successfulFinish, !text.isEmpty else { throw CoreError.incomplete }; return text
    }
}
/// Reject every redirect: credentials never follow redirects, including cross-origin ones.
public final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class AIClient: @unchecked Sendable {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) { makeConfiguration = configuration }
    public func generate(_ request: URLRequest, progress: @escaping @Sendable (String) async -> Void) async throws -> String {
        let config = makeConfiguration()
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreError.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var decoder = SSETextDecoder(), packet = Data(), previous = ""
        for try await byte in bytes {
            try Task.checkCancellation(); packet.append(byte)
            if byte == 10 || packet.count >= 4096 {
                try decoder.append(packet); packet.removeAll(keepingCapacity: true)
                if decoder.text != previous { previous = decoder.text; await progress(previous) }
                if decoder.finished { break }
            }
        }
        if !packet.isEmpty { try decoder.append(packet) }
        return try decoder.complete()
    }
    public func models(provider: ProviderConfiguration, key: String) async throws -> [String] {
        let config = makeConfiguration(); config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: try provider.endpoint("models"), timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CoreError.response((response as? HTTPURLResponse)?.statusCode ?? 0) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1024 * 1024 else { throw CoreError.tooLarge }
            data.append(byte)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}
