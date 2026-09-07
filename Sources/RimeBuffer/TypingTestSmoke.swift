import Foundation

/// Pure article/model/private-store coverage. No IMK client, keyboard hook,
/// current input source, live userdb, or user's statistics are touched.
func runTypingTestSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool { print("FAILED: typing test \(message)"); return false }
    func close(_ lhs: Double?, _ rhs: Double) -> Bool { abs((lhs ?? -1) - rhs) < 0.000_001 }
    func article(_ text: String, language: TypingTestLanguage = .chinese) -> TypingTestArticle {
        .init(id: "smoke.article", version: 1, language: language,
              title: "Smoke", theme: "Test", difficulty: "Test", text: text)
    }
    func copied(_ value: TypingTestResult, metrics: TypingTestMetrics,
                context: TypingTestContext? = nil, completedAt: TimeInterval? = nil) -> TypingTestResult {
        .init(id: UUID(), articleID: value.articleID, articleVersion: value.articleVersion,
              language: value.language, context: context ?? value.context,
              completedAt: completedAt ?? value.completedAt, metrics: metrics,
              isComplete: value.isComplete, practiceReasons: value.practiceReasons)
    }
    let context = TypingTestContext(schemaID: "smoke.schema", keymapID: "smoke.keymap",
                                    keymapVersion: 1, chordCountingAvailable: true,
                                    inputSourceID: "smoke.source", keymapRevision: "snapshot-1")
    guard TypingTestArticles.all.count == 8,
          Set(TypingTestArticles.all.map(\.id)).count == 8,
          TypingTestArticles.all.filter({ $0.language == .chinese }).count == 6,
          TypingTestArticles.all.filter({ $0.language == .chinese }).allSatisfy({ (400...600).contains($0.characterCount) }),
          TypingTestArticles.all.filter({ $0.language == .english }).allSatisfy({ (150...200).contains($0.wordCount) })
    else {
        return fail("article sizes: \(TypingTestArticles.all.map { "\($0.id)=\($0.characterCount)c/\($0.wordCount)w" }.joined(separator: ", "))")
    }

    let test = TypingTestSession(article: article("abcdef"), context: context)
    guard !test.snapshot(at: 90).isStarted else { return fail("render starts timer") }
    test.recordKey(at: 100)
    for offset in 1...7 { test.recordKey(at: 100 + Double(offset)) }
    test.recordKey(at: 108, isBackspace: true, isComposing: true)
    test.recordKey(at: 109, isBackspace: true)
    test.recordKey(at: 110, isRepeat: true)
    test.recordChord(at: 111)
    test.recordChord(at: 112)
    guard test.reconcileCommittedText("abq", at: 113),
          test.reconcileCommittedText("ab", at: 114),
          test.reconcileCommittedText("abdef", at: 115) else { return fail("committed edit rejected") }
    let live = test.snapshot(at: 120)
    guard live.canComplete, live.metrics.correctCharacterCount == 5,
          live.metrics.omissionCount == 1, live.metrics.extraCharacterCount == 0,
          live.targetStates == [.correct, .correct, .omitted, .correct, .correct, .correct],
          close(live.metrics.processAccuracy, 5.0 / 6.0),
          live.metrics.deletedCharacterCount == 1, live.metrics.correctionCount == 1,
          live.metrics.backspaceCount == 2, live.metrics.compositionBackspaceCount == 1,
          live.metrics.committedBackspaceCount == 1, live.metrics.physicalKeyCount == 10,
          live.metrics.repeatKeyCount == 1, live.metrics.chordCount == 2,
          close(live.metrics.effectiveCPM, 15) else { return fail("alignment, process errors, or key counters") }
    // Regressing/non-finite clocks cannot rewrite a previous observation.
    test.recordKey(at: 119)
    test.recordKey(at: .infinity)
    guard test.snapshot(at: 119).metrics == live.metrics,
          !test.reconcileCommittedText("bad", at: .nan),
          !test.reconcileCommittedText(String(repeating: "字", count: 2_049), at: 121),
          !test.reconcileCommittedText("\0", at: 121) else { return fail("bounds and monotonic clock") }
    guard let result = test.finish(at: 160, completedAt: Date(timeIntervalSince1970: 1_700_000_000)),
          result.isComparable, result.metrics.elapsedSeconds == 60,
          close(result.metrics.effectiveCPM, 5), close(result.metrics.rawCPM, 5),
          close(result.metrics.keysPerSecond, 10.0 / 60),
          close(result.metrics.finalAccuracy, 5.0 / 6),
          test.finish(at: 999) == result,
          test.snapshot(at: 999).metrics == result.metrics,
          !test.reconcileCommittedText("abcdef", at: 999),
          TypingTestHistoryStore.valid(result) else { return fail("continuous time or frozen result") }

    let corrected = TypingTestSession(article: article("abc"), context: context)
    corrected.start(at: 0)
    _ = corrected.reconcileCommittedText("axc", at: 1)
    _ = corrected.reconcileCommittedText("abc", at: 2)
    guard let correctedResult = corrected.finish(at: 3),
          close(correctedResult.metrics.processAccuracy, 0.75),
          close(correctedResult.metrics.finalAccuracy, 1),
          correctedResult.metrics.deletedCharacterCount == 1,
          correctedResult.metrics.attemptedCharacterCount == 4 else { return fail("corrected error erased from process accuracy") }
    let identical = TypingTestSession(article: article("abc"), context: context)
    _ = identical.reconcileCommittedText("abc", at: 0)
    guard identical.reconcileCommittedText("abc", at: 1, explicitInsertionRange: 1..<2),
          identical.snapshot(at: 1).metrics.attemptedCharacterCount == 4,
          identical.snapshot(at: 1).metrics.deletedCharacterCount == 1,
          !identical.reconcileCommittedText("xyz", at: 2, explicitInsertionRange: 1..<2)
    else { return fail("same-text replacement or stale explicit range") }

    let unicode = TypingTestSession(article: article("你👨‍👩‍👧‍👦e\u{301}\n好"), context: context)
    unicode.start(at: 0)
    _ = unicode.reconcileCommittedText("你👨‍👩‍👧‍👦é\r\n好", at: 1)
    guard unicode.snapshot(at: 2).metrics.correctCharacterCount == 5,
          unicode.snapshot(at: 2).canComplete else { return fail("graphemes, canonical equivalence, line endings") }

    let incomplete = TypingTestSession(article: article("abcde"), context: context)
    incomplete.start(at: 0)
    _ = incomplete.reconcileCommittedText("ab", at: 1)
    guard incomplete.snapshot(at: 2).metrics.omissionCount == 0,
          let partial = incomplete.finish(at: 3), !partial.isComplete, !partial.isComparable,
          partial.metrics.omissionCount == 3, partial.practiceReasons == [.incomplete],
          TypingTestHistoryStore.valid(partial) else { return fail("pending suffix vs final omission") }

    let extra = TypingTestSession(article: article("abc"), context: context)
    extra.start(at: 0)
    _ = extra.reconcileCommittedText("axbc", at: 1)
    guard let extraResult = extra.finish(at: 2), extraResult.metrics.extraCharacterCount == 1,
          extraResult.metrics.correctCharacterCount == 3,
          close(extraResult.metrics.finalAccuracy, 0.75) else { return fail("extra character alignment") }
    let wrong = TypingTestSession(article: article("abc"), context: context)
    _ = wrong.reconcileCommittedText("xxx", at: 1)
    guard wrong.snapshot(at: 2).canComplete else { return fail("full wrong text can be finished") }

    let english = TypingTestSession(article: article("abcdefghijklmnopqrstuvwxy", language: .english),
                                    context: .init(schemaID: "english", mode: .practice))
    english.start(at: 0)
    _ = english.reconcileCommittedText("abcdefghijklmnopqrstuvwxy", at: 30)
    english.markPractice(reason: .focusLost)
    guard let englishResult = english.finish(at: 60), close(englishResult.metrics.wordsPerMinute, 5),
          englishResult.context.mode == .practice, englishResult.metrics.chordCount == nil,
          !englishResult.isComparable, englishResult.practiceReasons == [.focusLost] else { return fail("WPM, unavailable chords, practice reason") }

    let cancelled = TypingTestSession(article: article("a"), context: context)
    _ = cancelled.reconcileCommittedText("a", at: 1)
    cancelled.cancel()
    guard cancelled.finish(at: 2) == nil, cancelled.snapshot(at: 2).isCancelled else { return fail("cancel has no result") }
    let zeroTime = TypingTestSession(article: article("a"), context: context)
    _ = zeroTime.reconcileCommittedText("a", at: 10)
    guard zeroTime.finish(at: 10) == nil else { return fail("zero-duration score accepted") }
    let classified = TypingTestSession(article: article("ab"), context: context)
    classified.recordKey(at: 0, isBackspace: true)
    let beforeUpgrade = classified.snapshot(at: 1).metrics
    classified.reclassifyBackspaceAsComposition()
    let afterUpgrade = classified.snapshot(at: 1).metrics
    guard afterUpgrade.physicalKeyCount == beforeUpgrade.physicalKeyCount,
          afterUpgrade.backspaceCount == beforeUpgrade.backspaceCount,
          afterUpgrade.elapsedSeconds == beforeUpgrade.elapsedSeconds,
          afterUpgrade.committedBackspaceCount == 0,
          afterUpgrade.compositionBackspaceCount == 1 else { return fail("backspace classification upgrade double-counted") }
    _ = classified.reconcileCommittedText("ab", at: 2)
    guard let classificationResult = classified.finish(at: 3) else { return fail("classification result") }
    classified.reclassifyBackspaceAsComposition()
    guard classified.snapshot(at: 4).metrics == classificationResult.metrics else { return fail("classification modified frozen result") }
    let long = TypingTestSession(article: article("a"), context: context)
    _ = long.reconcileCommittedText("a", at: 0)
    for second in 1...500 { _ = long.snapshot(at: TimeInterval(second)) }
    guard let sampled = long.finish(at: 501), sampled.metrics.speedSamples.count <= 120,
          sampled.metrics.speedSamples.last?.elapsedSeconds == 501,
          TypingTestHistoryStore.valid(sampled) else { return fail("bounded chart sampling") }

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("rimes-typing-test-smoke-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let store = TypingTestHistoryStore(storageRoot: root)
        guard store.storageIssue == nil, store.add(result), store.add(result),
              store.results.count == 1 else { return fail("history add/idempotence") }
        let url = root.appendingPathComponent("stats/typing_tests.json")
        let encoded = try String(contentsOf: url, encoding: .utf8)
        guard !encoded.contains("abcdef"), !encoded.contains("abdef"),
              !encoded.contains("committedText"), !encoded.contains("keyID"),
              !encoded.contains("targetStates"),
              TypingTestHistoryStore(storageRoot: root).results == store.results,
              ((try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600,
              ((try fileManager.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700 else { return fail("private aggregate-only persistence") }

        // A valid 500-record history with full charts can exceed the byte cap.
        // Exercise retention without hundreds of disk writes or live data.
        var chartMetrics = result.metrics
        chartMetrics.speedSamples = (1..<120).map { index in
            let elapsed = Double(index) * 0.478398413072984
            return .init(elapsedSeconds: elapsed, effectiveCPM: Double(index % 6) * 60 / elapsed)
        }
        chartMetrics.speedSamples.append(.init(elapsedSeconds: chartMetrics.elapsedSeconds,
                                                effectiveCPM: chartMetrics.effectiveCPM))
        let longContext = TypingTestContext(
            schemaID: String(repeating: "s", count: 256), keymapID: String(repeating: "k", count: 256),
            keymapVersion: 1, chordCountingAvailable: true,
            inputSourceID: String(repeating: "i", count: 256), keymapRevision: String(repeating: "r", count: 256)
        )
        let fullHistory = (0..<500).map { index in
            copied(result, metrics: chartMetrics, context: longContext,
                   completedAt: result.completedAt + Double(index))
        }
        guard fullHistory.allSatisfy(TypingTestHistoryStore.valid) else { return fail("large history fixture") }
        let retained = try TypingTestHistoryStore.retainedEncoding(fullHistory)
        guard retained.results.count < 500, !retained.results.isEmpty,
              retained.data.count <= TypingTestHistoryStore.maximumFileBytes,
              retained.results.first?.id == fullHistory.last?.id else { return fail("byte-budget retention") }
        do {
            _ = try TypingTestHistoryStore.retainedEncoding([result], maximumBytes: 1)
            return fail("single oversized score silently dropped")
        } catch LocalMetricsFileSecurity.StorageError.fileTooLarge { }
        guard try Data(contentsOf: url) == Data(encoded.utf8) else { return fail("retention helper changed disk") }

        var impossible = result.metrics
        impossible.attemptedCharacterCount = 0
        impossible.correctAttemptCount = 0
        let invalidResult = copied(result, metrics: impossible)
        guard !TypingTestHistoryStore.valid(invalidResult), !store.add(invalidResult) else { return fail("impossible aggregate accepted") }
        let semanticRoot = root.appendingPathComponent("semantic-corruption")
        let semanticURL = semanticRoot.appendingPathComponent("stats/typing_tests.json")
        try fileManager.createDirectory(at: semanticURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let validJSONWithBadCounts = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "results": [JSONSerialization.jsonObject(with: JSONEncoder().encode(invalidResult))]
        ])
        try validJSONWithBadCounts.write(to: semanticURL)
        let semantic = TypingTestHistoryStore(storageRoot: semanticRoot)
        guard semantic.storageIssue != nil, semantic.results.isEmpty, !semantic.add(result),
              try Data(contentsOf: semanticURL) == validJSONWithBadCounts else { return fail("semantically corrupt JSON did not fail closed") }

        let corruptRoot = root.appendingPathComponent("corrupt")
        let corruptURL = corruptRoot.appendingPathComponent("stats/typing_tests.json")
        try fileManager.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{not valid json".utf8)
        try original.write(to: corruptURL)
        let corrupt = TypingTestHistoryStore(storageRoot: corruptRoot)
        guard corrupt.storageIssue != nil, !corrupt.add(result), !corrupt.clearAll(),
              try Data(contentsOf: corruptURL) == original,
              corrupt.repairReadOnlyStore(), corrupt.add(result) else { return fail("corrupt read-only/explicit repair") }
        let backups = try fileManager.contentsOfDirectory(at: corruptURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("typing_tests.corrupt-") }
        guard backups.count == 1, try Data(contentsOf: backups[0]) == original else { return fail("repair preserves original") }

        let linkRoot = root.appendingPathComponent("link")
        let linkURL = linkRoot.appendingPathComponent("stats/typing_tests.json")
        let target = root.appendingPathComponent("do-not-touch.json")
        try original.write(to: target)
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: target)
        let linked = TypingTestHistoryStore(storageRoot: linkRoot)
        guard linked.storageIssue != nil, linked.repairReadOnlyStore(), linked.add(result),
              !LocalMetricsFileSecurity.pathEntryIsSymbolicLink(linkURL),
              try Data(contentsOf: target) == original else { return fail("symlink target followed") }

        let parentRoot = root.appendingPathComponent("unsafe-parent")
        try fileManager.createDirectory(at: parentRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: parentRoot.appendingPathComponent("stats"), withDestinationURL: root.appendingPathComponent("stats"))
        let unsafe = TypingTestHistoryStore(storageRoot: parentRoot)
        guard unsafe.storageIssue != nil, !unsafe.repairReadOnlyStore(),
              store.clearAll(), store.results.isEmpty else { return fail("unsafe parent or clear") }
        print("typing test smoke OK")
        return true
    } catch { return fail("store threw \(error.localizedDescription)") }
}
