import Foundation

/// Isolated model, portable-file, activation-snapshot and compiler coverage.
/// The caller can add live-engine compilation tests using its isolated userdir.
func runChordKeymapSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("chord-keymap-smoke: FAIL \(message)")
        return false
    }
    func rejects(_ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch { return true }
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "rimes-chord-keymap-smoke-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let suite = "rimes.chord-keymap.smoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return fail("isolated defaults") }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? manager.removeItem(at: root)
    }

    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = try FlyChordSchemaParser.parse(
            """
            schema:
              schema_id: my_combo
            chord_composer:
              alphabet: 'qwertyuiopasdfghjklzxcvbnm,.'
              algebra:
                - 'xform/^dv$/n/'
                - 'xform/^km$/ong/'
                - 'xform/^dvkm$/nong/'
                - 'xform/^dvi$/ni/'
            """,
            sourceURL: root.appendingPathComponent("fixture.schema.yaml")
        )
        let builtin = try ChordKeymapProfile.builtIn(from: schema).validated()
        guard builtin.isBuiltIn, builtin.schemaID == "my_combo",
              builtin.boundaryPolicy == .legacyBatches,
              builtin.duplicated().boundaryPolicy == .legacyBatches,
              builtin.mappings.count == schema.mappings.count,
              builtin.entry(for: [100, 118])?.kind == .fragment,
              builtin.entry(for: [100, 118, 105])?.kind == .syllable,
              builtin.half(for: 100) == .left,
              builtin.half(for: 105) == .right,
              builtin.half(for: -1) == nil else { return fail("built-in conversion and layout") }

        let store = ChordKeymapStore(rootURL: root, defaults: defaults,
                                    builtInLoader: { builtin })
        guard store.activeProfile == builtin, store.loadError == nil,
              try store.allProfiles() == [builtin] else { return fail("initial state") }

        var profile = ChordKeymapProfile.newProfile(name: "测试 ' 键位")
        guard profile.boundaryPolicy == .explicitSyllables else { return fail("new profile boundary policy") }
        profile.leftKeys = "ab"
        profile.rightKeys = "cv,."
        profile.mappings = [
            .init(keys: "ba", output: "cv", kind: .fragment),
            .init(keys: "vc", output: "ni", kind: .syllable),
            .init(keys: ".,", output: "abcdefghijk", kind: .fragment),
            .init(keys: "v.a", output: "er", kind: .syllable),
        ]
        profile = try profile.validated()
        guard profile.mappings.map(\.keys) == ["ab", "cv", ",.", "av."],
              profile.canonicalKeys("vba") == "abv",
              profile.canonicalKeys("ab!") == "ab!",
              profile.entry(for: [98, 97])?.output == "cv",
              profile.entry(for: [97]) == nil,
              profile.entry(for: [97, -1]) == nil,
              profile.schemaID == "rimes_chord_" + profile.id.replacingOccurrences(of: "-", with: "")
        else { return fail("canonical set and singleton rules") }

        var duplicate = profile
        duplicate.mappings.append(.init(keys: "ba", output: "hao", kind: .syllable))
        guard rejects({ _ = try duplicate.validated() }) else { return fail("unordered duplicate accepted") }
        var invalid = profile
        invalid.leftKeys += "a"
        guard rejects({ _ = try invalid.validated() }) else { return fail("duplicate layout key accepted") }
        invalid = profile
        invalid.rightKeys += "a"
        guard rejects({ _ = try invalid.validated() }) else { return fail("cross-zone key overlap accepted") }
        for keys in ["a", "aa", "ad", "a ", "aA", "a\n", "a😀"] {
            invalid = profile
            invalid.mappings = [.init(keys: keys, output: "ni", kind: .syllable)]
            guard rejects({ _ = try invalid.validated() }) else { return fail("invalid keys accepted: \(keys)") }
        }
        for output in ["", "NI", "n i", "n'i", "ü", "ni\n", "~0~", String(repeating: "a", count: 33)] {
            invalid = profile
            invalid.mappings[0].output = output
            guard rejects({ _ = try invalid.validated() }) else { return fail("invalid output accepted") }
        }
        invalid = profile
        invalid.formatVersion = 2
        guard rejects({ _ = try invalid.validated() }) else { return fail("future version accepted") }
        invalid = profile
        invalid.id = "../../unsafe"
        guard rejects({ _ = try invalid.validated() }) else { return fail("unsafe ID accepted") }
        invalid = profile
        invalid.name = "name\nengine:"
        guard rejects({ _ = try invalid.validated() }) else { return fail("multiline name accepted") }

        let draft = ChordKeymapProfile.newProfile(name: "空草稿")
        try store.save(draft)
        guard try store.profile(id: draft.id) == draft,
              rejects({ try store.activate(draft) }),
              rejects({ _ = try ChordKeymapCompiler.schemaYAML(for: draft) }) else {
            return fail("draft persistence and activation boundary")
        }
        let data = try store.exportData(profile)
        let imported = try store.importData(data)
        guard imported.id != profile.id, imported.mappings == profile.mappings,
              imported.name == profile.name, imported.leftKeys == profile.leftKeys,
              imported.rightKeys == profile.rightKeys,
              try store.importData(store.exportData(builtin)).isBuiltIn == false,
              rejects({ _ = try store.importData(Data("not json".utf8)) }),
              rejects({ _ = try store.importData(Data(repeating: 0, count: ChordKeymapProfile.maximumFileBytes + 1)) })
        else { return fail("portable import and fresh identity") }
        var oldDocument = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        oldDocument.removeValue(forKey: "boundaryPolicy")
        let oldData = try JSONSerialization.data(withJSONObject: oldDocument)
        guard try store.importData(oldData).boundaryPolicy == .explicitSyllables,
              try store.importData(store.exportData(builtin)).boundaryPolicy == .legacyBatches else {
            return fail("backward-compatible boundary policy import")
        }
        oldDocument["boundaryPolicy"] = "unsupported-policy"
        guard rejects({ _ = try store.importData(JSONSerialization.data(withJSONObject: oldDocument)) }) else {
            return fail("unknown boundary policy accepted")
        }
        try store.save(profile)
        guard try store.profile(id: profile.id) == profile,
              try store.allProfiles().count == 3,
              rejects({ try store.save(builtin) }),
              rejects({ try store.remove(id: builtin.id) }) else { return fail("store CRUD") }

        // Notifications represent effective changes, never editing events.
        var activationNotifications = 0
        let observation = NotificationCenter.default.addObserver(
            forName: .chordKeymapDidChange, object: nil, queue: nil
        ) { note in
            guard let sender = note.object as? ChordKeymapStore, sender === store else { return }
            activationNotifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        try store.setActiveProfile(id: profile.id)
        guard store.activeProfile == profile, activationNotifications == 1,
              rejects({ try store.remove(id: profile.id) }) else { return fail("activation and delete guard") }

        var edited = profile
        edited.mappings[0].output = "hao"
        try store.save(edited)
        let restarted = ChordKeymapStore(rootURL: root, defaults: defaults,
                                        builtInLoader: { builtin })
        guard store.activeProfile == profile, restarted.activeProfile == profile,
              activationNotifications == 1,
              try restarted.profile(id: profile.id) == edited else {
            return fail("saving active draft changed running or restarted snapshot")
        }
        try store.activate(edited)
        try store.activate(profile) // Deployment rollback must keep newer draft.
        guard store.activeProfile == profile,
              try store.profile(id: profile.id) == edited,
              activationNotifications == 3 else { return fail("exact revision activation/rollback") }

        let permissions = try manager.attributesOfItem(atPath: store.activeProfileURL.path)
        guard (permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            return fail("effective snapshot permissions")
        }
        let savedURL = store.directoryURL.appendingPathComponent(profile.id + ".json")
        guard (try manager.attributesOfItem(atPath: savedURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            return fail("draft permissions")
        }

        // Both known and unknown chords must be event-order independent. Use
        // the actual generated algebra, not a mirror of the compiler algorithm.
        func compiledRules(_ profile: ChordKeymapProfile) throws -> [(NSRegularExpression, String)] {
            try ChordKeymapCompiler.algebraRules(for: profile).map { rule -> (NSRegularExpression, String) in
                let parts = rule.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 4, parts[0] == "xform", parts[3].isEmpty else {
                    throw ChordKeymapError.invalid("compiler produced malformed algebra")
                }
                return (try NSRegularExpression(pattern: String(parts[1])), String(parts[2]))
            }
        }
        let rules = try compiledRules(profile)
        func evaluate(_ input: String, using override: [(NSRegularExpression, String)]? = nil) -> String {
            (override ?? rules).reduce(input) { value, rule in
                rule.0.stringByReplacingMatches(in: value,
                                                range: NSRange(value.startIndex..., in: value),
                                                withTemplate: rule.1)
            }
        }
        func permutations(_ characters: [Character]) -> [String] {
            if characters.isEmpty { return [""] }
            return characters.indices.flatMap { index -> [String] in
                var remaining = characters
                let first = remaining.remove(at: index)
                return permutations(remaining).map { String(first) + $0 }
            }
        }
        let alphabet = Array(profile.alphabet)
        var permutationCount = 0
        for mask in 1..<(1 << alphabet.count) {
            let selected = alphabet.indices.filter { mask & (1 << $0) != 0 }.map { alphabet[$0] }
            if selected.count > 4 { continue }
            let canonical = String(selected)
            let fallback = selected.count == 1 ? canonical
                : String(canonical.filter { $0 != "," && $0 != "." })
            let expected = profile.mappings.first(where: { $0.keys == canonical })?.output ?? fallback
            for input in permutations(selected) {
                guard evaluate(input) == expected else { return fail("compiled map differs for \(input)") }
                permutationCount += 1
            }
        }
        let yaml = try ChordKeymapCompiler.schemaYAML(for: profile)
        guard evaluate("ba") == "cv", evaluate("vc") == "ni",
              evaluate(".,") == "abcdefghijk", evaluate("v") == "v",
              yaml.contains("name: '测试 '' 键位'"),
              yaml.contains("schema_id: \(profile.schemaID)"),
              yaml.contains("__include: rime_ice.schema:/"),
              yaml.contains("punct: \"^$\""), !yaml.contains("v_filter") else {
            return fail("compiled collision, full-output or schema inheritance")
        }
        var punctuationFallback = profile
        punctuationFallback.mappings.removeAll { $0.keys == ",." }
        let fallbackRules = try compiledRules(punctuationFallback)
        guard evaluate(",.", using: fallbackRules).isEmpty,
              evaluate(".,", using: fallbackRules).isEmpty,
              evaluate(".", using: fallbackRules) == ".",
              evaluate(",", using: fallbackRules) == ",",
              evaluate(".v,b", using: fallbackRules) == "bv" else {
            return fail("unknown mixed and punctuation-only fallback")
        }

        // Imported/saved files cannot redirect managed reads or writes. A bad
        // profile is reported instead of disappearing from the editor roster.
        let unsafeID = UUID().uuidString.lowercased()
        let unsafeURL = store.directoryURL.appendingPathComponent(unsafeID + ".json")
        try manager.createSymbolicLink(at: unsafeURL, withDestinationURL: savedURL)
        var unsafeProfile = profile
        unsafeProfile.id = unsafeID
        guard rejects({ _ = try store.profile(id: unsafeID) }),
              rejects({ _ = try store.allProfiles() }),
              rejects({ try store.save(unsafeProfile) }) else { return fail("symlink accepted") }
        try manager.removeItem(at: unsafeURL)

        let corruptID = UUID().uuidString.lowercased()
        let corruptURL = store.directoryURL.appendingPathComponent(corruptID + ".json")
        try Data("{}".utf8).write(to: corruptURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corruptURL.path)
        guard rejects({ _ = try store.allProfiles() }) else { return fail("corrupt draft silently omitted") }
        try manager.removeItem(at: corruptURL)

        try Data("{}".utf8).write(to: store.activeProfileURL)
        let recovered = ChordKeymapStore(rootURL: root, defaults: defaults,
                                        builtInLoader: { builtin })
        guard recovered.activeProfile == builtin, recovered.loadError != nil,
              try recovered.profile(id: profile.id) == edited else {
            return fail("corrupt active snapshot used an unapplied draft")
        }
        print("chord-keymap-smoke: PASS profiles, snapshots, import, validation, \(permutationCount) compiled permutations")
        return true
    } catch {
        return fail(error.localizedDescription)
    }
}
