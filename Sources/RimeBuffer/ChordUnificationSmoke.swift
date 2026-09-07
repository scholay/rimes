import Foundation

/// Migration and resolver checks use private suites and an isolated keymap
/// directory. In particular configuration reads never touch live durations.
func runChordUnificationSmokeTest() -> Bool {
    enum Failure: Error { case assertion(String) }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "rimes-chord-unification-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    var suites: [String] = []
    defer {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try? manager.removeItem(at: root)
    }

    func makeDefaults(_ label: String, values: [String: Any] = [:]) throws -> UserDefaults {
        let name = "RIMES.ChordUnificationSmoke.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            throw Failure.assertion("cannot create isolated defaults")
        }
        suites.append(name)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    let enabledKey = "chord.extension.enabled.v1"
    let oldModeKey = "chord.extension.mode.v1"
    let unifiedKey = "chord.extension.unifiedSemantics.v1"
    let selectedKey = "input.configuration.schemaID.v2"
    let previousOrdinaryKey = "input.configuration.lastOrdinarySchemaID.v2"
    let encodingKey = "input.configuration.encoding.v1"
    let keyingKey = "input.configuration.keyingMode.v1"
    let semanticsKey = "input.configuration.keyingMode.semantics.v2"
    let durationKey = "chord.duration"

    do {
        let chordID = ChordExtensionStore.schemaID
        let expectedChord = InputConfiguration(encoding: .fullPinyin, keyingMode: .chord)
        let fresh = try makeDefaults("fresh")
        let freshChord = ChordExtensionStore(defaults: fresh)
        let freshInput = InputConfigurationStore(defaults: fresh, chordExtensionStore: freshChord)
        let configuration = freshChord.bootstrap()
        try check(!configuration.isEnabled && configuration.duration == ChordSettings.defaultDuration,
                  "fresh extension must remain off with the default duration")
        try check(configuration.settlementPolicy == .independentHalves
                    && freshChord.settlementPolicy == .independentHalves,
                  "unified configuration must always allow independent halves")
        try check(freshInput.configuration == .defaultValue
                    && freshInput.selectedSchemaID == "rime_ice"
                    && freshInput.lastOrdinarySchemaID == "rime_ice",
                  "fresh extension migration changed ordinary selection")
        try check(!freshInput.adoptRuntimeSchema(chordID) && !freshChord.isEnabled,
                  "stale F4 chord entry enabled a fresh extension")
        try check(fresh.string(forKey: oldModeKey) == "mutual"
                    && fresh.integer(forKey: unifiedKey) == 1,
                  "unified downgrade spelling or migration marker missing")

        let profiles = InputConfigurationResolver.profiles
        try check(profiles.count == 6
                    && Set(profiles.map(\.schemaID)).count == profiles.count
                    && profiles.filter { $0.configuration.keyingMode == .chord }.count == 1
                    && !profiles.contains { $0.configuration.keyingMode == .mutual }
                    && KeyingMode.allCases == [.sequential, .chord],
                  "resolver still exposes two live chord modes")
        for oldName in [KeyingMode.chord, .mutual] {
            let legacy = InputConfiguration(encoding: .fullPinyin, keyingMode: oldName)
            try check(InputConfigurationResolver.profile(for: legacy)?.configuration == expectedChord,
                      "legacy mode did not normalize in profile lookup")
            try check(InputConfigurationResolver.selecting(oldName, from: .defaultValue) == expectedChord,
                      "legacy mode did not normalize in selection")
            try check(InputConfigurationResolver.selecting(.fullPinyin, from: legacy) == expectedChord,
                      "encoding selection retained legacy mode")
            try check(InputConfigurationResolver.selecting(.wubi86, from: legacy)
                        == InputConfiguration(encoding: .wubi86, keyingMode: .sequential),
                      "non-pinyin encoding retained chord behavior")
        }
        try check(InputConfigurationResolver.profile(schemaID: chordID)?.configuration == expectedChord
                    && InputConfigurationResolver.profile(for: .init(encoding: .wubi86, keyingMode: .mutual)) == nil,
                  "schema lookup or unsupported encoding resolver invariant")
        let decodedLegacy = try JSONDecoder().decode(
            InputConfiguration.self,
            from: Data(#"{"encoding":"fullPinyin","keyingMode":"mutual"}"#.utf8)
        )
        try check(decodedLegacy.keyingMode == .mutual
                    && InputConfigurationResolver.profile(for: decodedLegacy)?.configuration == expectedChord,
                  "legacy Codable compatibility")

        // Strict, mutual and unknown stored mode values cannot create a second
        // runtime behavior. Explicit enablement and future semantics survive.
        for oldMode in ["chord", "mutual", "unknown"] {
            let defaults = try makeDefaults("explicit-\(oldMode)", values: [
                enabledKey: true, oldModeKey: oldMode,
                selectedKey: chordID, "preferredSchema": chordID,
                previousOrdinaryKey: "wubi86", semanticsKey: 99,
                encodingKey: "fullPinyin", keyingKey: oldMode == "mutual" ? "mutual" : "chord",
                durationKey: 0.073,
                "chord.keymap.activeID.v1": "fixture-profile-identity",
                "fixture.learning.progress": ["attempts": 19],
            ])
            let chord = ChordExtensionStore(defaults: defaults)
            let input = InputConfigurationStore(defaults: defaults, chordExtensionStore: chord)
            try check(chord.bootstrap().isEnabled
                        && chord.settlementPolicy == .independentHalves
                        && input.configuration == expectedChord
                        && input.selectedSchemaID == chordID
                        && input.lastOrdinarySchemaID == "wubi86",
                      "explicit \(oldMode) state did not normalize")
            try check(chord.duration == 0.073 && defaults.double(forKey: durationKey) == 0.073
                        && defaults.integer(forKey: semanticsKey) == 99
                        && defaults.string(forKey: oldModeKey) == "mutual"
                        && defaults.string(forKey: keyingKey) == "mutual"
                        && defaults.string(forKey: "chord.keymap.activeID.v1") == "fixture-profile-identity"
                        && (defaults.dictionary(forKey: "fixture.learning.progress")?["attempts"] as? Int) == 19,
                      "migration changed duration, future semantics, profile or learning state")
            let beforeRestart = defaults.dictionaryRepresentation() as NSDictionary
            let restartedChord = ChordExtensionStore(defaults: defaults)
            let restartedInput = InputConfigurationStore(defaults: defaults, chordExtensionStore: restartedChord)
            for _ in 0..<3 {
                try check(restartedChord.bootstrap() == chord.configuration
                            && restartedInput.configuration == expectedChord
                            && restartedInput.lastOrdinarySchemaID == "wubi86",
                          "migration not stable after restart")
            }
            try check(beforeRestart.isEqual(to: defaults.dictionaryRepresentation()),
                      "repeated migration changed preferences")
        }

        // Pre-extension v1/v2 configurations migrate regardless of the old
        // strict-vs-mutual semantics marker. They still keep their cadence.
        for version in [0, 1, 2, 99] {
            for oldMode in ["chord", "mutual"] {
                let defaults = try makeDefaults("legacy-\(version)-\(oldMode)", values: [
                    "preferredSchema": chordID, encodingKey: "fullPinyin",
                    keyingKey: oldMode, semanticsKey: version, durationKey: 0.05,
                ])
                let chord = ChordExtensionStore(defaults: defaults)
                let input = InputConfigurationStore(defaults: defaults, chordExtensionStore: chord)
                try check(chord.isEnabled && input.configuration == expectedChord
                            && chord.duration == 0.05 && input.selectedSchemaID == chordID
                            && defaults.string(forKey: oldModeKey) == "mutual"
                            && defaults.integer(forKey: semanticsKey) == max(2, version),
                          "old semantics \(version)/\(oldMode) migration")
            }
        }

        // A disabled extension cannot be resurrected by stale selected schema,
        // an old alias, or a mode migration. Preserve the remembered fallback.
        for oldMode in ["chord", "mutual"] {
            for storedSchema in [chordID, "rimes_chord_stale_fixture"] {
                let defaults = try makeDefaults("disabled-\(oldMode)", values: [
                    enabledKey: false, oldModeKey: oldMode,
                    selectedKey: storedSchema, "preferredSchema": storedSchema,
                    previousOrdinaryKey: "double_pinyin", encodingKey: "fullPinyin",
                    keyingKey: oldMode, durationKey: 0.12,
                ])
                let chord = ChordExtensionStore(defaults: defaults)
                let input = InputConfigurationStore(defaults: defaults, chordExtensionStore: chord)
                try check(!chord.isEnabled && input.selectedSchemaID == "double_pinyin"
                            && input.configuration == .init(encoding: .naturalDoublePinyin, keyingMode: .sequential)
                            && !input.adoptRuntimeSchema(chordID) && !chord.isEnabled
                            && chord.duration == 0.12,
                          "disabled residue migration re-enabled chord or changed fallback")
            }
        }

        for enabled in [false, true] {
            let defaults = try makeDefaults("ordinary-\(enabled)", values: [
                enabledKey: enabled, oldModeKey: "chord", selectedKey: "wubi86",
                "preferredSchema": "wubi86", previousOrdinaryKey: "wubi86", durationKey: 0.08,
            ])
            let chord = ChordExtensionStore(defaults: defaults)
            let input = InputConfigurationStore(defaults: defaults, chordExtensionStore: chord)
            try check(chord.isEnabled == enabled && input.selectedSchemaID == "wubi86"
                        && input.configuration == .init(encoding: .wubi86, keyingMode: .sequential)
                        && chord.duration == 0.08,
                      "mode migration changed current ordinary scheme or enablement")
        }
        // A known v2 ordinary selection wins over stale v1 chord tuples even
        // when no explicit extension enablement has been persisted yet. Both
        // bootstrap orders must reach precisely the same disabled state.
        for oldMode in ["chord", "mutual"] {
            for extensionReadsFirst in [true, false] {
                let defaults = try makeDefaults("v2-priority-\(oldMode)-\(extensionReadsFirst)", values: [
                    selectedKey: "rime_ice", "preferredSchema": chordID,
                    encodingKey: "fullPinyin", keyingKey: oldMode,
                    oldModeKey: oldMode, durationKey: 0.067,
                ])
                let chord = ChordExtensionStore(defaults: defaults)
                let input = InputConfigurationStore(defaults: defaults, chordExtensionStore: chord)
                if extensionReadsFirst { _ = chord.bootstrap() }
                else { _ = input.selectedSchemaID }
                try check(!chord.isEnabled && input.selectedSchemaID == "rime_ice"
                            && input.configuration == .defaultValue
                            && !defaults.bool(forKey: enabledKey)
                            && chord.duration == 0.067,
                          "v2 ordinary schema lost precedence under read order \(extensionReadsFirst)/\(oldMode)")
            }
        }
        // Invalid v2 residue is not an authoritative choice. Preserve a valid
        // older chord selection when that is the only recoverable preference.
        let invalidV2 = try makeDefaults("invalid-v2", values: [
            selectedKey: "unknown-schema", "preferredSchema": chordID,
            encodingKey: "fullPinyin", keyingKey: "mutual",
        ])
        let invalidV2Chord = ChordExtensionStore(defaults: invalidV2)
        let invalidV2Input = InputConfigurationStore(defaults: invalidV2, chordExtensionStore: invalidV2Chord)
        try check(invalidV2Chord.isEnabled && invalidV2Input.configuration == expectedChord,
                  "invalid v2 residue blocked valid legacy migration")
        let learningOnly = try makeDefaults("learning-only", values: [
            "preferredSchema": "english", "plugins.internal.disabledIDs": [String](),
        ])
        let learningChord = ChordExtensionStore(defaults: learningOnly)
        let learningInput = InputConfigurationStore(defaults: learningOnly, chordExtensionStore: learningChord)
        try check(!learningChord.isEnabled && learningInput.selectedSchemaID == "english",
                  "old learning-page switch enabled chord input")

        let lifecycleDefaults = try makeDefaults("lifecycle", values: ["preferredSchema": "wubi86"])
        weak var lifecycleInput: InputConfigurationStore?
        let lifecycleChord = ChordExtensionStore(defaults: lifecycleDefaults, fallbackBeforeDisable: {
            _ = lifecycleInput?.fallBackFromChordScheme()
        })
        let input = InputConfigurationStore(defaults: lifecycleDefaults, chordExtensionStore: lifecycleChord)
        lifecycleInput = input
        try check(input.selectedSchemaID == "wubi86" && !lifecycleChord.isEnabled,
                  "lifecycle initial ordinary state")
        try check(lifecycleChord.setEnabled(true) && input.selectedSchemaID == "wubi86",
                  "enabling extension implicitly selected its schema")
        try check(input.select(keyingMode: .mutual) && input.configuration == expectedChord,
                  "legacy explicit selection did not select canonical chord")
        try check(input.select(keyingMode: .chord) && input.configuration == expectedChord,
                  "canonical explicit selection failed")
        try check(input.set(.init(encoding: .fullPinyin, keyingMode: .mutual))
                    && input.configuration == expectedChord,
                  "legacy complete configuration did not normalize")
        try check(lifecycleChord.setEnabled(false) && !lifecycleChord.isEnabled
                    && input.selectedSchemaID == "wubi86" && !input.adoptRuntimeSchema(chordID),
                  "safe disable lost ordinary fallback")

        // A private profile with differing saved/applied revisions must remain
        // byte-for-byte unchanged while its extension preferences migrate.
        let profileDefaults = try makeDefaults("profiles", values: [
            enabledKey: true, oldModeKey: "chord", durationKey: 0.061,
        ])
        var builtin = ChordKeymapProfile.newProfile(name: "Fixture built-in")
        builtin.id = ChordKeymapProfile.builtInID
        builtin.mappings = [.init(keys: "dv", output: "n", kind: .fragment)]
        let keymaps = ChordKeymapStore(rootURL: root, defaults: profileDefaults,
                                      builtInLoader: { builtin })
        var profile = builtin.duplicated(name: "Applied profile")
        try keymaps.save(profile)
        try keymaps.activate(profile)
        let activeBefore = keymaps.activeProfile
        profile.name = "Saved but unapplied draft"
        profile.mappings[0].output = "m"
        try keymaps.save(profile)
        let draftURL = keymaps.directoryURL.appendingPathComponent(profile.id + ".json")
        let draftBytes = try Data(contentsOf: draftURL)
        let snapshotBytes = try Data(contentsOf: keymaps.activeProfileURL)
        let profileChord = ChordExtensionStore(defaults: profileDefaults)
        _ = profileChord.bootstrap()
        let profileChordRestart = ChordExtensionStore(defaults: profileDefaults)
        _ = profileChordRestart.bootstrap()
        try check(keymaps.activeProfile == activeBefore
                    && profileDefaults.string(forKey: "chord.keymap.activeID.v1") == profile.id
                    && profileChord.duration == 0.061
                    && (try Data(contentsOf: draftURL)) == draftBytes
                    && (try Data(contentsOf: keymaps.activeProfileURL)) == snapshotBytes,
                  "unification changed keymap drafts or applied snapshot")
        print("chord-unification-smoke: PASS unified runtime, legacy migrations, restart, disable, ordinary schema, duration and profile preservation")
        return true
    } catch Failure.assertion(let message) {
        print("chord-unification-smoke: FAIL \(message)")
        return false
    } catch {
        print("chord-unification-smoke: FAIL \(error.localizedDescription)")
        return false
    }
}
