import XCTest
@testable import RIMES
import RimesCore

@MainActor final class EngineTests: XCTestCase {
    func testBundledChineseEngines() throws {
        let engine = MobileEngine()
        XCTAssertTrue(engine.available)
        for (schema,code,expected) in [("rimes_pinyin","nihao","你好"),("rimes_ziranma","nihk","你好"),("rimes_wubi","wq","你")] {
            XCTAssertTrue(engine.select(schema:schema),schema)
            var state = EngineSnapshot()
            for c in code.unicodeScalars { state = engine.process(key:Int32(c.value)) }
            let index = try XCTUnwrap(state.candidates.firstIndex(of:expected),"\(schema): \(state.candidates)")
            XCTAssertEqual(engine.candidate(index).commit,expected)
            engine.clear()
        }
    }
    func testDefaultChordUsesZiranmaForSinglesFragmentsAndSyllables() throws {
        let config = AppConfiguration()
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
        let profile = restored.keyboardChord
        XCTAssertEqual(profile.outputEncoding, .ziranma)
        XCTAssertEqual(profile.mappings, config.chord.mappings)
        for entry in profile.mappings { XCTAssertNotNil(profile.encoded(entry), entry.keys) }
        XCTAssertEqual(profile.resolve(Set("ef"))?.input, "u")
        let engine = MobileEngine()
        XCTAssertTrue(engine.select(schema: "rimes_ziranma"))
        for key: Character in ["g", "h"] {
            let resolved = try XCTUnwrap(profile.resolve([key]))
            for c in resolved.input.unicodeScalars { _ = engine.process(key: Int32(c.value)) }
        }
        XCTAssertEqual(engine.rawInput, "gh")
        XCTAssertEqual(engine.currentSnapshot.preedit, "gang")
        XCTAssertTrue(engine.currentSnapshot.candidates.contains("刚"))
        engine.clear()
        for code in [try XCTUnwrap(profile.resolve(Set("ef"))).input, "h"] {
            for c in code.unicodeScalars { _ = engine.process(key: Int32(c.value)) }
        }
        XCTAssertEqual(engine.rawInput, "uh")
        XCTAssertEqual(engine.currentSnapshot.preedit, "shang")
        engine.clear()
        let syllable = try XCTUnwrap(profile.mappings.first { $0.kind == .syllable && $0.output == "ni" })
        let code = try XCTUnwrap(profile.resolve(Set(syllable.keys))).input
        XCTAssertEqual(code, "ni")
        for c in code.unicodeScalars { _ = engine.process(key: Int32(c.value)) }
        XCTAssertEqual(engine.currentSnapshot.preedit, "ni")
        XCTAssertTrue(engine.currentSnapshot.candidates.contains("你"))
        var custom = config; custom.chord = config.chord.copy()
        XCTAssertEqual(custom.keyboardChord.outputEncoding, .fullPinyin)
        custom.chord.outputEncoding = .ziranma
        XCTAssertEqual(custom.keyboardChord.outputEncoding, .ziranma)
    }
    func testDirectionalSlideCodesDecodeToRequestedSyllables() throws {
        let profile = AppConfiguration().keyboardChord
        let engine = MobileEngine(); XCTAssertTrue(engine.select(schema: "rimes_ziranma"))
        for (path, expected) in [("ty", "ting"), ("gh", "gang"), ("bn", "bin"), ("tyu", "tu"), ("ghj", "gan"), ("bnm", "bian"), ("bh", "bang"), ("th", "tang"), ("gy", "guai")] {
            engine.clear()
            var gesture = ChordGesture(); gesture.begin(id: 1, key: path.first, profile: profile)
            for key in path.dropFirst() { gesture.move(id: 1, key: key, profile: profile) }
            let result = try XCTUnwrap(gesture.end(id: 1, key: path.last, profile: profile))
            for scalar in result.input.unicodeScalars { _ = engine.process(key: Int32(scalar.value)) }
            XCTAssertEqual(engine.currentSnapshot.preedit, expected, path)
            XCTAssertFalse(engine.currentSnapshot.candidates.isEmpty, path)
        }
    }
    func testSwitchingSchemaRetiresComposition() {
        let engine = MobileEngine(); XCTAssertTrue(engine.select(schema:"rimes_pinyin"))
        _ = engine.process(key:110); _ = engine.process(key:105)
        XCTAssertTrue(engine.select(schema:"rimes_wubi"))
        let state = engine.process(key:119)
        XCTAssertFalse(state.preedit.contains("ni"))
    }
    func testRawInputUsesEngineCodeAndOnlyDropsGeneratedChordSeparators() {
        let engine = MobileEngine()
        XCTAssertTrue(engine.select(schema: "rimes_ziranma"))
        for scalar in "nihk".unicodeScalars { _ = engine.handledKey(Int32(scalar.value)) }
        XCTAssertEqual(engine.rawInput, "nihk")
        XCTAssertEqual(engine.literalInput, "nihk")
        XCTAssertNotEqual(engine.currentSnapshot.preedit, engine.rawInput)
        XCTAssertTrue(engine.select(schema: "rimes_pinyin"))
        for scalar in "xi'an".unicodeScalars { _ = engine.handledKey(Int32(scalar.value)) }
        XCTAssertEqual(engine.literalInput, "xi'an")
        _ = engine.handledKey(39, generatedSeparator: true)
        XCTAssertEqual(engine.rawInput, "xi'an'")
        XCTAssertEqual(engine.literalInput, "xi'an")
        _ = engine.process(key: 0xff08)
        XCTAssertEqual(engine.literalInput, "xi'an")
        engine.clear(); XCTAssertTrue(engine.literalInput.isEmpty)
    }
    func testScriptToggleUpdatesCandidatesAndCommitWithoutReplayingInput() throws {
        let engine = MobileEngine(); XCTAssertTrue(engine.select(schema: "rimes_pinyin"))
        var simplified = EngineSnapshot()
        for c in "hanzi".unicodeScalars { simplified = engine.process(key: Int32(c.value)) }
        let index = try XCTUnwrap(simplified.candidates.firstIndex(of: "汉字"))
        engine.traditional = true
        XCTAssertEqual(engine.currentSnapshot.preedit, simplified.preedit)
        XCTAssertEqual(engine.currentSnapshot.candidates[index], "漢字")
        XCTAssertTrue(engine.currentSnapshot.commit.isEmpty)
        engine.traditional = false
        XCTAssertEqual(engine.currentSnapshot.candidates, simplified.candidates)
        engine.traditional = true
        XCTAssertEqual(engine.candidate(index).commit, "漢字")
        XCTAssertTrue(engine.currentSnapshot.commit.isEmpty)
        engine.traditional = false
        XCTAssertTrue(engine.currentSnapshot.commit.isEmpty)
        engine.clear(); XCTAssertTrue(engine.currentSnapshot.candidates.isEmpty)
    }
    func testKeychainRoundTripAndNoKeyInConfig() throws {
        let store = KeychainStore(), id = UUID()
        defer { try? store.delete(id) }
        try store.save("test-only-local-key",id:id)
        XCTAssertEqual(try store.read(id),"test-only-local-key")
        try store.delete(id); XCTAssertEqual(try store.read(id),"")
        XCTAssertFalse(String(data:try JSONEncoder().encode(AppConfiguration()),encoding:.utf8)!.contains("test-only-local-key"))
    }
    func testLegacyConfigurationAndLocalPreferencePersistence() throws {
        var config = AppConfiguration()
        config.scheme = .ziranma
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        XCTAssertNil(json["schemeSelectionRevision"])
        let legacy = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.scheme, .ziranma)
        let suite = "org.scholay.rimes.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = KeyboardPreferences(); preferences.select(.chord)
        preferences.chordLayout = .splitOrthogonal; preferences.hapticStrength = .strongest
        preferences.toggleLanguage()
        KeyboardPreferenceStore(defaults: defaults).save(preferences)
        let restored = KeyboardPreferenceStore(defaults: defaults).load()
        XCTAssertEqual(restored.scheme, .chord)
        XCTAssertEqual(restored.chordLayout, .splitOrthogonal); XCTAssertEqual(restored.hapticStrength, .strongest)
        XCTAssertTrue(restored.englishInput); XCTAssertEqual(restored.lastChineseScheme, .chord)
    }

}
