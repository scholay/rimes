import SwiftUI
import Translation

struct TranslationSetupView: View {
    var body: some View {
        if #available(iOS 26, *) { TranslationLanguageSetup() }
        else { Text(L("苹果翻译插件需要 iOS 26 或更新版本。离线输入和已有 AI 功能仍可用。", "Apple translation requires iOS 26 or later. Offline typing and existing AI remain available.")).padding() }
    }
}

@available(iOS 26, *)
private struct TranslationLanguageSetup: View {
    @State private var languages: [Locale.Language] = []
    @AppStorage("translation-preparation-source") private var source = "zh-Hans"
    @AppStorage("translation-preparation-target") private var target = "en"
    @State private var configuration: TranslationSession.Configuration?
    @State private var status = ""
    @State private var preparing = false
    var body: some View {
        Form {
            Section(L("在设备上翻译", "Translate on device")) {
                Text(L("先下载语言包，再到键盘 Buffer 开启“苹果翻译”。停顿后自动预览，点击才插入；不需要 API Key。", "Download languages, then enable Apple translation in the keyboard Buffer. Preview updates after a pause; insertion is manual. No API key needed."))
                Picker(L("原文", "Source"), selection: $source) { languageOptions }.disabled(preparing)
                Picker(L("译文", "Target"), selection: $target) { languageOptions }.disabled(preparing)
                Button(L("交换方向", "Swap languages")) { swap(&source, &target) }.disabled(preparing)
                Button(preparing ? L("准备中…", "Preparing…") : L("准备／下载语言包", "Prepare / download languages")) {
                    preparing = true; status = ""
                    if #available(iOS 26.4, *) { configuration = .init(source: .init(identifier: source), target: .init(identifier: target), preferredStrategy: .lowLatency) }
                    else { configuration = .init(source: .init(identifier: source), target: .init(identifier: target)) }
                    configuration?.invalidate()
                }.disabled(preparing || source == target)
                if !status.isEmpty { Text(status).accessibilityIdentifier("translation.preparationStatus") }
            }
        }
        .navigationTitle(L("苹果翻译语言包", "Translation languages"))
        .task { languages = await LanguageAvailability().supportedLanguages.sorted { label($0) < label($1) } }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                status = L("语言包已就绪，可以回到键盘开启苹果翻译。", "Languages are ready. Enable Apple translation in the keyboard.")
            } catch { status = L("语言包准备未完成，请检查网络和系统下载提示后重试。", "Preparation did not finish. Check the network and system download prompt, then retry.") }
            preparing = false
        }
    }
    private func label(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
    @ViewBuilder private var languageOptions: some View {
        if languages.isEmpty { Text("简体中文").tag("zh-Hans"); Text("English").tag("en") }
        else { ForEach(languages, id: \.minimalIdentifier) { Text(label($0)).tag($0.minimalIdentifier) } }
    }
}
