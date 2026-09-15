import Foundation
import InputMethodKit

/// Routing, key tracking and preset rules for native chord schemes, without
/// IMK or librime. The engine behaviour itself is yoyo-engine-smoke.
func runNativeChordSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("native-chord-smoke: FAIL \(message)")
        return false
    }
    func rejects(_ action: () throws -> Void) -> Bool {
        do { try action(); return false } catch { return true }
    }
    func key(_ character: Character) -> Int32 {
        Int32(character.unicodeScalars.first!.value)
    }

    let zhemei = NativeChordSchemeCatalog.yoyoZhemei
    let hanmei = NativeChordSchemeCatalog.yoyoHanmei

    // The presets must describe exactly the bundled schemas' alphabets.
    let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for preset in NativeChordSchemeCatalog.all {
        let schemaURL = repo.appendingPathComponent("rime-data/\(preset.schemaID).schema.yaml")
        guard let text = try? String(contentsOf: schemaURL, encoding: .utf8) else {
            return fail("\(preset.schemaID).schema.yaml is not bundled")
        }
        let declared = text.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("alphabet: \"123456") }?
            .components(separatedBy: "\"").dropFirst().first
        guard declared == NativeChordSchemeCatalog.alphabet(of: preset) else {
            return fail("\(preset.name) alphabet \(NativeChordSchemeCatalog.alphabet(of: preset)) differs from schema \(declared ?? "nil")")
        }
    }

    func routes(_ keycode: Int32, mask: Int32 = 0, profile: ChordKeymapProfile = zhemei,
                schema: String = "yoyo-yx", ascii: Bool = false, enabled: Bool = true) -> Bool {
        NativeChordRoutingRules.isChordKey(keycode: keycode, mask: mask, profile: profile,
                                           schemaID: schema, asciiMode: ascii,
                                           extensionEnabled: enabled)
    }
    guard routes(key("q")), routes(key(" ")), routes(key("1")), routes(key("[")),
          routes(key(";")), routes(key("=")), routes(key(".")),
          !routes(key("/")),
          routes(key("/"), profile: hanmei, schema: "yoyo-yx-hm"),
          !routes(key("'")), !routes(RimeKey.return), !routes(RimeKey.backspace),
          !routes(key("q"), mask: RimeKey.shiftMask),
          !routes(key("q"), mask: RimeKey.controlMask),
          !routes(key("q"), ascii: true),
          !routes(key("q"), enabled: false),
          !routes(key("q"), schema: "rime_ice"),
          !routes(key("q"), profile: hanmei, schema: "yoyo-yx"),
          !NativeChordRoutingRules.isChordKey(keycode: key("q"), mask: 0,
                                              profile: ChordKeymapProfile.newProfile(),
                                              schemaID: "yoyo-yx", asciiMode: false,
                                              extensionEnabled: true) else {
        return fail("native routing rules")
    }

    var down = NativeChordKeysDown()
    guard down.press(key("q"), hardwareKeyCode: 12),
          !down.press(key("q"), hardwareKeyCode: 12),
          down.press(key(" "), hardwareKeyCode: 49),
          down.press(key("["), hardwareKeyCode: 33),
          down.release(hardwareKeyCode: 49) == key(" "),
          down.release(hardwareKeyCode: 49) == nil,
          down.releaseAll(where: { $0 == 33 }) == [key("[")],
          down.hasKeys,
          down.releaseAll(where: { _ in true }) == [key("q")],
          !down.hasKeys,
          down.press(key("w"), hardwareKeyCode: 13, observedDown: false),
          down.press(key("e"), hardwareKeyCode: 14, observedDown: true),
          down.releasePhysicallyUp({ _ in false }) == [key("e")],
          down.hasKeys else {
        return fail("held key bookkeeping")
    }

    // Releases the host never sends are recovered from physical key state,
    // and a flush releases whatever is still held.
    let chord = ChordController()
    var released: [[Int32]] = []
    var physicallyDown: Set<UInt16> = [12, 49]
    chord.onNativeRelease = { keycodes, _ in released.append(keycodes) }
    chord.physicalKeyIsDown = { physicallyDown.contains($0) }
    let client: (any IMKTextInput)? = nil
    guard chord.noteNativePress(key("q"), hardwareKeyCode: 12, client: client),
          chord.noteNativePress(key(" "), hardwareKeyCode: 49, client: client),
          !chord.noteNativePress(key("q"), hardwareKeyCode: 12, client: client),
          chord.hasPending, chord.hasNativeKeysDown else {
        return fail("native press tracking")
    }
    physicallyDown.remove(49)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard released == [[key(" ")]], chord.hasNativeKeysDown,
          chord.takeNativeRelease(hardwareKeyCode: 49) == nil else {
        return fail("lost key-up fallback released \(released)")
    }
    chord.flush()
    guard released == [[key(" ")], [key("q")]], !chord.hasPending else {
        return fail("flush did not release held native keys: \(released)")
    }
    guard chord.noteNativePress(key("a"), hardwareKeyCode: 0, client: client),
          chord.takeNativeRelease(hardwareKeyCode: 0) == key("a"),
          !chord.hasPending else {
        return fail("delivered key-up bookkeeping")
    }
    // A key the physical state never saw down waits for its real key-up.
    physicallyDown = []
    guard chord.noteNativePress(key("s"), hardwareKeyCode: 1, client: client) else {
        return fail("unobserved press tracking")
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard chord.hasNativeKeysDown,
          chord.takeNativeRelease(hardwareKeyCode: 1) == key("s") else {
        return fail("physical state released a key it never saw down")
    }
    chord.invalidate()

    // Presets: read-only, resolved from the app, never generated or imported.
    guard zhemei.isNative, zhemei.isPreset, !zhemei.isBuiltIn,
          zhemei.schemaID == "yoyo-yx", hanmei.schemaID == "yoyo-yx-hm",
          ChordExtensionStore.isChordSchema("yoyo-yx"),
          ChordExtensionStore.isChordSchema("yoyo-yx-hm"),
          !ChordExtensionStore.isChordSchema("yoyo"),
          (try? zhemei.validated()) == zhemei,
          !FlyChordRoutingRules.shouldStage(schemaID: "yoyo-yx", asciiMode: false),
          StreamInputChordRoutingRules.route(
            for: ChordExtensionConfiguration(isEnabled: true, duration: 0.05),
            profile: zhemei
          ) == nil else {
        return fail("preset identity and gates")
    }
    var tampered = zhemei
    tampered.name = "改名"
    tampered.leftKeys = "q"
    guard (try? tampered.validated()) == zhemei else {
        return fail("stored native snapshot must resolve to the bundled preset")
    }
    var impostor = ChordKeymapProfile.newProfile()
    impostor.nativeSchemeID = "yoyo-yx"
    guard rejects({ _ = try impostor.validated(requireMappings: false) }) else {
        return fail("a custom keymap claimed a native schema")
    }
    do {
        _ = try FlyChordSchemaParser.loadActive(profile: zhemei)
        return fail("learning accepted a native scheme")
    } catch FlyChordSchemaError.nativeSchemeWithoutLessons {
    } catch {
        return fail("learning error \(error)")
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "rimes-native-chord-smoke-\(UUID().uuidString.lowercased())", isDirectory: true)
    let suite = "rimes.native-chord.smoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return fail("isolated defaults") }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? manager.removeItem(at: root)
    }
    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let builtin = ChordKeymapProfile(id: ChordKeymapProfile.builtInID, name: "飞耀输入",
                                         leftKeys: "qwertasdfgzxcvb", rightKeys: "yuiophjklnm,.",
                                         mappings: [.init(keys: "dv", output: "n", kind: .fragment)],
                                         boundaryPolicy: .legacyBatches)
        let store = ChordKeymapStore(rootURL: root, defaults: defaults, builtInLoader: { builtin })
        guard try store.allProfiles() == [builtin, zhemei, hanmei],
              try store.profile(id: hanmei.id) == hanmei,
              rejects({ try store.save(zhemei) }),
              rejects({ try store.remove(id: zhemei.id) }),
              rejects({ _ = try store.importData(store.exportData(zhemei)) }) else {
            return fail("store presets")
        }
        try store.activate(hanmei)
        let restarted = ChordKeymapStore(rootURL: root, defaults: defaults, builtInLoader: { builtin })
        guard restarted.activeProfile == hanmei, restarted.loadError == nil else {
            return fail("active native preset did not survive a restart")
        }
        let files = ChordKeymapRuntimeFiles(root: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try files.prepare(zhemei)
        // enabledIDs() normalizes against this process's active scheme, so
        // read the written list itself.
        let listed = (try? String(contentsOf: root.appendingPathComponent("default.custom.yaml"),
                                  encoding: .utf8)) ?? ""
        guard !manager.fileExists(atPath: root.appendingPathComponent("yoyo-yx.schema.yaml").path),
              listed.contains("- schema: yoyo-yx\n") else {
            return fail("activation must enable the bundled schema without generating one: \(listed)")
        }
        let preview = try ChordKeymapEditorViewController.preview(profile: zhemei, keys: "qw")
        guard preview.contains("呦呦音形 · 折梅") else { return fail("editor preview \(preview)") }
    } catch {
        return fail(error.localizedDescription)
    }

    print("native-chord-smoke: PASS routing, held keys, lost key-up fallback, presets, store and activation")
    return true
}
