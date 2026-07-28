import Darwin
import Foundation

/// Performs a prompt-free capability check against the exact Codex app-server
/// surface RimeBuffer uses for generation. It intentionally does not inspect
/// release numbers or version-output formatting.
enum AITextCodexCapabilityProbe {
    private static let timeout: TimeInterval = 4
    private static let maximumOutputBytes = 256 * 1_024

    static func run(executableURL: URL,
                    environment: [String: String]) -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RimeBuffer-Codex-Probe-\(UUID().uuidString)",
                                   isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        defer { try? fileManager.removeItem(at: root) }

        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        let homeStore = AITextCodexHomeStore(rootDirectory: stateRoot)
        do {
            try homeStore.prepare()
            try fileManager.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }

        var processEnvironment = AITextCLIExecutableLocator.sanitizedEnvironment(
            for: .codexCLI,
            executableURL: executableURL,
            from: environment
        )
        processEnvironment["CODEX_HOME"] = homeStore.homeDirectory.path
        processEnvironment["TMPDIR"] = root.path
        let semaphore = DispatchSemaphore(value: 0)
        var capabilityResult = false
        let operation = AITextCodexCapabilityProbeOperation(
            executableURL: executableURL,
            arguments: ["app-server"]
                + AITextCodexIsolation.arguments(workspaceURL: workspaceURL)
                + ["--listen", "stdio://"],
            environment: processEnvironment,
            currentDirectoryURL: workspaceURL,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        ) { result in
            capabilityResult = result
            semaphore.signal()
        }
        operation.start()
        guard semaphore.wait(timeout: .now() + timeout + 2) == .success else {
            operation.cancel()
            _ = semaphore.wait(timeout: .now() + 2)
            return false
        }
        return capabilityResult
    }

}

/// A deliberately small JSON-RPC client used only by the capability probe. It
/// never starts a thread or turn, so no prompt and no model request can leave
/// the machine during compatibility detection.
private final class AITextCodexCapabilityProbeOperation: AITextCancellable {
    private enum Lifecycle {
        case idle
        case running
        case stopping
        case finished
    }

    private let stateQueue = DispatchQueue(
        label: "RimeBuffer.AIText.CodexCapabilityProbe",
        qos: .utility
    )
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private var completion: ((Bool) -> Void)?
    private let byteCountLock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var lineBuffer = Data()
    private var reservedOutputBytes = 0
    private var reservedErrorBytes = 0
    private var receivedInitialize = false
    private var processExited = false
    private var stdoutReachedEOF = false
    private var pendingResult: Bool?

    init(executableURL: URL,
         arguments: [String],
         environment: [String: String],
         currentDirectoryURL: URL,
         timeout: TimeInterval,
         maximumOutputBytes: Int,
         completion: @escaping (Bool) -> Void) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = max(1, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.completion = completion
    }

    func start() {
        stateQueue.async { [weak self] in self?.startOnQueue() }
    }

    func cancel() {
        stateQueue.async { [weak self] in self?.requestFinish(false) }
    }

    private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .idle else { return }
        lifecycle = .running

        let child = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = currentDirectoryURL
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.terminationHandler = { [weak self] _ in
            self?.stateQueue.async { [weak self] in self?.processDidExit() }
        }
        process = child
        standardInput = stdinPipe.fileHandleForWriting
        standardOutput = stdoutPipe.fileHandleForReading
        standardError = stderrPipe.fileHandleForReading

        do {
            try child.run()
        } catch {
            process = nil
            standardInput = nil
            standardOutput = nil
            standardError = nil
            close(stdinPipe.fileHandleForWriting)
            close(stdoutPipe.fileHandleForReading)
            close(stderrPipe.fileHandleForReading)
            processExited = true
            requestFinish(false, terminateProcess: false)
            return
        }

        startReading(stdout: stdoutPipe.fileHandleForReading,
                     stderr: stderrPipe.fileHandleForReading)
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout
        ) { [weak self] in
            self?.stateQueue.async { [weak self] in
                self?.requestFinish(false)
            }
        }

        guard send([
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "rimebuffer-capability-probe",
                    "title": ProductIdentity.displayName,
                    "version": "1",
                ],
            ],
        ]) else {
            requestFinish(false)
            return
        }
    }

    private func startReading(stdout: FileHandle, stderr: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? stdout.close() }
            while true {
                let data = stdout.availableData
                guard !data.isEmpty else { break }
                guard self?.reserveOutputBytes(data.count) == true else {
                    self?.stateQueue.async { [weak self] in self?.requestFinish(false) }
                    break
                }
                self?.stateQueue.async { [weak self] in self?.receiveStandardOutput(data) }
            }
            self?.stateQueue.async { [weak self] in
                self?.finishBufferedLine()
                self?.stdoutDidReachEOF()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { try? stderr.close() }
            while true {
                let data = stderr.availableData
                guard !data.isEmpty else { break }
                guard self?.reserveErrorBytes(data.count) == true else {
                    self?.stateQueue.async { [weak self] in self?.requestFinish(false) }
                    break
                }
            }
        }
    }

    private func reserveOutputBytes(_ count: Int) -> Bool {
        byteCountLock.lock()
        defer { byteCountLock.unlock() }
        guard count <= maximumOutputBytes - reservedOutputBytes else { return false }
        reservedOutputBytes += count
        return true
    }

    private func reserveErrorBytes(_ count: Int) -> Bool {
        byteCountLock.lock()
        defer { byteCountLock.unlock() }
        guard count <= maximumOutputBytes - reservedErrorBytes else { return false }
        reservedErrorBytes += count
        return true
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
        lineBuffer.append(data)
        let maximumLineBytes = min(maximumOutputBytes, 128 * 1_024)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let record = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            guard record.count <= maximumLineBytes else {
                requestFinish(false)
                return
            }
            guard !record.isEmpty else { continue }
            receiveRecord(record)
            guard lifecycle == .running else { return }
        }
        if lineBuffer.count > maximumLineBytes {
            requestFinish(false)
        }
    }

    private func finishBufferedLine() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running, !lineBuffer.isEmpty else { return }
        let record = lineBuffer
        lineBuffer.removeAll(keepingCapacity: false)
        guard record.count <= min(maximumOutputBytes, 128 * 1_024) else {
            requestFinish(false)
            return
        }
        receiveRecord(record)
    }

    private func receiveRecord(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            requestFinish(false)
            return
        }
        guard let requestID = Self.integer(object["id"]) else {
            // Notifications such as remoteControl/status/changed are expected
            // on newer app-server builds and are not part of this handshake.
            return
        }
        switch requestID {
        case 1:
            guard !receivedInitialize,
                  object["error"] == nil,
                  object["result"] as? [String: Any] != nil else {
                requestFinish(false)
                return
            }
            receivedInitialize = true
            guard send(["method": "initialized", "params": [:]]),
                  send([
                      "method": "mcpServerStatus/list",
                      "id": 2,
                      "params": ["detail": "toolsAndAuthOnly", "limit": 100],
                  ]) else {
                requestFinish(false)
                return
            }
        case 2:
            guard receivedInitialize,
                  object["error"] == nil,
                  let result = object["result"] as? [String: Any],
                  let servers = result["data"] as? [Any],
                  servers.isEmpty,
                  result["nextCursor"] == nil || result["nextCursor"] is NSNull else {
                requestFinish(false)
                return
            }
            requestFinish(true)
        default:
            return
        }
    }

    private func processDidExit() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        processExited = true
        if lifecycle == .stopping {
            finalizeIfPossible()
        } else if lifecycle == .running, stdoutReachedEOF {
            requestFinish(false, terminateProcess: false)
        }
    }

    private func stdoutDidReachEOF() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        stdoutReachedEOF = true
        if lifecycle == .running, processExited {
            requestFinish(false, terminateProcess: false)
        }
    }

    private func requestFinish(_ result: Bool, terminateProcess: Bool = true) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .running else { return }
        lifecycle = .stopping
        pendingResult = result
        close(standardInput)
        standardInput = nil

        if terminateProcess, let child = process, child.isRunning {
            child.terminate()
            let pid = child.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning, pid > 0 { Darwin.kill(pid, SIGKILL) }
            }
        } else if process?.isRunning != true {
            processExited = true
        }
        finalizeIfPossible()
    }

    private func finalizeIfPossible() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard lifecycle == .stopping, processExited, let result = pendingResult else {
            return
        }
        lifecycle = .finished
        process = nil
        close(standardOutput)
        close(standardError)
        standardOutput = nil
        standardError = nil
        pendingResult = nil
        let callback = completion
        completion = nil
        callback?(result)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private func close(_ handle: FileHandle?) {
        try? handle?.close()
    }
}
