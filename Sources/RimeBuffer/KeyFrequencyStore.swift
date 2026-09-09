import AppKit
import Foundation

extension Notification.Name {
    static let keyFrequencyDidChange = Notification.Name("KeyFrequencyDidChange")
}

struct KeyFrequencySnapshot {
    let dayKey: String
    let counts: [String: Int]
    let total: Int
    let maxCount: Int
    let topKeyId: String?

    static let empty = KeyFrequencySnapshot(
        dayKey: "",
        counts: [:],
        total: 0,
        maxCount: 0,
        topKeyId: nil
    )
}

struct KeyFrequencyDayTotal: Equatable {
    let dayKey: String
    let total: Int
}

struct KeyFrequencyHistorySnapshot: Equatable {
    let days: [KeyFrequencyDayTotal]
    let total: Int
    let maxDayTotal: Int
    let firstDayKey: String?
    let lastDayKey: String?

    static let empty = KeyFrequencyHistorySnapshot(
        days: [], total: 0, maxDayTotal: 0,
        firstDayKey: nil, lastDayKey: nil
    )
}

enum KeyFrequencyStorageState: Equatable {
    case ready
    case readOnly(reason: String)
}

enum LocalMetricsFileSecurity {
    enum StorageError: LocalizedError {
        case unsafeDirectory
        case unsafeFile
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsafeDirectory: return "统计目录不是安全的本地目录"
            case .unsafeFile: return "统计文件不是安全的常规文件"
            case .fileTooLarge: return "统计文件超过安全大小限制"
            }
        }
    }

    static func readIfPresent(from url: URL,
                              maximumBytes: Int,
                              fileManager: FileManager = .default) throws -> Data? {
        try validateDirectoryIfPresent(url.deletingLastPathComponent(),
                                       fileManager: fileManager)
        guard !pathEntryIsSymbolicLink(url, fileManager: fileManager) else {
            throw StorageError.unsafeFile
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw StorageError.unsafeFile
        }
        try fileManager.setAttributes([.posixPermissions: 0o700],
                                      ofItemAtPath: url.deletingLastPathComponent().path)
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: url.path)
        guard let size = values.fileSize,
              size >= 0,
              size <= maximumBytes else {
            throw StorageError.fileTooLarge
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func write(_ data: Data,
                      to url: URL,
                      maximumBytes: Int,
                      fileManager: FileManager = .default) throws {
        guard data.count <= maximumBytes else { throw StorageError.fileTooLarge }
        let directory = url.deletingLastPathComponent()
        if pathEntryIsSymbolicLink(directory, fileManager: fileManager) {
            throw StorageError.unsafeDirectory
        } else if fileManager.fileExists(atPath: directory.path) {
            try validateDirectoryIfPresent(directory, fileManager: fileManager)
        } else {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700],
                                      ofItemAtPath: directory.path)

        if pathEntryIsSymbolicLink(url, fileManager: fileManager) {
            throw StorageError.unsafeFile
        } else if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw StorageError.unsafeFile
            }
        }
        try data.write(to: url, options: .atomic)
        let written = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard written.isRegularFile == true,
              written.isSymbolicLink != true else {
            throw StorageError.unsafeFile
        }
        try fileManager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: url.path)
    }

    static func validateDirectoryIfPresent(_ url: URL,
                                           fileManager: FileManager = .default) throws {
        guard !pathEntryIsSymbolicLink(url, fileManager: fileManager) else {
            throw StorageError.unsafeDirectory
        }
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw StorageError.unsafeDirectory
        }
    }

    static func pathEntryIsSymbolicLink(_ url: URL,
                                        fileManager: FileManager = .default) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

enum LocalMetricsValidation {
    static let maximumHistoryDays = 36_600

    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    static func date(forDayKey value: String) -> Date? {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day else { return nil }
        return date
    }

    static func validDayKeys<S: Sequence>(_ keys: S,
                                          maximumCount: Int) -> Bool where S.Element == String {
        let values = Array(keys)
        guard values.count <= maximumCount else { return false }
        let dates = values.compactMap(date(forDayKey:))
        guard dates.count == values.count else { return false }
        guard let first = dates.min(), let last = dates.max() else { return true }
        guard let span = calendar.dateComponents([.day], from: first, to: last).day else {
            return false
        }
        return span >= 0 && span < maximumHistoryDays
    }
}

final class KeyFrequencyStore {
    static let shared = KeyFrequencyStore()

    static let maximumFileBytes = 4 * 1_048_576
    private static let maximumDays = LocalMetricsValidation.maximumHistoryDays
    private static let maximumKeysPerDay = 512
    private static let maximumCounter = 1_000_000_000

    private struct StoreFile: Codable {
        var version: Int
        var days: [String: DayRecord]
        var updatedAt: TimeInterval
    }

    private struct DayRecord: Codable {
        var keys: [String: Int]
    }

    private let url: URL
    private let dateProvider: () -> Date
    private let autosaveDelay: TimeInterval
    private let calendar = Calendar(identifier: .gregorian)
    private var file: StoreFile
    private(set) var storageState: KeyFrequencyStorageState
    private var pendingSave: DispatchWorkItem?

    init(
        storageRoot: URL? = nil,
        autosaveDelay: TimeInterval = 1.0,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        let environmentRoot = ProcessInfo.processInfo.environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
            ?? ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        let root = storageRoot
            ?? environmentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/\(RimesPaths.directoryName)")
        self.url = root.appendingPathComponent("stats/key_frequency.json")
        self.autosaveDelay = autosaveDelay
        self.dateProvider = dateProvider
        let loaded = Self.load(from: self.url)
        self.file = loaded.file
        self.storageState = loaded.state
    }

    func record(keyCode: UInt16) {
        guard let keyId = KeyboardLayout.keyId(forKeyCode: keyCode) else { return }
        record(keyID: keyId, at: dateProvider())
    }

    func recordModifierPress(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard KeyboardLayout.isModifierKey(keyCode),
              KeyboardLayout.isModifierPressed(keyCode: keyCode, flags: flags),
              let keyId = KeyboardLayout.keyId(forKeyCode: keyCode)
        else { return }
        record(keyID: keyId, at: dateProvider())
    }

    /// Used by the built-in statistics plugin after the input path has mapped
    /// a hardware key code. Unknown/empty identifiers are rejected so corrupt
    /// observers cannot create unbounded JSON keys.
    func record(keyID: String, at day: Date) {
        guard storageState == .ready,
              !keyID.isEmpty, keyID.count <= 80 else { return }
        let key = dayKey(for: day)
        if file.days[key] == nil {
            guard LocalMetricsValidation.validDayKeys(
                Array(file.days.keys) + [key],
                maximumCount: Self.maximumDays
            ) else { return }
        }
        var record = file.days[key] ?? DayRecord(keys: [:])
        guard file.days[key] != nil || file.days.count < Self.maximumDays,
              record.keys[keyID] != nil || record.keys.count < Self.maximumKeysPerDay else {
            return
        }
        let current = record.keys[keyID, default: 0]
        guard current < Self.maximumCounter else { return }
        record.keys[keyID] = current + 1
        file.days[key] = record
        file.updatedAt = Date().timeIntervalSince1970
        scheduleSave()
        NotificationCenter.default.post(name: .keyFrequencyDidChange, object: self)
    }

    func snapshot(for day: Date) -> KeyFrequencySnapshot {
        snapshot(dayKey: dayKey(for: day))
    }

    func snapshot(dayKey: String) -> KeyFrequencySnapshot {
        makeSnapshot(dayKey: dayKey)
    }

    func historySnapshot() -> KeyFrequencyHistorySnapshot {
        let days = file.days.map { dayKey, record in
            KeyFrequencyDayTotal(dayKey: dayKey,
                                 total: record.keys.values.reduce(0, +))
        }.sorted { $0.dayKey < $1.dayKey }
        guard !days.isEmpty else { return .empty }
        return KeyFrequencyHistorySnapshot(
            days: days,
            total: days.reduce(0) { $0 + $1.total },
            maxDayTotal: days.map(\.total).max() ?? 0,
            firstDayKey: days.first?.dayKey,
            lastDayKey: days.last?.dayKey
        )
    }

    func clear(day: Date?) {
        guard storageState == .ready else { return }
        if let day {
            file.days.removeValue(forKey: dayKey(for: day))
        } else {
            file.days.removeAll()
        }
        file.updatedAt = Date().timeIntervalSince1970
        saveNow()
        NotificationCenter.default.post(name: .keyFrequencyDidChange, object: self)
    }

    func saveNow() {
        guard storageState == .ready else { return }
        pendingSave?.cancel()
        pendingSave = nil
        do {
            guard Self.validate(file) else {
                storageState = .readOnly(reason: "统计数据结构或数值超出安全范围")
                IMELog.write("key-frequency save blocked: invalid in-memory aggregate")
                NotificationCenter.default.post(name: .keyFrequencyDidChange,
                                                object: self)
                return
            }
            let data = try JSONEncoder.prettySorted.encode(file)
            try LocalMetricsFileSecurity.write(data,
                                               to: url,
                                               maximumBytes: Self.maximumFileBytes)
        } catch {
            storageState = .readOnly(reason: error.localizedDescription)
            IMELog.write("key-frequency save FAILED: \(error.localizedDescription)")
            NotificationCenter.default.post(name: .keyFrequencyDidChange,
                                            object: self)
        }
    }

    func dayKey(for day: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Explicit recovery path for a corrupt/unknown file. The unreadable file
    /// is preserved beside the new store instead of being silently replaced by
    /// the next key event.
    @discardableResult
    func repairReadOnlyStore() -> Bool {
        guard case .readOnly = storageState else { return true }
        do {
            let directory = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) {
                try LocalMetricsFileSecurity.validateDirectoryIfPresent(directory)
                try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                      ofItemAtPath: directory.path)
            }
            let isSymbolicLink = LocalMetricsFileSecurity.pathEntryIsSymbolicLink(url)
            if isSymbolicLink || FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                let stamp = Int(Date().timeIntervalSince1970)
                let backup = url.deletingPathExtension()
                    .appendingPathExtension(
                        "corrupt-\(stamp)-\(UUID().uuidString.lowercased()).json"
                    )
                try FileManager.default.moveItem(at: url, to: backup)
                if !isSymbolicLink, values.isSymbolicLink != true {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                          ofItemAtPath: backup.path)
                }
            }
            file = Self.emptyFile()
            storageState = .ready
            saveNow()
            NotificationCenter.default.post(name: .keyFrequencyDidChange, object: self)
            return true
        } catch {
            storageState = .readOnly(reason: error.localizedDescription)
            IMELog.write("key-frequency repair FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private func makeSnapshot(dayKey: String) -> KeyFrequencySnapshot {
        let counts = file.days[dayKey]?.keys ?? [:]
        let total = counts.values.reduce(0, +)
        let maxCount = counts.values.max() ?? 0
        let topKeyId = counts.max { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        }?.key
        return KeyFrequencySnapshot(
            dayKey: dayKey,
            counts: counts,
            total: total,
            maxCount: maxCount,
            topKeyId: topKeyId
        )
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: work)
    }

    private static func emptyFile() -> StoreFile {
        StoreFile(version: 1, days: [:], updatedAt: Date().timeIntervalSince1970)
    }

    private static func load(from url: URL) -> (file: StoreFile, state: KeyFrequencyStorageState) {
        do {
            guard let data = try LocalMetricsFileSecurity.readIfPresent(
                from: url,
                maximumBytes: maximumFileBytes
            ) else {
                return (emptyFile(), .ready)
            }
            let decoded = try JSONDecoder().decode(StoreFile.self, from: data)
            guard validate(decoded) else {
                return (emptyFile(), .readOnly(reason: "统计数据结构或数值超出安全范围"))
            }
            return (decoded, .ready)
        } catch {
            IMELog.write("key-frequency load FAILED; preserving file read-only: \(error.localizedDescription)")
            return (emptyFile(), .readOnly(reason: error.localizedDescription))
        }
    }

    private static func validate(_ value: StoreFile) -> Bool {
        value.version == 1
            && value.updatedAt.isFinite
            && value.updatedAt >= 0
            && LocalMetricsValidation.validDayKeys(value.days.keys,
                                                   maximumCount: maximumDays)
            && value.days.values.allSatisfy { record in
                record.keys.count <= maximumKeysPerDay
                    && record.keys.allSatisfy { keyID, count in
                        !keyID.isEmpty
                            && keyID.count <= 80
                            && count >= 0
                            && count <= maximumCounter
                    }
            }
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct KeyboardKeySpec {
    let keyId: String
    let label: String
    let keyCode: UInt16?
    let frame: CGRect
}

struct KeyboardLayout {
    let keys: [KeyboardKeySpec]
    let size: CGSize

    static let macANSI = KeyboardLayout(keys: macANSIKeys)

    init(keys: [KeyboardKeySpec]) {
        self.keys = keys
        let maxX = keys.map { $0.frame.maxX }.max() ?? 0
        let maxY = keys.map { $0.frame.maxY }.max() ?? 0
        self.size = CGSize(width: maxX, height: maxY)
    }

    static func keyId(forKeyCode keyCode: UInt16) -> String? {
        keyCodeToKeyId[keyCode]
    }

    static func displayName(for keyId: String) -> String {
        keyIdToLabel[keyId] ?? keyId
    }

    static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func isModifierPressed(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 57: return true
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63: return flags.contains(.function)
        default: return false
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let keyCodeToKeyId: [UInt16: String] = {
        var map = Dictionary(uniqueKeysWithValues: macANSIKeys.compactMap { key in
            key.keyCode.map { ($0, key.keyId) }
        })
        let extra: [UInt16: String] = [
            64: "F17", 65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd",
            71: "NumpadClear", 75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract",
            81: "NumpadEqual", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2",
            85: "Numpad3", 86: "Numpad4", 87: "Numpad5", 88: "Numpad6",
            89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 105: "F13",
            106: "F16", 107: "F14", 113: "F15", 114: "Help"
        ]
        for (code, keyId) in extra { map[code] = keyId }
        return map
    }()

    private static let keyIdToLabel: [String: String] = {
        var map = Dictionary(uniqueKeysWithValues: macANSIKeys.map { ($0.keyId, $0.label) })
        let extra = [
            "NumpadDecimal": "Num .", "NumpadMultiply": "Num *", "NumpadAdd": "Num +",
            "NumpadClear": "Clear", "NumpadDivide": "Num /", "NumpadEnter": "Num Enter",
            "NumpadSubtract": "Num -", "NumpadEqual": "Num =", "Numpad0": "Num 0",
            "Numpad1": "Num 1", "Numpad2": "Num 2", "Numpad3": "Num 3",
            "Numpad4": "Num 4", "Numpad5": "Num 5", "Numpad6": "Num 6",
            "Numpad7": "Num 7", "Numpad8": "Num 8", "Numpad9": "Num 9"
        ]
        for (keyId, label) in extra { map[keyId] = label }
        return map
    }()

    private static let macANSIKeys: [KeyboardKeySpec] = [
        key("Escape", "Esc", 53, 0, 0, 1.15),
        key("F1", "F1", 122, 1.6, 0), key("F2", "F2", 120, 2.7, 0),
        key("F3", "F3", 99, 3.8, 0), key("F4", "F4", 118, 4.9, 0),
        key("F5", "F5", 96, 6.25, 0), key("F6", "F6", 97, 7.35, 0),
        key("F7", "F7", 98, 8.45, 0), key("F8", "F8", 100, 9.55, 0),
        key("F9", "F9", 101, 10.9, 0), key("F10", "F10", 109, 12.0, 0),
        key("F11", "F11", 103, 13.1, 0), key("F12", "F12", 111, 14.2, 0),

        key("Backquote", "`", 50, 0, 1.35), key("Digit1", "1", 18, 1.05, 1.35),
        key("Digit2", "2", 19, 2.1, 1.35), key("Digit3", "3", 20, 3.15, 1.35),
        key("Digit4", "4", 21, 4.2, 1.35), key("Digit5", "5", 23, 5.25, 1.35),
        key("Digit6", "6", 22, 6.3, 1.35), key("Digit7", "7", 26, 7.35, 1.35),
        key("Digit8", "8", 28, 8.4, 1.35), key("Digit9", "9", 25, 9.45, 1.35),
        key("Digit0", "0", 29, 10.5, 1.35), key("Minus", "-", 27, 11.55, 1.35),
        key("Equal", "=", 24, 12.6, 1.35), key("Backspace", "Delete", 51, 13.65, 1.35, 1.65),

        key("Tab", "Tab", 48, 0, 2.4, 1.45), key("KeyQ", "Q", 12, 1.5, 2.4),
        key("KeyW", "W", 13, 2.55, 2.4), key("KeyE", "E", 14, 3.6, 2.4),
        key("KeyR", "R", 15, 4.65, 2.4), key("KeyT", "T", 17, 5.7, 2.4),
        key("KeyY", "Y", 16, 6.75, 2.4), key("KeyU", "U", 32, 7.8, 2.4),
        key("KeyI", "I", 34, 8.85, 2.4), key("KeyO", "O", 31, 9.9, 2.4),
        key("KeyP", "P", 35, 10.95, 2.4), key("BracketLeft", "[", 33, 12.0, 2.4),
        key("BracketRight", "]", 30, 13.05, 2.4), key("Backslash", "\\", 42, 14.1, 2.4, 1.2),

        key("CapsLock", "Caps", 57, 0, 3.45, 1.7), key("KeyA", "A", 0, 1.75, 3.45),
        key("KeyS", "S", 1, 2.8, 3.45), key("KeyD", "D", 2, 3.85, 3.45),
        key("KeyF", "F", 3, 4.9, 3.45), key("KeyG", "G", 5, 5.95, 3.45),
        key("KeyH", "H", 4, 7.0, 3.45), key("KeyJ", "J", 38, 8.05, 3.45),
        key("KeyK", "K", 40, 9.1, 3.45), key("KeyL", "L", 37, 10.15, 3.45),
        key("Semicolon", ";", 41, 11.2, 3.45), key("Quote", "'", 39, 12.25, 3.45),
        key("Enter", "Return", 36, 13.3, 3.45, 2.0),

        key("LeftShift", "Shift", 56, 0, 4.5, 2.25), key("KeyZ", "Z", 6, 2.3, 4.5),
        key("KeyX", "X", 7, 3.35, 4.5), key("KeyC", "C", 8, 4.4, 4.5),
        key("KeyV", "V", 9, 5.45, 4.5), key("KeyB", "B", 11, 6.5, 4.5),
        key("KeyN", "N", 45, 7.55, 4.5), key("KeyM", "M", 46, 8.6, 4.5),
        key("Comma", ",", 43, 9.65, 4.5), key("Period", ".", 47, 10.7, 4.5),
        key("Slash", "/", 44, 11.75, 4.5), key("RightShift", "Shift", 60, 12.8, 4.5, 2.5),

        key("Function", "fn", 63, 0, 5.55, 0.85), key("LeftControl", "Control", 59, 0.9, 5.55, 1.25),
        key("LeftOption", "Option", 58, 2.2, 5.55, 1.25), key("LeftCommand", "Command", 55, 3.5, 5.55, 1.45),
        key("Space", "Space", 49, 5.0, 5.55, 4.8), key("RightCommand", "Command", 54, 9.85, 5.55, 1.45),
        key("RightOption", "Option", 61, 11.35, 5.55, 1.25), key("ArrowLeft", "←", 123, 12.85, 5.8, 0.9, 0.65),
        key("ArrowUp", "↑", 126, 13.8, 5.55, 0.9, 0.65), key("ArrowDown", "↓", 125, 13.8, 6.25, 0.9, 0.65),
        key("ArrowRight", "→", 124, 14.75, 5.8, 0.9, 0.65),
        key("Home", "Home", 115, 15.95, 1.35), key("PageUp", "PgUp", 116, 17.0, 1.35),
        key("ForwardDelete", "Del", 117, 15.95, 2.4), key("End", "End", 119, 15.95, 3.45),
        key("PageDown", "PgDn", 121, 17.0, 3.45)
    ]

    private static func key(
        _ id: String,
        _ label: String,
        _ keyCode: UInt16?,
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat = 1,
        _ height: CGFloat = 0.85
    ) -> KeyboardKeySpec {
        KeyboardKeySpec(
            keyId: id,
            label: label,
            keyCode: keyCode,
            frame: CGRect(x: x, y: y, width: width, height: height)
        )
    }
}
