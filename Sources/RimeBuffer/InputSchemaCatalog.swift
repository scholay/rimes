import Foundation

enum InputEncoding: String, CaseIterable, Codable {
    case fullPinyin
    case naturalDoublePinyin
    case xiaoheDoublePinyin
    case wubi86
    case english

    var title: String {
        switch self {
        case .fullPinyin: return "雾凇全拼"
        case .naturalDoublePinyin: return "自然码双拼"
        case .xiaoheDoublePinyin: return "小鹤双拼"
        case .wubi86: return "五笔86"
        case .english: return "英文"
        }
    }
}

/// Compatibility spelling for old preferences. `mutual` is decode/migration
/// only; every live chord configuration is canonicalized to `chord`.
enum KeyingMode: String, CaseIterable, Codable {
    case sequential
    case chord
    case mutual

    static let allCases: [KeyingMode] = [.sequential, .chord]
    var canonical: KeyingMode { self == .mutual ? .chord : self }

    var title: String {
        switch self {
        case .sequential: return "串击"
        case .chord, .mutual: return "并击"
        }
    }

    var implementationName: String? {
        switch self {
        case .chord, .mutual: return ChordExtensionStore.shared.implementationName
        case .sequential: return nil
        }
    }
}

struct InputConfiguration: Equatable, Codable {
    var encoding: InputEncoding
    var keyingMode: KeyingMode

    static let defaultValue = InputConfiguration(encoding: .fullPinyin,
                                                 keyingMode: .sequential)

    var canonical: InputConfiguration {
        InputConfiguration(encoding: encoding, keyingMode: keyingMode.canonical)
    }
}

struct RuntimeInputProfile: Equatable {
    enum LexiconFamily: String {
        case chinese
        case wubi86
        case english
    }

    let configuration: InputConfiguration
    let schemaID: String
    let lexiconFamily: LexiconFamily
}

enum InputConfigurationResolver {
    static var profiles: [RuntimeInputProfile] { [
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .sequential),
            schemaID: "rime_ice",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .naturalDoublePinyin,
                                 keyingMode: .sequential),
            schemaID: "double_pinyin",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .xiaoheDoublePinyin,
                                 keyingMode: .sequential),
            schemaID: "double_pinyin_flypy",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .wubi86,
                                 keyingMode: .sequential),
            schemaID: "wubi86",
            lexiconFamily: .wubi86
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .chord),
            schemaID: ChordExtensionStore.schemaID,
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .english,
                                 keyingMode: .sequential),
            schemaID: "english",
            lexiconFamily: .english
        ),
    ] }

    static func profile(for configuration: InputConfiguration) -> RuntimeInputProfile? {
        profiles.first { $0.configuration == configuration.canonical }
    }

    static func profile(schemaID: String) -> RuntimeInputProfile? {
        profiles.first { $0.schemaID == schemaID }
    }

    static func selecting(_ encoding: InputEncoding,
                          from current: InputConfiguration) -> InputConfiguration {
        var next = current.canonical
        next.encoding = encoding
        if encoding != .fullPinyin, next.keyingMode != .sequential {
            next.keyingMode = .sequential
        }
        return next
    }

    static func selecting(_ keyingMode: KeyingMode,
                          from current: InputConfiguration) -> InputConfiguration? {
        var next = current.canonical
        next.keyingMode = keyingMode.canonical
        if next.keyingMode == .chord {
            next.encoding = .fullPinyin
        }
        return profile(for: next) == nil ? nil : next
    }
}

extension Notification.Name {
    static let inputConfigurationDidChange = Notification.Name(
        "RimeBuffer.InputConfiguration.didChange"
    )
}

final class InputConfigurationStore {
    static let shared = InputConfigurationStore()

    private enum Key {
        static let selectedSchemaID = "input.configuration.schemaID.v2"
        static let lastOrdinarySchemaID =
            "input.configuration.lastOrdinarySchemaID.v2"
        static let encoding = "input.configuration.encoding.v1"
        static let keyingMode = "input.configuration.keyingMode.v1"
        static let preferredSchema = "preferredSchema"
        static let semanticsVersion = "input.configuration.keyingMode.semantics.v2"
    }

    private static let currentSemanticsVersion = 2

    private let defaults: UserDefaults
    private let chordExtensionStore: ChordExtensionStore

    init(defaults: UserDefaults = .standard,
         chordExtensionStore: ChordExtensionStore? = nil) {
        self.defaults = defaults
        if let chordExtensionStore {
            self.chordExtensionStore = chordExtensionStore
        } else if defaults === UserDefaults.standard {
            self.chordExtensionStore = .shared
        } else {
            self.chordExtensionStore = ChordExtensionStore(defaults: defaults)
        }
    }

    /// Compatibility projection for callers that still speak the old
    /// InputEncoding x KeyingMode model. Runtime selection is schema-driven;
    /// every chord scheme uses the extension's one independent-halves policy.
    var configuration: InputConfiguration {
        runtimeProfile.configuration
    }

    var selectedSchemaID: String {
        migrateSchemaSelectionIfNeeded()
        return defaults.string(forKey: Key.selectedSchemaID)
            ?? InputConfigurationResolver.profile(for: .defaultValue)!.schemaID
    }

    var lastOrdinarySchemaID: String {
        migrateSchemaSelectionIfNeeded()
        let stored = defaults.string(forKey: Key.lastOrdinarySchemaID)
        if let stored,
           !ChordExtensionStore.isChordSchema(stored),
           InputConfigurationResolver.profile(schemaID: stored) != nil {
            return stored
        }
        return InputConfigurationResolver.profile(for: .defaultValue)!.schemaID
    }

    var runtimeProfile: RuntimeInputProfile {
        let schemaID = selectedSchemaID
        return InputConfigurationResolver.profile(schemaID: schemaID)
            ?? InputConfigurationResolver.profile(for: .defaultValue)!
    }

    @discardableResult
    func select(encoding: InputEncoding) -> Bool {
        guard let profile = InputConfigurationResolver.profiles.first(where: {
            $0.configuration.encoding == encoding
                && $0.configuration.keyingMode == .sequential
        }) else { return false }
        return select(schemaID: profile.schemaID)
    }

    /// Returns false for a mode that has no installed runtime implementation.
    /// The old valid selection is preserved, so settings can never leave the
    /// live IME pointing at a schema that does not exist.
    @discardableResult
    func select(keyingMode: KeyingMode) -> Bool {
        switch keyingMode {
        case .sequential:
            if selectedSchemaID == ChordExtensionStore.schemaID {
                return fallBackFromChordScheme()
            }
            return true
        case .chord, .mutual:
            return select(schemaID: ChordExtensionStore.schemaID)
        }
    }

    /// Selects one concrete deployed schema. Choosing FlyYao is also an
    /// explicit request to enable its owning extension; choosing an ordinary
    /// schema remembers a safe fallback without disabling the extension.
    @discardableResult
    func select(schemaID: String) -> Bool {
        select(schemaID: schemaID, source: .schemaSelection)
    }

    @discardableResult
    func adoptRuntimeSchema(_ schemaID: String) -> Bool {
        // A stale F4 list from an older deployment is not an enable gesture.
        // Once the user turns the extension off, runtime switcher residue must
        // fail closed instead of silently resurrecting it.
        if ChordExtensionStore.isChordSchema(schemaID),
           !chordExtensionStore.isEnabled {
            _ = fallBackFromChordScheme()
            IMELog.write("input_schema rejected disabled runtime chord schema")
            return false
        }
        return select(schemaID: schemaID, source: .runtimeSchema)
    }

    @discardableResult
    func set(_ configuration: InputConfiguration) -> Bool {
        guard let profile = InputConfigurationResolver.profile(for: configuration) else {
            return false
        }
        return select(schemaID: profile.schemaID, source: .migration)
    }

    /// Called by the extension lifecycle before it publishes the disabled
    /// state. Pending session-local chords are retired by live controllers when
    /// they receive that later notification; the persisted target is already
    /// an ordinary schema by then.
    @discardableResult
    func fallBackFromChordScheme() -> Bool {
        guard ChordExtensionStore.isChordSchema(selectedSchemaID) else {
            return false
        }
        return select(schemaID: lastOrdinarySchemaID, source: .rollback)
    }

    private func select(schemaID: String,
                        source: ChordExtensionChangeSource) -> Bool {
        guard let profile = InputConfigurationResolver.profile(schemaID: schemaID) else { return false }

        if schemaID == ChordExtensionStore.schemaID {
            _ = chordExtensionStore.setEnabled(true, source: source)
        }

        migrateSchemaSelectionIfNeeded()
        let changed = defaults.string(forKey: Key.selectedSchemaID) != schemaID
            || defaults.string(forKey: Key.preferredSchema) != schemaID
        defaults.set(schemaID, forKey: Key.selectedSchemaID)
        defaults.set(schemaID, forKey: Key.preferredSchema)
        if !ChordExtensionStore.isChordSchema(schemaID) {
            defaults.set(schemaID, forKey: Key.lastOrdinarySchemaID)
        }
        persistLegacyProjection(profile.configuration)
        if changed {
            IMELog.write("input_schema selected=\(schemaID) source=\(source.rawValue)")
            NotificationCenter.default.post(name: .inputConfigurationDidChange,
                                            object: self)
        }
        return true
    }

    private func migrateSchemaSelectionIfNeeded() {
        // A profile activation replaces the one optional runtime chord schema.
        // Retarget persisted/F4 residue without treating it as an enable action.
        if let stored = defaults.string(forKey: Key.selectedSchemaID),
           ChordExtensionStore.isChordSchema(stored),
           stored != ChordExtensionStore.schemaID {
            let replacement = chordExtensionStore.isEnabled
                ? ChordExtensionStore.schemaID : storedOrdinaryFallback()
            defaults.set(replacement, forKey: Key.selectedSchemaID)
            defaults.set(replacement, forKey: Key.preferredSchema)
        }
        if let stored = defaults.string(forKey: Key.selectedSchemaID),
           InputConfigurationResolver.profile(schemaID: stored) != nil {
            // `selectedSchemaID` can outlive a deploy or a crashed settings
            // transaction. Once the extension has an explicit disabled state,
            // that residue is not an enable gesture: fail closed to the last
            // ordinary schema. Legacy profiles without the extension key are
            // still enabled by ChordExtensionStore's one-time migration.
            if stored == ChordExtensionStore.schemaID,
               !chordExtensionStore.isEnabled {
                let fallback = storedOrdinaryFallback()
                defaults.set(fallback, forKey: Key.selectedSchemaID)
                defaults.set(fallback, forKey: Key.preferredSchema)
                defaults.set(fallback, forKey: Key.lastOrdinarySchemaID)
                if let profile = InputConfigurationResolver.profile(
                    schemaID: fallback
                ) {
                    persistLegacyProjection(profile.configuration)
                }
                IMELog.write(
                    "input_schema retired disabled persisted chord schema "
                        + "fallback=\(fallback)"
                )
                return
            }
            ensureOrdinaryFallbackExists(selectedSchemaID: stored)
            if let profile = InputConfigurationResolver.profile(schemaID: stored) {
                persistLegacyProjection(profile.configuration)
            }
            return
        }

        let legacyConfiguration: InputConfiguration? = {
            guard let encodingRaw = defaults.string(forKey: Key.encoding),
                  let keyingRaw = defaults.string(forKey: Key.keyingMode),
                  let encoding = InputEncoding(rawValue: encodingRaw),
                  let keyingMode = KeyingMode(rawValue: keyingRaw) else {
                return nil
            }
            // Both old names, under every shipped semantics version, become
            // one canonical runtime chord configuration.
            let stored = InputConfiguration(encoding: encoding,
                                             keyingMode: keyingMode.canonical)
            return InputConfigurationResolver.profile(for: stored) == nil
                ? nil : stored
        }()

        let legacySchemaID = legacyConfiguration
            .flatMap(InputConfigurationResolver.profile(for:))?.schemaID
            ?? defaults.string(forKey: Key.preferredSchema)
                .flatMap(InputConfigurationResolver.profile(schemaID:))?.schemaID
        var schemaID = legacySchemaID
            ?? InputConfigurationResolver.profile(for: .defaultValue)!.schemaID

        // ChordExtensionStore owns the migration decision. It enables genuine
        // legacy chord users, but an already-persisted explicit `false` must
        // win over stale v1 keying/preferred-schema residue.
        if schemaID == ChordExtensionStore.schemaID,
           !chordExtensionStore.isEnabled {
            schemaID = storedOrdinaryFallback()
            IMELog.write(
                "input_schema rejected disabled legacy chord preference "
                    + "fallback=\(schemaID)"
            )
        }
        defaults.set(schemaID, forKey: Key.selectedSchemaID)
        defaults.set(schemaID, forKey: Key.preferredSchema)
        ensureOrdinaryFallbackExists(selectedSchemaID: schemaID)
        if let profile = InputConfigurationResolver.profile(schemaID: schemaID) {
            persistLegacyProjection(profile.configuration)
        }
    }

    private func ensureOrdinaryFallbackExists(selectedSchemaID: String) {
        if !ChordExtensionStore.isChordSchema(selectedSchemaID) {
            defaults.set(selectedSchemaID, forKey: Key.lastOrdinarySchemaID)
            return
        }
        let existing = defaults.string(forKey: Key.lastOrdinarySchemaID)
        if existing == nil
            || existing.map(ChordExtensionStore.isChordSchema) == true
            || InputConfigurationResolver.profile(schemaID: existing!) == nil {
            defaults.set(
                InputConfigurationResolver.profile(for: .defaultValue)!.schemaID,
                forKey: Key.lastOrdinarySchemaID
            )
        }
    }

    private func storedOrdinaryFallback() -> String {
        if let stored = defaults.string(forKey: Key.lastOrdinarySchemaID),
           !ChordExtensionStore.isChordSchema(stored),
           InputConfigurationResolver.profile(schemaID: stored) != nil {
            return stored
        }
        return InputConfigurationResolver.profile(for: .defaultValue)!.schemaID
    }

    private func persistLegacyProjection(_ configuration: InputConfiguration) {
        if defaults.string(forKey: Key.encoding) != configuration.encoding.rawValue {
            defaults.set(configuration.encoding.rawValue, forKey: Key.encoding)
        }
        // Runtime speaks `.chord`; an older build understands independent
        // halves as `.mutual`. Preserve that wire spelling for safe downgrade.
        let legacyKeyingMode = configuration.keyingMode == .sequential
            ? KeyingMode.sequential.rawValue : KeyingMode.mutual.rawValue
        if defaults.string(forKey: Key.keyingMode) != legacyKeyingMode {
            defaults.set(legacyKeyingMode, forKey: Key.keyingMode)
        }
        if defaults.integer(forKey: Key.semanticsVersion) < Self.currentSemanticsVersion {
            defaults.set(Self.currentSemanticsVersion, forKey: Key.semanticsVersion)
        }
    }
}

struct InputSchemaOption {
    let id: String
    let name: String
    let detail: String
    let requiresChordExtension: Bool

    init(id: String,
         name: String,
         detail: String,
         requiresChordExtension: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.requiresChordExtension = requiresChordExtension
    }
}

/// The product-level schema catalog. Supporting schemas such as melt_eng and
/// radical_pinyin stay on disk as dependencies, but never appear here or in
/// the user's F4 switcher.
enum InputSchemaCatalog {
    static var options: [InputSchemaOption] { [
        InputSchemaOption(id: "rime_ice", name: "雾凇全拼", detail: "完整拼音输入"),
        InputSchemaOption(id: "double_pinyin", name: "自然码双拼", detail: "自然码双拼方案"),
        InputSchemaOption(id: "double_pinyin_flypy", name: "小鹤双拼", detail: "小鹤双拼方案"),
        InputSchemaOption(id: "wubi86", name: "五笔86", detail: "86 版五笔字型"),
        InputSchemaOption(id: "english", name: "英文", detail: "英文候选与补全"),
        InputSchemaOption(id: ChordExtensionStore.schemaID,
                          name: ChordKeymapStore.shared.activeProfile.name,
                          detail: "由并击扩展提供",
                          requiresChordExtension: true),
    ] }

    /// Fresh profiles expose ordinary schemes only. Enabling the optional
    /// chord extension appends `my_combo` through the same catalog order.
    static var defaultEnabledIDs: [String] {
        enabledIDs(chordExtensionEnabled: false)
    }

    static func enabledIDs(chordExtensionEnabled: Bool) -> [String] {
        options.compactMap { option in
            (!option.requiresChordExtension || chordExtensionEnabled)
                ? option.id : nil
        }
    }

    static func normalized(_ ids: [String], chordSchemaID: String? = nil) -> [String] {
        let requested = Set(ids)
        let available = options.map { option in
            option.requiresChordExtension ? (chordSchemaID ?? option.id) : option.id
        }
        return available.filter(requested.contains)
    }
}

/// Reads and rewrites only `patch.schema_list` while preserving the rest of
/// default.custom.yaml (menu size and future unrelated settings).
enum SchemaListStore {
    enum StoreError: LocalizedError {
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .emptySelection: return "至少保留一个输入方案。"
            }
        }
    }

    static func enabledIDs(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "schema_list:"
        }) else { return [] }

        let baseIndent = leadingSpaceCount(lines[start])
        var ids: [String] = []
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if leadingSpaceCount(line) <= baseIndent { break }
            guard trimmed.hasPrefix("- schema:") else { continue }
            let rawID = trimmed
                .dropFirst("- schema:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let id = String(rawID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !id.isEmpty { ids.append(id) }
        }
        return InputSchemaCatalog.normalized(ids)
    }

    static func writeEnabledIDs(_ requestedIDs: [String], to url: URL,
                                chordSchemaID: String? = nil) throws {
        let ids = InputSchemaCatalog.normalized(requestedIDs, chordSchemaID: chordSchemaID)
        guard !ids.isEmpty else { throw StoreError.emptySelection }

        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "patch:\n  schema_list:\n  menu:\n    page_size: 9\n"
        var lines = text.components(separatedBy: .newlines)
        let itemLines = ids.map { "    - schema: \($0)" }

        if let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "schema_list:"
        }) {
            let baseIndent = leadingSpaceCount(lines[start])
            var end = start + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, leadingSpaceCount(lines[end]) <= baseIndent { break }
                end += 1
            }
            lines.replaceSubrange((start + 1)..<end, with: itemLines + [""])
        } else if let patchIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "patch:"
        }) {
            lines.insert(contentsOf: ["  schema_list:"] + itemLines + [""], at: patchIndex + 1)
        } else {
            if !lines.isEmpty, lines.last != "" { lines.append("") }
            lines.append(contentsOf: ["patch:", "  schema_list:"] + itemLines + [""])
        }

        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }

        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try? manager.copyItem(at: url, to: backup)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
