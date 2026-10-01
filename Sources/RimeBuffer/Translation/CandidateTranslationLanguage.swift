import Foundation
import Translation

extension Notification.Name {
    static let candidateTranslationLanguageDidChange = Notification.Name(
        "RimeBuffer.CandidateTranslationLanguage.didChange"
    )
}

enum CandidateTranslationLanguagePreferences {
    static let defaultLanguageID = "en"
    static let defaultsKey = "candidateWindow.translationTargetLanguage.v1"

    static var targetLanguageID: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? defaultLanguageID
    }

    @discardableResult
    static func setTargetLanguageID(_ identifier: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 35,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || $0 == "-" || $0 == "_"
              }) else {
            return false
        }
        guard value != targetLanguageID else { return true }
        UserDefaults.standard.set(value, forKey: defaultsKey)
        NotificationCenter.default.post(
            name: .candidateTranslationLanguageDidChange,
            object: nil
        )
        return true
    }

    static func fallbackOptions() -> [TranslationLanguageOption] {
        ["en", "ja", "ko", "fr", "de", "es", "it", "pt", "zh-Hant"]
            .map(languageOption(identifier:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func supportedOptions() async -> [TranslationLanguageOption] {
        guard #available(macOS 15.0, *) else { return fallbackOptions() }
        let languages = await LanguageAvailability().supportedLanguages
        let identifiers = Set(languages.map(\.minimalIdentifier).filter {
            !TranslationLanguageIdentity.matches($0, expected: "zh-Hans")
        })
        let options = identifiers.map(languageOption(identifier:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return options.isEmpty ? fallbackOptions() : options
    }

    static func languageName(for identifier: String) -> String {
        languageOption(identifier: identifier).title
    }

    private static func languageOption(identifier: String) -> TranslationLanguageOption {
        let locale = Locale.current
        let title = locale.localizedString(forIdentifier: identifier)
            ?? locale.localizedString(forLanguageCode: identifier)
            ?? identifier
        return TranslationLanguageOption(identifier: identifier, title: title)
    }
}
