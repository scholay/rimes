import Darwin
import Foundation

enum AITextClaudeLoginStatus: Equatable {
    case launching
    case waitingForBrowser
    case verifying

    var displayText: String {
        switch self {
        case .launching:
            return "正在启动 Claude Code 登录"
        case .waitingForBrowser:
            return "等待浏览器完成 Claude 授权…"
        case .verifying:
            return "授权流程已结束，正在验证 Claude Code 登录…"
        }
    }
}

/// Verifies the installed CLI's own login state without reading credential
/// files or retaining any account metadata returned by the command.
enum AITextClaudeAuthentication {
    static func isLoggedIn(executableURL: URL,
                           environment: [String: String]) -> Bool {
        let runner = AITextFoundationCLIProcessRunner()
        let semaphore = DispatchSemaphore(value: 0)
        var processResult: AITextCLIProcessResult?
        let spec = AITextCLIProcessSpec(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"],
            standardInput: Data(),
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: AITextCLIExecutableLocator.sanitizedEnvironment(
                for: .claudeCodeCLI,
                executableURL: executableURL,
                from: environment
            ),
            timeout: 2,
            maximumOutputBytes: 4_096
        )
        let task = runner.run(spec, onStandardOutput: { _ in }, completion: { result in
            processResult = result
            semaphore.signal()
        })
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            task.cancel()
            return false
        }
        return processResult.map(acceptsStatusResult) ?? false
    }

    static func acceptsStatusResult(_ processResult: AITextCLIProcessResult) -> Bool {
        guard processResult.terminationStatus == 0,
              !processResult.timedOut,
              !processResult.cancelled,
              !processResult.outputTooLarge,
              let object = try? JSONSerialization.jsonObject(
                  with: processResult.standardOutput,
                  options: []
              ) as? [String: Any],
              object["loggedIn"] as? Bool == true else {
            return false
        }
        return true
    }
}

/// Runs the official Claude Code browser login as a fixed, tool-free process.
/// Output is drained only to prevent pipe backpressure; it is never decoded,
/// logged, retained, or surfaced to the settings UI.
final class AITextClaudeLoginOperation: AITextCancellable {
    typealias StatusHandler = (AITextClaudeLoginStatus) -> Void
    typealias Completion = (Result<Void, AITextProviderError>) -> Void

    private enum Lifecycle {
        case idle
        case running
        case verifying
        case finishing
        case finished
    }

    private final class BoundedOutputCounter {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var byteCount = 0
        private var exceeded = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func consume(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !exceeded else { return false }
            guard data.count <= maximumBytes - byteCount else {
                exceeded = true
                return false
            }
            byteCount += data.count
            return true
        }
    }

    private let stateQueue = DispatchQueue(label: "RimeBuffer.AIText.ClaudeLogin")
    private let environment: [String: String]
    private let executableResolver: () -> URL?
    private let compatibilityResolver: (URL) -> Bool
    private let authenticationResolver: (URL, [String: String]) -> Bool
    private let loginTimeout: TimeInterval
    private var statusHandler: StatusHandler?
    private var completion: Completion?

    private var lifecycle: Lifecycle = .idle
    private var process: Process?
    private var temporaryDirectory: URL?
    private var loginExecutableURL: URL?
    private var processTerminationStatus: Int32?
    private var finishedOutputDrainCount = 0
    private var deadlineGeneration: UInt64 = 0
    private var pendingResult: Result<Void, AITextProviderError>?

    private let maximumCombinedOutputBytes = 256 * 1_024

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         executableResolver: (() -> URL?)? = nil,
         compatibilityResolver: ((URL) -> Bool)? = nil,
         authenticationResolver: ((URL, [String: String]) -> Bool)? = nil,
         loginTimeout: TimeInterval = 5 * 60,
         onStatus: @escaping StatusHandler,
         completion: @escaping Completion) {
        let resolvedCompatibility = compatibilityResolver ?? { executableURL in
            AITextClaudeCompatibility.isSupported(executableURL: executableURL,
                                                  environment: environment)
        }
        self.environment = environment
        self.executableResolver = executableResolver ?? {
            AITextCLIExecutableLocator.compatibleExecutable(
                for: .claudeCodeCLI,
                environment: environment,
                compatibility: resolvedCompatibility
            )
        }
        self.compatibilityResolver = resolvedCompatibility
        self.authenticationResolver = authenticationResolver ?? { executableURL, environment in
            AITextClaudeAuthentication.isLoggedIn(executableURL: executableURL,
                                                  environment: environment)
        }
        self.loginTimeout = max(0.05, loginTimeout)
        statusHandler = onStatus
        self.completion = completion
    }

    func start() {
        stateQueue.async { [weak self] in self?.startOnQueue() }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self,
                  self.lifecycle == .running || self.lifecycle == .verifying else { return }
            self.finish(.failure(.cancelled))
        }
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .idle else { return }
        lifecycle = .running
        emitStatus(.launching)

        guard let locatedExecutableURL = executableResolver() else {
            finish(.failure(.unavailable("未找到 Claude Code CLI")), terminateProcess: false)
            return
        }
        guard let before = AITextVerifiedCLIExecutable.capture(locatedExecutableURL),
              compatibilityResolver(before.url),
              let verified = AITextVerifiedCLIExecutable.capture(before.url),
              verified == before else {
            finish(
                .failure(.unavailable(
                    "Claude Code CLI 未提供授权所需的安全参数与流式能力"
                )),
                terminateProcess: false
            )
            return
        }
        let executableURL = verified.url

        let workspaceURL: URL
        do {
            workspaceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("RimeBuffer-Claude-Login-\(UUID().uuidString)",
                                       isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            temporaryDirectory = workspaceURL
        } catch {
            finish(.failure(.failed), terminateProcess: false)
            return
        }

        let child = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = ["auth", "login", "--claudeai"]
        child.currentDirectoryURL = workspaceURL
        var processEnvironment = AITextCLIExecutableLocator.sanitizedEnvironment(
            for: .claudeCodeCLI,
            executableURL: executableURL,
            from: environment
        )
        processEnvironment["TMPDIR"] = workspaceURL.path
        child.environment = processEnvironment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async { [weak self] in
                self?.processDidExit(status: terminated.terminationStatus)
            }
        }

        process = child
        loginExecutableURL = executableURL
        do {
            try child.run()
        } catch {
            process = nil
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            finish(.failure(.failed), terminateProcess: false)
            return
        }

        let outputCounter = BoundedOutputCounter(maximumBytes: maximumCombinedOutputBytes)
        drain(stdoutPipe.fileHandleForReading, counter: outputCounter)
        drain(stderrPipe.fileHandleForReading, counter: outputCounter)
        emitStatus(.waitingForBrowser)
        scheduleDeadline(after: loginTimeout)
    }

    private func drain(_ handle: FileHandle, counter: BoundedOutputCounter) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? handle.close() }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else {
                    self?.stateQueue.async { [weak self] in
                        self?.outputDrainDidFinish(exceeded: false)
                    }
                    return
                }
                guard counter.consume(data) else {
                    self?.stateQueue.async { [weak self] in
                        self?.outputDrainDidFinish(exceeded: true)
                    }
                    return
                }
            }
        }
    }

    private func outputDrainDidFinish(exceeded: Bool) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running else { return }
        if exceeded {
            finish(.failure(.resultTooLarge))
            return
        }
        finishedOutputDrainCount += 1
        advanceAfterLoginIfReady()
    }

    private func processDidExit(status: Int32) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if lifecycle == .finishing {
            finalizeFinish()
            return
        }
        guard lifecycle == .running else { return }
        process = nil
        processTerminationStatus = status
        advanceAfterLoginIfReady()
    }

    private func advanceAfterLoginIfReady() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running,
              finishedOutputDrainCount == 2,
              let status = processTerminationStatus,
              let executableURL = loginExecutableURL else { return }
        deadlineGeneration &+= 1
        guard status == 0 else {
            finish(.failure(.failed), terminateProcess: false)
            return
        }

        lifecycle = .verifying
        emitStatus(.verifying)
        let authenticationResolver = self.authenticationResolver
        let environment = self.environment
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isLoggedIn = authenticationResolver(executableURL, environment)
            self?.stateQueue.async { [weak self] in
                guard let self, self.lifecycle == .verifying else { return }
                if isLoggedIn {
                    self.finish(.success(()), terminateProcess: false)
                } else {
                    self.finish(
                        .failure(.unavailable("Claude Code 登录未通过验证")),
                        terminateProcess: false
                    )
                }
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

    private func emitStatus(_ status: AITextClaudeLoginStatus) {
        guard let statusHandler else { return }
        DispatchQueue.main.async { statusHandler(status) }
    }

    private func finish(_ result: Result<Void, AITextProviderError>,
                        terminateProcess: Bool = true) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running || lifecycle == .verifying else { return }
        lifecycle = .finishing
        pendingResult = result
        deadlineGeneration &+= 1

        guard terminateProcess, let child = process, child.isRunning else {
            finalizeFinish()
            return
        }
        child.terminate()
        let pid = child.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning, pid > 0 { Darwin.kill(pid, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            child.waitUntilExit()
            self?.stateQueue.async { [weak self] in self?.finalizeFinish() }
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
        temporaryDirectory = nil
        loginExecutableURL = nil
        processTerminationStatus = nil
        statusHandler = nil
        completion = nil

        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        if let finalCompletion {
            DispatchQueue.main.async { finalCompletion(result) }
        }
    }

    private func closePipe(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}
