import AppKit
import CoreFoundation
import Darwin
import Foundation

extension Notification.Name {
    /// Posted after a plugin configuration has been committed or reset.
    ///
    /// The notification deliberately carries only the plugin identifier and
    /// changed field identifiers. Configuration values (including ordinary
    /// text values) never cross the notification boundary.
    static let pluginConfigurationDidChange = Notification.Name(
        "RimeBuffer.PluginConfiguration.didChange"
    )
}

enum PluginConfigurationNotificationKey {
    static let pluginID = "pluginID"
    static let changedFieldIDs = "changedFieldIDs"
}

/// A deliberately small value vocabulary shared by declaration, persistence
/// and the generic form. Its debug description is always redacted because the
/// same container may hold a password.
enum PluginConfigurationValue: Equatable, Codable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    case string(String)
    case bool(Bool)
    case number(Double)

    private enum CodingKeys: String, CodingKey {
        case type
        case string
        case bool
        case number
    }

    private enum ValueType: String, Codable {
        case string
        case bool
        case number
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .number:
            let number = try container.decode(Double.self, forKey: .number)
            guard number.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .number,
                    in: container,
                    debugDescription: "Non-finite plugin configuration number"
                )
            }
            self = .number(number)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .string)
        case let .bool(value):
            try container.encode(ValueType.bool, forKey: .type)
            try container.encode(value, forKey: .bool)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Non-finite plugin configuration number"
                    )
                )
            }
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .number)
        }
    }

    var description: String { "<redacted plugin configuration value>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(
            self,
            children: ["value": description],
            displayStyle: .enum
        )
    }
}

struct PluginConfigurationSnapshot: Equatable, Codable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate(set) var values: [String: PluginConfigurationValue]

    init(values: [String: PluginConfigurationValue] = [:]) {
        self.values = values
    }

    subscript(fieldID: String) -> PluginConfigurationValue? {
        get { values[fieldID] }
        set { values[fieldID] = newValue }
    }

    func string(_ fieldID: String) -> String? {
        guard case let .string(value)? = values[fieldID] else { return nil }
        return value
    }

    func bool(_ fieldID: String) -> Bool? {
        guard case let .bool(value)? = values[fieldID] else { return nil }
        return value
    }

    func number(_ fieldID: String) -> Double? {
        guard case let .number(value)? = values[fieldID] else { return nil }
        return value
    }

    var description: String { "<redacted plugin configuration>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(
            self,
            children: ["values": description],
            displayStyle: .struct
        )
    }
}

struct PluginConfigurationChoice: Equatable {
    let value: String
    let title: String

    init(value: String, title: String) {
        self.value = value
        self.title = title
    }
}

enum PluginConfigurationFieldKind {
    case text(placeholder: String?, maximumLength: Int, trimsWhitespace: Bool)
    case secureText(placeholder: String?, maximumLength: Int)
    case toggle
    case choice(options: [PluginConfigurationChoice])
    case number(minimum: Double, maximum: Double, step: Double)

    var isSecure: Bool {
        if case .secureText = self { return true }
        return false
    }
}

/// A validator returns a reader-facing error message, never the rejected value.
/// Validators must not interpolate configuration values into that message.
typealias PluginConfigurationFieldValidator = (
    _ value: PluginConfigurationValue,
    _ snapshot: PluginConfigurationSnapshot
) -> String?

struct PluginConfigurationField {
    let id: String
    let title: String
    let helpText: String?
    let kind: PluginConfigurationFieldKind
    let defaultValue: PluginConfigurationValue
    let isRequired: Bool
    let validator: PluginConfigurationFieldValidator?

    init(id: String,
         title: String,
         helpText: String? = nil,
         kind: PluginConfigurationFieldKind,
         defaultValue: PluginConfigurationValue,
         isRequired: Bool = false,
         validator: PluginConfigurationFieldValidator? = nil) {
        self.id = id
        self.title = title
        self.helpText = helpText
        self.kind = kind
        self.defaultValue = defaultValue
        self.isRequired = isRequired
        self.validator = validator
    }

    static func text(id: String,
                     title: String,
                     helpText: String? = nil,
                     placeholder: String? = nil,
                     defaultValue: String = "",
                     maximumLength: Int = 2_048,
                     trimsWhitespace: Bool = true,
                     isRequired: Bool = false,
                     validator: PluginConfigurationFieldValidator? = nil)
        -> PluginConfigurationField {
        PluginConfigurationField(
            id: id,
            title: title,
            helpText: helpText,
            kind: .text(
                placeholder: placeholder,
                maximumLength: maximumLength,
                trimsWhitespace: trimsWhitespace
            ),
            defaultValue: .string(defaultValue),
            isRequired: isRequired,
            validator: validator
        )
    }

    static func secureText(id: String,
                           title: String,
                           helpText: String? = nil,
                           placeholder: String? = nil,
                           defaultValue: String = "",
                           maximumLength: Int = 4_096,
                           isRequired: Bool = false,
                           validator: PluginConfigurationFieldValidator? = nil)
        -> PluginConfigurationField {
        PluginConfigurationField(
            id: id,
            title: title,
            helpText: helpText,
            kind: .secureText(
                placeholder: placeholder,
                maximumLength: maximumLength
            ),
            defaultValue: .string(defaultValue),
            isRequired: isRequired,
            validator: validator
        )
    }

    static func toggle(id: String,
                       title: String,
                       helpText: String? = nil,
                       defaultValue: Bool = false,
                       validator: PluginConfigurationFieldValidator? = nil)
        -> PluginConfigurationField {
        PluginConfigurationField(
            id: id,
            title: title,
            helpText: helpText,
            kind: .toggle,
            defaultValue: .bool(defaultValue),
            validator: validator
        )
    }

    static func choice(id: String,
                       title: String,
                       helpText: String? = nil,
                       options: [PluginConfigurationChoice],
                       defaultValue: String,
                       validator: PluginConfigurationFieldValidator? = nil)
        -> PluginConfigurationField {
        PluginConfigurationField(
            id: id,
            title: title,
            helpText: helpText,
            kind: .choice(options: options),
            defaultValue: .string(defaultValue),
            isRequired: true,
            validator: validator
        )
    }

    static func number(id: String,
                       title: String,
                       helpText: String? = nil,
                       defaultValue: Double,
                       minimum: Double,
                       maximum: Double,
                       step: Double = 1,
                       validator: PluginConfigurationFieldValidator? = nil)
        -> PluginConfigurationField {
        PluginConfigurationField(
            id: id,
            title: title,
            helpText: helpText,
            kind: .number(minimum: minimum, maximum: maximum, step: step),
            defaultValue: .number(defaultValue),
            validator: validator
        )
    }
}

struct PluginConfigurationSchema {
    let pluginID: String
    let title: String
    let summary: String?
    let fields: [PluginConfigurationField]

    init(pluginID: String,
         title: String,
         summary: String? = nil,
         fields: [PluginConfigurationField]) {
        self.pluginID = pluginID
        self.title = title
        self.summary = summary
        self.fields = fields
    }

    fileprivate func validateDefinition() throws {
        guard !pluginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pluginID.utf8.count <= 256,
              !pluginID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PluginConfigurationError.invalidSchema("插件标识无效")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fields.isEmpty else {
            throw PluginConfigurationError.invalidSchema("配置标题或字段为空")
        }

        var knownIDs = Set<String>()
        for field in fields {
            guard PluginConfigurationIdentifier.isValid(field.id),
                  knownIDs.insert(field.id).inserted else {
                throw PluginConfigurationError.invalidSchema("配置字段标识无效或重复")
            }
            try validateDefinition(of: field)
        }
        _ = try normalized(
            PluginConfigurationSnapshot(
                values: Dictionary(uniqueKeysWithValues: fields.map {
                    ($0.id, $0.defaultValue)
                })
            )
        )
    }

    fileprivate func normalized(
        _ snapshot: PluginConfigurationSnapshot
    ) throws -> PluginConfigurationSnapshot {
        var values: [String: PluginConfigurationValue] = [:]
        for field in fields {
            let supplied = snapshot[field.id] ?? field.defaultValue
            values[field.id] = try normalized(supplied, for: field)
        }
        let result = PluginConfigurationSnapshot(values: values)
        for field in fields {
            guard let value = result[field.id] else { continue }
            if let message = field.validator?(value, result),
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PluginConfigurationError.invalidField(
                    fieldID: field.id,
                    message: message
                )
            }
        }
        return result
    }

    fileprivate var containsSecureFields: Bool {
        fields.contains { $0.kind.isSecure }
    }

    private func validateDefinition(of field: PluginConfigurationField) throws {
        switch field.kind {
        case let .text(_, maximumLength, _),
             let .secureText(_, maximumLength):
            guard maximumLength > 0, maximumLength <= 64 * 1_024 else {
                throw PluginConfigurationError.invalidSchema("文本字段长度限制无效")
            }
            guard case .string = field.defaultValue else {
                throw PluginConfigurationError.invalidSchema("文本字段默认值类型无效")
            }
        case .toggle:
            guard case .bool = field.defaultValue else {
                throw PluginConfigurationError.invalidSchema("开关字段默认值类型无效")
            }
        case let .choice(options):
            guard !options.isEmpty,
                  options.count <= 256,
                  Set(options.map(\.value)).count == options.count,
                  options.allSatisfy({
                      !$0.value.isEmpty && !$0.title.isEmpty &&
                          $0.value.utf8.count <= 1_024
                  }),
                  case let .string(defaultValue) = field.defaultValue,
                  options.contains(where: { $0.value == defaultValue }) else {
                throw PluginConfigurationError.invalidSchema("选项字段声明无效")
            }
        case let .number(minimum, maximum, step):
            guard minimum.isFinite,
                  maximum.isFinite,
                  step.isFinite,
                  minimum <= maximum,
                  step > 0,
                  case .number = field.defaultValue else {
                throw PluginConfigurationError.invalidSchema("数值字段声明无效")
            }
        }
    }

    private func normalized(
        _ value: PluginConfigurationValue,
        for field: PluginConfigurationField
    ) throws -> PluginConfigurationValue {
        switch (field.kind, value) {
        case let (.text(_, maximumLength, trimsWhitespace), .string(raw)):
            let value = trimsWhitespace
                ? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                : raw
            try validateText(value,
                             maximumLength: maximumLength,
                             field: field)
            return .string(value)
        case let (.secureText(_, maximumLength), .string(value)):
            try validateText(value,
                             maximumLength: maximumLength,
                             field: field)
            return .string(value)
        case (.toggle, .bool):
            return value
        case let (.choice(options), .string(selected)):
            guard options.contains(where: { $0.value == selected }) else {
                throw PluginConfigurationError.invalidField(
                    fieldID: field.id,
                    message: "请选择有效选项"
                )
            }
            return value
        case let (.number(minimum, maximum, _), .number(number)):
            guard number.isFinite, number >= minimum, number <= maximum else {
                throw PluginConfigurationError.invalidField(
                    fieldID: field.id,
                    message: "数值超出允许范围"
                )
            }
            return value
        default:
            throw PluginConfigurationError.invalidField(
                fieldID: field.id,
                message: "配置值类型不匹配"
            )
        }
    }

    private func validateText(
        _ value: String,
        maximumLength: Int,
        field: PluginConfigurationField
    ) throws {
        if field.isRequired && value.isEmpty {
            throw PluginConfigurationError.invalidField(
                fieldID: field.id,
                message: "此项不能为空"
            )
        }
        guard value.utf8.count <= maximumLength else {
            throw PluginConfigurationError.invalidField(
                fieldID: field.id,
                message: "内容过长"
            )
        }
    }
}

enum PluginConfigurationError: Error, LocalizedError {
    case invalidSchema(String)
    case invalidField(fieldID: String, message: String)
    case secureValuesRequirePrivateStorage
    case unsafePath
    case invalidPermissions
    case oversized
    case unreadable
    case corruptDocument

    var fieldID: String? {
        if case let .invalidField(fieldID, _) = self { return fieldID }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .invalidSchema(message):
            return "插件配置声明无效：\(message)"
        case let .invalidField(_, message):
            return message
        case .secureValuesRequirePrivateStorage:
            return "包含敏感字段的配置必须保存到私有配置文件"
        case .unsafePath:
            return "配置文件路径不安全"
        case .invalidPermissions:
            return "配置目录或文件权限不安全"
        case .oversized:
            return "配置文件过大"
        case .unreadable:
            return "无法读写插件配置"
        case .corruptDocument:
            return "插件配置文件已损坏"
        }
    }
}

protocol PluginConfigurationStoring: AnyObject {
    var supportsSecureValues: Bool { get }
    func validate(schema: PluginConfigurationSchema) throws
    func load(schema: PluginConfigurationSchema) throws
        -> PluginConfigurationSnapshot?
    func save(_ snapshot: PluginConfigurationSnapshot,
              schema: PluginConfigurationSchema) throws
    func delete(schema: PluginConfigurationSchema) throws
}

/// Non-sensitive plugin preferences. One property-list dictionary is used per
/// plugin so readers never observe a partially updated field set.
final class PluginConfigurationUserDefaultsStore: PluginConfigurationStoring {
    let supportsSecureValues = false

    private let defaults: UserDefaults
    private let namespace: String
    private let storageKey: String

    init(namespace: String,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.namespace = namespace
        storageKey = "RimeBuffer.PluginConfiguration.\(namespace)"
    }

    func validate(schema: PluginConfigurationSchema) throws {
        guard PluginConfigurationIdentifier.isValidStorageNamespace(
            namespace
        ) else {
            throw PluginConfigurationError.invalidSchema("存储命名空间无效")
        }
        guard !schema.containsSecureFields else {
            throw PluginConfigurationError.secureValuesRequirePrivateStorage
        }
    }

    func load(schema: PluginConfigurationSchema) throws
        -> PluginConfigurationSnapshot? {
        guard let raw = defaults.dictionary(forKey: storageKey) else {
            return nil
        }
        var values: [String: PluginConfigurationValue] = [:]
        for field in schema.fields {
            guard let stored = raw[field.id] else { continue }
            guard let decoded = decode(stored, for: field.kind) else {
                throw PluginConfigurationError.corruptDocument
            }
            values[field.id] = decoded
        }
        return PluginConfigurationSnapshot(values: values)
    }

    func save(_ snapshot: PluginConfigurationSnapshot,
              schema: PluginConfigurationSchema) throws {
        try validate(schema: schema)
        var raw: [String: Any] = [:]
        for field in schema.fields {
            guard let value = snapshot[field.id] else { continue }
            switch value {
            case let .string(value): raw[field.id] = value
            case let .bool(value): raw[field.id] = value
            case let .number(value): raw[field.id] = value
            }
        }
        defaults.set(raw, forKey: storageKey)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        defaults.removeObject(forKey: storageKey)
    }

    private func decode(
        _ raw: Any,
        for kind: PluginConfigurationFieldKind
    ) -> PluginConfigurationValue? {
        switch kind {
        case .text, .secureText, .choice:
            guard let value = raw as? String else { return nil }
            return .string(value)
        case .toggle:
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return nil
            }
            return .bool(number.boolValue)
        case .number:
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else {
                return nil
            }
            return .number(number.doubleValue)
        }
    }
}

/// Atomic, mode-0600 storage for schemas containing credentials.
///
/// This follows the input method's current ad-hoc-signing threat model:
/// secrets live outside UserDefaults in a private file, while same-user
/// processes remain inside the local trust boundary.
final class PluginConfigurationPrivateJSONStore: PluginConfigurationStoring {
    static let maximumDocumentBytes = 64 * 1_024
    let supportsSecureValues = true
    let configurationURL: URL

    private struct Document: Codable {
        let schemaVersion: Int
        let pluginID: String
        let values: [String: PluginConfigurationValue]
    }

    private let rootDirectory: URL
    private let baseDirectory: URL
    private let pluginDirectory: URL
    private let storageIdentifier: String
    private let fileManager: FileManager

    init(storageIdentifier: String,
         rootDirectory: URL? = nil,
         fileManager: FileManager = .default) throws {
        guard PluginConfigurationIdentifier.isValidStorageNamespace(
            storageIdentifier
        ) else {
            throw PluginConfigurationError.invalidSchema("存储命名空间无效")
        }
        self.fileManager = fileManager
        self.storageIdentifier = storageIdentifier
        if let rootDirectory {
            self.rootDirectory = rootDirectory.standardizedFileURL
        } else if let override = ProcessInfo.processInfo.environment[
            "RIMEBUFFER_LOCAL_DATA_ROOT"
        ], !override.isEmpty {
            self.rootDirectory = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        } else {
            self.rootDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/RimeBuffer",
                                        isDirectory: true)
                .standardizedFileURL
        }
        baseDirectory = self.rootDirectory
            .appendingPathComponent("plugin-config", isDirectory: true)
        pluginDirectory = baseDirectory
            .appendingPathComponent(storageIdentifier, isDirectory: true)
        configurationURL = pluginDirectory
            .appendingPathComponent("configuration.json", isDirectory: false)
    }

    func validate(schema: PluginConfigurationSchema) throws {
        // Private storage is also allowed for schemas without credentials when
        // a plugin needs one atomic configuration document.
        guard schema.pluginID == storageIdentifier else {
            throw PluginConfigurationError.invalidSchema(
                "私有存储标识必须与插件标识一致"
            )
        }
    }

    func load(schema: PluginConfigurationSchema) throws
        -> PluginConfigurationSnapshot? {
        try validate(schema: schema)
        var configurationInfo = stat()
        if lstat(configurationURL.path, &configurationInfo) == 0 {
            try validatePrivateDirectoryChain()
            try removeOrphanedTemporaryFiles()
        } else if errno == ENOENT {
            var pluginDirectoryInfo = stat()
            if lstat(pluginDirectory.path, &pluginDirectoryInfo) == 0 {
                try validatePrivateDirectoryChain()
                try removeOrphanedTemporaryFiles()
            } else if errno != ENOENT {
                throw PluginConfigurationError.unreadable
            }
        } else {
            throw PluginConfigurationError.unreadable
        }
        let data = try readPrivateFile()
        guard let data else { return nil }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw PluginConfigurationError.corruptDocument
        }
        guard document.schemaVersion == 1,
              document.pluginID == schema.pluginID else {
            throw PluginConfigurationError.corruptDocument
        }
        return PluginConfigurationSnapshot(values: document.values)
    }

    func save(_ snapshot: PluginConfigurationSnapshot,
              schema: PluginConfigurationSchema) throws {
        try validate(schema: schema)
        let document = Document(
            schemaVersion: 1,
            pluginID: schema.pluginID,
            values: snapshot.values
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(document)
        } catch {
            throw PluginConfigurationError.unreadable
        }
        guard data.count <= Self.maximumDocumentBytes else {
            throw PluginConfigurationError.oversized
        }

        try ensureSharedRootDirectory(rootDirectory)
        try ensurePrivateDirectory(baseDirectory)
        try ensurePrivateDirectory(pluginDirectory)
        try removeOrphanedTemporaryFiles()
        try rejectExistingNonRegularFile(at: configurationURL)

        let temporaryURL = pluginDirectory.appendingPathComponent(
            ".configuration.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PluginConfigurationError.unreadable
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlink(temporaryURL.path) }
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              rename(temporaryURL.path, configurationURL.path) == 0 else {
            throw PluginConfigurationError.unreadable
        }
        shouldUnlink = false
        try fsyncDirectory(pluginDirectory)
    }

    func delete(schema: PluginConfigurationSchema) throws {
        try validate(schema: schema)
        var info = stat()
        if lstat(configurationURL.path, &info) != 0 {
            if errno == ENOENT { return }
            throw PluginConfigurationError.unreadable
        }
        try validatePrivateDirectoryChain()
        try removeOrphanedTemporaryFiles()
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw PluginConfigurationError.unsafePath
        }
        guard unlink(configurationURL.path) == 0 else {
            throw PluginConfigurationError.unreadable
        }
        try fsyncDirectory(pluginDirectory)
    }

    private func readPrivateFile() throws -> Data? {
        var before = stat()
        if lstat(configurationURL.path, &before) != 0 {
            if errno == ENOENT { return nil }
            throw PluginConfigurationError.unreadable
        }
        guard (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid() else {
            throw PluginConfigurationError.unsafePath
        }
        guard (before.st_mode & 0o777) == 0o600 else {
            throw PluginConfigurationError.invalidPermissions
        }
        guard before.st_size >= 0,
              before.st_size <= Self.maximumDocumentBytes else {
            throw PluginConfigurationError.oversized
        }

        let descriptor = open(configurationURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PluginConfigurationError.unreadable
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino else {
            throw PluginConfigurationError.unsafePath
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PluginConfigurationError.unreadable
            }
            data.append(buffer, count: count)
            guard data.count <= Self.maximumDocumentBytes else {
                throw PluginConfigurationError.oversized
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count <= 0 {
                    if errno == EINTR { continue }
                    throw PluginConfigurationError.unreadable
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw PluginConfigurationError.unsafePath
            }
        } else {
            guard errno == ENOENT else {
                throw PluginConfigurationError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PluginConfigurationError.unreadable
            }
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw PluginConfigurationError.unsafePath
            }
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw PluginConfigurationError.invalidPermissions
        }
    }

    /// `rootDirectory` is shared with Rime schemas and user data, so an
    /// installer may legitimately leave it mode 0755. Secrets remain behind
    /// the exact-0700 `plugin-config/<plugin-id>` directories. At this shared
    /// boundary, require a real current-user-owned directory with full owner
    /// access and no group/world write permission, but do not rewrite its
    /// otherwise-safe mode.
    private func ensureSharedRootDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw PluginConfigurationError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PluginConfigurationError.unreadable
            }
        }
        try validateSharedRootDirectory(url)
    }

    private func validateSharedRootDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw PluginConfigurationError.unsafePath
        }
        let permissions = info.st_mode & 0o777
        guard (permissions & 0o700) == 0o700,
              (permissions & 0o022) == 0 else {
            throw PluginConfigurationError.invalidPermissions
        }
    }

    private func validatePrivateDirectoryChain() throws {
        try validateSharedRootDirectory(rootDirectory)
        for directory in [baseDirectory, pluginDirectory] {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw PluginConfigurationError.unsafePath
            }
            guard (info.st_mode & 0o777) == 0o700 else {
                throw PluginConfigurationError.invalidPermissions
            }
        }
    }

    /// A crash between creating and renaming the temporary document may leave
    /// a second plaintext credential copy. Remove only files created by this
    /// writer, and only after proving owner, type, and permissions.
    private func removeOrphanedTemporaryFiles() throws {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(
                atPath: pluginDirectory.path
            )
        } catch {
            throw PluginConfigurationError.unreadable
        }
        for name in names {
            guard name.hasPrefix(".configuration."),
                  name.hasSuffix(".tmp"),
                  UUID(
                    uuidString: String(
                        name.dropFirst(".configuration.".count)
                            .dropLast(".tmp".count)
                    )
                  ) != nil else {
                continue
            }
            let url = pluginDirectory.appendingPathComponent(
                name,
                isDirectory: false
            )
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o600 else {
                throw PluginConfigurationError.unsafePath
            }
            guard unlink(url.path) == 0 else {
                throw PluginConfigurationError.unreadable
            }
        }
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw PluginConfigurationError.unreadable
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw PluginConfigurationError.unreadable
        }
    }

    private func rejectExistingNonRegularFile(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw PluginConfigurationError.unreadable
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            throw PluginConfigurationError.unsafePath
        }
    }
}

/// Thread-safe configuration boundary used by settings UI and plugin runtime.
/// Persisted values are normalized and validated before they are returned.
final class PluginConfigurationModel {
    let schema: PluginConfigurationSchema

    private let store: any PluginConfigurationStoring
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()

    init(schema: PluginConfigurationSchema,
         store: any PluginConfigurationStoring,
         notificationCenter: NotificationCenter = .default) throws {
        self.schema = schema
        self.store = store
        self.notificationCenter = notificationCenter
        try schema.validateDefinition()
        try store.validate(schema: schema)
    }

    func load() throws -> PluginConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let persisted = try store.load(schema: schema)
        return try schema.normalized(
            persisted ?? PluginConfigurationSnapshot()
        )
    }

    @discardableResult
    func save(_ snapshot: PluginConfigurationSnapshot) throws
        -> PluginConfigurationSnapshot {
        let normalized = try schema.normalized(snapshot)
        let previous: PluginConfigurationSnapshot
        lock.lock()
        do {
            previous = try schema.normalized(
                try store.load(schema: schema) ??
                    PluginConfigurationSnapshot()
            )
            try store.save(normalized, schema: schema)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        postChange(previous: previous, next: normalized)
        return normalized
    }

    func reset() throws {
        lock.lock()
        let previous = try? store.load(schema: schema).map {
            try schema.normalized($0)
        }
        do {
            try store.delete(schema: schema)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let defaults = try schema.normalized(PluginConfigurationSnapshot())
        postChange(previous: previous, next: defaults, forceAll: previous == nil)
    }

    private func postChange(
        previous: PluginConfigurationSnapshot?,
        next: PluginConfigurationSnapshot,
        forceAll: Bool = false
    ) {
        let changedFieldIDs: [String]
        if forceAll || previous == nil {
            changedFieldIDs = schema.fields.map(\.id)
        } else {
            changedFieldIDs = schema.fields.compactMap { field in
                previous?[field.id] == next[field.id] ? nil : field.id
            }
        }
        guard !changedFieldIDs.isEmpty else { return }
        notificationCenter.post(
            name: .pluginConfigurationDidChange,
            object: nil,
            userInfo: [
                PluginConfigurationNotificationKey.pluginID: schema.pluginID,
                PluginConfigurationNotificationKey.changedFieldIDs:
                    changedFieldIDs,
            ]
        )
    }
}

/// Opt-in boundary for built-in plugins. PluginRegistry can discover this
/// conformance without adding one-off settings branches for every plugin.
protocol PluginConfigurationProviding: AnyObject {
    func makePluginConfigurationModel() throws -> PluginConfigurationModel
}

extension PluginConfigurationProviding {
    func makePluginConfigurationViewController() throws -> NSViewController {
        PluginConfigurationViewController(
            model: try makePluginConfigurationModel()
        )
    }
}

/// Single construction seam for plugin-configuration sheets. Assigning a
/// content view controller lets AppKit replace the panel's requested content
/// rect with the controller view's fitting size, so the final size must be
/// applied after that assignment.
enum PluginConfigurationSheetFactory {
    static func make(
        contentViewController controller: NSViewController,
        title: String
    ) -> NSPanel {
        // Force the generic controller to calculate its content-driven
        // preferred height before choosing the panel rect.
        _ = controller.view
        let declaredSize = controller.preferredContentSize
        let preferredSize: NSSize
        if declaredSize.width.isFinite,
           declaredSize.height.isFinite,
           declaredSize.width > 0,
           declaredSize.height > 0 {
            preferredSize = declaredSize
        } else {
            preferredSize =
                PluginConfigurationViewController.preferredFormSize
        }

        let sheet = NSPanel(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = title
        sheet.isReleasedWhenClosed = false
        sheet.appearance = RimeUI.appKitAppearance
        sheet.contentViewController = controller
        sheet.setContentSize(preferredSize)
        return sheet
    }
}

/// Generic settings surface for declarative plugin schemas.
///
/// It uses an explicit Save action, masks secure text with NSSecureTextField,
/// and reports validation/storage errors without logging form contents.
final class PluginConfigurationViewController: NSViewController,
    NSTextFieldDelegate {
    static let preferredFormSize = NSSize(width: 700, height: 420)
    static let minimumFormHeight: CGFloat = 320
    static let maximumFormHeight: CGFloat = 520

    private enum FieldControl {
        case text(NSTextField)
        case toggle(RimeFixedAccentSwitch)
        case choice(NSPopUpButton)
        case number(PluginConfigurationNumberControl)
    }

    private let model: PluginConfigurationModel
    private var controls: [String: FieldControl] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private let resetButton = NSButton(
        title: "恢复默认值…",
        target: nil,
        action: nil
    )
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)
    var onDismiss: (() -> Void)?

    init(model: PluginConfigurationModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        controls.removeAll()

        let root = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.preferredFormSize.width,
            height: Self.maximumFormHeight
        ))
        let heading = NSTextField(labelWithString: model.schema.title)
        heading.font = .systemFont(ofSize: 22, weight: .semibold)

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(
            top: 26,
            left: 28,
            bottom: 30,
            right: 28
        )
        content.addArrangedSubview(heading)

        if let summary = model.schema.summary, !summary.isEmpty {
            let label = NSTextField(wrappingLabelWithString: summary)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.widthAnchor.constraint(equalToConstant: 620).isActive = true
            content.addArrangedSubview(label)
        }

        let separator = NSBox()
        separator.boxType = .separator
        content.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: content.widthAnchor,
                                         constant: -56).isActive = true

        for field in model.schema.fields {
            content.addArrangedSubview(makeRow(for: field))
        }

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 42
        ).isActive = true

        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = RimeUI.accentGreen
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveTapped(_:))
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetTapped(_:))
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(doneTapped(_:))

        let actions = NSStackView(
            views: [saveButton, resetButton, flexibleSpacer(), doneButton]
        )
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.widthAnchor.constraint(equalToConstant: 620).isActive = true
        content.addArrangedSubview(actions)
        content.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalToConstant: 620).isActive = true

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        view = root
        root.layoutSubtreeIfNeeded()
        let naturalHeight = ceil(content.fittingSize.height)
        let resolvedHeight = min(
            max(naturalHeight, Self.minimumFormHeight),
            Self.maximumFormHeight
        )
        let resolvedSize = NSSize(
            width: Self.preferredFormSize.width,
            height: resolvedHeight
        )
        root.setFrameSize(resolvedSize)
        preferredContentSize = resolvedSize
        root.layoutSubtreeIfNeeded()
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        do {
            let snapshot = try model.load()
            apply(snapshot)
            setStatus("", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    @objc private func saveTapped(_ sender: Any?) {
        do {
            let snapshot = try snapshotFromControls()
            _ = try model.save(snapshot)
            setStatus("已保存", isError: false, isSuccess: true)
        } catch {
            setStatus(error.localizedDescription, isError: true)
            if let configurationError = error as? PluginConfigurationError,
               let fieldID = configurationError.fieldID {
                focus(fieldID: fieldID)
            }
            NSSound.beep()
        }
    }

    @objc private func resetTapped(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "恢复默认配置？"
        alert.informativeText = "这会删除此插件已保存的配置，包括其中的敏感字段。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复默认值")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = RimeUI.appKitAppearance
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.reset()
            reload()
            setStatus("已恢复默认值", isError: false, isSuccess: true)
        } catch {
            setStatus(error.localizedDescription, isError: true)
            NSSound.beep()
        }
    }

    @objc private func doneTapped(_ sender: Any?) {
        onDismiss?()
    }

    @objc private func controlChanged(_ sender: Any?) {
        setStatus("有未保存的更改", isError: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        controlChanged(obj.object)
    }

    private func makeRow(for field: PluginConfigurationField) -> NSView {
        let title = NSTextField(labelWithString: field.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)

        let labels = NSStackView(views: [title])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        if let helpText = field.helpText, !helpText.isEmpty {
            let help = NSTextField(wrappingLabelWithString: helpText)
            help.font = .systemFont(ofSize: 10.5)
            help.textColor = .tertiaryLabelColor
            help.maximumNumberOfLines = 3
            help.widthAnchor.constraint(equalToConstant: 250).isActive = true
            labels.addArrangedSubview(help)
        }
        labels.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let controlView: NSView
        switch field.kind {
        case let .text(placeholder, _, _):
            let control = NSTextField(string: "")
            control.placeholderString = placeholder
            configureTextField(control)
            controls[field.id] = .text(control)
            controlView = control
        case let .secureText(placeholder, _):
            let control = NSSecureTextField(string: "")
            control.placeholderString = placeholder
            configureTextField(control)
            controls[field.id] = .text(control)
            controlView = control
        case .toggle:
            let control = RimeFixedAccentSwitch()
            control.target = self
            control.action = #selector(controlChanged(_:))
            control.setAccessibilityLabel(field.title)
            controls[field.id] = .toggle(control)
            controlView = control
        case let .choice(options):
            let control = RimeFixedAccentPopUpButton()
            for option in options {
                control.addItem(withTitle: option.title)
                control.lastItem?.representedObject = option.value
            }
            control.target = self
            control.action = #selector(controlChanged(_:))
            controls[field.id] = .choice(control)
            controlView = control
        case let .number(minimum, maximum, step):
            let control = PluginConfigurationNumberControl(
                minimum: minimum,
                maximum: maximum,
                step: step
            )
            control.onChange = { [weak self] in
                self?.controlChanged(nil)
            }
            controls[field.id] = .number(control)
            controlView = control
        }
        controlView.translatesAutoresizingMaskIntoConstraints = false
        controlView.widthAnchor.constraint(equalToConstant: 350).isActive = true

        let row = NSStackView(views: [labels, controlView])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 20
        row.widthAnchor.constraint(equalToConstant: 620).isActive = true
        return row
    }

    private func configureTextField(_ field: NSTextField) {
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }

    private func snapshotFromControls() throws
        -> PluginConfigurationSnapshot {
        var snapshot = PluginConfigurationSnapshot()
        for field in model.schema.fields {
            guard let control = controls[field.id] else {
                throw PluginConfigurationError.invalidSchema("配置控件缺失")
            }
            switch control {
            case let .text(textField):
                snapshot[field.id] = .string(textField.stringValue)
            case let .toggle(toggle):
                snapshot[field.id] = .bool(toggle.state == .on)
            case let .choice(popup):
                guard let value = popup.selectedItem?.representedObject
                    as? String else {
                    throw PluginConfigurationError.invalidField(
                        fieldID: field.id,
                        message: "请选择有效选项"
                    )
                }
                snapshot[field.id] = .string(value)
            case let .number(control):
                guard let value = control.value else {
                    throw PluginConfigurationError.invalidField(
                        fieldID: field.id,
                        message: "请输入有效数值"
                    )
                }
                snapshot[field.id] = .number(value)
            }
        }
        return snapshot
    }

    private func apply(_ snapshot: PluginConfigurationSnapshot) {
        for field in model.schema.fields {
            guard let value = snapshot[field.id],
                  let control = controls[field.id] else {
                continue
            }
            switch (control, value) {
            case let (.text(textField), .string(value)):
                textField.stringValue = value
            case let (.toggle(toggle), .bool(value)):
                toggle.state = value ? .on : .off
            case let (.choice(popup), .string(value)):
                if let item = popup.itemArray.first(where: {
                    ($0.representedObject as? String) == value
                }) {
                    popup.select(item)
                }
            case let (.number(control), .number(value)):
                control.value = value
            default:
                break
            }
        }
    }

    private func focus(fieldID: String) {
        guard let control = controls[fieldID] else { return }
        switch control {
        case let .text(field):
            view.window?.makeFirstResponder(field)
        case let .toggle(toggle):
            view.window?.makeFirstResponder(toggle)
        case let .choice(popup):
            view.window?.makeFirstResponder(popup)
        case let .number(control):
            view.window?.makeFirstResponder(control.textField)
        }
    }

    private func setStatus(_ message: String,
                           isError: Bool,
                           isSuccess: Bool = false) {
        statusLabel.stringValue = message
        if isError {
            statusLabel.textColor = .systemRed
        } else if isSuccess {
            statusLabel.textColor = RimeUI.accentTextColor
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow,
                                                       for: .horizontal)
        return spacer
    }
}

private final class PluginConfigurationNumberControl: NSStackView,
    NSTextFieldDelegate {
    let textField = NSTextField(string: "")
    private let stepper = NSStepper()
    private let formatter = NumberFormatter()
    var onChange: (() -> Void)?

    var value: Double? {
        get {
            guard let number = formatter.number(from: textField.stringValue) else {
                return nil
            }
            return number.doubleValue
        }
        set {
            guard let newValue else {
                textField.stringValue = ""
                return
            }
            textField.stringValue = formatter.string(
                from: NSNumber(value: newValue)
            ) ?? String(newValue)
            stepper.doubleValue = newValue
        }
    }

    init(minimum: Double, maximum: Double, step: Double) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4

        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: minimum)
        formatter.maximum = NSNumber(value: maximum)
        formatter.maximumFractionDigits = 6
        formatter.generatesDecimalNumbers = false

        textField.formatter = formatter
        textField.delegate = self
        textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
            .isActive = true

        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = step
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        addArrangedSubview(textField)
        addArrangedSubview(stepper)
    }

    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ obj: Notification) {
        if let value {
            stepper.doubleValue = value
        }
        onChange?()
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        value = sender.doubleValue
        onChange?()
    }
}

private enum PluginConfigurationIdentifier {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) ||
                $0 == "_" || $0 == "-" || $0 == "."
        }
    }

    static func isValidStorageNamespace(_ value: String) -> Bool {
        isValid(value) && value != "." && value != ".."
    }
}
