import Foundation

extension Notification.Name {
    static let typingTestHistoryDidChange = Notification.Name("RimeBuffer.TypingTestHistory.didChange")
}

/// Explicit-test aggregates only. Passive daily telemetry remains in its
/// existing file; article text and user-entered text are never encoded here.
final class TypingTestHistoryStore {
    static let shared = TypingTestHistoryStore()
    static let maximumFileBytes = 4 * 1_048_576
    static let maximumResults = 500

    private struct StoreFile: Codable {
        var version: Int = 1
        var results: [TypingTestResult] = []
    }

    private var url: URL
    private var file = StoreFile()
    private(set) var storageIssue: String?

    init(storageRoot: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        let environmentRoot = environment["RIMEBUFFER_LOCAL_DATA_ROOT"] ?? environment["RIMEBUFFER_USER_DIR"]
        let root = storageRoot
            ?? environmentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/\(RimesPaths.directoryName)")
        url = root.appendingPathComponent("stats/typing_tests.json")
        do {
            if let data = try LocalMetricsFileSecurity.readIfPresent(
                from: url, maximumBytes: Self.maximumFileBytes
            ) {
                let decoded = try JSONDecoder().decode(StoreFile.self, from: data)
                guard Self.valid(decoded) else {
                    storageIssue = "跟打成绩结构或数值超出安全范围"
                    return
                }
                file = decoded
            }
        } catch {
            storageIssue = error.localizedDescription
            IMELog.write("typing-test history load blocked; preserving original file")
        }
    }

    var results: [TypingTestResult] {
        file.results.sorted {
            if $0.completedAt == $1.completedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.completedAt > $1.completedAt
        }
    }

    @discardableResult
    func add(_ result: TypingTestResult) -> Bool {
        guard storageIssue == nil, Self.valid(result) else { return false }
        guard !file.results.contains(where: { $0.id == result.id }) else { return true }
        var candidate = file
        candidate.results.append(result)
        candidate.results.sort { $0.completedAt > $1.completedAt }
        candidate.results = Array(candidate.results.prefix(Self.maximumResults))
        return publish(candidate, retainingNewestWithinByteBudget: true)
    }

    @discardableResult
    func clearAll() -> Bool {
        guard storageIssue == nil else { return false }
        return publish(StoreFile())
    }

    /// Requires an explicit user action. Preserve the exact original path entry
    /// beside the replacement; never follow a symlink or repair a linked parent.
    @discardableResult
    func repairReadOnlyStore() -> Bool {
        guard storageIssue != nil else { return true }
        do {
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try LocalMetricsFileSecurity.validateDirectoryIfPresent(directory)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            let linked = LocalMetricsFileSecurity.pathEntryIsSymbolicLink(url)
            if linked || fileManager.fileExists(atPath: url.path) {
                var regular = false
                if !linked {
                    regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                }
                let backup = directory.appendingPathComponent(
                    "typing_tests.corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
                )
                try fileManager.moveItem(at: url, to: backup)
                if regular {
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            url.removeAllCachedResourceValues()
            storageIssue = nil
            return publish(StoreFile())
        } catch {
            storageIssue = error.localizedDescription
            notify()
            return false
        }
    }

    private func publish(_ candidate: StoreFile, retainingNewestWithinByteBudget: Bool = false) -> Bool {
        do {
            guard Self.valid(candidate) else { return false }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var retained = candidate
            let data: Data
            if retainingNewestWithinByteBudget {
                let encoded = try Self.retainedEncoding(candidate.results)
                retained.results = encoded.results
                data = encoded.data
            } else {
                data = try encoder.encode(candidate)
            }
            try LocalMetricsFileSecurity.write(data, to: url,
                                                maximumBytes: Self.maximumFileBytes)
            file = retained
            notify()
            return true
        } catch {
            storageIssue = error.localizedDescription
            IMELog.write("typing-test history write blocked; preserving in-memory aggregates")
            notify()
            return false
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .typingTestHistoryDidChange, object: self)
    }

    /// A record count ceiling alone cannot bound variable-size chart samples.
    /// Retain the newest prefix which fits both limits, instead of treating
    /// ordinary history growth as a corrupt/read-only store. A single record
    /// that cannot fit is an error; the caller has not replaced the old file.
    static func retainedEncoding(_ results: [TypingTestResult],
                                 maximumBytes: Int = maximumFileBytes) throws
        -> (results: [TypingTestResult], data: Data) {
        let sorted = Array(results.sorted {
            if $0.completedAt == $1.completedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.completedAt > $1.completedAt
        }.prefix(maximumResults))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func encoded(_ count: Int) throws -> Data {
            try encoder.encode(StoreFile(results: Array(sorted.prefix(count))))
        }
        let all = try encoded(sorted.count)
        if all.count <= maximumBytes { return (sorted, all) }
        guard !sorted.isEmpty else { throw LocalMetricsFileSecurity.StorageError.fileTooLarge }
        var kept = 1
        var best = try encoded(kept)
        guard best.count <= maximumBytes else { throw LocalMetricsFileSecurity.StorageError.fileTooLarge }
        var upper = sorted.count - 1
        while kept < upper {
            let middle = kept + (upper - kept + 1) / 2
            let data = try encoded(middle)
            if data.count <= maximumBytes { kept = middle; best = data }
            else { upper = middle - 1 }
        }
        return (Array(sorted.prefix(kept)), best)
    }

    private static func valid(_ file: StoreFile) -> Bool {
        file.version == 1 && file.results.count <= maximumResults
            && Set(file.results.map(\.id)).count == file.results.count
            && file.results.allSatisfy(valid)
    }

    static func valid(_ result: TypingTestResult) -> Bool {
        let metrics = result.metrics
        let counters = [
            metrics.physicalKeyCount, metrics.repeatKeyCount, metrics.backspaceCount,
            metrics.compositionBackspaceCount, metrics.committedBackspaceCount,
            metrics.deletedCharacterCount, metrics.correctionCount,
            metrics.attemptedCharacterCount, metrics.correctAttemptCount,
            metrics.correctCharacterCount, metrics.substitutionCount, metrics.omissionCount,
            metrics.extraCharacterCount, metrics.committedCharacterCount, metrics.expectedCharacterCount
        ]
        guard validIdentifier(result.articleID), result.articleVersion > 0,
              result.articleVersion <= 1_000_000,
              validIdentifier(result.context.schemaID, allowEmpty: true),
              result.context.keymapID.map({ validIdentifier($0) }) ?? true,
              result.context.inputSourceID.map({ validIdentifier($0) }) ?? true,
              result.context.keymapRevision.map({ validIdentifier($0) }) ?? true,
              result.context.keymapVersion.map({ $0 > 0 && $0 <= 1_000_000 }) ?? true,
              result.completedAt.isFinite, result.completedAt >= 0,
              metrics.elapsedSeconds.isFinite, metrics.elapsedSeconds > 0,
              metrics.elapsedSeconds <= TypingTestSession.maximumDuration,
              counters.allSatisfy({ $0 >= 0 && $0 <= TypingTestSession.maximumCounter }),
              metrics.expectedCharacterCount > 0,
              metrics.expectedCharacterCount <= TypingTestSession.maximumCharacters,
              metrics.committedCharacterCount > 0,
              metrics.committedCharacterCount <= TypingTestSession.maximumCharacters,
              metrics.attemptedCharacterCount >= metrics.committedCharacterCount,
              metrics.correctAttemptCount <= metrics.attemptedCharacterCount,
              metrics.deletedCharacterCount <= metrics.attemptedCharacterCount,
              metrics.correctionCount <= metrics.deletedCharacterCount,
              metrics.compositionBackspaceCount + metrics.committedBackspaceCount == metrics.backspaceCount,
              metrics.backspaceCount <= metrics.physicalKeyCount + metrics.repeatKeyCount,
              metrics.committedCharacterCount == metrics.correctCharacterCount + metrics.substitutionCount + metrics.extraCharacterCount,
              metrics.expectedCharacterCount == metrics.correctCharacterCount + metrics.substitutionCount + metrics.omissionCount,
              (metrics.chordCount != nil) == result.context.chordCountingAvailable,
              metrics.chordCount.map({ $0 >= 0 && $0 <= TypingTestSession.maximumCounter }) ?? true,
              result.practiceReasons.count <= TypingTestPracticeReason.allCases.count,
              Set(result.practiceReasons).count == result.practiceReasons.count,
              result.isComplete || result.practiceReasons.contains(.incomplete),
              !metrics.speedSamples.isEmpty,
              metrics.speedSamples.count <= TypingTestSession.maximumSamples,
              metrics.effectiveCPM.isFinite, metrics.rawCPM.isFinite,
              metrics.keysPerSecond.isFinite,
              metrics.speedSamples.last?.elapsedSeconds == metrics.elapsedSeconds,
              metrics.speedSamples.last?.effectiveCPM == metrics.effectiveCPM else { return false }
        var last: TimeInterval = 0
        for sample in metrics.speedSamples {
            guard sample.elapsedSeconds.isFinite, sample.elapsedSeconds > last,
                  sample.elapsedSeconds <= metrics.elapsedSeconds,
                  sample.effectiveCPM.isFinite, sample.effectiveCPM >= 0,
                  sample.effectiveCPM <= Double(metrics.expectedCharacterCount) * 60 / sample.elapsedSeconds
            else { return false }
            last = sample.elapsedSeconds
        }
        return true
    }

    private static func validIdentifier(_ value: String, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= 256
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
