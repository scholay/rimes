import Foundation

/// Explicit, no-billing model discovery for a saved Provider profile. Results
/// live only in memory for the caller; credentials and raw response bodies are
/// never logged, persisted, or included in thrown errors.
enum AIProviderModelCatalogProbeError: Error, LocalizedError {
    case profileUnavailable
    case missingAPIKey
    case invalidEndpoint
    case timedOut
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .profileUnavailable: return "Provider 配置不可用"
        case .missingAPIKey: return "该 Provider 需要 API Key"
        case .invalidEndpoint: return "Provider 模型目录地址无效"
        case .timedOut: return "模型目录查询超时"
        case .requestFailed: return "模型目录查询失败"
        case .invalidResponse: return "模型目录响应无效"
        }
    }
}

enum AIProviderModelCatalogProbe {
    static func fetch(
        profileID: UUID,
        store: AIProviderProfileCatalogStore = .shared
    ) throws -> [String] {
        let catalog = try store.loadMigratingLegacyOpenAICompatibleIfNeeded()
        guard let profile = catalog.profile(id: profileID), profile.isEnabled else {
            throw AIProviderModelCatalogProbeError.profileUnavailable
        }
        let apiKey = try store.secretStore.secret(for: profileID)?.apiKey
        if profile.requiresAPIKey && (apiKey?.isEmpty ?? true) {
            throw AIProviderModelCatalogProbeError.missingAPIKey
        }
        let url = try modelsURL(for: profile)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int?
        var transportFailed = false
        let task = session.dataTask(with: request) { data, response, error in
            transportFailed = error != nil
            if let data, data.count <= 2 * 1_024 * 1_024 {
                responseData = data
            }
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        let timedOut = semaphore.wait(timeout: .now() + 20) == .timedOut
        task.cancel()
        session.invalidateAndCancel()
        if timedOut { throw AIProviderModelCatalogProbeError.timedOut }
        guard !transportFailed,
              let statusCode,
              (200...299).contains(statusCode),
              let responseData else {
            throw AIProviderModelCatalogProbeError.requestFailed
        }
        return try parseModelIDs(responseData)
    }

    private static func modelsURL(for profile: AIProviderProfile) throws -> URL {
        guard var components = URLComponents(string: profile.baseURL),
              components.query == nil,
              components.fragment == nil else {
            throw AIProviderModelCatalogProbeError.invalidEndpoint
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/models") { path += "/models" }
        if path.isEmpty { path = "/models" }
        components.path = path
        guard let url = components.url else {
            throw AIProviderModelCatalogProbeError.invalidEndpoint
        }
        return url
    }

    private static func parseModelIDs(_ data: Data) throws -> [String] {
        guard data.count <= 2 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else {
            throw AIProviderModelCatalogProbeError.invalidResponse
        }
        var result: [String] = []
        var seen: Set<String> = []
        for entry in entries {
            guard let raw = entry["id"] as? String else { continue }
            let modelID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty,
                  modelID.utf8.count <= 200,
                  !modelID.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  seen.insert(modelID).inserted else {
                continue
            }
            result.append(modelID)
            if result.count == 500 { break }
        }
        guard !result.isEmpty else {
            throw AIProviderModelCatalogProbeError.invalidResponse
        }
        return result
    }
}
