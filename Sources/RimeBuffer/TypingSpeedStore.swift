import Foundation

extension Notification.Name {
    static let typingSpeedDidChange = Notification.Name("RimeBuffer.TypingSpeed.didChange")
}

struct TypingSpeedDaySnapshot: Equatable {
    let dayKey: String
    let keyCount: Int
    let committedCharacterCount: Int
    let chordCount: Int
    let activeSeconds: TimeInterval
    let sessionCount: Int

    var keysPerMinute: Double {
        guard activeSeconds > 0 else { return 0 }
        return Double(keyCount) * 60 / max(1, activeSeconds)
    }

    var charactersPerMinute: Double {
        guard activeSeconds > 0 else { return 0 }
        return Double(committedCharacterCount) * 60 / max(1, activeSeconds)
    }

    static let empty = TypingSpeedDaySnapshot(
        dayKey: "", keyCount: 0, committedCharacterCount: 0,
        chordCount: 0, activeSeconds: 0, sessionCount: 0
    )
}

struct TypingSpeedSessionSnapshot: Equatable {
    let startedAt: TimeInterval
    let endedAt: TimeInterval
    let dayKey: String
    let keyCount: Int
    let committedCharacterCount: Int
    let chordCount: Int
    let activeSeconds: TimeInterval

    var charactersPerMinute: Double {
        guard activeSeconds > 0 else { return 0 }
        return Double(committedCharacterCount) * 60 / max(1, activeSeconds)
    }
}

struct TypingSpeedHistorySnapshot: Equatable {
    let days: [TypingSpeedDaySnapshot]
    let recentSessions: [TypingSpeedSessionSnapshot]
    let bestCharactersPerMinute: Double
}

final class TypingSpeedStore {
    static let shared = TypingSpeedStore()

    static let maximumFileBytes = 4 * 1_048_576
    private static let maximumDays = LocalMetricsValidation.maximumHistoryDays
    private static let maximumSessions = 500
    private static let maximumCounter = 1_000_000_000
    private static let maximumActiveSeconds: TimeInterval = 1_000_000_000

    // NSEvent's device-independent Control, Option, and Command bits. Keep the
    // telemetry model value-only while excluding host shortcuts at this sink.
    private static let shortcutModifierMask: UInt =
        (UInt(1) << 18) | (UInt(1) << 19) | (UInt(1) << 20)
    private static let pureNavigationKeyIDs: Set<String> = [
        "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
        "Home", "End", "PageUp", "PageDown",
    ]

    private struct DayRecord: Codable {
        var keyCount: Int
        var committedCharacterCount: Int
        var chordCount: Int
        var activeSeconds: TimeInterval
        var sessionCount: Int
    }

    private struct SessionRecord: Codable {
        var startedAt: TimeInterval
        var endedAt: TimeInterval
        var dayKey: String
        var keyCount: Int
        var committedCharacterCount: Int
        var chordCount: Int
        var activeSeconds: TimeInterval
    }

    private struct StoreFile: Codable {
        var version: Int
        var days: [String: DayRecord]
        var sessions: [SessionRecord]
        var updatedAt: TimeInterval
    }

    private var url: URL
    private let autosaveDelay: TimeInterval
    private let inactivityThreshold: TimeInterval
    private var calendar = Calendar(identifier: .gregorian)
    private var file: StoreFile
    private var currentSessionIndex: Int?
    private var lastEventAt: TimeInterval?
    private var pendingSave: DispatchWorkItem?
    private(set) var storageIssue: String?

    init(storageRoot: URL? = nil,
         autosaveDelay: TimeInterval = 1,
         inactivityThreshold: TimeInterval = 10) {
        let environmentRoot = ProcessInfo.processInfo.environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
            ?? ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        let root = storageRoot
            ?? environmentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/\(RimesPaths.directoryName)")
        url = root.appendingPathComponent("stats/typing_speed.json")
        self.autosaveDelay = autosaveDelay
        self.inactivityThreshold = max(1, inactivityThreshold)
        let loaded = Self.load(from: url)
        file = loaded.file
        storageIssue = loaded.issue
    }

    func consume(_ event: InputTelemetryEvent) {
        guard storageIssue == nil else { return }
        if case let .key(value) = event,
           !Self.countsTowardTypingSpeed(value) {
            return
        }
        let timestamp: TimeInterval
        switch event {
        case let .key(value): timestamp = value.timestamp
        case let .commit(value):
            guard value.characterCount > 0,
                  value.characterCount <= Self.maximumCounter else { return }
            timestamp = value.timestamp
        case let .chord(value):
            guard value.duration.isFinite,
                  value.duration >= 0,
                  value.handledReleaseCount >= 0 else { return }
            timestamp = value.timestamp
        }
        guard timestamp.isFinite, timestamp >= 0 else { return }
        var dayKey = self.dayKey(for: timestamp)
        if file.days[dayKey] == nil {
            guard LocalMetricsValidation.validDayKeys(
                Array(file.days.keys) + [dayKey],
                maximumCount: Self.maximumDays
            ) else { return }
        }
        let requiresNewSession: Bool
        if let lastEventAt,
           timestamp >= lastEventAt,
           timestamp - lastEventAt <= inactivityThreshold,
           let index = currentSessionIndex,
           file.sessions.indices.contains(index),
           file.sessions[index].dayKey == dayKey {
            requiresNewSession = false
        } else {
            requiresNewSession = true
        }

        if requiresNewSession {
            file.sessions.append(SessionRecord(
                startedAt: timestamp, endedAt: timestamp, dayKey: dayKey,
                keyCount: 0, committedCharacterCount: 0,
                chordCount: 0, activeSeconds: 0
            ))
            if file.sessions.count > Self.maximumSessions {
                file.sessions.removeFirst(file.sessions.count - Self.maximumSessions)
            }
            currentSessionIndex = file.sessions.indices.last
            var day = file.days[dayKey] ?? Self.emptyDay()
            day.sessionCount = Self.boundedAdd(day.sessionCount, 1,
                                               maximum: Self.maximumCounter)
            file.days[dayKey] = day
        }

        guard let sessionIndex = currentSessionIndex,
              file.sessions.indices.contains(sessionIndex) else { return }
        dayKey = file.sessions[sessionIndex].dayKey
        var day = file.days[dayKey] ?? Self.emptyDay()
        if let lastEventAt,
           !requiresNewSession,
           timestamp >= lastEventAt {
            let delta = min(timestamp - lastEventAt, inactivityThreshold)
            file.sessions[sessionIndex].activeSeconds = min(
                Self.maximumActiveSeconds,
                file.sessions[sessionIndex].activeSeconds + delta
            )
            day.activeSeconds = min(Self.maximumActiveSeconds,
                                    day.activeSeconds + delta)
        }
        file.sessions[sessionIndex].endedAt = max(file.sessions[sessionIndex].endedAt, timestamp)
        switch event {
        case .key:
            file.sessions[sessionIndex].keyCount = Self.boundedAdd(
                file.sessions[sessionIndex].keyCount, 1,
                maximum: Self.maximumCounter
            )
            day.keyCount = Self.boundedAdd(day.keyCount, 1,
                                           maximum: Self.maximumCounter)
        case let .commit(value):
            file.sessions[sessionIndex].committedCharacterCount = Self.boundedAdd(
                file.sessions[sessionIndex].committedCharacterCount,
                value.characterCount,
                maximum: Self.maximumCounter
            )
            day.committedCharacterCount = Self.boundedAdd(
                day.committedCharacterCount,
                value.characterCount,
                maximum: Self.maximumCounter
            )
        case .chord:
            file.sessions[sessionIndex].chordCount = Self.boundedAdd(
                file.sessions[sessionIndex].chordCount, 1,
                maximum: Self.maximumCounter
            )
            day.chordCount = Self.boundedAdd(day.chordCount, 1,
                                             maximum: Self.maximumCounter)
        }
        file.days[dayKey] = day
        lastEventAt = timestamp
        file.updatedAt = Date().timeIntervalSince1970
        scheduleSave()
        NotificationCenter.default.post(name: .typingSpeedDidChange, object: self)
    }

    /// Heat-map observers still receive every physical press. Only the speed
    /// aggregate rejects repeats, host shortcuts, and navigation-only keys.
    static func countsTowardTypingSpeed(_ key: InputTelemetryEvent.Key) -> Bool {
        !key.isRepeat
            && key.modifierFlags & shortcutModifierMask == 0
            && !pureNavigationKeyIDs.contains(key.keyID)
    }

    func snapshot(for date: Date) -> TypingSpeedDaySnapshot {
        snapshot(dayKey: dayKey(for: date.timeIntervalSince1970))
    }

    func snapshot(dayKey: String) -> TypingSpeedDaySnapshot {
        guard let day = file.days[dayKey] else {
            return TypingSpeedDaySnapshot(
                dayKey: dayKey, keyCount: 0, committedCharacterCount: 0,
                chordCount: 0, activeSeconds: 0, sessionCount: 0
            )
        }
        return Self.snapshot(dayKey: dayKey, record: day)
    }

    func historySnapshot() -> TypingSpeedHistorySnapshot {
        let days = file.days.map { Self.snapshot(dayKey: $0.key, record: $0.value) }
            .sorted { $0.dayKey < $1.dayKey }
        let sessions = file.sessions.suffix(100).reversed().map(Self.snapshot(session:))
        return TypingSpeedHistorySnapshot(
            days: days,
            recentSessions: sessions,
            bestCharactersPerMinute: sessions.map(\.charactersPerMinute).max() ?? 0
        )
    }

    /// Do not bridge an excluded practice session or a disabled collector
    /// into the surrounding day's active-time denominator.
    func endCurrentSession() {
        currentSessionIndex = nil
        lastEventAt = nil
    }

    func clearAll() {
        guard storageIssue == nil else { return }
        file = Self.emptyFile()
        currentSessionIndex = nil
        lastEventAt = nil
        saveNow()
        NotificationCenter.default.post(name: .typingSpeedDidChange, object: self)
    }

    func saveNow() {
        guard storageIssue == nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            guard Self.validate(file) else {
                storageIssue = "测速数据结构或数值超出安全范围"
                IMELog.write("typing-speed save blocked: invalid in-memory aggregate")
                NotificationCenter.default.post(name: .typingSpeedDidChange,
                                                object: self)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try LocalMetricsFileSecurity.write(
                encoder.encode(file),
                to: url,
                maximumBytes: Self.maximumFileBytes
            )
        } catch {
            storageIssue = error.localizedDescription
            IMELog.write("typing-speed save FAILED: \(error.localizedDescription)")
            NotificationCenter.default.post(name: .typingSpeedDidChange,
                                            object: self)
        }
    }

    /// Explicit recovery path for an unreadable, oversized, or unsafe store.
    /// The original path entry is moved beside the new store before any write;
    /// a symbolic link is therefore preserved as a link and is never followed.
    @discardableResult
    func repairReadOnlyStore() -> Bool {
        guard storageIssue != nil else { return true }
        pendingSave?.cancel()
        pendingSave = nil

        do {
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            if fileManager.fileExists(atPath: directory.path)
                || LocalMetricsFileSecurity.pathEntryIsSymbolicLink(directory) {
                try LocalMetricsFileSecurity.validateDirectoryIfPresent(directory)
                try fileManager.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: directory.path)
            }

            let isSymbolicLink = LocalMetricsFileSecurity.pathEntryIsSymbolicLink(url)
            if isSymbolicLink || fileManager.fileExists(atPath: url.path) {
                let sourceIsRegularFile: Bool
                if isSymbolicLink {
                    sourceIsRegularFile = false
                } else {
                    let values = try url.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ])
                    sourceIsRegularFile = values.isRegularFile == true
                        && values.isSymbolicLink != true
                }

                let stamp = Int(Date().timeIntervalSince1970)
                let backup = url.deletingPathExtension()
                    .appendingPathExtension(
                        "corrupt-\(stamp)-\(UUID().uuidString.lowercased()).json"
                    )
                try fileManager.moveItem(at: url, to: backup)
                if sourceIsRegularFile {
                    try fileManager.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: backup.path)
                }
            }

            file = Self.emptyFile()
            currentSessionIndex = nil
            lastEventAt = nil
            storageIssue = nil
            // The same URL may have cached its pre-repair symlink/file resource
            // values. Drop them before validating the newly written regular file.
            url.removeAllCachedResourceValues()
            saveNow()
            guard storageIssue == nil else { return false }
            NotificationCenter.default.post(name: .typingSpeedDidChange, object: self)
            return true
        } catch {
            storageIssue = error.localizedDescription
            IMELog.write("typing-speed repair FAILED: \(error.localizedDescription)")
            NotificationCenter.default.post(name: .typingSpeedDidChange, object: self)
            return false
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: item)
    }

    private func dayKey(for timestamp: TimeInterval) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day], from: Date(timeIntervalSince1970: timestamp)
        )
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func snapshot(dayKey: String, record: DayRecord) -> TypingSpeedDaySnapshot {
        TypingSpeedDaySnapshot(
            dayKey: dayKey,
            keyCount: record.keyCount,
            committedCharacterCount: record.committedCharacterCount,
            chordCount: record.chordCount,
            activeSeconds: record.activeSeconds,
            sessionCount: record.sessionCount
        )
    }

    private static func snapshot(session: SessionRecord) -> TypingSpeedSessionSnapshot {
        TypingSpeedSessionSnapshot(
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            dayKey: session.dayKey,
            keyCount: session.keyCount,
            committedCharacterCount: session.committedCharacterCount,
            chordCount: session.chordCount,
            activeSeconds: session.activeSeconds
        )
    }

    private static func emptyDay() -> DayRecord {
        DayRecord(keyCount: 0, committedCharacterCount: 0,
                  chordCount: 0, activeSeconds: 0, sessionCount: 0)
    }

    private static func emptyFile() -> StoreFile {
        StoreFile(version: 1, days: [:], sessions: [],
                  updatedAt: Date().timeIntervalSince1970)
    }

    private static func load(from url: URL) -> (file: StoreFile, issue: String?) {
        do {
            guard let data = try LocalMetricsFileSecurity.readIfPresent(
                from: url,
                maximumBytes: maximumFileBytes
            ) else {
                return (emptyFile(), nil)
            }
            let decoded = try JSONDecoder().decode(StoreFile.self, from: data)
            guard validate(decoded) else {
                return (emptyFile(), "测速数据结构或数值超出安全范围")
            }
            return (decoded, nil)
        } catch {
            IMELog.write("typing-speed load FAILED; preserving file: \(error.localizedDescription)")
            return (emptyFile(), error.localizedDescription)
        }
    }

    private static func validate(_ value: StoreFile) -> Bool {
        value.version == 1
            && value.updatedAt.isFinite
            && value.updatedAt >= 0
            && LocalMetricsValidation.validDayKeys(value.days.keys,
                                                   maximumCount: maximumDays)
            && value.sessions.count <= maximumSessions
            && value.days.values.allSatisfy(valid(day:))
            && value.sessions.allSatisfy(valid(session:))
    }

    private static func valid(day: DayRecord) -> Bool {
        validCounter(day.keyCount)
            && validCounter(day.committedCharacterCount)
            && validCounter(day.chordCount)
            && day.activeSeconds.isFinite
            && day.activeSeconds >= 0
            && day.activeSeconds <= maximumActiveSeconds
            && validCounter(day.sessionCount)
    }

    private static func valid(session: SessionRecord) -> Bool {
        session.startedAt.isFinite
            && session.startedAt >= 0
            && session.endedAt.isFinite
            && session.endedAt >= session.startedAt
            && LocalMetricsValidation.date(forDayKey: session.dayKey) != nil
            && validCounter(session.keyCount)
            && validCounter(session.committedCharacterCount)
            && validCounter(session.chordCount)
            && session.activeSeconds.isFinite
            && session.activeSeconds >= 0
            && session.activeSeconds <= maximumActiveSeconds
    }

    private static func validCounter(_ value: Int) -> Bool {
        value >= 0 && value <= maximumCounter
    }

    private static func boundedAdd(_ lhs: Int,
                                   _ rhs: Int,
                                   maximum: Int) -> Int {
        guard lhs < maximum, rhs > 0 else { return min(maximum, max(0, lhs)) }
        return rhs >= maximum - lhs ? maximum : lhs + rhs
    }
}
