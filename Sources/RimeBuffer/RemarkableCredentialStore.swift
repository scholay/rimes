import Darwin
import Foundation

extension Notification.Name {
    static let remarkableConfigurationDidChange = Notification.Name(
        "RimeBuffer.RemarkableConfiguration.didChange"
    )
}

enum RemarkableCredentialStoreError: LocalizedError, Equatable {
    case unsafePath
    case invalidPermissions
    case unreadable
    case oversized
    case unsupportedSchema
    case invalidHost
    case invalidUsername
    case invalidPassword

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "reMarkable 凭据路径不安全"
        case .invalidPermissions:
            return "reMarkable 凭据目录或文件权限不安全"
        case .unreadable:
            return "无法读取或保存 reMarkable 凭据"
        case .oversized:
            return "reMarkable 凭据文件过大"
        case .unsupportedSchema:
            return "reMarkable 凭据版本不受支持"
        case .invalidHost:
            return "reMarkable SSH 主机格式无效"
        case .invalidUsername:
            return "reMarkable SSH 用户名格式无效"
        case .invalidPassword:
            return "reMarkable SSH 密码格式无效"
        }
    }
}

/// Complete user-editable SSH configuration. String conversion and reflection
/// are deliberately redacted; the value is only persisted by
/// `RemarkableCredentialStore` in its mode-0600 file.
struct RemarkableSSHConfiguration: Codable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let currentSchemaVersion = 1
    static let maximumPasswordBytes = 4 * 1_024

    let schemaVersion: Int
    let host: String
    let username: String
    let password: String

    init(host: String,
         username: String,
         password: String,
         schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.host = host
        self.username = username
        self.password = password
    }

    func validated() throws -> RemarkableSSHConfiguration {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RemarkableCredentialStoreError.unsupportedSchema
        }
        guard RemarkableSSHTarget.isValidHostOrAlias(host) else {
            throw RemarkableCredentialStoreError.invalidHost
        }
        guard RemarkableSSHTarget.isValidUsername(username) else {
            throw RemarkableCredentialStoreError.invalidUsername
        }
        let passwordBytes = password.utf8.count
        guard passwordBytes <= Self.maximumPasswordBytes,
              !password.contains("\0"),
              !password.contains("\r"),
              !password.contains("\n") else {
            throw RemarkableCredentialStoreError.invalidPassword
        }
        return self
    }

    var description: String { "<redacted reMarkable SSH configuration>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(
            self,
            children: ["configuration": description],
            displayStyle: .struct
        )
    }
}

/// Ad-hoc signed input-method rebuilds cannot use a stable Keychain ACL without
/// repeated prompts. Until the app has a stable Developer ID identity, this
/// store keeps the SSH password in a private JSON file:
///
///   ~/Library/RimeBuffer/plugin-config/builtin.remarkable/credentials.json
///
/// The shared `~/Library/RimeBuffer` root may use a safe non-writable 0755
/// mode. The private directories below it are mode 0700 and the credential is
/// atomically replaced as a mode-0600 regular file.
final class RemarkableCredentialStore {
    static let shared = RemarkableCredentialStore()

    private static let maximumFileBytes = 16 * 1_024
    private static let temporaryFilePrefix = ".credentials."
    private static let temporaryFileSuffix = ".tmp"

    private let fileManager: FileManager
    let rootDirectory: URL
    let configurationDirectoryURL: URL
    let configurationURL: URL

    init(rootDirectory: URL? = nil,
         fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let selectedRoot: URL
        if let rootDirectory {
            selectedRoot = rootDirectory
        } else if let override =
            ProcessInfo.processInfo.environment["RIMEBUFFER_LOCAL_DATA_ROOT"],
                  !override.isEmpty {
            selectedRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            selectedRoot = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        }
        self.rootDirectory = selectedRoot.standardizedFileURL
        configurationDirectoryURL = self.rootDirectory
            .appendingPathComponent("plugin-config", isDirectory: true)
            .appendingPathComponent("builtin.remarkable", isDirectory: true)
        configurationURL = configurationDirectoryURL
            .appendingPathComponent("credentials.json", isDirectory: false)
    }

    func load() throws -> RemarkableSSHConfiguration? {
        var info = stat()
        if lstat(configurationURL.path, &info) != 0 {
            if errno == ENOENT {
                var directoryInfo = stat()
                if lstat(configurationDirectoryURL.path, &directoryInfo) == 0 {
                    try validateSharedRootDirectory(rootDirectory)
                    try validatePrivateDirectory(
                        configurationDirectoryURL.deletingLastPathComponent()
                    )
                    try validatePrivateDirectory(configurationDirectoryURL)
                    try cleanupOrphanedTemporaryFiles()
                } else if errno != ENOENT {
                    throw RemarkableCredentialStoreError.unreadable
                }
                return nil
            }
            throw RemarkableCredentialStoreError.unreadable
        }
        try validateSharedRootDirectory(rootDirectory)
        try validatePrivateDirectory(
            configurationDirectoryURL.deletingLastPathComponent()
        )
        try validatePrivateDirectory(configurationDirectoryURL)
        try cleanupOrphanedTemporaryFiles()
        return try Self.readConfiguration(at: configurationURL)
    }

    func editableConfiguration(
        fallingBackTo defaults: UserDefaults
    ) throws -> RemarkableSSHConfiguration {
        if let saved = try load() {
            return saved
        }
        let legacyTarget = try RemarkableSSHTarget.configured(in: defaults)
        return RemarkableSSHConfiguration(
            host: legacyTarget.host,
            username: legacyTarget.username ?? "root",
            password: ""
        )
    }

    func configuredTarget(
        fallingBackTo defaults: UserDefaults
    ) throws -> RemarkableSSHTarget {
        guard let configuration = try load() else {
            return try RemarkableSSHTarget.configured(in: defaults)
        }
        let validated = try configuration.validated()
        return try RemarkableSSHTarget(
            username: validated.username,
            host: validated.host,
            passwordCredentialURL: validated.password.isEmpty
                ? nil
                : configurationURL
        )
    }

    func save(_ configuration: RemarkableSSHConfiguration) throws {
        let validated = try configuration.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= Self.maximumFileBytes else {
            throw RemarkableCredentialStoreError.oversized
        }

        try ensureSharedRootDirectory(rootDirectory)
        let pluginConfigRoot =
            configurationDirectoryURL.deletingLastPathComponent()
        try ensurePrivateDirectory(pluginConfigRoot)
        try ensurePrivateDirectory(configurationDirectoryURL)
        try cleanupOrphanedTemporaryFiles()
        try rejectExistingNonRegularFile(at: configurationURL)

        let temporaryURL = configurationDirectoryURL.appendingPathComponent(
            "\(Self.temporaryFilePrefix)\(UUID().uuidString)"
                + Self.temporaryFileSuffix,
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink {
                unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw RemarkableCredentialStoreError.unreadable
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0,
              rename(temporaryURL.path, configurationURL.path) == 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        shouldUnlink = false
        defer {
            NotificationCenter.default.post(
                name: .remarkableConfigurationDidChange,
                object: self
            )
        }
        try synchronizeConfigurationDirectory()
    }

    func delete() throws {
        var info = stat()
        if lstat(configurationURL.path, &info) != 0 {
            if errno == ENOENT { return }
            throw RemarkableCredentialStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw RemarkableCredentialStoreError.unsafePath
        }
        try validateSharedRootDirectory(rootDirectory)
        try validatePrivateDirectory(
            configurationDirectoryURL.deletingLastPathComponent()
        )
        try validatePrivateDirectory(configurationDirectoryURL)
        guard unlink(configurationURL.path) == 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        defer {
            NotificationCenter.default.post(
                name: .remarkableConfigurationDidChange,
                object: self
            )
        }
        try synchronizeConfigurationDirectory()
    }

    /// Used by the tiny SSH_ASKPASS launch path. It never logs or describes the
    /// decoded value and follows no symlink at the final path component.
    static func readConfiguration(
        at configurationURL: URL
    ) throws -> RemarkableSSHConfiguration {
        let path = configurationURL.standardizedFileURL.path
        let pluginDirectory = configurationURL.deletingLastPathComponent()
            .standardizedFileURL
        let pluginConfigDirectory = pluginDirectory.deletingLastPathComponent()
            .standardizedFileURL
        let rootDirectory = pluginConfigDirectory.deletingLastPathComponent()
            .standardizedFileURL
        guard rootDirectory.path != "/",
              pluginConfigDirectory.path != rootDirectory.path,
              pluginDirectory.path != pluginConfigDirectory.path else {
            throw RemarkableCredentialStoreError.unsafePath
        }
        try validateSharedRootDirectory(rootDirectory)
        for directory in [pluginConfigDirectory, pluginDirectory] {
            try validatePrivateDirectory(directory)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw RemarkableCredentialStoreError.unsafePath
        }
        guard (info.st_mode & 0o777) == 0o600 else {
            throw RemarkableCredentialStoreError.invalidPermissions
        }
        guard info.st_size >= 0,
              info.st_size <= Self.maximumFileBytes else {
            throw RemarkableCredentialStoreError.oversized
        }

        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        defer { close(descriptor) }
        var openedInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              (openedInfo.st_mode & S_IFMT) == S_IFREG,
              openedInfo.st_uid == geteuid(),
              openedInfo.st_dev == info.st_dev,
              openedInfo.st_ino == info.st_ino else {
            throw RemarkableCredentialStoreError.unsafePath
        }

        var data = Data()
        data.reserveCapacity(Int(openedInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RemarkableCredentialStoreError.unreadable
            }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumFileBytes else {
                throw RemarkableCredentialStoreError.oversized
            }
        }
        do {
            return try JSONDecoder()
                .decode(RemarkableSSHConfiguration.self, from: data)
                .validated()
        } catch let error as RemarkableCredentialStoreError {
            throw error
        } catch {
            throw RemarkableCredentialStoreError.unreadable
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw RemarkableCredentialStoreError.unsafePath
            }
        } else {
            guard errno == ENOENT else {
                throw RemarkableCredentialStoreError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw RemarkableCredentialStoreError.unreadable
            }
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw RemarkableCredentialStoreError.unsafePath
            }
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw RemarkableCredentialStoreError.invalidPermissions
        }
    }

    private func ensureSharedRootDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw RemarkableCredentialStoreError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw RemarkableCredentialStoreError.unreadable
            }
        }
        try Self.validateSharedRootDirectory(url)
    }

    private func validateSharedRootDirectory(_ url: URL) throws {
        try Self.validateSharedRootDirectory(url)
    }

    private static func validateSharedRootDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw RemarkableCredentialStoreError.unsafePath
        }
        let permissions = info.st_mode & 0o777
        guard (permissions & 0o700) == 0o700,
              (permissions & 0o022) == 0 else {
            throw RemarkableCredentialStoreError.invalidPermissions
        }
    }

    private func validatePrivateDirectory(_ url: URL) throws {
        try Self.validatePrivateDirectory(url)
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw RemarkableCredentialStoreError.unsafePath
        }
        guard (info.st_mode & 0o777) == 0o700 else {
            throw RemarkableCredentialStoreError.invalidPermissions
        }
    }

    private func rejectExistingNonRegularFile(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw RemarkableCredentialStoreError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw RemarkableCredentialStoreError.unsafePath
        }
    }

    private func cleanupOrphanedTemporaryFiles() throws {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(
                atPath: configurationDirectoryURL.path
            )
        } catch {
            throw RemarkableCredentialStoreError.unreadable
        }

        var removedAny = false
        for name in names where Self.isTemporaryCredentialFileName(name) {
            let url = configurationDirectoryURL.appendingPathComponent(
                name,
                isDirectory: false
            )
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw RemarkableCredentialStoreError.unreadable
            }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o600 else {
                throw RemarkableCredentialStoreError.unsafePath
            }
            if unlink(url.path) != 0 {
                if errno == ENOENT { continue }
                throw RemarkableCredentialStoreError.unreadable
            }
            removedAny = true
        }
        if removedAny {
            try synchronizeConfigurationDirectory()
        }
    }

    private static func isTemporaryCredentialFileName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryFilePrefix),
              name.hasSuffix(temporaryFileSuffix) else {
            return false
        }
        let start = name.index(
            name.startIndex,
            offsetBy: temporaryFilePrefix.count
        )
        let end = name.index(
            name.endIndex,
            offsetBy: -temporaryFileSuffix.count
        )
        let token = String(name[start..<end])
        return token.utf8.count == 36 && UUID(uuidString: token) != nil
    }

    private func synchronizeConfigurationDirectory() throws {
        let descriptor = open(
            configurationDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o700,
              fsync(descriptor) == 0 else {
            throw RemarkableCredentialStoreError.unreadable
        }
    }
}

enum RemarkablePluginConfigurationFieldID {
    static let host = "host"
    static let username = "username"
    static let password = "password"
}

/// Adapter between the declarative plugin-settings form and the dedicated
/// SSH credential document. This keeps the generic settings UI without ever
/// creating a second copy of the password in the generic private JSON store.
final class RemarkablePluginConfigurationStore: PluginConfigurationStoring {
    let supportsSecureValues = true

    private let credentialStore: RemarkableCredentialStore
    private let defaults: UserDefaults

    init(credentialStore: RemarkableCredentialStore = .shared,
         defaults: UserDefaults = .standard) {
        self.credentialStore = credentialStore
        self.defaults = defaults
    }

    func validate(schema: PluginConfigurationSchema) throws {
        guard schema.pluginID == BuiltInPluginID.remarkable else {
            throw PluginConfigurationError.invalidSchema(
                "reMarkable 配置标识不匹配"
            )
        }
        let knownFields = Set(schema.fields.map(\.id))
        guard knownFields.contains(
                  RemarkablePluginConfigurationFieldID.host
              ),
              knownFields.contains(
                  RemarkablePluginConfigurationFieldID.username
              ),
              let passwordField = schema.fields.first(where: {
                  $0.id == RemarkablePluginConfigurationFieldID.password
              }),
              passwordField.kind.isSecure else {
            throw PluginConfigurationError.invalidSchema(
                "reMarkable 配置字段不完整"
            )
        }
    }

    func load(schema: PluginConfigurationSchema) throws
        -> PluginConfigurationSnapshot? {
        if let saved = try credentialStore.load() {
            return Self.snapshot(from: saved)
        }
        // Preserve an explicitly configured pre-settings-platform destination.
        // When no legacy override exists, returning nil lets the schema supply
        // its declared USB defaults.
        guard defaults.object(
            forKey: RemarkableSSHTarget.defaultsKey
        ) != nil else {
            return nil
        }
        let target = try RemarkableSSHTarget.configured(in: defaults)
        return Self.snapshot(from: RemarkableSSHConfiguration(
            host: target.host,
            username: target.username ?? "root",
            password: ""
        ))
    }

    func save(_ snapshot: PluginConfigurationSnapshot,
              schema: PluginConfigurationSchema) throws {
        guard let host = snapshot.string(
                  RemarkablePluginConfigurationFieldID.host
              ),
              let username = snapshot.string(
                  RemarkablePluginConfigurationFieldID.username
              ),
              let password = snapshot.string(
                  RemarkablePluginConfigurationFieldID.password
              ) else {
            throw PluginConfigurationError.corruptDocument
        }
        let configuration = RemarkableSSHConfiguration(
            host: host,
            username: username,
            password: password
        )
        try credentialStore.save(configuration)
        // This value contains no credential. Keeping it synchronized preserves
        // compatibility with older readers and makes downgrade behavior sane.
        let target = try RemarkableSSHTarget(
            username: username,
            host: host
        )
        defaults.set(
            target.destination,
            forKey: RemarkableSSHTarget.defaultsKey
        )
    }

    func delete(schema: PluginConfigurationSchema) throws {
        try credentialStore.delete()
        defaults.removeObject(forKey: RemarkableSSHTarget.defaultsKey)
    }

    private static func snapshot(
        from configuration: RemarkableSSHConfiguration
    ) -> PluginConfigurationSnapshot {
        PluginConfigurationSnapshot(values: [
            RemarkablePluginConfigurationFieldID.host:
                .string(configuration.host),
            RemarkablePluginConfigurationFieldID.username:
                .string(configuration.username),
            RemarkablePluginConfigurationFieldID.password:
                .string(configuration.password),
        ])
    }
}

/// Early-process SSH_ASKPASS entry point. `main.swift` should call this before
/// smoke/install/IMK startup and exit with the returned status when non-nil:
///
///   if let status = RemarkableSSHAskPassHandler.handleIfRequested() {
///       exit(status)
///   }
///
/// The environment carries only a purpose bit and a mode-0600 file path. The
/// password itself never appears in argv or an environment value.
enum RemarkableSSHAskPassHandler {
    static let requestEnvironmentKey = "RIMEBUFFER_REMARKABLE_ASKPASS"
    static let credentialPathEnvironmentKey =
        "RIMEBUFFER_REMARKABLE_CREDENTIAL_FILE"
    static let destinationEnvironmentKey =
        "RIMEBUFFER_REMARKABLE_ASKPASS_DESTINATION"

    static func handleIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        expectedCredentialURL: URL? = nil,
        parentSSHCheck: (() -> Bool)? = nil,
        output: FileHandle = .standardOutput
    ) -> Int32? {
        guard environment[requestEnvironmentKey] == "1" else {
            return nil
        }
        guard isPasswordPrompt(arguments),
              (parentSSHCheck?() ?? parentProcessIsSystemSSH()) else {
            return 1
        }
        guard let path = environment[credentialPathEnvironmentKey],
              !path.isEmpty,
              path.hasPrefix("/"),
              let expectedDestination =
                environment[destinationEnvironmentKey],
              let expectedTarget = try? RemarkableSSHTarget(
                  validating: expectedDestination
              ) else {
            return 1
        }
        let suppliedURL = URL(
            fileURLWithPath: path,
            isDirectory: false
        ).standardizedFileURL
        let trustedURL = (
            expectedCredentialURL
                ?? RemarkableCredentialStore.shared.configurationURL
        ).standardizedFileURL
        guard suppliedURL.path == trustedURL.path else {
            return 1
        }
        do {
            let configuration = try RemarkableCredentialStore.readConfiguration(
                at: trustedURL
            )
            let storedTarget = try RemarkableSSHTarget(
                username: configuration.username,
                host: configuration.host
            )
            guard storedTarget.destination == expectedTarget.destination else {
                return 1
            }
            guard !configuration.password.isEmpty else {
                return 1
            }
            try output.write(contentsOf: Data(
                (configuration.password + "\n").utf8
            ))
            return 0
        } catch {
            return 1
        }
    }

    private static func isPasswordPrompt(_ arguments: [String]) -> Bool {
        guard arguments.count == 2 else { return false }
        let prompt = arguments[1].lowercased()
        guard !prompt.contains("passphrase") else { return false }
        return prompt.contains("password") || prompt.contains("密码")
    }

    private static func parentProcessIsSystemSSH() -> Bool {
        let parentPID = getppid()
        guard parentPID > 1 else { return false }
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(
            parentPID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard length > 0, length < pathBuffer.count else { return false }
        let path = String(cString: pathBuffer)
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == "/usr/bin/ssh"
    }
}
