import Darwin
import Foundation

/// Private-store regression coverage for the multi-provider migration. The
/// fixture keys are synthetic and this smoke never touches a user's profile.
func runAIProviderProfilesSmokeTest() -> Bool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RimeBuffer-Provider-Smoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        let legacyStore = OpenAICompatibleConfigurationStore(rootDirectory: root)
        try legacyStore.save(OpenAICompatibleConfiguration(
            baseURL: "https://api.cometapi.com/v1",
            model: "comet-smoke-model",
            apiKey: "synthetic-comet-key"
        ))
        let store = AIProviderProfileCatalogStore(
            rootDirectory: root,
            legacyConfigurationStore: legacyStore
        )
        let migrated = try store.loadMigratingLegacyOpenAICompatibleIfNeeded()
        guard let comet = migrated.profile(
            id: AIProviderProfile.legacyOpenAICompatibleID
        ), comet.displayName == "CometAPI",
              comet.routes.count == 1,
              comet.routes[0].modelID == "comet-smoke-model",
              try store.secretStore.hasStoredAPIKey(for: comet.id) else {
            return false
        }

        let openRouter = AIProviderProfile.openRouter()
        let savedOpenRouter = try store.upsert(
            openRouter,
            secretUpdate: .set("synthetic-openrouter-key")
        )
        guard savedOpenRouter.routes.contains(where: {
            $0.adapter == .openRouterDecisions
                && $0.modelID == "~typesafe/jev-latest"
                && $0.capabilities.contains(.decision)
                && !$0.capabilities.contains(.textGeneration)
        }), !migrated.bindings.contains(where: { $0.use == .primaryText }) else {
            return false
        }

        guard let chat = savedOpenRouter.routes.first(where: {
            $0.adapter == .openAIChatCompletions
        }), !chat.isEnabled else {
            return false
        }
        guard let decisions = savedOpenRouter.routes.first(where: {
            $0.adapter == .openRouterDecisions
        }), let reference = savedOpenRouter.reference(for: decisions.id) else {
            return false
        }
        let resolved = try store.resolve(reference, requiresAPIKey: true)
        guard resolved.route.adapter == .openRouterDecisions,
              resolved.apiKey == "synthetic-openrouter-key" else {
            return false
        }

        var edited = savedOpenRouter
        edited.displayName = "OpenRouter edited"
        _ = try store.upsert(edited)
        do {
            _ = try store.resolve(reference)
            return false
        } catch AIProviderProfileStoreError.staleRoute {
            // Required: an old request/thread can never switch to edited state.
        }

        var info = stat()
        guard lstat(store.catalogURL.path, &info) == 0,
              (info.st_mode & 0o777) == 0o600 else {
            return false
        }
        let secretURL = store.secretStore.directoryURL.appendingPathComponent(
            "\(savedOpenRouter.id.uuidString.lowercased()).json",
            isDirectory: false
        )
        guard lstat(secretURL.path, &info) == 0,
              (info.st_mode & 0o777) == 0o600 else {
            return false
        }
        return true
    } catch {
        return false
    }
}
