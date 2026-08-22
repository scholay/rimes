import Cocoa
import Carbon.HIToolbox
import Foundation

// MARK: - Manifest and wire protocol

struct ActionPluginKey: Hashable, Equatable {
    let pluginId: String
    let actionId: String
}

struct ActionPluginPresentationKey: Hashable, Equatable {
    let pluginId: String
    let presentationId: String
}

struct ActionPluginManifest: Decodable, Equatable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String?
    let runtimeConfigPaths: [String]
    let actions: [ActionPluginDefinition]
}

struct ActionPluginDefinition: Decodable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let statusPath: String
    /// Optional Rime-owned execution contract. When present, the plugin only
    /// prepares a prompt; RimeBuffer runs the selected local AI connector and
    /// keeps the resulting blocks bound to this plugin's context lease.
    let preparePath: String?
    let invokePath: String
    let streamPath: String?
    let modes: [String]
    /// Whether invoking this action requires a live IMK focus lease. Existing
    /// manifests default to `true`; context-only actions can opt out while
    /// keeping delivery fail-closed until the user focuses a fresh target.
    let requiresFocus: Bool
    /// Actions that are mutually selected by runtime context can share one
    /// stable workbench control without collapsing their wire identities.
    let presentationId: String?
    let presentationTitle: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case symbol
        case statusPath
        case preparePath
        case invokePath
        case streamPath
        case modes
        case requiresFocus
        case presentationId
        case presentationTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decode(String.self, forKey: .symbol)
        statusPath = try container.decode(String.self, forKey: .statusPath)
        preparePath = try container.decodeIfPresent(String.self, forKey: .preparePath)
        invokePath = try container.decode(String.self, forKey: .invokePath)
        streamPath = try container.decodeIfPresent(String.self, forKey: .streamPath)
        modes = try container.decode([String].self, forKey: .modes)
        requiresFocus = try container.decodeIfPresent(Bool.self, forKey: .requiresFocus) ?? true
        presentationId = try container.decodeIfPresent(String.self, forKey: .presentationId)
        presentationTitle = try container.decodeIfPresent(String.self, forKey: .presentationTitle)
    }

    init(id: String,
         title: String,
         symbol: String,
         statusPath: String,
         preparePath: String? = nil,
         invokePath: String,
         streamPath: String? = nil,
         modes: [String],
         requiresFocus: Bool = true,
         presentationId: String? = nil,
         presentationTitle: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.statusPath = statusPath
        self.preparePath = preparePath
        self.invokePath = invokePath
        self.streamPath = streamPath
        self.modes = modes
        self.requiresFocus = requiresFocus
        self.presentationId = presentationId
        self.presentationTitle = presentationTitle
    }
}

struct ActionPluginRuntimeConfig: Decodable, Equatable {
    let pluginId: String
    let apiBase: String
    let token: String
    let updatedAt: TimeInterval
    let instanceId: String?
    let processId: Int?
}

struct ActionPluginRuntimeBinding: Equatable {
    let config: ActionPluginRuntimeConfig

    /// Non-secret identity copied into Buffer metadata. The bearer token stays
    /// only inside the host's in-memory binding table.
    var identity: String {
        if let instanceId = config.instanceId,
           !instanceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "instance:\(instanceId)"
        }
        return "endpoint:\(config.apiBase)#\(config.updatedAt)#\(config.processId ?? -1)"
    }
}

struct ActionPluginStatus: Decodable, Equatable, Sendable {
    let available: Bool
    let contextId: String?
    let mode: String?
    let actionId: String
    let label: String?
    let targetSummary: String?
    let updatedAt: TimeInterval
}

struct ActionPluginStatusSnapshot: Equatable {
    let value: ActionPluginStatus
    let binding: ActionPluginRuntimeBinding
}

struct ActionPluginInvokeRequest: Codable, Equatable {
    let requestId: String
    let actionId: String
    let contextId: String
    let pluginId: String?
    let runtimeInstanceId: String?

    init(requestId: String,
         actionId: String,
         contextId: String,
         pluginId: String? = nil,
         runtimeInstanceId: String? = nil) {
        self.requestId = requestId
        self.actionId = actionId
        self.contextId = contextId
        self.pluginId = pluginId
        self.runtimeInstanceId = runtimeInstanceId
    }
}

struct ActionPluginResultBlock: Decodable, Equatable, Sendable {
    let text: String
    let title: String?
}

struct ActionPluginInvokeResponse: Decodable, Equatable, Sendable {
    let requestId: String
    let actionId: String
    let contextId: String
    let blocks: [ActionPluginResultBlock]
    let targetSummary: String?
}

/// Action Plugin v1's additive prompt-preparation response. The plugin may
/// provide only text and display metadata; model choice, credentials, CLI
/// arguments, tools, and the output schema stay exclusively inside RimeBuffer.
struct ActionPluginPrepareResponse: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let resultFormat: String
    let pluginId: String
    let runtimeInstanceId: String
    let requestId: String
    let actionId: String
    let contextId: String
    let prompt: String
    let targetSummary: String?
}

enum ActionPluginPrepareContract {
    static let protocolVersion = 1
    static let resultFormat = "blocks-v1"
    static let maximumPromptBytes = 256 * 1_024

    static func accepts(_ response: ActionPluginPrepareResponse,
                        expectedIdentity: ActionPluginStreamIdentity) -> Bool {
        let identity = ActionPluginStreamIdentity(
            pluginId: response.pluginId,
            runtimeInstanceId: response.runtimeInstanceId,
            requestId: response.requestId,
            actionId: response.actionId,
            contextId: response.contextId
        )
        return response.protocolVersion == protocolVersion
            && response.resultFormat == resultFormat
            && identity == expectedIdentity
            && ActionPluginStreamParser.validIdentity(identity)
            && !response.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !response.prompt.contains("\0")
            && response.prompt.utf8.count <= maximumPromptBytes
            && ActionPluginStreamParser.validOptionalText(
                response.targetSummary,
                maximumBytes: ActionPluginStreamParser.maximumSummaryBytes
            )
    }
}

struct ActionPluginStreamIdentity: Equatable {
    let pluginId: String
    let runtimeInstanceId: String
    let requestId: String
    let actionId: String
    let contextId: String
}

struct ActionPluginStreamBlockSnapshot: Equatable {
    let identity: ActionPluginStreamIdentity
    let sequence: Int
    let index: Int
    let text: String
    let title: String?
}

enum ActionPluginStreamEvent: Equatable {
    case block(ActionPluginStreamBlockSnapshot)
    case heartbeat(identity: ActionPluginStreamIdentity, sequence: Int)
}

struct InstalledActionPlugin: Equatable {
    let manifest: ActionPluginManifest
    let directory: URL
}

enum ActionPluginManifestLoader {
    private struct PresentationContract {
        let title: String
        let statusPath: String
        let preparePath: String?
        let invokePath: String
        let streamPath: String?
        let requiresFocus: Bool
        var modes: Set<String>
    }

    static var defaultRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["RIMEBUFFER_PLUGIN_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/RimeBuffer/plugins", isDirectory: true)
    }

    static func load(from rootURL: URL = defaultRootURL,
                     fileManager: FileManager = .default) -> [InstalledActionPlugin] {
        let rootValues = try? rootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues?.isDirectory == true,
              rootValues?.isSymbolicLink != true else { return [] }
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen = Set<String>()
        var installed: [InstalledActionPlugin] = []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            do {
                let manifestValues = try manifestURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
                guard manifestValues.isRegularFile == true,
                      manifestValues.isSymbolicLink != true,
                      (manifestValues.fileSize ?? 0) <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
                    IMELog.write("plugin manifest rejected path=\(manifestURL.path)")
                    continue
                }
                let data = try Data(contentsOf: manifestURL)
                guard data.count <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes else {
                    IMELog.write("plugin manifest rejected path=\(manifestURL.path)")
                    continue
                }
                let manifest = try JSONDecoder().decode(ActionPluginManifest.self, from: data)
                guard validate(manifest), seen.insert(manifest.id).inserted else {
                    IMELog.write("plugin manifest rejected path=\(manifestURL.path)")
                    continue
                }
                installed.append(InstalledActionPlugin(manifest: manifest,
                                                       directory: directory))
            } catch {
                IMELog.write("plugin manifest read failed path=\(manifestURL.path) error=\(error.localizedDescription)")
            }
        }
        return installed
    }

    static func validate(_ manifest: ActionPluginManifest) -> Bool {
        guard manifest.schemaVersion == 1,
              isIdentifier(manifest.id),
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.name.count <= 80,
              !manifest.runtimeConfigPaths.isEmpty,
              manifest.runtimeConfigPaths.count <= 16,
              manifest.runtimeConfigPaths.allSatisfy({ !$0.isEmpty && $0.count <= 1_024 }),
              !manifest.actions.isEmpty,
              manifest.actions.count <= 32 else { return false }
        var actionIDs = Set<String>()
        var presentationContracts: [String: PresentationContract] = [:]
        for action in manifest.actions {
            let presentationIsValid: Bool
            switch (action.presentationId, action.presentationTitle) {
            case (nil, nil):
                presentationIsValid = true
            case let (.some(identifier), .some(title)):
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let modes = Set(action.modes)
                let baseIsValid = isIdentifier(identifier)
                    && !trimmedTitle.isEmpty
                    && title.count <= 80
                    && !modes.isEmpty
                    && modes.count == action.modes.count
                if let existing = presentationContracts[identifier] {
                    presentationIsValid = baseIsValid
                        && existing.title == title
                        && existing.statusPath == action.statusPath
                        && existing.preparePath == action.preparePath
                        && existing.invokePath == action.invokePath
                        && existing.streamPath == action.streamPath
                        && existing.requiresFocus == action.requiresFocus
                        && existing.modes.isDisjoint(with: modes)
                    if presentationIsValid {
                        var updated = existing
                        updated.modes.formUnion(modes)
                        presentationContracts[identifier] = updated
                    }
                } else {
                    presentationIsValid = baseIsValid
                    if presentationIsValid {
                        presentationContracts[identifier] = PresentationContract(
                            title: title,
                            statusPath: action.statusPath,
                            preparePath: action.preparePath,
                            invokePath: action.invokePath,
                            streamPath: action.streamPath,
                            requiresFocus: action.requiresFocus,
                            modes: modes
                        )
                    }
                }
            default:
                presentationIsValid = false
            }
            guard isIdentifier(action.id),
                  actionIDs.insert(action.id).inserted,
                  !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action.title.count <= 80,
                  !action.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  action.symbol.count <= 80,
                  validEndpointPath(action.statusPath),
                  action.preparePath.map(validEndpointPath) ?? true,
                  validEndpointPath(action.invokePath),
                  action.streamPath.map(validEndpointPath) ?? true,
                  action.modes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  presentationIsValid else {
                return false
            }
        }
        return true
    }

    static func expandedPath(_ path: String,
                             pluginDirectory: URL,
                             homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2)))
        }
        guard !path.hasPrefix("~") else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let root = pluginDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    static func runtimeConfigs(for plugin: InstalledActionPlugin,
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ActionPluginRuntimeConfig] {
        let candidates: [(index: Int, config: ActionPluginRuntimeConfig)] = plugin.manifest
            .runtimeConfigPaths.enumerated().compactMap { pair -> (Int, ActionPluginRuntimeConfig)? in
            let (index, path) = pair
            guard let url = expandedPath(path,
                                         pluginDirectory: plugin.directory,
                                         homeDirectory: homeDirectory),
                  let values = try? url.resourceValues(forKeys: [
                      .isRegularFileKey,
                      .isSymbolicLinkKey,
                      .fileSizeKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes,
                  let data = try? Data(contentsOf: url),
                  data.count <= ActionPluginHTTPSManifestDownloader.maximumManifestBytes,
                  let config = try? JSONDecoder().decode(ActionPluginRuntimeConfig.self,
                                                          from: data),
                  config.pluginId == plugin.manifest.id,
                  !config.token.isEmpty,
                  config.updatedAt.isFinite,
                  ActionPluginHTTPClient.isAllowedLoopbackBase(config.apiBase) else {
                return nil
            }
            return (index, config)
        }
        return candidates.sorted { lhs, rhs in
            if lhs.config.updatedAt != rhs.config.updatedAt {
                return lhs.config.updatedAt > rhs.config.updatedAt
            }
            return lhs.index < rhs.index
        }.map(\.config)
    }

    static func runtimeConfig(for plugin: InstalledActionPlugin,
                              homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ActionPluginRuntimeConfig? {
        runtimeConfigs(for: plugin, homeDirectory: homeDirectory).first
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
                    options: .regularExpression) != nil
    }

    private static func validEndpointPath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.hasPrefix("//") && !value.contains("://")
    }
}

// MARK: - HTTP transport

enum ActionPluginHTTPError: LocalizedError {
    case runtimeUnavailable
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable: return "插件服务尚未启动"
        case .invalidEndpoint: return "插件端点不是本机回环地址"
        case .invalidResponse: return "插件返回了无效响应"
        case .responseTooLarge: return "插件响应超过大小限制"
        case let .status(code): return "插件服务返回 HTTP \(code)"
        }
    }
}

enum ActionPluginStreamError: LocalizedError {
    case invalidContentType
    case invalidUTF8
    case invalidFrame
    case invalidIdentity
    case invalidSequence
    case lineTooLarge
    case tooManyEvents
    case missingTerminal
    case frameAfterTerminal
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidContentType: return "插件流响应类型无效"
        case .invalidUTF8: return "插件流包含无效文本编码"
        case .invalidFrame: return "插件流包含无效事件"
        case .invalidIdentity: return "插件流身份与当前请求不匹配"
        case .invalidSequence: return "插件流事件顺序不连续"
        case .lineTooLarge: return "插件流单条事件超过大小限制"
        case .tooManyEvents: return "插件流事件数量超过限制"
        case .missingTerminal: return "插件流在完成事件前中断"
        case .frameAfterTerminal: return "插件流在结束后继续发送事件"
        case let .remote(message): return message
        }
    }
}

protocol ActionPluginInvocationCancellable: AnyObject {
    func cancel()
}

extension URLSessionTask: ActionPluginInvocationCancellable {}

protocol ActionPluginTransport: AnyObject {
    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void)
    func prepare(plugin: InstalledActionPlugin,
                 action: ActionPluginDefinition,
                 binding: ActionPluginRuntimeBinding,
                 request payload: ActionPluginInvokeRequest,
                 completion: @escaping (Result<ActionPluginPrepareResponse, Error>) -> Void)
        -> (any ActionPluginInvocationCancellable)?
    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> (any ActionPluginInvocationCancellable)?
}

extension ActionPluginTransport {
    func prepare(plugin: InstalledActionPlugin,
                 action: ActionPluginDefinition,
                 binding: ActionPluginRuntimeBinding,
                 request payload: ActionPluginInvokeRequest,
                 completion: @escaping (Result<ActionPluginPrepareResponse, Error>) -> Void)
        -> (any ActionPluginInvocationCancellable)? {
        completion(.failure(ActionPluginHTTPError.invalidEndpoint))
        return nil
    }
}

/// Keeps cancellation continuous while a prepared action moves from the
/// plugin's HTTP request to a locally spawned connector process.
private final class ActionPluginCancellationChain: ActionPluginInvocationCancellable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    private var cancelled = false

    func install(_ task: (any ActionPluginInvocationCancellable)?) {
        installCancellation(task.map { task in { task.cancel() } })
    }

    func installAI(_ task: any AITextCancellable) {
        installCancellation { task.cancel() }
    }

    private func installCancellation(_ operation: (() -> Void)?) {
        lock.lock()
        if cancelled {
            lock.unlock()
            operation?()
            return
        }
        cancellation = operation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let operation = cancellation
        cancellation = nil
        lock.unlock()
        operation?()
    }
}

private final class ActionPluginConnectorEventSequence {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Incremental NDJSON decoder for Action Plugin stream protocol v1. Every wire
/// frame is authenticated by the HTTP binding and repeats the non-secret
/// request identity; this parser rejects any mismatch before the host sees an
/// event. UI coalescing happens later and never relaxes sequence validation.
struct ActionPluginStreamParser {
    static let protocolVersion = 1
    static let maximumWireBytes = ActionPluginHTTPClient.maximumResponseBytes
    // A terminal `complete` frame carries the authoritative array for every
    // streamed block. Keep one line large enough for the full provider output
    // (currently capped at 256 KiB) plus JSON and identity overhead.
    static let maximumLineBytes = 512 * 1_024
    static let maximumEvents = 2_048
    static let maximumBlocks = 20
    static let maximumBlockBytes = 20_000
    static let maximumTitleBytes = 200
    static let maximumSummaryBytes = 1_000
    static let maximumErrorBytes = 500
    static let maximumIdentifierBytes = 128

    private struct WireFrame: Decodable {
        let protocolVersion: Int
        let type: String
        let seq: Int
        let pluginId: String
        let runtimeInstanceId: String
        let requestId: String
        let actionId: String
        let contextId: String
        let index: Int?
        let text: String?
        let title: String?
        let blocks: [ActionPluginResultBlock]?
        let targetSummary: String?
        let message: String?
    }

    let expectedIdentity: ActionPluginStreamIdentity
    private var pendingLine = Data()
    private var totalBytes = 0
    private var eventCount = 0
    /// Marine's encoder numbers the first emitted frame as 1. Keeping the
    /// baseline explicit makes a 0-based peer fail before any partial block is
    /// exposed to the workbench.
    private var nextSequence = 1
    private var terminalResponse: ActionPluginInvokeResponse?

    /// Becomes non-nil as soon as a newline-delimited `complete` frame is
    /// validated. The transport can finish without waiting for a provider to
    /// close an otherwise keep-alive HTTP response.
    var completedResponse: ActionPluginInvokeResponse? { terminalResponse }

    init(expectedIdentity: ActionPluginStreamIdentity) {
        self.expectedIdentity = expectedIdentity
    }

    mutating func append(_ chunk: Data) throws -> [ActionPluginStreamEvent] {
        guard terminalResponse == nil else {
            if chunk.isEmpty { return [] }
            throw ActionPluginStreamError.frameAfterTerminal
        }
        guard chunk.count <= Self.maximumWireBytes - totalBytes else {
            throw ActionPluginHTTPError.responseTooLarge
        }
        totalBytes += chunk.count
        pendingLine.append(chunk)

        var events: [ActionPluginStreamEvent] = []
        while let newline = pendingLine.firstIndex(of: 0x0A) {
            let line = Data(pendingLine[..<newline])
            pendingLine.removeSubrange(...newline)
            events.append(contentsOf: try parseLine(line))
        }
        if terminalResponse != nil, !pendingLine.isEmpty {
            throw ActionPluginStreamError.frameAfterTerminal
        }
        guard pendingLine.count <= Self.maximumLineBytes else {
            throw ActionPluginStreamError.lineTooLarge
        }
        return events
    }

    mutating func finish() throws -> (events: [ActionPluginStreamEvent],
                                      response: ActionPluginInvokeResponse) {
        var events: [ActionPluginStreamEvent] = []
        if !pendingLine.isEmpty {
            let finalLine = pendingLine
            pendingLine.removeAll(keepingCapacity: false)
            events = try parseLine(finalLine)
        }
        guard let terminalResponse else {
            throw ActionPluginStreamError.missingTerminal
        }
        return (events, terminalResponse)
    }

    private mutating func parseLine(_ rawLine: Data) throws -> [ActionPluginStreamEvent] {
        guard terminalResponse == nil else {
            throw ActionPluginStreamError.frameAfterTerminal
        }
        var line = rawLine
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty,
              line.count <= Self.maximumLineBytes,
              !line.contains(0),
              String(data: line, encoding: .utf8) != nil else {
            if line.count > Self.maximumLineBytes {
                throw ActionPluginStreamError.lineTooLarge
            }
            throw line.contains(0)
                ? ActionPluginStreamError.invalidUTF8
                : ActionPluginStreamError.invalidFrame
        }
        guard eventCount < Self.maximumEvents else {
            throw ActionPluginStreamError.tooManyEvents
        }
        let frame: WireFrame
        do {
            frame = try JSONDecoder().decode(WireFrame.self, from: line)
        } catch {
            throw ActionPluginStreamError.invalidFrame
        }
        eventCount += 1
        guard frame.protocolVersion == Self.protocolVersion,
              frame.seq == nextSequence else {
            throw frame.protocolVersion == Self.protocolVersion
                ? ActionPluginStreamError.invalidSequence
                : ActionPluginStreamError.invalidFrame
        }
        nextSequence += 1

        let identity = ActionPluginStreamIdentity(pluginId: frame.pluginId,
                                                  runtimeInstanceId: frame.runtimeInstanceId,
                                                  requestId: frame.requestId,
                                                  actionId: frame.actionId,
                                                  contextId: frame.contextId)
        guard Self.validIdentity(identity), identity == expectedIdentity else {
            throw ActionPluginStreamError.invalidIdentity
        }

        switch frame.type {
        case "heartbeat":
            return [.heartbeat(identity: identity, sequence: frame.seq)]
        case "block":
            guard let index = frame.index,
                  (0..<Self.maximumBlocks).contains(index),
                  let text = frame.text,
                  Self.validText(text, maximumBytes: Self.maximumBlockBytes),
                  Self.validOptionalText(frame.title,
                                         maximumBytes: Self.maximumTitleBytes) else {
                throw ActionPluginStreamError.invalidFrame
            }
            return [.block(ActionPluginStreamBlockSnapshot(identity: identity,
                                                            sequence: frame.seq,
                                                            index: index,
                                                            text: text,
                                                            title: frame.title))]
        case "complete":
            guard let blocks = frame.blocks,
                  !blocks.isEmpty,
                  blocks.count <= Self.maximumBlocks,
                  blocks.allSatisfy({
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && Self.validText($0.text,
                                            maximumBytes: Self.maximumBlockBytes)
                          && Self.validOptionalText(
                              $0.title,
                              maximumBytes: Self.maximumTitleBytes
                          )
                  }),
                  Self.validOptionalText(frame.targetSummary,
                                         maximumBytes: Self.maximumSummaryBytes) else {
                throw ActionPluginStreamError.invalidFrame
            }
            terminalResponse = ActionPluginInvokeResponse(
                requestId: identity.requestId,
                actionId: identity.actionId,
                contextId: identity.contextId,
                blocks: blocks,
                targetSummary: frame.targetSummary
            )
            return []
        case "error":
            guard Self.validOptionalText(frame.message,
                                         maximumBytes: Self.maximumErrorBytes) else {
                throw ActionPluginStreamError.invalidFrame
            }
            throw ActionPluginStreamError.remote(
                frame.message?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? "插件生成失败"
            )
        default:
            throw ActionPluginStreamError.invalidFrame
        }
    }

    static func validIdentity(_ identity: ActionPluginStreamIdentity) -> Bool {
        [identity.pluginId,
         identity.runtimeInstanceId,
         identity.requestId,
         identity.actionId,
         identity.contextId].allSatisfy { value in
            guard !value.isEmpty,
                  value.utf8.count <= maximumIdentifierBytes,
                  !value.unicodeScalars.contains(where: {
                      !$0.isASCII || $0.value < 0x21 || $0.value > 0x7E
                  }) else {
                return false
            }
            return true
        }
    }

    static func validText(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes && !value.contains("\0")
    }

    static func validOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
        value.map { validText($0, maximumBytes: maximumBytes) } ?? true
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct ActionPluginResponseBuffer {
    private(set) var data = Data()

    mutating func append(_ chunk: Data, maximumBytes: Int) -> Bool {
        guard data.count <= maximumBytes,
              chunk.count <= maximumBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

private final class ActionPluginSessionDelegate: NSObject, URLSessionDataDelegate {
    typealias Completion = (Result<(Data, URLResponse), Error>) -> Void

    private enum StreamMode {
        case awaitingResponse
        case ndjson
        case json
    }

    private struct Pending {
        var buffer = ActionPluginResponseBuffer()
        let completion: Completion
    }

    private struct StreamingPending {
        var mode: StreamMode = .awaitingResponse
        var buffer = ActionPluginResponseBuffer()
        var parser: ActionPluginStreamParser
        let onEvent: (ActionPluginStreamEvent) -> Void
        let completion: (Result<ActionPluginInvokeResponse, Error>) -> Void
    }

    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var streamingPending: [Int: StreamingPending] = [:]

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func perform(session: URLSession,
                 request: URLRequest,
                 completion: @escaping Completion) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        pending[task.taskIdentifier] = Pending(completion: completion)
        lock.unlock()
        task.resume()
        return task
    }

    func performStream(session: URLSession,
                       request: URLRequest,
                       expectedIdentity: ActionPluginStreamIdentity,
                       onEvent: @escaping (ActionPluginStreamEvent) -> Void,
                       completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        streamingPending[task.taskIdentifier] = StreamingPending(
            parser: ActionPluginStreamParser(expectedIdentity: expectedIdentity),
            onEvent: onEvent,
            completion: completion
        )
        lock.unlock()
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            finish(taskIdentifier: dataTask.taskIdentifier,
                   result: .failure(ActionPluginHTTPError.responseTooLarge))
            finishStream(taskIdentifier: dataTask.taskIdentifier,
                         result: .failure(ActionPluginHTTPError.responseTooLarge))
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }

        var streamFailure: ((Result<ActionPluginInvokeResponse, Error>) -> Void)?
        var failureError: Error?
        lock.lock()
        if var item = streamingPending[dataTask.taskIdentifier] {
            do {
                let contentType = try ActionPluginHTTPClient.validatedContentType(response)
                switch contentType {
                case "application/x-ndjson": item.mode = .ndjson
                case "application/json": item.mode = .json
                default: throw ActionPluginStreamError.invalidContentType
                }
                streamingPending[dataTask.taskIdentifier] = item
            } catch {
                streamFailure = streamingPending.removeValue(
                    forKey: dataTask.taskIdentifier
                )?.completion
                failureError = error
            }
        }
        lock.unlock()
        if let streamFailure, let failureError {
            completionHandler(.cancel)
            dataTask.cancel()
            streamFailure(.failure(failureError))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        var overflow: Pending?
        var streamEvents: [ActionPluginStreamEvent] = []
        var streamEventHandler: ((ActionPluginStreamEvent) -> Void)?
        var streamFailure: ((Result<ActionPluginInvokeResponse, Error>) -> Void)?
        var streamFailureError: Error?
        var streamTerminal: (
            completion: (Result<ActionPluginInvokeResponse, Error>) -> Void,
            response: ActionPluginInvokeResponse
        )?
        lock.lock()
        if var item = pending[dataTask.taskIdentifier] {
            if item.buffer.append(data, maximumBytes: maximumResponseBytes) {
                pending[dataTask.taskIdentifier] = item
            } else {
                overflow = pending.removeValue(forKey: dataTask.taskIdentifier)
            }
        }
        if var item = streamingPending[dataTask.taskIdentifier] {
            do {
                switch item.mode {
                case .awaitingResponse:
                    throw ActionPluginHTTPError.invalidResponse
                case .ndjson:
                    streamEvents = try item.parser.append(data)
                    streamEventHandler = item.onEvent
                case .json:
                    guard item.buffer.append(data, maximumBytes: maximumResponseBytes) else {
                        throw ActionPluginHTTPError.responseTooLarge
                    }
                }
                if let response = item.parser.completedResponse {
                    _ = streamingPending.removeValue(forKey: dataTask.taskIdentifier)
                    streamTerminal = (item.completion, response)
                } else {
                    streamingPending[dataTask.taskIdentifier] = item
                }
            } catch {
                streamFailure = streamingPending.removeValue(
                    forKey: dataTask.taskIdentifier
                )?.completion
                streamFailureError = error
            }
        }
        lock.unlock()
        if let overflow {
            dataTask.cancel()
            overflow.completion(.failure(ActionPluginHTTPError.responseTooLarge))
        }
        if let streamFailure, let streamFailureError {
            dataTask.cancel()
            streamFailure(.failure(streamFailureError))
            return
        }
        if let streamEventHandler {
            streamEvents.forEach(streamEventHandler)
        }
        if let streamTerminal {
            // The protocol's terminal frame is authoritative; retaining a
            // keep-alive response after it must not hold the action slot open.
            dataTask.cancel()
            streamTerminal.completion(.success(streamTerminal.response))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let item: Pending?
        let streamItemValue: StreamingPending?
        lock.lock()
        item = pending.removeValue(forKey: task.taskIdentifier)
        streamItemValue = streamingPending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let item {
            if let error {
                item.completion(.failure(error))
            } else if let response = task.response {
                item.completion(.success((item.buffer.data, response)))
            } else {
                item.completion(.failure(ActionPluginHTTPError.invalidResponse))
            }
        }

        guard var streamItem = streamItemValue else { return }
        if let error {
            streamItem.completion(.failure(error))
            return
        }
        switch streamItem.mode {
        case .awaitingResponse:
            streamItem.completion(.failure(ActionPluginHTTPError.invalidResponse))
        case .json:
            streamItem.completion(ActionPluginHTTPClient.decodeResponse(
                data: streamItem.buffer.data,
                response: task.response,
                as: ActionPluginInvokeResponse.self
            ))
        case .ndjson:
            do {
                let finished = try streamItem.parser.finish()
                finished.events.forEach(streamItem.onEvent)
                streamItem.completion(.success(finished.response))
            } catch {
                streamItem.completion(.failure(error))
            }
        }
    }

    private func finish(taskIdentifier: Int,
                        result: Result<(Data, URLResponse), Error>) {
        let item: Pending?
        lock.lock()
        item = pending.removeValue(forKey: taskIdentifier)
        lock.unlock()
        item?.completion(result)
    }

    private func finishStream(taskIdentifier: Int,
                              result: Result<ActionPluginInvokeResponse, Error>) {
        let item: StreamingPending?
        lock.lock()
        item = streamingPending.removeValue(forKey: taskIdentifier)
        lock.unlock()
        item?.completion(result)
    }
}

final class ActionPluginHTTPClient: ActionPluginTransport {
    static let maximumResponseBytes = 1_048_576
    static let streamRequestTimeout: TimeInterval = 270
    static let legacyRequestTimeout: TimeInterval = 120
    private let session: URLSession
    private let streamingDelegate: ActionPluginSessionDelegate?

    init(session: URLSession? = nil,
         configuration suppliedConfiguration: URLSessionConfiguration? = nil) {
        if let session {
            self.session = session
            streamingDelegate = nil
        } else {
            let configuration = suppliedConfiguration ?? URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let delegate = ActionPluginSessionDelegate(
                maximumResponseBytes: Self.maximumResponseBytes
            )
            streamingDelegate = delegate
            self.session = URLSession(configuration: configuration,
                                      delegate: delegate,
                                      delegateQueue: nil)
        }
    }

    static func isAllowedLoopbackBase(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        return true
    }

    static func endpointURL(apiBase: String, path: String) -> URL? {
        guard isAllowedLoopbackBase(apiBase),
              path.hasPrefix("/"),
              !path.hasPrefix("//"),
              !path.contains("://") else { return nil }
        let base = apiBase.hasSuffix("/") ? String(apiBase.dropLast()) : apiBase
        return URL(string: base + path)
    }

    static func makeRequest(config: ActionPluginRuntimeConfig,
                            path: String,
                            method: String,
                            body: Data? = nil,
                            timeout: TimeInterval,
                            accept: String = "application/json") -> URLRequest? {
        guard let url = endpointURL(apiBase: config.apiBase, path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void) {
        if let binding,
           binding.config.pluginId != plugin.manifest.id {
            completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
            return
        }
        let bindings = binding.map { [$0] }
            ?? ActionPluginManifestLoader.runtimeConfigs(for: plugin).map(ActionPluginRuntimeBinding.init)
        guard !bindings.isEmpty else {
            completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
            return
        }

        func attempt(_ index: Int, lastError: Error?) {
            guard bindings.indices.contains(index) else {
                completion(.failure(lastError ?? ActionPluginHTTPError.runtimeUnavailable))
                return
            }
            let candidate = bindings[index]
            guard let request = Self.makeRequest(config: candidate.config,
                                                 path: action.statusPath,
                                                 method: "GET",
                                                 timeout: 1.5) else {
                attempt(index + 1, lastError: ActionPluginHTTPError.invalidEndpoint)
                return
            }
            perform(request, decode: ActionPluginStatus.self) { result in
                switch result {
                case let .success(status):
                    completion(.success(ActionPluginStatusSnapshot(value: status,
                                                                   binding: candidate)))
                case let .failure(error):
                    attempt(index + 1, lastError: error)
                }
            }
        }
        attempt(0, lastError: nil)
    }

    func prepare(plugin: InstalledActionPlugin,
                 action: ActionPluginDefinition,
                 binding: ActionPluginRuntimeBinding,
                 request payload: ActionPluginInvokeRequest,
                 completion: @escaping (Result<ActionPluginPrepareResponse, Error>) -> Void)
        -> (any ActionPluginInvocationCancellable)? {
        guard binding.config.pluginId == plugin.manifest.id,
              let preparePath = action.preparePath,
              let runtimeInstanceId = binding.config.instanceId,
              payload.pluginId == plugin.manifest.id,
              payload.runtimeInstanceId == runtimeInstanceId else {
            completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
            return nil
        }
        do {
            let body = try JSONEncoder().encode(payload)
            guard let request = Self.makeRequest(
                config: binding.config,
                path: preparePath,
                method: "POST",
                body: body,
                timeout: Self.legacyRequestTimeout
            ) else {
                completion(.failure(ActionPluginHTTPError.invalidEndpoint))
                return nil
            }
            return perform(request,
                           decode: ActionPluginPrepareResponse.self,
                           completion: completion)
        } catch {
            completion(.failure(error))
            return nil
        }
    }

    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> (any ActionPluginInvocationCancellable)? {
        guard binding.config.pluginId == plugin.manifest.id else {
            completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
            return nil
        }
        do {
            let body = try JSONEncoder().encode(payload)
            let isStreaming = action.streamPath != nil
            let path = action.streamPath ?? action.invokePath
            if isStreaming {
                guard let runtimeInstanceId = binding.config.instanceId,
                      payload.pluginId == plugin.manifest.id,
                      payload.runtimeInstanceId == runtimeInstanceId else {
                    completion(.failure(ActionPluginHTTPError.runtimeUnavailable))
                    return nil
                }
            }
            guard let request = Self.makeRequest(
                config: binding.config,
                path: path,
                method: "POST",
                body: body,
                timeout: isStreaming
                    ? Self.streamRequestTimeout
                    : Self.legacyRequestTimeout,
                accept: isStreaming
                    ? "application/x-ndjson, application/json;q=0.8"
                    : "application/json"
            ) else {
                completion(.failure(ActionPluginHTTPError.invalidEndpoint))
                return nil
            }
            guard isStreaming else {
                return perform(request,
                               decode: ActionPluginInvokeResponse.self,
                               completion: completion)
            }

            let expectedIdentity = ActionPluginStreamIdentity(
                pluginId: plugin.manifest.id,
                runtimeInstanceId: binding.config.instanceId!,
                requestId: payload.requestId,
                actionId: payload.actionId,
                contextId: payload.contextId
            )
            guard ActionPluginStreamParser.validIdentity(expectedIdentity) else {
                completion(.failure(ActionPluginStreamError.invalidIdentity))
                return nil
            }
            if let streamingDelegate {
                return streamingDelegate.performStream(
                    session: session,
                    request: request,
                    expectedIdentity: expectedIdentity,
                    onEvent: onStreamEvent,
                    completion: completion
                )
            }
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let data, data.count <= Self.maximumResponseBytes else {
                    completion(.failure(data == nil
                        ? ActionPluginHTTPError.invalidResponse
                        : ActionPluginHTTPError.responseTooLarge))
                    return
                }
                do {
                    switch try Self.validatedContentType(response) {
                    case "application/json":
                        completion(Self.decodeResponse(data: data,
                                                       response: response,
                                                       as: ActionPluginInvokeResponse.self))
                    case "application/x-ndjson":
                        var parser = ActionPluginStreamParser(
                            expectedIdentity: expectedIdentity
                        )
                        try parser.append(data).forEach(onStreamEvent)
                        let finished = try parser.finish()
                        finished.events.forEach(onStreamEvent)
                        completion(.success(finished.response))
                    default:
                        completion(.failure(ActionPluginStreamError.invalidContentType))
                    }
                } catch {
                    completion(.failure(error))
                }
            }
            task.resume()
            return task
        } catch {
            completion(.failure(error))
            return nil
        }
    }

    @discardableResult
    private func perform<T: Decodable & Sendable>(_ request: URLRequest,
                                       decode type: T.Type,
                                       completion: @escaping (Result<T, Error>) -> Void)
        -> URLSessionDataTask {
        if let streamingDelegate {
            return streamingDelegate.perform(session: session, request: request) { result in
                switch result {
                case let .success((data, response)):
                    completion(Self.decodeResponse(data: data,
                                                   response: response,
                                                   as: type))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(ActionPluginHTTPError.invalidResponse))
                return
            }
            guard data.count <= Self.maximumResponseBytes else {
                completion(.failure(ActionPluginHTTPError.responseTooLarge))
                return
            }
            completion(Self.decodeResponse(data: data, response: response, as: type))
        }
        task.resume()
        return task
    }

    fileprivate static func decodeResponse<T: Decodable>(data: Data,
                                                          response: URLResponse?,
                                                          as type: T.Type) -> Result<T, Error> {
        guard let http = response as? HTTPURLResponse else {
            return .failure(ActionPluginHTTPError.invalidResponse)
        }
        guard let responseURL = http.url,
              isAllowedLoopbackURL(responseURL) else {
            return .failure(ActionPluginHTTPError.invalidEndpoint)
        }
        guard (200...299).contains(http.statusCode) else {
            return .failure(ActionPluginHTTPError.status(http.statusCode))
        }
        guard data.count <= maximumResponseBytes else {
            return .failure(ActionPluginHTTPError.responseTooLarge)
        }
        do {
            return .success(try JSONDecoder().decode(type, from: data))
        } catch {
            return .failure(error)
        }
    }

    fileprivate static func validatedContentType(_ response: URLResponse?) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw ActionPluginHTTPError.invalidResponse
        }
        guard let responseURL = http.url,
              isAllowedLoopbackURL(responseURL) else {
            throw ActionPluginHTTPError.invalidEndpoint
        }
        guard (200...299).contains(http.statusCode) else {
            throw ActionPluginHTTPError.status(http.statusCode)
        }
        let raw = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        return raw.split(separator: ";", maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
    }

    fileprivate static func isAllowedLoopbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              url.user == nil,
              url.password == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true else { return false }
        return true
    }
}

// MARK: - Runtime host

struct ActionPluginPresentation: Equatable {
    let key: ActionPluginKey
    let presentationKey: ActionPluginPresentationKey
    let pluginName: String
    let title: String
    let symbol: String
    let label: String
    let targetSummary: String?
    let available: Bool
    let canInvoke: Bool
    let requiresFocus: Bool
    /// `preparePath` delegates model execution to RimeBuffer's selected AI
    /// connector. This semantic flag lets the workbench promote a prepared
    /// action without coupling its UI to a specific plugin id such as Marine.
    let preparedGenerationActionIDs: Set<String>
    let running: Bool
    let waitingForFirstContent: Bool

    var isPreparedGeneration: Bool { !preparedGenerationActionIDs.isEmpty }
}

enum ActionPluginPrimaryPresentationRules {
    /// Promotion must be deterministic. Only an owner whose entire resolved
    /// action surface is one prepared presentation can share the AI primary
    /// control; any additional presentation keeps the explicit shelf so Return
    /// never chooses between capabilities.
    static func primary(in presentations: [ActionPluginPresentation])
        -> ActionPluginPresentation? {
        // The primary control replaces the whole action shelf for this owner.
        // If any second presentation exists (prepared or legacy), keeping the
        // ordinary shelf + delivery behavior is the only unambiguous choice.
        guard presentations.count == 1,
              presentations[0].isPreparedGeneration else { return nil }
        return presentations[0]
    }

    static func secondary(in presentations: [ActionPluginPresentation])
        -> [ActionPluginPresentation] {
        primary(in: presentations) == nil ? presentations : []
    }
}

enum ActionPluginRoutingRules {
    static func focusBindingMatches(bound: FocusToken?, current: FocusToken?) -> Bool {
        guard let bound, let current else { return false }
        return bound == current
    }

    static func statusMatches(_ status: ActionPluginStatus?,
                              action: ActionPluginDefinition,
                              contextId: String) -> Bool {
        guard let status,
              status.available,
              status.actionId == action.id,
              status.contextId == contextId else { return false }
        return action.modes.isEmpty || status.mode.map(action.modes.contains) == true
    }

    static func shouldStageDirect(responseMatches: Bool,
                                  focusValid: Bool,
                                  currentStatusMatches: Bool,
                                  invocationMarkedStale: Bool) -> Bool {
        responseMatches
            && focusValid
            && currentStatusMatches
            && !invocationMarkedStale
    }
}

enum ActionPluginDeliveryFailure: Equatable {
    case stale
    case targetChanged
    case unavailable
}

enum ActionPluginDeliveryDecision: Equatable {
    case allowed
    case rejected(ActionPluginDeliveryFailure)
}

struct ActionPluginFocusAccess {
    let currentToken: () -> FocusToken?
    let isValid: (FocusToken) -> Bool
    let secureInputEnabled: () -> Bool

    static let live = ActionPluginFocusAccess(
        currentToken: { InputFocusCoordinator.shared.liveTarget()?.token },
        isValid: { InputFocusCoordinator.shared.liveTarget(expected: $0) != nil },
        secureInputEnabled: { IsSecureEventInputEnabled() }
    )
}

/// Discovers declarative action plugins and coordinates one foreground request
/// at a time. A bounded set of target-changed streams may finish in the
/// background solely so their terminal result can enter the review inbox.
/// Plugins receive only request/action/context identifiers over local
/// HTTP. The FocusToken never leaves this process and every result still waits
/// in BufferModel for the user's explicit Return/paper-plane delivery action.
final class ActionPluginHost {
    static let shared = ActionPluginHost(pluginIsSelected: {
        BufferPluginSelectionStore.shared.isSelectedExternal(pluginID: $0)
    }, configuredInvocationTimeout: { pluginID in
        guard pluginID == PluginConfigurationCatalog.marinePluginID else {
            return nil
        }
        return PluginConfigurationCatalog.marineInvocationTimeout()
    })
    static let defaultInvocationTimeout: TimeInterval = 270
    private static let maximumBackgroundInvocations = 4

    static func resolvedInvocationTimeout(
        fallback: TimeInterval,
        configured: TimeInterval?
    ) -> TimeInterval {
        if let configured, configured.isFinite {
            return max(0.01, configured)
        }
        return max(0.01, fallback)
    }

    private struct PendingStreamBlock {
        let index: Int
        let text: String
        let title: String?
    }

    private struct HostedStreamSegment {
        let index: Int
        let text: String
        let title: String?
    }

    private static let streamSegmentIndexStride = 100_000

    private struct ActiveInvocation {
        let nonce: UUID
        let hostGeneration: UInt64
        let key: ActionPluginKey
        let plugin: InstalledActionPlugin
        let action: ActionPluginDefinition
        let requestId: String
        let contextId: String
        /// Nil means the user explicitly invoked a context-only action without
        /// an IMK target. Such output may stream into the workbench but never
        /// gains target-bound delivery authority.
        let focusToken: FocusToken?
        let binding: ActionPluginRuntimeBinding
        let targetSummary: String?
        let streaming: Bool
        let startedAt: TimeInterval
        var activityMessage: String
        var markedStale: Bool
        var task: (any ActionPluginInvocationCancellable)?
        var receivedFirstContent: Bool
        /// Latest authoritative snapshot for every upstream provider index.
        /// Host-created semantic children are derived from this full map.
        var streamLogicalBlocks: [Int: PendingStreamBlock]
        var streamBlockIDs: [Int: UUID]
        var stagedStreamBlockIDs: Set<UUID>
        var pendingStreamBlocks: [Int: PendingStreamBlock]
        var streamFlushScheduled: Bool
    }

    private struct ObservedStatus: Equatable {
        let snapshot: ActionPluginStatusSnapshot
        let focusToken: FocusToken?
        let plugin: InstalledActionPlugin
        let action: ActionPluginDefinition
    }

    private struct StatusRequest: Equatable {
        let id: UUID
        let focusToken: FocusToken?
        let plugin: InstalledActionPlugin
        let action: ActionPluginDefinition
    }

    private let client: any ActionPluginTransport
    private let focus: ActionPluginFocusAccess
    private let bufferModel: BufferModel
    private let inboundBus: InboundBus
    private let rootURL: URL
    private let pluginLoader: (URL) -> [InstalledActionPlugin]
    private let pluginIsSelected: (String) -> Bool
    private let connectorProvider: () -> (any AITextProvider)?
    private let runtimeBindingIsCurrent: (InstalledActionPlugin, ActionPluginRuntimeBinding) -> Bool
    private let invocationTimeout: TimeInterval
    private let configuredInvocationTimeout: (String) -> TimeInterval?
    private let runtimeAuthorityRecheckInterval: TimeInterval
    private let streamDrainDidRun: () -> Void
    private var managementObserver: NSObjectProtocol?
    private var bufferObserver: NSObjectProtocol?
    private var plugins: [String: InstalledActionPlugin] = [:]
    private var installedManifestSnapshot: [String: InstalledActionPlugin] = [:]
    private var statuses: [ActionPluginKey: ObservedStatus] = [:]
    private var failures: [ActionPluginKey: String] = [:]
    private var statusRequests: [ActionPluginKey: StatusRequest] = [:]
    private var activeInvocation: ActiveInvocation?
    private var backgroundInvocations: [UUID: ActiveInvocation] = [:]
    private var backgroundInvocationOrder: [UUID] = []
    private var streamAuthorityValidatedAt: [UUID: TimeInterval] = [:]
    private let streamEventMailboxLock = NSLock()
    private var queuedStreamBlocks: [UUID: [Int: ActionPluginStreamBlockSnapshot]] = [:]
    private var queuedStreamHeartbeats: [UUID: (
        identity: ActionPluginStreamIdentity,
        sequence: Int
    )] = [:]
    private var scheduledStreamDrains: Set<UUID> = []
    private var deliveryBindings: [String: ActionPluginRuntimeBinding] = [:]
    private var deliveryPlugins: [String: InstalledActionPlugin] = [:]
    private var deliveryKeys: [String: ActionPluginKey] = [:]
    private var deliveryBindingOrder: [String] = []
    private var lastManifestReload: TimeInterval = 0
    private var lastStatusRefresh: TimeInterval = 0
    private var hostGeneration: UInt64 = 1

    var onChange: (() -> Void)?
    /// Plugin failures belong to the workbench status shelf, never to the
    /// text-bearing BufferModel rail. A background retention warning has
    /// priority over the current foreground request so an older parked result
    /// cannot disappear merely because a newer loading owner exists.
    private var foregroundFailureMessage: String?
    private var backgroundNoticeMessage: String?
    var workbenchFailureMessage: String? {
        backgroundNoticeMessage ?? foregroundFailureMessage
    }

    init(rootURL: URL = ActionPluginManifestLoader.defaultRootURL,
         client: any ActionPluginTransport = ActionPluginHTTPClient(),
         focus: ActionPluginFocusAccess = .live,
         bufferModel: BufferModel = .shared,
         inboundBus: InboundBus = .shared,
         pluginLoader: @escaping (URL) -> [InstalledActionPlugin] = {
             ActionPluginManager.enabledPlugins(from: $0)
         },
         pluginIsSelected: @escaping (String) -> Bool = { _ in true },
         connectorProvider: @escaping () -> (any AITextProvider)? = {
             AITextConnectorRegistry.shared.selectedProvider
         },
         runtimeBindingIsCurrent: @escaping (
             InstalledActionPlugin,
             ActionPluginRuntimeBinding
         ) -> Bool = { plugin, binding in
             ActionPluginManifestLoader.runtimeConfigs(for: plugin)
                 .contains(binding.config)
         },
         invocationTimeout: TimeInterval = ActionPluginHost.defaultInvocationTimeout,
         configuredInvocationTimeout: @escaping (String) -> TimeInterval? = {
             _ in nil
         },
         runtimeAuthorityRecheckInterval: TimeInterval = 0.5,
         streamDrainDidRun: @escaping () -> Void = {}) {
        self.rootURL = rootURL
        self.client = client
        self.focus = focus
        self.bufferModel = bufferModel
        self.inboundBus = inboundBus
        self.pluginLoader = pluginLoader
        self.pluginIsSelected = pluginIsSelected
        self.connectorProvider = connectorProvider
        self.runtimeBindingIsCurrent = runtimeBindingIsCurrent
        self.invocationTimeout = max(0.01, invocationTimeout)
        self.configuredInvocationTimeout = configuredInvocationTimeout
        self.runtimeAuthorityRecheckInterval = max(0, runtimeAuthorityRecheckInterval)
        self.streamDrainDidRun = streamDrainDidRun
        reloadManifests(force: true)
        managementObserver = NotificationCenter.default.addObserver(
            forName: ActionPluginManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let changedRoot = notification.userInfo?[ActionPluginManager.rootPathUserInfoKey] as? String,
                  changedRoot == self.rootURL.standardizedFileURL.path else { return }
            self.pluginConfigurationDidChange(
                changedPluginID: notification.userInfo?[ActionPluginManager.changedPluginIDUserInfoKey]
                    as? String
            )
        }
        bufferObserver = NotificationCenter.default.addObserver(
            forName: .bufferModelDidChange,
            object: bufferModel,
            queue: .main
        ) { [weak self] _ in
            self?.bufferModelDidChange()
        }
    }

    deinit {
        if let managementObserver {
            NotificationCenter.default.removeObserver(managementObserver)
        }
        if let bufferObserver {
            NotificationCenter.default.removeObserver(bufferObserver)
        }
    }

    var presentations: [ActionPluginPresentation] {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentFocusToken = focus.currentToken()
        let secureInputEnabled = focus.secureInputEnabled()
        return plugins.values
            .filter { pluginIsSelected($0.manifest.id) }
            .sorted { $0.manifest.name < $1.manifest.name }
            .flatMap { plugin in
            func makePresentation(for action: ActionPluginDefinition) -> ActionPluginPresentation {
                let key = ActionPluginKey(pluginId: plugin.manifest.id,
                                          actionId: action.id)
                let observed = statuses[key].flatMap {
                    $0.plugin == plugin && $0.action == action ? $0 : nil
                }
                let status = observed?.snapshot.value
                let contextId = status?.contextId ?? ""
                let focusRequirementMatches = !action.requiresFocus
                    || ActionPluginRoutingRules.focusBindingMatches(
                        bound: observed?.focusToken,
                        current: currentFocusToken
                    )
                let available = focusRequirementMatches && !contextId.isEmpty
                    && ActionPluginRoutingRules.statusMatches(status,
                                                              action: action,
                                                              contextId: contextId)
                let running = activeInvocation?.key == key
                let waitingForFirstContent = activeInvocation.map {
                    $0.key == key
                        && $0.streaming
                        && !$0.markedStale
                        && !$0.receivedFirstContent
                } ?? false
                let connectorStatus: (ready: Bool, message: String?)
                if action.preparePath == nil {
                    connectorStatus = (true, nil)
                } else if let connector = connectorProvider() {
                    switch connector.availability {
                    case .ready:
                        connectorStatus = (true, nil)
                    case let .unavailable(message):
                        connectorStatus = (false, message)
                    }
                } else {
                    connectorStatus = (false, "请先选择 AI 模型连接器")
                }
                let label = status?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedLabel = connectorStatus.message
                    ?? (label?.isEmpty == false ? label.map { String($0.prefix(120)) } : nil)
                    ?? (failures[key] ?? action.title)
                return ActionPluginPresentation(
                    key: key,
                    presentationKey: ActionPluginPresentationKey(
                        pluginId: plugin.manifest.id,
                        presentationId: action.presentationId ?? action.id
                    ),
                    pluginName: plugin.manifest.name,
                    title: action.title,
                    symbol: action.symbol,
                    label: resolvedLabel,
                    targetSummary: status?.targetSummary.map { String($0.prefix(1_000)) },
                    available: available,
                    canInvoke: available && connectorStatus.ready
                        && !secureInputEnabled
                        && (!action.requiresFocus || currentFocusToken != nil)
                        && activeInvocation == nil,
                    requiresFocus: action.requiresFocus,
                    preparedGenerationActionIDs: action.preparePath == nil
                        ? []
                        : [action.id],
                    running: running,
                    waitingForFirstContent: waitingForFirstContent
                )
            }

            let candidates = plugin.manifest.actions.map { action in
                (action: action, presentation: makePresentation(for: action))
            }
            var renderedGroups = Set<String>()
            var resolved: [ActionPluginPresentation] = []
            for candidate in candidates {
                guard let presentationId = candidate.action.presentationId,
                      let presentationTitle = candidate.action.presentationTitle else {
                    resolved.append(candidate.presentation)
                    continue
                }
                guard renderedGroups.insert(presentationId).inserted else { continue }

                let group = candidates.filter { $0.action.presentationId == presentationId }
                // The current status makes exactly one contextual action
                // invokable. Keep a running action visible while its status is
                // revalidated, then prefer the currently invokable/available
                // member and finally the manifest's stable first member.
                let selected = group.first(where: { $0.presentation.running })
                    ?? group.first(where: { $0.presentation.canInvoke })
                    ?? group.first(where: { $0.presentation.available })
                    ?? group[0]
                let symbol = group[0].presentation.symbol
                resolved.append(ActionPluginPresentation(
                    key: selected.presentation.key,
                    presentationKey: selected.presentation.presentationKey,
                    pluginName: selected.presentation.pluginName,
                    title: presentationTitle,
                    symbol: symbol,
                    label: selected.presentation.label,
                    targetSummary: selected.presentation.targetSummary,
                    available: selected.presentation.available,
                    canInvoke: selected.presentation.canInvoke,
                    requiresFocus: selected.presentation.requiresFocus,
                    preparedGenerationActionIDs: Set(group.compactMap {
                        $0.action.preparePath == nil ? nil : $0.action.id
                    }),
                    running: selected.presentation.running,
                    waitingForFirstContent: selected.presentation.waitingForFirstContent
                ))
            }
            return resolved
        }
    }

    var primaryGenerationPresentation: ActionPluginPresentation? {
        ActionPluginPrimaryPresentationRules.primary(in: presentations)
    }

    var secondaryPresentations: [ActionPluginPresentation] {
        ActionPluginPrimaryPresentationRules.secondary(in: presentations)
    }

    func refreshStatuses(force: Bool = false,
                         onlyPluginID: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = ProcessInfo.processInfo.systemUptime
        reloadManifests(force: force || now - lastManifestReload >= 5)
        guard force || now - lastStatusRefresh >= 0.75 else { return }
        if onlyPluginID == nil {
            lastStatusRefresh = now
        }
        if force {
            // A panel may have been hidden while the browser target changed.
            // Disable cached actions until the fresh status request returns;
            // final invoke verification remains the last safety gate.
            let previousCount = statuses.count
            if let onlyPluginID {
                statuses = statuses.filter { $0.key.pluginId != onlyPluginID }
            } else {
                statuses.removeAll()
            }
            if statuses.count != previousCount {
                onChange?()
            }
        }

        for plugin in plugins.values
            where pluginIsSelected(plugin.manifest.id)
                && (onlyPluginID == nil || plugin.manifest.id == onlyPluginID) {
            for action in plugin.manifest.actions {
                let key = ActionPluginKey(pluginId: plugin.manifest.id,
                                          actionId: action.id)
                guard statusRequests[key] == nil else { continue }
                let request = StatusRequest(id: UUID(),
                                            focusToken: focus.currentToken(),
                                            plugin: plugin,
                                            action: action)
                statusRequests[key] = request
                client.fetchStatus(plugin: plugin,
                                   action: action,
                                   binding: nil) { [weak self] result in
                    DispatchQueue.main.async {
                        self?.handleStatus(result,
                                           plugin: plugin,
                                           action: action,
                                           key: key,
                                           request: request)
                    }
                }
            }
        }
    }

    @discardableResult
    func invoke(_ key: ActionPluginKey) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeInvocation == nil,
              !focus.secureInputEnabled(),
              pluginIsSelected(key.pluginId),
              let plugin = plugins[key.pluginId],
              let action = plugin.manifest.actions.first(where: { $0.id == key.actionId }),
              let observed = statuses[key],
              observed.plugin == plugin,
              observed.action == action,
              livePlugin(withID: key.pluginId) == plugin,
              let status = Optional(observed.snapshot.value),
              let contextId = status.contextId,
              ActionPluginRoutingRules.statusMatches(status,
                                                     action: action,
                                                     contextId: contextId) else {
            return false
        }

        let focusToken = focus.currentToken()
        if let focusToken {
            guard focus.isValid(focusToken) else { return false }
        } else {
            guard !action.requiresFocus else { return false }
        }
        if action.requiresFocus {
            guard ActionPluginRoutingRules.focusBindingMatches(
                bound: observed.focusToken,
                current: focusToken
            ) else { return false }
        }

        let binding = observed.snapshot.binding
        let preparedByPlugin = action.preparePath != nil
        // Locally generated connector snapshots use the same strict streaming
        // authority and stale-result retention rules as remote NDJSON streams.
        let streaming = preparedByPlugin || action.streamPath != nil
        guard runtimeBindingIsCurrent(plugin, binding) else {
            failures[key] = "插件运行实例已失效，请稍后重试"
            onChange?()
            return false
        }
        if streaming, binding.config.instanceId?.isEmpty != false {
            failures[key] = "插件流运行实例不可用"
            onChange?()
            return false
        }

        // Freeze the plugin-specific preference at the invocation boundary.
        // Later settings changes affect only the next request.
        let frozenInvocationTimeout = Self.resolvedInvocationTimeout(
            fallback: invocationTimeout,
            configured: configuredInvocationTimeout(plugin.manifest.id)
        )
        let requestId = UUID().uuidString.lowercased()
        let nonce = UUID()
        let cancellationChain = preparedByPlugin ? ActionPluginCancellationChain() : nil
        let startedAt = ProcessInfo.processInfo.systemUptime
        let initialActivity = preparedByPlugin
            ? "正在准备话术"
            : "正在等待 \(plugin.manifest.name)"
        clearWorkbenchMessages()
        activeInvocation = ActiveInvocation(nonce: nonce,
                                            hostGeneration: hostGeneration,
                                            key: key,
                                            plugin: plugin,
                                            action: action,
                                            requestId: requestId,
                                            contextId: contextId,
                                            focusToken: focusToken,
                                            binding: binding,
                                            targetSummary: status.targetSummary,
                                            streaming: streaming,
                                            startedAt: startedAt,
                                            activityMessage: initialActivity,
                                            markedStale: false,
                                            task: cancellationChain,
                                            receivedFirstContent: false,
                                            streamLogicalBlocks: [:],
                                            streamBlockIDs: [:],
                                            stagedStreamBlockIDs: [],
                                            pendingStreamBlocks: [:],
                                            streamFlushScheduled: false)
        if streaming {
            streamAuthorityValidatedAt[nonce] = ProcessInfo.processInfo.systemUptime
        }
        bufferModel.beginTransientLoading(
            requestId: requestId,
            message: "\(initialActivity) · 0 秒"
        )
        if streaming { scheduleInvocationActivityTick(nonce: nonce) }
        onChange?()

        let payload = ActionPluginInvokeRequest(
            requestId: requestId,
            actionId: action.id,
            contextId: contextId,
            pluginId: streaming ? plugin.manifest.id : nil,
            runtimeInstanceId: streaming ? binding.config.instanceId : nil
        )
        if let cancellationChain {
            let task = client.prepare(
                plugin: plugin,
                action: action,
                binding: binding,
                request: payload
            ) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handlePreparation(
                        result,
                        nonce: nonce,
                        requestId: requestId,
                        plugin: plugin,
                        action: action,
                        cancellationChain: cancellationChain
                    )
                }
            }
            cancellationChain.install(task)
        } else {
            let task = client.invoke(plugin: plugin,
                                     action: action,
                                     binding: binding,
                                     request: payload,
                                     onStreamEvent: { [weak self] event in
                self?.enqueueStreamEvent(event, nonce: nonce)
            }) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleInvoke(result,
                                       nonce: nonce,
                                       requestId: requestId,
                                       plugin: plugin,
                                       action: action)
                }
            }
            if var invocation = activeInvocation, invocation.nonce == nonce {
                invocation.task = task
                activeInvocation = invocation
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + frozenInvocationTimeout
        ) { [weak self] in
            guard let self,
                  let current = self.storedInvocation(nonce: nonce) else { return }
            self.cancelInvocation(current,
                                  failureMessage: "插件生成超时",
                                  preserveLegacyResultRouting: false)
        }
        return true
    }

    func focusInvalidated(_ token: FocusToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        statuses = statuses.filter { $0.value.focusToken != token }
        if let invocation = activeInvocation,
           let boundFocusToken = invocation.focusToken,
           boundFocusToken == token {
            parkInvocationForInbox(invocation)
        } else if workbenchFailureMessage != nil {
            clearWorkbenchMessages()
        }
        onChange?()
    }

    func focusDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let invocation = activeInvocation else {
            if workbenchFailureMessage != nil {
                clearWorkbenchMessages()
                onChange?()
            }
            return
        }
        guard let boundFocusToken = invocation.focusToken,
              focus.currentToken() != boundFocusToken else { return }
        parkInvocationForInbox(invocation)
        onChange?()
    }

    func pluginConfigurationDidChange(changedPluginID: String? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let changedPluginID {
            // A named manager mutation is a boundary for that plugin only.
            // Settings may enable/disable inactive plugin B while selected
            // plugin A is generating; B must lose every task and grant without
            // interrupting A's invocation, partial blocks, status, or message.
            let touchesForeground = pluginIsSelected(changedPluginID)
                || activeInvocation?.key.pluginId == changedPluginID
            if touchesForeground {
                clearWorkbenchMessages()
            }
            statuses = statuses.filter { $0.key.pluginId != changedPluginID }
            failures = failures.filter { $0.key.pluginId != changedPluginID }
            statusRequests = statusRequests.filter { $0.key.pluginId != changedPluginID }
            if let invocation = activeInvocation,
               invocation.key.pluginId == changedPluginID {
                cancelInvocation(invocation,
                                 failureMessage: nil,
                                 preserveLegacyResultRouting: false)
            }
            cancelBackgroundInvocations(pluginID: changedPluginID)
            revokeDeliveryBindings(pluginID: changedPluginID)
            reloadManifests(force: true)
            refreshStatuses(force: true, onlyPluginID: changedPluginID)
            onChange?()
            return
        }

        // Older/third-party notifications cannot identify their mutation.
        // Retain the original fail-closed global generation boundary.
        hostGeneration &+= 1
        clearWorkbenchMessages()
        statuses.removeAll()
        failures.removeAll()
        statusRequests.removeAll()
        if let invocation = activeInvocation {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
        cancelBackgroundInvocations()
        deliveryBindings.removeAll()
        deliveryPlugins.removeAll()
        deliveryKeys.removeAll()
        deliveryBindingOrder.removeAll()
        reloadManifests(force: true)
        refreshStatuses(force: true)
        onChange?()
    }

    func bufferPluginSelectionDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Owner selection is a presentation/execution boundary, not a plugin
        // installation boundary. Cancel work that is still running for the old
        // owner, but retain completed request bindings: those blocks remain in
        // BufferModel and must still be verifiable when the user later sends
        // them after switching to another workbench plugin.
        hostGeneration &+= 1
        clearWorkbenchMessages()
        statuses.removeAll()
        failures.removeAll()
        statusRequests.removeAll()
        if let invocation = activeInvocation {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
        cancelBackgroundInvocations()
        reloadManifests(force: true)
        refreshStatuses(force: true)
        onChange?()
    }

    /// A generated block is target-bound. Before the only delivery coordinator
    /// can insert it, re-check the original Marine instance and browser context
    /// while holding the exact focus epoch captured at generation time.
    func validateForDelivery(metadata: BufferModel.PluginMetadata,
                             expectedFocusToken: FocusToken,
                             completion: @escaping (ActionPluginDeliveryDecision) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !metadata.stale,
              !metadata.incomplete,
              let boundFocusToken = metadata.focusToken,
              boundFocusToken == expectedFocusToken,
              focus.currentToken() == expectedFocusToken,
              focus.isValid(expectedFocusToken),
              !focus.secureInputEnabled() else {
            completion(.rejected(metadata.stale ? .stale : .targetChanged))
            return
        }
        let key = ActionPluginKey(pluginId: metadata.pluginId,
                                  actionId: metadata.actionId)
        guard let plugin = plugins[key.pluginId],
              let action = plugin.manifest.actions.first(where: { $0.id == key.actionId }),
              livePlugin(withID: key.pluginId) == plugin,
              let binding = deliveryBindings[metadata.requestId],
              deliveryPlugins[metadata.requestId] == plugin,
              deliveryKeys[metadata.requestId] == key,
              binding.config.pluginId == metadata.pluginId,
              binding.identity == metadata.runtimeIdentity,
              runtimeBindingIsCurrent(plugin, binding) else {
            completion(.rejected(.stale))
            return
        }

        client.fetchStatus(plugin: plugin,
                           action: action,
                           binding: binding) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.rejected(.unavailable))
                    return
                }
                guard self.focus.currentToken() == expectedFocusToken,
                      self.focus.isValid(expectedFocusToken),
                      !self.focus.secureInputEnabled(),
                      !metadata.stale,
                      metadata.focusToken == expectedFocusToken else {
                    completion(.rejected(.targetChanged))
                    return
                }
                // The manager notification may still be queued behind this
                // transport callback. Re-read the enabled plugin set as well
                // as the host cache so disable/uninstall/upgrade wins even in
                // that ordering.
                guard metadata.pluginId == key.pluginId,
                      metadata.actionId == key.actionId,
                      self.plugins[key.pluginId] == plugin,
                      self.livePlugin(withID: key.pluginId) == plugin,
                      plugin.manifest.actions.first(where: { $0.id == key.actionId }) == action,
                      self.deliveryPlugins[metadata.requestId] == plugin,
                      self.deliveryKeys[metadata.requestId] == key,
                      self.deliveryBindings[metadata.requestId] == binding,
                      binding.config.pluginId == metadata.pluginId,
                      binding.identity == metadata.runtimeIdentity,
                      self.runtimeBindingIsCurrent(plugin, binding) else {
                    completion(.rejected(.stale))
                    return
                }
                guard let snapshot = try? result.get(),
                      snapshot.binding == binding else {
                    completion(.rejected(.unavailable))
                    return
                }
                guard ActionPluginRoutingRules.statusMatches(
                    snapshot.value,
                    action: action,
                    contextId: metadata.contextId
                ) else {
                    completion(.rejected(.targetChanged))
                    return
                }
                completion(.allowed)
            }
        }
    }

    /// Read through the loader instead of trusting only the cached manifest
    /// map. This closes the short window where a management notification has
    /// been posted but is still waiting behind a completed HTTP callback.
    private func livePlugin(withID pluginID: String) -> InstalledActionPlugin? {
        return pluginLoader(rootURL).first { $0.manifest.id == pluginID }
    }

    private func storedInvocation(nonce: UUID) -> ActiveInvocation? {
        if let activeInvocation, activeInvocation.nonce == nonce {
            return activeInvocation
        }
        return backgroundInvocations[nonce]
    }

    /// URLSession may decode a legal burst of thousands of frames on its
    /// delegate queue. Heartbeats collapse to one authority pulse, and block
    /// frames are full snapshots, so retain only the newest snapshot per index
    /// and schedule at most one main-thread drain per short display interval.
    private func enqueueStreamEvent(_ event: ActionPluginStreamEvent, nonce: UUID) {
        streamEventMailboxLock.lock()
        switch event {
        case let .heartbeat(identity, sequence):
            if queuedStreamHeartbeats[nonce]?.sequence ?? 0 <= sequence {
                queuedStreamHeartbeats[nonce] = (identity, sequence)
            }
        case let .block(snapshot):
            var blocks = queuedStreamBlocks[nonce] ?? [:]
            if blocks[snapshot.index]?.sequence ?? 0 <= snapshot.sequence {
                blocks[snapshot.index] = snapshot
                queuedStreamBlocks[nonce] = blocks
            }
        }
        let shouldSchedule = scheduledStreamDrains.insert(nonce).inserted
        streamEventMailboxLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.drainQueuedStreamEvents(nonce: nonce)
        }
    }

    private func drainQueuedStreamEvents(nonce: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        streamDrainDidRun()
        streamEventMailboxLock.lock()
        let snapshots = queuedStreamBlocks.removeValue(forKey: nonce)?.values
            .sorted { $0.sequence < $1.sequence } ?? []
        let heartbeat = queuedStreamHeartbeats.removeValue(forKey: nonce)
        scheduledStreamDrains.remove(nonce)
        streamEventMailboxLock.unlock()

        var events = snapshots.map(ActionPluginStreamEvent.block)
        if let heartbeat {
            events.append(.heartbeat(identity: heartbeat.identity,
                                     sequence: heartbeat.sequence))
        }
        events.sort { lhs, rhs in
            func sequence(_ event: ActionPluginStreamEvent) -> Int {
                switch event {
                case let .heartbeat(_, sequence): return sequence
                case let .block(snapshot): return snapshot.sequence
                }
            }
            return sequence(lhs) < sequence(rhs)
        }
        for event in events {
            handleStreamEvent(event, nonce: nonce)
        }
    }

    private func discardQueuedStreamEvents(nonce: UUID) {
        streamEventMailboxLock.lock()
        queuedStreamBlocks[nonce] = nil
        queuedStreamHeartbeats[nonce] = nil
        scheduledStreamDrains.remove(nonce)
        streamEventMailboxLock.unlock()
    }

    private func invocationIsStored(_ invocation: ActiveInvocation) -> Bool {
        storedInvocation(nonce: invocation.nonce) != nil
    }

    private func updateStoredInvocation(_ invocation: ActiveInvocation) {
        if activeInvocation?.nonce == invocation.nonce {
            activeInvocation = invocation
        } else if backgroundInvocations[invocation.nonce] != nil {
            backgroundInvocations[invocation.nonce] = invocation
        }
    }

    private func updateConnectorActivity(_ activity: AITextProviderActivity,
                                         nonce: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var invocation = activeInvocation,
              invocation.nonce == nonce,
              invocation.streaming,
              !invocation.receivedFirstContent else { return }
        guard streamingRuntimeIsAuthoritative(invocation) else {
            cancelInvocation(invocation,
                             failureMessage: "插件运行实例已变化",
                             preserveLegacyResultRouting: false)
            return
        }
        let normalized = Self.normalizedActivityMessage(activity.message)
        guard !normalized.isEmpty else { return }
        let changed = invocation.activityMessage != normalized
        if changed {
            invocation.activityMessage = normalized
            activeInvocation = invocation
        }
        let displayText = activityDisplayText(for: invocation)
        guard changed || bufferModel.loadingMessage != displayText else { return }
        bufferModel.updateTransientLoading(
            requestId: invocation.requestId,
            message: displayText
        )
        onChange?()
    }

    private func scheduleInvocationActivityTick(nonce: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self,
                  let invocation = self.activeInvocation,
                  invocation.nonce == nonce,
                  invocation.streaming,
                  !invocation.receivedFirstContent else { return }
            self.bufferModel.updateTransientLoading(
                requestId: invocation.requestId,
                message: self.activityDisplayText(for: invocation)
            )
            self.onChange?()
            self.scheduleInvocationActivityTick(nonce: nonce)
        }
    }

    private func activityDisplayText(for invocation: ActiveInvocation) -> String {
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - invocation.startedAt)
        return "\(invocation.activityMessage) · \(Int(elapsed)) 秒"
    }

    private static func normalizedActivityMessage(_ value: String) -> String {
        let oneLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(120))
    }

    @discardableResult
    private func removeStoredInvocation(nonce: UUID) -> ActiveInvocation? {
        streamAuthorityValidatedAt[nonce] = nil
        discardQueuedStreamEvents(nonce: nonce)
        if let activeInvocation, activeInvocation.nonce == nonce {
            self.activeInvocation = nil
            return activeInvocation
        }
        backgroundInvocationOrder.removeAll { $0 == nonce }
        return backgroundInvocations.removeValue(forKey: nonce)
    }

    private func cancelBackgroundInvocations() {
        let invocations = backgroundInvocationOrder.compactMap {
            backgroundInvocations[$0]
        }
        for invocation in invocations {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
    }

    private func cancelBackgroundInvocations(pluginID: String) {
        let invocations = backgroundInvocationOrder.compactMap {
            backgroundInvocations[$0]
        }.filter {
            $0.key.pluginId == pluginID
        }
        for invocation in invocations {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
    }

    private func revokeDeliveryBindings(pluginID: String) {
        for requestID in deliveryBindingOrder
            where deliveryKeys[requestID]?.pluginId == pluginID {
            deliveryBindings[requestID] = nil
            deliveryPlugins[requestID] = nil
            deliveryKeys[requestID] = nil
        }
        deliveryBindingOrder.removeAll { deliveryBindings[$0] == nil }
    }

    func cancelActiveInvocationForWorkbench() {
        dispatchPrecondition(condition: .onQueue(.main))
        var changed = false
        if let invocation = activeInvocation {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
            changed = true
        }
        if !backgroundInvocations.isEmpty {
            cancelBackgroundInvocations()
            changed = true
        }
        if workbenchFailureMessage != nil {
            clearWorkbenchMessages()
            changed = true
        }
        if changed { onChange?() }
    }

    private func cancelInvocation(_ invocation: ActiveInvocation,
                                  failureMessage: String? = nil,
                                  preserveLegacyResultRouting: Bool = false) {
        guard let current = storedInvocation(nonce: invocation.nonce) else { return }
        if preserveLegacyResultRouting, !invocation.streaming {
            var stale = current
            stale.markedStale = true
            activeInvocation = stale
            return
        }
        let wasForeground = activeInvocation?.nonce == current.nonce
        _ = removeStoredInvocation(nonce: current.nonce)
        current.task?.cancel()
        if current.streaming {
            bufferModel.removePluginStreamBlocks(
                requestId: current.requestId,
                blockIDs: current.stagedStreamBlockIDs
            )
            // A stream error must not reuse `loadingMessage`: the buffer rail
            // renders that as a chip beside sendable content. Settle the rail
            // and expose only a short, local status-shelf message instead.
            bufferModel.finishTransientLoading(requestId: current.requestId)
            if wasForeground {
                foregroundFailureMessage = failureMessage.map(Self.streamFailureSummary)
            }
        } else if let failureMessage {
            if wasForeground {
                bufferModel.failTransientLoading(requestId: current.requestId,
                                                 message: failureMessage)
            } else {
                bufferModel.finishTransientLoading(requestId: current.requestId)
                backgroundNoticeMessage = Self.streamFailureSummary(failureMessage)
            }
        } else {
            bufferModel.finishTransientLoading(requestId: current.requestId)
        }
        onChange?()
    }

    private func clearWorkbenchMessages() {
        foregroundFailureMessage = nil
        backgroundNoticeMessage = nil
    }

    private static func streamFailureSummary(_ message: String) -> String {
        if message.contains("超时") { return "生成超时" }
        if message.contains("目标") { return "评论目标已变化" }
        if message.contains("取消") || message.contains("删除") { return "生成已取消" }
        return "生成失败"
    }

    /// Authority that survives a focus change. A valid terminal response may
    /// still be retained in the review inbox, but a disabled/upgraded plugin or
    /// rotated runtime must be tombstoned completely.
    private func streamingCachedAuthorityIsValid(_ invocation: ActiveInvocation) -> Bool {
        guard invocation.streaming,
              invocationIsStored(invocation),
              invocation.hostGeneration == hostGeneration,
              plugins[invocation.key.pluginId] == invocation.plugin,
              invocation.plugin.manifest.actions.first(where: {
                  $0.id == invocation.key.actionId
              }) == invocation.action else { return false }
        return true
    }

    /// Disk-backed plugin/runtime authority is expensive to re-read on every
    /// heartbeat. Management notifications remain immediate; this bounded
    /// cache protects the main-thread event hot path, while terminal and
    /// delivery transitions always pass `force: true`.
    private func streamingRuntimeIsAuthoritative(_ invocation: ActiveInvocation,
                                                 force: Bool = false) -> Bool {
        guard streamingCachedAuthorityIsValid(invocation) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if !force,
           let validatedAt = streamAuthorityValidatedAt[invocation.nonce],
           now - validatedAt < runtimeAuthorityRecheckInterval {
            return true
        }
        guard livePlugin(withID: invocation.key.pluginId) == invocation.plugin,
              runtimeBindingIsCurrent(invocation.plugin, invocation.binding) else {
            return false
        }
        streamAuthorityValidatedAt[invocation.nonce] = now
        return true
    }

    /// Stronger lease required before provisional text can touch the live
    /// workbench. Focus and secure-input state are deliberately local gates;
    /// losing either moves the eventual complete result to the inbox.
    private func streamingInvocationCanStageLive(_ invocation: ActiveInvocation) -> Bool {
        guard activeInvocation?.nonce == invocation.nonce,
              streamingCachedAuthorityIsValid(invocation),
              !invocation.markedStale,
              !focus.secureInputEnabled() else { return false }
        guard let boundFocusToken = invocation.focusToken else {
            return !invocation.action.requiresFocus
        }
        return focus.currentToken() == boundFocusToken
            && focus.isValid(boundFocusToken)
    }

    /// Stop exposing partial text after the target changes, while preserving
    /// the still-authorized provider task long enough to retain its complete
    /// terminal response in InboundBus for explicit review.
    private func markStreamingInvocationStaleForInbox(_ invocation: ActiveInvocation) {
        guard var current = storedInvocation(nonce: invocation.nonce),
              current.streaming else { return }

        let stagedIDs = current.stagedStreamBlockIDs
        let wasStale = current.markedStale
        current.markedStale = true
        current.pendingStreamBlocks.removeAll()
        current.streamFlushScheduled = false
        current.streamBlockIDs.removeAll()
        current.stagedStreamBlockIDs.removeAll()
        let wasForeground = storeAsBackground(current)

        // Publish the empty staged-ID lease before mutating BufferModel. Its
        // synchronous observer must not interpret our scoped cleanup as a user
        // deletion and cancel the provider task.
        if !stagedIDs.isEmpty {
            bufferModel.removePluginStreamBlocks(requestId: current.requestId,
                                                 blockIDs: stagedIDs)
        }
        bufferModel.finishTransientLoading(requestId: current.requestId)
        if wasForeground { foregroundFailureMessage = nil }
        if !wasStale { onChange?() }
    }

    private func parkInvocationForInbox(_ invocation: ActiveInvocation) {
        guard !invocation.streaming else {
            markStreamingInvocationStaleForInbox(invocation)
            return
        }
        guard var current = storedInvocation(nonce: invocation.nonce) else { return }
        let wasStale = current.markedStale
        current.markedStale = true
        let wasForeground = storeAsBackground(current)
        bufferModel.finishTransientLoading(requestId: current.requestId)
        if wasForeground { foregroundFailureMessage = nil }
        if !wasStale { onChange?() }
    }

    /// Move an invocation out of the single foreground slot. Keeping at most a
    /// few terminal-only continuations prevents a sequence of target changes
    /// from accumulating unbounded network tasks.
    @discardableResult
    private func storeAsBackground(_ invocation: ActiveInvocation) -> Bool {
        let wasForeground = activeInvocation?.nonce == invocation.nonce
        if wasForeground { activeInvocation = nil }
        backgroundInvocations[invocation.nonce] = invocation
        backgroundInvocationOrder.removeAll { $0 == invocation.nonce }
        backgroundInvocationOrder.append(invocation.nonce)

        while backgroundInvocationOrder.count > Self.maximumBackgroundInvocations {
            let oldest = backgroundInvocationOrder[0]
            guard let overflow = backgroundInvocations[oldest] else {
                backgroundInvocationOrder.removeFirst()
                continue
            }
            cancelInvocation(overflow,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
        return wasForeground
    }

    private func bufferModelDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        switch bufferModel.lastMutationReason {
        case .pause, .privacyDiscard:
            if let invocation = activeInvocation, invocation.streaming {
                cancelInvocation(invocation,
                                 failureMessage: nil,
                                 preserveLegacyResultRouting: false)
            }
            cancelBackgroundInvocations()
            return
        case .pluginStreamFinalization:
            return
        default:
            break
        }
        guard let invocation = activeInvocation, invocation.streaming else { return }
        let liveIDs = Set(bufferModel.blocks.map(\.id))
        guard invocation.stagedStreamBlockIDs.isSubset(of: liveIDs) else {
            cancelInvocation(invocation,
                             failureMessage: "插件生成已取消",
                             preserveLegacyResultRouting: false)
            return
        }
    }

    private func handleStreamEvent(_ event: ActionPluginStreamEvent,
                                   nonce: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard var invocation = storedInvocation(nonce: nonce),
              invocation.streaming else { return }

        let eventIdentity: ActionPluginStreamIdentity
        switch event {
        case let .heartbeat(identity, _):
            eventIdentity = identity
        case let .block(snapshot):
            eventIdentity = snapshot.identity
        }
        let expectedIdentity = ActionPluginStreamIdentity(
            pluginId: invocation.plugin.manifest.id,
            runtimeInstanceId: invocation.binding.config.instanceId ?? "",
            requestId: invocation.requestId,
            actionId: invocation.action.id,
            contextId: invocation.contextId
        )
        guard eventIdentity == expectedIdentity else {
            cancelInvocation(invocation,
                             failureMessage: "插件流身份不匹配",
                             preserveLegacyResultRouting: false)
            return
        }
        guard streamingRuntimeIsAuthoritative(invocation) else {
            cancelInvocation(invocation,
                             failureMessage: "插件运行实例已变化",
                             preserveLegacyResultRouting: false)
            return
        }
        // A parked stream can no longer mutate visible state. Its coalesced
        // heartbeat still renews/revokes runtime authority at the bounded cache
        // cadence, but partial snapshots are discarded here.
        guard activeInvocation?.nonce == invocation.nonce else { return }
        guard streamingInvocationCanStageLive(invocation) else {
            markStreamingInvocationStaleForInbox(invocation)
            return
        }

        switch event {
        case .heartbeat:
            return
        case let .block(snapshot):
            let maximumLogicalBlocks = maximumStreamLogicalBlockCount(for: invocation)
            let maximumLogicalBytes = maximumStreamLogicalBlockBytes(for: invocation)
            guard (0..<maximumLogicalBlocks).contains(snapshot.index),
                  !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ActionPluginStreamParser.validText(
                      snapshot.text,
                      maximumBytes: maximumLogicalBytes
                  ),
                  ActionPluginStreamParser.validOptionalText(
                      snapshot.title,
                      maximumBytes: ActionPluginStreamParser.maximumTitleBytes
                  ) else {
                cancelInvocation(invocation,
                                 failureMessage: "连接器流结果无效",
                                 preserveLegacyResultRouting: false)
                return
            }
            let logical = PendingStreamBlock(
                index: snapshot.index,
                text: snapshot.text,
                title: snapshot.title
            )
            var logicalBlocks = invocation.streamLogicalBlocks
            logicalBlocks[snapshot.index] = logical
            guard logicalBlocks.values.reduce(0, {
                $0 + $1.text.utf8.count
            }) <= maximumStreamLogicalTotalBytes(for: invocation) else {
                cancelInvocation(invocation,
                                 failureMessage: "连接器流结果过大",
                                 preserveLegacyResultRouting: false)
                return
            }
            invocation.streamLogicalBlocks = logicalBlocks
            invocation.pendingStreamBlocks[snapshot.index] = logical
            let firstContent = !invocation.receivedFirstContent
            invocation.receivedFirstContent = true
            activeInvocation = invocation
            if firstContent {
                flushPendingStreamBlocks(nonce: nonce)
            } else {
                scheduleStreamFlush(nonce: nonce)
            }
        }
    }

    private func scheduleStreamFlush(nonce: UUID) {
        guard var invocation = activeInvocation,
              invocation.nonce == nonce,
              !invocation.streamFlushScheduled else { return }
        invocation.streamFlushScheduled = true
        activeInvocation = invocation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.flushPendingStreamBlocks(nonce: nonce)
        }
    }

    private func flushPendingStreamBlocks(nonce: UUID) {
        guard var invocation = activeInvocation,
              invocation.nonce == nonce,
              invocation.streaming else { return }
        guard streamingRuntimeIsAuthoritative(invocation) else {
            cancelInvocation(invocation,
                             failureMessage: "插件运行实例已变化",
                             preserveLegacyResultRouting: false)
            return
        }
        guard streamingInvocationCanStageLive(invocation) else {
            markStreamingInvocationStaleForInbox(invocation)
            return
        }
        let pending = invocation.pendingStreamBlocks.values.sorted { $0.index < $1.index }
        invocation.pendingStreamBlocks.removeAll()
        invocation.streamFlushScheduled = false
        guard !pending.isEmpty else { return }

        let segments = hostedStreamSegments(
            Array(invocation.streamLogicalBlocks.values)
        )
        guard !segments.isEmpty else {
            cancelInvocation(invocation,
                             failureMessage: "插件分块结果超过安全上限",
                             preserveLegacyResultRouting: false)
            return
        }
        let liveIndices = Set(segments.map(\.index))
        let obsoleteIndices = Set(invocation.streamBlockIDs.keys)
            .subtracting(liveIndices)
        let obsoleteIDs = Set(obsoleteIndices.compactMap {
            invocation.streamBlockIDs.removeValue(forKey: $0)
        })
        invocation.stagedStreamBlockIDs.subtract(obsoleteIDs)
        for segment in segments where invocation.streamBlockIDs[segment.index] == nil {
            invocation.streamBlockIDs[segment.index] = UUID()
        }
        activeInvocation = invocation
        if !obsoleteIDs.isEmpty {
            bufferModel.removePluginStreamBlocks(
                requestId: invocation.requestId,
                blockIDs: obsoleteIDs
            )
        }

        let origin = Origin.plugin(id: invocation.plugin.manifest.id)
        let updates = segments.compactMap { segment -> BufferModel.PluginStreamUpdate? in
            guard let id = invocation.streamBlockIDs[segment.index] else { return nil }
            let metadata = BufferModel.PluginMetadata(
                pluginId: invocation.plugin.manifest.id,
                actionId: invocation.action.id,
                requestId: invocation.requestId,
                contextId: invocation.contextId,
                focusToken: invocation.focusToken,
                runtimeIdentity: invocation.binding.identity,
                title: segment.title,
                targetSummary: invocation.targetSummary,
                stale: false,
                incomplete: true,
                streamProtocolVersion: ActionPluginStreamParser.protocolVersion,
                streamIndex: segment.index,
                reviewedAsPlainText: invocation.focusToken == nil
            )
            return BufferModel.PluginStreamUpdate(id: id,
                                                  index: segment.index,
                                                  text: segment.text,
                                                  origin: origin,
                                                  metadata: metadata)
        }
        guard updates.count == segments.count,
              bufferModel.applyPluginStreamUpdates(requestId: invocation.requestId,
                                                   updates: updates) else {
            cancelInvocation(invocation,
                             failureMessage: "插件流无法更新缓冲块",
                             preserveLegacyResultRouting: false)
            return
        }
        guard var current = activeInvocation, current.nonce == nonce else { return }
        current.stagedStreamBlockIDs.formUnion(updates.map(\.id))
        activeInvocation = current
        onChange?()
    }

    private func hostedStreamSegments(_ blocks: [PendingStreamBlock])
        -> [HostedStreamSegment] {
        let fragments = SemanticBlockSegmenter.refine(
            blocks.map {
                SemanticLogicalBlock(sourceIndex: $0.index,
                                     text: $0.text,
                                     title: $0.title)
            },
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        guard !fragments.isEmpty,
              fragments.allSatisfy({
                  ActionPluginStreamParser.validText(
                      $0.text,
                      maximumBytes: ActionPluginStreamParser.maximumBlockBytes
                  )
              }) else { return [] }
        return fragments.map { fragment in
            HostedStreamSegment(
                index: fragment.key.sourceIndex * Self.streamSegmentIndexStride
                    + fragment.key.childIndex,
                text: fragment.text,
                title: fragment.title
            )
        }
    }

    private func reloadManifests(force: Bool) {
        guard force else { return }
        lastManifestReload = ProcessInfo.processInfo.systemUptime
        let installed = Dictionary(
            ActionPluginManifestLoader.load(from: rootURL)
                .map { ($0.manifest.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let loaded = Dictionary(
            pluginLoader(rootURL)
                .map { ($0.manifest.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        if installed != installedManifestSnapshot {
            installedManifestSnapshot = installed
            // Marine owns its manifest and may atomically install/restore it
            // without going through ActionPluginManager. Observe the complete
            // installed set (including disabled plugins), then notify on the
            // next main-loop turn to avoid reentering this reload transaction.
            let changedRoot = rootURL.standardizedFileURL.path
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .externalActionManifestSetDidChange,
                    object: nil,
                    userInfo: [ActionPluginManager.rootPathUserInfoKey: changedRoot]
                )
            }
        }

        guard loaded != plugins else { return }
        let previousPlugins = plugins
        let changedPluginIDs = Set(previousPlugins.keys).union(loaded.keys).filter {
            previousPlugins[$0] != loaded[$0]
        }
        plugins = loaded

        // A key surviving an upgrade is not the same authority. Preserve
        // cached state only when the complete installed plugin and action
        // definition are byte-for-byte equivalent to the generation that
        // created it.
        statuses = statuses.filter { key, observed in
            guard let currentPlugin = loaded[key.pluginId],
                  currentPlugin == observed.plugin,
                  currentPlugin.manifest.actions.first(where: { $0.id == key.actionId })
                    == observed.action else { return false }
            return true
        }
        statusRequests = statusRequests.filter { key, request in
            guard let currentPlugin = loaded[key.pluginId],
                  currentPlugin == request.plugin,
                  currentPlugin.manifest.actions.first(where: { $0.id == key.actionId })
                    == request.action else { return false }
            return true
        }
        failures = failures.filter { key, _ in
            guard let previous = previousPlugins[key.pluginId],
                  let current = loaded[key.pluginId],
                  previous == current,
                  current.manifest.actions.contains(where: { $0.id == key.actionId }) else {
                return false
            }
            return true
        }

        if let invocation = activeInvocation,
           changedPluginIDs.contains(invocation.key.pluginId) {
            cancelInvocation(invocation,
                             failureMessage: nil,
                             preserveLegacyResultRouting: false)
        }
        for pluginID in changedPluginIDs {
            cancelBackgroundInvocations(pluginID: pluginID)
        }

        for requestID in deliveryBindingOrder {
            guard let plugin = deliveryPlugins[requestID],
                  let key = deliveryKeys[requestID],
                  let binding = deliveryBindings[requestID],
                  loaded[key.pluginId] == plugin,
                  plugin.manifest.actions.contains(where: { $0.id == key.actionId }),
                  binding.config.pluginId == key.pluginId else {
                deliveryBindings[requestID] = nil
                deliveryPlugins[requestID] = nil
                deliveryKeys[requestID] = nil
                continue
            }
        }
        deliveryBindingOrder.removeAll { deliveryBindings[$0] == nil }
        onChange?()
    }

    private func handleStatus(_ result: Result<ActionPluginStatusSnapshot, Error>,
                              plugin: InstalledActionPlugin,
                              action: ActionPluginDefinition,
                              key: ActionPluginKey,
                              request: StatusRequest) {
        guard statusRequests[key] == request else { return }
        statusRequests[key] = nil
        guard request.plugin == plugin,
              request.action == action,
              plugins[plugin.manifest.id] == plugin,
              plugin.manifest.actions.first(where: { $0.id == action.id }) == action else {
            return
        }
        guard !action.requiresFocus || focus.currentToken() == request.focusToken else {
            statuses[key] = nil
            onChange?()
            return
        }
        let oldStatus = statuses[key]
        let oldFailure = failures[key]
        switch result {
        case let .success(snapshot):
            let status = snapshot.value
            statuses[key] = ObservedStatus(snapshot: snapshot,
                                           focusToken: request.focusToken,
                                           plugin: plugin,
                                           action: action)
            failures[key] = nil
            if let invocation = activeInvocation,
               invocation.key == key,
               (!ActionPluginRoutingRules.statusMatches(status,
                                                        action: action,
                                                        contextId: invocation.contextId)
                   || snapshot.binding != invocation.binding) {
                if invocation.streaming {
                    if snapshot.binding != invocation.binding {
                        cancelInvocation(invocation,
                                         failureMessage: "插件运行实例已变化",
                                         preserveLegacyResultRouting: false)
                    } else {
                        markStreamingInvocationStaleForInbox(invocation)
                    }
                } else {
                    parkInvocationForInbox(invocation)
                }
            }
        case let .failure(error):
            statuses[key] = nil
            failures[key] = (error as? LocalizedError)?.errorDescription ?? "插件服务不可用"
        }
        if oldStatus != statuses[key] || oldFailure != failures[key] { onChange?() }
    }

    private func handlePreparation(_ result: Result<ActionPluginPrepareResponse, Error>,
                                   nonce: UUID,
                                   requestId: String,
                                   plugin: InstalledActionPlugin,
                                   action: ActionPluginDefinition,
                                   cancellationChain: ActionPluginCancellationChain) {
        guard let invocation = storedInvocation(nonce: nonce),
              invocation.requestId == requestId,
              invocation.plugin == plugin,
              invocation.action == action,
              action.preparePath != nil,
              invocation.streaming else { return }
        guard plugins[plugin.manifest.id] == plugin,
              plugin.manifest.actions.first(where: { $0.id == action.id }) == action,
              streamingRuntimeIsAuthoritative(invocation, force: true) else {
            cancelInvocation(invocation,
                             failureMessage: "插件运行实例已变化",
                             preserveLegacyResultRouting: false)
            return
        }

        let preparation: ActionPluginPrepareResponse
        switch result {
        case let .failure(error):
            cancelInvocation(
                invocation,
                failureMessage: (error as? LocalizedError)?.errorDescription ?? "插件话术准备失败",
                preserveLegacyResultRouting: false
            )
            return
        case let .success(response):
            let expectedIdentity = ActionPluginStreamIdentity(
                pluginId: plugin.manifest.id,
                runtimeInstanceId: invocation.binding.config.instanceId ?? "",
                requestId: invocation.requestId,
                actionId: action.id,
                contextId: invocation.contextId
            )
            guard ActionPluginPrepareContract.accepts(
                response,
                expectedIdentity: expectedIdentity
            ) else {
                cancelInvocation(invocation,
                                 failureMessage: "插件返回的话术身份或格式无效",
                                 preserveLegacyResultRouting: false)
                return
            }
            preparation = response
        }

        guard let connector = connectorProvider() else {
            cancelInvocation(invocation,
                             failureMessage: "请先在“连接器 › AI 模型”选择一个模型源",
                             preserveLegacyResultRouting: false)
            return
        }
        if case let .unavailable(message) = connector.availability {
            cancelInvocation(invocation,
                             failureMessage: message,
                             preserveLegacyResultRouting: false)
            return
        }

        let identity = ActionPluginStreamIdentity(
            pluginId: plugin.manifest.id,
            runtimeInstanceId: invocation.binding.config.instanceId ?? "",
            requestId: invocation.requestId,
            actionId: action.id,
            contextId: invocation.contextId
        )
        let sequence = ActionPluginConnectorEventSequence()
        let connectorRequestID = UUID(uuidString: requestId) ?? UUID()
        updateConnectorActivity(
            AITextProviderActivity(kind: .launching,
                                   message: "正在启动 \(connector.kind.displayName)"),
            nonce: nonce
        )
        let task = connector.generate(
            AITextProviderRequest(
                requestID: connectorRequestID,
                sourceText: "",
                preparedPrompt: preparation.prompt
            ),
            onEvent: { [weak self] event in
                switch event {
                case let .activity(activity):
                    DispatchQueue.main.async {
                        self?.updateConnectorActivity(activity, nonce: nonce)
                    }
                case let .blockSnapshot(block):
                    self?.enqueueStreamEvent(
                        .block(ActionPluginStreamBlockSnapshot(
                            identity: identity,
                            sequence: sequence.next(),
                            index: block.index,
                            text: block.text,
                            title: block.title
                        )),
                        nonce: nonce
                    )
                }
            },
            completion: { [weak self] connectorResult in
                let invocationResult: Result<ActionPluginInvokeResponse, Error>
                switch connectorResult {
                case let .failure(error):
                    invocationResult = .failure(error)
                case let .success(blocks):
                    invocationResult = .success(ActionPluginInvokeResponse(
                        requestId: requestId,
                        actionId: action.id,
                        contextId: preparation.contextId,
                        blocks: blocks.map {
                            ActionPluginResultBlock(text: $0.text, title: $0.title)
                        },
                        targetSummary: preparation.targetSummary ?? invocation.targetSummary
                    ))
                }
                DispatchQueue.main.async {
                    self?.handleInvoke(invocationResult,
                                       nonce: nonce,
                                       requestId: requestId,
                                       plugin: plugin,
                                       action: action)
                }
            }
        )
        cancellationChain.installAI(task)
    }

    private func handleInvoke(_ result: Result<ActionPluginInvokeResponse, Error>,
                              nonce: UUID,
                              requestId: String,
                              plugin: InstalledActionPlugin,
                              action: ActionPluginDefinition) {
        if case .success = result,
           activeInvocation?.nonce == nonce,
           activeInvocation?.streaming == true {
            flushPendingStreamBlocks(nonce: nonce)
        }
        guard let invocation = storedInvocation(nonce: nonce),
              invocation.requestId == requestId,
              invocation.key.pluginId == plugin.manifest.id,
              invocation.key.actionId == action.id else { return }
        let pluginDefinitionMatches = invocation.plugin == plugin
            && invocation.action == action
            && plugins[plugin.manifest.id] == plugin
            && plugin.manifest.actions.first(where: { $0.id == action.id }) == action
        let authorityIsCurrent = invocation.streaming
            ? streamingRuntimeIsAuthoritative(invocation, force: true)
            : livePlugin(withID: plugin.manifest.id) == plugin
                && runtimeBindingIsCurrent(plugin, invocation.binding)
        guard pluginDefinitionMatches, authorityIsCurrent else {
            cancelInvocation(invocation,
                             failureMessage: invocation.streaming
                                ? "插件运行实例已变化"
                                : nil,
                             preserveLegacyResultRouting: false)
            return
        }
        switch result {
        case let .failure(error):
            if invocation.streaming {
                IMELog.write(
                    "buffer plugin stream failed plugin=\(plugin.manifest.id) "
                        + "action=\(action.id) error=\(IMELog.redact(error.localizedDescription))"
                )
            }
            cancelInvocation(
                invocation,
                failureMessage: (error as? LocalizedError)?.errorDescription ?? "插件请求失败",
                preserveLegacyResultRouting: false
            )
        case let .success(response):
            let responseMatches = response.requestId == invocation.requestId
                && response.actionId == action.id
                && response.contextId == invocation.contextId
            guard responseMatches else {
                if invocation.streaming {
                    cancelInvocation(invocation,
                                     failureMessage: "插件返回的请求身份不匹配",
                                     preserveLegacyResultRouting: false)
                } else {
                    route(response: response,
                          invocation: invocation,
                          direct: false,
                          plugin: plugin)
                }
                return
            }
            guard !invocation.streaming
                    || streamingResponseIsValid(response, invocation: invocation) else {
                cancelInvocation(invocation,
                                 failureMessage: "插件最终结果无效",
                                 preserveLegacyResultRouting: false)
                return
            }

            // Verify the browser target once more after the terminal event.
            // Provisional blocks remain incomplete until this exact binding,
            // context and focus generation all validate together.
            client.fetchStatus(plugin: plugin,
                               action: action,
                               binding: invocation.binding) { [weak self] statusResult in
                DispatchQueue.main.async {
                    guard let self,
                          let current = self.storedInvocation(nonce: nonce) else { return }
                    let definitionStillInstalled = current.plugin == plugin
                        && current.action == action
                        && self.plugins[current.key.pluginId] == plugin
                        && plugin.manifest.actions.first(where: {
                            $0.id == current.key.actionId
                        }) == action
                    let authorityStillCurrent = current.streaming
                        ? self.streamingRuntimeIsAuthoritative(current, force: true)
                        : self.livePlugin(withID: current.key.pluginId) == plugin
                            && self.runtimeBindingIsCurrent(plugin, current.binding)
                    guard definitionStillInstalled, authorityStillCurrent else {
                        self.cancelInvocation(
                            current,
                            failureMessage: current.streaming
                                ? "插件运行实例已变化"
                                : nil,
                            preserveLegacyResultRouting: false
                        )
                        return
                    }
                    let currentSnapshot = try? statusResult.get()
                    let currentStatus = currentSnapshot?.value
                    // A background result belongs to an old focus epoch. Its
                    // terminal revalidation must not overwrite a newer focus's
                    // status cache or disable the new foreground action.
                    if (!current.action.requiresFocus && current.focusToken == nil)
                        || self.focus.currentToken() == current.focusToken {
                        if let currentSnapshot {
                            self.statuses[current.key] = ObservedStatus(
                                snapshot: currentSnapshot,
                                focusToken: current.focusToken,
                                plugin: plugin,
                                action: action
                            )
                        } else {
                            self.statuses[current.key] = nil
                        }
                    }
                    let focusValid: Bool
                    if let boundFocusToken = current.focusToken {
                        focusValid = self.focus.isValid(boundFocusToken)
                            && self.focus.currentToken() == boundFocusToken
                            && !self.focus.secureInputEnabled()
                    } else {
                        focusValid = !current.action.requiresFocus
                            && !self.focus.secureInputEnabled()
                    }
                    let statusMatches = ActionPluginRoutingRules.statusMatches(
                        currentStatus,
                        action: action,
                        contextId: current.contextId
                    )
                    let direct = ActionPluginRoutingRules.shouldStageDirect(
                        responseMatches: true,
                        focusValid: focusValid,
                        currentStatusMatches: statusMatches,
                        invocationMarkedStale: current.markedStale
                    ) && currentSnapshot?.binding == current.binding

                    if current.streaming {
                        guard currentSnapshot?.binding == nil
                                || currentSnapshot?.binding == current.binding else {
                            self.cancelInvocation(
                                current,
                                failureMessage: "插件运行实例已变化",
                                preserveLegacyResultRouting: false
                            )
                            return
                        }
                        if direct {
                            self.finalizeStreamingResponse(response,
                                                           invocation: current,
                                                           plugin: plugin)
                        } else {
                            self.markStreamingInvocationStaleForInbox(current)
                            guard let stale = self.storedInvocation(nonce: nonce) else { return }
                            self.route(response: response,
                                       invocation: stale,
                                       direct: false,
                                       plugin: plugin)
                        }
                    } else {
                        self.route(response: response,
                                   invocation: current,
                                   direct: direct,
                                   plugin: plugin)
                    }
                }
            }
        }
    }

    private func finalizeStreamingResponse(_ response: ActionPluginInvokeResponse,
                                           invocation: ActiveInvocation,
                                           plugin: InstalledActionPlugin) {
        guard activeInvocation?.nonce == invocation.nonce,
              streamingInvocationCanStageLive(invocation),
              streamingResponseIsValid(response, invocation: invocation) else {
            cancelInvocation(invocation,
                             failureMessage: "插件最终结果无效",
                             preserveLegacyResultRouting: false)
            return
        }

        var blockIDs = invocation.streamBlockIDs
        let origin = Origin.plugin(id: plugin.manifest.id)
        let targetSummary = response.targetSummary ?? invocation.targetSummary
        let segments = hostedStreamSegments(
            response.blocks.enumerated().map { index, block in
                PendingStreamBlock(index: index,
                                   text: block.text,
                                   title: block.title)
            }
        )
        guard !segments.isEmpty else {
            cancelInvocation(invocation,
                             failureMessage: "插件分块结果超过安全上限",
                             preserveLegacyResultRouting: false)
            return
        }
        let finals = segments.map { segment -> BufferModel.PluginStreamFinalBlock in
            let id = blockIDs[segment.index] ?? UUID()
            blockIDs[segment.index] = id
            let metadata = BufferModel.PluginMetadata(
                pluginId: plugin.manifest.id,
                actionId: invocation.action.id,
                requestId: invocation.requestId,
                contextId: invocation.contextId,
                focusToken: invocation.focusToken,
                runtimeIdentity: invocation.binding.identity,
                title: segment.title,
                targetSummary: targetSummary,
                stale: false,
                incomplete: false,
                streamProtocolVersion: ActionPluginStreamParser.protocolVersion,
                streamIndex: segment.index,
                reviewedAsPlainText: invocation.focusToken == nil
            )
            return BufferModel.PluginStreamFinalBlock(id: id,
                                                      index: segment.index,
                                                      text: segment.text,
                                                      origin: origin,
                                                      metadata: metadata)
        }
        guard bufferModel.finalizePluginStream(
            requestId: invocation.requestId,
            partialBlockIDs: invocation.stagedStreamBlockIDs,
            blocks: finals
        ) else {
            cancelInvocation(invocation,
                             failureMessage: "插件流结果已被取消或修改",
                             preserveLegacyResultRouting: false)
            return
        }
        if invocation.focusToken != nil {
            registerDeliveryAuthority(invocation)
        }
        _ = removeStoredInvocation(nonce: invocation.nonce)
        foregroundFailureMessage = nil
        onChange?()
    }

    private func maximumStreamLogicalBlockCount(for invocation: ActiveInvocation) -> Int {
        invocation.action.preparePath == nil
            ? ActionPluginStreamParser.maximumBlocks
            : AITextRuntimeLimits.maximumModelBlockCount
    }

    private func maximumStreamLogicalBlockBytes(for invocation: ActiveInvocation) -> Int {
        invocation.action.preparePath == nil
            ? ActionPluginStreamParser.maximumBlockBytes
            : AITextRuntimeLimits.maximumWireBytes
    }

    private func maximumStreamLogicalTotalBytes(for invocation: ActiveInvocation) -> Int {
        invocation.action.preparePath == nil
            ? ActionPluginStreamParser.maximumWireBytes
            : AITextRuntimeLimits.maximumWireBytes
    }

    private func streamingResponseIsValid(
        _ response: ActionPluginInvokeResponse,
        invocation: ActiveInvocation
    ) -> Bool {
        !response.blocks.isEmpty
            && response.blocks.count <= maximumStreamLogicalBlockCount(for: invocation)
            && response.blocks.reduce(0, { $0 + $1.text.utf8.count })
                <= maximumStreamLogicalTotalBytes(for: invocation)
            && response.blocks.allSatisfy { block in
                !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ActionPluginStreamParser.validText(
                        block.text,
                        maximumBytes: maximumStreamLogicalBlockBytes(for: invocation)
                    )
                    && ActionPluginStreamParser.validOptionalText(
                        block.title,
                        maximumBytes: ActionPluginStreamParser.maximumTitleBytes
                    )
            }
            && ActionPluginStreamParser.validOptionalText(
                response.targetSummary,
                maximumBytes: ActionPluginStreamParser.maximumSummaryBytes
            )
    }

    private func route(response: ActionPluginInvokeResponse,
                       invocation: ActiveInvocation,
                       direct: Bool,
                       plugin: InstalledActionPlugin) {
        guard invocationIsStored(invocation) else { return }
        let wasForeground = activeInvocation?.nonce == invocation.nonce
        guard invocation.plugin == plugin,
              plugins[invocation.key.pluginId] == plugin,
              plugin.manifest.actions.first(where: {
                  $0.id == invocation.key.actionId
              }) == invocation.action,
              invocation.streaming
                ? streamingRuntimeIsAuthoritative(invocation, force: true)
                : livePlugin(withID: invocation.key.pluginId) == plugin
                    && runtimeBindingIsCurrent(plugin, invocation.binding) else {
            cancelInvocation(invocation)
            return
        }
        _ = removeStoredInvocation(nonce: invocation.nonce)
        bufferModel.finishTransientLoading(requestId: invocation.requestId)
        if wasForeground { foregroundFailureMessage = nil }
        let origin = Origin.plugin(id: plugin.manifest.id)
        let targetSummary = (response.targetSummary ?? invocation.targetSummary)
            .map { String($0.prefix(1_000)) }
        let logicalBlocks = response.blocks
            .prefix(maximumStreamLogicalBlockCount(for: invocation))
            .compactMap { block -> ActionPluginResultBlock? in
            let text = invocation.action.preparePath == nil
                ? String(block.text.prefix(InboundBus.maxTextCount))
                : block.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ActionPluginResultBlock(text: text,
                                           title: block.title.map { String($0.prefix(200)) })
            }
        let usableBlocks: [ActionPluginResultBlock]
        if direct {
            usableBlocks = hostedStreamSegments(
                logicalBlocks.enumerated().map { index, block in
                    PendingStreamBlock(index: index,
                                       text: block.text,
                                       title: block.title)
                }
            ).map {
                ActionPluginResultBlock(text: $0.text, title: $0.title)
            }
        } else {
            // Keep one review item per upstream logical block. Accepting it
            // applies the same semantic segmentation at the BufferModel gate,
            // avoiding inbox-cap data loss from hundreds of tiny children.
            usableBlocks = logicalBlocks
        }
        guard !usableBlocks.isEmpty else {
            if wasForeground {
                bufferModel.failTransientLoading(requestId: invocation.requestId,
                                                 message: "插件没有返回可用文字")
            } else {
                backgroundNoticeMessage = "后台插件没有返回可用文字"
            }
            onChange?()
            return
        }

        if direct, invocation.focusToken != nil {
            registerDeliveryAuthority(invocation)
        }

        var inboxRejectedCount = 0
        for block in usableBlocks {
            let metadata = BufferModel.PluginMetadata(
                pluginId: plugin.manifest.id,
                actionId: invocation.key.actionId,
                requestId: invocation.requestId,
                contextId: invocation.contextId,
                focusToken: invocation.focusToken,
                runtimeIdentity: invocation.binding.identity,
                title: block.title,
                targetSummary: targetSummary,
                stale: !direct,
                reviewedAsPlainText: direct && invocation.focusToken == nil
            )
            if direct {
                bufferModel.stageExternal(block.text,
                                          origin: origin,
                                          pluginMetadata: metadata)
            } else {
                switch inboundBus.submitDetailed(
                    origin: origin,
                    text: block.text,
                    title: block.title ?? targetSummary ?? plugin.manifest.name,
                    pluginMetadata: metadata
                ) {
                case .pending, .staged:
                    break
                case .rejected:
                    inboxRejectedCount += 1
                }
            }
        }
        if inboxRejectedCount > 0 {
            backgroundNoticeMessage = "收信箱已满，\(inboxRejectedCount) 条插件结果未保存"
        }
        onChange?()
    }

    private func registerDeliveryAuthority(_ invocation: ActiveInvocation) {
        deliveryBindings[invocation.requestId] = invocation.binding
        deliveryPlugins[invocation.requestId] = invocation.plugin
        deliveryKeys[invocation.requestId] = invocation.key
        deliveryBindingOrder.removeAll { $0 == invocation.requestId }
        deliveryBindingOrder.append(invocation.requestId)
        while deliveryBindingOrder.count > 128 {
            let removedRequestID = deliveryBindingOrder.removeFirst()
            deliveryBindings[removedRequestID] = nil
            deliveryPlugins[removedRequestID] = nil
            deliveryKeys[removedRequestID] = nil
        }
    }
}

extension ActionPluginHost: WorkbenchManualGenerationControls,
                            BufferDeliveryContentSource {
    var canGenerate: Bool {
        primaryGenerationPresentation?.canInvoke == true
    }

    var isGenerating: Bool {
        primaryGenerationPresentation?.running == true
    }

    var generationProviderName: String {
        primaryGenerationPresentation?.pluginName ?? "Action Plugin"
    }

    var generationStatusText: String {
        if let failure = workbenchFailureMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !failure.isEmpty {
            return failure
        }
        if let label = primaryGenerationPresentation?.label
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return "等待插件上下文"
    }

    var generationRequestDescription: String {
        "让 \(generationProviderName) 处理当前插件上下文"
    }

    var primaryAction: WorkbenchManualGenerationPrimaryAction {
        guard let presentation = primaryGenerationPresentation else { return .disabled }
        return WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: presentation.running,
            hasReadyDelivery: !deliveryPendingBlocks.isEmpty,
            canGenerate: presentation.canInvoke
        )
    }

    @discardableResult
    func generate() -> Bool {
        guard primaryAction == .requestGeneration,
              let presentation = primaryGenerationPresentation else { return false }
        return invoke(presentation.key)
    }

    // MARK: Prepared-generation delivery source

    var deliveryWorkspaceID: String {
        guard let key = primaryGenerationPresentation?.presentationKey else {
            return "action-prepared:none"
        }
        return "action-prepared:\(key.pluginId):\(key.presentationId)"
    }

    var deliveryGeneration: UInt64 { bufferModel.deliveryGeneration }

    var hasIncompleteDeliveryBlocks: Bool {
        guard let presentation = primaryGenerationPresentation else { return false }
        return bufferModel.blocks.contains {
            preparedDeliveryBlock($0, matches: presentation, requireFinal: false)
                && $0.pluginMetadata?.incomplete == true
        }
    }

    var deliveryPendingBlocks: [BufferModel.Block] {
        guard let presentation = primaryGenerationPresentation else { return [] }
        return bufferModel.blocks.filter {
            preparedDeliveryBlock($0, matches: presentation, requireFinal: true)
        }
    }

    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block? {
        guard deliveryGeneration == generation,
              let presentation = primaryGenerationPresentation,
              let block = bufferModel.block(id: id),
              preparedDeliveryBlock(block,
                                    matches: presentation,
                                    requireFinal: true) else { return nil }
        return block
    }

    func consumeDelivered(blockIDs: [UUID], generation: UInt64) {
        _ = consumeDeliveredAndReportTerminalDrain(
            blockIDs: blockIDs,
            generation: generation
        )
    }

    func consumeDeliveredAndReportTerminalDrain(
        blockIDs: [UUID],
        generation: UInt64
    ) -> BufferDeliveryTerminalSourceReceipt? {
        // Delivery.insert already accepted these exact stable UUIDs. Consume
        // them even if unrelated BufferModel input advanced the global model
        // generation while a later block's async target validation was held;
        // otherwise an accepted block could be offered a second time.
        let generationBeforeConsumption = deliveryGeneration
        let presentation = primaryGenerationPresentation
        let workspaceID = presentation.map {
            "action-prepared:\($0.presentationKey.pluginId):\($0.presentationKey.presentationId)"
        }
        let matchingBefore = presentation.map { presentation in
            self.bufferModel.blocks.filter { block in
                blockIDs.contains(block.id)
                    && self.preparedDeliveryBlock(
                        block,
                        matches: presentation,
                        requireFinal: true
                    )
            }
        } ?? []
        bufferModel.consumeDelivered(blockIDs: blockIDs)

        let consumedIDs = Set(matchingBefore.lazy.filter {
            self.bufferModel.block(id: $0.id) == nil
        }.map(\.id))
        guard let presentation,
              let workspaceID,
              generationBeforeConsumption == generation,
              !consumedIDs.isEmpty,
              !presentation.running,
              !bufferModel.blocks.contains(where: {
                self.preparedDeliveryBlock(
                    $0,
                    matches: presentation,
                    requireFinal: false
                )
              }) else {
            return nil
        }
        return BufferDeliveryTerminalSourceReceipt(
            workspaceID: workspaceID,
            generation: generationBeforeConsumption,
            generationAfterConsumption: deliveryGeneration,
            consumedBlockIDs: consumedIDs
        )
    }

    @discardableResult
    func markDeliveryBlockStale(id: UUID, generation _: UInt64) -> Bool {
        // The coordinator selected this stable UUID from the filtered source.
        // Marking it remains safe after unrelated generation changes or an
        // owner switch; BufferModel itself verifies that it is still a bound,
        // non-reviewed plugin block and never acts on a replacement UUID.
        return bufferModel.markPluginBlockStale(id: id)
    }

    private func preparedDeliveryBlock(
        _ block: BufferModel.Block,
        matches presentation: ActionPluginPresentation,
        requireFinal: Bool
    ) -> Bool {
        guard case let .plugin(originPluginID) = block.origin,
              let metadata = block.pluginMetadata,
              originPluginID == presentation.key.pluginId,
              metadata.pluginId == presentation.key.pluginId,
              presentation.preparedGenerationActionIDs.contains(metadata.actionId),
              !metadata.stale else { return false }
        return !requireFinal || !metadata.incomplete
    }
}
