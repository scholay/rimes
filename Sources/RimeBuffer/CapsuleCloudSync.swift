import AppKit
import CryptoKit
import Darwin
import Foundation

extension Notification.Name {
    static let capsuleCloudSyncStatusDidChange = Notification.Name(
        "CapsuleCloudSyncStatusDidChange"
    )
}

enum CapsuleCloudSyncPhase: String, Equatable {
    case unconfigured
    case unavailable
    case idle
    case syncing
    case synced
    case failed
}

struct CapsuleCloudSyncStatus: Equatable {
    let phase: CapsuleCloudSyncPhase
    let configured: Bool
    let folderName: String?
    let message: String
    let lastSyncedAt: Date?
    let conflictCount: Int
    let deferredCount: Int

    var isConfigured: Bool {
        configured
    }

    var isBusy: Bool { phase == .syncing }

    static let unconfigured = CapsuleCloudSyncStatus(
        phase: .unconfigured,
        configured: false,
        folderName: nil,
        message: "iCloud 未设置",
        lastSyncedAt: nil,
        conflictCount: 0,
        deferredCount: 0
    )
}

struct CapsuleCloudSyncResult: Equatable {
    let uploaded: Int
    let downloaded: Int
    let deleted: Int
    let conflicts: Int
    let deferred: Int
}

enum CapsuleCloudSyncError: LocalizedError {
    case invalidRoot(String)
    case unavailable(String)
    case mediaUnavailable(String)
    case unsafeItem(String)
    case malformedDocument(String)
    case conflict(String)
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRoot(message):
            return "iCloud 同步目录无效：\(message)"
        case let .unavailable(message):
            return "iCloud Drive 不可用：\(message)"
        case let .mediaUnavailable(message):
            return "媒体文件暂不可用：\(message)"
        case let .unsafeItem(path):
            return "iCloud 同步发现不安全文件：\(path)"
        case let .malformedDocument(path):
            return "iCloud Capsule 文档格式无效：\(path)"
        case let .conflict(message):
            return "iCloud 同步期间内容又发生变化：\(message)"
        case let .fileOperation(message):
            return "iCloud 同步文件操作失败：\(message)"
        }
    }
}

private struct CapsuleCloudLibraryMarker: Codable, Equatable {
    let format: String
    let version: Int
    let libraryID: UUID
}

private struct CapsuleCloudTombstone: Codable, Equatable {
    let version: Int
    let id: UUID
    let deletedAt: Date
    let deviceID: UUID
    let revision: String
}

private struct CapsuleCloudEntryState: Codable, Equatable {
    var localRevision: String?
    var cloudRevision: String?
    var tombstoneRevision: String?
    var localAssetFingerprint: String? = nil
    var localAssetPathHash: String? = nil
}

private struct CapsuleCloudDeletionConflict: Codable, Equatable {
    let version: Int
    let kind: String
    let id: UUID
    let deviceID: UUID
    let observedCloudRevision: String
    let observedAt: Date
}

private struct CapsuleCloudUnavailableMediaConflict: Codable, Equatable {
    let version: Int
    let kind: String
    let id: UUID
    let type: String
    let title: String
    let localRevision: String
    let localAssetPathHash: String
    let observedAt: Date
}

private struct CapsuleLocalAssetObservation: Equatable {
    let pathHash: String
    let fingerprint: String?

    var isAvailable: Bool { fingerprint != nil }
}

private struct CapsuleLocalLibraryMarker: Codable, Equatable {
    let version: Int
    let libraryID: UUID
}

private struct CapsuleCloudSyncState: Codable, Equatable {
    let version: Int
    let libraryID: UUID
    let localLibraryID: UUID
    let deviceID: UUID
    var entries: [String: CapsuleCloudEntryState]
}

private struct CapsuleCloudSyncConfiguration: Codable, Equatable {
    let version: Int
    let enabled: Bool
    let libraryID: UUID
    let folderPath: String
    let bookmark: Data
}

private struct CapsuleCloudParsedDocument {
    let id: UUID
    let type: CapsuleEntryKind
    let title: String
    let updatedAt: Date
    let content: String
    let assetName: String?
    let data: Data
    let revision: String
    let frontMatterLines: [String]
}

private struct CapsuleCloudLoadedTombstone {
    let value: CapsuleCloudTombstone
    let data: Data
    let dataRevision: String
}

private struct CapsuleCloudLayout {
    let rootURL: URL

    var markerDirectoryURL: URL {
        rootURL.appendingPathComponent(".rimes-capsule-sync", isDirectory: true)
    }

    var markerURL: URL {
        markerDirectoryURL.appendingPathComponent("library.json")
    }

    var versionDirectoryURL: URL {
        rootURL.appendingPathComponent("v1", isDirectory: true)
    }

    var entriesURL: URL {
        versionDirectoryURL.appendingPathComponent("entries", isDirectory: true)
    }

    var assetsURL: URL {
        versionDirectoryURL.appendingPathComponent("assets", isDirectory: true)
    }

    var tombstonesURL: URL {
        versionDirectoryURL.appendingPathComponent("tombstones", isDirectory: true)
    }

    var conflictsURL: URL {
        versionDirectoryURL.appendingPathComponent("conflicts", isDirectory: true)
    }

    func entryURL(id: UUID) -> URL {
        entriesURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).md"
        )
    }

    func tombstoneURL(id: UUID) -> URL {
        tombstonesURL.appendingPathComponent(
            "\(id.uuidString.lowercased()).json"
        )
    }
}

enum CapsuleCloudSyncRootValidator {
    static func validate(
        _ candidate: URL,
        localCapsuleRoot: URL,
        requireUbiquitous: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard candidate.isFileURL,
              NSString(string: candidate.path).isAbsolutePath else {
            throw CapsuleCloudSyncError.invalidRoot("必须选择本机文件 URL")
        }
        let standardized = candidate.standardizedFileURL
        var metadata = stat()
        guard standardized.path.withCString({
            lstat($0, &metadata)
        }) == 0,
        (metadata.st_mode & S_IFMT) == S_IFDIR,
        (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw CapsuleCloudSyncError.invalidRoot(
                "所选项目必须是现存的普通目录，不能是符号链接"
            )
        }
        let resolved = standardized.resolvingSymlinksInPath()
        let local = localCapsuleRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        guard !containsOrEquals(resolved, local),
              !containsOrEquals(local, resolved) else {
            throw CapsuleCloudSyncError.invalidRoot(
                "同步目录不能包含本机 Capsule，也不能位于其内部"
            )
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let disallowed = [
            URL(fileURLWithPath: "/", isDirectory: true),
            home,
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !disallowed.contains(where: { $0.path == resolved.path }) else {
            throw CapsuleCloudSyncError.invalidRoot(
                "请选择 iCloud Drive 内专门用于 Capsule 的子文件夹"
            )
        }
        guard fileManager.isWritableFile(atPath: resolved.path) else {
            throw CapsuleCloudSyncError.invalidRoot("所选目录不可写")
        }
        if requireUbiquitous {
            let values: URLResourceValues
            do {
                values = try resolved.resourceValues(forKeys: [
                    .isUbiquitousItemKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw CapsuleCloudSyncError.unavailable(
                    error.localizedDescription
                )
            }
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  values.isUbiquitousItem == true else {
                throw CapsuleCloudSyncError.invalidRoot(
                    "该文件夹未被 macOS 标记为 iCloud Drive 项目"
                )
            }
        }
        return resolved
    }

    static func containsOrEquals(_ ancestor: URL, _ child: URL) -> Bool {
        let ancestorPath = ancestor.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath == ancestorPath
            || childPath.hasPrefix(
                ancestorPath == "/" ? "/" : ancestorPath + "/"
            )
    }
}

private enum CapsuleCloudIO {
    static let maximumAssetBytes = 256 * 1_024 * 1_024

    static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func secureRead(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CapsuleCloudSyncError.unsafeItem(url.path)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw CapsuleCloudSyncError.unsafeItem(url.path)
        }
        var data = Data(count: Int(metadata.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CapsuleCloudSyncError.fileOperation(
                    "无法分配读取缓冲区"
                )
            }
            while offset < buffer.count {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw CapsuleCloudSyncError.fileOperation(
                        "读取 \(url.lastPathComponent) 不完整"
                    )
                }
                offset += count
            }
        }
        return data
    }

    static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw CapsuleCloudSyncError.unsafeItem(url.path)
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try requireDirectory(url)
            guard chmod(url.path, mode_t(0o700)) == 0 else {
                throw CapsuleCloudSyncError.fileOperation(
                    "无法收紧同步目录权限"
                )
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try requireDirectory(url)
            guard chmod(url.path, mode_t(0o700)) == 0 else {
                throw CapsuleCloudSyncError.fileOperation(
                    "无法收紧同步目录权限"
                )
            }
        } catch let error as CapsuleCloudSyncError {
            throw error
        } catch {
            throw CapsuleCloudSyncError.fileOperation(
                error.localizedDescription
            )
        }
    }

    static func coordinatedRead(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try secureRead(coordinatedURL, maximumBytes: maximumBytes)
            }
        }
        if let coordinationError {
            throw CapsuleCloudSyncError.fileOperation(
                coordinationError.localizedDescription
            )
        }
        guard let result else {
            throw CapsuleCloudSyncError.fileOperation(
                "iCloud 协调读取没有返回结果"
            )
        }
        return try result.get()
    }

    static func coordinatedWrite(
        _ data: Data,
        to destination: URL,
        expectedRevision: String?
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let exists = FileManager.default.fileExists(
                    atPath: coordinatedURL.path
                )
                if exists {
                    let current = try secureRead(
                        coordinatedURL,
                        maximumBytes: max(
                            CapsuleCloudIO.maximumAssetBytes,
                            CapsuleContentStore.maximumDocumentBytes
                        )
                    )
                    guard let expectedRevision,
                          revision(current) == expectedRevision else {
                        throw CapsuleCloudSyncError.conflict(
                            coordinatedURL.lastPathComponent
                        )
                    }
                } else if expectedRevision != nil {
                    throw CapsuleCloudSyncError.conflict(
                        coordinatedURL.lastPathComponent
                    )
                }
                try atomicWrite(data, to: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw CapsuleCloudSyncError.fileOperation(
                coordinationError.localizedDescription
            )
        }
        if let operationError { throw operationError }
    }

    static func coordinatedRemove(
        _ url: URL,
        expectedRevision: String
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let current = try secureRead(
                    coordinatedURL,
                    maximumBytes: max(
                        CapsuleCloudIO.maximumAssetBytes,
                        CapsuleContentStore.maximumDocumentBytes
                    )
                )
                guard revision(current) == expectedRevision else {
                    throw CapsuleCloudSyncError.conflict(
                        coordinatedURL.lastPathComponent
                    )
                }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                operationError = error
            }
        }
        if let coordinationError {
            throw CapsuleCloudSyncError.fileOperation(
                coordinationError.localizedDescription
            )
        }
        if let operationError { throw operationError }
    }

    static func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try requireDirectory(directory)
        let staged = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = open(
            staged.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw CapsuleCloudSyncError.fileOperation(
                "无法创建同步临时文件"
            )
        }
        var writeError: Error?
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    writeError = CapsuleCloudSyncError.fileOperation(
                        "同步临时文件写入不完整"
                    )
                    return
                }
                offset += count
            }
        }
        if writeError == nil, fsync(descriptor) != 0 {
            writeError = CapsuleCloudSyncError.fileOperation(
                "无法同步临时文件"
            )
        }
        close(descriptor)
        if let writeError {
            try? FileManager.default.removeItem(at: staged)
            throw writeError
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw CapsuleCloudSyncError.fileOperation(
                error.localizedDescription
            )
        }
    }

    static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private enum CapsuleCloudDocumentCodec {
    private static let allowedImageExtensions = Set([
        "png", "jpg", "jpeg", "heic", "webp", "tif", "tiff", "gif", "bmp",
    ])

    static func parse(_ data: Data, fileURL: URL)
        throws -> CapsuleCloudParsedDocument {
        guard !data.isEmpty,
              data.count <= CapsuleContentStore.maximumDocumentBytes,
              let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count >= 8,
              lines[0] == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
        }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else {
                throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
            }
            let key = String(line[..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil else {
                throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
            }
            fields[key] = value
        }
        guard fields["version"] == "1",
              let typeRaw = fields["capsule"],
              let type = CapsuleEntryKind(rawValue: typeRaw),
              type != .password,
              type != .skill,
              let idRaw = fields["id"],
              let id = UUID(uuidString: try decodeScalar(idRaw)),
              let titleRaw = fields["title"],
              let title = try? decodeScalar(titleRaw),
              !title.isEmpty,
              title.count <= CapsuleContentStore.maximumTitleCharacters,
              let updatedRaw = fields["updated_at"],
              let updatedText = try? decodeScalar(updatedRaw),
              let updatedAt = parseDate(updatedText) else {
            throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
        }
        guard fileURL.deletingPathExtension().lastPathComponent.lowercased()
                == id.uuidString.lowercased() else {
            throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
        }
        var bodyStart = end + 1
        if lines.indices.contains(bodyStart), lines[bodyStart].isEmpty {
            bodyStart += 1
        }
        let content = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n")
            : ""
        guard !content.isEmpty,
              content.count <= CapsuleContentStore.maximumContentCharacters,
              !content.contains("\0") else {
            throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
        }

        var assetName: String?
        if type == .image || type == .pdf {
            guard let assetRaw = fields["sync_asset"],
                  let decoded = try? decodeScalar(assetRaw),
                  isValidAssetName(decoded, for: type) else {
                throw CapsuleCloudSyncError.malformedDocument(fileURL.path)
            }
            assetName = decoded
        }
        return CapsuleCloudParsedDocument(
            id: id,
            type: type,
            title: title,
            updatedAt: updatedAt,
            content: content,
            assetName: assetName,
            data: data,
            revision: CapsuleCloudIO.revision(data),
            frontMatterLines: Array(lines[0...end])
        )
    }

    static func cloudData(
        from local: CapsuleContentSyncDocument,
        assetName: String?
    ) throws -> Data {
        guard local.record.summary.type == .image
                || local.record.summary.type == .pdf else {
            return local.data
        }
        guard let assetName,
              isValidAssetName(assetName, for: local.record.summary.type),
              let text = String(data: local.data, encoding: .utf8) else {
            throw CapsuleCloudSyncError.malformedDocument(
                local.record.summary.fileURL.path
            )
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            throw CapsuleCloudSyncError.malformedDocument(
                local.record.summary.fileURL.path
            )
        }
        var frontMatter = Array(lines[0..<end])
        var replacedAsset = false
        var hasOriginalName = false
        for index in frontMatter.indices {
            switch frontMatterKey(frontMatter[index]) {
            case "sync_asset":
                frontMatter[index] = "sync_asset: \(encodeScalar(assetName))"
                replacedAsset = true
            case "sync_original_name":
                hasOriginalName = true
            default:
                break
            }
        }
        if !replacedAsset {
            frontMatter.append(
                "sync_asset: \(encodeScalar(assetName))"
            )
        }
        let originalName = URL(
            fileURLWithPath: local.record.content
        ).lastPathComponent
        if !hasOriginalName {
            frontMatter.append(
                "sync_original_name: \(encodeScalar(originalName))"
            )
        }
        frontMatter.append("---")
        let body = "![[../assets/\(assetName)]]"
        return Data((frontMatter.joined(separator: "\n")
            + "\n\n" + body).utf8)
    }

    static func localData(
        from cloud: CapsuleCloudParsedDocument,
        materializedPath: String
    ) -> Data {
        Data((cloud.frontMatterLines.joined(separator: "\n")
            + "\n\n" + materializedPath).utf8)
    }

    static func assetHash(from assetName: String) -> String? {
        guard let dot = assetName.firstIndex(of: ".") else { return nil }
        let value = String(assetName[..<dot])
        guard value.count == 64,
              value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return value
    }

    static func equivalenceData(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            return nil
        }
        let comparable: [String] = lines.enumerated().compactMap {
            index, line -> String? in
            if index > 0, index < end,
               frontMatterKey(line) == "updated_at" {
                return nil
            }
            return line
        }
        return Data(comparable.joined(separator: "\n").utf8)
    }

    static func isValidAssetName(
        _ name: String,
        for type: CapsuleEntryKind
    ) -> Bool {
        guard name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/"),
              !name.contains("\\"),
              let hash = assetHash(from: name) else { return false }
        _ = hash
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch type {
        case .image:
            return allowedImageExtensions.contains(ext)
        case .pdf:
            return ext == "pdf"
        case .password, .skill, .note:
            return false
        }
    }

    private static func decodeScalar(_ value: String) throws -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                String.self,
                from: data
              ) else {
            throw CapsuleCloudSyncError.malformedDocument("front matter")
        }
        return decoded
    }

    private static func encodeScalar(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    private static func frontMatterKey(_ line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[..<colon]).trimmingCharacters(
            in: .whitespaces
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        if let date = fractionalISO8601.date(from: value) { return date }
        return plainISO8601.date(from: value)
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

final class CapsuleCloudSyncEngine {
    private let contentStore: CapsuleContentStore
    private let localRootURL: URL
    private let cloudLayout: CapsuleCloudLayout
    private let stateURL: URL
    private let libraryID: UUID
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        contentStore: CapsuleContentStore,
        localRootURL: URL,
        cloudRootURL: URL,
        stateURL: URL,
        libraryID: UUID,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.contentStore = contentStore
        self.localRootURL = localRootURL.standardizedFileURL
        cloudLayout = CapsuleCloudLayout(
            rootURL: cloudRootURL.standardizedFileURL
        )
        self.stateURL = stateURL.standardizedFileURL
        self.libraryID = libraryID
        self.now = now
        self.fileManager = fileManager
    }

    static func prepareLibrary(
        at rootURL: URL,
        preferredLibraryID: UUID? = nil
    ) throws -> UUID {
        let layout = CapsuleCloudLayout(rootURL: rootURL.standardizedFileURL)
        try CapsuleCloudIO.requireDirectory(layout.rootURL)
        let rootItems = try FileManager.default.contentsOfDirectory(
            at: layout.rootURL,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey,
            ],
            options: []
        )
        let meaningfulItems = rootItems.filter {
            ![".DS_Store", ".localized"].contains($0.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: layout.markerURL.path) {
            try CapsuleCloudIO.requireDirectory(
                layout.markerDirectoryURL
            )
            let data = try CapsuleCloudIO.coordinatedRead(
                layout.markerURL,
                maximumBytes: 64 * 1_024
            )
            let marker: CapsuleCloudLibraryMarker
            do {
                marker = try CapsuleCloudIO.decodeJSON(
                    CapsuleCloudLibraryMarker.self,
                    from: data
                )
            } catch {
                throw CapsuleCloudSyncError.invalidRoot(
                    "已有 RIMES 标记无法读取"
                )
            }
            guard marker.format == "rimes-capsule-sync",
                  marker.version == 1,
                  preferredLibraryID == nil
                    || marker.libraryID == preferredLibraryID else {
                throw CapsuleCloudSyncError.invalidRoot(
                    "已有目录属于另一个或不兼容的 Capsule 镜像"
                )
            }
            try prepareLayoutDirectories(layout)
            return marker.libraryID
        }
        guard meaningfulItems.isEmpty else {
            throw CapsuleCloudSyncError.invalidRoot(
                "请选择空文件夹，或选择已有的 RIMES Capsule 同步文件夹"
            )
        }
        let libraryID = preferredLibraryID ?? UUID()
        try CapsuleCloudIO.ensureDirectory(layout.markerDirectoryURL)
        let marker = CapsuleCloudLibraryMarker(
            format: "rimes-capsule-sync",
            version: 1,
            libraryID: libraryID
        )
        let data = try CapsuleCloudIO.jsonData(marker)
        try CapsuleCloudIO.coordinatedWrite(
            data,
            to: layout.markerURL,
            expectedRevision: nil
        )
        try prepareLayoutDirectories(layout)
        return libraryID
    }

    func synchronize() throws -> CapsuleCloudSyncResult {
        let preparedID = try Self.prepareLibrary(
            at: cloudLayout.rootURL,
            preferredLibraryID: libraryID
        )
        guard preparedID == libraryID else {
            throw CapsuleCloudSyncError.invalidRoot(
                "同步库标识不一致"
            )
        }
        var localDocuments = Dictionary(
            uniqueKeysWithValues: try contentStore
                .synchronizationDocuments()
                .map { ($0.record.summary.id, $0) }
        )
        var assetObservations = Dictionary(
            uniqueKeysWithValues: localDocuments.compactMap { id, document in
                localAssetObservation(document).map { (id, $0) }
            }
        )
        let localLibraryID = try loadOrCreateLocalLibraryID()
        var state = try loadState(localLibraryID: localLibraryID)
        var cloudDocuments = try loadCloudDocuments()
        var tombstones = try loadTombstones()
        let identifiers = Set(localDocuments.keys)
            .union(cloudDocuments.keys)
            .union(tombstones.keys)
            .union(state.entries.keys.compactMap(UUID.init(uuidString:)))
            .sorted { $0.uuidString < $1.uuidString }

        var uploaded = 0
        var downloaded = 0
        var deleted = 0
        var conflicts = 0
        var deferred = 0
        var deferredIDs = Set<UUID>()

        for id in identifiers {
            let key = id.uuidString.lowercased()
            let baseline = state.entries[key]
            let local = localDocuments[id]
            let cloud = cloudDocuments[id]
            var loadedTombstone = tombstones[id]
            let assetObservation = assetObservations[id]

            // Tombstones are permanent in v1. A missing cloud file can mean a
            // rebuilt sync root or an incomplete iCloud merge; a device that
            // already consumed the deletion must restore that knowledge before
            // any stale local/cloud copy can be uploaded or downloaded again.
            if loadedTombstone == nil,
               baseline?.tombstoneRevision != nil {
                let restored = try createTombstone(
                    id: id,
                    replacing: nil,
                    deviceID: state.deviceID
                )
                tombstones[id] = restored
                loadedTombstone = restored
            }

            if let loadedTombstone {
                if let local {
                    let isFreshAutomaticDefault = isFreshAutomaticDefault(
                        local,
                        baseline: baseline
                    )
                    let assetChanged = localAssetChanged(
                        assetObservation,
                        baseline: baseline
                    )
                    let localChanged = !isFreshAutomaticDefault
                        && (baseline?.localRevision == nil
                            || baseline?.localRevision != local.revision
                            || assetChanged)
                    if localChanged {
                        try archiveLocalConflict(
                            local,
                            id: id,
                            origin: "local-before-delete",
                            assetObservation: assetObservation
                        )
                        conflicts += 1
                    }
                    try contentStore.removeSynchronizedRecord(
                        id: id,
                        expectedRevision: local.revision
                    )
                    localDocuments[id] = nil
                    assetObservations[id] = nil
                    if let cloud {
                        try archive(
                            cloud.data,
                            id: id,
                            origin: "cloud-alongside-delete"
                        )
                        conflicts += 1
                        try CapsuleCloudIO.coordinatedRemove(
                            cloudLayout.entryURL(id: id),
                            expectedRevision: cloud.revision
                        )
                        cloudDocuments[id] = nil
                    }
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: nil,
                        cloudRevision: nil,
                        tombstoneRevision:
                            loadedTombstone.value.revision
                    )
                    deleted += 1
                } else {
                    if let cloud {
                        try archive(
                            cloud.data,
                            id: id,
                            origin: "cloud-alongside-delete"
                        )
                        conflicts += 1
                        try CapsuleCloudIO.coordinatedRemove(
                            cloudLayout.entryURL(id: id),
                            expectedRevision: cloud.revision
                        )
                        cloudDocuments[id] = nil
                    }
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: nil,
                        cloudRevision: nil,
                        tombstoneRevision:
                            loadedTombstone.value.revision
                    )
                }
                continue
            }

            switch (local, cloud) {
            case (nil, nil):
                if baseline?.localRevision != nil
                    || baseline?.cloudRevision != nil {
                    let tombstone = try createTombstone(
                        id: id,
                        replacing: nil,
                        deviceID: state.deviceID
                    )
                    tombstones[id] = tombstone
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: nil,
                        cloudRevision: nil,
                        tombstoneRevision: tombstone.value.revision
                    )
                    deleted += 1
                }

            case let (nil, cloud?):
                if baseline?.localRevision != nil {
                    let cloudChanged = baseline?.cloudRevision == nil
                        || baseline?.cloudRevision != cloud.revision
                    if cloudChanged {
                        do {
                            try ensureCloudMediaAvailable(cloud)
                        } catch CapsuleCloudSyncError.mediaUnavailable {
                            deferred += 1
                            deferredIDs.insert(id)
                            continue
                        }
                        try archiveDeletionIntent(
                            id: id,
                            deviceID: state.deviceID,
                            cloudRevision: cloud.revision
                        )
                        conflicts += 1
                        let applied = try download(
                            cloud,
                            replacing: nil
                        )
                        localDocuments[id] = applied
                        assetObservations[id] = localAssetObservation(applied)
                        state.entries[key] = CapsuleCloudEntryState(
                            localRevision: applied.revision,
                            cloudRevision: cloud.revision,
                            tombstoneRevision: nil
                        )
                        downloaded += 1
                    } else {
                        let tombstone = try createTombstone(
                            id: id,
                            replacing: nil,
                            deviceID: state.deviceID
                        )
                        tombstones[id] = tombstone
                        try CapsuleCloudIO.coordinatedRemove(
                            cloudLayout.entryURL(id: id),
                            expectedRevision: cloud.revision
                        )
                        cloudDocuments[id] = nil
                        state.entries[key] = CapsuleCloudEntryState(
                            localRevision: nil,
                            cloudRevision: nil,
                            tombstoneRevision: tombstone.value.revision
                        )
                        deleted += 1
                    }
                } else {
                    do {
                        try ensureCloudMediaAvailable(cloud)
                    } catch CapsuleCloudSyncError.mediaUnavailable {
                        deferred += 1
                        deferredIDs.insert(id)
                        continue
                    }
                    let applied = try download(
                        cloud,
                        replacing: nil
                    )
                    localDocuments[id] = applied
                    assetObservations[id] = localAssetObservation(applied)
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: applied.revision,
                        cloudRevision: cloud.revision,
                        tombstoneRevision: nil
                    )
                    downloaded += 1
                }

            case let (local?, nil):
                if let assetObservation,
                   !assetObservation.isAvailable {
                    deferred += 1
                    deferredIDs.insert(id)
                    continue
                }
                let uploadedDocument: CapsuleCloudParsedDocument
                do {
                    uploadedDocument = try upload(
                        local,
                        replacing: nil,
                        assetObservation: assetObservation
                    )
                } catch CapsuleCloudSyncError.mediaUnavailable {
                    deferred += 1
                    deferredIDs.insert(id)
                    continue
                }
                cloudDocuments[id] = uploadedDocument
                state.entries[key] = CapsuleCloudEntryState(
                    localRevision: local.revision,
                    cloudRevision: uploadedDocument.revision,
                    tombstoneRevision: nil
                )
                uploaded += 1

            case let (local?, cloud?):
                let assetChanged = localAssetChanged(
                    assetObservation,
                    baseline: baseline
                )
                let localChanged = !isFreshAutomaticDefault(
                    local,
                    baseline: baseline
                ) && (baseline?.localRevision == nil
                    || baseline?.localRevision != local.revision
                    || assetChanged)
                let cloudChanged = baseline?.cloudRevision == nil
                    || baseline?.cloudRevision != cloud.revision
                if !localChanged && !cloudChanged {
                    if missingManagedAssetNeedsRestoration(
                        local: local,
                        cloud: cloud,
                        observation: assetObservation
                    ) {
                        do {
                            try ensureCloudMediaAvailable(cloud)
                        } catch CapsuleCloudSyncError.mediaUnavailable {
                            deferred += 1
                            deferredIDs.insert(id)
                            continue
                        }
                        let applied = try download(
                            cloud,
                            replacing: local
                        )
                        localDocuments[id] = applied
                        assetObservations[id] = localAssetObservation(applied)
                        state.entries[key] = CapsuleCloudEntryState(
                            localRevision: applied.revision,
                            cloudRevision: cloud.revision,
                            tombstoneRevision: nil
                        )
                        downloaded += 1
                        continue
                    }
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: local.revision,
                        cloudRevision: cloud.revision,
                        tombstoneRevision: nil
                    )
                    continue
                }
                if try semanticallyEqual(
                    local: local,
                    cloud: cloud,
                    assetObservation: assetObservation
                ) {
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: local.revision,
                        cloudRevision: cloud.revision,
                        tombstoneRevision: nil
                    )
                    continue
                }
                if localChanged && cloudChanged {
                    do {
                        try ensureCloudMediaAvailable(cloud)
                    } catch CapsuleCloudSyncError.mediaUnavailable {
                        deferred += 1
                        deferredIDs.insert(id)
                        continue
                    }
                    conflicts += 1
                    // The version already accepted by the coordinated cloud
                    // entry wins a true concurrent edit. This is independent
                    // of device wall clocks; the local loser remains as an
                    // Obsidian-readable conflict document.
                    try archiveLocalConflict(
                        local,
                        id: id,
                        origin: "local-concurrent",
                        assetObservation: assetObservation
                    )
                    let applied = try download(
                        cloud,
                        replacing: local
                    )
                    localDocuments[id] = applied
                    assetObservations[id] = localAssetObservation(applied)
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: applied.revision,
                        cloudRevision: cloud.revision,
                        tombstoneRevision: nil
                    )
                    downloaded += 1
                } else if localChanged {
                    if let assetObservation,
                       !assetObservation.isAvailable,
                       baseline?.localAssetPathHash
                        != assetObservation.pathHash {
                        deferred += 1
                        deferredIDs.insert(id)
                        continue
                    }
                    let uploadedDocument: CapsuleCloudParsedDocument
                    do {
                        uploadedDocument = try upload(
                            local,
                            replacing: cloud,
                            assetObservation: assetObservation
                        )
                    } catch CapsuleCloudSyncError.mediaUnavailable {
                        deferred += 1
                        deferredIDs.insert(id)
                        continue
                    }
                    cloudDocuments[id] = uploadedDocument
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: local.revision,
                        cloudRevision: uploadedDocument.revision,
                        tombstoneRevision: nil
                    )
                    uploaded += 1
                } else if cloudChanged {
                    do {
                        try ensureCloudMediaAvailable(cloud)
                    } catch CapsuleCloudSyncError.mediaUnavailable {
                        deferred += 1
                        deferredIDs.insert(id)
                        continue
                    }
                    let applied = try download(
                        cloud,
                        replacing: local
                    )
                    localDocuments[id] = applied
                    assetObservations[id] = localAssetObservation(applied)
                    state.entries[key] = CapsuleCloudEntryState(
                        localRevision: applied.revision,
                        cloudRevision: cloud.revision,
                        tombstoneRevision: nil
                    )
                    downloaded += 1
                }
            }
        }

        for (id, document) in localDocuments {
            let key = id.uuidString.lowercased()
            guard !deferredIDs.contains(id),
                  var entry = state.entries[key] else { continue }
            if document.record.summary.type == .image
                || document.record.summary.type == .pdf {
                guard let observation = assetObservations[id] else {
                    continue
                }
                entry.localAssetPathHash = observation.pathHash
                if let fingerprint = observation.fingerprint {
                    entry.localAssetFingerprint = fingerprint
                }
            } else {
                entry.localAssetFingerprint = nil
                entry.localAssetPathHash = nil
            }
            state.entries[key] = entry
        }
        try writeState(state)
        let retainedConflicts = try retainedConflictCount()
        return CapsuleCloudSyncResult(
            uploaded: uploaded,
            downloaded: downloaded,
            deleted: deleted,
            conflicts: max(conflicts, retainedConflicts),
            deferred: deferred
        )
    }

    private static func prepareLayoutDirectories(
        _ layout: CapsuleCloudLayout
    ) throws {
        try CapsuleCloudIO.ensureDirectory(layout.versionDirectoryURL)
        try CapsuleCloudIO.ensureDirectory(layout.entriesURL)
        try CapsuleCloudIO.ensureDirectory(layout.assetsURL)
        try CapsuleCloudIO.ensureDirectory(layout.tombstonesURL)
        try CapsuleCloudIO.ensureDirectory(layout.conflictsURL)
    }

    private func loadOrCreateLocalLibraryID() throws -> UUID {
        let markerURL = localRootURL.appendingPathComponent(
            "content-library-v1.json"
        )
        if fileManager.fileExists(atPath: markerURL.path) {
            let data = try CapsuleCloudIO.secureRead(
                markerURL,
                maximumBytes: 64 * 1_024
            )
            let marker: CapsuleLocalLibraryMarker
            do {
                marker = try CapsuleCloudIO.decodeJSON(
                    CapsuleLocalLibraryMarker.self,
                    from: data
                )
            } catch {
                throw CapsuleCloudSyncError.fileOperation(
                    "本机 Capsule 库标识损坏"
                )
            }
            guard marker.version == 1 else {
                throw CapsuleCloudSyncError.fileOperation(
                    "本机 Capsule 库标识版本不兼容"
                )
            }
            return marker.libraryID
        }
        let marker = CapsuleLocalLibraryMarker(
            version: 1,
            libraryID: UUID()
        )
        let data = try CapsuleCloudIO.jsonData(marker)
        do {
            try CapsuleCloudIO.atomicWrite(data, to: markerURL)
            _ = chmod(markerURL.path, mode_t(0o600))
            return marker.libraryID
        } catch {
            // A concurrent standalone process may have created the marker
            // after our existence check. Read and validate that winner.
            guard fileManager.fileExists(atPath: markerURL.path) else {
                throw error
            }
            let winnerData = try CapsuleCloudIO.secureRead(
                markerURL,
                maximumBytes: 64 * 1_024
            )
            let winner = try CapsuleCloudIO.decodeJSON(
                CapsuleLocalLibraryMarker.self,
                from: winnerData
            )
            guard winner.version == 1 else {
                throw CapsuleCloudSyncError.fileOperation(
                    "本机 Capsule 库标识版本不兼容"
                )
            }
            return winner.libraryID
        }
    }

    private func loadState(
        localLibraryID: UUID
    ) throws -> CapsuleCloudSyncState {
        let directory = stateURL.deletingLastPathComponent()
        try CapsuleCloudIO.ensureDirectory(directory)
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return CapsuleCloudSyncState(
                version: 2,
                libraryID: libraryID,
                localLibraryID: localLibraryID,
                deviceID: UUID(),
                entries: [:]
            )
        }
        let data = try CapsuleCloudIO.secureRead(
            stateURL,
            maximumBytes: 8 * 1_024 * 1_024
        )
        let decoded: CapsuleCloudSyncState
        do {
            decoded = try CapsuleCloudIO.decodeJSON(
                CapsuleCloudSyncState.self,
                from: data
            )
        } catch {
            // State is only a comparison cache. Losing or corrupting it must
            // cause a conservative merge, never propagate mass deletion.
            return CapsuleCloudSyncState(
                version: 2,
                libraryID: libraryID,
                localLibraryID: localLibraryID,
                deviceID: UUID(),
                entries: [:]
            )
        }
        guard decoded.version == 2,
              decoded.libraryID == libraryID,
              decoded.localLibraryID == localLibraryID else {
            return CapsuleCloudSyncState(
                version: 2,
                libraryID: libraryID,
                localLibraryID: localLibraryID,
                deviceID: decoded.deviceID,
                entries: [:]
            )
        }
        return decoded
    }

    private func writeState(_ state: CapsuleCloudSyncState) throws {
        let data = try CapsuleCloudIO.jsonData(state)
        try CapsuleCloudIO.atomicWrite(data, to: stateURL)
        _ = chmod(stateURL.path, mode_t(0o600))
    }

    private func loadCloudDocuments() throws
        -> [UUID: CapsuleCloudParsedDocument] {
        try CapsuleCloudIO.requireDirectory(cloudLayout.entriesURL)
        let urls = try fileManager.contentsOfDirectory(
            at: cloudLayout.entriesURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= CapsuleContentStore.maximumRecordCount else {
            throw CapsuleCloudSyncError.unsafeItem(
                cloudLayout.entriesURL.path
            )
        }
        var documents: [UUID: CapsuleCloudParsedDocument] = [:]
        for url in urls {
            guard url.pathExtension.lowercased() == "md" else {
                throw CapsuleCloudSyncError.unsafeItem(url.path)
            }
            let data = try CapsuleCloudIO.coordinatedRead(
                url,
                maximumBytes: CapsuleContentStore.maximumDocumentBytes
            )
            let document = try CapsuleCloudDocumentCodec.parse(
                data,
                fileURL: url
            )
            guard documents[document.id] == nil else {
                throw CapsuleCloudSyncError.malformedDocument(url.path)
            }
            documents[document.id] = document
        }
        return documents
    }

    private func loadTombstones() throws
        -> [UUID: CapsuleCloudLoadedTombstone] {
        try CapsuleCloudIO.requireDirectory(cloudLayout.tombstonesURL)
        let urls = try fileManager.contentsOfDirectory(
            at: cloudLayout.tombstonesURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        )
        guard urls.count <= CapsuleContentStore.maximumRecordCount else {
            throw CapsuleCloudSyncError.unsafeItem(
                cloudLayout.tombstonesURL.path
            )
        }
        var result: [UUID: CapsuleCloudLoadedTombstone] = [:]
        for url in urls {
            guard url.pathExtension.lowercased() == "json",
                  let fileID = UUID(
                    uuidString: url.deletingPathExtension().lastPathComponent
                  ) else {
                throw CapsuleCloudSyncError.unsafeItem(url.path)
            }
            let data = try CapsuleCloudIO.coordinatedRead(
                url,
                maximumBytes: 64 * 1_024
            )
            let tombstone: CapsuleCloudTombstone
            do {
                tombstone = try CapsuleCloudIO.decodeJSON(
                    CapsuleCloudTombstone.self,
                    from: data
                )
            } catch {
                throw CapsuleCloudSyncError.malformedDocument(url.path)
            }
            guard tombstone.version == 1,
                  tombstone.id == fileID,
                  result[fileID] == nil else {
                throw CapsuleCloudSyncError.malformedDocument(url.path)
            }
            result[fileID] = CapsuleCloudLoadedTombstone(
                value: tombstone,
                data: data,
                dataRevision: CapsuleCloudIO.revision(data)
            )
        }
        return result
    }

    private func makeCloudPayload(
        from local: CapsuleContentSyncDocument
    ) throws -> CapsuleCloudParsedDocument {
        let type = local.record.summary.type
        var assetName: String?
        if type == .image || type == .pdf {
            let sourceURL = URL(fileURLWithPath: local.record.content)
                .standardizedFileURL
            let maximum = type == .image
                ? CapsuleMediaPreviewLoader.maximumImageBytes
                : CapsuleMediaPreviewLoader.maximumPDFBytes
            let data = try CapsuleCloudIO.secureRead(
                sourceURL,
                maximumBytes: maximum
            )
            let hash = CapsuleCloudIO.revision(data)
            let ext = sourceURL.pathExtension.lowercased()
            let name = "\(hash).\(ext)"
            guard CapsuleCloudDocumentCodec.isValidAssetName(
                name,
                for: type
            ) else {
                throw CapsuleCloudSyncError.unsafeItem(sourceURL.path)
            }
            let destination = cloudLayout.assetsURL
                .appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                let existing = try CapsuleCloudIO.coordinatedRead(
                    destination,
                    maximumBytes: maximum
                )
                guard CapsuleCloudIO.revision(existing) == hash else {
                    throw CapsuleCloudSyncError.unsafeItem(
                        destination.path
                    )
                }
            } else {
                try CapsuleCloudIO.coordinatedWrite(
                    data,
                    to: destination,
                    expectedRevision: nil
                )
            }
            assetName = name
        }
        let data = try CapsuleCloudDocumentCodec.cloudData(
            from: local,
            assetName: assetName
        )
        return try CapsuleCloudDocumentCodec.parse(
            data,
            fileURL: cloudLayout.entryURL(id: local.record.summary.id)
        )
    }

    private func upload(
        _ local: CapsuleContentSyncDocument,
        replacing cloud: CapsuleCloudParsedDocument?,
        assetObservation: CapsuleLocalAssetObservation?
    ) throws -> CapsuleCloudParsedDocument {
        let payload: CapsuleCloudParsedDocument
        if let assetObservation, !assetObservation.isAvailable {
            guard let assetName = cloud?.assetName else {
                throw CapsuleCloudSyncError.unavailable(
                    "\(local.record.summary.title) 的媒体文件当前离线"
                )
            }
            let data = try CapsuleCloudDocumentCodec.cloudData(
                from: local,
                assetName: assetName
            )
            payload = try CapsuleCloudDocumentCodec.parse(
                data,
                fileURL: cloudLayout.entryURL(
                    id: local.record.summary.id
                )
            )
        } else {
            do {
                payload = try makeCloudPayload(from: local)
            } catch {
                if localAssetObservation(local)?.isAvailable == false {
                    throw CapsuleCloudSyncError.mediaUnavailable(
                        local.record.summary.title
                    )
                }
                throw error
            }
        }
        try CapsuleCloudIO.coordinatedWrite(
            payload.data,
            to: cloudLayout.entryURL(id: local.record.summary.id),
            expectedRevision: cloud?.revision
        )
        return payload
    }

    private func download(
        _ cloud: CapsuleCloudParsedDocument,
        replacing local: CapsuleContentSyncDocument?
    ) throws -> CapsuleContentSyncDocument {
        let localData: Data
        if cloud.type == .image || cloud.type == .pdf {
            guard let assetName = cloud.assetName else {
                throw CapsuleCloudSyncError.malformedDocument(
                    cloudLayout.entryURL(id: cloud.id).path
                )
            }
            let materializedPath = try materializeAsset(
                named: assetName,
                type: cloud.type
            )
            localData = CapsuleCloudDocumentCodec.localData(
                from: cloud,
                materializedPath: materializedPath
            )
        } else {
            localData = cloud.data
        }
        let record = try contentStore.applySynchronizedDocument(
            localData,
            id: cloud.id,
            expectedRevision: local?.revision
        )
        return CapsuleContentSyncDocument(
            record: record,
            data: localData,
            revision: CapsuleCloudIO.revision(localData)
        )
    }

    private func materializeAsset(
        named assetName: String,
        type: CapsuleEntryKind
    ) throws -> String {
        guard CapsuleCloudDocumentCodec.isValidAssetName(
            assetName,
            for: type
        ), let expectedHash = CapsuleCloudDocumentCodec.assetHash(
            from: assetName
        ) else {
            throw CapsuleCloudSyncError.unsafeItem(assetName)
        }
        let maximum = type == .image
            ? CapsuleMediaPreviewLoader.maximumImageBytes
            : CapsuleMediaPreviewLoader.maximumPDFBytes
        let localAssets = localRootURL.appendingPathComponent(
            "assets",
            isDirectory: true
        )
        try CapsuleCloudIO.ensureDirectory(localAssets)
        let localURL = localAssets.appendingPathComponent(assetName)
        if fileManager.fileExists(atPath: localURL.path) {
            let existing = try CapsuleCloudIO.secureRead(
                localURL,
                maximumBytes: maximum
            )
            guard CapsuleCloudIO.revision(existing) == expectedHash else {
                throw CapsuleCloudSyncError.unsafeItem(localURL.path)
            }
            return localURL.path
        }
        let cloudURL = cloudLayout.assetsURL.appendingPathComponent(assetName)
        if fileManager.isUbiquitousItem(at: cloudURL) {
            try? fileManager.startDownloadingUbiquitousItem(at: cloudURL)
        }
        let data: Data
        do {
            data = try CapsuleCloudIO.coordinatedRead(
                cloudURL,
                maximumBytes: maximum
            )
        } catch {
            if cloudAssetIsAwaitingDownload(cloudURL) {
                throw CapsuleCloudSyncError.mediaUnavailable(assetName)
            }
            throw error
        }
        guard CapsuleCloudIO.revision(data) == expectedHash else {
            throw CapsuleCloudSyncError.unsafeItem(cloudURL.path)
        }
        try CapsuleCloudIO.atomicWrite(data, to: localURL)
        _ = chmod(localURL.path, mode_t(0o600))
        return localURL.path
    }

    private func cloudAssetIsAwaitingDownload(_ url: URL) -> Bool {
        guard fileManager.isUbiquitousItem(at: url) else { return false }
        try? fileManager.startDownloadingUbiquitousItem(at: url)
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey,
        ])
        guard values?.ubiquitousItemDownloadingError == nil else {
            return true
        }
        return values?.ubiquitousItemDownloadingStatus != .current
    }

    private func ensureCloudMediaAvailable(
        _ cloud: CapsuleCloudParsedDocument
    ) throws {
        guard cloud.type == .image || cloud.type == .pdf else { return }
        guard let assetName = cloud.assetName else {
            throw CapsuleCloudSyncError.malformedDocument(
                cloudLayout.entryURL(id: cloud.id).path
            )
        }
        _ = try materializeAsset(named: assetName, type: cloud.type)
    }

    private func semanticallyEqual(
        local: CapsuleContentSyncDocument,
        cloud: CapsuleCloudParsedDocument,
        assetObservation: CapsuleLocalAssetObservation?
    ) throws -> Bool {
        guard local.record.summary.type == cloud.type else { return false }
        let payloadData: Data
        if let assetObservation, !assetObservation.isAvailable {
            guard let assetName = cloud.assetName else { return false }
            payloadData = try CapsuleCloudDocumentCodec.cloudData(
                from: local,
                assetName: assetName
            )
        } else {
            do {
                payloadData = try makeCloudPayload(from: local).data
            } catch {
                if localAssetObservation(local)?.isAvailable == false {
                    // The file went offline after the initial snapshot. Treat
                    // the documents as different so a cloud-only change can
                    // still download; a required local upload is deferred by
                    // its caller without stopping unrelated UUIDs.
                    return false
                }
                throw error
            }
        }
        guard let localComparable = CapsuleCloudDocumentCodec
            .equivalenceData(payloadData),
              let cloudComparable = CapsuleCloudDocumentCodec
                .equivalenceData(cloud.data) else { return false }
        return localComparable == cloudComparable
    }

    private func localAssetObservation(
        _ local: CapsuleContentSyncDocument
    ) -> CapsuleLocalAssetObservation? {
        let type = local.record.summary.type
        guard type == .image || type == .pdf else { return nil }
        let url = URL(fileURLWithPath: local.record.content)
            .standardizedFileURL
        let pathHash = CapsuleCloudIO.revision(Data(url.path.utf8))
        var metadata = stat()
        guard url.path.withCString({ lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size > 0,
              metadata.st_size <= (type == .image
                ? CapsuleMediaPreviewLoader.maximumImageBytes
                : CapsuleMediaPreviewLoader.maximumPDFBytes) else {
            return CapsuleLocalAssetObservation(
                pathHash: pathHash,
                fingerprint: nil
            )
        }
        let fingerprint = [
            String(UInt64(metadata.st_dev)),
            String(UInt64(metadata.st_ino)),
            String(Int64(metadata.st_size)),
            String(Int64(metadata.st_mtimespec.tv_sec)),
            String(Int64(metadata.st_mtimespec.tv_nsec)),
        ].joined(separator: ":")
        return CapsuleLocalAssetObservation(
            pathHash: pathHash,
            fingerprint: fingerprint
        )
    }

    private func localAssetChanged(
        _ observation: CapsuleLocalAssetObservation?,
        baseline: CapsuleCloudEntryState?
    ) -> Bool {
        guard let fingerprint = observation?.fingerprint else {
            // An unavailable file is not a content edit. Keeping the previous
            // fingerprint lets an unchanged file come back online without a
            // needless upload, while a replacement still changes metadata.
            return false
        }
        return baseline?.localAssetFingerprint != fingerprint
    }

    private func isFreshAutomaticDefault(
        _ local: CapsuleContentSyncDocument,
        baseline: CapsuleCloudEntryState?
    ) -> Bool {
        baseline == nil
            && local.record.summary.id == CapsuleContentStore.defaultEntryID
            && local.record.summary.type == .note
            && local.record.summary.title
                == CapsuleContentStore.defaultEntryTitle
            && local.record.content == CapsuleContentStore.defaultEntryContent
            && Self.hasCanonicalAutomaticDefaultShape(local)
    }

    /// Only the exact front-matter shape emitted by the one-time seed may be
    /// discarded without a conflict copy. Unknown fields, reordered metadata,
    /// or other direct Obsidian edits make the fixed UUID user-owned even when
    /// its visible title and body still equal the defaults.
    private static func hasCanonicalAutomaticDefaultShape(
        _ local: CapsuleContentSyncDocument
    ) -> Bool {
        guard let text = String(data: local.data, encoding: .utf8),
              let id = encodeSeedScalar(
                CapsuleContentStore.defaultEntryID.uuidString.lowercased()
              ),
              let title = encodeSeedScalar(
                CapsuleContentStore.defaultEntryTitle
              ),
              let updatedAt = encodeSeedScalar(
                seedISO8601.string(from: local.record.summary.updatedAt)
              ) else {
            return false
        }
        let expected = """
        ---
        capsule: memory
        version: 1
        id: \(id)
        title: \(title)
        updated_at: \(updatedAt)
        ---

        \(CapsuleContentStore.defaultEntryContent)
        """
        return text == expected
    }

    private static func encodeSeedScalar(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static let seedISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private func missingManagedAssetNeedsRestoration(
        local: CapsuleContentSyncDocument,
        cloud: CapsuleCloudParsedDocument,
        observation: CapsuleLocalAssetObservation?
    ) -> Bool {
        guard let observation,
              !observation.isAvailable,
              let assetName = cloud.assetName,
              local.record.summary.type == .image
                || local.record.summary.type == .pdf else {
            return false
        }
        let expected = localRootURL
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(assetName)
            .standardizedFileURL
        let current = URL(fileURLWithPath: local.record.content)
            .standardizedFileURL
        return current.path == expected.path
    }

    private func createTombstone(
        id: UUID,
        replacing existing: CapsuleCloudLoadedTombstone?,
        deviceID: UUID
    ) throws -> CapsuleCloudLoadedTombstone {
        let timestamp = now()
        let logicalRevision = "\(Int(timestamp.timeIntervalSince1970 * 1_000))"
            + "-\(deviceID.uuidString.lowercased())"
        let tombstone = CapsuleCloudTombstone(
            version: 1,
            id: id,
            deletedAt: timestamp,
            deviceID: deviceID,
            revision: logicalRevision
        )
        let data = try CapsuleCloudIO.jsonData(tombstone)
        try CapsuleCloudIO.coordinatedWrite(
            data,
            to: cloudLayout.tombstoneURL(id: id),
            expectedRevision: existing?.dataRevision
        )
        return CapsuleCloudLoadedTombstone(
            value: tombstone,
            data: data,
            dataRevision: CapsuleCloudIO.revision(data)
        )
    }

    private func removeTombstone(
        id: UUID,
        loaded: CapsuleCloudLoadedTombstone
    ) throws {
        try CapsuleCloudIO.coordinatedRemove(
            cloudLayout.tombstoneURL(id: id),
            expectedRevision: loaded.dataRevision
        )
    }

    private func archiveDeletionIntent(
        id: UUID,
        deviceID: UUID,
        cloudRevision: String
    ) throws {
        let conflict = CapsuleCloudDeletionConflict(
            version: 1,
            kind: "local-deletion-conflict",
            id: id,
            deviceID: deviceID,
            observedCloudRevision: cloudRevision,
            observedAt: now()
        )
        try archive(
            CapsuleCloudIO.jsonData(conflict),
            id: id,
            origin: "local-deletion",
            pathExtension: "json"
        )
    }

    private func archiveLocalConflict(
        _ local: CapsuleContentSyncDocument,
        id: UUID,
        origin: String,
        assetObservation: CapsuleLocalAssetObservation?
    ) throws {
        guard let assetObservation else {
            try archive(local.data, id: id, origin: origin)
            return
        }
        var unavailableObservation = assetObservation
        if assetObservation.isAvailable {
            do {
                let payload = try makeCloudPayload(from: local)
                try archive(payload.data, id: id, origin: origin)
                return
            } catch {
                guard let current = localAssetObservation(local),
                      !current.isAvailable else {
                    throw error
                }
                unavailableObservation = current
            }
        }
        // Never place an absolute local media path into iCloud merely to
        // record a conflict. The metadata below preserves the audit boundary
        // and allows the deletion to converge without leaking that path.
        try contentStore.archiveSynchronizedConflict(
            local.data,
            id: id,
            origin: origin
        )
        let conflict = CapsuleCloudUnavailableMediaConflict(
            version: 1,
            kind: "local-media-unavailable-conflict",
            id: id,
            type: local.record.summary.type.rawValue,
            title: local.record.summary.title,
            localRevision: local.revision,
            localAssetPathHash: unavailableObservation.pathHash,
            observedAt: now()
        )
        try archive(
            CapsuleCloudIO.jsonData(conflict),
            id: id,
            origin: origin + "-media-unavailable",
            pathExtension: "json"
        )
    }

    private func archive(
        _ data: Data,
        id: UUID,
        origin: String,
        pathExtension: String = "md"
    ) throws {
        let directory = cloudLayout.conflictsURL.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true
        )
        try CapsuleCloudIO.ensureDirectory(directory)
        let milliseconds = Int(now().timeIntervalSince1970 * 1_000)
        let safeOrigin = origin.filter {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
        let destination = directory.appendingPathComponent(
            "\(milliseconds)-\(safeOrigin)-\(UUID().uuidString.lowercased()).\(pathExtension)"
        )
        try CapsuleCloudIO.coordinatedWrite(
            data,
            to: destination,
            expectedRevision: nil
        )
    }

    private func retainedConflictCount() throws -> Int {
        try CapsuleCloudIO.requireDirectory(cloudLayout.conflictsURL)
        let directories = try fileManager.contentsOfDirectory(
            at: cloudLayout.conflictsURL,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        )
        guard directories.count <= CapsuleContentStore.maximumRecordCount else {
            throw CapsuleCloudSyncError.unsafeItem(
                cloudLayout.conflictsURL.path
            )
        }
        var count = 0
        for directory in directories {
            try CapsuleCloudIO.requireDirectory(directory)
            let items = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
            guard count <= 100_000 - items.count else {
                throw CapsuleCloudSyncError.unsafeItem(directory.path)
            }
            for item in items {
                let values = try item.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard ["md", "json"].contains(item.pathExtension),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw CapsuleCloudSyncError.unsafeItem(item.path)
                }
            }
            count += items.count
        }
        return count
    }
}

private final class CapsuleCloudSyncConfigurationStore {
    let directoryURL: URL
    let configurationURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
        configurationURL = self.directoryURL.appendingPathComponent(
            "config-v1.json"
        )
    }

    func load() throws -> CapsuleCloudSyncConfiguration? {
        try CapsuleCloudIO.ensureDirectory(directoryURL)
        guard FileManager.default.fileExists(
            atPath: configurationURL.path
        ) else { return nil }
        let data = try CapsuleCloudIO.secureRead(
            configurationURL,
            maximumBytes: 1 * 1_024 * 1_024
        )
        let configuration: CapsuleCloudSyncConfiguration
        do {
            configuration = try CapsuleCloudIO.decodeJSON(
                CapsuleCloudSyncConfiguration.self,
                from: data
            )
        } catch {
            throw CapsuleCloudSyncError.fileOperation(
                "本机 iCloud 同步配置损坏"
            )
        }
        guard configuration.version == 1,
              configuration.enabled else {
            throw CapsuleCloudSyncError.fileOperation(
                "本机 iCloud 同步配置版本不兼容"
            )
        }
        return configuration
    }

    func save(
        folderURL: URL,
        libraryID: UUID
    ) throws -> CapsuleCloudSyncConfiguration {
        try CapsuleCloudIO.ensureDirectory(directoryURL)
        let bookmark: Data
        do {
            bookmark = try folderURL.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw CapsuleCloudSyncError.fileOperation(
                "无法保存 iCloud 文件夹书签"
            )
        }
        let configuration = CapsuleCloudSyncConfiguration(
            version: 1,
            enabled: true,
            libraryID: libraryID,
            folderPath: folderURL.path,
            bookmark: bookmark
        )
        let data = try CapsuleCloudIO.jsonData(configuration)
        try CapsuleCloudIO.atomicWrite(data, to: configurationURL)
        _ = chmod(configurationURL.path, mode_t(0o600))
        return configuration
    }

    func resolveFolder(
        from configuration: CapsuleCloudSyncConfiguration
    ) throws -> (url: URL, stale: Bool) {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: configuration.bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url.standardizedFileURL, stale)
        } catch {
            let fallback = URL(
                fileURLWithPath: configuration.folderPath,
                isDirectory: true
            )
            guard FileManager.default.fileExists(
                atPath: fallback.path
            ) else {
                throw CapsuleCloudSyncError.unavailable(
                    "已设置的文件夹目前不在本机"
                )
            }
            return (fallback.standardizedFileURL, true)
        }
    }

    func disable() throws {
        guard FileManager.default.fileExists(
            atPath: configurationURL.path
        ) else { return }
        do {
            try FileManager.default.removeItem(at: configurationURL)
        } catch {
            throw CapsuleCloudSyncError.fileOperation(
                error.localizedDescription
            )
        }
    }

    func stateURL(libraryID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "state-\(libraryID.uuidString.lowercased()).json"
        )
    }
}

private final class CapsuleCloudFilePresenter: NSObject, NSFilePresenter {
    private(set) var presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: () -> Void
    private let moved: (URL) -> Void
    private let disappeared: () -> Void

    init(
        rootURL: URL,
        changed: @escaping () -> Void,
        moved: @escaping (URL) -> Void,
        disappeared: @escaping () -> Void
    ) {
        presentedItemURL = rootURL
        self.changed = changed
        self.moved = moved
        self.disappeared = disappeared
        let queue = OperationQueue()
        queue.name = "RIMES.CapsuleCloudSync.presenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        super.init()
    }

    func presentedItemDidChange() {
        changed()
    }

    func presentedSubitemDidAppear(at url: URL) {
        changed()
    }

    func presentedSubitemDidChange(at url: URL) {
        changed()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        changed()
    }

    func presentedSubitemDidDisappear(at url: URL) {
        changed()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL.standardizedFileURL
        moved(newURL.standardizedFileURL)
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        disappeared()
        completionHandler(nil)
    }
}

final class CapsuleCloudSyncController {
    static let shared = CapsuleCloudSyncController()

    private let contentStore: CapsuleContentStore
    private let localRootURL: URL
    private let configurationStore: CapsuleCloudSyncConfigurationStore
    private let requireUbiquitousRoot: Bool
    private let queue: DispatchQueue
    private let statusLock = NSLock()

    private var statusStorage = CapsuleCloudSyncStatus.unconfigured
    private var engine: CapsuleCloudSyncEngine?
    private var configuredFolderURL: URL?
    private var configuredLibraryID: UUID?
    private var presenter: CapsuleCloudFilePresenter?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var requestGeneration: UInt64 = 0
    private var syncInFlight = false

    convenience init() {
        let localRoot = CapsulePasswordStore.defaultRootURL()
        let configurationDirectory = localRoot
            .deletingLastPathComponent()
            .appendingPathComponent("capsule-sync", isDirectory: true)
        self.init(
            contentStore: .shared,
            localRootURL: localRoot,
            configurationDirectoryURL: configurationDirectory,
            requireUbiquitousRoot: true
        )
    }

    init(
        contentStore: CapsuleContentStore,
        localRootURL: URL,
        configurationDirectoryURL: URL,
        requireUbiquitousRoot: Bool
    ) {
        self.contentStore = contentStore
        self.localRootURL = localRootURL.standardizedFileURL
        configurationStore = CapsuleCloudSyncConfigurationStore(
            directoryURL: configurationDirectoryURL
        )
        self.requireUbiquitousRoot = requireUbiquitousRoot
        queue = DispatchQueue(
            label: "RIMES.CapsuleCloudSync",
            qos: .utility
        )
    }

    deinit {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspace.removeObserver)
    }

    var status: CapsuleCloudSyncStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return statusStorage
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.installObservers()
            self.installTimer()
            self.restoreConfiguration()
        }
    }

    func configure(
        folderURL: URL,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let previousStatus = self.status
            do {
                let root = try CapsuleCloudSyncRootValidator.validate(
                    folderURL,
                    localCapsuleRoot: self.localRootURL,
                    requireUbiquitous: self.requireUbiquitousRoot
                )
                let libraryID = try CapsuleCloudSyncEngine.prepareLibrary(
                    at: root
                )
                _ = try self.configurationStore.save(
                    folderURL: root,
                    libraryID: libraryID
                )
                self.installEngine(
                    rootURL: root,
                    libraryID: libraryID
                )
                self.publish(
                    CapsuleCloudSyncStatus(
                        phase: .idle,
                        configured: true,
                        folderName: root.lastPathComponent,
                        message: "等待同步",
                        lastSyncedAt: nil,
                        conflictCount: 0,
                        deferredCount: 0
                    )
                )
                self.performSync()
                DispatchQueue.main.async {
                    completion?(.success(()))
                }
            } catch {
                if previousStatus.isConfigured {
                    self.publish(previousStatus)
                } else {
                    self.publishFailure(
                        error,
                        folderName: folderURL.lastPathComponent
                    )
                }
                DispatchQueue.main.async {
                    completion?(.failure(error))
                }
            }
        }
    }

    func requestSync(after delay: TimeInterval = 0) {
        queue.async { [weak self] in
            guard let self else { return }
            self.requestGeneration &+= 1
            let generation = self.requestGeneration
            self.queue.asyncAfter(
                deadline: .now() + max(0, delay)
            ) { [weak self] in
                guard let self,
                      generation == self.requestGeneration else { return }
                self.performSync()
            }
        }
    }

    func disable(
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configurationStore.disable()
                self.uninstallPresenter()
                self.engine = nil
                self.configuredFolderURL = nil
                self.configuredLibraryID = nil
                self.requestGeneration &+= 1
                self.publish(.unconfigured)
                DispatchQueue.main.async {
                    completion?(.success(()))
                }
            } catch {
                self.publishFailure(
                    error,
                    folderName: self.configuredFolderURL?.lastPathComponent
                )
                DispatchQueue.main.async {
                    completion?(.failure(error))
                }
            }
        }
    }

    private func restoreConfiguration() {
        do {
            guard let configuration = try configurationStore.load() else {
                publish(.unconfigured)
                return
            }
            let resolved = try configurationStore.resolveFolder(
                from: configuration
            )
            let root = try CapsuleCloudSyncRootValidator.validate(
                resolved.url,
                localCapsuleRoot: localRootURL,
                requireUbiquitous: requireUbiquitousRoot
            )
            let libraryID = try CapsuleCloudSyncEngine.prepareLibrary(
                at: root,
                preferredLibraryID: configuration.libraryID
            )
            if resolved.stale {
                _ = try configurationStore.save(
                    folderURL: root,
                    libraryID: libraryID
                )
            }
            installEngine(rootURL: root, libraryID: libraryID)
            publish(
                CapsuleCloudSyncStatus(
                    phase: .idle,
                    configured: true,
                    folderName: root.lastPathComponent,
                    message: "等待同步",
                    lastSyncedAt: nil,
                    conflictCount: 0,
                    deferredCount: 0
                )
            )
            performSync()
        } catch {
            let folderName = (try? configurationStore.load())?
                .folderPath
                .split(separator: "/")
                .last
                .map(String.init)
            publish(
                CapsuleCloudSyncStatus(
                    phase: .unavailable,
                    configured: true,
                    folderName: folderName ?? nil,
                    message: error.localizedDescription,
                    lastSyncedAt: nil,
                    conflictCount: 0,
                    deferredCount: 0
                )
            )
        }
    }

    private func installEngine(rootURL: URL, libraryID: UUID) {
        uninstallPresenter()
        configuredFolderURL = rootURL
        configuredLibraryID = libraryID
        engine = CapsuleCloudSyncEngine(
            contentStore: contentStore,
            localRootURL: localRootURL,
            cloudRootURL: rootURL,
            stateURL: configurationStore.stateURL(
                libraryID: libraryID
            ),
            libraryID: libraryID
        )
        let presenter = CapsuleCloudFilePresenter(
            rootURL: rootURL
        ) { [weak self] in
            self?.requestSync(after: 0.75)
        } moved: { [weak self] newURL in
            self?.handlePresentedRootMove(to: newURL)
        } disappeared: { [weak self] in
            self?.handlePresentedRootDisappearance()
        }
        self.presenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    private func handlePresentedRootMove(to newURL: URL) {
        queue.async { [weak self] in
            guard let self, let libraryID = self.configuredLibraryID else {
                return
            }
            do {
                let root = try CapsuleCloudSyncRootValidator.validate(
                    newURL,
                    localCapsuleRoot: self.localRootURL,
                    requireUbiquitous: self.requireUbiquitousRoot
                )
                let preparedID = try CapsuleCloudSyncEngine.prepareLibrary(
                    at: root,
                    preferredLibraryID: libraryID
                )
                _ = try self.configurationStore.save(
                    folderURL: root,
                    libraryID: preparedID
                )
                self.installEngine(rootURL: root, libraryID: preparedID)
                self.publish(
                    CapsuleCloudSyncStatus(
                        phase: .idle,
                        configured: true,
                        folderName: root.lastPathComponent,
                        message: "同步文件夹已移动，等待同步",
                        lastSyncedAt: self.status.lastSyncedAt,
                        conflictCount: self.status.conflictCount,
                        deferredCount: self.status.deferredCount
                    )
                )
                self.performSync()
            } catch {
                self.markPresentedRootUnavailable(error, at: newURL)
            }
        }
    }

    private func handlePresentedRootDisappearance() {
        queue.async { [weak self] in
            guard let self else { return }
            self.markPresentedRootUnavailable(
                CapsuleCloudSyncError.unavailable(
                    "已设置的同步文件夹被移走或删除，请重新选择"
                ),
                at: self.configuredFolderURL
            )
        }
    }

    private func markPresentedRootUnavailable(
        _ error: Error,
        at url: URL?
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        uninstallPresenter()
        engine = nil
        configuredFolderURL = url
        requestGeneration &+= 1
        publish(
            CapsuleCloudSyncStatus(
                phase: .unavailable,
                configured: true,
                folderName: url?.lastPathComponent,
                message: error.localizedDescription,
                lastSyncedAt: status.lastSyncedAt,
                conflictCount: status.conflictCount,
                deferredCount: status.deferredCount
            )
        )
    }

    private func uninstallPresenter() {
        if let presenter {
            NSFileCoordinator.removeFilePresenter(presenter)
            self.presenter = nil
        }
    }

    private func performSync() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !syncInFlight, let engine else { return }
        syncInFlight = true
        let folderName = configuredFolderURL?.lastPathComponent
        publish(
            CapsuleCloudSyncStatus(
                phase: .syncing,
                configured: true,
                folderName: folderName,
                message: "正在同步",
                lastSyncedAt: status.lastSyncedAt,
                conflictCount: status.conflictCount,
                deferredCount: status.deferredCount
            )
        )
        do {
            let result = try engine.synchronize()
            syncInFlight = false
            let timestamp = Date()
            let visibleConflictCount = result.conflicts
            publish(
                CapsuleCloudSyncStatus(
                    phase: .synced,
                    configured: true,
                    folderName: folderName,
                    message: syncCompletionMessage(
                        conflicts: visibleConflictCount,
                        deferred: result.deferred
                    ),
                    lastSyncedAt: timestamp,
                    conflictCount: visibleConflictCount,
                    deferredCount: result.deferred
                )
            )
            if result.downloaded > 0 || result.deleted > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .capsuleStoreDidChange,
                        object: self
                    )
                }
            }
        } catch {
            syncInFlight = false
            publishFailure(error, folderName: folderName)
            if case CapsuleCloudSyncError.conflict = error {
                requestSync(after: 1.0)
            }
        }
    }

    private func installTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + 20,
            repeating: 60,
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.performSync()
        }
        timer.resume()
        self.timer = timer
    }

    private func syncCompletionMessage(
        conflicts: Int,
        deferred: Int
    ) -> String {
        var details: [String] = []
        if conflicts > 0 {
            details.append("保留 \(conflicts) 个冲突")
        }
        if deferred > 0 {
            details.append("\(deferred) 个媒体等待本机文件")
        }
        return details.isEmpty ? "已同步" : "已同步，" + details.joined(separator: "，")
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .capsuleStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard (notification.object as AnyObject?) !== self else {
                return
            }
            self?.requestSync(after: 0.5)
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.requestSync(after: 0.25)
        })
        observers.append(center.addObserver(
            forName: Notification.Name.NSUbiquityIdentityDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.requestSync(after: 0.25)
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.requestSync(after: 0.25)
        })
    }

    private func publishFailure(
        _ error: Error,
        folderName: String?
    ) {
        publish(
            CapsuleCloudSyncStatus(
                phase: .failed,
                configured: engine != nil || status.isConfigured,
                folderName: folderName,
                message: error.localizedDescription,
                lastSyncedAt: status.lastSyncedAt,
                conflictCount: status.conflictCount,
                deferredCount: status.deferredCount
            )
        )
    }

    private func publish(_ status: CapsuleCloudSyncStatus) {
        statusLock.lock()
        statusStorage = status
        statusLock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .capsuleCloudSyncStatusDidChange,
                object: self
            )
        }
    }
}
