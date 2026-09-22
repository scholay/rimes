import Foundation
import Security
import RimesCore

func L(_ zh: String, _ en: String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en }

struct AppConfiguration: Codable {
    var scheme: InputScheme = .pinyin
    var schemeSelectionRevision: UUID?
    var chord = ChordProfile.builtIn
    /// Keep the persisted mapping format intact; the default keyboard uses the
    /// same pinyin-to-Ziranma encoding layer as desktop Ziranma chord profiles.
    var keyboardChord: ChordProfile {
        var profile = chord
        if profile.id == ChordProfile.builtIn.id { profile.outputEncoding = .ziranma }
        return profile
    }
    var profiles: [ChordProfile] = []
    var providers: [ProviderConfiguration] = []
    var selectedProvider: UUID?
    var consents: [String] = []
    var translationLanguage = "English"
    var provider: ProviderConfiguration? { providers.first { $0.id == selectedProvider } }
}
/// Only the containing app writes this snapshot. The keyboard never requires group write access.
final class ConfigurationStore: ConfigurationStorage {
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "RIMESAppGroup") as? String ?? "group.org.scholay.rimes.ios" }
    private var root: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var file: URL { root.appendingPathComponent("configuration-v1.json") }
    func load() -> AppConfiguration {
        guard let data = try? Data(contentsOf: file), data.count < 8 * 1024 * 1024,
              var value = try? JSONDecoder().decode(AppConfiguration.self, from: data),
              value.providers.count <= 32, value.profiles.count <= 128 else { return AppConfiguration() }
        value.chord = (try? value.chord.validated()) ?? .builtIn
        value.profiles = value.profiles.compactMap { try? $0.validated() }
        return value
    }
    func save(_ value: AppConfiguration) throws {
        _ = try value.chord.validated()
        guard value.providers.count <= 32, value.profiles.count <= 128 else { throw CoreError.tooLarge }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
    }
}
final class KeychainStore: ProviderSecretStore {
    private func query(_ id: UUID) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.scholay.rimes.ios.providers", kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false]
        if let group = Bundle.main.object(forInfoDictionaryKey: "RIMESKeychainGroup") as? String, !group.contains("$(") { q[kSecAttrAccessGroup as String] = group }
        return q
    }
    func read(_ id: UUID) throws -> String {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var object: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &object)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = object as? Data, let key = String(data: data, encoding: .utf8) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }
    func save(_ key: String, id: UUID) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let q = query(id)
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var entry = q; attributes.forEach { entry[$0.key] = $0.value }; status = SecItemAdd(entry as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

final class KeyboardPreferenceStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> KeyboardPreferences {
        guard let data = defaults.data(forKey: "keyboard-preferences-v1"),
              let value = try? JSONDecoder().decode(KeyboardPreferences.self, from: data) else { return .init() }
        return value
    }
    func save(_ value: KeyboardPreferences) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "keyboard-preferences-v1") }
    }
}
