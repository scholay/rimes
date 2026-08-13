import AppKit
import Foundation

enum BuiltInPluginID {
    static let statistics = "builtin.statistics"
    static let typingSpeed = "builtin.typing-speed"
    static let flyChordLearning = "builtin.fly-chord-learning"
    static let appleTranslation = "builtin.apple-translation"
    static let myPrompt = "builtin.my-prompt"
    static let remarkable = "builtin.remarkable"
    static let marineChrome = "builtin.marine-chrome"
    static let streamInput = "builtin.stream-input"
    static let aiText = AITextBuiltInPluginID.aiText
    // Provider-specific IDs are retained for preference/source compatibility.
    static let codexCLI = AITextBuiltInPluginID.codexCLI
    static let claudeCodeCLI = AITextBuiltInPluginID.claudeCodeCLI
    static let openAICompatible = AITextBuiltInPluginID.openAICompatible
}

enum BuiltInPlugins {
    static func makeAll() -> [any InternalPlugin] {
        [
            StatisticsInternalPlugin(),
            TypingSpeedInternalPlugin(),
            FlyChordLearningInternalPlugin(),
            AppleTranslationInternalPlugin(),
            MyPromptInternalPlugin(),
            RemarkableInternalPlugin(),
            MarineChromeInternalPlugin(),
            StreamInputInternalPlugin(),
            AITextInternalPlugin(),
        ]
    }
}

private final class MarineChromeInternalPlugin: InternalPlugin {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.marineChrome
    )!
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn,
                       rawID: BuiltInPluginID.marineChrome),
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "network",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        MarineChromeWorkspace.shared.start()
    }

    func stop() {
        MarineChromeWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }
}

/// Synchronously flushes the aggregate-only metrics owned by built-in
/// extensions. Direct `exit(0)` paths do not deliver AppKit termination
/// notifications, so restart/update actions call this explicitly.
enum InputMetricsPersistence {
    static func saveNow() {
        KeyFrequencyStore.shared.saveNow()
        TypingSpeedStore.shared.saveNow()
    }
}

private final class StatisticsInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.statistics),
        wireID: nil,
        name: "统计",
        symbolName: "chart.bar.xaxis",
        version: "1.0",
        summary: "按日查看键盘热力图与全部历史趋势；仅保存本地计数。",
        source: .builtIn,
        capabilities: [.settingsPage, .keyMetrics, .localStorage],
        settings: PluginSettingsContribution(
            id: "statistics",
            title: "统计",
            symbolName: "chart.bar.xaxis",
            subpages: [
                PluginSettingsSubpage(id: "daily", title: "每日"),
                PluginSettingsSubpage(id: "history", title: "历史"),
            ]
        ),
        canUninstall: false
    )

    private var observation: InputTelemetryObservation?

    func start() {
        guard observation == nil else { return }
        observation = InputTelemetryBus.shared.observe { event in
            guard case let .key(key) = event else { return }
            KeyFrequencyStore.shared.record(
                keyID: key.keyID,
                at: Date(timeIntervalSince1970: key.timestamp)
            )
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        KeyFrequencyStore.shared.saveNow()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeStatistics(subpageID: subpageID)
    }
}

private final class TypingSpeedInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.typingSpeed),
        wireID: nil,
        name: "打字测速",
        symbolName: "speedometer",
        version: "1.0",
        summary: "按活跃输入时间计算按键和成文字符速度；成文字符按 Rime commit 计数，不保存输入正文。",
        source: .builtIn,
        capabilities: [.settingsPage, .keyMetrics, .commitMetrics, .localStorage],
        settings: PluginSettingsContribution(
            id: "typing-speed",
            title: "打字测速",
            symbolName: "speedometer",
            subpages: [
                PluginSettingsSubpage(id: "overview", title: "概览"),
                PluginSettingsSubpage(id: "history", title: "历史"),
            ]
        ),
        canUninstall: false
    )

    private var observation: InputTelemetryObservation?

    func start() {
        guard observation == nil else { return }
        observation = InputTelemetryBus.shared.observe { event in
            TypingSpeedStore.shared.consume(event)
        }
    }

    func stop() {
        observation?.cancel()
        observation = nil
        TypingSpeedStore.shared.saveNow()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeTypingSpeed(subpageID: subpageID)
    }
}

private final class FlyChordLearningInternalPlugin: InternalPlugin {
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.flyChordLearning),
        wireID: nil,
        name: "飞耀互击学习",
        symbolName: "hands.sparkles",
        version: "1.0",
        summary: "从飞耀互击方案生成课程与专项练习，进度只保存在本机。",
        source: .builtIn,
        capabilities: [.settingsPage, .chordLearning, .localStorage],
        settings: PluginSettingsContribution(
            id: "fly-chord-learning",
            title: "飞耀互击学习",
            symbolName: "hands.sparkles",
            subpages: [
                PluginSettingsSubpage(id: "lessons", title: "课程"),
                PluginSettingsSubpage(id: "practice", title: "练习"),
                PluginSettingsSubpage(id: "progress", title: "进度"),
            ]
        ),
        canUninstall: false
    )

    func start() {}
    func stop() {}

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        BuiltInPluginPageFactory.makeFlyChordLearning(subpageID: subpageID)
    }
}

private final class AppleTranslationInternalPlugin:
    InternalPlugin, PluginConfigurationProviding {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.appleTranslation
    )!
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.appleTranslation),
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "character.book.closed",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        AppleTranslationWorkspace.shared.start()
    }

    func stop() {
        AppleTranslationWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    func makePluginConfigurationModel() throws
        -> PluginConfigurationModel {
        try PluginConfigurationCatalog.makeRealtimeTranslationModel()
    }
}

private final class RemarkableInternalPlugin:
    InternalPlugin, PluginConfigurationProviding {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.remarkable
    )!
    let descriptor = PluginDescriptor(
        key: PluginKey(domain: .builtIn, rawID: BuiltInPluginID.remarkable),
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "rectangle.and.hand.point.up.left",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        RemarkableWorkspace.shared.start()
    }

    func stop() {
        RemarkableWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    func makePluginConfigurationModel() throws
        -> PluginConfigurationModel {
        let schema = PluginConfigurationSchema(
            pluginID: BuiltInPluginID.remarkable,
            title: "Remarkable",
            summary: "默认连接 USB 地址 10.11.99.1。请在平板设置中开启 USB Web Interface；插件通过只读 SSH 锁定当前页，再导出 PDF 并在 Mac 本地识别，不调用官方转写。SSH 严格校验 known_hosts，绝不自动信任未知主机。",
            fields: [
                .text(
                    id: RemarkablePluginConfigurationFieldID.host,
                    title: "SSH 主机",
                    helpText: "填写主机名、SSH 别名或 USB 地址；不要包含 user@ 前缀。",
                    placeholder: "10.11.99.1",
                    defaultValue: "10.11.99.1",
                    maximumLength: 253,
                    isRequired: true,
                    validator: { value, _ in
                        guard case let .string(host) = value,
                              RemarkableSSHTarget.isValidHostOrAlias(host) else {
                            return "请填写有效的 SSH 主机或别名"
                        }
                        return nil
                    }
                ),
                .text(
                    id: RemarkablePluginConfigurationFieldID.username,
                    title: "SSH 用户名",
                    placeholder: "root",
                    defaultValue: "root",
                    maximumLength: 64,
                    isRequired: true,
                    validator: { value, _ in
                        guard case let .string(username) = value,
                              RemarkableSSHTarget.isValidUsername(username) else {
                            return "请填写有效的 SSH 用户名"
                        }
                        return nil
                    }
                ),
                .choice(
                    id: RemarkablePluginConfigurationFieldID.ocrLanguage,
                    title: "首选识别语言",
                    helpText: "默认优先识别简体中文并保留英文词；自动模式适合繁简混排页面。全部由 Apple Vision 在这台 Mac 上识别。",
                    options: RemarkableOCRLanguageMode.allCases.map {
                        PluginConfigurationChoice(
                            value: $0.rawValue,
                            title: $0.displayName
                        )
                    },
                    defaultValue:
                        RemarkableOCRLanguageMode.defaultMode.rawValue,
                    validator: { value, _ in
                        guard case let .string(rawValue) = value,
                              RemarkableOCRLanguageMode(
                                  rawValue: rawValue
                              ) != nil else {
                            return "请选择有效的手写语言"
                        }
                        return nil
                    }
                ),
                .secureText(
                    id: RemarkablePluginConfigurationFieldID.password,
                    title: "SSH 密码",
                    helpText: "可留空以使用 ~/.ssh/config、私钥或 ssh-agent。",
                    placeholder: "留空则使用密钥认证",
                    maximumLength: 4_096,
                    validator: { value, _ in
                        guard case let .string(password) = value,
                              !password.contains("\r"),
                              !password.contains("\n") else {
                            return "SSH 密码格式无效"
                        }
                        return nil
                    }
                ),
            ]
        )
        return try PluginConfigurationModel(
            schema: schema,
            store: RemarkablePluginConfigurationStore()
        )
    }
}

private final class MyPromptInternalPlugin:
    InternalPlugin, PluginConfigurationProviding {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.myPrompt
    )!
    let descriptor = PluginDescriptor(
        key: MyPromptWorkspace.pluginKey,
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "doc.text.magnifyingglass",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction, .localStorage],
        settings: nil,
        canUninstall: false
    )

    func start() {
        MyPromptWorkspace.shared.start()
    }

    func stop() {
        MyPromptWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    func makePluginConfigurationModel() throws
        -> PluginConfigurationModel {
        try PluginConfigurationCatalog.makeMyPromptModel()
    }
}

private final class AITextInternalPlugin:
    InternalPlugin, PluginConfigurationProviding {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.aiText
    )!
    let descriptor = PluginDescriptor(
        key: AITextBuiltInPluginID.key,
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "sparkles",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        migrateLegacyProviderSelectionIfNeeded()
        AITextPluginRuntimeRegistry.shared.workspace.start()
    }

    func stop() {
        AITextPluginRuntimeRegistry.shared.workspace.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    func makePluginConfigurationModel() throws
        -> PluginConfigurationModel {
        try PluginConfigurationCatalog.makeAITextModel()
    }

    private func migrateLegacyProviderSelectionIfNeeded() {
        let bufferSelection = BufferPluginSelectionStore.shared
        guard let legacyKind = AITextProviderKind.legacyKind(
            for: bufferSelection.activeKey
        ) else { return }
        AITextConnectorSelectionStore.shared.select(legacyKind)
        _ = bufferSelection.select(
            descriptor.key,
            among: [RegisteredPlugin(descriptor: descriptor, isEnabled: true)]
        )
    }
}

private final class StreamInputInternalPlugin:
    InternalPlugin, PluginConfigurationProviding {
    private static let catalog = PresetBufferPluginCatalog.entry(
        id: BuiltInPluginID.streamInput
    )!
    let descriptor = PluginDescriptor(
        key: StreamInputWorkspace.pluginKey,
        wireID: nil,
        name: catalog.nameZH,
        symbolName: "waveform",
        version: catalog.version,
        summary: catalog.summaryZH,
        source: .builtIn,
        capabilities: [.bufferAction],
        settings: nil,
        canUninstall: false
    )

    func start() {
        StreamInputWorkspace.shared.start()
    }

    func stop() {
        StreamInputWorkspace.shared.stop()
    }

    func makeSettingsViewController(subpageID: String) -> NSViewController? {
        nil
    }

    func makePluginConfigurationModel() throws
        -> PluginConfigurationModel {
        try PluginConfigurationCatalog.makeStreamInputModel()
    }
}

/// Kept behind a tiny factory so the plugin model has no knowledge of the
/// settings window's routing shell. Each call returns a page-owned controller.
enum BuiltInPluginPageFactory {
    static func makeStatistics(subpageID: String) -> NSViewController {
        StatisticsSettingsViewController(subpageID: subpageID)
    }

    static func makeTypingSpeed(subpageID: String) -> NSViewController {
        TypingSpeedSettingsViewController(subpageID: subpageID)
    }

    static func makeFlyChordLearning(subpageID: String) -> NSViewController {
        FlyChordLearningSettingsViewController(subpageID: subpageID)
    }
}
