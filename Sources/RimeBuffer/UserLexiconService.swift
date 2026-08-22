import Foundation

enum UserLexiconKind: String, CaseIterable, Codable, Sendable {
    case chinese
    case wubi86
    case english

    var dictionaryName: String {
        switch self {
        case .chinese: return "rime_ice"
        case .wubi86: return "wubi86"
        case .english: return "english"
        }
    }

    var displayName: String {
        switch self {
        case .chinese: return "中文学习词库"
        case .wubi86: return "五笔86学习词库"
        case .english: return "英文学习词库"
        }
    }

    var suggestedFileName: String {
        "\(ProductIdentity.displayName)-\(rawValue)-learning.tsv"
    }
}

struct UserLexiconStatus: Equatable, Sendable {
    let kind: UserLexiconKind
    /// librime's iterator reports whether the userdb exists, not whether it
    /// already contains learned rows. Keep that distinction explicit so an
    /// empty database is never presented as confirmed learning data.
    let hasLearningDatabase: Bool
}

struct UserLexiconTransferResult: Equatable, Sendable {
    let kind: UserLexiconKind
    let entryCount: Int
    let fileURL: URL
    /// Old `rime_dict_manager -e` exports have no db metadata. They remain
    /// importable after the user explicitly chooses a target dictionary, while
    /// RIMES exports are self-describing and can reject a wrong target.
    let sourceWasSelfDescribing: Bool
}

enum UserLexiconServiceError: LocalizedError, Equatable {
    case engineUnavailable
    case sourceMissing
    case sourceIsSymbolicLink
    case sourceIsNotRegularFile
    case sourceTooLarge
    case invalidUTF8
    case containsNUL
    case malformedLine(Int)
    case noLearningEntries
    case snapshotMissingDictionary
    case wrongDictionary(expected: String, actual: String)
    case exportFailed
    case importFailed
    case destinationIsSymbolicLink
    case destinationIsNotRegularFile
    case fileOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Rime 引擎尚未就绪。"
        case .sourceMissing:
            return "没有找到要导入的学习词库文件。"
        case .sourceIsSymbolicLink:
            return "为避免路径被替换，不能从符号链接导入学习词库。"
        case .sourceIsNotRegularFile:
            return "学习词库必须是普通文件。"
        case .sourceTooLarge:
            return "学习词库文件超过 64 MiB 安全上限。"
        case .invalidUTF8:
            return "学习词库不是 UTF-8 文本。"
        case .containsNUL:
            return "学习词库含有无效的 NUL 字节。"
        case .malformedLine(let line):
            return "学习词库第 \(line) 行不是 Rime 用户词典 TSV。"
        case .noLearningEntries:
            return "学习词库中没有可处理的 Rime 学习记录。"
        case .snapshotMissingDictionary:
            return "Rime 学习快照缺少 db_name，无法安全判断目标词库。"
        case .wrongDictionary(let expected, let actual):
            return "文件属于 \(actual)，不能导入到 \(expected)。"
        case .exportFailed:
            return "Rime 未能导出学习词库。"
        case .importFailed:
            return "Rime 未能导入学习词库。"
        case .destinationIsSymbolicLink:
            return "为避免覆盖错误位置，不能导出到符号链接。"
        case .destinationIsNotRegularFile:
            return "导出目标必须是普通文件。"
        case .fileOperationFailed(let detail):
            return "学习词库文件操作失败：\(detail)"
        }
    }
}

protocol UserLexiconEngine: AnyObject {
    var isHealthy: Bool { get }
    func hasUserDictionary(named name: String) -> Bool
    func exportUserDictionary(named name: String, to fileURL: URL) -> Int
    func importUserDictionary(named name: String, from fileURL: URL) -> Int
    func restoreUserDictionarySnapshot(from fileURL: URL) -> Bool
}

extension RimeEngine: UserLexiconEngine {}

/// Real Rime user-learning import/export. Base dictionaries bundled under
/// SharedSupport remain app-managed and immutable here; this service operates
/// only on portable learned entries through librime's official levers API.
final class UserLexiconService {
    static let shared = UserLexiconService(engine: rimeEngine)

    private static let maxFileBytes = 64 * 1_024 * 1_024
    private static let maxLineBytes = 64 * 1_024
    private static let formatVersion = "1"

    private let engine: UserLexiconEngine
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(engine: UserLexiconEngine,
         fileManager: FileManager = .default,
         temporaryDirectory: URL? = nil) {
        self.engine = engine
        self.fileManager = fileManager
        let userDirectory = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        self.temporaryDirectory = temporaryDirectory
            ?? userDirectory.appendingPathComponent("tmp/lexicon", isDirectory: true)
    }

    func status(for kind: UserLexiconKind) -> UserLexiconStatus {
        UserLexiconStatus(kind: kind,
                          hasLearningDatabase: engine.isHealthy
                            && engine.hasUserDictionary(named: kind.dictionaryName))
    }

    /// Produces a self-describing, portable TSV containing only learned
    /// entries. No LevelDB files, schemas, preedit text, or typing history are
    /// copied.
    func exportLearningData(_ kind: UserLexiconKind,
                            to destinationURL: URL) throws -> UserLexiconTransferResult {
        guard engine.isHealthy else { throw UserLexiconServiceError.engineUnavailable }
        try validateDestination(destinationURL)
        let tempURL = try makeTemporaryFileURL()
        defer { try? fileManager.removeItem(at: tempURL) }

        let exportedCount = engine.exportUserDictionary(named: kind.dictionaryName,
                                                        to: tempURL)
        guard exportedCount >= 0 else { throw UserLexiconServiceError.exportFailed }

        // Official exports are usually metadata-free. If a newer librime does
        // declare its database, still reject an impossible cross-dictionary
        // response instead of annotating a mismatched payload as this kind.
        let exported = try validatedContents(of: tempURL, expectedKind: kind)
        guard exported.entryCount == exportedCount || exportedCount == 0 else {
            throw UserLexiconServiceError.exportFailed
        }
        let annotated = Self.annotate(exported.text, kind: kind)
        try writeAtomically(Data(annotated.utf8), to: destinationURL)
        return UserLexiconTransferResult(kind: kind,
                                         entryCount: exported.entryCount,
                                         fileURL: destinationURL,
                                         sourceWasSelfDescribing: true)
    }

    /// Imports through Rime's UserDbImporter, which merges learning weights;
    /// it never replaces the live LevelDB. RIMES self-describing exports reject
    /// any cross-dictionary mismatch. Legacy official TSV exports without
    /// metadata are accepted only into the target the user explicitly chose.
    func importLearningData(_ kind: UserLexiconKind,
                            from sourceURL: URL) throws -> UserLexiconTransferResult {
        guard engine.isHealthy else { throw UserLexiconServiceError.engineUnavailable }
        let validated = try validatedContents(of: sourceURL, expectedKind: kind)

        // Pass a private, immutable copy to librime so a user-selected file
        // cannot be swapped between validation and import.
        let tempURL = try makeTemporaryFileURL()
        defer { try? fileManager.removeItem(at: tempURL) }
        do {
            try Data(validated.text.utf8).write(to: tempURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: tempURL.path)
        } catch {
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }

        let importedCount: Int
        switch validated.format {
        case .portableExport:
            importedCount = engine.importUserDictionary(named: kind.dictionaryName,
                                                        from: tempURL)
            guard importedCount >= 0 else { throw UserLexiconServiceError.importFailed }
        case .losslessSnapshot:
            guard validated.declaredDictionary != nil else {
                throw UserLexiconServiceError.snapshotMissingDictionary
            }
            guard engine.restoreUserDictionarySnapshot(from: tempURL) else {
                throw UserLexiconServiceError.importFailed
            }
            importedCount = validated.entryCount
        }
        return UserLexiconTransferResult(kind: kind,
                                         entryCount: importedCount,
                                         fileURL: sourceURL,
                                         sourceWasSelfDescribing: validated.declaredDictionary != nil)
    }

    // MARK: Validation

    private struct ValidatedContents {
        let text: String
        let entryCount: Int
        let declaredDictionary: String?
        let format: PayloadFormat
    }

    private enum PayloadFormat: Equatable {
        case portableExport
        case losslessSnapshot
    }

    private func validatedContents(of url: URL,
                                   expectedKind: UserLexiconKind?) throws -> ValidatedContents {
        guard fileManager.fileExists(atPath: url.path) else {
            throw UserLexiconServiceError.sourceMissing
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
        } catch {
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }
        if values.isSymbolicLink == true { throw UserLexiconServiceError.sourceIsSymbolicLink }
        guard values.isRegularFile == true else {
            throw UserLexiconServiceError.sourceIsNotRegularFile
        }
        guard (values.fileSize ?? 0) <= Self.maxFileBytes else {
            throw UserLexiconServiceError.sourceTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }
        guard data.count <= Self.maxFileBytes else {
            throw UserLexiconServiceError.sourceTooLarge
        }
        guard !data.contains(0) else { throw UserLexiconServiceError.containsNUL }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UserLexiconServiceError.invalidUTF8
        }

        var entryCount = 0
        var declaredDictionary: String?
        var detectedFormat: PayloadFormat?
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
        for (zeroBasedIndex, lineSlice) in lines.enumerated() {
            let line = String(lineSlice).trimmingCharacters(in: .init(charactersIn: "\r"))
            guard line.utf8.count <= Self.maxLineBytes else {
                throw UserLexiconServiceError.malformedLine(zeroBasedIndex + 1)
            }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if let value = Self.metadataValue(in: line, key: "db_name") {
                    if let declaredDictionary, declaredDictionary != value {
                        throw UserLexiconServiceError.malformedLine(zeroBasedIndex + 1)
                    }
                    declaredDictionary = value
                }
                continue
            }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  !columns[0].trimmingCharacters(in: .whitespaces).isEmpty,
                  !columns[1].isEmpty else {
                throw UserLexiconServiceError.malformedLine(zeroBasedIndex + 1)
            }
            let value = String(columns[2]).trimmingCharacters(in: .whitespaces)
            let lineFormat: PayloadFormat
            if let weight = Double(value), weight.isFinite, weight >= 0 {
                lineFormat = .portableExport
            } else if Self.isPackedUserDbValue(value) {
                lineFormat = .losslessSnapshot
            } else {
                throw UserLexiconServiceError.malformedLine(zeroBasedIndex + 1)
            }
            if let detectedFormat, detectedFormat != lineFormat {
                throw UserLexiconServiceError.malformedLine(zeroBasedIndex + 1)
            }
            detectedFormat = lineFormat
            entryCount += 1
        }
        guard entryCount > 0 else { throw UserLexiconServiceError.noLearningEntries }
        guard let detectedFormat else { throw UserLexiconServiceError.noLearningEntries }
        if let expectedKind,
           let declaredDictionary,
           declaredDictionary != expectedKind.dictionaryName {
            throw UserLexiconServiceError.wrongDictionary(
                expected: expectedKind.displayName,
                actual: declaredDictionary
            )
        }
        return ValidatedContents(text: text,
                                 entryCount: entryCount,
                                 declaredDictionary: declaredDictionary,
                                 format: detectedFormat)
    }

    private static func isPackedUserDbValue(_ value: String) -> Bool {
        var commit: Int?
        var weight: Double?
        var tick: UInt64?
        for field in value.split(separator: " ") {
            let pair = field.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return false }
            switch pair[0] {
            case "c":
                if let value = Int(pair[1]), value >= 0 { commit = value }
            case "d":
                if let value = Double(pair[1]), value.isFinite, value >= 0 {
                    weight = value
                }
            case "t": tick = UInt64(pair[1])
            default: continue
            }
        }
        return commit != nil && weight != nil && tick != nil
    }

    private static func metadataValue(in line: String, key: String) -> String? {
        let prefix = "#@/\(key)"
        guard line.hasPrefix(prefix) else { return nil }
        let suffix = line.dropFirst(prefix.count)
        guard suffix.first.map({ $0.isWhitespace }) == true else { return nil }
        let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func annotate(_ text: String, kind: UserLexiconKind) -> String {
        let header = [
            "# RimeBuffer portable learning dictionary",
            "#@/rimebuffer_format\t\(formatVersion)",
            "#@/db_name\t\(kind.dictionaryName)",
        ].joined(separator: "\n")
        return header + "\n" + text
    }

    private func validateDestination(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                throw UserLexiconServiceError.destinationIsSymbolicLink
            }
            if values.isRegularFile != true {
                throw UserLexiconServiceError.destinationIsNotRegularFile
            }
        } catch let error as UserLexiconServiceError {
            throw error
        } catch {
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }
    }

    private func makeTemporaryFileURL() throws -> URL {
        do {
            try fileManager.createDirectory(at: temporaryDirectory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700],
                                          ofItemAtPath: temporaryDirectory.path)
        } catch {
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }
        return temporaryDirectory.appendingPathComponent(".lexicon-\(UUID().uuidString).tsv")
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: staged, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: staged.path)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL,
                                                  withItemAt: staged,
                                                  backupItemName: nil,
                                                  options: [])
            } else {
                try fileManager.moveItem(at: staged, to: destinationURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: destinationURL.path)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw UserLexiconServiceError.fileOperationFailed(error.localizedDescription)
        }
    }
}
