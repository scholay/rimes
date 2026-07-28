import Foundation
import Darwin

enum AITextCodexLoginStatus: Equatable {
    case launching
    case waitingForBrowser
    case verifying

    var displayText: String {
        switch self {
        case .launching: return "正在启动 Codex 登录"
        case .waitingForBrowser: return "等待浏览器完成 ChatGPT 授权…"
        case .verifying: return "授权已返回，正在验证订阅登录…"
        }
    }
}

enum AITextCodexLoginProtocolAction: Equatable {
    case sendInitializedAndStartLogin
    case openAuthorizationURL(URL, loginID: String)
    case sendAccountRead(loginID: String)
    case completed
    case failed
}

/// Pure account/login JSON-RPC state. Keeping this separate from Process makes
/// the authorization URL, login-id binding, and final account verification
/// independently testable without opening a browser or touching credentials.
struct AITextCodexLoginProtocolState {
    static let initializeRequestID = 1
    static let loginStartRequestID = 2
    static let accountReadRequestID = 3
    static let loginCancelRequestID = 4

    private enum Stage: Equatable {
        case initializing
        case startingLogin
        case waitingForBrowser(String)
        case readingAccount(String)
        case completed
        case failed
    }

    private(set) var activeLoginID: String?
    private var stage: Stage = .initializing

    mutating func consume(_ object: [String: Any]) -> [AITextCodexLoginProtocolAction] {
        if let requestID = Self.integer(object["id"]) {
            if object["error"] != nil {
                stage = .failed
                return [.failed]
            }
            switch requestID {
            case Self.initializeRequestID:
                guard stage == .initializing,
                      object["result"] as? [String: Any] != nil else {
                    stage = .failed
                    return [.failed]
                }
                stage = .startingLogin
                return [.sendInitializedAndStartLogin]

            case Self.loginStartRequestID:
                guard stage == .startingLogin,
                      let result = object["result"] as? [String: Any],
                      result["type"] as? String == "chatgpt",
                      let loginID = result["loginId"] as? String,
                      !loginID.isEmpty,
                      loginID.utf8.count <= 512,
                      let rawURL = result["authUrl"] as? String,
                      let url = Self.safeAuthorizationURL(rawURL) else {
                    stage = .failed
                    return [.failed]
                }
                activeLoginID = loginID
                stage = .waitingForBrowser(loginID)
                return [.openAuthorizationURL(url, loginID: loginID)]

            case Self.accountReadRequestID:
                guard case .readingAccount = stage,
                      let result = object["result"] as? [String: Any],
                      let account = result["account"] as? [String: Any],
                      account["type"] as? String == "chatgpt" else {
                    stage = .failed
                    return [.failed]
                }
                stage = .completed
                return [.completed]

            case Self.loginCancelRequestID:
                return []

            default:
                return []
            }
        }

        guard let method = object["method"] as? String else { return [] }
        switch method {
        case "account/login/completed":
            guard let params = object["params"] as? [String: Any],
                  case let .waitingForBrowser(expectedLoginID) = stage,
                  params["loginId"] as? String == expectedLoginID else {
                return []
            }
            guard params["success"] as? Bool == true else {
                stage = .failed
                return [.failed]
            }
            stage = .readingAccount(expectedLoginID)
            return [.sendAccountRead(loginID: expectedLoginID)]

        case "account/updated":
            // This is advisory. The matching completed notification followed
            // by account/read remains the authority for success.
            return []

        case "error":
            stage = .failed
            return [.failed]

        default:
            return []
        }
    }

    private static func safeAuthorizationURL(_ raw: String) -> URL? {
        let allowedHosts: Set<String> = ["auth.openai.com", "chatgpt.com"]
        guard raw.utf8.count <= 8_192,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host.map({ allowedHosts.contains($0.lowercased()) }) == true,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}

/// One browser-based ChatGPT subscription login against RimeBuffer's private
/// Codex home. The operation never reads the user's normal ~/.codex state and
/// never accepts an API key from the process environment.
final class AITextCodexLoginOperation: AITextCancellable {
    typealias AuthorizationHandler = (URL) -> Void
    typealias StatusHandler = (AITextCodexLoginStatus) -> Void
    typealias Completion = (Result<Void, AITextProviderError>) -> Void

    private enum Lifecycle {
        case idle
        case running
        case finishing
        case finished
    }

    private let stateQueue = DispatchQueue(label: "RimeBuffer.AIText.CodexLogin")
    private let environment: [String: String]
    private let homeStore: AITextCodexHomeStore
    private let executableResolver: () -> URL?
    private let compatibilityResolver: (URL) -> Bool
    private let handshakeTimeout: TimeInterval
    private let loginTimeout: TimeInterval
    private var authorizationHandler: AuthorizationHandler?
    private var statusHandler: StatusHandler?
    private var completion: Completion?

    private var lifecycle: Lifecycle = .idle
    private var protocolState = AITextCodexLoginProtocolState()
    private var process: Process?
    private var standardInput: FileHandle?
    private var stdoutReachedEOF = false
    private var processTerminationStatus: Int32?
    private var lineBuffer = Data()
    private var receivedOutputBytes = 0
    private var deadlineGeneration: UInt64 = 0
    private var temporaryDirectory: URL?
    private var pendingResult: Result<Void, AITextProviderError>?

    private let maximumOutputBytes = 1 * 1_024 * 1_024
    private let maximumLineBytes = 256 * 1_024

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         homeStore: AITextCodexHomeStore = .shared,
         executableResolver: (() -> URL?)? = nil,
         compatibilityResolver: ((URL) -> Bool)? = nil,
         handshakeTimeout: TimeInterval = 15,
         loginTimeout: TimeInterval = 5 * 60,
         onAuthorizationURL: @escaping AuthorizationHandler,
         onStatus: @escaping StatusHandler,
         completion: @escaping Completion) {
        let resolvedCompatibility = compatibilityResolver ?? { executableURL in
            AITextCodexCompatibility.isSupported(executableURL: executableURL,
                                                 environment: environment)
        }
        self.environment = environment
        self.homeStore = homeStore
        self.executableResolver = executableResolver ?? {
            AITextCLIExecutableLocator.compatibleExecutable(
                for: .codexCLI,
                environment: environment,
                compatibility: resolvedCompatibility
            )
        }
        self.compatibilityResolver = resolvedCompatibility
        self.handshakeTimeout = max(0.05, handshakeTimeout)
        self.loginTimeout = max(0.05, loginTimeout)
        authorizationHandler = onAuthorizationURL
        statusHandler = onStatus
        self.completion = completion
    }

    func start() {
        stateQueue.async { [weak self] in self?.startOnQueue() }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self, self.lifecycle == .running else { return }
            if let loginID = self.protocolState.activeLoginID {
                _ = self.send([
                    "method": "account/login/cancel",
                    "id": AITextCodexLoginProtocolState.loginCancelRequestID,
                    "params": ["loginId": loginID],
                ])
            }
            self.finish(.failure(.cancelled))
        }
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .idle else { return }
        lifecycle = .running
        emitStatus(.launching)

        guard let locatedExecutableURL = executableResolver() else {
            finish(.failure(.unavailable("未找到 Codex CLI")))
            return
        }
        guard let before = AITextVerifiedCLIExecutable.capture(locatedExecutableURL),
              compatibilityResolver(before.url),
              let verified = AITextVerifiedCLIExecutable.capture(before.url),
              verified == before else {
            finish(.failure(.unavailable(
                "Codex CLI 未通过所需启动参数与 app-server 握手检查"
            )))
            return
        }
        let executableURL = verified.url
        do {
            try homeStore.prepare()
        } catch {
            finish(.failure(.unavailable("无法准备 Codex 的独立安全配置")))
            return
        }

        let workspaceURL: URL
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RimeBuffer-Codex-Login-\(UUID().uuidString)",
                                       isDirectory: true)
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            temporaryDirectory = root
            workspaceURL = root
        } catch {
            finish(.failure(.failed))
            return
        }

        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = executableURL
        // Login exchanges no buffer text and needs Codex's authentication
        // control plane. Generation compatibility has already been verified
        // with the complete isolation argv before this process is launched.
        child.arguments = ["app-server", "--strict-config", "--listen", "stdio://"]
        child.currentDirectoryURL = workspaceURL
        var processEnvironment = AITextCLIExecutableLocator.sanitizedEnvironment(
            for: .codexCLI,
            executableURL: executableURL,
            from: environment
        )
        processEnvironment["CODEX_HOME"] = homeStore.homeDirectory.path
        processEnvironment["TMPDIR"] = workspaceURL.path
        child.environment = processEnvironment
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async { [weak self] in
                self?.processDidExit(status: terminated.terminationStatus)
            }
        }

        process = child
        standardInput = stdinPipe.fileHandleForWriting
        do {
            try child.run()
        } catch {
            process = nil
            standardInput = nil
            close(stdinPipe.fileHandleForWriting)
            close(stdoutPipe.fileHandleForReading)
            close(stderrPipe.fileHandleForReading)
            finish(.failure(.failed), terminateProcess: false)
            return
        }

        startReading(stdout: stdoutPipe.fileHandleForReading,
                     stderr: stderrPipe.fileHandleForReading)
        scheduleDeadline(after: handshakeTimeout)
        guard send([
            "method": "initialize",
            "id": AITextCodexLoginProtocolState.initializeRequestID,
            "params": [
                "clientInfo": [
                    "name": "rimebuffer",
                    "title": ProductIdentity.displayName,
                    "version": "1",
                ],
            ],
        ]) else {
            finish(.failure(.failed))
            return
        }
    }

    private func startReading(stdout: FileHandle, stderr: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? stdout.close() }
            while true {
                let data = stdout.availableData
                guard !data.isEmpty else { break }
                self?.stateQueue.async { [weak self] in self?.receiveStandardOutput(data) }
            }
            self?.stateQueue.async { [weak self] in
                self?.finishBufferedLine()
                self?.standardOutputDidReachEOF()
            }
        }
        DispatchQueue.global(qos: .utility).async {
            defer { try? stderr.close() }
            while !stderr.availableData.isEmpty {}
        }
    }

    @discardableResult
    private func send(_ object: [String: Any]) -> Bool {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running,
              JSONSerialization.isValidJSONObject(object),
              let input = standardInput,
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        var record = data
        record.append(0x0A)
        do {
            try input.write(contentsOf: record)
            return true
        } catch {
            return false
        }
    }

    private func receiveStandardOutput(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running else { return }
        guard data.count <= maximumOutputBytes - receivedOutputBytes else {
            finish(.failure(.resultTooLarge))
            return
        }
        receivedOutputBytes += data.count
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let record = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            guard record.count <= maximumLineBytes else {
                finish(.failure(.resultTooLarge))
                return
            }
            if !record.isEmpty { receiveRecord(record) }
            if lifecycle == .finished { return }
        }
        if lineBuffer.count > maximumLineBytes {
            finish(.failure(.resultTooLarge))
        }
    }

    private func finishBufferedLine() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running, !lineBuffer.isEmpty else { return }
        guard lineBuffer.count <= maximumLineBytes else {
            finish(.failure(.resultTooLarge))
            return
        }
        let record = lineBuffer
        lineBuffer.removeAll(keepingCapacity: false)
        receiveRecord(record)
    }

    private func receiveRecord(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish(.failure(.invalidResult))
            return
        }
        for action in protocolState.consume(object) {
            guard lifecycle == .running else { return }
            switch action {
            case .sendInitializedAndStartLogin:
                guard send(["method": "initialized", "params": [:]]),
                      send([
                        "method": "account/login/start",
                        "id": AITextCodexLoginProtocolState.loginStartRequestID,
                        "params": ["type": "chatgpt"],
                      ]) else {
                    finish(.failure(.failed))
                    return
                }
                scheduleDeadline(after: handshakeTimeout)

            case let .openAuthorizationURL(url, _):
                emitStatus(.waitingForBrowser)
                emitAuthorizationURL(url)
                scheduleDeadline(after: loginTimeout)

            case .sendAccountRead:
                emitStatus(.verifying)
                guard send([
                    "method": "account/read",
                    "id": AITextCodexLoginProtocolState.accountReadRequestID,
                    "params": ["refreshToken": false],
                ]) else {
                    finish(.failure(.failed))
                    return
                }
                scheduleDeadline(after: handshakeTimeout)

            case .completed:
                guard homeStore.hasChatGPTCredential else {
                    finish(.failure(.failed))
                    return
                }
                finish(.success(()))

            case .failed:
                finish(.failure(.failed))
            }
        }
    }

    private func scheduleDeadline(after interval: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        deadlineGeneration &+= 1
        let generation = deadlineGeneration
        stateQueue.asyncAfter(deadline: .now() + max(1, interval)) { [weak self] in
            guard let self,
                  self.lifecycle == .running,
                  self.deadlineGeneration == generation else { return }
            self.finish(.failure(.timedOut))
        }
    }

    private func processDidExit(status: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        processTerminationStatus = status
        if lifecycle == .finishing {
            finalizeFinish()
            return
        }
        guard stdoutReachedEOF else { return }
        failForPrematureProcessExit()
    }

    private func standardOutputDidReachEOF() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        stdoutReachedEOF = true
        guard processTerminationStatus != nil else { return }
        failForPrematureProcessExit()
    }

    private func failForPrematureProcessExit() {
        guard lifecycle == .running else { return }
        finish(.failure(.failed), terminateProcess: false)
    }

    private func emitAuthorizationURL(_ url: URL) {
        guard let handler = authorizationHandler else { return }
        DispatchQueue.main.async { handler(url) }
    }

    private func emitStatus(_ status: AITextCodexLoginStatus) {
        guard let handler = statusHandler else { return }
        DispatchQueue.main.async { handler(status) }
    }

    private func finish(_ result: Result<Void, AITextProviderError>,
                        terminateProcess: Bool = true) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running else { return }
        lifecycle = .finishing
        pendingResult = result
        deadlineGeneration &+= 1

        let child = process
        let input = standardInput
        standardInput = nil
        close(input)

        guard terminateProcess, let child, child.isRunning else {
            finalizeFinish()
            return
        }
        child.terminate()
        let pid = child.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning, pid > 0 { Darwin.kill(pid, SIGKILL) }
        }
        // Completion stays pending until the child has actually exited. This
        // prevents a second login process from sharing the same auth store
        // during token persistence/teardown. The termination handler normally
        // wins; waitUntilExit is a bounded-by-SIGKILL fallback.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            child.waitUntilExit()
            let status = child.terminationStatus
            self?.stateQueue.async { [weak self] in
                self?.processDidExit(status: status)
            }
        }
    }

    private func finalizeFinish() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .finishing, let result = pendingResult else { return }
        lifecycle = .finished
        pendingResult = nil

        let directory = temporaryDirectory
        let finalCompletion = completion
        process = nil
        standardInput = nil
        temporaryDirectory = nil
        authorizationHandler = nil
        statusHandler = nil
        completion = nil

        if let directory {
            _ = try? FileManager.default.removeItem(at: directory)
        }
        if let finalCompletion {
            DispatchQueue.main.async { finalCompletion(result) }
        }
    }

    private func close(_ handle: FileHandle?) {
        try? handle?.close()
    }
}
