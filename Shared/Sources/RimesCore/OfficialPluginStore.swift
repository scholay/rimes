import Foundation
import CryptoKit

public struct OfficialPluginCatalog: Decodable {
    public struct Entry: Decodable, Identifiable {
        public let id, version, sha256, downloadAssetName, downloadURL: String
        public let nameZH, nameEN, kind: String
        public let platforms: [String: OfficialPluginPackage.Platform]
    }
    public let schemaVersion: Int
    public let releaseVersion: String
    public let plugins: [Entry]

    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json", subdirectory: "OfficialPlugins") else {
            throw OfficialPluginStateError.invalidPackage
        }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard catalog.schemaVersion == 1, Set(catalog.plugins.map(\.id)).count == catalog.plugins.count else {
            throw OfficialPluginStateError.invalidPackage
        }
        return catalog
    }

    public static func bundledData(_ entry: Entry) throws -> Data {
        guard let url = Bundle.module.url(forResource: entry.downloadAssetName, withExtension: nil, subdirectory: "OfficialPlugins") else {
            throw OfficialPluginStateError.invalidPackage
        }
        return try Data(contentsOf: url)
    }
}

public enum OfficialPluginStateError: Error, LocalizedError {
    case invalidPackage, unavailable, changed, invalidPath, downloadFailed
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "插件包校验失败 / Plugin package verification failed"
        case .unavailable: return "请先安装并启用插件 / Install and enable this plugin first"
        case .changed: return "插件状态已变化，请重试 / Plugin state changed; please retry"
        case .invalidPath: return "插件目录不可用 / Plugin directory is unavailable"
        case .downloadFailed: return "插件下载失败 / Plugin download failed"
        }
    }
}

/// The containing app writes installation state; keyboard extensions only read
/// it. Each immutable package and each receipt is replaced atomically. Secrets,
/// documents, dictionaries and configuration live outside this directory.
public final class OfficialPluginStore {
    public struct State: Codable, Equatable {
        public let installationID: String
        public let installed, enabled, bundled: Bool
        public let sha256: String
    }
    private struct Migration: Codable { let legacy: Bool }
    public let entries: [OfficialPluginCatalog.Entry]
    public let platform: String
    private let root: URL
    private let hostVersion: String
    private let legacyProfile: Bool
    private let loadBundled: (OfficialPluginCatalog.Entry) throws -> Data
    private let lock = NSRecursiveLock()

    public init(root: URL, platform: String, hostVersion: String,
                catalog: OfficialPluginCatalog, legacyProfile: Bool = false,
                bundledData: @escaping (OfficialPluginCatalog.Entry) throws -> Data = OfficialPluginCatalog.bundledData) {
        self.root = root.standardizedFileURL
        self.platform = platform; self.hostVersion = hostVersion
        entries = catalog.plugins.filter { $0.platforms[platform] != nil }
        self.legacyProfile = legacyProfile; loadBundled = bundledData
    }

    /// Call once from the containing app, before saving its first new profile.
    public func bootstrap() throws {
        lock.lock(); defer { lock.unlock() }
        let file = try safeFile("migration.json", create: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            try JSONEncoder().encode(Migration(legacy: legacyProfile)).write(to: file, options: .atomic)
        }
    }

    public func entry(legacyID: String) -> OfficialPluginCatalog.Entry? {
        entries.first { $0.platforms[platform]?.legacyID == legacyID }
    }

    public func state(_ id: String) -> State? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        guard let file = try? safeFile(id + ".state.json") else { return nil }
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? boundedRead(file, limit: 4096),
                  let state = try? JSONDecoder().decode(State.self, from: data),
                  state.sha256 == entry.sha256 else { return nil }
            return state
        }
        var legacy = legacyProfile
        guard let migrationFile = try? safeFile("migration.json") else { return nil }
        if FileManager.default.fileExists(atPath: migrationFile.path) {
            guard let data = try? boundedRead(migrationFile, limit: 4096),
                  let migration = try? JSONDecoder().decode(Migration.self, from: data) else { return nil }
            legacy = migration.legacy
        }
        let available = legacy || entry.platforms[platform]?.distribution == "bundled"
        return State(installationID: "bundled-" + entry.sha256, installed: available, enabled: available,
                     bundled: true, sha256: entry.sha256)
    }

    public func isEnabled(legacyID: String) -> Bool {
        guard let entry = entry(legacyID: legacyID), let state = state(entry.id), state.installed, state.enabled else { return false }
        return (try? package(entry.id)) != nil
    }

    public func package(_ id: String, requireEnabled: Bool = true) throws -> OfficialPluginPackage {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }), let state = state(id),
              state.installed, !requireEnabled || state.enabled else { throw OfficialPluginStateError.unavailable }
        let data = try state.bundled ? loadBundled(entry) : boundedRead(safeFile(id + ".json"), limit: OfficialPluginPackage.maximumBytes)
        return try verify(data, entry: entry)
    }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try package(id, requireEnabled: false)
        guard let old = state(id) else { throw OfficialPluginStateError.unavailable }
        try write(State(installationID: UUID().uuidString, installed: true, enabled: enabled,
                        bundled: old.bundled, sha256: old.sha256), id: id)
    }

    public func uninstall(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { throw OfficialPluginStateError.unavailable }
        // Revoke authorization before removing content. No unrelated user file
        // is deleted, even if a subsequent file operation fails.
        try write(State(installationID: UUID().uuidString, installed: false, enabled: false,
                        bundled: false, sha256: entry.sha256), id: id)
        let file = try safeFile(id + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public func install(_ data: Data, id: String, expectedState: State? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { throw OfficialPluginStateError.unavailable }
        _ = try verify(data, entry: entry)
        if let expectedState, state(id) != expectedState { throw OfficialPluginStateError.changed }
        try data.write(to: safeFile(id + ".json", create: true), options: .atomic)
        try write(State(installationID: UUID().uuidString, installed: true, enabled: false,
                        bundled: false, sha256: entry.sha256), id: id)
    }

    public func install(_ id: String) async throws {
        guard let entry = entries.first(where: { $0.id == id }), let before = state(id) else {
            throw OfficialPluginStateError.unavailable
        }
        let data: Data
        if entry.platforms[platform]?.distribution == "bundled" {
            data = try loadBundled(entry)
        } else {
            guard let url = URL(string: entry.downloadURL), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/scholay/rimes-plugins/releases/download/v"),
                  url.lastPathComponent == entry.downloadAssetName else { throw OfficialPluginStateError.invalidPackage }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url?.scheme == "https", response.expectedContentLength <= OfficialPluginPackage.maximumBytes else {
                throw OfficialPluginStateError.downloadFailed
            }
            var received = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard received.count < OfficialPluginPackage.maximumBytes else { throw OfficialPluginStateError.invalidPackage }
                received.append(byte)
            }
            data = received
        }
        try Task.checkCancellation()
        try install(data, id: id, expectedState: before)
    }

    private func verify(_ data: Data, entry: OfficialPluginCatalog.Entry) throws -> OfficialPluginPackage {
        guard data.count <= OfficialPluginPackage.maximumBytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw OfficialPluginStateError.invalidPackage
        }
        return try .validated(data, expectedID: entry.id, expectedVersion: entry.version,
                              platform: platform, hostVersion: hostVersion)
    }

    private func write(_ state: State, id: String) throws {
        try JSONEncoder().encode(state).write(to: safeFile(id + ".state.json", create: true), options: .atomic)
    }

    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw OfficialPluginStateError.invalidPackage }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw OfficialPluginStateError.invalidPackage }
        return data
    }

    private func safeFile(_ name: String, create: Bool = false) throws -> URL {
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw OfficialPluginStateError.invalidPath
        }
        var current = root
        while current.path != "/" {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                // Darwin exposes /var and /tmp as fixed system aliases even
                // after URL.resolvingSymlinksInPath(). Do not reject app-group
                // containers merely because they use that OS-owned spelling.
                let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                let systemAlias = (current.path == "/var" && ["private/var", "/private/var"].contains(destination ?? ""))
                    || (current.path == "/tmp" && ["private/tmp", "/private/tmp"].contains(destination ?? ""))
                guard systemAlias else { throw OfficialPluginStateError.invalidPath }
            }
            current.deleteLastPathComponent()
        }
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let file = root.appendingPathComponent(name)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw OfficialPluginStateError.invalidPath
        }
        return file
    }
}
