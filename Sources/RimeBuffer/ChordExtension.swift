import Foundation

/// The two settlement behaviours supplied by the optional chord extension.
/// Ordinary Rime schemas are sequential by definition and therefore do not
/// participate in this model.
enum ChordExtensionMode: String, CaseIterable, Codable {
    case chord
    case mutual

    var title: String {
        switch self {
        case .chord: return "并击"
        case .mutual: return "互击"
        }
    }

    var implementationName: String {
        switch self {
        case .chord: return "飞耀并击"
        case .mutual: return "飞耀互击"
        }
    }

    var settlementPolicy: FlyChordSettlementPolicy {
        switch self {
        case .chord: return .sameBatchOnly
        case .mutual: return .independentHalves
        }
    }
}

struct ChordExtensionConfiguration: Equatable {
    let isEnabled: Bool
    let mode: ChordExtensionMode
    let duration: TimeInterval
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
    static let previousMode = "previousMode"
    static let currentMode = "currentMode"
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
    static let schemaID = "my_combo"
    static let pluginID = "builtin.fly-chord-learning"

    static let shared = ChordExtensionStore(
        defaults: .standard,
        fallbackBeforeDisable: {
            _ = InputConfigurationStore.shared.fallBackFromChordScheme()
        }
    )

    private enum Key {
        static let enabled = "chord.extension.enabled.v1"
        static let mode = "chord.extension.mode.v1"

        // Migration-only keys. Keep their spelling stable until every shipped
        // profile has crossed the v1 extension boundary.
        static let legacyEncoding = "input.configuration.encoding.v1"
        static let legacyKeyingMode = "input.configuration.keyingMode.v1"
        static let legacyKeyingModeSemantics =
            "input.configuration.keyingMode.semantics.v2"
        static let legacyPreferredSchema = "preferredSchema"
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

    var mode: ChordExtensionMode {
        migrateIfNeeded()
        return defaults.string(forKey: Key.mode)
            .flatMap(ChordExtensionMode.init(rawValue:)) ?? .mutual
    }

    var duration: TimeInterval {
        get { ChordSettings.duration }
        set { ChordSettings.duration = newValue }
    }

    var configuration: ChordExtensionConfiguration {
        ChordExtensionConfiguration(isEnabled: isEnabled,
                                    mode: mode,
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
        let previousMode = mode

        if !enabled {
            fallbackBeforeDisable?()
        }
        guard previousEnabled != enabled else { return false }

        defaults.set(enabled, forKey: Key.enabled)
        IMELog.write("chord_extension enabled=\(enabled) source=\(source.rawValue)")
        postChange(previousEnabled: previousEnabled,
                   currentEnabled: enabled,
                   previousMode: previousMode,
                   currentMode: previousMode,
                   source: source)
        return true
    }

    @discardableResult
    func setMode(_ mode: ChordExtensionMode,
                 source: ChordExtensionChangeSource = .user) -> Bool {
        migrateIfNeeded()
        let previousMode = self.mode
        guard previousMode != mode else { return false }
        let enabled = isEnabled
        defaults.set(mode.rawValue, forKey: Key.mode)
        IMELog.write("chord_extension mode=\(mode.rawValue) source=\(source.rawValue)")
        postChange(previousEnabled: enabled,
                   currentEnabled: enabled,
                   previousMode: previousMode,
                   currentMode: mode,
                   source: source)
        return true
    }

    func resetDuration() {
        ChordSettings.resetToDefault()
    }

    private func migrateIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true

        let hadExplicitEnabled = defaults.object(forKey: Key.enabled) != nil
        let hadExplicitMode = defaults.object(forKey: Key.mode) != nil

        let legacyMode = defaults.string(forKey: Key.legacyKeyingMode)
            .flatMap(KeyingMode.init(rawValue:))
        let migratedMode: ChordExtensionMode
        switch legacyMode {
        case .chord where defaults.integer(
            forKey: Key.legacyKeyingModeSemantics
        ) >= 2:
            migratedMode = .chord
        case .chord:
            // In the first shipped model `.chord` named the only FlyYao
            // behaviour, which already supported independent halves. Preserve
            // that historical meaning exactly once.
            migratedMode = .mutual
        case .mutual, .sequential, .none: migratedMode = .mutual
        }
        if !hadExplicitMode {
            defaults.set(migratedMode.rawValue, forKey: Key.mode)
        }

        if !hadExplicitEnabled {
            let preferredIsChord = defaults.string(
                forKey: Key.legacyPreferredSchema
            ) == Self.schemaID
            let legacyConfigurationIsChord =
                defaults.string(forKey: Key.legacyEncoding)
                    == InputEncoding.fullPinyin.rawValue
                && (legacyMode == .chord || legacyMode == .mutual)

            // Only a real legacy FlyYao selection enables the new input
            // feature. The former learning page was enabled by default for
            // many ordinary users, so treating that UI switch as authority
            // would accidentally opt almost every upgrade into chord input.
            let enabled = preferredIsChord
                || legacyConfigurationIsChord
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
                            previousMode: ChordExtensionMode,
                            currentMode: ChordExtensionMode,
                            source: ChordExtensionChangeSource) {
        NotificationCenter.default.post(
            name: .chordExtensionDidChange,
            object: self,
            userInfo: [
                ChordExtensionNotificationKey.previousEnabled: previousEnabled,
                ChordExtensionNotificationKey.currentEnabled: currentEnabled,
                ChordExtensionNotificationKey.previousMode: previousMode.rawValue,
                ChordExtensionNotificationKey.currentMode: currentMode.rawValue,
                ChordExtensionNotificationKey.source: source.rawValue,
            ]
        )
    }
}
