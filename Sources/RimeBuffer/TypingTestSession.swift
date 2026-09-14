import Foundation

enum TypingTestMode: String, Codable { case firstAttempt, practice }

enum TypingTestPracticeReason: String, Codable, CaseIterable {
    case focusLost, inputSourceChanged, configurationChanged, interrupted
    case incomplete, assistedInput
}

struct TypingTestContext: Codable, Equatable {
    let schemaID: String
    let keymapID: String?
    let keymapVersion: Int?
    let mode: TypingTestMode
    let chordCountingAvailable: Bool
    let inputSourceID: String?
    let keymapRevision: String?

    init(schemaID: String, keymapID: String? = nil, keymapVersion: Int? = nil,
         mode: TypingTestMode = .firstAttempt, chordCountingAvailable: Bool = false,
         inputSourceID: String? = nil, keymapRevision: String? = nil) {
        self.schemaID = schemaID
        self.keymapID = keymapID
        self.keymapVersion = keymapVersion
        self.mode = mode
        self.chordCountingAvailable = chordCountingAvailable
        self.inputSourceID = inputSourceID
        self.keymapRevision = keymapRevision
    }
}

enum TypingTestCharacterState: Equatable { case pending, correct, incorrect, omitted }

struct TypingTestSpeedSample: Codable, Equatable {
    let elapsedSeconds: TimeInterval
    let effectiveCPM: Double
}

/// No text, individual key identity, or key-event timeline belongs in this value.
struct TypingTestMetrics: Codable, Equatable {
    var elapsedSeconds: TimeInterval = 0
    var physicalKeyCount = 0
    var repeatKeyCount = 0
    var backspaceCount = 0
    var compositionBackspaceCount = 0
    var committedBackspaceCount = 0
    var deletedCharacterCount = 0
    var correctionCount = 0
    var chordCount: Int?
    var attemptedCharacterCount = 0
    var correctAttemptCount = 0
    var correctCharacterCount = 0
    var substitutionCount = 0
    var omissionCount = 0
    var extraCharacterCount = 0
    var committedCharacterCount = 0
    var expectedCharacterCount = 0
    var speedSamples: [TypingTestSpeedSample] = []

    var effectiveCPM: Double { rate(correctCharacterCount, multiplier: 60) }
    var rawCPM: Double { rate(committedCharacterCount, multiplier: 60) }
    var wordsPerMinute: Double { effectiveCPM / 5 }
    var keysPerSecond: Double { rate(physicalKeyCount, multiplier: 1) }
    var chordsPerSecond: Double? { chordCount.map { rate($0, multiplier: 1) } }
    var processAccuracy: Double? {
        attemptedCharacterCount > 0
            ? Double(correctAttemptCount) / Double(attemptedCharacterCount) : nil
    }
    var finalAccuracy: Double? {
        let total = correctCharacterCount + substitutionCount + omissionCount + extraCharacterCount
        return total > 0 ? Double(correctCharacterCount) / Double(total) : nil
    }
    var progress: Double {
        guard expectedCharacterCount > 0 else { return 0 }
        return min(1, Double(correctCharacterCount + substitutionCount + omissionCount)
            / Double(expectedCharacterCount))
    }
    var codeLength: Double? {
        committedCharacterCount > 0
            ? Double(physicalKeyCount) / Double(committedCharacterCount) : nil
    }
    private func rate(_ count: Int, multiplier: Double) -> Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(count) * multiplier / elapsedSeconds
    }
}

struct TypingTestSnapshot {
    let metrics: TypingTestMetrics
    let committedText: String
    let targetStates: [TypingTestCharacterState]
    let typedCorrectness: [Bool]
    let canComplete: Bool
    let isStarted: Bool
    let isFinished: Bool
    let isCancelled: Bool
}

struct TypingTestResult: Codable, Equatable, Identifiable {
    let id: UUID
    let articleID: String
    let articleVersion: Int
    let language: TypingTestLanguage
    let context: TypingTestContext
    let completedAt: TimeInterval
    let metrics: TypingTestMetrics
    let isComplete: Bool
    let practiceReasons: [TypingTestPracticeReason]

    var isComparable: Bool { isComplete && practiceReasons.isEmpty }
    var displaySpeed: Double {
        language == .english ? metrics.wordsPerMinute : metrics.effectiveCPM
    }
}

/// Value-only scoring for an explicitly owned article editor. Callers supply a
/// monotonic clock (systemUptime / NSEvent.timestamp), never wall-clock dates.
/// Marked text must not be passed to reconcileCommittedText. Only aggregates
/// leave this model when the user finishes; the editor text stays in memory.
final class TypingTestSession {
    static let maximumCharacters = 2_048
    static let maximumTextBytes = 16_384
    static let maximumCounter = 1_000_000
    static let maximumDuration: TimeInterval = 86_400
    static let maximumSamples = 120

    let article: TypingTestArticle
    let context: TypingTestContext
    private let id = UUID()
    private let expected: [Character]
    private var committed: [Character] = []
    private var startedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var metrics: TypingTestMetrics
    private var alignment: Alignment
    private var sampleInterval: TimeInterval = 1
    private var reasons: [TypingTestPracticeReason] = []
    private var result: TypingTestResult?
    private var cancelled = false

    init(article: TypingTestArticle, context: TypingTestContext) {
        self.article = article
        self.context = context
        expected = Array(Self.normalized(article.text))
        metrics = TypingTestMetrics(chordCount: context.chordCountingAvailable ? 0 : nil,
                                    expectedCharacterCount: expected.count)
        alignment = Alignment.empty(expectedCount: expected.count)
        if expected.isEmpty || expected.count > Self.maximumCharacters
            || article.text.utf8.count > Self.maximumTextBytes {
            cancelled = true
        }
    }

    func start(at time: TimeInterval) {
        guard !cancelled, result == nil, startedAt == nil,
              time.isFinite, time >= 0 else { return }
        startedAt = time
        lastTime = time
    }

    /// Caller admits text/candidate-selection/deletion keyDown events only;
    /// modifier-only, navigation and host shortcuts are excluded upstream.
    func recordKey(at time: TimeInterval, isRepeat: Bool = false,
                   isBackspace: Bool = false, isComposing: Bool = false) {
        guard accepts(time) else { return }
        start(at: time)
        advance(to: time)
        if isRepeat { increment(&metrics.repeatKeyCount) }
        else { increment(&metrics.physicalKeyCount) }
        // A repeated delete is a delete action, but not a new physical press.
        if isBackspace {
            increment(&metrics.backspaceCount)
            if isComposing { increment(&metrics.compositionBackspaceCount) }
            else { increment(&metrics.committedBackspaceCount) }
        }
    }

    func recordChord(at time: TimeInterval) {
        guard accepts(time), context.chordCountingAvailable, startedAt != nil else { return }
        advance(to: time)
        metrics.chordCount = min(Self.maximumCounter, (metrics.chordCount ?? 0) + 1)
    }

    /// The IMK observer can know about a pending chord before it has produced
    /// marked text. Upgrade only the classification of that already-counted
    /// local key; the hub must first deduplicate the exact physical identity.
    func reclassifyBackspaceAsComposition() {
        guard !cancelled, result == nil, metrics.committedBackspaceCount > 0 else { return }
        metrics.committedBackspaceCount -= 1
        metrics.compositionBackspaceCount += 1
    }

    /// Reconciles actual committed editor content. A minimal sequence diff
    /// distinguishes deletions from new attempts even for middle-of-text edits.
    /// Each new attempt is judged at its commit; later correction cannot erase
    /// that history. Final alignment may improve when more context is entered.
    @discardableResult
    func reconcileCommittedText(_ text: String, at time: TimeInterval,
                                explicitInsertionRange: Range<Int>? = nil) -> Bool {
        guard accepts(time), text.utf8.count <= Self.maximumTextBytes,
              !text.contains("\0") else { return false }
        let normalized = Self.normalized(text)
        let next = Array(normalized)
        guard next.count <= Self.maximumCharacters else { return false }
        var inserted: [Int] = []
        var removed = 0
        if let range = explicitInsertionRange {
            // Exact insertText metadata can observe replacement with identical
            // text, which a whole-document diff cannot. Validate the unchanged
            // prefix/suffix so a stale replacement callback fails closed.
            guard range.lowerBound >= 0, range.upperBound <= next.count,
                  range.lowerBound <= committed.count else { return false }
            removed = committed.count + range.count - next.count
            guard removed >= 0, range.lowerBound + removed <= committed.count,
                  committed.prefix(range.lowerBound) == next.prefix(range.lowerBound),
                  committed.dropFirst(range.lowerBound + removed) == next.dropFirst(range.upperBound)
            else { return false }
            inserted = Array(range)
        } else {
            guard next != committed else { return true }
            for change in next.difference(from: committed) {
                switch change {
                case let .insert(offset, _, _): inserted.append(offset)
                case .remove: removed += 1
                }
            }
        }
        guard next != committed || !inserted.isEmpty || removed > 0 else { return true }
        start(at: time)
        advance(to: time)
        committed = next
        alignment = Self.align(expected: expected, typed: committed, final: false)
        increment(&metrics.deletedCharacterCount, by: removed)
        if removed > 0 { increment(&metrics.correctionCount) }
        increment(&metrics.attemptedCharacterCount, by: inserted.count)
        increment(&metrics.correctAttemptCount, by: inserted.filter {
            alignment.typedCorrectness.indices.contains($0) && alignment.typedCorrectness[$0]
        }.count)
        refreshAlignmentMetrics()
        return true
    }

    func markPractice(reason: TypingTestPracticeReason) {
        guard !cancelled, result == nil, !reasons.contains(reason) else { return }
        reasons.append(reason)
    }

    func cancel() { guard result == nil else { return }; cancelled = true }

    func snapshot(at time: TimeInterval) -> TypingTestSnapshot {
        if !cancelled, result == nil, accepts(time) { advance(to: time); sample() }
        return TypingTestSnapshot(
            metrics: metrics, committedText: String(committed),
            targetStates: alignment.targetStates, typedCorrectness: alignment.typedCorrectness,
            canComplete: !committed.isEmpty && alignment.consumedTargetCount == expected.count,
            isStarted: startedAt != nil, isFinished: result != nil, isCancelled: cancelled
        )
    }

    @discardableResult
    func finish(at time: TimeInterval, completedAt: Date = Date()) -> TypingTestResult? {
        if let result { return result }
        guard accepts(time), startedAt != nil, !committed.isEmpty,
              completedAt.timeIntervalSince1970.isFinite,
              completedAt.timeIntervalSince1970 >= 0 else { return nil }
        advance(to: time)
        guard metrics.elapsedSeconds > 0 else { return nil }
        let isComplete = alignment.consumedTargetCount == expected.count
        if !isComplete { markPractice(reason: .incomplete) }
        alignment = Self.align(expected: expected, typed: committed, final: true)
        refreshAlignmentMetrics()
        sample(force: true)
        let value = TypingTestResult(
            id: id, articleID: article.id, articleVersion: article.version,
            language: article.language, context: context,
            completedAt: completedAt.timeIntervalSince1970, metrics: metrics,
            isComplete: isComplete, practiceReasons: reasons
        )
        result = value
        return value
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func accepts(_ time: TimeInterval) -> Bool {
        !cancelled && result == nil && time.isFinite && time >= 0
            && (lastTime == nil || time >= lastTime!)
    }

    private func advance(to time: TimeInterval) {
        guard let startedAt else { return }
        lastTime = max(lastTime ?? startedAt, time)
        metrics.elapsedSeconds = min(Self.maximumDuration, max(0, time - startedAt))
        if time - startedAt > Self.maximumDuration { markPractice(reason: .interrupted) }
    }

    private func increment(_ value: inout Int, by amount: Int = 1) {
        value = min(Self.maximumCounter, value + min(Self.maximumCounter, max(0, amount)))
    }

    private func refreshAlignmentMetrics() {
        metrics.committedCharacterCount = committed.count
        metrics.correctCharacterCount = alignment.correctCount
        metrics.substitutionCount = alignment.substitutionCount
        metrics.omissionCount = alignment.omissionCount
        metrics.extraCharacterCount = alignment.extraCount
    }

    private func sample(force: Bool = false) {
        guard startedAt != nil, metrics.elapsedSeconds > 0 else { return }
        let previous = metrics.speedSamples.last?.elapsedSeconds ?? 0
        guard force || metrics.elapsedSeconds - previous >= sampleInterval else { return }
        if metrics.speedSamples.last?.elapsedSeconds == metrics.elapsedSeconds {
            metrics.speedSamples.removeLast()
        }
        metrics.speedSamples.append(.init(elapsedSeconds: metrics.elapsedSeconds,
                                          effectiveCPM: metrics.effectiveCPM))
        if metrics.speedSamples.count > Self.maximumSamples {
            let last = metrics.speedSamples.last!
            metrics.speedSamples = metrics.speedSamples.enumerated().compactMap {
                $0.offset.isMultiple(of: 2) ? $0.element : nil
            }
            if metrics.speedSamples.last != last { metrics.speedSamples.append(last) }
            sampleInterval *= 2
        }
    }

    private struct Alignment {
        var targetStates: [TypingTestCharacterState]
        var typedCorrectness: [Bool]
        var consumedTargetCount = 0
        var correctCount = 0
        var substitutionCount = 0
        var omissionCount = 0
        var extraCount = 0
        static func empty(expectedCount: Int) -> Alignment {
            Alignment(targetStates: Array(repeating: .pending, count: expectedCount),
                      typedCorrectness: [])
        }
    }

    /// Levenshtein alignment, breaking equal edit distances by more exact
    /// matches. During a live test, the unvisited target suffix is free/pending;
    /// on finish it becomes omissions. This avoids cascading errors after one
    /// missing or extra character. Direction storage is bounded to ~4 MiB.
    private static func align(expected: [Character], typed: [Character], final: Bool) -> Alignment {
        let width = expected.count + 1
        var previousCost = Array(0...expected.count)
        var previousMatches = Array(repeating: 0, count: width)
        var directions = [UInt8](repeating: 0, count: width * (typed.count + 1))
        for column in 1..<width { directions[column] = 2 }
        if !typed.isEmpty {
            for row in 1...typed.count {
                var costs = [Int](repeating: 0, count: width)
                var matches = [Int](repeating: 0, count: width)
                costs[0] = row
                directions[row * width] = 3
                if !expected.isEmpty {
                    for column in 1...expected.count {
                        let equal = typed[row - 1] == expected[column - 1]
                        var cost = previousCost[column - 1] + (equal ? 0 : 1)
                        var count = previousMatches[column - 1] + (equal ? 1 : 0)
                        var direction: UInt8 = 1
                        let omissionCost = costs[column - 1] + 1
                        if omissionCost < cost || (omissionCost == cost && matches[column - 1] > count) {
                            cost = omissionCost; count = matches[column - 1]; direction = 2
                        }
                        let extraCost = previousCost[column] + 1
                        if extraCost < cost || (extraCost == cost && previousMatches[column] > count) {
                            cost = extraCost; count = previousMatches[column]; direction = 3
                        }
                        costs[column] = cost; matches[column] = count
                        directions[row * width + column] = direction
                    }
                }
                previousCost = costs; previousMatches = matches
            }
        }
        var endpoint = expected.count
        if !final {
            endpoint = 0
            for column in 1..<width {
                if previousCost[column] < previousCost[endpoint]
                    || (previousCost[column] == previousCost[endpoint]
                        && previousMatches[column] >= previousMatches[endpoint]) {
                    endpoint = column
                }
            }
        }
        var value = Alignment.empty(expectedCount: expected.count)
        value.typedCorrectness = Array(repeating: false, count: typed.count)
        value.consumedTargetCount = endpoint
        var row = typed.count
        var column = endpoint
        while row > 0 || column > 0 {
            switch directions[row * width + column] {
            case 1:
                row -= 1; column -= 1
                if typed[row] == expected[column] {
                    value.targetStates[column] = .correct
                    value.typedCorrectness[row] = true
                    value.correctCount += 1
                } else {
                    value.targetStates[column] = .incorrect
                    value.substitutionCount += 1
                }
            case 2:
                column -= 1; value.targetStates[column] = .omitted; value.omissionCount += 1
            default:
                row -= 1; value.extraCount += 1
            }
        }
        return value
    }
}
