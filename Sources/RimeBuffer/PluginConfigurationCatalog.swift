import CoreFoundation
import Foundation

enum AITextPluginConfigurationFieldID {
    static let connector = "connector"
}

enum StreamInputPluginConfigurationFieldID {
    static let connector = "connector"
    static let candidateCount = "candidateCount"
    static let responsePace = "latency"

    // v1.1 persisted these two free-form timings. They are intentionally kept
    // as migration-only identifiers so an existing profile can be projected
    // onto one of the v1.2 response-pace presets without losing its connector.
    static let debounceSeconds = "debounceSeconds"
    static let maximumWaitSeconds = "maximumWaitSeconds"
}

enum StreamInputResponsePace: String, CaseIterable {
    case fast
    case balanced
    case stable

    static let defaultValue = StreamInputResponsePace.balanced

    var displayName: String {
        switch self {
        case .fast: return "灵敏"
        case .balanced: return "平衡"
        case .stable: return "稳定"
        }
    }

    var debounce: TimeInterval {
        switch self {
        case .fast: return 0.14
        case .balanced: return 0.22
        case .stable: return 0.35
        }
    }

    var maximumWait: TimeInterval {
        switch self {
        case .fast: return 0.50
        case .balanced: return 0.80
        case .stable: return 1.20
        }
    }

    /// Pick the nearest named preset for a v1.1 profile. Missing legacy values
    /// do not outweigh the value that was actually saved.
    static func migratedLegacyValue(
        debounce: TimeInterval?,
        maximumWait: TimeInterval?
    ) -> StreamInputResponsePace {
        guard debounce != nil || maximumWait != nil else {
            return defaultValue
        }
        return allCases.min { lhs, rhs in
            legacyDistance(lhs, debounce: debounce, maximumWait: maximumWait)
                < legacyDistance(
                    rhs,
                    debounce: debounce,
                    maximumWait: maximumWait
                )
        } ?? defaultValue
    }

    private static func legacyDistance(
        _ pace: StreamInputResponsePace,
        debounce: TimeInterval?,
        maximumWait: TimeInterval?
    ) -> Double {
        let debounceDistance = debounce.map {
            abs($0 - pace.debounce) / 0.21
        } ?? 0
        let waitDistance = maximumWait.map {
            abs($0 - pace.maximumWait) / 0.70
        } ?? 0
        return debounceDistance + waitDistance
    }
}

enum MyPromptPluginConfigurationFieldID {
    static let libraryDirectory = "libraryDirectory"
    static let remoteRepositories = "remoteRepositories"
    static let resultLimit = "resultLimit"
    static let includeUserPrompt = "includeUserPrompt"
    static let syncRemoteOnStart = "syncRemoteOnStart"
}

enum RealtimeTranslationProviderKind: String, CaseIterable {
    case appleLocal = "apple-local"
    case aiConnector = "ai-connector"

    var displayName: String {
        switch self {
        case .appleLocal: return "Apple 本地翻译（默认）"
        case .aiConnector: return "当前 AI 渠道"
        }
    }
}

enum RealtimeTranslationPluginConfigurationFieldID {
    static let provider = "provider"
    static let connector = "connector"
    static let sourceLanguage = "sourceLanguage"
    static let targetLanguage = "targetLanguage"
}

enum MarinePluginConfigurationFieldID {
    static let connector = "connector"
    static let invocationTimeoutSeconds = "invocationTimeoutSeconds"
}

enum RealtimeTranslationConfigurationKey {
    static let provider = "plugins.realtimeTranslation.provider.v1"
    static let sourceLanguage = "plugins.appleTranslation.sourceLanguage.v1"
    static let targetLanguage = "plugins.appleTranslation.targetLanguage.v1"
}

struct StreamInputPluginSettings: Equatable {
    static let minimumCandidateCount = 1
    static let maximumCandidateCount = 5
    static let defaultCandidateCount = 5

    let connectorKind: AITextProviderKind
    let candidateCount: Int
    let responsePace: StreamInputResponsePace

    var debounce: TimeInterval { responsePace.debounce }
    var maximumWait: TimeInterval { responsePace.maximumWait }
}

struct RealtimeTranslationPluginSettings: Equatable {
    let providerKind: RealtimeTranslationProviderKind
    let connectorKind: AITextProviderKind
    let sourceLanguageID: String
    let targetLanguageID: String
}

struct MyPromptPluginSettings: Equatable {
    let libraryDirectoryURL: URL
    let remoteRepositoryURLs: [URL]
    let resultLimit: Int
    let includeUserPrompt: Bool
    let syncRemoteOnStart: Bool
}

/// Central declarations for user-configurable plugin behavior.
///
/// Built-in plugins expose these models through PluginConfigurationProviding.
/// External Action Plugins can be matched by their manifest id without adding
/// target-specific contents or credentials to the host settings surface.
enum PluginConfigurationCatalog {
    static let marinePluginID = "marine"

    static func makeModel(
        pluginID: String
    ) throws -> PluginConfigurationModel? {
        switch pluginID {
        case AITextBuiltInPluginID.aiText:
            return try makeAITextModel()
        case BuiltInPluginID.streamInput:
            return try makeStreamInputModel()
        case BuiltInPluginID.appleTranslation:
            return try makeRealtimeTranslationModel()
        case BuiltInPluginID.myPrompt:
            return try makeMyPromptModel()
        case marinePluginID:
            return try makeMarineModel()
        default:
            return nil
        }
    }

    static func makeAITextModel(
        selectionStore: AITextConnectorSelectionStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) throws -> PluginConfigurationModel {
        let schema = PluginConfigurationSchema(
            pluginID: AITextBuiltInPluginID.aiText,
            title: "AI 生成",
            summary: "选择 AI 生成使用的渠道。这个选择也会提供给实时翻译与 Marine；各插件的配置页显示的是同一项全局选择。",
            fields: [
                .choice(
                    id: AITextPluginConfigurationFieldID.connector,
                    title: "AI 渠道",
                    helpText: "CLI 渠道沿用各自登录状态；OpenAI 兼容渠道沿用“连接器”里的私有 API 配置。",
                    options: aiConnectorChoices,
                    defaultValue: AITextProviderKind.codexCLI.rawValue
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: AIConnectorConfigurationStore(
                selectionStore: selectionStore
            ),
            notificationCenter: notificationCenter
        )
    }

    static func makeStreamInputModel(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) throws -> PluginConfigurationModel {
        let schema = PluginConfigurationSchema(
            pluginID: BuiltInPluginID.streamInput,
            title: "意识流输入",
            summary: "为连续全拼猜测单独选择 AI 渠道、候选数量和响应节奏。默认显示最多五个候选，并使用平衡节奏。",
            fields: [
                .choice(
                    id: StreamInputPluginConfigurationFieldID.connector,
                    title: "猜测渠道",
                    helpText: "这是意识流输入自己的选择，不会改动普通 AI 生成的渠道。",
                    options: aiConnectorChoices,
                    defaultValue:
                        AITextProviderKind.openAICompatible.rawValue
                ),
                .number(
                    id: StreamInputPluginConfigurationFieldID.candidateCount,
                    title: "候选数量",
                    helpText: "连续全拼可展示一至五个完整猜测；工作台使用分页切换，不改变候选内容。",
                    defaultValue: Double(
                        StreamInputPluginSettings.defaultCandidateCount
                    ),
                    minimum: Double(
                        StreamInputPluginSettings.minimumCandidateCount
                    ),
                    maximum: Double(
                        StreamInputPluginSettings.maximumCandidateCount
                    ),
                    step: 1,
                    validator: { value, _ in
                        guard case let .number(candidateCount) = value,
                              candidateCount.rounded() == candidateCount else {
                            return "候选数量必须是 1–5 的整数"
                        }
                        return nil
                    }
                ),
                .choice(
                    id: StreamInputPluginConfigurationFieldID.responsePace,
                    title: "响应节奏",
                    helpText: "灵敏会更快重算，稳定会等待更完整的输入，平衡适合日常使用。",
                    options: StreamInputResponsePace.allCases.map {
                        PluginConfigurationChoice(
                            value: $0.rawValue,
                            title: $0.displayName
                        )
                    },
                    defaultValue:
                        StreamInputResponsePace.defaultValue.rawValue
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: StreamInputConfigurationStore(
                defaults: defaults
            ),
            notificationCenter: notificationCenter
        )
    }

    static func makeRealtimeTranslationModel(
        defaults: UserDefaults = .standard,
        selectionStore: AITextConnectorSelectionStore = .shared,
        notificationCenter: NotificationCenter = .default,
        additionalLanguageIDs: [String] = []
    ) throws -> PluginConfigurationModel {
        let languageChoices = translationLanguageChoices(
            defaults: defaults,
            additionalLanguageIDs: additionalLanguageIDs
        )
        let schema = PluginConfigurationSchema(
            pluginID: BuiltInPluginID.appleTranslation,
            title: "实时翻译",
            summary: "默认完全使用 Apple 本地翻译；也可改用当前 AI 渠道。切换配置会取消旧请求，并按未改动的源缓冲区重新翻译。",
            fields: [
                .choice(
                    id: RealtimeTranslationPluginConfigurationFieldID.provider,
                    title: "翻译方式",
                    helpText: "Apple 本地翻译不发送原文；AI 渠道会把原文交给当前选中的连接器。",
                    options: RealtimeTranslationProviderKind.allCases.map {
                        PluginConfigurationChoice(
                            value: $0.rawValue,
                            title: $0.displayName
                        )
                    },
                    defaultValue:
                        RealtimeTranslationProviderKind.appleLocal.rawValue
                ),
                .choice(
                    id: RealtimeTranslationPluginConfigurationFieldID.connector,
                    title: "AI 渠道",
                    helpText: "仅在翻译方式为“当前 AI 渠道”时使用；与 AI 生成及 Marine 共享。",
                    options: aiConnectorChoices,
                    defaultValue: AITextProviderKind.codexCLI.rawValue
                ),
                .choice(
                    id: RealtimeTranslationPluginConfigurationFieldID
                        .sourceLanguage,
                    title: "源语言",
                    options: languageChoices,
                    defaultValue:
                        AppleTranslationWorkspace.defaultSourceLanguageID
                ),
                .choice(
                    id: RealtimeTranslationPluginConfigurationFieldID
                        .targetLanguage,
                    title: "目标语言",
                    options: languageChoices,
                    defaultValue:
                        AppleTranslationWorkspace.defaultTargetLanguageID,
                    validator: { value, snapshot in
                        guard case let .string(target) = value,
                              let source = snapshot.string(
                                RealtimeTranslationPluginConfigurationFieldID
                                    .sourceLanguage
                              ),
                              !TranslationLanguageIdentity.matches(
                                source,
                                expected: target
                              ) else {
                            return "源语言和目标语言不能相同"
                        }
                        return nil
                    }
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: RealtimeTranslationConfigurationStore(
                defaults: defaults,
                selectionStore: selectionStore
            ),
            notificationCenter: notificationCenter
        )
    }

    static func makeMyPromptModel(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) throws -> PluginConfigurationModel {
        let schema = PluginConfigurationSchema(
            pluginID: BuiltInPluginID.myPrompt,
            title: "My Prompt",
            summary: "本地 Markdown 建立 SQLite 全文索引；远程 HTTPS Git 仓库先同步到本机，实时查询不访问网络。",
            fields: [
                .text(
                    id: MyPromptPluginConfigurationFieldID.libraryDirectory,
                    title: "本地提示词目录",
                    helpText: "支持 ~/ 开头或绝对路径。目录不存在时会自动创建；提示词正文不会写入日志。",
                    placeholder: "~/Library/RimeBuffer/my-prompt/library",
                    defaultValue: defaultMyPromptLibraryDirectory.path,
                    maximumLength: 2_048,
                    isRequired: true,
                    validator: { value, _ in
                        guard case let .string(path) = value,
                              validMyPromptLibraryPath(path) else {
                            return "请填写 ~/ 开头或绝对的本地目录"
                        }
                        return nil
                    }
                ),
                .text(
                    id: MyPromptPluginConfigurationFieldID.remoteRepositories,
                    title: "远程 Git 仓库",
                    helpText: "可留空；多个无凭据 HTTPS 仓库用逗号、分号或换行分隔，保存后立即同步。",
                    placeholder: "https://github.com/danielmiessler/Fabric.git",
                    defaultValue: "",
                    maximumLength: 8_192,
                    validator: { value, _ in
                        guard case let .string(raw) = value else {
                            return "远程仓库格式无效"
                        }
                        return myPromptRemoteRepositoryURLs(raw) == nil
                            ? "只支持不含凭据的 HTTPS Git 仓库 URL"
                            : nil
                    }
                ),
                .number(
                    id: MyPromptPluginConfigurationFieldID.resultLimit,
                    title: "实时结果数",
                    helpText: "缓冲工作台最多同时展示三条结果。",
                    defaultValue: 3,
                    minimum: 1,
                    maximum: 3,
                    step: 1
                ),
                .toggle(
                    id: MyPromptPluginConfigurationFieldID.includeUserPrompt,
                    title: "投递时附加 user.md",
                    helpText: "默认只投递 system.md。开启后会在其后附加非空的 Fabric user.md 模板。",
                    defaultValue: false
                ),
                .toggle(
                    id: MyPromptPluginConfigurationFieldID.syncRemoteOnStart,
                    title: "启动时同步远程仓库",
                    helpText: "关闭后仍可在缓冲工作台点刷新手动同步；查询始终使用本地索引。",
                    defaultValue: true
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: PluginConfigurationUserDefaultsStore(
                namespace: BuiltInPluginID.myPrompt,
                defaults: defaults
            ),
            notificationCenter: notificationCenter
        )
    }

    static func makeMarineModel(
        defaults: UserDefaults = .standard,
        selectionStore: AITextConnectorSelectionStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) throws -> PluginConfigurationModel {
        let schema = PluginConfigurationSchema(
            pluginID: marinePluginID,
            title: "Marine",
            summary: "Marine 只接收本地浏览器上下文标识，不在设置页展示目标内容。AI 渠道与普通 AI 生成共享；超时会在每次调用开始时冻结。",
            fields: [
                .choice(
                    id: MarinePluginConfigurationFieldID.connector,
                    title: "AI 渠道",
                    helpText: "Marine 预生成使用当前共享渠道；修改后也会影响普通 AI 生成。",
                    options: aiConnectorChoices,
                    defaultValue: AITextProviderKind.codexCLI.rawValue
                ),
                .number(
                    id: MarinePluginConfigurationFieldID
                        .invocationTimeoutSeconds,
                    title: "生成超时（秒）",
                    helpText: "只影响新启动的 Marine 请求；正在运行的请求保持启动时的超时。",
                    defaultValue: 270,
                    minimum: 60,
                    maximum: 600,
                    step: 30
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: MarineConfigurationStore(
                defaults: defaults,
                selectionStore: selectionStore
            ),
            notificationCenter: notificationCenter
        )
    }

    static func streamInputSettings(
        defaults: UserDefaults = .standard
    ) -> StreamInputPluginSettings {
        guard let model = try? makeStreamInputModel(defaults: defaults),
              let snapshot = try? model.load() else {
            return StreamInputPluginSettings(
                connectorKind: .openAICompatible,
                candidateCount:
                    StreamInputPluginSettings.defaultCandidateCount,
                responsePace: .defaultValue
            )
        }
        let candidateCount = Int(
            snapshot.number(
                StreamInputPluginConfigurationFieldID.candidateCount
            ) ?? Double(StreamInputPluginSettings.defaultCandidateCount)
        )
        return StreamInputPluginSettings(
            connectorKind: AITextProviderKind(
                rawValue: snapshot.string(
                    StreamInputPluginConfigurationFieldID.connector
                ) ?? ""
            ) ?? .openAICompatible,
            candidateCount: min(
                max(
                    candidateCount,
                    StreamInputPluginSettings.minimumCandidateCount
                ),
                StreamInputPluginSettings.maximumCandidateCount
            ),
            responsePace: StreamInputResponsePace(
                rawValue: snapshot.string(
                    StreamInputPluginConfigurationFieldID.responsePace
                ) ?? ""
            ) ?? .defaultValue
        )
    }

    static func realtimeTranslationSettings(
        defaults: UserDefaults = .standard,
        selectionStore: AITextConnectorSelectionStore = .shared
    ) -> RealtimeTranslationPluginSettings {
        guard let model = try? makeRealtimeTranslationModel(
                defaults: defaults,
                selectionStore: selectionStore
              ),
              let snapshot = try? model.load() else {
            return RealtimeTranslationPluginSettings(
                providerKind: .appleLocal,
                connectorKind: selectionStore.selectedKind,
                sourceLanguageID:
                    AppleTranslationWorkspace.defaultSourceLanguageID,
                targetLanguageID:
                    AppleTranslationWorkspace.defaultTargetLanguageID
            )
        }
        return RealtimeTranslationPluginSettings(
            providerKind: RealtimeTranslationProviderKind(
                rawValue: snapshot.string(
                    RealtimeTranslationPluginConfigurationFieldID.provider
                ) ?? ""
            ) ?? .appleLocal,
            connectorKind: AITextProviderKind(
                rawValue: snapshot.string(
                    RealtimeTranslationPluginConfigurationFieldID.connector
                ) ?? ""
            ) ?? selectionStore.selectedKind,
            sourceLanguageID: snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.sourceLanguage
            ) ?? AppleTranslationWorkspace.defaultSourceLanguageID,
            targetLanguageID: snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.targetLanguage
            ) ?? AppleTranslationWorkspace.defaultTargetLanguageID
        )
    }

    static func myPromptSettings(
        defaults: UserDefaults = .standard
    ) -> MyPromptPluginSettings {
        let fallback = MyPromptPluginSettings(
            libraryDirectoryURL: defaultMyPromptLibraryDirectory,
            remoteRepositoryURLs: [],
            resultLimit: 3,
            includeUserPrompt: false,
            syncRemoteOnStart: true
        )
        guard let model = try? makeMyPromptModel(
                defaults: defaults
              ),
              let snapshot = try? model.load(),
              let rawPath = snapshot.string(
                MyPromptPluginConfigurationFieldID.libraryDirectory
              ),
              validMyPromptLibraryPath(rawPath),
              let repositories = myPromptRemoteRepositoryURLs(
                snapshot.string(
                    MyPromptPluginConfigurationFieldID.remoteRepositories
                ) ?? ""
              ) else {
            return fallback
        }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        let resultLimit = Int(
            snapshot.number(
                MyPromptPluginConfigurationFieldID.resultLimit
            ) ?? 3
        )
        return MyPromptPluginSettings(
            libraryDirectoryURL: URL(
                fileURLWithPath: expandedPath,
                isDirectory: true
            ).standardizedFileURL,
            remoteRepositoryURLs: repositories,
            resultLimit: min(max(resultLimit, 1), 3),
            includeUserPrompt: snapshot.bool(
                MyPromptPluginConfigurationFieldID.includeUserPrompt
            ) ?? false,
            syncRemoteOnStart: snapshot.bool(
                MyPromptPluginConfigurationFieldID.syncRemoteOnStart
            ) ?? true
        )
    }

    static func marineInvocationTimeout(
        defaults: UserDefaults = .standard
    ) -> TimeInterval {
        guard let model = try? makeMarineModel(defaults: defaults),
              let snapshot = try? model.load(),
              let value = snapshot.number(
                MarinePluginConfigurationFieldID.invocationTimeoutSeconds
              ),
              value.isFinite else {
            return 270
        }
        return min(max(value, 60), 600)
    }

    private static let aiConnectorChoices =
        AITextProviderKind.allCases.map {
            PluginConfigurationChoice(
                value: $0.rawValue,
                title: $0.displayName
            )
        }

    static var defaultMyPromptDataRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
            ?? environment["RIMEBUFFER_USER_DIR"]
        return (root.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/RimeBuffer", isDirectory: true))
            .appendingPathComponent("my-prompt", isDirectory: true)
    }

    private static var defaultMyPromptLibraryDirectory: URL {
        defaultMyPromptDataRoot
            .appendingPathComponent("library", isDirectory: true)
    }

    private static func validMyPromptLibraryPath(_ raw: String) -> Bool {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.utf8.count <= 2_048,
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        return path.hasPrefix("/") || path.hasPrefix("~/")
    }

    /// A nil return means at least one configured token was unsafe. An empty
    /// list is valid and keeps the plugin fully local.
    private static func myPromptRemoteRepositoryURLs(
        _ raw: String
    ) -> [URL]? {
        let tokens = raw.components(
            separatedBy: CharacterSet(charactersIn: ",;\n\r")
        ).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard tokens.count <= 32 else { return nil }
        var result: [URL] = []
        for token in tokens {
            guard token.utf8.count <= 2_048,
                  let components = URLComponents(string: token),
                  components.scheme?.lowercased() == "https",
                  components.user == nil,
                  components.password == nil,
                  let host = components.host,
                  !host.isEmpty,
                  components.query == nil,
                  components.fragment == nil,
                  let url = components.url else {
                return nil
            }
            let normalized = url.standardized
            if !result.contains(normalized) {
                result.append(normalized)
            }
        }
        return result
    }

    private static func translationLanguageChoices(
        defaults: UserDefaults,
        additionalLanguageIDs: [String] = []
    ) -> [PluginConfigurationChoice] {
        var identifiers = [
            "zh-Hans", "zh-Hant", "en", "ja", "ko",
            "fr", "de", "es", "it", "pt", "ar", "nl",
            "id", "pl", "ru", "th", "tr", "uk", "vi",
        ]
        let standardDictionaryKey =
            "RimeBuffer.PluginConfiguration.\(BuiltInPluginID.appleTranslation)"
        let standardValues = defaults.dictionary(
            forKey: standardDictionaryKey
        )
        for fieldID in [
            RealtimeTranslationPluginConfigurationFieldID.sourceLanguage,
            RealtimeTranslationPluginConfigurationFieldID.targetLanguage,
        ] {
            if let value = standardValues?[fieldID] as? String,
               validLanguageIdentifier(value),
               !identifiers.contains(value) {
                identifiers.append(value)
            }
        }
        for key in [
            RealtimeTranslationConfigurationKey.sourceLanguage,
            RealtimeTranslationConfigurationKey.targetLanguage,
        ] {
            if let value = defaults.string(forKey: key),
               validLanguageIdentifier(value),
               !identifiers.contains(value) {
                identifiers.append(value)
            }
        }
        for value in additionalLanguageIDs where
            validLanguageIdentifier(value) && !identifiers.contains(value) {
            identifiers.append(value)
        }
        return identifiers.map {
            let title = Locale.current.localizedString(forIdentifier: $0)
                ?? Locale.current.localizedString(forLanguageCode: $0)
                ?? $0
            return PluginConfigurationChoice(value: $0, title: title)
        }
    }

    private static func validLanguageIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 35
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || $0 == "-" || $0 == "_"
            }
    }

    fileprivate static func configuredLanguage(
        _ raw: String?,
        fallback: String
    ) -> String {
        guard let value = raw?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return fallback
        }
        switch value.lowercased() {
        case "auto", "automatic", "__automatic__":
            return fallback
        default:
            return value
        }
    }
}

/// v1.2 stores a named response pace instead of exposing two timing numbers.
/// Loading remains backward compatible with the v1.1 dictionary; the next
/// explicit save rewrites it in the current schema and removes the legacy keys.
private final class StreamInputConfigurationStore:
    PluginConfigurationStoring {
    let supportsSecureValues = false

    private let defaults: UserDefaults
    private let baseStore: PluginConfigurationUserDefaultsStore
    private let storageKey: String

    init(defaults: UserDefaults) {
        self.defaults = defaults
        baseStore = PluginConfigurationUserDefaultsStore(
            namespace: BuiltInPluginID.streamInput,
            defaults: defaults
        )
        storageKey =
            "RimeBuffer.PluginConfiguration.\(BuiltInPluginID.streamInput)"
    }

    func validate(schema: PluginConfigurationSchema) throws {
        try baseStore.validate(schema: schema)
    }

    func load(schema: PluginConfigurationSchema) throws
        -> PluginConfigurationSnapshot? {
        var snapshot = try baseStore.load(schema: schema)
        guard snapshot?[StreamInputPluginConfigurationFieldID.responsePace]
                == nil,
              let raw = defaults.dictionary(forKey: storageKey) else {
            return snapshot
        }
        let legacyDebounce = finiteNumber(
            raw[StreamInputPluginConfigurationFieldID.debounceSeconds]
        )
        let legacyMaximumWait = finiteNumber(
            raw[StreamInputPluginConfigurationFieldID.maximumWaitSeconds]
        )
        guard legacyDebounce != nil || legacyMaximumWait != nil else {
            return snapshot
        }
        if snapshot == nil {
            snapshot = PluginConfigurationSnapshot()
        }
        snapshot?[StreamInputPluginConfigurationFieldID.responsePace] = .string(
            StreamInputResponsePace.migratedLegacyValue(
                debounce: legacyDebounce,
                maximumWait: legacyMaximumWait
            ).rawValue
        )
        return snapshot
    }

    func save(_ snapshot: PluginConfigurationSnapshot,
              schema: PluginConfigurationSchema) throws {
        try baseStore.save(snapshot, schema: schema)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        try baseStore.delete(schema: schema)
    }

    private func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return nil
        }
        return number.doubleValue
    }
}

/// Dynamic facade used only by consciousness-stream input. An injected
/// provider in smoke tests still bypasses this facade completely.
final class StreamInputConfiguredAITextProvider: AITextProvider {
    static let shared = StreamInputConfiguredAITextProvider()

    private let connectorRegistry: AITextConnectorRegistry
    private let defaults: UserDefaults

    init(connectorRegistry: AITextConnectorRegistry = .shared,
         defaults: UserDefaults = .standard) {
        self.connectorRegistry = connectorRegistry
        self.defaults = defaults
    }

    var kind: AITextProviderKind {
        PluginConfigurationCatalog.streamInputSettings(
            defaults: defaults
        ).connectorKind
    }

    var availability: AITextProviderAvailability {
        connectorRegistry.availability(for: kind)
    }

    @discardableResult
    func generate(
        _ request: AITextProviderRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        let selectedKind = kind
        guard let provider = connectorRegistry.provider(for: selectedKind) else {
            completion(.failure(.unavailable(
                "连接器不可用：\(selectedKind.displayName)"
            )))
            return AITextNoopCancellation()
        }
        return provider.generate(
            request,
            onEvent: onEvent,
            completion: completion
        )
    }
}

private final class AIConnectorConfigurationStore:
    PluginConfigurationStoring {
    let supportsSecureValues = false
    private let selectionStore: AITextConnectorSelectionStore

    init(selectionStore: AITextConnectorSelectionStore) {
        self.selectionStore = selectionStore
    }

    func validate(schema: PluginConfigurationSchema) throws {}

    func load(
        schema: PluginConfigurationSchema
    ) throws -> PluginConfigurationSnapshot? {
        PluginConfigurationSnapshot(values: [
            AITextPluginConfigurationFieldID.connector:
                .string(selectionStore.selectedKind.rawValue),
        ])
    }

    func save(
        _ snapshot: PluginConfigurationSnapshot,
        schema: PluginConfigurationSchema
    ) throws {
        guard let raw = snapshot.string(
            AITextPluginConfigurationFieldID.connector
        ), let kind = AITextProviderKind(rawValue: raw) else {
            throw PluginConfigurationError.corruptDocument
        }
        selectionStore.select(kind)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        selectionStore.select(.codexCLI)
    }
}

private final class RealtimeTranslationConfigurationStore:
    PluginConfigurationStoring {
    let supportsSecureValues = false

    private let defaults: UserDefaults
    private let selectionStore: AITextConnectorSelectionStore
    private let baseStore: PluginConfigurationUserDefaultsStore

    init(defaults: UserDefaults,
         selectionStore: AITextConnectorSelectionStore) {
        self.defaults = defaults
        self.selectionStore = selectionStore
        baseStore = PluginConfigurationUserDefaultsStore(
            namespace: BuiltInPluginID.appleTranslation,
            defaults: defaults
        )
    }

    func validate(schema: PluginConfigurationSchema) throws {
        try baseStore.validate(schema: schema)
    }

    func load(
        schema: PluginConfigurationSchema
    ) throws -> PluginConfigurationSnapshot? {
        if var stored = try baseStore.load(schema: schema) {
            var source = stored.string(
                RealtimeTranslationPluginConfigurationFieldID.sourceLanguage
            ) ?? AppleTranslationWorkspace.defaultSourceLanguageID
            var target = stored.string(
                RealtimeTranslationPluginConfigurationFieldID.targetLanguage
            ) ?? AppleTranslationWorkspace.defaultTargetLanguageID
            if defaults.object(
                forKey: RealtimeTranslationConfigurationKey.sourceLanguage
            ) != nil {
                source = PluginConfigurationCatalog.configuredLanguage(
                    defaults.string(
                        forKey:
                            RealtimeTranslationConfigurationKey.sourceLanguage
                    ),
                    fallback:
                        AppleTranslationWorkspace.defaultSourceLanguageID
                )
            }
            if defaults.object(
                forKey: RealtimeTranslationConfigurationKey.targetLanguage
            ) != nil {
                target = PluginConfigurationCatalog.configuredLanguage(
                    defaults.string(
                        forKey:
                            RealtimeTranslationConfigurationKey.targetLanguage
                    ),
                    fallback:
                        AppleTranslationWorkspace.defaultTargetLanguageID
                )
            }
            if TranslationLanguageIdentity.matches(source, expected: target) {
                target = TranslationLanguageIdentity.matches(
                    source,
                    expected:
                        AppleTranslationWorkspace.defaultTargetLanguageID
                )
                    ? AppleTranslationWorkspace.defaultSourceLanguageID
                    : AppleTranslationWorkspace.defaultTargetLanguageID
            }
            let storedSource = stored.string(
                RealtimeTranslationPluginConfigurationFieldID.sourceLanguage
            )
            let storedTarget = stored.string(
                RealtimeTranslationPluginConfigurationFieldID.targetLanguage
            )
            if storedSource != source || storedTarget != target {
                stored[
                    RealtimeTranslationPluginConfigurationFieldID
                        .sourceLanguage
                ] = .string(source)
                stored[
                    RealtimeTranslationPluginConfigurationFieldID
                        .targetLanguage
                ] = .string(target)
                try baseStore.save(stored, schema: schema)
            }
            stored[
                RealtimeTranslationPluginConfigurationFieldID.connector
            ] = .string(selectionStore.selectedKind.rawValue)
            return stored
        }

        let provider = defaults.string(
            forKey: RealtimeTranslationConfigurationKey.provider
        ).flatMap(RealtimeTranslationProviderKind.init(rawValue:))
            ?? .appleLocal
        let source = PluginConfigurationCatalog.configuredLanguage(
            defaults.string(
                forKey: RealtimeTranslationConfigurationKey.sourceLanguage
            ),
            fallback: AppleTranslationWorkspace.defaultSourceLanguageID
        )
        var target = PluginConfigurationCatalog.configuredLanguage(
            defaults.string(
                forKey: RealtimeTranslationConfigurationKey.targetLanguage
            ),
            fallback: AppleTranslationWorkspace.defaultTargetLanguageID
        )
        if TranslationLanguageIdentity.matches(source, expected: target) {
            target = TranslationLanguageIdentity.matches(
                source,
                expected: AppleTranslationWorkspace.defaultTargetLanguageID
            )
                ? AppleTranslationWorkspace.defaultSourceLanguageID
                : AppleTranslationWorkspace.defaultTargetLanguageID
        }
        let migrated = PluginConfigurationSnapshot(values: [
            RealtimeTranslationPluginConfigurationFieldID.provider:
                .string(provider.rawValue),
            RealtimeTranslationPluginConfigurationFieldID.connector:
                .string(selectionStore.selectedKind.rawValue),
            RealtimeTranslationPluginConfigurationFieldID.sourceLanguage:
                .string(source),
            RealtimeTranslationPluginConfigurationFieldID.targetLanguage:
                .string(target),
        ])
        try baseStore.save(migrated, schema: schema)
        // Keep the legacy language pair canonical for downgrade compatibility.
        defaults.set(
            source,
            forKey: RealtimeTranslationConfigurationKey.sourceLanguage
        )
        defaults.set(
            target,
            forKey: RealtimeTranslationConfigurationKey.targetLanguage
        )
        return migrated
    }

    func save(
        _ snapshot: PluginConfigurationSnapshot,
        schema: PluginConfigurationSchema
    ) throws {
        guard let providerRaw = snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.provider
              ),
              RealtimeTranslationProviderKind(rawValue: providerRaw) != nil,
              let connectorRaw = snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.connector
              ),
              let connector = AITextProviderKind(rawValue: connectorRaw),
              let source = snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.sourceLanguage
              ),
              let target = snapshot.string(
                RealtimeTranslationPluginConfigurationFieldID.targetLanguage
              ) else {
            throw PluginConfigurationError.corruptDocument
        }
        try baseStore.save(snapshot, schema: schema)
        defaults.set(
            source,
            forKey: RealtimeTranslationConfigurationKey.sourceLanguage
        )
        defaults.set(
            target,
            forKey: RealtimeTranslationConfigurationKey.targetLanguage
        )
        selectionStore.select(connector)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        try baseStore.delete(schema: schema)
        defaults.removeObject(
            forKey: RealtimeTranslationConfigurationKey.provider
        )
        defaults.removeObject(
            forKey: RealtimeTranslationConfigurationKey.sourceLanguage
        )
        defaults.removeObject(
            forKey: RealtimeTranslationConfigurationKey.targetLanguage
        )
        selectionStore.select(.codexCLI)
    }
}

private final class MarineConfigurationStore: PluginConfigurationStoring {
    let supportsSecureValues = false
    private let selectionStore: AITextConnectorSelectionStore
    private let baseStore: PluginConfigurationUserDefaultsStore

    init(defaults: UserDefaults,
         selectionStore: AITextConnectorSelectionStore) {
        self.selectionStore = selectionStore
        baseStore = PluginConfigurationUserDefaultsStore(
            namespace: PluginConfigurationCatalog.marinePluginID,
            defaults: defaults
        )
    }

    func validate(schema: PluginConfigurationSchema) throws {
        try baseStore.validate(schema: schema)
    }

    func load(
        schema: PluginConfigurationSchema
    ) throws -> PluginConfigurationSnapshot? {
        if var stored = try baseStore.load(schema: schema) {
            stored[MarinePluginConfigurationFieldID.connector] =
                .string(selectionStore.selectedKind.rawValue)
            return stored
        }
        return PluginConfigurationSnapshot(values: [
            MarinePluginConfigurationFieldID.connector:
                .string(selectionStore.selectedKind.rawValue),
            MarinePluginConfigurationFieldID.invocationTimeoutSeconds:
                .number(ActionPluginHost.defaultInvocationTimeout),
        ])
    }

    func save(
        _ snapshot: PluginConfigurationSnapshot,
        schema: PluginConfigurationSchema
    ) throws {
        guard let connectorRaw = snapshot.string(
                MarinePluginConfigurationFieldID.connector
              ),
              let connector = AITextProviderKind(rawValue: connectorRaw),
              snapshot.number(
                MarinePluginConfigurationFieldID.invocationTimeoutSeconds
              ) != nil else {
            throw PluginConfigurationError.corruptDocument
        }
        try baseStore.save(snapshot, schema: schema)
        selectionStore.select(connector)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        try baseStore.delete(schema: schema)
        selectionStore.select(.codexCLI)
    }
}
