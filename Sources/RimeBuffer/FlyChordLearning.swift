import Foundation

/// Pure-model support for learning the `my_combo` chord schema. The Rime
/// schema identifier is intentionally kept stable while the product-facing
/// name can evolve independently.
enum FlyChordLearningIdentity {
    static let schemaID = "my_combo"
    static let displayName = "飞耀输入"
    static let schemaFileName = "my_combo.schema.yaml"
    static let maximumSchemaBytes = 2 * 1_024 * 1_024
}

struct FlyChordLiteralRule: Equatable {
    let input: String
    let output: String
    let order: Int
    let sourceLine: Int
}

struct FlyChordMapping: Identifiable, Equatable {
    let id: String
    let chord: String
    let output: String
    let keyCount: Int
    let sourceOrder: Int
}

struct FlyChordSchema: Equatable {
    let schemaID: String
    let displayName: String
    let alphabet: String
    let sourceURL: URL
    let literalRules: [FlyChordLiteralRule]
    let mappings: [FlyChordMapping]
}

enum FlyChordSchemaError: LocalizedError, Equatable {
    case schemaNotFound
    case unreadableSchema(String)
    case unexpectedSchemaID(String)
    case missingChordComposer
    case missingAlgebra
    case noLiteralMappings

    var errorDescription: String? {
        switch self {
        case .schemaNotFound:
            return "未找到飞耀输入方案文件（my_combo.schema.yaml）"
        case let .unreadableSchema(path):
            return "无法读取飞耀输入方案：\(path)"
        case let .unexpectedSchemaID(id):
            return "并击方案 ID 不匹配：\(id)"
        case .missingChordComposer:
            return "并击方案缺少 chord_composer 配置"
        case .missingAlgebra:
            return "并击方案缺少 chord_composer.algebra 配置"
        case .noLiteralMappings:
            return "并击方案中没有可用于学习的精确映射"
        }
    }
}

/// Locates the source-tree schema during development and the copied schema in
/// an installed app's Contents/SharedSupport directory. Candidate roots are
/// injectable so the parser and smoke test never depend on a running IME.
enum FlyChordSchemaLocator {
    static func candidateURLs(
        additionalSearchRoots: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                    isDirectory: true)
    ) -> [URL] {
        var candidates: [URL] = []
        func appendSchema(at root: URL) {
            if root.lastPathComponent == FlyChordLearningIdentity.schemaFileName {
                candidates.append(root)
            } else {
                candidates.append(
                    root.appendingPathComponent(FlyChordLearningIdentity.schemaFileName)
                )
            }
        }

        additionalSearchRoots.forEach(appendSchema)
        let userRoot: URL
        if let userOverride = environment["RIMEBUFFER_USER_DIR"],
           !userOverride.isEmpty {
            userRoot = URL(fileURLWithPath: userOverride, isDirectory: true)
        } else {
            userRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        }
        // Rime applies `my_combo.custom.yaml` during deployment. The effective
        // algebra therefore lives in build/, while the root schema remains the
        // safe fallback before the first successful deployment.
        appendSchema(at: userRoot.appendingPathComponent("build", isDirectory: true))
        appendSchema(at: userRoot)
        if let override = environment["RIMEBUFFER_SHARED_DIR"], !override.isEmpty {
            appendSchema(at: URL(fileURLWithPath: override, isDirectory: true))
        }
        if let sharedSupportPath = bundle.sharedSupportPath, !sharedSupportPath.isEmpty {
            appendSchema(at: URL(fileURLWithPath: sharedSupportPath, isDirectory: true))
        }
        appendSchema(at: currentDirectory.appendingPathComponent("rime-data", isDirectory: true))
        appendSchema(at: currentDirectory)

        var seen = Set<String>()
        return candidates.compactMap { candidate -> URL? in
            let standardized = candidate.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    static func locate(
        additionalSearchRoots: [URL] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                    isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        for candidate in candidateURLs(additionalSearchRoots: additionalSearchRoots,
                                       environment: environment,
                                       bundle: bundle,
                                       currentDirectory: currentDirectory) {
            guard let values = try? candidate.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.fileSize ?? FlyChordLearningIdentity.maximumSchemaBytes + 1)
                <= FlyChordLearningIdentity.maximumSchemaBytes,
            fileManager.isReadableFile(atPath: candidate.path) else {
                continue
            }
            return candidate
        }
        throw FlyChordSchemaError.schemaNotFound
    }
}

enum FlyChordSchemaParser {
    private struct ParsedSection {
        let schemaID: String
        let alphabet: String
        let algebraScalars: [(line: Int, value: String)]
    }

    static func load(from url: URL) throws -> FlyChordSchema {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        (values.fileSize ?? FlyChordLearningIdentity.maximumSchemaBytes + 1)
            <= FlyChordLearningIdentity.maximumSchemaBytes,
        let data = try? Data(contentsOf: url),
        data.count <= FlyChordLearningIdentity.maximumSchemaBytes,
        let text = String(data: data, encoding: .utf8) else {
            throw FlyChordSchemaError.unreadableSchema(url.path)
        }
        return try parse(text, sourceURL: url)
    }

    static func loadDefault(additionalSearchRoots: [URL] = []) throws -> FlyChordSchema {
        try load(from: FlyChordSchemaLocator.locate(
            additionalSearchRoots: additionalSearchRoots
        ))
    }

    static func parse(_ text: String, sourceURL: URL) throws -> FlyChordSchema {
        let section = try parseSection(text)
        guard section.schemaID == FlyChordLearningIdentity.schemaID else {
            throw FlyChordSchemaError.unexpectedSchemaID(section.schemaID)
        }

        let rules = section.algebraScalars.enumerated().compactMap { index, scalar in
            parseLiteralRule(scalar.value,
                             order: index,
                             sourceLine: scalar.line)
        }
        let alphabet = section.alphabet.isEmpty
            ? "qwertyuiopasdfghjklzxcvbnm,."
            : section.alphabet
        let mappings = resolvedMappings(rules: rules, alphabet: Set(alphabet))
        guard !mappings.isEmpty else {
            throw FlyChordSchemaError.noLiteralMappings
        }
        return FlyChordSchema(schemaID: section.schemaID,
                              displayName: FlyChordLearningIdentity.displayName,
                              alphabet: alphabet,
                              sourceURL: sourceURL.standardizedFileURL,
                              literalRules: rules,
                              mappings: mappings)
    }

    private static func parseSection(_ text: String) throws -> ParsedSection {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var schemaID = ""
        var schemaIndent: Int?
        var chordIndent: Int?
        var algebraIndent: Int?
        var alphabet = ""
        var scalars: [(line: Int, value: String)] = []

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let indent = leadingSpaceCount(rawLine)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed == "schema:" {
                schemaIndent = indent
                continue
            }
            if let activeSchemaIndent = schemaIndent,
               indent > activeSchemaIndent,
               trimmed.hasPrefix("schema_id:"),
               schemaID.isEmpty {
                schemaID = yamlScalar(afterColonIn: trimmed) ?? ""
                continue
            }
            if let activeSchemaIndent = schemaIndent,
               indent <= activeSchemaIndent,
               trimmed != "schema:" {
                schemaIndent = nil
            }

            if trimmed == "chord_composer:" {
                chordIndent = indent
                algebraIndent = nil
                continue
            }
            guard let activeChordIndent = chordIndent else { continue }
            if indent <= activeChordIndent {
                chordIndent = nil
                algebraIndent = nil
                continue
            }

            if trimmed.hasPrefix("alphabet:"), alphabet.isEmpty {
                alphabet = yamlScalar(afterColonIn: trimmed) ?? ""
                continue
            }
            if trimmed == "algebra:" {
                algebraIndent = indent
                continue
            }
            guard let activeAlgebraIndent = algebraIndent else { continue }
            if indent <= activeAlgebraIndent {
                algebraIndent = nil
                continue
            }
            guard trimmed.hasPrefix("-") else { continue }
            let item = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            if let scalar = yamlScalar(item) {
                scalars.append((lineNumber, scalar))
            }
        }

        guard chordIndent != nil || lines.contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "chord_composer:"
        }) else {
            throw FlyChordSchemaError.missingChordComposer
        }
        guard !scalars.isEmpty else {
            throw FlyChordSchemaError.missingAlgebra
        }
        return ParsedSection(schemaID: schemaID,
                             alphabet: alphabet,
                             algebraScalars: scalars)
    }

    private static func parseLiteralRule(_ scalar: String,
                                         order: Int,
                                         sourceLine: Int) -> FlyChordLiteralRule? {
        guard scalar.hasPrefix("xform/"), scalar.count <= 512 else { return nil }
        var index = scalar.index(scalar.startIndex, offsetBy: "xform/".count)
        guard let rawPattern = readDelimitedComponent(in: scalar, index: &index),
              let rawReplacement = readDelimitedComponent(in: scalar, index: &index),
              scalar[index...].trimmingCharacters(in: .whitespaces).isEmpty,
              rawPattern.hasPrefix("^"),
              rawPattern.hasSuffix("$"),
              !isEscapedCharacter(at: rawPattern.index(before: rawPattern.endIndex),
                                  in: rawPattern) else {
            return nil
        }

        let patternStart = rawPattern.index(after: rawPattern.startIndex)
        let patternEnd = rawPattern.index(before: rawPattern.endIndex)
        guard let input = decodeRegexLiteral(String(rawPattern[patternStart..<patternEnd])),
              let output = decodeReplacementLiteral(rawReplacement),
              !input.isEmpty,
              !output.isEmpty,
              input.count <= 32,
              output.count <= 64 else {
            return nil
        }
        return FlyChordLiteralRule(input: input,
                                   output: output,
                                   order: order,
                                   sourceLine: sourceLine)
    }

    /// Applies only the extracted exact rules, in their original order. This
    /// resolves exact temporary markers such as `wio -> w*en -> wen` without
    /// interpreting any skipped regex or wildcard rule.
    private static func resolvedMappings(rules: [FlyChordLiteralRule],
                                         alphabet: Set<Character>) -> [FlyChordMapping] {
        var firstOrder: [String: Int] = [:]
        for rule in rules where rule.input.allSatisfy(alphabet.contains) {
            if firstOrder[rule.input] == nil { firstOrder[rule.input] = rule.order }
        }

        return firstOrder.sorted { lhs, rhs in lhs.value < rhs.value }.compactMap { chord, order in
            var output = chord
            for rule in rules where output == rule.input {
                output = rule.output
            }
            guard !output.isEmpty, !output.contains("*") else { return nil }
            return FlyChordMapping(
                id: stableMappingID(schemaID: FlyChordLearningIdentity.schemaID,
                                    chord: chord,
                                    output: output),
                chord: chord,
                output: output,
                keyCount: chord.count,
                sourceOrder: order
            )
        }
    }

    private static func stableMappingID(schemaID: String,
                                        chord: String,
                                        output: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(schemaID)\u{0}\(chord)\u{0}\(output)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return "\(schemaID).rule.\(String(format: "%016llx", hash))"
    }

    private static func readDelimitedComponent(in value: String,
                                               index: inout String.Index) -> String? {
        var result = ""
        var escaped = false
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            if escaped {
                result.append("\\")
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "/" {
                return result
            } else {
                result.append(character)
            }
        }
        return nil
    }

    private static func decodeRegexLiteral(_ value: String) -> String? {
        let metacharacters = CharacterSet(charactersIn: ".^$*+?()[]{}|\\/")
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            if character == "\\" {
                guard index < value.endIndex else { return nil }
                let escaped = value[index]
                index = value.index(after: index)
                guard String(escaped).rangeOfCharacter(from: metacharacters) != nil else {
                    return nil
                }
                result.append(escaped)
                continue
            }
            guard String(character).rangeOfCharacter(from: metacharacters) == nil else {
                return nil
            }
            result.append(character)
        }
        return result
    }

    private static func decodeReplacementLiteral(_ value: String) -> String? {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            if character == "$" { return nil }
            if character == "\\" {
                guard index < value.endIndex else { return nil }
                let escaped = value[index]
                index = value.index(after: index)
                guard escaped == "\\" || escaped == "/" || escaped == "$" else {
                    return nil
                }
                result.append(escaped)
                continue
            }
            result.append(character)
        }
        return result
    }

    private static func isEscapedCharacter(at index: String.Index,
                                           in value: String) -> Bool {
        var slashCount = 0
        var cursor = index
        while cursor > value.startIndex {
            let previous = value.index(before: cursor)
            guard value[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount % 2 == 1
    }

    private static func yamlScalar(afterColonIn value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        return yamlScalar(String(value[value.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces))
    }

    private static func yamlScalar(_ value: String) -> String? {
        guard !value.isEmpty else { return "" }
        if value.first == "'" {
            var result = ""
            var index = value.index(after: value.startIndex)
            while index < value.endIndex {
                let character = value[index]
                index = value.index(after: index)
                if character == "'" {
                    if index < value.endIndex, value[index] == "'" {
                        result.append("'")
                        index = value.index(after: index)
                        continue
                    }
                    return result
                }
                result.append(character)
            }
            return nil
        }
        if value.first == "\"" {
            var escaped = false
            var index = value.index(after: value.startIndex)
            while index < value.endIndex {
                let character = value[index]
                if character == "\"" && !escaped {
                    let quoted = String(value[value.startIndex...index])
                    return try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                index = value.index(after: index)
            }
            return nil
        }

        let commentStart = value.indices.first { index in
            guard value[index] == "#", index > value.startIndex else { return false }
            return value[value.index(before: index)].isWhitespace
        }
        let end = commentStart ?? value.endIndex
        return String(value[..<end]).trimmingCharacters(in: .whitespaces)
    }

    private static func leadingSpaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}

struct FlyChordCourse: Identifiable, Equatable {
    let id: String
    let title: String
    let keyCount: Int
    let mappings: [FlyChordMapping]
}

struct FlyChordCurriculum: Equatable {
    let schemaID: String
    let displayName: String
    let alphabet: String
    let courses: [FlyChordCourse]

    var mappings: [FlyChordMapping] { courses.flatMap(\.mappings) }

    init(schema: FlyChordSchema) {
        schemaID = schema.schemaID
        displayName = schema.displayName
        alphabet = schema.alphabet
        courses = Dictionary(grouping: schema.mappings, by: \.keyCount)
            .keys.sorted()
            .compactMap { keyCount in
                guard let mappings = Dictionary(grouping: schema.mappings, by: \.keyCount)[keyCount],
                      !mappings.isEmpty else { return nil }
                return FlyChordCourse(
                    id: "\(schema.schemaID).keys.\(keyCount)",
                    title: Self.courseTitle(keyCount: keyCount),
                    keyCount: keyCount,
                    mappings: mappings.sorted { $0.sourceOrder < $1.sourceOrder }
                )
            }
    }

    func course(id: String) -> FlyChordCourse? {
        courses.first { $0.id == id }
    }

    private static func courseTitle(keyCount: Int) -> String {
        switch keyCount {
        case 1: return "单键热身"
        case 2: return "双键基础"
        case 3: return "三键进阶"
        case 4: return "四键强化"
        default: return "\(keyCount) 键挑战"
        }
    }
}

struct FlyChordExercise: Identifiable, Equatable {
    let id: String
    let courseID: String
    let mappingID: String
    let chord: String
    let expectedOutput: String
}

/// A chord is a simultaneous set of physical keys. Its textual order is an
/// internal normalization detail of the Rime algebra, not part of the answer:
/// the schema alphabet uses ordinary keyboard-row order while FlyYao rules use a
/// left-zone/right-zone canonical order. Comparing sets keeps practice aligned
/// with what the user actually pressed (for example Y+D+F answers `dfy`).
enum FlyChordAnswerMatcher {
    static func matches(captured: String, expected: String) -> Bool {
        guard !captured.isEmpty,
              captured.count == expected.count else { return false }
        return Set(captured) == Set(expected)
    }
}

enum FlyChordExerciseSampler {
    static func sample(from course: FlyChordCourse,
                       limit: Int,
                       progress: FlyChordProgressSnapshot = .empty,
                       seed: UInt64 = 0) -> [FlyChordExercise] {
        guard limit > 0 else { return [] }
        var random = SplitMix64(seed: seed ^ stableSeed(course.id))
        let grouped = Dictionary(grouping: course.mappings) { mapping -> Int in
            let item = progress.items[mapping.id]
            if item == nil || item?.attempts == 0 { return 0 }
            return item?.isMastered == true ? 2 : 1
        }
        let ordered = [0, 1, 2].flatMap { tier -> [FlyChordMapping] in
            shuffled(grouped[tier] ?? [], using: &random)
        }
        return ordered.prefix(limit).enumerated().map { index, mapping in
            FlyChordExercise(id: "\(course.id).exercise.\(index).\(mapping.id)",
                             courseID: course.id,
                             mappingID: mapping.id,
                             chord: mapping.chord,
                             expectedOutput: mapping.output)
        }
    }

    private static func shuffled<T>(_ values: [T], using random: inout SplitMix64) -> [T] {
        guard values.count > 1 else { return values }
        var result = values
        for upper in stride(from: result.count - 1, through: 1, by: -1) {
            let index = Int(random.next() % UInt64(upper + 1))
            if index != upper { result.swapAt(index, upper) }
        }
        return result
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private struct SplitMix64 {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }
}

struct FlyChordItemProgress: Equatable {
    static let masteryStreak = 3

    let attempts: Int
    let correctAttempts: Int
    let currentStreak: Int
    let bestStreak: Int
    let updatedAt: TimeInterval

    var isMastered: Bool { bestStreak >= Self.masteryStreak }
    var accuracy: Double {
        attempts == 0 ? 0 : Double(correctAttempts) / Double(attempts)
    }
}

struct FlyChordCourseProgress: Equatable {
    let totalItems: Int
    let attemptedItems: Int
    let masteredItems: Int
    let attempts: Int
    let correctAttempts: Int
}

struct FlyChordProgressSnapshot: Equatable {
    let schemaID: String
    let items: [String: FlyChordItemProgress]
    let updatedAt: TimeInterval

    static let empty = FlyChordProgressSnapshot(
        schemaID: FlyChordLearningIdentity.schemaID,
        items: [:],
        updatedAt: 0
    )

    func progress(for course: FlyChordCourse) -> FlyChordCourseProgress {
        let values = course.mappings.compactMap { items[$0.id] }
        return FlyChordCourseProgress(
            totalItems: course.mappings.count,
            attemptedItems: values.filter { $0.attempts > 0 }.count,
            masteredItems: values.filter(\.isMastered).count,
            attempts: values.reduce(0) { $0 + $1.attempts },
            correctAttempts: values.reduce(0) { $0 + $1.correctAttempts }
        )
    }
}

enum FlyChordProgressStoreError: LocalizedError, Equatable {
    case invalidProgressFile
    case invalidMappingID(String)
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidProgressFile:
            return "并击学习进度文件无效"
        case let .invalidMappingID(id):
            return "未知的并击练习项：\(id)"
        case let .fileOperation(message):
            return "保存并击学习进度失败：\(message)"
        }
    }
}

/// Stores only opaque mapping IDs, counters and timestamps. It never persists
/// chord/output text, focused-field identities, application identities or any
/// IMK object.
final class FlyChordProgressStore {
    private struct PersistedFile: Codable {
        var version: Int
        var schemaID: String
        var items: [String: PersistedItem]
        var updatedAt: TimeInterval
    }

    private struct PersistedItem: Codable {
        var attempts: Int
        var correctAttempts: Int
        var currentStreak: Int
        var bestStreak: Int
        var updatedAt: TimeInterval
    }

    private static let maximumFileBytes = 1_048_576
    static let maximumItems = 4_096

    let storageURL: URL
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let lock = NSLock()
    private var file: PersistedFile

    init(storageRoot: URL? = nil,
         fileManager: FileManager = .default,
         dateProvider: @escaping () -> Date = Date.init) throws {
        let environmentRoot = ProcessInfo.processInfo.environment["RIMEBUFFER_LOCAL_DATA_ROOT"]
            ?? ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"]
        let root = storageRoot
            ?? environmentRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        storageURL = root.appendingPathComponent("learning/my_combo_progress.json")
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        file = try Self.load(from: storageURL, fileManager: fileManager)
    }

    var snapshot: FlyChordProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot(file)
    }

    @discardableResult
    func recordAttempt(mappingID: String, correct: Bool) throws -> FlyChordProgressSnapshot {
        guard Self.validMappingID(mappingID) else {
            throw FlyChordProgressStoreError.invalidMappingID(mappingID)
        }
        lock.lock()
        defer { lock.unlock() }

        var updated = file
        let now = dateProvider().timeIntervalSince1970
        guard updated.items[mappingID] != nil
                || updated.items.count < Self.maximumItems else {
            throw FlyChordProgressStoreError.invalidProgressFile
        }
        var item = updated.items[mappingID] ?? PersistedItem(
            attempts: 0,
            correctAttempts: 0,
            currentStreak: 0,
            bestStreak: 0,
            updatedAt: now
        )
        item.attempts = Self.saturatingIncrement(item.attempts)
        if correct {
            item.correctAttempts = Self.saturatingIncrement(item.correctAttempts)
            item.currentStreak = Self.saturatingIncrement(item.currentStreak)
            item.bestStreak = max(item.bestStreak, item.currentStreak)
        } else {
            item.currentStreak = 0
        }
        item.updatedAt = now
        updated.items[mappingID] = item
        updated.updatedAt = now
        try persist(updated)
        file = updated
        return makeSnapshot(updated)
    }

    @discardableResult
    func clear() throws -> FlyChordProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let updated = PersistedFile(version: 1,
                                    schemaID: FlyChordLearningIdentity.schemaID,
                                    items: [:],
                                    updatedAt: dateProvider().timeIntervalSince1970)
        try persist(updated)
        file = updated
        return makeSnapshot(updated)
    }

    private func persist(_ value: PersistedFile) throws {
        do {
            guard Self.validate(value) else {
                throw FlyChordProgressStoreError.invalidProgressFile
            }
            try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= Self.maximumFileBytes else {
                throw FlyChordProgressStoreError.invalidProgressFile
            }
            try data.write(to: storageURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: storageURL.path)
        } catch let error as FlyChordProgressStoreError {
            throw error
        } catch {
            throw FlyChordProgressStoreError.fileOperation(error.localizedDescription)
        }
    }

    private static func load(from url: URL,
                             fileManager: FileManager) throws -> PersistedFile {
        guard fileManager.fileExists(atPath: url.path) else {
            return PersistedFile(version: 1,
                                 schemaID: FlyChordLearningIdentity.schemaID,
                                 items: [:],
                                 updatedAt: 0)
        }
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0,
                  size <= maximumFileBytes else {
                throw FlyChordProgressStoreError.invalidProgressFile
            }
            let decoded = try JSONDecoder().decode(PersistedFile.self,
                                                   from: Data(contentsOf: url))
            guard validate(decoded) else {
                throw FlyChordProgressStoreError.invalidProgressFile
            }
            return decoded
        } catch let error as FlyChordProgressStoreError {
            throw error
        } catch {
            throw FlyChordProgressStoreError.invalidProgressFile
        }
    }

    private static func validate(_ value: PersistedFile) -> Bool {
        value.version == 1
            && value.schemaID == FlyChordLearningIdentity.schemaID
            && value.updatedAt.isFinite
            && value.items.count <= maximumItems
            && value.items.allSatisfy { id, item in
                validMappingID(id)
                    && item.attempts >= 0
                    && item.correctAttempts >= 0
                    && item.correctAttempts <= item.attempts
                    && item.currentStreak >= 0
                    && item.currentStreak <= item.correctAttempts
                    && item.bestStreak >= item.currentStreak
                    && item.bestStreak <= item.correctAttempts
                    && item.updatedAt.isFinite
            }
    }

    private static func validMappingID(_ id: String) -> Bool {
        let prefix = "\(FlyChordLearningIdentity.schemaID).rule."
        guard id.hasPrefix(prefix), id.count == prefix.count + 16 else { return false }
        return id.dropFirst(prefix.count).allSatisfy { $0.isHexDigit }
    }

    private static func saturatingIncrement(_ value: Int) -> Int {
        value == Int.max ? value : value + 1
    }

    private func makeSnapshot(_ value: PersistedFile) -> FlyChordProgressSnapshot {
        FlyChordProgressSnapshot(
            schemaID: value.schemaID,
            items: value.items.mapValues {
                FlyChordItemProgress(attempts: $0.attempts,
                                     correctAttempts: $0.correctAttempts,
                                     currentStreak: $0.currentStreak,
                                     bestStreak: $0.bestStreak,
                                     updatedAt: $0.updatedAt)
            },
            updatedAt: value.updatedAt
        )
    }
}
