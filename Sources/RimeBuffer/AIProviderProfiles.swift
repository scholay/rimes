import Darwin
import Foundation

// MARK: - Provider catalog model

extension Notification.Name {
    /// Posted after the private profile catalog or one profile's private secret
    /// changed. The payload contains at most a profile UUID and a change kind;
    /// it deliberately never contains an endpoint, model, or credential.
    static let aiProviderProfilesDidChange = Notification.Name(
        "RimeBuffer.AIProviderProfiles.didChange"
    )
}

/// The wire protocol selected for an individual model route. A provider may
/// expose more than one of these routes while sharing one account credential.
/// Adding an enum case only describes a saved route; it must not be exposed as
/// a runnable text model until a matching request adapter exists.
enum AIProviderAdapter: String, CaseIterable, Codable, Hashable {
    case openAIChatCompletions = "openai-chat-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
    case openRouterDecisions = "openrouter-decisions"

    var displayName: String {
        switch self {
        case .openAIChatCompletions: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .openRouterDecisions: return "OpenRouter Decisions"
        }
    }

    /// The request layer owns final URL construction and must still validate
    /// the selected endpoint. This is intentionally just a route hint, not a
    /// promise that a generic endpoint supports the protocol.
    var defaultEndpointPath: String {
        switch self {
        case .openAIChatCompletions: return "chat/completions"
        case .openAIResponses: return "responses"
        case .anthropicMessages: return "messages"
        case .openRouterDecisions: return "alpha/decisions"
        }
    }

    var supportsAITextBlocks: Bool {
        switch self {
        case .openAIChatCompletions: return true
        // The catalog can represent these official protocols today; they are
        // intentionally not surfaced as ordinary text routes until the app
        // owns their separate request/stream decoders.
        case .openAIResponses, .anthropicMessages: return false
        case .openRouterDecisions: return false
        }
    }
}

/// Capabilities are descriptive filters for feature routing. They do not make
/// a route executable; the active request adapter remains the authority.
enum AIModelCapability: String, CaseIterable, Codable, Hashable {
    case textGeneration = "text-generation"
    case streamingText = "streaming-text"
    case jsonSchema = "json-schema"
    case toolCalling = "tool-calling"
    case modelDiscovery = "model-discovery"
    case nativeStructuredOutput = "native-structured-output"
    case decision = "decision"
}

/// Product-level usages that may be bound to an eligible model route. There is
/// intentionally no global "decision model" binding: a future feature may opt
/// into a structured-capable route explicitly without making Jev special.
enum AIProviderUse: String, CaseIterable, Codable, Hashable {
    case primaryText = "primary-text"
    case streamInput = "stream-input"
    case translation = "translation"
    case mailbox = "mailbox"
    case actionPlugin = "action-plugin"
}

/// A non-secret, durable selector for a concrete profile/model route at a
/// request boundary. `profileRevision` prevents an old Mailbox thread or an
/// in-flight plan from silently moving to a newly edited endpoint or key.
struct AIProviderRouteReference: Codable, Equatable, Hashable {
    let profileID: UUID
    let routeID: UUID
    let profileRevision: UInt64

    init(profileID: UUID, routeID: UUID, profileRevision: UInt64) {
        self.profileID = profileID
        self.routeID = routeID
        self.profileRevision = profileRevision
    }
}

/// A model plus the protocol endpoint through which it is called. Model IDs
/// can be nil while a user is creating a profile; such a route is intentionally
/// not runnable until a model has been chosen or entered.
struct AIModelRoute: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var modelID: String?
    var adapter: AIProviderAdapter
    /// A route can use a different protocol root than its parent profile. This
    /// is needed by OpenRouter's normal `/api/v1` chat route and its `/api`
    /// native decisions route without duplicating the account credential.
    var endpointOverride: String?
    var documentationURL: String?
    var capabilities: Set<AIModelCapability>
    var isEnabled: Bool

    init(id: UUID = UUID(),
         displayName: String,
         modelID: String? = nil,
         adapter: AIProviderAdapter,
         endpointOverride: String? = nil,
         documentationURL: String? = nil,
         capabilities: Set<AIModelCapability> = [],
         isEnabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
        self.adapter = adapter
        self.endpointOverride = endpointOverride
        self.documentationURL = documentationURL
        self.capabilities = capabilities
        self.isEnabled = isEnabled
    }

    var hasSelectedModel: Bool { modelID != nil }

    func validated() throws -> AIModelRoute {
        var copy = self
        copy.displayName = try AIProviderProfileValidation.displayName(
            displayName,
            field: "模型路由名称"
        )
        copy.modelID = try AIProviderProfileValidation.modelID(modelID)
        if let endpointOverride {
            copy.endpointOverride = try AIProviderProfileValidation.endpoint(
                endpointOverride,
                field: "路由端点"
            )
        }
        if let documentationURL {
            copy.documentationURL = try AIProviderProfileValidation.documentationURL(
                documentationURL
            )
        }
        return copy
    }
}

/// Binds one product-level use to exactly one profile/model route. Bindings are
/// catalog-level because a primary text model may belong to a different
/// provider than a stream-input or translation route.
struct AIProviderUseBinding: Codable, Equatable, Hashable {
    var use: AIProviderUse
    var profileID: UUID
    var routeID: UUID

    init(use: AIProviderUse, profileID: UUID, routeID: UUID) {
        self.use = use
        self.profileID = profileID
        self.routeID = routeID
    }
}

/// Non-secret provider account metadata. The matching API key is stored in a
/// separate mode-0600 file keyed by this profile's UUID.
struct AIProviderProfile: Codable, Equatable, Identifiable {
    /// A stable migration target lets old `openai-compatible` selections and
    /// historical Mailbox sources map to the same profile on every launch.
    static let legacyOpenAICompatibleID = UUID(
        uuidString: "693E9128-EA6B-4DF9-B1C9-D2F7090438BB"
    )!
    static let legacyOpenAICompatibleRouteID = UUID(
        uuidString: "F902B55D-3DF8-473A-A94E-857D3D007AC8"
    )!

    let id: UUID
    var displayName: String
    /// API root, never an endpoint with user credentials or a query string.
    var baseURL: String
    var documentationURL: String?
    var routes: [AIModelRoute]
    var requiresAPIKey: Bool
    var isEnabled: Bool
    /// Increases every time this profile or its private API key is changed.
    /// It is deliberately part of durable request references.
    var revision: UInt64

    init(id: UUID = UUID(),
         displayName: String,
         baseURL: String,
         documentationURL: String? = nil,
         routes: [AIModelRoute] = [],
         requiresAPIKey: Bool = false,
         isEnabled: Bool = true,
         revision: UInt64 = 1) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.documentationURL = documentationURL
        self.routes = routes
        self.requiresAPIKey = requiresAPIKey
        self.isEnabled = isEnabled
        self.revision = revision
    }

    func route(id: UUID) -> AIModelRoute? {
        routes.first(where: { $0.id == id })
    }

    func reference(for routeID: UUID) -> AIProviderRouteReference? {
        guard route(id: routeID) != nil else { return nil }
        return AIProviderRouteReference(
            profileID: id,
            routeID: routeID,
            profileRevision: revision
        )
    }

    func validated() throws -> AIProviderProfile {
        var copy = self
        guard revision > 0 else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "Provider revision 必须大于 0"
            )
        }
        guard routes.count <= 64 else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "一个 Provider 最多保存 64 个模型路由"
            )
        }
        copy.displayName = try AIProviderProfileValidation.displayName(
            displayName,
            field: "Provider 名称"
        )
        copy.baseURL = try AIProviderProfileValidation.endpoint(
            baseURL,
            field: "API Base URL"
        )
        if let documentationURL {
            copy.documentationURL = try AIProviderProfileValidation.documentationURL(
                documentationURL
            )
        }
        copy.routes = try routes.map { try $0.validated() }
        let routeIDs = Set(copy.routes.map(\.id))
        guard routeIDs.count == copy.routes.count else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "一个 Provider 中不能有重复的模型路由"
            )
        }
        return copy
    }

    /// A ready-to-edit OpenRouter account. The two routes deliberately share a
    /// profile and therefore one stored API key. No use binding is created: the
    /// caller chooses whether either route is used by a concrete feature.
    static func openRouter(
        id: UUID = UUID(),
        displayName: String = "OpenRouter",
        chatModelID: String? = nil,
        decisionModelID: String? = "~typesafe/jev-latest"
    ) -> AIProviderProfile {
        let chatRoute = AIModelRoute(
            displayName: "OpenAI Chat",
            modelID: chatModelID,
            adapter: .openAIChatCompletions,
            documentationURL: "https://openrouter.ai/docs/quickstart",
            capabilities: [.textGeneration, .streamingText],
            isEnabled: chatModelID != nil
        )
        let decisionsRoute = AIModelRoute(
            displayName: "Native Decisions",
            modelID: decisionModelID,
            adapter: .openRouterDecisions,
            endpointOverride: "https://openrouter.ai/api",
            documentationURL: "https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request",
            capabilities: [.nativeStructuredOutput, .decision],
            isEnabled: decisionModelID != nil
        )
        return AIProviderProfile(
            id: id,
            displayName: displayName,
            baseURL: "https://openrouter.ai/api/v1",
            documentationURL: "https://openrouter.ai/docs/quickstart",
            routes: [chatRoute, decisionsRoute],
            requiresAPIKey: true
        )
    }

    static func migratingLegacyOpenAICompatible(
        _ configuration: OpenAICompatibleConfiguration
    ) -> AIProviderProfile {
        let isCometAPI = URLComponents(string: configuration.baseURL)?
            .host?.lowercased() == "api.cometapi.com"
        let route = AIModelRoute(
            id: legacyOpenAICompatibleRouteID,
            displayName: configuration.model,
            modelID: configuration.model,
            adapter: .openAIChatCompletions,
            capabilities: [.textGeneration, .streamingText]
        )
        return AIProviderProfile(
            id: legacyOpenAICompatibleID,
            displayName: isCometAPI ? "CometAPI" : "OpenAI API",
            baseURL: configuration.baseURL,
            routes: [route],
            // Existing OpenAI-compatible configuration has always allowed an
            // empty key for local loopback gateways, so preserve that behavior.
            requiresAPIKey: false,
            revision: 1
        )
    }
}

/// The complete non-secret provider catalog. It intentionally stores only a
/// small set of manually selected routes, never a provider's unbounded model
/// discovery response.
struct AIProviderProfileCatalog: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: [AIProviderProfile]
    var bindings: [AIProviderUseBinding]

    init(schemaVersion: Int = AIProviderProfileCatalog.currentSchemaVersion,
         profiles: [AIProviderProfile] = [],
         bindings: [AIProviderUseBinding] = []) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.bindings = bindings
    }

    func profile(id: UUID) -> AIProviderProfile? {
        profiles.first(where: { $0.id == id })
    }

    func binding(for use: AIProviderUse) -> AIProviderUseBinding? {
        bindings.first(where: { $0.use == use })
    }

    func validated() throws -> AIProviderProfileCatalog {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AIProviderProfileStoreError.unsupportedSchemaVersion
        }
        guard profiles.count <= 64 else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "最多保存 64 个 Provider"
            )
        }
        var copy = self
        copy.profiles = try profiles.map { try $0.validated() }
        let profileIDs = Set(copy.profiles.map(\.id))
        guard profileIDs.count == copy.profiles.count else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "不能保存重复的 Provider"
            )
        }
        let uses = Set(bindings.map(\.use))
        guard uses.count == bindings.count else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "同一种用途只能绑定一个模型路由"
            )
        }
        for binding in bindings {
            guard let profile = copy.profile(id: binding.profileID),
                  let route = profile.route(id: binding.routeID),
                  route.isEnabled,
                  route.hasSelectedModel else {
                throw AIProviderProfileStoreError.invalidConfiguration(
                    "用途绑定指向了不可用的 Provider 或模型路由"
                )
            }
        }
        return copy
    }
}

/// A mutation of the private credential that accompanies a profile update.
/// This is intentionally not Codable and has no printable representation.
enum AIProviderSecretUpdate {
    case preserve
    case set(String)
    case clear
}

/// Private credential payload. Do not add `CustomStringConvertible`, logging,
/// or a public debug description to this type.
struct AIProviderProfileSecret: Codable, Equatable {
    let apiKey: String

    init(apiKey: String) throws {
        guard apiKey.utf8.count <= 16_384,
              !apiKey.contains("\r"),
              !apiKey.contains("\n") else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "API Key 格式无效"
            )
        }
        self.apiKey = apiKey
    }
}

/// A resolved route is intentionally short-lived and must never be written to
/// a log, UserDefaults, Mailbox message, notification, or a diagnostic value.
struct AIProviderResolvedRoute {
    let reference: AIProviderRouteReference
    let profile: AIProviderProfile
    let route: AIModelRoute
    let apiKey: String?
}

/// Safe-to-display state for settings and diagnostics. It deliberately omits
/// endpoint URLs and all credential content.
struct AIProviderRouteRedactedStatus: Equatable {
    let id: UUID
    let displayName: String
    let modelID: String?
    let adapter: AIProviderAdapter
    let capabilities: Set<AIModelCapability>
    let isEnabled: Bool
}

struct AIProviderProfileRedactedStatus: Equatable {
    let id: UUID
    let displayName: String
    let revision: UInt64
    let requiresAPIKey: Bool
    let hasStoredAPIKey: Bool
    let isEnabled: Bool
    let routes: [AIProviderRouteRedactedStatus]
}

enum AIProviderProfileStoreError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case unsafePath
    case invalidPermissions
    case oversized
    case unreadable
    case malformed
    case unsupportedSchemaVersion
    case missingProfile
    case missingRoute
    case staleRoute
    case missingAPIKey
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): return message
        case .unsafePath: return "Provider 配置路径不安全"
        case .invalidPermissions: return "Provider 配置权限不安全"
        case .oversized: return "Provider 配置超过大小限制"
        case .unreadable: return "无法读取 Provider 配置"
        case .malformed: return "Provider 配置格式无效"
        case .unsupportedSchemaVersion: return "Provider 配置版本不受支持"
        case .missingProfile: return "找不到指定的 Provider"
        case .missingRoute: return "找不到指定的模型路由"
        case .staleRoute: return "Provider 配置已变更，请重新选择模型"
        case .missingAPIKey: return "该 Provider 需要 API Key"
        case .rollbackFailed: return "Provider 配置回滚失败，请重新检查密钥"
        }
    }
}

// MARK: - Private per-profile secret storage

/// Each profile's secret is isolated in its own mode-0600 JSON file. A profile
/// name never contributes to the file path; UUID validation keeps names and
/// arbitrary user input out of filesystem addressing.
final class AIProviderProfileSecretStore {
    static let shared = AIProviderProfileSecretStore()

    let rootDirectory: URL
    let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()

    init(rootDirectory: URL? = nil,
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootDirectory = AIProviderPrivateStorage.rootDirectory(
            rootDirectory,
            fileManager: fileManager
        )
        directoryURL = self.rootDirectory
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
    }

    func secret(for profileID: UUID) throws -> AIProviderProfileSecret? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try AIProviderPrivateStorage.read(
            at: url(for: profileID),
            maximumBytes: 32 * 1_024
        ) else {
            return nil
        }
        do {
            let secret = try JSONDecoder().decode(AIProviderProfileSecret.self, from: data)
            // Re-run construction validation after decode instead of trusting
            // a syntactically valid but out-of-policy on-disk value.
            return try AIProviderProfileSecret(apiKey: secret.apiKey)
        } catch let error as AIProviderProfileStoreError {
            throw error
        } catch {
            throw AIProviderProfileStoreError.malformed
        }
    }

    func hasStoredAPIKey(for profileID: UUID) throws -> Bool {
        guard let secret = try secret(for: profileID) else { return false }
        return !secret.apiKey.isEmpty
    }

    func save(_ secret: AIProviderProfileSecret, for profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let data: Data
        do {
            data = try JSONEncoder().encode(secret)
        } catch {
            throw AIProviderProfileStoreError.unreadable
        }
        guard data.count <= 32 * 1_024 else {
            throw AIProviderProfileStoreError.oversized
        }
        try AIProviderPrivateStorage.ensureDirectory(rootDirectory, fileManager: fileManager)
        try AIProviderPrivateStorage.ensureDirectory(
            directoryURL,
            fileManager: fileManager
        )
        try AIProviderPrivateStorage.write(
            data,
            to: url(for: profileID),
            fileManager: fileManager
        )
    }

    func deleteSecret(for profileID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try AIProviderPrivateStorage.delete(at: url(for: profileID))
    }

    private func url(for profileID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(profileID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }
}

// MARK: - Catalog storage and legacy migration

final class AIProviderProfileCatalogStore {
    static let shared = AIProviderProfileCatalogStore()

    let rootDirectory: URL
    let catalogURL: URL
    let secretStore: AIProviderProfileSecretStore
    private let fileManager: FileManager
    private let legacyConfigurationStore: OpenAICompatibleConfigurationStore
    private let lock = NSRecursiveLock()

    init(rootDirectory: URL? = nil,
         fileManager: FileManager = .default,
         legacyConfigurationStore: OpenAICompatibleConfigurationStore? = nil) {
        self.fileManager = fileManager
        let selectedRoot = AIProviderPrivateStorage.rootDirectory(
            rootDirectory,
            fileManager: fileManager
        )
        self.rootDirectory = selectedRoot
        catalogURL = selectedRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("provider-profiles.json", isDirectory: false)
        secretStore = AIProviderProfileSecretStore(
            rootDirectory: selectedRoot,
            fileManager: fileManager
        )
        self.legacyConfigurationStore = legacyConfigurationStore
            ?? OpenAICompatibleConfigurationStore(
                rootDirectory: selectedRoot,
                fileManager: fileManager
            )
    }

    /// Loads only the new catalog. Call `loadMigratingLegacyOpenAICompatibleIfNeeded`
    /// at process startup or before presenting the new settings UI.
    func load() throws -> AIProviderProfileCatalog {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    /// Imports the existing single OpenAI-compatible configuration once, with
    /// no network activity. The legacy 0600 file is deliberately retained so
    /// an older installed build remains able to read it during the transition.
    func loadMigratingLegacyOpenAICompatibleIfNeeded() throws -> AIProviderProfileCatalog {
        lock.lock()
        defer { lock.unlock() }
        if try AIProviderPrivateStorage.exists(at: catalogURL) {
            return try loadUnlocked()
        }
        guard let legacy = try legacyConfigurationStore.load() else {
            return AIProviderProfileCatalog()
        }
        let migratedProfile = try AIProviderProfile
            .migratingLegacyOpenAICompatible(legacy)
            .validated()
        if !legacy.apiKey.isEmpty {
            try secretStore.save(
                AIProviderProfileSecret(apiKey: legacy.apiKey),
                for: migratedProfile.id
            )
        }
        let catalog = try AIProviderProfileCatalog(
            profiles: [migratedProfile]
        ).validated()
        try saveUnlocked(catalog, changedProfileID: migratedProfile.id, change: "migrated")
        return catalog
    }

    func save(_ catalog: AIProviderProfileCatalog) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(catalog, changedProfileID: nil, change: "catalog")
    }

    /// Inserts or updates one profile and, optionally, its secret. Every
    /// successful profile edit increments the revision used by request/Mailbox
    /// snapshots. Secret replacement also increments that same revision.
    @discardableResult
    func upsert(_ profile: AIProviderProfile,
                secretUpdate: AIProviderSecretUpdate = .preserve) throws -> AIProviderProfile {
        lock.lock()
        defer { lock.unlock() }
        var catalog = try loadUnlocked()
        let previousCatalog = catalog
        var candidate = try profile.validated()
        let existing = catalog.profile(id: candidate.id)
        if let existing {
            candidate.revision = existing.revision &+ 1
            if candidate.revision == 0 { candidate.revision = 1 }
        } else {
            candidate.revision = max(candidate.revision, 1)
        }
        candidate = try candidate.validated()

        // A cross-file catalog/secret commit cannot be made truly atomic. For
        // an existing profile, retain the old secret and actively restore it if
        // the subsequent catalog write fails; without this rollback, a failed
        // metadata save could silently replace the credential used by the old
        // reachable profile. For a new profile, an orphan secret is deleted on
        // failure because no catalog references it yet.
        let previousSecret: AIProviderProfileSecret?
        if existing != nil, case .set = secretUpdate {
            previousSecret = try secretStore.secret(for: candidate.id)
        } else {
            previousSecret = nil
        }
        if case let .set(apiKey) = secretUpdate {
            try secretStore.save(
                AIProviderProfileSecret(apiKey: apiKey),
                for: candidate.id
            )
        }
        if let index = catalog.profiles.firstIndex(where: { $0.id == candidate.id }) {
            catalog.profiles[index] = candidate
        } else {
            catalog.profiles.append(candidate)
        }
        do {
            try saveUnlocked(catalog, changedProfileID: candidate.id, change: "saved")
        } catch {
            guard case .set = secretUpdate else { throw error }
            do {
                if let existing {
                    if let previousSecret {
                        try secretStore.save(previousSecret, for: existing.id)
                    } else {
                        try secretStore.deleteSecret(for: existing.id)
                    }
                } else {
                    try secretStore.deleteSecret(for: candidate.id)
                }
            } catch {
                // Do not imply that the old credential is intact if restoring
                // it failed. Nothing sensitive is included in this error.
                throw AIProviderProfileStoreError.rollbackFailed
            }
            throw error
        }
        if case .clear = secretUpdate {
            // Clear only after the catalog revision has advanced. Revert that
            // metadata write if the secret deletion itself fails, so the UI
            // never reports a completed profile change with an unknown secret
            // state.
            do {
                try secretStore.deleteSecret(for: candidate.id)
            } catch {
                do {
                    try saveUnlocked(
                        previousCatalog,
                        changedProfileID: candidate.id,
                        change: "rollback"
                    )
                } catch {
                    throw AIProviderProfileStoreError.rollbackFailed
                }
                throw error
            }
            postChange(profileID: candidate.id, change: "secret-cleared")
        }
        return candidate
    }

    func removeProfile(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var catalog = try loadUnlocked()
        let previousCatalog = catalog
        guard catalog.profile(id: id) != nil else {
            throw AIProviderProfileStoreError.missingProfile
        }
        catalog.profiles.removeAll(where: { $0.id == id })
        catalog.bindings.removeAll(where: { $0.profileID == id })
        try saveUnlocked(catalog, changedProfileID: id, change: "removed")
        do {
            try secretStore.deleteSecret(for: id)
        } catch {
            do {
                try saveUnlocked(
                    previousCatalog,
                    changedProfileID: id,
                    change: "rollback"
                )
            } catch {
                throw AIProviderProfileStoreError.rollbackFailed
            }
            throw error
        }
        postChange(profileID: id, change: "secret-removed")
    }

    func setBinding(_ binding: AIProviderUseBinding?) throws {
        lock.lock()
        defer { lock.unlock() }
        var catalog = try loadUnlocked()
        if let binding {
            guard let profile = catalog.profile(id: binding.profileID),
                  let route = profile.route(id: binding.routeID),
                  profile.isEnabled,
                  route.isEnabled,
                  route.hasSelectedModel else {
                throw AIProviderProfileStoreError.invalidConfiguration(
                    "用途绑定指向了不可用的模型路由"
                )
            }
            catalog.bindings.removeAll(where: { $0.use == binding.use })
            catalog.bindings.append(binding)
        } else {
            // No argument means callers should use `clearBinding(for:)`; it is
            // intentionally not ambiguous about which use to remove.
            throw AIProviderProfileStoreError.invalidConfiguration("缺少用途绑定")
        }
        try saveUnlocked(catalog, changedProfileID: binding?.profileID, change: "binding")
    }

    func clearBinding(for use: AIProviderUse) throws {
        lock.lock()
        defer { lock.unlock() }
        var catalog = try loadUnlocked()
        let removed = catalog.bindings.first(where: { $0.use == use })
        catalog.bindings.removeAll(where: { $0.use == use })
        guard removed != nil else { return }
        try saveUnlocked(catalog, changedProfileID: removed?.profileID, change: "binding")
    }

    func routeReference(profileID: UUID, routeID: UUID) throws -> AIProviderRouteReference {
        let catalog = try load()
        guard let profile = catalog.profile(id: profileID) else {
            throw AIProviderProfileStoreError.missingProfile
        }
        guard profile.route(id: routeID) != nil else {
            throw AIProviderProfileStoreError.missingRoute
        }
        return AIProviderRouteReference(
            profileID: profileID,
            routeID: routeID,
            profileRevision: profile.revision
        )
    }

    /// Resolves a previously frozen route. A revision mismatch intentionally
    /// fails rather than reading a later endpoint/key/model under an old job.
    func resolve(_ reference: AIProviderRouteReference,
                 requiresAPIKey: Bool = false) throws -> AIProviderResolvedRoute {
        let catalog = try load()
        guard let profile = catalog.profile(id: reference.profileID) else {
            throw AIProviderProfileStoreError.missingProfile
        }
        guard profile.revision == reference.profileRevision else {
            throw AIProviderProfileStoreError.staleRoute
        }
        guard profile.isEnabled else {
            throw AIProviderProfileStoreError.invalidConfiguration("Provider 已停用")
        }
        guard let route = profile.route(id: reference.routeID) else {
            throw AIProviderProfileStoreError.missingRoute
        }
        guard route.isEnabled, route.hasSelectedModel else {
            throw AIProviderProfileStoreError.invalidConfiguration("模型路由尚未配置")
        }
        let apiKey = try secretStore.secret(for: profile.id)?.apiKey
        if (requiresAPIKey || profile.requiresAPIKey) && (apiKey?.isEmpty ?? true) {
            throw AIProviderProfileStoreError.missingAPIKey
        }
        return AIProviderResolvedRoute(
            reference: reference,
            profile: profile,
            route: route,
            apiKey: apiKey
        )
    }

    func redactedStatuses(
        migratingLegacyOpenAICompatible: Bool = true
    ) throws -> [AIProviderProfileRedactedStatus] {
        let catalog = migratingLegacyOpenAICompatible
            ? try loadMigratingLegacyOpenAICompatibleIfNeeded()
            : try load()
        return try catalog.profiles.map { profile in
            AIProviderProfileRedactedStatus(
                id: profile.id,
                displayName: profile.displayName,
                revision: profile.revision,
                requiresAPIKey: profile.requiresAPIKey,
                hasStoredAPIKey: try secretStore.hasStoredAPIKey(for: profile.id),
                isEnabled: profile.isEnabled,
                routes: profile.routes.map {
                    AIProviderRouteRedactedStatus(
                        id: $0.id,
                        displayName: $0.displayName,
                        modelID: $0.modelID,
                        adapter: $0.adapter,
                        capabilities: $0.capabilities,
                        isEnabled: $0.isEnabled
                    )
                }
            )
        }
    }

    private func loadUnlocked() throws -> AIProviderProfileCatalog {
        guard let data = try AIProviderPrivateStorage.read(
            at: catalogURL,
            maximumBytes: 256 * 1_024
        ) else {
            return AIProviderProfileCatalog()
        }
        do {
            return try JSONDecoder().decode(AIProviderProfileCatalog.self, from: data)
                .validated()
        } catch let error as AIProviderProfileStoreError {
            throw error
        } catch {
            throw AIProviderProfileStoreError.malformed
        }
    }

    private func saveUnlocked(_ catalog: AIProviderProfileCatalog,
                              changedProfileID: UUID?,
                              change: String) throws {
        let validated = try catalog.validated()
        let data: Data
        do {
            data = try JSONEncoder().encode(validated)
        } catch {
            throw AIProviderProfileStoreError.unreadable
        }
        guard data.count <= 256 * 1_024 else {
            throw AIProviderProfileStoreError.oversized
        }
        try AIProviderPrivateStorage.ensureDirectory(rootDirectory, fileManager: fileManager)
        try AIProviderPrivateStorage.ensureDirectory(
            catalogURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        try AIProviderPrivateStorage.write(data, to: catalogURL, fileManager: fileManager)
        postChange(profileID: changedProfileID, change: change)
    }

    private func postChange(profileID: UUID?, change: String) {
        var userInfo: [AnyHashable: Any] = ["change": change]
        if let profileID {
            userInfo["profileID"] = profileID.uuidString
        }
        NotificationCenter.default.post(
            name: .aiProviderProfilesDidChange,
            object: self,
            userInfo: userInfo
        )
    }
}

// MARK: - Validation and private atomic files

private enum AIProviderProfileValidation {
    static func displayName(_ raw: String, field: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 160,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIProviderProfileStoreError.invalidConfiguration("\(field)无效")
        }
        return normalized
    }

    static func modelID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.utf8.count <= 200,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AIProviderProfileStoreError.invalidConfiguration("模型名称无效")
        }
        return normalized
    }

    static func endpoint(_ raw: String, field: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= 2_048,
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AIProviderProfileStoreError.invalidConfiguration("\(field)无效")
        }
        guard scheme == "https" || (scheme == "http" && isExactLoopback(host)) else {
            throw AIProviderProfileStoreError.invalidConfiguration(
                "远程 API 必须使用 HTTPS"
            )
        }
        guard components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw AIProviderProfileStoreError.invalidConfiguration("API 端口无效")
        }
        let encodedSegments = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        for segment in encodedSegments {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/") else {
                throw AIProviderProfileStoreError.invalidConfiguration("API 路径无效")
            }
        }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url,
              url.host?.lowercased() == host else {
            throw AIProviderProfileStoreError.invalidConfiguration("\(field)无效")
        }
        return url.absoluteString
    }

    static func documentationURL(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= 2_048,
              let components = URLComponents(string: normalized),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw AIProviderProfileStoreError.invalidConfiguration("文档地址无效")
        }
        return url.absoluteString
    }

    private static func isExactLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

private enum AIProviderPrivateStorage {
    static func rootDirectory(_ requested: URL?, fileManager: FileManager) -> URL {
        let selected: URL
        if let requested {
            selected = requested
        } else if let override = ProcessInfo.processInfo.environment[
            "RIMEBUFFER_LOCAL_DATA_ROOT"
        ], !override.isEmpty {
            selected = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            selected = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/\(RimesPaths.directoryName)", isDirectory: true)
        }
        return selected.standardizedFileURL
    }

    static func exists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw AIProviderProfileStoreError.unreadable
    }

    static func read(at url: URL, maximumBytes: Int) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw AIProviderProfileStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AIProviderProfileStoreError.unsafePath
        }
        guard (info.st_mode & 0o777) == 0o600 else {
            throw AIProviderProfileStoreError.invalidPermissions
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            throw AIProviderProfileStoreError.oversized
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AIProviderProfileStoreError.unreadable
        }
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_dev == info.st_dev,
              openedInfo.st_ino == info.st_ino else {
            throw AIProviderProfileStoreError.unsafePath
        }
        var data = Data()
        data.reserveCapacity(Int(openedInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AIProviderProfileStoreError.unreadable
            }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else {
                throw AIProviderProfileStoreError.oversized
            }
        }
        return data
    }

    static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        guard data.count <= 256 * 1_024 else {
            throw AIProviderProfileStoreError.oversized
        }
        try rejectExistingNonRegularFile(at: url)
        let directory = url.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let temporaryPath = temporaryURL.path
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AIProviderProfileStoreError.unreadable
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlink(temporaryPath) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AIProviderProfileStoreError.unreadable
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        guard fsync(descriptor) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw AIProviderProfileStoreError.unreadable
        }
        guard rename(temporaryPath, url.path) == 0 else {
            throw AIProviderProfileStoreError.unreadable
        }
        shouldUnlink = false
        _ = fileManager // Keep the same explicit dependency seam as callers.
    }

    static func delete(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw AIProviderProfileStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AIProviderProfileStoreError.unsafePath
        }
        guard unlink(url.path) == 0 else {
            throw AIProviderProfileStoreError.unreadable
        }
    }

    static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw AIProviderProfileStoreError.unsafePath
            }
        } else {
            guard errno == ENOENT else {
                throw AIProviderProfileStoreError.unreadable
            }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw AIProviderProfileStoreError.unsafePath
            }
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw AIProviderProfileStoreError.invalidPermissions
        }
    }

    private static func rejectExistingNonRegularFile(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw AIProviderProfileStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AIProviderProfileStoreError.unsafePath
        }
    }
}
