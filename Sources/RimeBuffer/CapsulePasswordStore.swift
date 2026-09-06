import CryptoKit
import Darwin
import Foundation

/// The sensitive half of a Capsule password entry: one free-form Markdown
/// body. Entries hold whatever the secret actually is — an API key, a
/// username and password pair, a recovery phrase, connection details — so a
/// fixed field set only ever fit some of them. The title stays in plaintext
/// for retrieval; everything here is encrypted.
struct CapsulePasswordSecret: Codable, Equatable {
    let body: String
}

/// The pre-v2 field set, retained only so existing records still open. Its
/// values are folded into a Markdown body on read, and the entry is stored in
/// the new shape the next time it is saved.
private struct CapsulePasswordLegacySecret: Codable {
    let url: String?
    let app: String?
    let username: String?
    let password: String
    let previousPasswords: [String]

    var markdownBody: String {
        var lines: [String] = []
        if let url, !url.isEmpty { lines.append("- 网址：\(url)") }
        if let app, !app.isEmpty { lines.append("- App：\(app)") }
        if let username, !username.isEmpty {
            lines.append("- 用户名：\(username)")
        }
        lines.append("- 密码：\(password)")
        for (index, previous) in previousPasswords.enumerated()
        where !previous.isEmpty {
            lines.append("- 曾用密码 \(index + 1)：\(previous)")
        }
        return lines.joined(separator: "\n")
    }
}

struct CapsulePasswordWriteRequest: Codable, Equatable {
    let id: UUID?
    let title: String
    let body: String

    init(id: UUID? = nil, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// Accepts the retired field set so a stored JSON payload or an older
    /// caller still imports, folded into the same Markdown body.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        if let body = try container.decodeIfPresent(String.self, forKey: .body) {
            self.body = body
            return
        }
        let legacy = CapsulePasswordLegacySecret(
            url: try container.decodeIfPresent(String.self, forKey: .url),
            app: try container.decodeIfPresent(String.self, forKey: .app),
            username: try container.decodeIfPresent(String.self,
                                                    forKey: .username),
            password: try container.decode(String.self, forKey: .password),
            previousPasswords: try container.decodeIfPresent(
                [String].self,
                forKey: .previousPasswords
            ) ?? []
        )
        body = legacy.markdownBody
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, url, app, username, password, previousPasswords
    }
}

struct CapsulePasswordSummary: Equatable, Identifiable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let fileURL: URL

    /// Fixed-width masking deliberately does not reveal password length.
    var maskedPassword: String { "••••••••" }
}

struct CapsulePasswordRecord: Equatable {
    let summary: CapsulePasswordSummary
    let secret: CapsulePasswordSecret
}

struct CapsulePasswordImportResult: Equatable {
    let received: Int
    let uniqueInput: Int
    let inserted: Int
    let skippedExisting: Int
    let skippedInputDuplicates: Int
}

private struct CapsulePasswordIdentity: Hashable {
    let title: String
    let body: String

    init(_ request: CapsulePasswordWriteRequest) {
        title = request.title
        body = request.body
    }

    init(_ record: CapsulePasswordRecord) {
        title = record.summary.title
        body = record.secret.body
    }
}

enum CapsulePasswordStoreError: LocalizedError, Equatable {
    case unsafeStorage(String)
    case invalidRequest(String)
    case malformedDocument(String)
    case missingMasterKey
    case invalidMasterKey
    case recordNotFound
    case revisionConflict
    case encryptionFailed
    case decryptionFailed
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case let .unsafeStorage(path):
            return "Capsule 本地目录不安全：\(path)"
        case let .invalidRequest(message):
            return "密码记录无效：\(message)"
        case let .malformedDocument(path):
            return "Capsule 密码文档格式无效：\(path)"
        case .missingMasterKey:
            return "Capsule 主密钥缺失；为避免覆盖已有密码，已停止操作"
        case .invalidMasterKey:
            return "Capsule 主密钥格式无效"
        case .recordNotFound:
            return "未找到 Capsule 密码记录"
        case .revisionConflict:
            return "Capsule 密码记录已被其他窗口更新"
        case .encryptionFailed:
            return "Capsule 密码加密失败"
        case .decryptionFailed:
            return "Capsule 密码解密失败，文档可能已损坏或被修改"
        case let .fileOperation(message):
            return "Capsule 本地文件操作失败：\(message)"
        }
    }
}

/// Local-only encrypted Markdown password store.
///
/// The Markdown document is the source of truth. Only the title and document
/// identity remain visible to Obsidian and local search; every credential
/// field is authenticated and encrypted with ChaCha20-Poly1305. The random
/// master key lives beside (not inside) the Markdown library under the same
/// private RIMES user directory. This matches the current ad-hoc development
/// threat model used by the other local credentials: 0700 directories and
/// 0600 files, with no repository, UserDefaults, log, or pasteboard copy.
final class CapsulePasswordStore {
    static let shared = CapsulePasswordStore()

    static let maximumDocumentBytes = 1 * 1_024 * 1_024
    static let maximumImportBytes = 8 * 1_024 * 1_024
    static let maximumRecordCount = 20_000
    static let maximumTitleCharacters = 256
    static let maximumFieldCharacters = 16_384
    static let maximumBodyCharacters = 65_536
    static let maximumPreviousPasswordCount = 100

    let rootURL: URL
    let passwordDirectoryURL: URL
    let masterKeyURL: URL

    private let fileManager: FileManager
    private let now: () -> Date

    init(rootURL: URL = CapsulePasswordStore.defaultRootURL(),
         fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init) {
        self.rootURL = rootURL.standardizedFileURL
        passwordDirectoryURL = self.rootURL.appendingPathComponent(
            "passwords",
            isDirectory: true
        )
        masterKeyURL = self.rootURL.appendingPathComponent("master-key")
        self.fileManager = fileManager
        self.now = now
    }

    static func defaultRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let userRoot: URL
        if let override = environment["RIMEBUFFER_USER_DIR"], !override.isEmpty {
            userRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            userRoot = homeDirectory.appendingPathComponent(
                "Library/RimeBuffer",
                isDirectory: true
            )
        }
        return userRoot.appendingPathComponent("capsule", isDirectory: true)
    }

    func listSummaries() throws -> [CapsulePasswordSummary] {
        try withStoreLock {
            try summariesWithoutLock()
        }
    }

    func search(_ query: String, limit: Int = 5) throws
        -> [CapsulePasswordSummary] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return [] }
        return try listSummaries().lazy.filter { summary in
            let title = summary.title.lowercased()
            return terms.allSatisfy(title.contains)
        }
        .prefix(min(max(limit, 1), 20))
        .map { $0 }
    }

    @discardableResult
    func put(_ request: CapsulePasswordWriteRequest,
             expectedRevision: String? = nil) throws
        -> CapsulePasswordSummary {
        let normalized = try Self.validate(request)
        return try withStoreLock {
            try prepareDirectoriesWithoutLock()
            return try writeRecordWithoutLock(
                normalized,
                expectedRevision: expectedRevision
            )
        }
    }

    /// Imports a batch while holding the store's process-wide flock for the
    /// complete read/deduplicate/write transaction. This makes repeated and
    /// concurrent CLI imports converge on one encrypted record per identity.
    func importUnique(_ requests: [CapsulePasswordWriteRequest]) throws
        -> CapsulePasswordImportResult {
        guard requests.count <= Self.maximumRecordCount,
              requests.allSatisfy({ $0.id == nil }) else {
            throw CapsulePasswordStoreError.invalidRequest(
                "导入数量超过上限或包含记录 ID"
            )
        }
        let normalized = try requests.map(Self.validate)
        return try withStoreLock {
            try prepareDirectoriesWithoutLock()
            let summaries = try summariesWithoutLock()
            var existing = Set<CapsulePasswordIdentity>()
            for summary in summaries {
                existing.insert(CapsulePasswordIdentity(
                    try recordWithoutLock(id: summary.id)
                ))
            }
            var uniqueInput = Set<CapsulePasswordIdentity>()
            var inserted = 0
            var skippedExisting = 0
            var skippedInputDuplicates = 0
            var recordCount = summaries.count
            for request in normalized {
                let identity = CapsulePasswordIdentity(request)
                guard uniqueInput.insert(identity).inserted else {
                    skippedInputDuplicates += 1
                    continue
                }
                guard !existing.contains(identity) else {
                    skippedExisting += 1
                    continue
                }
                guard recordCount < Self.maximumRecordCount else {
                    throw CapsulePasswordStoreError.invalidRequest(
                        "记录数量超过上限"
                    )
                }
                _ = try writeRecordWithoutLock(
                    request,
                    knownRecordCount: recordCount
                )
                existing.insert(identity)
                inserted += 1
                recordCount += 1
            }
            return CapsulePasswordImportResult(
                received: normalized.count,
                uniqueInput: uniqueInput.count,
                inserted: inserted,
                skippedExisting: skippedExisting,
                skippedInputDuplicates: skippedInputDuplicates
            )
        }
    }

    func record(id: UUID) throws -> CapsulePasswordRecord {
        try withStoreLock {
            try recordWithoutLock(id: id)
        }
    }

    func remove(id: UUID, expectedRevision: String? = nil) throws {
        try withStoreLock {
            let url = passwordDirectoryURL
                .appendingPathComponent("\(id.uuidString.lowercased()).md")
            guard fileManager.fileExists(atPath: url.path) else {
                throw CapsulePasswordStoreError.recordNotFound
            }
            let values = try safeValues(for: url)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CapsulePasswordStoreError.unsafeStorage(url.path)
            }
            if let expectedRevision {
                guard try fileRevisionWithoutLock(url) == expectedRevision else {
                    throw CapsulePasswordStoreError.revisionConflict
                }
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw CapsulePasswordStoreError.fileOperation(
                    error.localizedDescription
                )
            }
        }
    }

    private func writeRecordWithoutLock(
        _ normalized: CapsulePasswordWriteRequest,
        expectedRevision: String? = nil,
        knownRecordCount: Int? = nil
    ) throws -> CapsulePasswordSummary {
        let id = normalized.id ?? UUID()
        let hasExistingRecords: Bool
        if normalized.id == nil {
            let recordCount = try knownRecordCount ?? summariesWithoutLock().count
            guard recordCount < Self.maximumRecordCount else {
                throw CapsulePasswordStoreError.invalidRequest("记录数量超过上限")
            }
            hasExistingRecords = recordCount > 0
        } else {
            let destination = passwordDirectoryURL.appendingPathComponent(
                "\(id.uuidString.lowercased()).md"
            )
            guard fileManager.fileExists(atPath: destination.path) else {
                throw CapsulePasswordStoreError.recordNotFound
            }
            let values = try safeValues(for: destination)
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CapsulePasswordStoreError.unsafeStorage(destination.path)
            }
            hasExistingRecords = true
        }

        let updatedAt = now()
        let secret = CapsulePasswordSecret(body: normalized.body)
        let key = try loadOrCreateMasterKeyWithoutLock(
            hasExistingRecords: hasExistingRecords
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let secretData = try? encoder.encode(secret),
              secretData.count <= Self.maximumDocumentBytes else {
            throw CapsulePasswordStoreError.encryptionFailed
        }
        let aad = Self.authenticatedMetadata(id: id, title: normalized.title)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(
                secretData,
                using: key,
                authenticating: aad
            )
        } catch {
            throw CapsulePasswordStoreError.encryptionFailed
        }
        let document = Self.markdownDocument(
            id: id,
            title: normalized.title,
            updatedAt: updatedAt,
            ciphertext: sealed.combined.base64EncodedString()
        )
        let data = Data(document.utf8)
        guard data.count <= Self.maximumDocumentBytes else {
            throw CapsulePasswordStoreError.invalidRequest("密码文档超过大小上限")
        }
        let destination = passwordDirectoryURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).md"
        )
        if let expectedRevision {
            guard try fileRevisionWithoutLock(destination) == expectedRevision else {
                throw CapsulePasswordStoreError.revisionConflict
            }
        }
        try writePrivateFileWithoutLock(data, to: destination)
        return CapsulePasswordSummary(
            id: id,
            title: normalized.title,
            updatedAt: updatedAt,
            fileURL: destination
        )
    }

    private func recordWithoutLock(id: UUID) throws -> CapsulePasswordRecord {
        let url = passwordDirectoryURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).md"
        )
        let parsed = try parseDocumentWithoutLock(url)
        guard parsed.id == id else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        let key = try loadMasterKeyWithoutLock()
        guard let combined = Data(base64Encoded: parsed.ciphertext) else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        let secretData: Data
        do {
            let sealed = try ChaChaPoly.SealedBox(combined: combined)
            secretData = try ChaChaPoly.open(
                sealed,
                using: key,
                authenticating: Self.authenticatedMetadata(
                    id: parsed.id,
                    title: parsed.title
                )
            )
        } catch {
            throw CapsulePasswordStoreError.decryptionFailed
        }
        if let legacy = try? JSONDecoder().decode(
            CapsulePasswordLegacySecret.self,
            from: secretData
        ) {
            return CapsulePasswordRecord(
                summary: CapsulePasswordSummary(
                    id: parsed.id,
                    title: parsed.title,
                    updatedAt: parsed.updatedAt,
                    fileURL: url
                ),
                secret: CapsulePasswordSecret(body: legacy.markdownBody)
            )
        }
        guard let secret = try? JSONDecoder().decode(
            CapsulePasswordSecret.self,
            from: secretData
        ) else {
            throw CapsulePasswordStoreError.decryptionFailed
        }
        return CapsulePasswordRecord(
            summary: CapsulePasswordSummary(
                id: parsed.id,
                title: parsed.title,
                updatedAt: parsed.updatedAt,
                fileURL: url
            ),
            secret: secret
        )
    }

    private func fileRevisionWithoutLock(_ url: URL) throws -> String {
        let values = try safeValues(for: url)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= Self.maximumDocumentBytes else {
            throw CapsulePasswordStoreError.unsafeStorage(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private struct ParsedDocument {
        let id: UUID
        let title: String
        let updatedAt: Date
        let ciphertext: String
    }

    private func summariesWithoutLock() throws -> [CapsulePasswordSummary] {
        guard fileManager.fileExists(atPath: passwordDirectoryURL.path) else {
            return []
        }
        try requireSafeDirectory(passwordDirectoryURL)
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: passwordDirectoryURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
        guard urls.count <= Self.maximumRecordCount else {
            throw CapsulePasswordStoreError.unsafeStorage(
                passwordDirectoryURL.path
            )
        }
        return try urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let parsed = try parseDocumentWithoutLock(url)
            guard url.deletingPathExtension().lastPathComponent
                    == parsed.id.uuidString.lowercased() else {
                throw CapsulePasswordStoreError.malformedDocument(url.path)
            }
            return CapsulePasswordSummary(
                id: parsed.id,
                title: parsed.title,
                updatedAt: parsed.updatedAt,
                fileURL: url
            )
        }
        .sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            if order == .orderedSame {
                return $0.id.uuidString < $1.id.uuidString
            }
            return order == .orderedAscending
        }
    }

    private func parseDocumentWithoutLock(_ url: URL) throws
        -> ParsedDocument {
        guard url.deletingLastPathComponent().standardizedFileURL
                == passwordDirectoryURL.standardizedFileURL else {
            throw CapsulePasswordStoreError.unsafeStorage(url.path)
        }
        let values = try safeValues(for: url)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumDocumentBytes else {
            throw CapsulePasswordStoreError.unsafeStorage(url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
        guard data.count <= Self.maximumDocumentBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 10,
              lines[0] == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else {
                throw CapsulePasswordStoreError.malformedDocument(url.path)
            }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil else {
                throw CapsulePasswordStoreError.malformedDocument(url.path)
            }
            fields[key] = value
        }
        guard fields["capsule"] == "password",
              fields["version"] == "1" || fields["version"] == "2",
              let idRaw = fields["id"],
              let titleRaw = fields["title"],
              let updatedRaw = fields["updated_at"],
              let id = UUID(uuidString: try Self.decodeJSONScalar(idRaw)),
              let title = try? Self.decodeJSONScalar(titleRaw),
              !title.isEmpty,
              title.count <= Self.maximumTitleCharacters,
              let updatedString = try? Self.decodeJSONScalar(updatedRaw),
              let updatedAt = Self.iso8601.date(from: updatedString) else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        let body = Array(lines[(end + 1)...])
        guard let fenceStart = body.firstIndex(of: "```capsule-password"),
              let fenceEnd = body[(fenceStart + 1)...]
                .firstIndex(of: "```"),
              fenceEnd == fenceStart + 2 else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        let ciphertext = body[fenceStart + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ciphertext.isEmpty,
              ciphertext.utf8.count <= Self.maximumDocumentBytes else {
            throw CapsulePasswordStoreError.malformedDocument(url.path)
        }
        return ParsedDocument(
            id: id,
            title: title,
            updatedAt: updatedAt,
            ciphertext: ciphertext
        )
    }

    private func loadOrCreateMasterKeyWithoutLock(
        hasExistingRecords: Bool
    ) throws -> SymmetricKey {
        if fileManager.fileExists(atPath: masterKeyURL.path) {
            return try loadMasterKeyWithoutLock()
        }
        guard !hasExistingRecords else {
            throw CapsulePasswordStoreError.missingMasterKey
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                == errSecSuccess else {
            throw CapsulePasswordStoreError.encryptionFailed
        }
        let data = Data(bytes)
        try writePrivateFileWithoutLock(data, to: masterKeyURL)
        return SymmetricKey(data: data)
    }

    private func loadMasterKeyWithoutLock() throws -> SymmetricKey {
        guard fileManager.fileExists(atPath: masterKeyURL.path) else {
            throw CapsulePasswordStoreError.missingMasterKey
        }
        let values = try safeValues(for: masterKeyURL)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == 32 else {
            throw CapsulePasswordStoreError.invalidMasterKey
        }
        let data: Data
        do {
            data = try Data(contentsOf: masterKeyURL)
        } catch {
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
        guard data.count == 32 else {
            throw CapsulePasswordStoreError.invalidMasterKey
        }
        return SymmetricKey(data: data)
    }

    private func prepareDirectoriesWithoutLock() throws {
        try preparePrivateDirectory(rootURL)
        try preparePrivateDirectory(passwordDirectoryURL)
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try requireSafeDirectory(url)
        } else {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CapsulePasswordStoreError.fileOperation(
                    error.localizedDescription
                )
            }
            try requireSafeDirectory(url)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw CapsulePasswordStoreError.fileOperation(
                "无法收紧目录权限"
            )
        }
    }

    private func requireSafeDirectory(_ url: URL) throws {
        let values = try safeValues(for: url)
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw CapsulePasswordStoreError.unsafeStorage(url.path)
        }
    }

    private func safeValues(for url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
        } catch {
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
    }

    private func writePrivateFileWithoutLock(_ data: Data, to url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL
                == rootURL.standardizedFileURL
                || url.deletingLastPathComponent().standardizedFileURL
                    == passwordDirectoryURL.standardizedFileURL else {
            throw CapsulePasswordStoreError.unsafeStorage(url.path)
        }
        let directory = url.deletingLastPathComponent()
        try preparePrivateDirectory(directory)
        let staged = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: staged, options: [.atomic])
            guard chmod(staged.path, 0o600) == 0 else {
                throw CapsulePasswordStoreError.fileOperation(
                    "无法收紧文件权限"
                )
            }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: staged, to: url)
            }
            guard chmod(url.path, 0o600) == 0 else {
                throw CapsulePasswordStoreError.fileOperation(
                    "无法收紧文件权限"
                )
            }
        } catch let error as CapsulePasswordStoreError {
            try? fileManager.removeItem(at: staged)
            throw error
        } catch {
            try? fileManager.removeItem(at: staged)
            throw CapsulePasswordStoreError.fileOperation(
                error.localizedDescription
            )
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try preparePrivateDirectory(rootURL)
        let lockURL = rootURL.appendingPathComponent(".lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CapsulePasswordStoreError.fileOperation("无法打开存储锁")
        }
        defer { close(descriptor) }
        _ = fchmod(descriptor, mode_t(0o600))
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw CapsulePasswordStoreError.fileOperation("无法取得存储锁")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validate(_ request: CapsulePasswordWriteRequest) throws
        -> CapsulePasswordWriteRequest {
        let title = request.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty,
              title.count <= maximumTitleCharacters,
              !title.contains("\0") else {
            throw CapsulePasswordStoreError.invalidRequest("标题为空或过长")
        }
        // The body keeps its own leading/trailing shape: Markdown structure is
        // the user's, and trimming it would quietly rewrite their record.
        guard !request.body.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              request.body.count <= maximumBodyCharacters,
              !request.body.contains("\0") else {
            throw CapsulePasswordStoreError.invalidRequest("敏感信息为空或过长")
        }
        return CapsulePasswordWriteRequest(
            id: request.id,
            title: title,
            body: request.body
        )
    }

    private static func markdownDocument(id: UUID,
                                         title: String,
                                         updatedAt: Date,
                                         ciphertext: String) -> String {
        """
        ---
        capsule: password
        version: 2
        id: \(encodeJSONScalar(id.uuidString.lowercased()))
        title: \(encodeJSONScalar(title))
        updated_at: \(encodeJSONScalar(iso8601.string(from: updatedAt)))
        ---

        <!-- RIMES Capsule encrypted password record. Do not edit the encrypted block manually. -->
        ```capsule-password
        \(ciphertext)
        ```
        """
    }

    private static func authenticatedMetadata(id: UUID, title: String) -> Data {
        Data("capsule-password-v1\n\(id.uuidString.lowercased())\n\(title)".utf8)
    }

    private static func encodeJSONScalar(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func decodeJSONScalar(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            throw CapsulePasswordStoreError.malformedDocument("front matter")
        }
        return decoded
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
