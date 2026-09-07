import Foundation

extension Notification.Name {
    static let dailyMetricsPreferencesDidChange = Notification.Name("RIMES.DailyMetricsPreferences.didChange")
}

/// The merged statistics page retains each former extension's collection
/// choice. Opening a page or upgrading must not grant new telemetry consent.
final class DailyMetricsPreferences {
    static let shared = DailyMetricsPreferences()
    static let migrationKey = "statistics.collectionMigration.v2"
    private static let keyFrequencyKey = "statistics.recordsKeyFrequency.v2"
    private static let typingActivityKey = "statistics.recordsTypingActivity.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var recordsKeyFrequency: Bool {
        defaults.object(forKey: Self.keyFrequencyKey) as? Bool ?? true
    }
    var recordsTypingActivity: Bool {
        defaults.object(forKey: Self.typingActivityKey) as? Bool ?? true
    }

    func setKeyFrequencyEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.keyFrequencyKey)
        NotificationCenter.default.post(name: .dailyMetricsPreferencesDidChange, object: self)
    }

    func setTypingActivityEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.typingActivityKey)
        NotificationCenter.default.post(name: .dailyMetricsPreferencesDidChange, object: self)
    }

    /// Call before starting either built-in. The typing-test enablement itself
    /// is preserved; only its former passive observer moves to statistics.
    static func migrate(disabledIDs: inout Set<String>, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let keyEnabled = !disabledIDs.contains(BuiltInPluginID.statistics)
        let speedEnabled = !disabledIDs.contains(BuiltInPluginID.typingSpeed)
        defaults.set(keyEnabled, forKey: keyFrequencyKey)
        defaults.set(speedEnabled, forKey: typingActivityKey)
        if keyEnabled || speedEnabled { disabledIDs.remove(BuiltInPluginID.statistics) }
        defaults.set(true, forKey: migrationKey)
    }
}

func runDailyMetricsMigrationSmokeTest() -> Bool {
    let name = "RIMES.DailyMetricsSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else { return false }
    defer { defaults.removePersistentDomain(forName: name) }
    for keyEnabled in [false, true] {
        for speedEnabled in [false, true] {
            defaults.removePersistentDomain(forName: name)
            var disabled: Set<String> = ["unrelated"]
            if !keyEnabled { disabled.insert(BuiltInPluginID.statistics) }
            if !speedEnabled { disabled.insert(BuiltInPluginID.typingSpeed) }
            DailyMetricsPreferences.migrate(disabledIDs: &disabled, defaults: defaults)
            let preferences = DailyMetricsPreferences(defaults: defaults)
            guard preferences.recordsKeyFrequency == keyEnabled,
                  preferences.recordsTypingActivity == speedEnabled,
                  disabled.contains(BuiltInPluginID.statistics) == !(keyEnabled || speedEnabled),
                  disabled.contains(BuiltInPluginID.typingSpeed) == !speedEnabled,
                  disabled.contains("unrelated") else { return false }
            preferences.setTypingActivityEnabled(!speedEnabled)
            DailyMetricsPreferences.migrate(disabledIDs: &disabled, defaults: defaults)
            guard preferences.recordsTypingActivity == !speedEnabled else { return false }
        }
    }
    print("daily metrics migration smoke OK")
    return true
}
