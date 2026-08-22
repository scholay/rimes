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

/// Legacy compatibility model retained while old preferences and smoke tests
/// migrate. Product UI no longer exposes sequential/chord/mutual as a global
/// axis; chord and mutual now belong to `ChordExtensionStore`.
enum KeyingMode: String, CaseIterable, Codable {
    case sequential
    case chord
    case mutual

    var title: String {
        switch self {
        case .sequential: return "串击"
        case .chord: return "并击"
        case .mutual: return "互击"
        }
    }

    var implementationName: String? {
        switch self {
        case .chord: return "飞耀并击"
        case .mutual: return "飞耀互击"
        case .sequential: return nil
        }
    }
}

struct InputConfiguration: Equatable, Codable {
    var encoding: InputEncoding
    var keyingMode: KeyingMode

    static let defaultValue = InputConfiguration(encoding: .fullPinyin,
                                                 keyingMode: .sequential)
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
    static let profiles: [RuntimeInputProfile] = [
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
            schemaID: "my_combo",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .fullPinyin,
                                 keyingMode: .mutual),
            schemaID: "my_combo",
            lexiconFamily: .chinese
        ),
        RuntimeInputProfile(
            configuration: .init(encoding: .english,
                                 keyingMode: .sequential),
            schemaID: "english",
            lexiconFamily: .english
        ),
    ]

    static func profile(for configuration: InputConfiguration) -> RuntimeInputProfile? {
        profiles.first { $0.configuration == configuration }
    }

    static func profile(schemaID: String) -> RuntimeInputProfile? {
        // F4 can identify the Rime schema but cannot encode the host-side
        // same-batch/cross-batch settlement policy. FlyYao is now canonically
        // the mutual scheme; callers that are already on my_combo preserve
        // their complete configuration in InputConfigurationStore.adoptRuntimeSchema.
        if schemaID == "my_combo" {
            return profile(for: .init(encoding: .fullPinyin, keyingMode: .mutual))
        }
        return profiles.first { $0.schemaID == schemaID }
    }

    static func profile(schemaID: String,
                        chordMode: ChordExtensionMode) -> RuntimeInputProfile? {
        guard schemaID == ChordExtensionStore.schemaID else {
            return profile(schemaID: schemaID)
        }
        let keyingMode: KeyingMode = chordMode == .chord ? .chord : .mutual
        return profile(for: .init(encoding: .fullPinyin,
                                  keyingMode: keyingMode))
    }

    static func selecting(_ encoding: InputEncoding,
                          from current: InputConfiguration) -> InputConfiguration {
        var next = current
        next.encoding = encoding
        if encoding != .fullPinyin, next.keyingMode != .sequential {
            next.keyingMode = .sequential
        }
        return next
    }

    static func selecting(_ keyingMode: KeyingMode,
                          from current: InputConfiguration) -> InputConfiguration? {
        var next = current
        next.keyingMode = keyingMode
        if keyingMode == .chord || keyingMode == .mutual {
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
    /// the FlyYao mode comes from the optional extension's own store.
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
           stored != ChordExtensionStore.schemaID,
           InputConfigurationResolver.profile(schemaID: stored) != nil {
            return stored
        }
        return InputConfigurationResolver.profile(for: .defaultValue)!.schemaID
    }

    var runtimeProfile: RuntimeInputProfile {
        let schemaID = selectedSchemaID
        if schemaID == ChordExtensionStore.schemaID,
           chordExtensionStore.isEnabled,
           let profile = InputConfigurationResolver.profile(
                schemaID: schemaID,
                chordMode: chordExtensionStore.mode
           ) {
            return profile
        }
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
        case .chord:
            _ = chordExtensionStore.setMode(.chord, source: .migration)
            return select(schemaID: ChordExtensionStore.schemaID)
        case .mutual:
            _ = chordExtensionStore.setMode(.mutual, source: .migration)
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
        if schemaID == ChordExtensionStore.schemaID,
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
        switch configuration.keyingMode {
        case .chord:
            _ = chordExtensionStore.setMode(.chord, source: .migration)
        case .mutual:
            _ = chordExtensionStore.setMode(.mutual, source: .migration)
        case .sequential:
            break
        }
        return select(schemaID: profile.schemaID, source: .migration)
    }

    /// Called by the extension lifecycle before it publishes the disabled
    /// state. Pending session-local chords are retired by live controllers when
    /// they receive that later notification; the persisted target is already
    /// an ordinary schema by then.
    @discardableResult
    func fallBackFromChordScheme() -> Bool {
        guard selectedSchemaID == ChordExtensionStore.schemaID else {
            return false
        }
        return select(schemaID: lastOrdinarySchemaID, source: .rollback)
    }

    private func select(schemaID: String,
                        source: ChordExtensionChangeSource) -> Bool {
        guard let profile = InputConfigurationResolver.profile(
            schemaID: schemaID,
            chordMode: chordExtensionStore.mode
        ) else { return false }

        if schemaID == ChordExtensionStore.schemaID {
            _ = chordExtensionStore.setEnabled(true, source: source)
        }

        migrateSchemaSelectionIfNeeded()
        let changed = defaults.string(forKey: Key.selectedSchemaID) != schemaID
            || defaults.string(forKey: Key.preferredSchema) != schemaID
        defaults.set(schemaID, forKey: Key.selectedSchemaID)
        defaults.set(schemaID, forKey: Key.preferredSchema)
        if schemaID != ChordExtensionStore.schemaID {
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
            return
        }

        let legacyConfiguration: InputConfiguration? = {
            guard let encodingRaw = defaults.string(forKey: Key.encoding),
                  let keyingRaw = defaults.string(forKey: Key.keyingMode),
                  let encoding = InputEncoding(rawValue: encodingRaw),
                  let keyingMode = KeyingMode(rawValue: keyingRaw) else {
                return nil
            }
            var stored = InputConfiguration(encoding: encoding,
                                            keyingMode: keyingMode)
            // Preserve the one historical semantic migration: pre-v2 `.chord`
            // already behaved as today's independent-halves mode.
            if defaults.integer(forKey: Key.semanticsVersion)
                    < Self.currentSemanticsVersion,
               stored == .init(encoding: .fullPinyin, keyingMode: .chord) {
                stored.keyingMode = .mutual
            }
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
        if let profile = InputConfigurationResolver.profile(
            schemaID: schemaID,
            chordMode: chordExtensionStore.mode
        ) {
            persistLegacyProjection(profile.configuration)
        }
    }

    private func ensureOrdinaryFallbackExists(selectedSchemaID: String) {
        if selectedSchemaID != ChordExtensionStore.schemaID {
            defaults.set(selectedSchemaID, forKey: Key.lastOrdinarySchemaID)
            return
        }
        let existing = defaults.string(forKey: Key.lastOrdinarySchemaID)
        if existing == nil
            || existing == ChordExtensionStore.schemaID
            || InputConfigurationResolver.profile(schemaID: existing!) == nil {
            defaults.set(
                InputConfigurationResolver.profile(for: .defaultValue)!.schemaID,
                forKey: Key.lastOrdinarySchemaID
            )
        }
    }

    private func storedOrdinaryFallback() -> String {
        if let stored = defaults.string(forKey: Key.lastOrdinarySchemaID),
           stored != ChordExtensionStore.schemaID,
           InputConfigurationResolver.profile(schemaID: stored) != nil {
            return stored
        }
        return InputConfigurationResolver.profile(for: .defaultValue)!.schemaID
    }

    private func persistLegacyProjection(_ configuration: InputConfiguration) {
        defaults.set(configuration.encoding.rawValue, forKey: Key.encoding)
        defaults.set(configuration.keyingMode.rawValue, forKey: Key.keyingMode)
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
    static let options: [InputSchemaOption] = [
        InputSchemaOption(id: "rime_ice", name: "雾凇全拼", detail: "完整拼音输入"),
        InputSchemaOption(id: "double_pinyin", name: "自然码双拼", detail: "自然码双拼方案"),
        InputSchemaOption(id: "double_pinyin_flypy", name: "小鹤双拼", detail: "小鹤双拼方案"),
        InputSchemaOption(id: "wubi86", name: "五笔86", detail: "86 版五笔字型"),
        InputSchemaOption(id: "english", name: "英文", detail: "英文候选与补全"),
        InputSchemaOption(id: ChordExtensionStore.schemaID,
                          name: "飞耀输入",
                          detail: "由并击扩展提供",
                          requiresChordExtension: true),
    ]

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

    static func normalized(_ ids: [String]) -> [String] {
        let requested = Set(ids)
        return options.map(\.id).filter(requested.contains)
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

    static func writeEnabledIDs(_ requestedIDs: [String], to url: URL) throws {
        let ids = InputSchemaCatalog.normalized(requestedIDs)
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
