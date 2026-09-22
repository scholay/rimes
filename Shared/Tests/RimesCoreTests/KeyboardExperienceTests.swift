import XCTest
@testable import RimesCore

final class KeyboardExperienceTests: XCTestCase {
    func testNewLayoutPreferencesMigrateAndPersistEnglishOverride() throws {
        var value = try JSONDecoder().decode(KeyboardPreferences.self, from: Data("{\"scheme\":\"chord\"}".utf8))
        XCTAssertEqual(value.chordLayout, .orthogonal)
        value.select(.chord); value.chordLayout = .splitOrthogonal; value.hapticStrength = .strongest
        value.toggleLanguage()
        var restored = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored.scheme, .chord); XCTAssertTrue(restored.englishInput)
        XCTAssertEqual(restored.chordLayout, .splitOrthogonal); XCTAssertEqual(restored.hapticStrength, .strongest)
        restored.toggleLanguage(); XCTAssertFalse(restored.englishInput)
        restored.select(.english); restored.toggleLanguage(); XCTAssertEqual(restored.scheme, .chord)
        restored.reconcile(scheme: .wubi86, revision: UUID()); XCTAssertFalse(restored.englishInput)
        XCTAssertEqual(restored.lastChineseScheme, .wubi86)
    }
    func testRemovedLayoutsMigrateWithoutLosingPreferences() throws {
        for removed in ["twoRows", "staggered"] {
            let json = "{\"scheme\":\"chord\",\"chordLayout\":\"\(removed)\",\"twoRowDirection\":\"rightAbove\",\"haptics\":false,\"traditional\":true}"
            let p = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(p.chordLayout, .orthogonal); XCTAssertEqual(p.scheme, .chord)
            XCTAssertFalse(p.haptics); XCTAssertTrue(p.traditional); XCTAssertEqual(p.hapticStrength, .light)
            let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(p), encoding: .utf8))
            XCTAssertFalse(encoded.contains("twoRowDirection"))
        }
        XCTAssertEqual(ChordLayout.allCases, [.orthogonal, .splitOrthogonal])
        for strength in HapticStrength.allCases {
            var p = KeyboardPreferences(); p.hapticStrength = strength
            XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(p)).hapticStrength, strength)
        }
    }
    func testRawSeparatorProvenancePreservesTypedSeparatorsAndRemapsEdits() {
        var input = RawInputProvenance()
        input.update("ni"); input.update("ni'", generatedSeparatorAt: 2)
        input.update("ni'hao"); input.update("ni'hao'", generatedSeparatorAt: 6)
        XCTAssertEqual(input.literal, "nihao")
        input.update("ni'hao"); input.update("ni'ha"); XCTAssertEqual(input.literal, "niha")
        input.update("ha"); XCTAssertEqual(input.literal, "ha")
        input.reset(); input.update("xi'an"); XCTAssertEqual(input.literal, "xi'an")
        input.update("xi'an'", generatedSeparatorAt: 5); XCTAssertEqual(input.literal, "xi'an")
        input.update(""); XCTAssertEqual(input.literal, "")
    }

    func testDefaultChordNameMigrationPreservesIdentityAndMappings() throws {
        let profile = ChordProfile.builtIn
        var legacy = profile
        legacy.name = "飞耀"
        let restored = try JSONDecoder().decode(ChordProfile.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored.name, "默认并击")
        XCTAssertEqual(restored.id, profile.id)
        XCTAssertEqual(restored.mappings, profile.mappings)
        var custom = profile.copy()
        custom.name = "My imported layout"
        let imported = try ChordProfile.imported(JSONEncoder().encode(custom))
        XCTAssertEqual(imported.name, custom.name)
        XCTAssertEqual(imported.mappings, custom.mappings)
        XCTAssertNotEqual(imported.id, profile.id)
    }
    func testLastSchemeSurvivesPersistenceAndOrdinaryAppSaves() throws {
        var value = KeyboardPreferences()
        value.reconcile(scheme: .pinyin, revision: nil)
        value.select(.chord); value.haptics = false; value.targetLanguage = "ja"; value.traditional = true
        var restored = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(value))
        restored.reconcile(scheme: .pinyin, revision: nil)
        XCTAssertEqual(restored.scheme, .chord); XCTAssertFalse(restored.haptics); XCTAssertEqual(restored.targetLanguage, "ja"); XCTAssertTrue(restored.traditional)
        let revision = UUID()
        restored.reconcile(scheme: .wubi86, revision: revision)
        XCTAssertEqual(restored.scheme, .wubi86)
        restored.select(.english)
        restored.reconcile(scheme: .wubi86, revision: revision)
        XCTAssertEqual(restored.scheme, .english)
    }
    func testLegacyPreferencesKeepSchemeAndLanguagesWhenScriptChoiceIsAdded() throws {
        let revision = UUID()
        var previous = KeyboardPreferences()
        previous.reconcile(scheme: .chord, revision: revision)
        previous.haptics = false; previous.sourceLanguage = "ja"; previous.targetLanguage = "en"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String: Any]
        json.removeValue(forKey: "traditional")
        let restored = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.scheme, .chord); XCTAssertEqual(restored.appliedAppSelection, revision)
        XCTAssertTrue(restored.initialized); XCTAssertFalse(restored.haptics); XCTAssertFalse(restored.traditional)
        XCTAssertEqual(restored.sourceLanguage, "ja"); XCTAssertEqual(restored.targetLanguage, "en")
    }
    func testReachabilityIncludesEveryBuiltInMappingFromBothHandOrders() {
        let profile = ChordProfile.builtIn, index = ChordReachability(profile: .builtIn)
        for mapping in profile.mappings {
            let left = Array(mapping.keys.filter { profile.leftKeys.contains($0) })
            let right = Array(mapping.keys.filter { profile.rightKeys.contains($0) })
            for hands in [[left, right], [right, left]] {
                var gesture = ChordGesture()
                for (id, keys) in hands.enumerated() where !keys.isEmpty {
                    gesture.begin(id: id, key: keys[0], profile: profile)
                    XCTAssertTrue(Set(mapping.keys).isSubset(of: gesture.availableKeys(in: index)), mapping.keys)
                    gesture.move(id: id, key: keys.last, profile: profile)
                }
            }
        }
    }
    func testReleasedHandCannotAdvertiseDifferentEndpointAndRecoveryWorks() throws {
        var profile = ChordProfile.builtIn.copy()
        profile.leftKeys = "as"; profile.rightKeys = "jk"; profile.mappings = [
            .init(keys: "aj", output: "ni", kind: .syllable), .init(keys: "ask", output: "hao", kind: .syllable)
        ]; profile = try profile.validated()
        let index = ChordReachability(profile: profile)
        var gesture = ChordGesture()
        gesture.begin(id: 1, key: "a", profile: profile)
        XCTAssertTrue(gesture.availableKeys(in: index).contains("s"))
        gesture.begin(id: 2, key: "j", profile: profile)
        _ = gesture.end(id: 1, key: "a", profile: profile)
        XCTAssertFalse(gesture.availableKeys(in: index).contains("s"))
        gesture.move(id: 2, key: nil, profile: profile)
        XCTAssertEqual(gesture.keys, Set("aj"))
        XCTAssertTrue(gesture.availableKeys(in: index).contains("j"))
        gesture.move(id: 2, key: "j", profile: profile)
        XCTAssertEqual(gesture.end(id: 2, key: "j", profile: profile)?.preview, "ni")
        XCTAssertEqual(gesture.availableKeys(in: index), index.allKeys)
    }
    func testUnmappedSlidePreservesLastValidChordUntilReplacementOrReturn() throws {
        let profile = ChordProfile.builtIn
        let expected = try XCTUnwrap(profile.resolve(Set("ef")))
        XCTAssertEqual(expected.preview, "sh")
        for endpoint: Character in ["v", "b"] {
            var gesture = ChordGesture()
            gesture.begin(id: 1, key: "e", profile: profile)
            gesture.move(id: 1, key: "f", profile: profile)
            gesture.move(id: 1, key: endpoint, profile: profile)
            XCTAssertEqual(gesture.keys, Set("ef"))
            XCTAssertEqual(gesture.end(id: 1, key: endpoint, profile: profile), expected)
            XCTAssertNil(gesture.end(id: 1, key: endpoint, profile: profile))
        }
        var gesture = ChordGesture()
        gesture.begin(id: 1, key: "e", profile: profile)
        gesture.move(id: 1, key: "f", profile: profile)
        gesture.move(id: 1, key: "b", profile: profile)
        gesture.move(id: 1, key: "r", profile: profile)
        XCTAssertEqual(gesture.keys, Set("er"))
        gesture.move(id: 1, key: "e", profile: profile)
        XCTAssertEqual(gesture.keys, Set("e"))
        gesture.move(id: 1, key: "f", profile: profile)
        gesture.cancel()
        XCTAssertNil(gesture.end(id: 1, key: "v", profile: profile))
    }
    func testProtectedCombinationSurvivesEitherHandReleaseOrder() throws {
        var profile = ChordProfile.builtIn.copy()
        profile.mappings = [.init(keys: "ef", output: "sh", kind: .fragment),
                            .init(keys: "jk", output: "ang", kind: .fragment)]
        profile = try profile.validated()
        for first in [1, 2] {
            var gesture = ChordGesture()
            gesture.begin(id: 1, key: "e", profile: profile)
            gesture.move(id: 1, key: "f", profile: profile)
            gesture.begin(id: 2, key: "j", profile: profile)
            gesture.move(id: 2, key: "k", profile: profile)
            XCTAssertEqual(profile.resolve(gesture.keys!)?.preview, "shang")
            gesture.move(id: 1, key: "b", profile: profile)
            XCTAssertEqual(gesture.keys, Set("efjk"))
            XCTAssertNil(gesture.end(id: first, key: first == 1 ? "v" : "k", profile: profile))
            XCTAssertEqual(gesture.end(id: first == 1 ? 2 : 1, key: first == 1 ? "k" : "b", profile: profile)?.preview, "shang")
        }
    }
    func testDirectionalSlidesEncodePreviewProtectAndCommitOnce() throws {
        var profile = ChordProfile.builtIn; profile.outputEncoding = .ziranma
        let routes = [("ty", "ting", "ty"), ("gh", "gang", "gh"), ("bn", "bin", "bn"),
                      ("tyu", "tu", "tu"), ("ghj", "gan", "gj"), ("bnm", "bian", "bm"),
                      ("bh", "bang", "bh"), ("th", "tang", "th"), ("gy", "guai", "gy")]
        for (path, pinyin, code) in routes {
            for skipMiddle in [false, true] {
                var gesture = ChordGesture()
                gesture.begin(id: 1, key: path.first, profile: profile)
                for key in skipMiddle ? [path.last!] : Array(path.dropFirst()) { gesture.move(id: 1, key: key, profile: profile) }
                XCTAssertEqual(gesture.keys, Set(path))
                XCTAssertEqual(gesture.resolution(in: profile)?.preview, pinyin)
                gesture.move(id: 1, key: nil, profile: profile)
                gesture.move(id: 1, key: "p", profile: profile)
                XCTAssertEqual(gesture.resolution(in: profile)?.input, code)
                XCTAssertEqual(gesture.end(id: 1, key: "p", profile: profile)?.input, code)
                XCTAssertNil(gesture.end(id: 1, key: nil, profile: profile))
            }
        }
        var gesture = ChordGesture()
        gesture.begin(id: 1, key: "t", profile: profile)
        gesture.move(id: 1, key: "u", profile: profile)
        gesture.move(id: 1, key: "y", profile: profile)
        XCTAssertEqual(gesture.resolution(in: profile)?.preview, "ting")
        gesture.move(id: 1, key: "t", profile: profile)
        XCTAssertEqual(gesture.keys, Set("t"))
        gesture.move(id: 1, key: "y", profile: profile); gesture.cancel()
        XCTAssertNil(gesture.end(id: 1, key: "u", profile: profile))
        gesture.begin(id: 1, key: "y", profile: profile)
        gesture.move(id: 1, key: "t", profile: profile)
        XCTAssertEqual(gesture.keys, Set("y"), "Reverse direction is not a shortcut")
        _ = gesture.end(id: 1, key: "y", profile: profile)
        gesture.begin(id: 1, key: "g", profile: profile)
        gesture.move(id: 1, key: "h", profile: profile)
        gesture.begin(id: 2, key: "j", profile: profile)
        XCTAssertNil(gesture.end(id: 1, key: "h", profile: profile))
        XCTAssertNil(gesture.end(id: 2, key: "j", profile: profile))
    }
    func testDefaultBlocksMatchDesktopClausesAndPreserveExactText() {
        let text = "第一段，第二段；第三段。"
        XCTAssertEqual(DefaultBlockSegmenter.segments(from: text), ["第一段，", "第二段；", "第三段。"])
        for sample in [text, "visit https://example.com/a?q=1 now please and continue typing", "3.14 is a number", String(repeating: "汉", count: 100), "  前后空格  "] {
            let blocks = DefaultBlockSegmenter.segments(from: sample)
            XCTAssertEqual(blocks.joined(), sample)
            var buffer = BufferSession(); buffer.edit(sample)
            XCTAssertEqual(buffer.pending, blocks)
            for expected in blocks { XCTAssertEqual(buffer.pending.first, expected); buffer.consumed(all: false) }
            XCTAssertTrue(buffer.source.isEmpty)
        }
    }
    func testDefaultBufferStatisticsAndIdleBurst() {
        var metrics = BufferLiveTypingMetrics()
        metrics.noteKey(at: 0, isRepeat: false, isBackspace: false)
        metrics.noteKey(at: 1, isRepeat: false, isBackspace: true)
        metrics.noteKey(at: 1.1, isRepeat: true, isBackspace: true)
        metrics.noteCommit(characterCount: 2, at: 2)
        XCTAssertEqual(metrics.charactersPerMinute, 60)
        XCTAssertEqual(metrics.codeLength, 1)
        XCTAssertEqual(metrics.keysPerSecond, 1)
        XCTAssertEqual(metrics.backspaceCount, 1)
        metrics.noteKey(at: 9, isRepeat: false, isBackspace: false)
        XCTAssertEqual(metrics.keyCount, 1); XCTAssertNil(metrics.charactersPerMinute)
    }
    func testDefaultBlockDelayEditsPauseAndOrderedConsumption() {
        var clock = DefaultBufferClock()
        clock.synchronize(["A。", "B"])
        XCTAssertFalse(clock.tick(at: 0, lifetime: 1, canAge: true))
        XCTAssertFalse(clock.tick(at: 0.5, lifetime: 1, canAge: true))
        clock.synchronize(["A。", "BC"])
        XCTAssertTrue(clock.tick(at: 1, lifetime: 1, canAge: true))
        clock.consumed(all: false); clock.synchronize(["BC"])
        XCTAssertEqual(clock.headAge, 0)
        XCTAssertFalse(clock.tick(at: 1.1, lifetime: 1, canAge: true))
        XCTAssertFalse(clock.tick(at: 2, lifetime: 1, canAge: false))
        XCTAssertFalse(clock.tick(at: 100, lifetime: 1, canAge: true))
        XCTAssertTrue(clock.tick(at: 101, lifetime: 1, canAge: true))
        clock.consumed(all: false)
        XCTAssertFalse(clock.tick(at: 102, lifetime: 1, canAge: true))
        clock.synchronize(["new"])
        XCTAssertFalse(clock.tick(at: 103, lifetime: 1, canAge: true))
        clock.reset(); XCTAssertFalse(clock.tick(at: 200, lifetime: 1, canAge: true))
    }
    func testFeedbackDeduplicatesAndThrottles() {
        var feedback = FeedbackGate()
        XCTAssertTrue(feedback.accept(.press, at: 1))
        XCTAssertFalse(feedback.accept(.selection, combination: "AS", at: 1.01))
        XCTAssertFalse(feedback.accept(.selection, combination: "AS", at: 1.1))
        XCTAssertTrue(feedback.accept(.selection, combination: "AJ", at: 1.2))
        XCTAssertFalse(feedback.accept(.selection, combination: nil, at: 1.3))
        XCTAssertTrue(feedback.accept(.selection, combination: "AJ", at: 1.4))
        feedback.reset()
        XCTAssertTrue(feedback.accept(.commit, at: 1.5))
    }
    func testPartialTranslationRetiresSourceAndKeepsRemainderAcrossEdits() {
        var buffer = BufferSession(); buffer.edit("你好！再见！")
        let id = buffer.begin(); buffer.finish("Hello!Goodbye!", id: id)
        buffer.consumePlugin(all: false)
        XCTAssertEqual(buffer.source, "")
        XCTAssertEqual(buffer.pluginPending, ["Goodbye!"])
        buffer.insert("新文字")
        let next = buffer.begin(); buffer.finish("New text", id: next)
        XCTAssertEqual(buffer.pluginPending, ["Goodbye!", "New text"])
        buffer.consumePlugin(all: false)
        XCTAssertEqual(buffer.source, "新文字")
        XCTAssertEqual(buffer.pluginPending, ["New text"])
        buffer.consumePlugin(all: true)
        XCTAssertTrue(buffer.source.isEmpty); XCTAssertTrue(buffer.pluginPending.isEmpty)
    }
    func testDeliveringRetainedTranslationDoesNotEraseNewUntranslatedSource() {
        var buffer = BufferSession(); buffer.edit("旧原文")
        let id = buffer.begin(); buffer.finish("First!Second!", id: id); buffer.consumePlugin(all: false)
        buffer.insert("新原文"); _ = buffer.begin(); buffer.cancel()
        XCTAssertEqual(buffer.pluginPending, ["Second!"])
        buffer.consumePlugin(all: true)
        XCTAssertEqual(buffer.source, "新原文"); XCTAssertTrue(buffer.pluginPending.isEmpty)
    }
    func testFailedAndCancelledPluginNeverExposesSourceAsPluginResult() {
        var buffer = BufferSession(); buffer.edit("原文")
        let id = buffer.begin(); buffer.receive("partial", id: id); buffer.cancel(); buffer.finish("late", id: id)
        XCTAssertTrue(buffer.pluginPending.isEmpty)
        XCTAssertEqual(buffer.source, "原文")
    }
}

@MainActor private final class SlowPlugin: BufferPlugin {
    let descriptor = BufferPluginDescriptor(id: "test", title: "test", realtime: true)
    var onStarted: ((String) -> Void)?
    var requests = [String](), concurrent = 0, peak = 0, cancellations = 0
    func availability(for request: BufferPluginRequest) async -> BufferPluginAvailability { .ready }
    func execute(_ request: BufferPluginRequest, preview: @escaping @MainActor (String) -> Void) async throws -> BufferPluginResult {
        requests.append(request.source); concurrent += 1; peak = max(peak, concurrent); onStarted?(request.source)
        // Deliberately ignores cancellation to prove the runner still serializes it.
        await withCheckedContinuation { continuation in
            Task { try? await Task.sleep(nanoseconds: 60_000_000); continuation.resume() }
        }
        concurrent -= 1; preview(request.source)
        return .init(text: request.source, revision: request.revision)
    }
    func cancel() { cancellations += 1 }
}

final class BufferPluginRunnerTests: XCTestCase {
    @MainActor func testDebounceOnlyExecutesLatestText() async throws {
        let runner = BufferPluginRunner(), plugin = SlowPlugin()
        var completed = [String]()
        let finished = expectation(description: "Latest request completes")
        for text in ["a", "ab", "abc"] {
            runner.submit(plugin: plugin, request: .init(source: text, revision: UUID()), delayNanoseconds: 20_000_000, preview: { _ in }, completion: { if case .success(let result) = $0 { completed.append(result.text); finished.fulfill() } })
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(plugin.requests, ["abc"]); XCTAssertEqual(completed, ["abc"])
    }
    @MainActor func testUncooperativeOldTaskCannotOverlapOrPublish() async throws {
        let runner = BufferPluginRunner(), plugin = SlowPlugin()
        var completed = [String](), previews = [String]()
        let started = expectation(description: "Old request is running")
        let finished = expectation(description: "Replacement completes")
        plugin.onStarted = { if $0 == "old" { started.fulfill() } }
        func submit(_ text: String) {
            runner.submit(plugin: plugin, request: .init(source: text, revision: UUID()), delayNanoseconds: 0, preview: { previews.append($0) }, completion: { if case .success(let result) = $0 { completed.append(result.text); finished.fulfill() } })
        }
        submit("old"); await fulfillment(of: [started], timeout: 5)
        submit("new"); await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(plugin.requests, ["old", "new"]); XCTAssertEqual(plugin.peak, 1)
        XCTAssertEqual(completed, ["new"]); XCTAssertEqual(previews, ["new"])
        submit("hidden"); runner.cancel(); try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(completed, ["new"])
    }
}
