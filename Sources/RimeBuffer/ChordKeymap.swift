import Foundation
import Darwin

enum ChordMappingKind: String, Codable, CaseIterable, Equatable, Hashable {
    case fragment
    case syllable

    var title: String {
        switch self {
        case .fragment: return "拼音片段"
        case .syllable: return "完整音节"
        }
    }
}

enum ChordKeymapBoundaryPolicy: String, Codable, CaseIterable, Equatable, Hashable {
    case legacyBatches
    case explicitSyllables

    var title: String {
        switch self {
        case .legacyBatches: return "每个多键批次（兼容飞耀）"
        case .explicitSyllables: return "按映射类型（完整音节／片段）"
        }
    }
}

struct ChordKeymapEntry: Codable, Equatable, Hashable {
    var keys: String
    var output: String
    var kind: ChordMappingKind
}

enum ChordKeymapError: LocalizedError {
    case invalid(String)
    case missing(String)
    case readOnlyBuiltIn
    case activeProfileRemoval
    case unsafePath
    case unreadable
    case tooLarge
    case tooManyProfiles

    var errorDescription: String? {
        switch self {
        case let .invalid(reason): return "并击键位方案无效：\(reason)"
        case let .missing(name): return "未找到并击键位方案：\(name)"
        case .readOnlyBuiltIn: return "内置方案不能覆盖或删除；飞耀可以先复制再编辑。"
        case .activeProfileRemoval: return "当前使用的键位方案不能删除，请先应用其他方案。"
        case .unsafePath: return "键位方案路径不是安全的本机普通文件或目录。"
        case .unreadable: return "无法读写并击键位方案文件。"
        case .tooLarge: return "键位方案文件超过 2 MiB 限制。"
        case .tooManyProfiles: return "最多保存 128 个自定义并击键位方案。"
        }
    }
}

/// A portable data-only keymap. Physical singleton batches remain literal;
/// mappings describe sets of two or more participating keys, never key order.
struct ChordKeymapProfile: Codable, Equatable, Identifiable {
    static let builtInID = "builtin.flyyao"
    static let allowedKeys = "abcdefghijklmnopqrstuvwxyz,."
    static let maximumMappings = 4_096
    static let maximumFileBytes = 2 * 1_024 * 1_024

    var formatVersion: Int = 1
    var id: String
    var name: String
    var leftKeys: String
    var rightKeys: String
    var mappings: [ChordKeymapEntry]
    var boundaryPolicy: ChordKeymapBoundaryPolicy = .explicitSyllables
    var outputEncoding: ChordOutputEncoding = .fullPinyin
    /// Set only on the read-only presets of NativeChordSchemeCatalog: the
    /// bundled Rime schema that owns chording, instead of a mapping table.
    var nativeSchemeID: String?

    init(formatVersion: Int = 1, id: String, name: String,
         leftKeys: String, rightKeys: String, mappings: [ChordKeymapEntry],
         boundaryPolicy: ChordKeymapBoundaryPolicy = .explicitSyllables,
         outputEncoding: ChordOutputEncoding = .fullPinyin,
         nativeSchemeID: String? = nil) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.leftKeys = leftKeys
        self.rightKeys = rightKeys
        self.mappings = mappings
        self.boundaryPolicy = boundaryPolicy
        self.outputEncoding = outputEncoding
        self.nativeSchemeID = nativeSchemeID
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, leftKeys, rightKeys, mappings, boundaryPolicy, outputEncoding
        case nativeSchemeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        leftKeys = try container.decode(String.self, forKey: .leftKeys)
        rightKeys = try container.decode(String.self, forKey: .rightKeys)
        mappings = try container.decode([ChordKeymapEntry].self, forKey: .mappings)
        boundaryPolicy = try container.decodeIfPresent(ChordKeymapBoundaryPolicy.self,
                                                       forKey: .boundaryPolicy) ?? .explicitSyllables
        outputEncoding = try container.decodeIfPresent(ChordOutputEncoding.self,
                                                       forKey: .outputEncoding) ?? .fullPinyin
        nativeSchemeID = try container.decodeIfPresent(String.self, forKey: .nativeSchemeID)
    }

    var alphabet: String { leftKeys + rightKeys }
    var isBuiltIn: Bool { id == Self.builtInID }
    var isNative: Bool { nativeSchemeID != nil }
    /// Read-only presets: the 飞耀 template and every native chord scheme.
    var isPreset: Bool { isBuiltIn || isNative }
    var schemaID: String {
        if let nativeSchemeID { return nativeSchemeID }
        return isBuiltIn ? "my_combo"
            : "rimes_chord_" + id.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func newProfile(name: String = "自定义并击") -> ChordKeymapProfile {
        ChordKeymapProfile(id: UUID().uuidString.lowercased(),
                           name: name,
                           leftKeys: "qwertasdfgzxcvb",
                           rightKeys: "yuiophjklnm,.",
                           mappings: [])
    }

    func duplicated(name: String? = nil) -> ChordKeymapProfile {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name = name ?? String(self.name.prefix(70)) + " 副本"
        return copy
    }

    static func builtIn(from schema: FlyChordSchema) -> ChordKeymapProfile {
        var profile = ChordKeymapProfile(id: builtInID,
                                         name: schema.displayName,
                                         leftKeys: "qwertasdfgzxcvb",
                                         rightKeys: "yuiophjklnm,.",
                                         mappings: [],
                                         boundaryPolicy: .legacyBatches)
        let left = Set(profile.leftKeys)
        let right = Set(profile.rightKeys)
        profile.mappings = schema.mappings.compactMap { mapping in
            let keys = Set(mapping.chord)
            guard keys.count > 1 else { return nil }
            let spansHalves = !keys.isDisjoint(with: left)
                && !keys.isDisjoint(with: right)
            return ChordKeymapEntry(keys: profile.canonicalKeys(mapping.chord),
                                    output: mapping.output,
                                    kind: spansHalves ? .syllable : .fragment)
        }
        return profile
    }

    /// Canonical order also defines deterministic fallback for unmapped sets.
    /// Unknown characters are retained so callers cannot hide invalid input by
    /// canonicalizing it before validation.
    func canonicalKeys(_ keys: String) -> String {
        let present = Set(keys)
        let known = Set(alphabet)
        return String(alphabet.filter(present.contains))
            + String(present.subtracting(known).sorted())
    }

    func entry(for keys: Set<Int32>) -> ChordKeymapEntry? {
        guard keys.count > 1 else { return nil }
        var characters = ""
        for key in keys {
            guard let scalar = UnicodeScalar(Int(key)),
                  alphabet.unicodeScalars.contains(scalar) else { return nil }
            characters.unicodeScalars.append(scalar)
        }
        let canonical = canonicalKeys(characters)
        return mappings.first { canonicalKeys($0.keys) == canonical }
    }

    func half(for key: Int32) -> FlyChordHalf? {
        guard let scalar = UnicodeScalar(Int(key)) else { return nil }
        if leftKeys.unicodeScalars.contains(scalar) { return .left }
        if rightKeys.unicodeScalars.contains(scalar) { return .right }
        return nil
    }

    /// Drafts may have an empty table; applying one must have real mappings.
    func validated(requireMappings: Bool = true) throws -> ChordKeymapProfile {
        guard formatVersion == 1 else {
            throw ChordKeymapError.invalid("不支持的格式版本 \(formatVersion)")
        }
        // A native preset is defined by the app, not by file contents: a
        // stored snapshot resolves to the current preset, and nothing else may
        // claim a native schema.
        if let preset = NativeChordSchemeCatalog.profile(id: id) {
            guard nativeSchemeID == nil || nativeSchemeID == preset.nativeSchemeID else {
                throw ChordKeymapError.invalid("原生并击方案与所属 Rime 方案不一致")
            }
            return preset
        }
        guard nativeSchemeID == nil else {
            throw ChordKeymapError.invalid("原生并击方案只能使用内置预设，不能导入或复制为自定义键位")
        }
        guard isBuiltIn || UUID(uuidString: id) != nil else {
            throw ChordKeymapError.invalid("方案 ID 必须是 UUID")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, name.utf8.count <= 240,
              name.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.newlines.contains($0)
              }) else {
            throw ChordKeymapError.invalid("名称须为 1–80 个字符，不能包含换行或控制字符")
        }
        let allowed = Set(Self.allowedKeys)
        let keys = Set(alphabet)
        guard !keys.isEmpty, keys.count == alphabet.count,
              keys.isSubset(of: allowed) else {
            throw ChordKeymapError.invalid("左右键区只能使用 a–z、逗号和句号，且每个键只能属于一个键区")
        }
        guard mappings.count <= Self.maximumMappings,
              !requireMappings || !mappings.isEmpty else {
            throw ChordKeymapError.invalid("应用方案需要 1–4096 条映射")
        }
        guard !isBuiltIn || outputEncoding == .fullPinyin else {
            throw ChordKeymapError.invalid("内置飞耀方案只能使用全拼输出，请复制后再切换编码")
        }
        var normalized = self
        normalized.id = isBuiltIn ? id : id.lowercased()
        var seen = Set<String>()
        normalized.mappings = try mappings.enumerated().map { index, mapping in
            let row = index + 1
            let combination = Set(mapping.keys)
            guard combination.count >= 2,
                  combination.count == mapping.keys.count,
                  combination.isSubset(of: keys) else {
                throw ChordKeymapError.invalid("第 \(row) 条映射须包含至少两个不同的已分区键；单键始终保留原字符")
            }
            let canonical = canonicalKeys(mapping.keys)
            guard seen.insert(canonical).inserted else {
                throw ChordKeymapError.invalid("第 \(row) 条映射与已有键组合 \(canonical.uppercased()) 重复（顺序无关）")
            }
            guard !mapping.output.isEmpty, mapping.output.utf8.count <= 32,
                  mapping.output.utf8.allSatisfy({ (97...122).contains($0) }) else {
                throw ChordKeymapError.invalid("第 \(row) 条输出须为 1–32 个小写英文字母；ü 请写 v")
            }
            if outputEncoding == .ziranma, engineOutput(for: mapping) == nil {
                throw ChordKeymapError.invalid(mapping.kind == .syllable
                    ? "第 \(row) 条“\(mapping.output)”不是可转为自然码的完整拼音音节"
                    : "第 \(row) 条“\(mapping.output)”不是可转为自然码的声母或韵母片段")
            }
            return ChordKeymapEntry(keys: canonical,
                                    output: mapping.output,
                                    kind: mapping.kind)
        }
        return normalized
    }
}

extension Notification.Name {
    /// Posted only when an explicit activation publishes an effective snapshot.
    static let chordKeymapDidChange = Notification.Name("RIMES.ChordKeymap.didChange")
}

/// Draft files and the active snapshot deliberately have different lifetimes.
/// Saving an active draft cannot change key behavior, even after app restart.
/// The deployment owner activates its exact frozen revision after validation.
final class ChordKeymapStore {
    static let shared = ChordKeymapStore()
    static let maximumCustomProfiles = 128
    private static let activeIDKey = "chord.keymap.activeID.v1"

    let directoryURL: URL
    var activeProfileURL: URL { directoryURL.appendingPathComponent("active-profile.json") }

    private let rootURL: URL
    private let defaults: UserDefaults
    private let builtInLoader: () throws -> ChordKeymapProfile
    private let lock = NSRecursiveLock()
    private var cachedBuiltIn: ChordKeymapProfile?
    private var cachedActive: ChordKeymapProfile?
    private var cachedLoadError: Error?

    init(rootURL: URL? = nil,
         defaults: UserDefaults = .standard,
         builtInLoader: (() throws -> ChordKeymapProfile)? = nil) {
        let environment = ProcessInfo.processInfo.environment
        self.rootURL = (rootURL
            ?? (environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
                ?? environment["RIMEBUFFER_USER_DIR"]).map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/\(RimesPaths.directoryName)", isDirectory: true))
            .standardizedFileURL
        directoryURL = self.rootURL.appendingPathComponent("chord-keymaps", isDirectory: true)
        self.defaults = defaults
        self.builtInLoader = builtInLoader ?? {
            ChordKeymapProfile.builtIn(from: try FlyChordSchemaParser.loadDefault())
        }
    }

    /// Read this after activeProfile to show a recovered startup error in UI.
    var loadError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return cachedLoadError
    }

    var activeProfile: ChordKeymapProfile {
        lock.lock()
        defer { lock.unlock() }
        if let cachedActive { return cachedActive }
        do {
            if let data = try readData(at: activeProfileURL) {
                let saved = try decode(data, requireMappings: true)
                // The built-in is a maintained template: app/schema upgrades
                // advance it, while custom profiles remain frozen snapshots.
                cachedActive = saved.isBuiltIn ? try builtInProfile() : saved
            } else if let selected = defaults.string(forKey: Self.activeIDKey),
                      selected != ChordKeymapProfile.builtInID {
                throw ChordKeymapError.missing("已应用方案快照（\(selected)）")
            } else {
                cachedActive = try builtInProfile()
            }
        } catch {
            cachedLoadError = error
            // Never substitute the latest draft for a missing/corrupt applied
            // snapshot. Keep a deterministic built-in fallback and surface it.
            cachedActive = (try? builtInProfile()) ?? ChordKeymapProfile(
                id: ChordKeymapProfile.builtInID,
                name: "飞耀输入",
                leftKeys: "qwertasdfgzxcvb",
                rightKeys: "yuiophjklnm,.",
                mappings: [],
                boundaryPolicy: .legacyBatches
            )
        }
        return cachedActive!
    }

    func allProfiles() throws -> [ChordKeymapProfile] {
        lock.lock()
        defer { lock.unlock() }
        let builtin = try builtInProfile()
        let files = try profileFiles()
        let custom = try files.map { url -> ChordKeymapProfile in
            guard let data = try readData(at: url) else {
                throw ChordKeymapError.missing(url.lastPathComponent)
            }
            let profile = try decode(data, requireMappings: false)
            guard !profile.isPreset,
                  url.deletingPathExtension().lastPathComponent == profile.id else {
                throw ChordKeymapError.invalid("文件名与方案 ID 不一致：\(url.lastPathComponent)")
            }
            return profile
        }.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return [builtin] + NativeChordSchemeCatalog.all + custom
    }

    func profile(id: String) throws -> ChordKeymapProfile {
        lock.lock()
        defer { lock.unlock() }
        if id == ChordKeymapProfile.builtInID { return try builtInProfile() }
        if let native = NativeChordSchemeCatalog.profile(id: id) { return native }
        let url = try profileURL(id: id)
        guard let data = try readData(at: url) else { throw ChordKeymapError.missing(id) }
        let profile = try decode(data, requireMappings: false)
        guard profile.id == id.lowercased(), !profile.isPreset else {
            throw ChordKeymapError.invalid("文件名与方案 ID 不一致")
        }
        return profile
    }

    func save(_ profile: ChordKeymapProfile) throws {
        lock.lock()
        defer { lock.unlock() }
        let normalized = try profile.validated(requireMappings: false)
        guard !normalized.isPreset else { throw ChordKeymapError.readOnlyBuiltIn }
        let target = try profileURL(id: normalized.id)
        let files = try profileFiles()
        guard files.contains(target) || files.count < Self.maximumCustomProfiles else {
            throw ChordKeymapError.tooManyProfiles
        }
        try writeData(exportData(normalized), to: target)
    }

    func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard id != ChordKeymapProfile.builtInID,
              NativeChordSchemeCatalog.profile(id: id) == nil else {
            throw ChordKeymapError.readOnlyBuiltIn
        }
        guard activeProfile.id != id.lowercased() else { throw ChordKeymapError.activeProfileRemoval }
        let target = try profileURL(id: id)
        guard try readData(at: target) != nil else { throw ChordKeymapError.missing(id) }
        guard unlink(target.path) == 0 else { throw ChordKeymapError.unreadable }
    }

    func setActiveProfile(id: String) throws {
        try activate(profile(id: id))
    }

    /// Does not modify the draft. Also used to restore a previous effective
    /// revision after a failed deployment without destroying later edits.
    func activate(_ profile: ChordKeymapProfile) throws {
        let normalized = try profile.validated()
        lock.lock()
        do {
            let previous = activeProfile
            try writeData(exportData(normalized), to: activeProfileURL)
            defaults.set(normalized.id, forKey: Self.activeIDKey)
            cachedActive = normalized
            cachedLoadError = nil
            lock.unlock()
            if previous != normalized {
                NotificationCenter.default.post(
                    name: .chordKeymapDidChange,
                    object: self,
                    userInfo: ["previousProfileID": previous.id,
                               "currentProfileID": normalized.id]
                )
            }
        } catch {
            lock.unlock()
            throw error
        }
    }

    func importData(_ data: Data) throws -> ChordKeymapProfile {
        var profile = try decode(data, requireMappings: false)
        guard !profile.isNative else {
            throw ChordKeymapError.invalid("原生并击方案已内置，请直接在方案列表中选择")
        }
        profile.id = UUID().uuidString.lowercased()
        return try profile.validated(requireMappings: false)
    }

    func exportData(_ profile: ChordKeymapProfile) throws -> Data {
        let normalized = try profile.validated(requireMappings: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        guard data.count <= ChordKeymapProfile.maximumFileBytes else { throw ChordKeymapError.tooLarge }
        return data
    }

    private func builtInProfile() throws -> ChordKeymapProfile {
        if let cachedBuiltIn { return cachedBuiltIn }
        let builtin = try builtInLoader().validated()
        guard builtin.isBuiltIn else { throw ChordKeymapError.invalid("内置方案身份不匹配") }
        cachedBuiltIn = builtin
        return builtin
    }

    private func decode(_ data: Data, requireMappings: Bool) throws -> ChordKeymapProfile {
        guard data.count <= ChordKeymapProfile.maximumFileBytes else { throw ChordKeymapError.tooLarge }
        let profile: ChordKeymapProfile
        do { profile = try JSONDecoder().decode(ChordKeymapProfile.self, from: data) }
        catch { throw ChordKeymapError.invalid("JSON 格式或字段类型不正确") }
        return try profile.validated(requireMappings: requireMappings)
    }

    private func profileURL(id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ChordKeymapError.invalid("方案 ID 必须是 UUID") }
        return directoryURL.appendingPathComponent(id.lowercased() + ".json")
    }

    private func profileFiles() throws -> [URL] {
        guard try checkDirectory(at: directoryURL) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let files = children.filter {
            $0.pathExtension == "json" && $0.lastPathComponent != "active-profile.json"
        }
        guard files.count <= Self.maximumCustomProfiles else { throw ChordKeymapError.tooManyProfiles }
        return files
    }

    @discardableResult
    private func checkDirectory(at url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw ChordKeymapError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid() else {
            throw ChordKeymapError.unsafePath
        }
        return true
    }

    private func prepareDirectory() throws {
        if try !checkDirectory(at: rootURL) {
            try FileManager.default.createDirectory(at: rootURL,
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        if try !checkDirectory(at: directoryURL) {
            try FileManager.default.createDirectory(at: directoryURL,
                                                     withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
        }
        guard try checkDirectory(at: rootURL), try checkDirectory(at: directoryURL) else {
            throw ChordKeymapError.unsafePath
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                             ofItemAtPath: directoryURL.path)
    }

    private func readData(at url: URL) throws -> Data? {
        // Check the root too: a symlink introduced after initialization cannot
        // redirect a managed file read to a different user-data tree.
        guard try checkDirectory(at: rootURL), try checkDirectory(at: directoryURL) else { return nil }
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            if errno == ENOENT { return nil }
            throw ChordKeymapError.unreadable
        }
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid(), (before.st_mode & 0o777) == 0o600 else {
            throw ChordKeymapError.unsafePath
        }
        guard before.st_size >= 0,
              before.st_size <= ChordKeymapProfile.maximumFileBytes else {
            throw ChordKeymapError.tooLarge
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ChordKeymapError.unreadable }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino, (opened.st_mode & S_IFMT) == S_IFREG else {
            throw ChordKeymapError.unsafePath
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ChordKeymapError.unreadable
            }
            data.append(buffer, count: count)
            guard data.count <= ChordKeymapProfile.maximumFileBytes else { throw ChordKeymapError.tooLarge }
        }
        return data
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        _ = try readData(at: url) // Refuse symlinks/nonregular existing targets.
        let temporary = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                      S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ChordKeymapError.unreadable }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ChordKeymapError.unreadable }
                offset += count
            }
        }
        guard fsync(fd) == 0, fchmod(fd, S_IRUSR | S_IWUSR) == 0,
              rename(temporary.path, url.path) == 0 else {
            throw ChordKeymapError.unreadable
        }
        renamed = true
        // Publish the complete file before consumers are notified.
        let directoryFD = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            close(directoryFD)
        }
    }
}

/// The generated schema is a RIMES-owned adapter over the full rime_ice chain.
/// All table matches first become non-alphabet markers; only after the final
/// match do markers expand to the encoded output (full pinyin or 自然码
/// codes), so an output can never rematch a key set.
enum ChordKeymapCompiler {
    static func algebraRules(for profile: ChordKeymapProfile) throws -> [String] {
        let profile = try profile.validated()
        var rules: [String] = []
        // Move each key to the front, from last to first. With the composer's
        // unique-key set this gives profile order for any event arrival order,
        // including unknown chords and comma/period keys.
        for character in profile.alphabet.reversed() {
            let literal = regexLiteral(String(character))
            rules.append("xform/^(.*)(\(literal))(.*)$/$2$1$3/")
        }
        for (index, mapping) in profile.mappings.enumerated() {
            rules.append("xform/^\(regexLiteral(mapping.keys))$/~\(index)~/")
        }
        // The stream source accepts letters and spaces only. Preserve the same
        // unknown multi-key fallback here: keep letters in profile order and
        // consume its punctuation keys. Single comma/period batches remain
        // untouched for punctuator. Staged known mappings contain no such keys.
        rules.append("xform/^([a-z,.]{2,})$/!$1!/")
        rules.append("xform/^!(.*)[,.](.*)!$/!$1$2!/")
        rules.append("xform/^!(.*)[,.](.*)!$/!$1$2!/")
        rules.append("xform/^!(.*)!$/$1/")
        for (index, mapping) in profile.mappings.enumerated() {
            // validated() guarantees every output encodes.
            rules.append("xform/^~\(index)~$/\(profile.engineOutput(for: mapping) ?? mapping.output)/")
        }
        return rules
    }

    static func schemaYAML(for profile: ChordKeymapProfile) throws -> String {
        let profile = try profile.validated()
        let algebra = try algebraRules(for: profile).map { "    - " + yamlScalar($0) }
            .joined(separator: "\n")
        let spelling = spellingYAML(for: profile.outputEncoding)
        return """
        # Generated from a RIMES chord keymap; edit the profile, not this file.
        __include: rime_ice.schema:/
        schema:
          schema_id: \(profile.schemaID)
          name: \(yamlScalar(profile.name))
          version: '1.0'
          dependencies:
            - rime_ice
        switches:
          - name: ascii_mode
            reset: 0
            states: [ 中, 英 ]
        engine:
          processors:
            - lua_processor@*select_character
            - ascii_composer
            - recognizer
            - chord_composer
            - key_binder
            - speller
            - punctuator
            - selector
            - navigator
            - express_editor
          segmentors:
            - ascii_segmentor
            - matcher
            - abc_segmentor
            - affix_segmentor@radical_lookup
            - punct_segmentor
            - fallback_segmentor
          translators:
            - punct_translator
            - script_translator
            - lua_translator@*date_translator
            - lua_translator@*lunar
            - table_translator@custom_phrase
            - table_translator@melt_eng
            - table_translator@cn_en
            - table_translator@radical_lookup
            - lua_translator@*unicode
            - lua_translator@*number_translator
            - lua_translator@*calc_translator
            - lua_translator@*force_gc
          filters:
            - lua_filter@*corrector
            - reverse_lookup_filter@radical_reverse_lookup
            - lua_filter@*autocap_filter
            - lua_filter@*pin_cand_filter
            - lua_filter@*long_word_filter
            - lua_filter@*reduce_english_filter
            - simplifier@emoji
            - simplifier@traditionalize
            - lua_filter@*search@radical_pinyin
            - uniquifier
        ascii_composer:
          good_old_caps_lock: true
          switch_key:
            Caps_Lock: clear
            Shift_L: commit_code
            Shift_R: commit_code
            Control_L: noop
            Control_R: noop
        chord_composer:
          alphabet: \(yamlScalar(profile.alphabet))
          algebra:
        \(algebra)
        \(spelling)
        punctuator:
          import_preset: default
        key_binder:
          import_preset: default
        recognizer:
          import_preset: default
          patterns:
            punct: "^$"

        """
    }

    /// Speller, translator and the code-keyed side tables. Both encodings
    /// share the rime_ice dictionary, so user learning carries across them.
    private static func spellingYAML(for encoding: ChordOutputEncoding) -> String {
        func list(_ rules: [String]) -> String {
            rules.map { "    - " + yamlScalar($0) }.joined(separator: "\n")
        }
        switch encoding {
        case .fullPinyin:
            return """
            speller:
              __include: rime_ice.schema:/speller
              alphabet: 'qwertyuiopasdfghjklzxcvbnm'
              initials: 'qwertyuiopasdfghjklzxcvbnm'
              delimiter: " '"
            translator:
              dictionary: rime_ice
              prism: rime_ice
              enable_word_completion: true
              spelling_hints: 8
              always_show_comments: true
              initial_quality: 1.2
              comment_format:
                - xform/^/［/
                - xform/$/］/
              preedit_format:
                - xform/([nl])v/$1ü/
                - xform/([nl])ue/$1üe/
                - xform/([jqxy])v/$1u/
            """
        case .ziranma:
            // No abbrev: initials-only spellings would reintroduce the
            // variable-length segmentation this encoding exists to remove.
            // rime_ice's two-letter date/lunar triggers (ts, sj, xq, nl) are
            // real 自然码 syllables, so they move to words as in
            // double_pinyin. Pins stay inherited: pin_cand_filter matches the
            // formatted pinyin preedit, not the codes.
            return """
            speller:
              alphabet: 'qwertyuiopasdfghjklzxcvbnm'
              initials: 'qwertyuiopasdfghjklzxcvbnm'
              delimiter: " '"
              algebra:
            \(list(ZiranmaShuangpin.syllableAlgebra))
            translator:
              dictionary: rime_ice
              prism: rimes_chord_ziranma
              enable_word_completion: true
              spelling_hints: 8
              always_show_comments: true
              initial_quality: 1.2
              comment_format:
                - xform/^/［/
                - xform/$/］/
              preedit_format:
            \(list(ZiranmaShuangpin.preeditFormat))
            cn_en:
              user_dict: en_dicts/cn_en_double_pinyin
            custom_phrase:
              user_dict: custom_phrase_double
            date_translator:
              date: date
              time: time
              week: week
              datetime: datetime
              timestamp: timestamp
            lunar: lunar
            """
        }
    }

    private static func yamlScalar(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func regexLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: ".", with: "\\.")
    }
}
