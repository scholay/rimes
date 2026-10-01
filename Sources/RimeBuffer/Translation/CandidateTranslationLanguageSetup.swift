import SwiftUI
import Translation

@available(macOS 15.0, *)
final class CandidateTranslationLanguageSetupModel: ObservableObject {
    @Published private(set) var targetLanguageID: String
    @Published private(set) var statusText = "正在检查 Apple 翻译语言…"
    @Published private(set) var configuration: TranslationSession.Configuration?

    private var requestID: UInt64 = 0

    init(targetLanguageID: String) {
        self.targetLanguageID = targetLanguageID
    }

    func refreshCurrentLanguage() {
        inspect(targetLanguageID, requestDownload: false)
    }

    func targetLanguageDidChange(_ identifier: String) {
        targetLanguageID = identifier
        inspect(identifier, requestDownload: true)
    }

    func requestDownload() {
        inspect(targetLanguageID, requestDownload: true)
    }

    private func inspect(_ identifier: String, requestDownload: Bool) {
        requestID &+= 1
        let currentRequestID = requestID
        configuration = nil
        statusText = "正在检查 Apple 翻译语言…"

        Task { @MainActor [weak self] in
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: "zh-Hans"),
                to: Locale.Language(identifier: identifier)
            )
            guard let self, self.requestID == currentRequestID else { return }
            switch status {
            case .installed:
                self.statusText = "Apple 翻译语言已就绪。"
            case .supported:
                guard requestDownload else {
                    self.statusText = "需要下载语言模型。选择语言时会请求授权，也可点“准备语言包”。"
                    return
                }
                self.statusText = "请在 Apple 弹窗中允许下载语言模型。"
                self.configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "zh-Hans"),
                    target: Locale.Language(identifier: identifier)
                )
            case .unsupported:
                self.statusText = "Apple 暂不支持简体中文到\(CandidateTranslationLanguagePreferences.languageName(for: identifier))的翻译。"
            @unknown default:
                self.statusText = "无法确认这个语言对是否可用。"
            }
        }
    }

    func prepare(_ session: TranslationSession) async {
        let currentRequestID = requestID
        do {
            try await session.prepareTranslation()
            guard requestID == currentRequestID else { return }
            configuration = nil
            statusText = "Apple 翻译语言已就绪。候选栏会使用所选语言。"
            NotificationCenter.default.post(
                name: .candidateTranslationLanguageDidChange,
                object: nil
            )
        } catch {
            guard requestID == currentRequestID else { return }
            configuration = nil
            statusText = "下载未完成。可稍后点“准备语言包”重试。"
        }
    }
}

@available(macOS 15.0, *)
struct CandidateTranslationLanguageSetupView: View {
    @ObservedObject var model: CandidateTranslationLanguageSetupModel

    var body: some View {
        HStack(spacing: 10) {
            Button("准备语言包") {
                model.requestDownload()
            }
            .disabled(model.configuration != nil)

            Text(model.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .translationTask(model.configuration) { session in
            await model.prepare(session)
        }
    }
}
