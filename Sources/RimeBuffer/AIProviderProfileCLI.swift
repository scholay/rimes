import Foundation

/// Narrow, terminal-safe setup surface for a Provider credential. It exists
/// for first-run configuration before the input-method UI has been rebuilt;
/// it deliberately accepts the key only from protected interactive stdin and
/// never prints it, an endpoint, a model list, or a server response body.
enum AIProviderProfileCLI {
    static func handleIfRequested(arguments: [String]) -> Int? {
        if arguments.contains("provider-config-openrouter") {
            return configureOpenRouter()
        }
        if arguments.contains("provider-verify-openrouter") {
            return verifyOpenRouterCredential()
        }
        if arguments.contains("provider-profiles-status") {
            return printRedactedStatus()
        }
        return nil
    }

    private static func configureOpenRouter() -> Int {
        // `readLine` consumes exactly one TTY line. The caller disables echo;
        // do not add a prompt because it could encourage copy/paste into logs.
        guard let enteredKey = readLine(strippingNewline: true), !enteredKey.isEmpty else {
            writeError("OpenRouter credential was not saved\n")
            return 2
        }
        do {
            let store = AIProviderProfileCatalogStore.shared
            let catalog = try store.loadMigratingLegacyOpenAICompatibleIfNeeded()
            let profile = mergedOpenRouterProfile(from: catalog)
            _ = try store.upsert(profile, secretUpdate: .set(enteredKey))
            print("OpenRouter Provider saved; Jev Latest is available as a native Decisions route")
            return 0
        } catch {
            writeError("OpenRouter credential could not be saved\n")
            return 1
        }
    }

    private static func verifyOpenRouterCredential() -> Int {
        do {
            let store = AIProviderProfileCatalogStore.shared
            let catalog = try store.loadMigratingLegacyOpenAICompatibleIfNeeded()
            guard let profile = openRouterProfile(in: catalog),
                  let route = profile.routes.first(where: { route in
                      route.adapter == .openRouterDecisions
                          && route.isEnabled
                          && route.hasSelectedModel
                  }),
                  let reference = profile.reference(for: route.id) else {
                writeError("OpenRouter Provider is not configured\n")
                return 2
            }
            let resolved = try store.resolve(reference, requiresAPIKey: true)
            guard let apiKey = resolved.apiKey, !apiKey.isEmpty else {
                writeError("OpenRouter Provider is not configured\n")
                return 2
            }
            guard let keyURL = URL(string: "https://openrouter.ai/api/v1/key"),
                  let modelsURL = URL(string:
                    "https://openrouter.ai/api/v1/models?output_modalities=decisions"
                  ) else {
                return 1
            }
            guard let keyResponse = authorizedGET(keyURL, apiKey: apiKey),
                  (200...299).contains(keyResponse.statusCode),
                  let modelsResponse = authorizedGET(modelsURL, apiKey: apiKey),
                  (200...299).contains(modelsResponse.statusCode),
                  containsKnownJevRoute(modelsResponse.data) else {
                writeError("OpenRouter credential verification failed\n")
                return 1
            }
            print("OpenRouter credential and model catalog verification: OK")
            return 0
        } catch {
            writeError("OpenRouter credential verification failed\n")
            return 1
        }
    }

    private static func printRedactedStatus() -> Int {
        do {
            let statuses = try AIProviderProfileCatalogStore.shared.redactedStatuses()
            let ready = statuses.filter { $0.isEnabled }.count
            print("Provider profiles: \(ready) enabled")
            return 0
        } catch {
            writeError("Provider profiles are unavailable\n")
            return 1
        }
    }

    /// Performs a bounded, no-billing GET with a private credential. Neither
    /// the request header nor the response body is ever emitted or persisted.
    private static func authorizedGET(
        _ url: URL,
        apiKey: String
    ) -> (statusCode: Int, data: Data)? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        var statusCode: Int?
        var responseData = Data()
        let task = session.dataTask(with: request) { data, response, _ in
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
        guard !timedOut, let statusCode else { return nil }
        return (statusCode, responseData)
    }

    private static func containsKnownJevRoute(_ data: Data) -> Bool {
        guard data.count <= 2 * 1_024 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let models = object["data"] as? [[String: Any]] else {
            return false
        }
        return models.contains { model in
            guard let id = model["id"] as? String else { return false }
            return id == "~typesafe/jev-latest" || id == "typesafe/jev-1.13"
        }
    }

    private static func mergedOpenRouterProfile(
        from catalog: AIProviderProfileCatalog
    ) -> AIProviderProfile {
        guard var profile = openRouterProfile(in: catalog) else {
            return AIProviderProfile.openRouter()
        }
        let template = AIProviderProfile.openRouter(id: profile.id)
        guard let templateDecision = template.routes.first(where: {
            $0.adapter == .openRouterDecisions
        }) else {
            return profile
        }
        if let index = profile.routes.firstIndex(where: {
            $0.adapter == .openRouterDecisions
        }) {
            var route = profile.routes[index]
            route.displayName = templateDecision.displayName
            route.modelID = templateDecision.modelID
            route.endpointOverride = templateDecision.endpointOverride
            route.documentationURL = templateDecision.documentationURL
            route.capabilities.formUnion(templateDecision.capabilities)
            route.isEnabled = true
            profile.routes[index] = route
        } else {
            profile.routes.append(templateDecision)
        }
        profile.requiresAPIKey = true
        profile.isEnabled = true
        return profile
    }

    private static func openRouterProfile(
        in catalog: AIProviderProfileCatalog
    ) -> AIProviderProfile? {
        catalog.profiles.first { profile in
            URLComponents(string: profile.baseURL)?.host?.lowercased() == "openrouter.ai"
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
