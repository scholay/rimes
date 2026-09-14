import Foundation

/// One public chord behavior: settle a batch, then allow its compatible next
/// half to complete it. Sequential schemas never participate in this policy.
struct ChordExtensionConfiguration: Equatable {
    let isEnabled: Bool
    let duration: TimeInterval

    var settlementPolicy: FlyChordSettlementPolicy { .independentHalves }
}

enum ChordExtensionChangeSource: String {
    case bootstrap
    case user
    case pluginLifecycle
    case schemaSelection
    case runtimeSchema
    case migration
    case rollback
}

enum ChordExtensionNotificationKey {
    static let previousEnabled = "previousEnabled"
    static let currentEnabled = "currentEnabled"
    static let source = "source"
}

extension Notification.Name {
    static let chordExtensionDidChange = Notification.Name(
        "RimeBuffer.ChordExtension.didChange"
    )
}

/// Authoritative product state for the optional “并击” extension.
///
/// Enablement is deliberately not inferred from the active Rime schema: the
/// extension may be enabled while another ordinary schema is selected. The
/// one-time bootstrap migrates only an actual legacy FlyYao selection. The old
/// learning-page switch was not an input-feature switch and is deliberately
/// ignored; mappings, duration, and learning progress remain untouched.
final class ChordExtensionStore {
    static var schemaID: String { ChordKeymapStore.shared.activeProfile.schemaID }
    static func isChordSchema(_ id: String) -> Bool {
        id == "my_combo" || id.hasPrefix("rimes_chord_")
    }
    static let pluginID = "builtin.fly-chord-learning"

    static let shared = ChordExtensionStore(
        defaults: .standard,
        fallbackBeforeDisable: {
            _ = InputConfigurationStore.shared.fallBackFromChordScheme()
        }
    )

    private enum Key {
        static let enabled = "chord.extension.enabled.v1"
        // Retained only for old builds: their "mutual" value denotes today's
        // one unified behavior. No live API reads a user-selectable mode.
        static let legacyExtensionMode = "chord.extension.mode.v1"
        static let unifiedSemantics = "chord.extension.unifiedSemantics.v1"
        static let duration = "chord.duration"
        static let durationMigration = "chord.duration.legacyConfigMigrated.v1"

        // Migration-only keys. Keep their spelling stable until every shipped
        // profile has crossed the v1 extension boundary.
        static let legacyEncoding = "input.configuration.encoding.v1"
        static let legacyKeyingMode = "input.configuration.keyingMode.v1"
        static let legacyPreferredSchema = "preferredSchema"
        static let selectedSchema = "input.configuration.schemaID.v2"
    }

    private let defaults: UserDefaults
    private let fallbackBeforeDisable: (() -> Void)?
    private var bootstrapped = false

    init(defaults: UserDefaults = .standard,
         fallbackBeforeDisable: (() -> Void)? = nil) {
        self.defaults = defaults
        self.fallbackBeforeDisable = fallbackBeforeDisable
    }

    @discardableResult
    func bootstrap() -> ChordExtensionConfiguration {
        migrateIfNeeded()
        return configuration
    }

    var isEnabled: Bool {
        migrateIfNeeded()
        return defaults.bool(forKey: Key.enabled)
    }

    var settlementPolicy: FlyChordSettlementPolicy { .independentHalves }

    var implementationName: String {
        "\(ChordKeymapStore.shared.activeProfile.name) · 并击"
    }

    var duration: TimeInterval {
        get {
            if defaults === UserDefaults.standard { return ChordSettings.duration }
            // Isolated stores must not read or migrate live standard defaults.
            guard defaults.object(forKey: Key.duration) != nil else { return ChordSettings.defaultDuration }
            return Self.clampedDuration(defaults.double(forKey: Key.duration))
        }
        set {
            if defaults === UserDefaults.standard {
                ChordSettings.duration = newValue
            } else {
                defaults.set(Self.clampedDuration(newValue), forKey: Key.duration)
                defaults.set(true, forKey: Key.durationMigration)
            }
        }
    }

    var configuration: ChordExtensionConfiguration {
        ChordExtensionConfiguration(isEnabled: isEnabled,
                                    duration: duration)
    }

    /// Returns true only when the effective state changed. The shared store
    /// first moves an active `my_combo` preference to its last ordinary schema;
    /// runtime controllers then receive `.chordExtensionDidChange` and retire
    /// any session-local pending batch before applying that fallback.
    @discardableResult
    func setEnabled(_ enabled: Bool,
                    source: ChordExtensionChangeSource = .user) -> Bool {
        migrateIfNeeded()
        let previousEnabled = defaults.bool(forKey: Key.enabled)
        if !enabled {
            fallbackBeforeDisable?()
        }
        guard previousEnabled != enabled else { return false }

        defaults.set(enabled, forKey: Key.enabled)
        IMELog.write("chord_extension enabled=\(enabled) source=\(source.rawValue)")
        postChange(previousEnabled: previousEnabled,
                   currentEnabled: enabled,
                   source: source)
        return true
    }

    func resetDuration() {
        if defaults === UserDefaults.standard {
            ChordSettings.resetToDefault()
        } else {
            defaults.removeObject(forKey: Key.duration)
            defaults.set(true, forKey: Key.durationMigration)
        }
    }

    private static func clampedDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return ChordSettings.defaultDuration }
        return min(max(duration, ChordSettings.range.lowerBound), ChordSettings.range.upperBound)
    }

    private func migrateIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let hadExplicitEnabled = defaults.object(forKey: Key.enabled) != nil
        let legacyMode = defaults.string(forKey: Key.legacyKeyingMode)
            .flatMap(KeyingMode.init(rawValue:))

        // Both the old strict "chord" and the old "mutual" preference now
        // resolve to the same independent-halves behavior. Keep the legacy
        // wire value compatible with downgrade, including a later old-build
        // write, without recreating an independently selectable runtime mode.
        if defaults.string(forKey: Key.legacyExtensionMode) != "mutual" {
            defaults.set("mutual", forKey: Key.legacyExtensionMode)
        }
        if defaults.integer(forKey: Key.unifiedSemantics) < 1 {
            defaults.set(1, forKey: Key.unifiedSemantics)
        }

        if !hadExplicitEnabled {
            let selectedSchema = defaults.string(forKey: Key.selectedSchema)
            let authoritativeSchema = selectedSchema.flatMap { schemaID -> String? in
                // A replaced custom chord ID is still a valid chord-family
                // selection; the configuration store retargets it separately.
                Self.isChordSchema(schemaID)
                    || InputConfigurationResolver.profile(schemaID: schemaID) != nil
                    ? schemaID : nil
            }
            let preferredIsChord = defaults.string(forKey: Key.legacyPreferredSchema)
                .map(Self.isChordSchema) == true
            let legacyConfigurationIsChord =
                defaults.string(forKey: Key.legacyEncoding)
                    == InputEncoding.fullPinyin.rawValue
                && (legacyMode == .chord || legacyMode == .mutual)

            // Only a real legacy FlyYao selection enables the new input
            // feature. The former learning page was enabled by default for
            // many ordinary users, so treating that UI switch as authority
            // would accidentally opt almost every upgrade into chord input.
            // v2 is authoritative over stale v1 tuples. Otherwise bootstrap
            // order could enable an ordinary user when the extension reads
            // first, but disable them when the configuration projection reads
            // first and replaces that stale tuple with "sequential".
            let enabled = authoritativeSchema.map(Self.isChordSchema)
                ?? (preferredIsChord || legacyConfigurationIsChord)
            defaults.set(enabled, forKey: Key.enabled)
            IMELog.write(
                "chord_extension bootstrap enabled=\(enabled) "
                    + "legacySchema=\(preferredIsChord) "
                    + "legacyConfig=\(legacyConfigurationIsChord)"
            )
        }
    }

    private func postChange(previousEnabled: Bool,
                            currentEnabled: Bool,
                            source: ChordExtensionChangeSource) {
        NotificationCenter.default.post(
            name: .chordExtensionDidChange,
            object: self,
            userInfo: [
                ChordExtensionNotificationKey.previousEnabled: previousEnabled,
                ChordExtensionNotificationKey.currentEnabled: currentEnabled,
                ChordExtensionNotificationKey.source: source.rawValue,
            ]
        )
    }
}
