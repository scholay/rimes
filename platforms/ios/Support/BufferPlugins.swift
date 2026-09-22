import Foundation
import Translation
import RimesCore

@MainActor final class AppleTranslationPlugin: BufferPlugin {
    let descriptor = BufferPluginDescriptor(id: "apple.translation", title: "苹果翻译 · Translate", realtime: true)
    private var session: AnyObject?
    func availability(for request: BufferPluginRequest) async -> BufferPluginAvailability {
        guard #available(iOS 26, *) else { return .unavailable(L("苹果翻译需要 iOS 26 或更新版本", "Apple translation requires iOS 26 or later")) }
        let source = Locale.Language(identifier: request.options["source"] ?? "zh-Hans")
        let target = Locale.Language(identifier: request.options["target"] ?? "en")
        guard source != target else { return .unavailable(L("请选择不同的原文和译文语言", "Choose different source and target languages")) }
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
        else { availability = LanguageAvailability() }
        switch await availability.status(from: source, to: target) {
        case .installed: return .ready
        case .supported: return .unavailable(L("请先在 RIMES App 的“苹果翻译语言包”中下载这两种语言", "Download these languages in RIMES → Apple translation languages"))
        case .unsupported: return .unavailable(L("苹果翻译不支持此语言对", "Apple translation does not support this language pair"))
        @unknown default: return .unavailable(L("暂时无法使用此语言对", "This language pair is currently unavailable"))
        }
    }
    func execute(_ request: BufferPluginRequest, preview: @escaping @MainActor (String) -> Void) async throws -> BufferPluginResult {
        guard #available(iOS 26, *) else { throw BufferPluginError.unavailable("Requires iOS 26") }
        let source = Locale.Language(identifier: request.options["source"] ?? "zh-Hans")
        let target = Locale.Language(identifier: request.options["target"] ?? "en")
        let translator: TranslationSession
        if #available(iOS 26.4, *) { translator = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency) }
        else { translator = TranslationSession(installedSource: source, target: target) }
        session = translator
        defer { session = nil }
        do {
            try Task.checkCancellation()
            let response = try await translator.translate(request.source)
            try Task.checkCancellation()
            guard !response.targetText.isEmpty else { throw CoreError.incomplete }
            return BufferPluginResult(text: response.targetText, revision: request.revision)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw BufferPluginError.unavailable(L("翻译未完成。请检查语言包；若系统限制键盘访问，请在设置中开启完全访问后重试。原文已保留。", "Translation failed. Check language downloads; if keyboard access is restricted, enable Full Access and retry. Source preserved."))
        }
    }
    func cancel() { if #available(iOS 26, *) { (session as? TranslationSession)?.cancel() } }
}

@MainActor final class AITextPlugin: BufferPlugin {
    let descriptor: BufferPluginDescriptor
    private let provider: ProviderConfiguration
    private let key: String
    private let consent: String
    private let action: AIAction
    init(provider: ProviderConfiguration, key: String, consent: String, action: AIAction) {
        self.provider = provider; self.key = key; self.consent = consent; self.action = action
        descriptor = .init(id: "ai.\(action.rawValue)", title: action.title, realtime: false)
    }
    func availability(for request: BufferPluginRequest) async -> BufferPluginAvailability { .ready }
    func execute(_ request: BufferPluginRequest, preview: @escaping @MainActor (String) -> Void) async throws -> BufferPluginResult {
        let networkRequest = try AIRequest.make(provider: provider, key: key, source: request.source, action: action,
                                               language: request.options["target"] ?? "English", consent: consent)
        let text = try await AIClient().generate(networkRequest) { text in await preview(text) }
        return .init(text: text, revision: request.revision)
    }
    func cancel() {} // Runner cancels the owning Task; URLSession transport observes it.
}
