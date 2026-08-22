import CryptoKit
import Foundation
import Darwin

struct PresetBufferPluginCatalogEntry: Equatable {
    let id: String
    let nameZH: String
    let nameEN: String
    let version: String
    let summaryZH: String
    let summaryEN: String
    let defaultInstalled: Bool
    let defaultEnabled: Bool
    let downloadAssetName: String?
    let sha256: String?

    var isDownloadable: Bool {
        !defaultInstalled && downloadAssetName != nil && sha256 != nil
    }
}

struct PresetBufferPluginPackageManifest: Codable, Equatable {
    let schemaVersion: Int
    let id: String
    let version: String
    let nameZH: String
    let nameEN: String
    let summaryZH: String
    let summaryEN: String
}

/// Host-owned installation identity committed in the same directory rename as
/// the downloaded manifest. An old enablement grant cannot authorize a newly
/// published receipt even when a reinstall uses byte-identical manifest data.
private struct PresetBufferPluginInstalledReceipt: Codable, Equatable {
    let schemaVersion: Int
    let sha256: String
    let installationID: String
    let enabled: Bool
}

enum PresetBufferPluginInstallationError: LocalizedError, Equatable {
    case unknownPlugin(String)
    case alreadyBundled(String)
    case notDownloadable(String)
    case downloadInProgress(String)
    case staleDownload
    case invalidDownloadURL
    case invalidDigest
    case invalidManifest
    case unsafeInstallPath(String)
    case fileOperation(String)

    var errorDescription: String? {
        switch self {
        case let .unknownPlugin(id):
            return "未知的预置插件：\(id)"
        case let .alreadyBundled(id):
            return "插件已经随 RIMES 预装：\(id)"
        case let .notDownloadable(id):
            return "插件没有可用的 GitHub 下载包：\(id)"
        case let .downloadInProgress(id):
            return "插件正在下载：\(id)"
        case .staleDownload:
            return "下载期间插件状态已变化，请重试"
        case .invalidDownloadURL:
            return "插件下载地址必须是可信的 HTTPS GitHub 地址"
        case .invalidDigest:
            return "插件包校验失败，文件可能已更新或损坏"
        case .invalidManifest:
            return "插件包的标识或版本与内置目录不一致"
        case let .unsafeInstallPath(path):
            return "插件安装路径不安全：\(path)"
        case let .fileOperation(message):
            return "插件安装失败：\(message)"
        }
    }
}

/// Installation receipts for optional first-party buffer plugins.
///
/// Their Swift runtime remains compiled into the signed input method. The
/// downloaded package is deliberately declarative: it is hash-pinned by the
/// host catalog and can never inject or execute network-provided code inside
/// the long-lived IMK process.
final class PresetBufferPluginInstallationStore {
    static let didChangeNotification = Notification.Name(
        "RimeBuffer.PresetBufferPluginInstallation.didChange"
    )
    static let rootPathUserInfoKey = "rootPath"
    static let changedPluginIDUserInfoKey = "pluginID"

    private enum DefaultsKey {
        static let migrated = "plugins.internal.presetDistribution.migrated.v1"
        static let grandfathered = "plugins.internal.presetDistribution.grandfathered.v1"
        // This legacy ID-only set is authoritative only for grandfathered
        // profiles, whose optional plug-ins predate downloadable receipts.
        static let enabledOptional = "plugins.internal.presetDistribution.enabledOptional.v1"
    }

    static let shared = PresetBufferPluginInstallationStore()

    let rootURL: URL

    private let defaults: UserDefaults
    private let catalogEntries: [PresetBufferPluginCatalogEntry]
    private let fileManager: FileManager
    private let downloader: ActionPluginManifestDownloading
    private let completionQueue: DispatchQueue
    private let hostVersion: String
    private let willCommitInstallation: (() -> Void)?
    private let workQueue = DispatchQueue(
        label: "com.isaac.rimebuffer.preset-plugin-install",
        qos: .utility
    )
    // Serializes enablement grants, generation checks, and the final receipt
    // rename. Invalidation therefore happens entirely before or after a commit.
    private let stateLock = NSRecursiveLock()
    private var inFlightPluginIDs: Set<String> = []
    private var mutationGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard,
         rootURL: URL = PresetBufferPluginInstallationStore.defaultRootURL(),
         fileManager: FileManager = .default,
         downloader: ActionPluginManifestDownloading = ActionPluginHTTPSManifestDownloader(),
         completionQueue: DispatchQueue = .main,
         hostVersion: String = PresetBufferPluginInstallationStore.currentHostVersion(),
         willCommitInstallation: (() -> Void)? = nil,
         catalogEntries: [PresetBufferPluginCatalogEntry] = PresetBufferPluginCatalog.entries) {
        self.defaults = defaults
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.downloader = downloader
        self.completionQueue = completionQueue
        self.hostVersion = hostVersion
        self.willCommitInstallation = willCommitInstallation
        self.catalogEntries = catalogEntries
    }

    static func currentHostVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
    }

    static func defaultRootURL() -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"],
           !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        }
        return base.appendingPathComponent("preset-plugins", isDirectory: true)
    }

    var defaultInstalledIDs: Set<String> {
        Set(catalogEntries.lazy
            .filter(\.defaultInstalled)
            .map(\.id))
    }

    var defaultEnabledIDs: Set<String> {
        Set(catalogEntries.lazy
            .filter { $0.defaultInstalled && $0.defaultEnabled }
            .map(\.id))
    }

    var optionalIDs: Set<String> {
        Set(catalogEntries.lazy
            .filter { !$0.defaultInstalled }
            .map(\.id))
    }

    /// Existing installations ran a version where every compiled-in plugin
    /// was considered installed. Preserve that contract exactly once. A truly
    /// fresh profile instead starts with the catalog's default plugins.
    func bootstrap(hadLegacyEnablement: Bool,
                   legacyDisabledIDs: Set<String>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let knownOptional = optionalIDs
        if !defaults.bool(forKey: DefaultsKey.migrated) {
            let grandfathered = hadLegacyEnablement ? knownOptional : []
            let enabled = hadLegacyEnablement
                ? knownOptional.subtracting(legacyDisabledIDs)
                : []
            defaults.set(grandfathered.sorted(), forKey: DefaultsKey.grandfathered)
            defaults.set(enabled.sorted(), forKey: DefaultsKey.enabledOptional)
            defaults.set(true, forKey: DefaultsKey.migrated)
            return
        }

        // Sanitize stale IDs left by a removed or renamed catalog entry.
        let grandfathered = Set(
            defaults.stringArray(forKey: DefaultsKey.grandfathered) ?? []
        ).intersection(knownOptional)
        // An old ID-only enablement must never authorize a downloaded receipt.
        // It remains valid solely for the grandfathered no-receipt path.
        let enabledGrandfathered = Set(
            defaults.stringArray(forKey: DefaultsKey.enabledOptional) ?? []
        ).intersection(grandfathered)
        defaults.set(grandfathered.sorted(), forKey: DefaultsKey.grandfathered)
        defaults.set(enabledGrandfathered.sorted(),
                     forKey: DefaultsKey.enabledOptional)

    }

    func catalogEntry(id: String) -> PresetBufferPluginCatalogEntry? {
        catalogEntries.first { $0.id == id }
    }

    func isManagedPreset(id: String) -> Bool {
        catalogEntry(id: id) != nil
    }

    func isOptional(id: String) -> Bool {
        catalogEntry(id: id)?.defaultInstalled == false
    }

    func isInstalled(id: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isInstalledLocked(id: id)
    }

    private func isInstalledLocked(id: String) -> Bool {
        guard let entry = catalogEntry(id: id) else { return true }
        if entry.defaultInstalled { return true }
        let grandfathered = Set(
            defaults.stringArray(forKey: DefaultsKey.grandfathered) ?? []
        )
        if grandfathered.contains(id) { return true }
        return validatedInstalledManifest(for: entry) != nil
    }

    func isOptionalEnabled(id: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isOptionalEnabledLocked(id: id)
    }

    private func isOptionalEnabledLocked(id: String) -> Bool {
        guard let entry = catalogEntry(id: id),
              !entry.defaultInstalled,
              isInstalledLocked(id: id) else { return false }
        let grandfathered = Set(
            defaults.stringArray(forKey: DefaultsKey.grandfathered) ?? []
        )
        if grandfathered.contains(id) {
            return Set(
                defaults.stringArray(forKey: DefaultsKey.enabledOptional) ?? []
            ).contains(id)
        }
        guard let receipt = validatedInstalledReceipt(for: entry) else {
            return false
        }
        return receipt.enabled
    }

    @discardableResult
    func setOptionalEnabled(_ enabled: Bool, id: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = catalogEntry(id: id),
              !entry.defaultInstalled,
              isInstalledLocked(id: id) else { return false }
        let grandfathered = Set(
            defaults.stringArray(forKey: DefaultsKey.grandfathered) ?? []
        )
        let changed: Bool
        if grandfathered.contains(id) {
            var enabledIDs = Set(
                defaults.stringArray(forKey: DefaultsKey.enabledOptional) ?? []
            ).intersection(grandfathered)
            changed = enabled
                ? enabledIDs.insert(id).inserted
                : enabledIDs.remove(id) != nil
            if changed {
                defaults.set(enabledIDs.sorted(),
                             forKey: DefaultsKey.enabledOptional)
            }
        } else {
            guard let receipt = validatedInstalledReceipt(for: entry) else {
                return false
            }
            changed = receipt.enabled != enabled
            guard changed else { return false }
            let updated = PresetBufferPluginInstalledReceipt(
                schemaVersion: receipt.schemaVersion,
                sha256: receipt.sha256,
                installationID: receipt.installationID,
                enabled: enabled
            )
            guard persistInstalledReceiptLocked(updated, for: entry) else {
                return false
            }
        }
        guard changed else { return false }
        mutationGeneration &+= 1
        return true
    }

    func install(id: String,
                 completion: @escaping (Result<PresetBufferPluginCatalogEntry, Error>) -> Void) {
        guard let entry = catalogEntry(id: id) else {
            finish(completion, with: .failure(
                PresetBufferPluginInstallationError.unknownPlugin(id)
            ))
            return
        }
        guard !entry.defaultInstalled else {
            finish(completion, with: .failure(
                PresetBufferPluginInstallationError.alreadyBundled(id)
            ))
            return
        }
        if isInstalled(id: id) {
            finish(completion, with: .success(entry))
            return
        }
        guard let url = Self.catalogDownloadURL(
                for: entry,
                hostVersion: hostVersion
              ),
              Self.isAllowedCatalogURL(
                url,
                entry: entry,
                hostVersion: hostVersion
              ),
              entry.sha256?.count == 64 else {
            finish(completion, with: .failure(
                PresetBufferPluginInstallationError.notDownloadable(id)
            ))
            return
        }

        stateLock.lock()
        let inserted = inFlightPluginIDs.insert(id).inserted
        let requestedGeneration = mutationGeneration
        stateLock.unlock()
        guard inserted else {
            finish(completion, with: .failure(
                PresetBufferPluginInstallationError.downloadInProgress(id)
            ))
            return
        }

        downloader.downloadManifest(from: url) { [weak self] result in
            guard let self else { return }
            self.workQueue.async {
                let installed: Result<PresetBufferPluginCatalogEntry, Error>
                do {
                    let data = try result.get()
                    try self.validateDownloadedPackage(data, for: entry)

                    self.stateLock.lock()
                    do {
                        guard self.mutationGeneration == requestedGeneration else {
                            throw PresetBufferPluginInstallationError.staleDownload
                        }
                        // Test seam runs while holding the same lock as the
                        // final generation check and filesystem publication.
                        self.willCommitInstallation?()
                        try self.installAtomically(data, for: entry)
                        self.mutationGeneration &+= 1
                        self.stateLock.unlock()
                    } catch {
                        self.stateLock.unlock()
                        throw error
                    }
                    installed = .success(entry)
                } catch {
                    installed = .failure(error)
                }
                self.stateLock.lock()
                self.inFlightPluginIDs.remove(id)
                self.stateLock.unlock()
                self.completionQueue.async {
                    if case .success = installed {
                        NotificationCenter.default.post(
                            name: Self.didChangeNotification,
                            object: self,
                            userInfo: [
                                Self.rootPathUserInfoKey: self.rootURL.path,
                                Self.changedPluginIDUserInfoKey: id,
                            ]
                        )
                    }
                    completion(installed)
                }
            }
        }
    }

    /// Invalidates delayed downloads when a newer catalog or state mutation
    /// wins. Production currently has no uninstall surface, but the seam keeps
    /// future update/disable flows from resurrecting stale receipts.
    func invalidatePendingInstalls() {
        stateLock.lock()
        mutationGeneration &+= 1
        stateLock.unlock()
    }

    private func finish(
        _ completion: @escaping (Result<PresetBufferPluginCatalogEntry, Error>) -> Void,
        with result: Result<PresetBufferPluginCatalogEntry, Error>
    ) {
        completionQueue.async { completion(result) }
    }

    private func validateDownloadedPackage(
        _ data: Data,
        for entry: PresetBufferPluginCatalogEntry
    ) throws {
        guard data.count <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
            throw PresetBufferPluginInstallationError.invalidManifest
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == entry.sha256?.lowercased() else {
            throw PresetBufferPluginInstallationError.invalidDigest
        }
        guard let manifest = try? JSONDecoder().decode(
            PresetBufferPluginPackageManifest.self,
            from: data
        ), manifest.schemaVersion == 1,
           manifest.id == entry.id,
           manifest.version == entry.version,
           manifest.nameZH == entry.nameZH,
           manifest.nameEN == entry.nameEN,
           manifest.summaryZH == entry.summaryZH,
           manifest.summaryEN == entry.summaryEN else {
            throw PresetBufferPluginInstallationError.invalidManifest
        }
    }

    private func installAtomically(
        _ data: Data,
        for entry: PresetBufferPluginCatalogEntry
    ) throws {
        guard Self.pathHasNoUntrustedSymlink(rootURL) else {
            throw PresetBufferPluginInstallationError.unsafeInstallPath(rootURL.path)
        }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard Self.pathHasNoUntrustedSymlink(rootURL) else {
                throw PresetBufferPluginInstallationError.unsafeInstallPath(rootURL.path)
            }
            let destination = rootURL.appendingPathComponent(entry.id, isDirectory: true)
            guard destination.deletingLastPathComponent().standardizedFileURL == rootURL,
                  Self.pathHasNoUntrustedSymlink(destination) else {
                throw PresetBufferPluginInstallationError.unsafeInstallPath(destination.path)
            }
            let staging = rootURL.appendingPathComponent(
                ".install-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            do {
                let manifestURL = staging.appendingPathComponent("manifest.json")
                try data.write(to: manifestURL, options: .atomic)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: manifestURL.path
                )
                try validateDownloadedPackage(data, for: entry)
                guard let digest = entry.sha256?.lowercased() else {
                    throw PresetBufferPluginInstallationError.invalidDigest
                }
                let receipt = PresetBufferPluginInstalledReceipt(
                    schemaVersion: 1,
                    sha256: digest,
                    installationID: UUID().uuidString.lowercased(),
                    enabled: false
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let receiptData = try encoder.encode(receipt)
                let receiptURL = staging.appendingPathComponent("receipt.json")
                try receiptData.write(to: receiptURL, options: .atomic)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: receiptURL.path
                )
                if fileManager.fileExists(atPath: destination.path) {
                    let backupName = ".backup-\(UUID().uuidString.lowercased())"
                    _ = try fileManager.replaceItemAt(
                        destination,
                        withItemAt: staging,
                        backupItemName: backupName,
                        options: []
                    )
                    let backup = rootURL.appendingPathComponent(
                        backupName,
                        isDirectory: true
                    )
                    try? fileManager.removeItem(at: backup)
                } else {
                    try fileManager.moveItem(at: staging, to: destination)
                }
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        } catch let error as PresetBufferPluginInstallationError {
            throw error
        } catch {
            throw PresetBufferPluginInstallationError.fileOperation(
                error.localizedDescription
            )
        }
    }

    private func validatedInstalledManifest(
        for entry: PresetBufferPluginCatalogEntry
    ) -> PresetBufferPluginPackageManifest? {
        guard validatedInstalledReceipt(for: entry) != nil else { return nil }
        let directory = rootURL.appendingPathComponent(entry.id, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard Self.pathHasNoUntrustedSymlink(rootURL),
              Self.pathHasNoUntrustedSymlink(directory),
              Self.pathHasNoUntrustedSymlink(manifestURL),
              let values = try? manifestURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes,
              let data = try? Data(contentsOf: manifestURL, options: [.mappedIfSafe, .uncached]),
              (try? validateDownloadedPackage(data, for: entry)) != nil else {
            return nil
        }
        return try? JSONDecoder().decode(
            PresetBufferPluginPackageManifest.self,
            from: data
        )
    }

    private func validatedInstalledReceipt(
        for entry: PresetBufferPluginCatalogEntry
    ) -> PresetBufferPluginInstalledReceipt? {
        let directory = rootURL.appendingPathComponent(entry.id, isDirectory: true)
        let receiptURL = directory.appendingPathComponent("receipt.json")
        guard Self.pathHasNoUntrustedSymlink(rootURL),
              Self.pathHasNoUntrustedSymlink(directory),
              Self.pathHasNoUntrustedSymlink(receiptURL),
              let values = try? receiptURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
              ]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 4_096,
              let data = try? Data(contentsOf: receiptURL,
                                   options: [.mappedIfSafe, .uncached]),
              data.count <= 4_096,
              let receipt = try? JSONDecoder().decode(
                PresetBufferPluginInstalledReceipt.self,
                from: data
              ),
              receipt.schemaVersion == 1,
              receipt.sha256 == entry.sha256?.lowercased(),
              let parsedID = UUID(uuidString: receipt.installationID),
              parsedID.uuidString.lowercased() == receipt.installationID else {
            return nil
        }
        return receipt
    }

    private func persistInstalledReceiptLocked(
        _ receipt: PresetBufferPluginInstalledReceipt,
        for entry: PresetBufferPluginCatalogEntry
    ) -> Bool {
        let directory = rootURL.appendingPathComponent(entry.id, isDirectory: true)
        let receiptURL = directory.appendingPathComponent("receipt.json")
        guard Self.pathHasNoUntrustedSymlink(rootURL),
              Self.pathHasNoUntrustedSymlink(directory),
              Self.pathHasNoUntrustedSymlink(receiptURL),
              validatedInstalledManifest(for: entry) != nil,
              let data = try? JSONEncoder().encode(receipt) else {
            return false
        }
        do {
            try data.write(to: receiptURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: receiptURL.path
            )
            return validatedInstalledReceipt(for: entry) == receipt
        } catch {
            return false
        }
    }

    private static func catalogDownloadURL(
        for entry: PresetBufferPluginCatalogEntry,
        hostVersion: String
    ) -> URL? {
        guard isReleaseVersion(hostVersion),
              let assetName = entry.downloadAssetName,
              assetName == "preset-plugin-\(entry.id)-\(entry.version).json" else {
            return nil
        }
        return URL(
            string: "https://github.com/scholay/rimes/releases/download/"
                + "v\(hostVersion)/\(assetName)"
        )
    }

    private static func isAllowedCatalogURL(
        _ url: URL,
        entry: PresetBufferPluginCatalogEntry,
        hostVersion: String
    ) -> Bool {
        guard let assetName = entry.downloadAssetName,
              isReleaseVersion(hostVersion) else { return false }
        let expectedPath = "/scholay/rimes/releases/download/v\(hostVersion)/"
            + assetName
        return ActionPluginHTTPSManifestDownloader.isAllowedDownloadURL(url)
            && url.host?.lowercased() == "github.com"
            && url.port == nil
            && url.query == nil
            && url.path == expectedPath
    }

    private static func isReleaseVersion(_ value: String) -> Bool {
        value.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func pathHasNoUntrustedSymlink(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let trustedSystemLinks = [
            "/var": "/private/var",
            "/tmp": "/private/tmp",
            "/etc": "/private/etc",
        ]
        let standardized = url.standardizedFileURL
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in standardized.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard let expectedTarget = trustedSystemLinks[current.path],
                          let rawTarget = try? FileManager.default
                            .destinationOfSymbolicLink(atPath: current.path) else {
                        return false
                    }
                    let targetURL = rawTarget.hasPrefix("/")
                        ? URL(fileURLWithPath: rawTarget)
                        : current.deletingLastPathComponent()
                            .appendingPathComponent(rawTarget)
                    guard targetURL.standardized.path == expectedTarget else {
                        return false
                    }
                }
                continue
            }
            if errno == ENOENT { break }
            return false
        }
        return true
    }
}
