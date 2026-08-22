import Darwin
import Foundation

private final class AITextSmokeCancellation: AITextCancellable {
    private(set) var wasCancelled = false
    func cancel() { wasCancelled = true }
}

private final class AITextSmokeCounter {
    private let lock = NSLock()
    private var storage = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storage += 1
        let value = storage
        lock.unlock()
        return value
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class AITextSmokeProvider: AITextProvider {
    let kind: AITextProviderKind
    var availability: AITextProviderAvailability = .ready
    private(set) var requests: [AITextProviderRequest] = []
    private(set) var cancellations: [AITextSmokeCancellation] = []
    private var eventCallbacks: [(AITextProviderEvent) -> Void] = []
    private var completions: [(Result<[AITextProviderBlock], AITextProviderError>) -> Void] = []

    init(kind: AITextProviderKind = .codexCLI) {
        self.kind = kind
    }

    @discardableResult
    func generate(_ request: AITextProviderRequest,
                  onEvent: @escaping (AITextProviderEvent) -> Void,
                  completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void)
        -> any AITextCancellable {
        requests.append(request)
        eventCallbacks.append(onEvent)
        completions.append(completion)
        let cancellation = AITextSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func emit(_ block: AITextProviderBlock, request index: Int) {
        eventCallbacks[index](.blockSnapshot(block))
    }

    func emitActivity(_ message: String,
                      kind: AITextProviderActivityKind = .reasoning,
                      request index: Int) {
        eventCallbacks[index](.activity(AITextProviderActivity(kind: kind,
                                                               message: message)))
    }

    func finish(_ result: Result<[AITextProviderBlock], AITextProviderError>,
                request index: Int) {
        completions[index](result)
    }
}

private final class AITextSmokeSelection {
    var selected = true
}

private final class AITextSmokeRunner: AITextCLIProcessRunning {
    private(set) var specs: [AITextCLIProcessSpec] = []
    private(set) var cancellations: [AITextSmokeCancellation] = []
    private var outputs: [(Data) -> Void] = []
    private var completions: [(AITextCLIProcessResult) -> Void] = []

    @discardableResult
    func run(_ spec: AITextCLIProcessSpec,
             onStandardOutput: @escaping (Data) -> Void,
             completion: @escaping (AITextCLIProcessResult) -> Void) -> any AITextCancellable {
        specs.append(spec)
        outputs.append(onStandardOutput)
        completions.append(completion)
        let cancellation = AITextSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func succeed(request index: Int, chunks: [Data]) {
        chunks.forEach(outputs[index])
        completions[index](AITextCLIProcessResult(terminationStatus: 0,
                                                  standardOutput: chunks.reduce(into: Data()) { $0.append($1) },
                                                  timedOut: false,
                                                  cancelled: false,
                                                  outputTooLarge: false))
    }
}

private final class AITextSmokeURLProtocol: URLProtocol {
    private static let handlerLock = NSLock()
    private static var storedHandler: ((AITextSmokeURLProtocol) -> Void)?

    static func install(_ handler: @escaping (AITextSmokeURLProtocol) -> Void) {
        handlerLock.lock()
        storedHandler = handler
        handlerLock.unlock()
    }

    static func reset() {
        handlerLock.lock()
        storedHandler = nil
        handlerLock.unlock()
    }

    private static func currentHandler() -> ((AITextSmokeURLProtocol) -> Void)? {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return storedHandler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        handler(self)
    }

    override func stopLoading() {}
}

private final class AITextOpenAISmokeRecorder {
    struct Snapshot {
        var events: [AITextProviderEvent]
        var results: [Result<[AITextProviderBlock], AITextProviderError>]
        var eventAfterCompletion: Bool
    }

    private let lock = NSLock()
    private var events: [AITextProviderEvent] = []
    private var results: [Result<[AITextProviderBlock], AITextProviderError>] = []
    private var completed = false
    private var eventAfterCompletion = false

    func record(_ event: AITextProviderEvent) {
        lock.lock()
        if completed { eventAfterCompletion = true }
        events.append(event)
        lock.unlock()
    }

    func record(_ result: Result<[AITextProviderBlock], AITextProviderError>) {
        lock.lock()
        completed = true
        results.append(result)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(events: events,
                        results: results,
                        eventAfterCompletion: eventAfterCompletion)
    }
}

private enum AITextCodexLoginProtocolSmoke {
    static func run() -> Bool {
        for rawURL in [
            "https://auth.openai.com/oauth/authorize?state=smoke",
            "https://chatgpt.com/auth/callback?state=smoke",
        ] {
            var state = AITextCodexLoginProtocolState()
            guard beginLogin(&state),
                  containsAuthorization(state.consume([
                    "id": AITextCodexLoginProtocolState.loginStartRequestID,
                    "result": [
                        "type": "chatgpt",
                        "loginId": "login-smoke",
                        "authUrl": rawURL,
                    ],
                  ]), rawURL: rawURL) else { return false }
        }

        for rejectedURL in [
            "http://auth.openai.com/oauth/authorize",
            "https://auth.openai.com.evil.example/oauth/authorize",
            "https://user@auth.openai.com/oauth/authorize",
            "https://auth.openai.com:444/oauth/authorize",
        ] {
            var state = AITextCodexLoginProtocolState()
            guard beginLogin(&state),
                  containsFailure(state.consume([
                    "id": AITextCodexLoginProtocolState.loginStartRequestID,
                    "result": [
                        "type": "chatgpt",
                        "loginId": "login-smoke",
                        "authUrl": rejectedURL,
                    ],
                  ])) else { return false }
        }

        var success = AITextCodexLoginProtocolState()
        guard beginLogin(&success),
              containsAuthorization(success.consume([
                "id": AITextCodexLoginProtocolState.loginStartRequestID,
                "result": [
                    "type": "chatgpt",
                    "loginId": "expected-login",
                    "authUrl": "https://chatgpt.com/auth/callback",
                ],
              ]), rawURL: "https://chatgpt.com/auth/callback"),
              success.consume([
                "method": "account/login/completed",
                "params": ["loginId": "other-login", "success": true],
              ]).isEmpty,
              containsAccountRead(success.consume([
                "method": "account/login/completed",
                "params": ["loginId": "expected-login", "success": true],
              ])),
              containsCompletion(success.consume([
                "id": AITextCodexLoginProtocolState.accountReadRequestID,
                "result": [
                    "account": [
                        "type": "chatgpt",
                        "email": NSNull(),
                        "planType": "plus",
                    ],
                    "requiresOpenaiAuth": true,
                ],
              ])) else { return false }

        var failedCompletion = AITextCodexLoginProtocolState()
        guard beginLogin(&failedCompletion) else { return false }
        _ = failedCompletion.consume([
            "id": AITextCodexLoginProtocolState.loginStartRequestID,
            "result": [
                "type": "chatgpt",
                "loginId": "failed-login",
                "authUrl": "https://auth.openai.com/oauth/authorize",
            ],
        ])
        guard containsFailure(failedCompletion.consume([
            "method": "account/login/completed",
            "params": ["loginId": "failed-login", "success": false],
        ])) else { return false }

        var missingAccount = AITextCodexLoginProtocolState()
        guard beginLogin(&missingAccount) else { return false }
        _ = missingAccount.consume([
            "id": AITextCodexLoginProtocolState.loginStartRequestID,
            "result": [
                "type": "chatgpt",
                "loginId": "missing-account",
                "authUrl": "https://auth.openai.com/oauth/authorize",
            ],
        ])
        _ = missingAccount.consume([
            "method": "account/login/completed",
            "params": ["loginId": "missing-account", "success": true],
        ])
        guard containsFailure(missingAccount.consume([
            "id": AITextCodexLoginProtocolState.accountReadRequestID,
            "result": ["account": NSNull(), "requiresOpenaiAuth": true],
        ])) else { return false }

        var rpcError = AITextCodexLoginProtocolState()
        guard containsFailure(rpcError.consume([
            "id": AITextCodexLoginProtocolState.initializeRequestID,
            "error": ["code": -32_000, "message": "smoke"],
        ])) else { return false }
        return true
    }

    private static func beginLogin(_ state: inout AITextCodexLoginProtocolState) -> Bool {
        state.consume([
            "id": AITextCodexLoginProtocolState.initializeRequestID,
            "result": ["userAgent": "smoke"],
        ]).contains {
            if case .sendInitializedAndStartLogin = $0 { return true }
            return false
        }
    }

    private static func containsAuthorization(
        _ actions: [AITextCodexLoginProtocolAction],
        rawURL: String
    ) -> Bool {
        actions.contains {
            if case let .openAuthorizationURL(url, loginID) = $0 {
                return url.absoluteString == rawURL && loginID == "login-smoke"
                    || url.absoluteString == rawURL && loginID == "expected-login"
            }
            return false
        }
    }

    private static func containsAccountRead(
        _ actions: [AITextCodexLoginProtocolAction]
    ) -> Bool {
        actions.contains {
            if case let .sendAccountRead(loginID) = $0 {
                return loginID == "expected-login"
            }
            return false
        }
    }

    private static func containsCompletion(
        _ actions: [AITextCodexLoginProtocolAction]
    ) -> Bool {
        actions.contains { if case .completed = $0 { return true }; return false }
    }

    private static func containsFailure(
        _ actions: [AITextCodexLoginProtocolAction]
    ) -> Bool {
        actions.contains { if case .failed = $0 { return true }; return false }
    }
}

private enum AITextCodexLoginTransportSmoke {
    private enum Mode: String {
        case success
        case cancel
        case timeout
    }

    static func run() -> Bool {
        guard statusDecoder() else {
            print("Claude auth status decoder smoke failed")
            return false
        }
        for mode in [Mode.success, .cancel, .timeout] {
            guard exercise(mode) else {
                print("Codex login transport smoke failed: \(mode.rawValue)")
                return false
            }
        }
        return true
    }

    private static func statusDecoder() -> Bool {
        func result(_ json: String,
                    status: Int32 = 0,
                    timedOut: Bool = false,
                    cancelled: Bool = false,
                    outputTooLarge: Bool = false) -> AITextCLIProcessResult {
            AITextCLIProcessResult(
                terminationStatus: status,
                standardOutput: Data(json.utf8),
                timedOut: timedOut,
                cancelled: cancelled,
                outputTooLarge: outputTooLarge
            )
        }
        let loggedIn = result("{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}")
        guard AITextClaudeAuthentication.acceptsStatusResult(loggedIn),
              !AITextClaudeAuthentication.acceptsStatusResult(
                result("{\"loggedIn\":false}")
              ),
              !AITextClaudeAuthentication.acceptsStatusResult(result("not-json")),
              !AITextClaudeAuthentication.acceptsStatusResult(result("{\"loggedIn\":true}",
                                                                      status: 1)),
              !AITextClaudeAuthentication.acceptsStatusResult(result("{\"loggedIn\":true}",
                                                                      timedOut: true)),
              !AITextClaudeAuthentication.acceptsStatusResult(result("{\"loggedIn\":true}",
                                                                      cancelled: true)),
              !AITextClaudeAuthentication.acceptsStatusResult(result("{\"loggedIn\":true}",
                                                                      outputTooLarge: true)) else {
            return false
        }
        return true
    }

    private static func exercise(_ mode: Mode) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-Codex-Login-Transport-Smoke-\(UUID().uuidString)",
                                   isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("fake-codex")
        let exitMarker = root.appendingPathComponent("process-exited")
        let traceURL = root.appendingPathComponent("trace")
        let script = fakeServerScript(mode: mode,
                                      exitMarker: exitMarker,
                                      traceURL: traceURL)
        do {
            try Data(script.utf8).write(to: executable, options: .atomic)
            guard chmod(executable.path, S_IRWXU) == 0 else { return false }
        } catch {
            return false
        }

        let homeStore = AITextCodexHomeStore(
            rootDirectory: root.appendingPathComponent("app-data", isDirectory: true)
        )
        var operation: AITextCodexLoginOperation?
        var result: Result<Void, AITextProviderError>?
        var completionCount = 0
        var receivedAuthorizationURL = false
        var callbackAfterCompletion = false
        operation = AITextCodexLoginOperation(
            environment: ["HOME": "/tmp", "USER": "smoke", "LOGNAME": "smoke"],
            homeStore: homeStore,
            executableResolver: { executable },
            compatibilityResolver: { _ in true },
            handshakeTimeout: mode == .timeout ? 0.1 : 3,
            loginTimeout: 1,
            onAuthorizationURL: { _ in
                if result != nil { callbackAfterCompletion = true }
                receivedAuthorizationURL = true
                if mode == .cancel { operation?.cancel() }
            },
            onStatus: { _ in
                if result != nil { callbackAfterCompletion = true }
            },
            completion: {
                completionCount += 1
                result = $0
            }
        )
        operation?.start()
        guard waitUntil(timeout: 4, { result != nil }) else {
            operation?.cancel()
            print("Codex login transport timed out waiting for completion: \(mode.rawValue)")
            return false
        }
        _ = waitUntil(timeout: 0.15, { false })
        guard completionCount == 1,
              !callbackAfterCompletion,
              FileManager.default.fileExists(atPath: exitMarker.path) else {
            print("Codex login transport lifecycle mismatch: mode=\(mode.rawValue) completions=\(completionCount) late=\(callbackAfterCompletion) exited=\(FileManager.default.fileExists(atPath: exitMarker.path)) result=\(String(describing: result))")
            return false
        }
        switch (mode, result) {
        case (.success, .success?):
            return receivedAuthorizationURL && homeStore.hasChatGPTCredential
        case (.cancel, .failure(.cancelled)?):
            return receivedAuthorizationURL
        case (.timeout, .failure(.timedOut)?):
            return !receivedAuthorizationURL
        default:
            let trace = (try? String(contentsOf: traceURL, encoding: .utf8)) ?? "<none>"
            print("Codex login transport result mismatch: mode=\(mode.rawValue) authURL=\(receivedAuthorizationURL) credential=\(homeStore.hasChatGPTCredential) result=\(String(describing: result)) trace=\(trace)")
            return false
        }
    }

    private static func waitUntil(timeout: TimeInterval,
                                  _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default,
                                    before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func fakeServerScript(mode: Mode,
                                         exitMarker: URL,
                                         traceURL: URL) -> String {
        let marker = shellQuote(exitMarker.path)
        let trace = shellQuote(traceURL.path)
        let header = """
        #!/bin/sh
        MARKER=\(marker)
        TRACE=\(trace)
        trap 'sleep 0.2; : > "$MARKER"; exit 0' TERM
        hang() { while :; do /bin/sleep 0.1; done; }

        """
        if mode == .timeout {
            return header + "while IFS= read -r line; do hang; done\n"
        }
        let loginResponse = """
              *login*start*)
        """ + (mode == .success ? """
                printf '%s\n%s\n' '{"id":2,"result":{"type":"chatgpt","loginId":"transport-login","authUrl":"https://auth.openai.com/oauth/authorize?state=smoke"}}' '{"method":"account/login/completed","params":{"loginId":"transport-login","success":true,"error":null}}'
        """ : """
                printf '%s\n' '{"id":2,"result":{"type":"chatgpt","loginId":"transport-login","authUrl":"https://chatgpt.com/auth/callback?state=smoke"}}'
                hang
        """) + """
                ;;
        """
        let accountResponse = mode == .success ? """
              *account*read*)
                printf '%s' '{"auth_mode":"chatgpt","tokens":{"access_token":"access","refresh_token":"refresh"}}' > "$CODEX_HOME/auth.json"
                chmod 600 "$CODEX_HOME/auth.json"
                printf '%s\n' '{"id":3,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}'
                hang
                ;;
        """ : ""
        return header + """
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$TRACE"
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s' '{"id":1,"result":'
              /bin/sleep 0.02
              printf '%s\n' '{"userAgent":"transport-smoke"}}'
              ;;
        \(loginResponse)
        \(accountResponse)
          esac
        done
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum AITextClaudeLoginTransportSmoke {
    private enum Mode: String {
        case success
        case cancel
        case timeout
    }

    static func run() -> Bool {
        for mode in [Mode.success, .cancel, .timeout] {
            guard exercise(mode) else {
                print("Claude login transport smoke failed: \(mode.rawValue)")
                return false
            }
        }
        return true
    }

    private static func exercise(_ mode: Mode) -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-Claude-Login-Transport-Smoke-\(UUID().uuidString)",
                                   isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("fake-claude")
        let exitMarker = root.appendingPathComponent("process-exited")
        let invocationMarker = root.appendingPathComponent("safe-invocation")
        let script = fakeCLIScript(mode: mode,
                                   exitMarker: exitMarker,
                                   invocationMarker: invocationMarker)
        do {
            try Data(script.utf8).write(to: executable, options: .atomic)
            guard chmod(executable.path, S_IRWXU) == 0 else { return false }
        } catch {
            return false
        }

        var operation: AITextClaudeLoginOperation?
        var result: Result<Void, AITextProviderError>?
        var completionCount = 0
        let authenticationChecks = AITextSmokeCounter()
        var callbackAfterCompletion = false
        var statuses: [AITextClaudeLoginStatus] = []
        operation = AITextClaudeLoginOperation(
            environment: [
                "HOME": "/tmp",
                "USER": "smoke",
                "LOGNAME": "smoke",
                "ANTHROPIC_API_KEY": "must-not-leak",
                "CLAUDE_CODE_OAUTH_TOKEN": "must-not-leak",
                "CLAUDE_CONFIG_DIR": "/tmp/must-not-leak",
            ],
            executableResolver: { executable },
            compatibilityResolver: { _ in true },
            authenticationResolver: { _, _ in
                authenticationChecks.increment()
                return mode == .success
            },
            loginTimeout: mode == .timeout ? 0.1 : 3,
            onStatus: { status in
                if result != nil { callbackAfterCompletion = true }
                statuses.append(status)
                if mode == .cancel, status == .waitingForBrowser {
                    operation?.cancel()
                }
            },
            completion: {
                completionCount += 1
                result = $0
            }
        )
        operation?.start()
        guard waitUntil(timeout: 5, { result != nil }) else {
            operation?.cancel()
            return false
        }
        _ = waitUntil(timeout: 0.15, { false })
        let requiresScriptStartup = mode != .cancel
        guard completionCount == 1,
              !callbackAfterCompletion,
              (!requiresScriptStartup
                || FileManager.default.fileExists(atPath: exitMarker.path)),
              (!requiresScriptStartup
                || FileManager.default.fileExists(atPath: invocationMarker.path)),
              statuses.first == .launching,
              statuses.contains(.waitingForBrowser) else {
            print("Claude login lifecycle mismatch: mode=\(mode.rawValue) result=\(String(describing: result)) completions=\(completionCount) late=\(callbackAfterCompletion) exited=\(FileManager.default.fileExists(atPath: exitMarker.path)) invoked=\(FileManager.default.fileExists(atPath: invocationMarker.path)) statuses=\(statuses) authChecks=\(authenticationChecks.value)")
            return false
        }
        switch (mode, result) {
        case (.success, .success?):
            return statuses.contains(.verifying) && authenticationChecks.value == 1
        case (.cancel, .failure(.cancelled)?):
            return !statuses.contains(.verifying) && authenticationChecks.value == 0
        case (.timeout, .failure(.timedOut)?):
            return !statuses.contains(.verifying) && authenticationChecks.value == 0
        default:
            print("Claude login result mismatch: mode=\(mode.rawValue) result=\(String(describing: result)) statuses=\(statuses) authChecks=\(authenticationChecks.value)")
            return false
        }
    }

    private static func waitUntil(timeout: TimeInterval,
                                  _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default,
                                    before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func fakeCLIScript(mode: Mode,
                                      exitMarker: URL,
                                      invocationMarker: URL) -> String {
        let exitPath = shellQuote(exitMarker.path)
        let invocationPath = shellQuote(invocationMarker.path)
        let body: String
        switch mode {
        case .success:
            body = "printf 'browser opened\\n'; printf 'waiting\\n' >&2; finish\n"
        case .cancel, .timeout:
            body = "while :; do /bin/sleep 0.05; done\n"
        }
        return """
        #!/bin/sh
        EXIT_MARKER=\(exitPath)
        INVOCATION_MARKER=\(invocationPath)
        finish() { : > "$EXIT_MARKER"; exit 0; }
        trap finish TERM INT
        if [ "$#" -ne 3 ] || [ "$1" != "auth" ] || [ "$2" != "login" ] || [ "$3" != "--claudeai" ]; then
          exit 64
        fi
        if [ -n "${ANTHROPIC_API_KEY+x}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN+x}" ] || [ -n "${CLAUDE_CONFIG_DIR+x}" ]; then
          exit 65
        fi
        : > "$INVOCATION_MARKER"
        \(body)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum AITextFoundationCLIStreamingSmoke {
    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-CLI-Streaming-Smoke-\(UUID().uuidString)",
                                   isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("stream-fixture")
        let releaseMarker = root.appendingPathComponent("release-final-output")
        let script = """
        #!/bin/sh
        printf '%s' 'partial'
        while [ ! -e "$1" ]; do /bin/sleep 0.02; done
        printf '%s' 'final'
        """
        do {
            try Data(script.utf8).write(to: executable, options: .atomic)
            guard chmod(executable.path, S_IRWXU) == 0 else { return false }
        } catch {
            return false
        }

        let firstChunk = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var observedFirst = false
        var releasedProcess = false
        var firstData = Data()
        var finalResult: AITextCLIProcessResult?
        let runner = AITextFoundationCLIProcessRunner()
        let task = runner.run(
            AITextCLIProcessSpec(
                executableURL: executable,
                arguments: [releaseMarker.path],
                standardInput: Data(),
                currentDirectoryURL: root,
                environment: ["HOME": "/tmp", "PATH": "/usr/bin:/bin"],
                timeout: 10,
                maximumOutputBytes: 1_024
            ),
            onStandardOutput: { data in
                lock.lock()
                if !observedFirst {
                    observedFirst = true
                    firstData = data
                    releasedProcess = FileManager.default.createFile(
                        atPath: releaseMarker.path,
                        contents: Data()
                    )
                    firstChunk.signal()
                }
                lock.unlock()
            },
            completion: { result in
                lock.lock()
                finalResult = result
                lock.unlock()
                completed.signal()
            }
        )
        // The marker makes this a causal streaming assertion instead of a
        // scheduler-speed assertion: the child cannot emit its final bytes or
        // exit until the first stdout callback has actually arrived.
        guard firstChunk.wait(timeout: .now() + 5) == .success else {
            task.cancel()
            _ = completed.wait(timeout: .now() + 2)
            return false
        }
        guard completed.wait(timeout: .now() + 5) == .success else {
            task.cancel()
            return false
        }
        lock.lock()
        let first = firstData
        let didReleaseProcess = releasedProcess
        let result = finalResult
        lock.unlock()
        return didReleaseProcess
            && String(data: first, encoding: .utf8) == "partial"
            && String(data: result?.standardOutput ?? Data(), encoding: .utf8) == "partialfinal"
            && result?.terminationStatus == 0
            && result?.timedOut == false
            && result?.cancelled == false
    }
}

private enum AITextPluginSmoke {
    static func run() -> Bool {
        guard Thread.isMainThread else { return false }
        guard resultDecoder() else {
            print("AI text smoke failed: result decoder")
            return false
        }
        guard streamParsers() else {
            print("AI text smoke failed: stream parsers")
            return false
        }
        guard fakeCLIRunners() else {
            print("AI text smoke failed: CLI providers")
            return false
        }
        guard configurationStorageAndRequest() else {
            print("AI text smoke failed: OpenAI configuration")
            return false
        }
        guard openAIStreamingOperation() else {
            print("AI text smoke failed: OpenAI streaming")
            return false
        }
        guard connectorSelectionAndUnifiedWorkspace() else {
            print("AI text smoke failed: connector workspace")
            return false
        }
        guard workspaceGatesAndDelivery() else {
            print("AI text smoke failed: workspace gates")
            return false
        }
        guard workspaceForcesProviderSegmentation() else {
            print("AI text smoke failed: workspace forced segmentation")
            return false
        }
        guard remoteMirrorAndActionReview() else {
            print("AI text smoke failed: remote action review")
            return false
        }
        return true
    }

    static func terminalDeliveryReceipt() -> Bool {
        guard Thread.isMainThread else { return false }
        let source = BufferModel()
        let provider = AITextSmokeProvider()
        let workspace = AITextPluginWorkspace(
            provider: provider,
            sourceModel: source,
            isSelected: { true }
        )
        workspace.start()
        defer { workspace.stop() }

        let previousBufferEnabled = UserDefaults.standard.object(
            forKey: "bufferEnabled"
        )
        defer {
            if let previousBufferEnabled {
                UserDefaults.standard.set(
                    previousBufferEnabled,
                    forKey: "bufferEnabled"
                )
            } else {
                UserDefaults.standard.removeObject(forKey: "bufferEnabled")
            }
        }
        source.enabled = true
        source.stageExternal("source", origin: .rime)
        guard workspace.generate(), provider.requests.count == 1 else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "first", title: nil),
            AITextProviderBlock(index: 1, text: "last", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 2 else { return false }

        let firstGeneration = workspace.deliveryGeneration
        let firstID = workspace.outputBlocks[0].id
        guard workspace.consumeDeliveredAndReportTerminalDrain(
                blockIDs: [firstID],
                generation: firstGeneration
              ) == nil,
              source.stagedText == "source",
              workspace.outputBlocks.count == 1 else { return false }

        let terminalGeneration = workspace.deliveryGeneration
        let terminalID = workspace.outputBlocks[0].id
        return workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: [terminalID],
            generation: terminalGeneration
        ) == BufferDeliveryTerminalSourceReceipt(
            workspaceID: workspace.deliveryWorkspaceID,
            generation: terminalGeneration,
            generationAfterConsumption: workspace.deliveryGeneration,
            consumedBlockIDs: Set([terminalID])
        ) && source.stagedText.isEmpty
            && workspace.outputBlocks.isEmpty
            && workspace.phase == .idle
    }

    private static func resultDecoder() -> Bool {
        let structured = """
        {"blocks":[{"text":"第一块","title":"A"},{"text":"第二块","title":null}]}
        """
        guard AITextResultDecoder.JSONSchema.contains("\"required\":[\"text\",\"title\"]"),
              let blocks = try? AITextResultDecoder.decodeFinalText(structured),
              blocks.count == 2,
              blocks[0].index == 0,
              blocks[0].text == "第一块",
              blocks[1].index == 1 else { return false }
        guard let fenced = try? AITextResultDecoder.decodeFinalText("```json\n\(structured)\n```"),
              fenced == blocks else { return false }
        guard let uppercaseFenced = try? AITextResultDecoder.decodeFinalText(
            "```JSON\n\(structured)\n```"
        ), uppercaseFenced == blocks else { return false }
        guard let fallback = try? AITextResultDecoder.decodeFinalText("甲\n\n乙"),
              fallback.map(\.text) == ["甲\n\n乙"] else { return false }
        let fineSource = "第一句，第二句。第三句\n第四句；第五句！"
        let fine = AITextFineBlockSegmenter.refine([
            AITextProviderBlock(index: 0, text: fineSource, title: "细分"),
        ])
        guard fine.count >= 5,
              fine.map(\.text).joined() == fineSource,
              fine.map(\.index) == Array(fine.indices),
              fine.first?.title == "细分",
              fine.dropFirst().allSatisfy({ $0.title == nil }) else { return false }
        let protectedSource = "访问 https://example.com/a?x=1,000&at=12:30，然后看“你好，世界”，代码 `let value = \"a,b:c\"`。"
        let protected = AITextFineBlockSegmenter.refine([
            AITextProviderBlock(index: 0, text: protectedSource, title: nil),
        ])
        guard protected.map(\.text).joined() == protectedSource,
              protected.contains(where: { $0.text.contains("https://example.com/a?x=1,000&at=12:30") }),
              protected.contains(where: { $0.text.contains("“你好，世界”") }),
              protected.contains(where: { $0.text.contains("`let value = \"a,b:c\"`") }) else {
            return false
        }
        let prefixedURLSource = "链接 (https://example.com/a?x=1,000&at=12:30)，后续"
        let prefixedURL = SemanticBlockSegmenter.segments(from: prefixedURLSource)
        guard prefixedURL.joined() == prefixedURLSource,
              prefixedURL.contains(where: {
                  $0.contains("(https://example.com/a?x=1,000&at=12:30)，")
              }) else { return false }
        let punctuationEdge = String(repeating: "中", count: 48) + "，后续"
        let punctuationSegments = SemanticBlockSegmenter.segments(from: punctuationEdge)
        guard punctuationSegments.joined() == punctuationEdge,
              !punctuationSegments.contains("，") else { return false }
        let exactWhitespace = "  甲\r\n\n乙  "
        let exactFragments = SemanticBlockSegmenter.refine(
            [SemanticLogicalBlock(sourceIndex: 0,
                                  text: exactWhitespace,
                                  title: nil)],
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        guard exactFragments.map(\.text).joined() == exactWhitespace else { return false }
        let englishSource = "This is one short phrase and this is another. Final words!"
        let english = AITextFineBlockSegmenter.refine([
            AITextProviderBlock(index: 0, text: englishSource, title: nil),
        ])
        guard english.count >= 3,
              english.map(\.text).joined() == englishSource,
              english.allSatisfy({ block in
                  let words = block.text.split { !$0.isLetter && !$0.isNumber }
                  return words.count <= SemanticBlockSegmenter.preferredLatinWordCount
                      || block.text.contains("https://")
              }) else { return false }
        var previousPrefixBlocks: [AITextProviderBlock] = []
        var growing = ""
        for character in protectedSource {
            growing.append(character)
            let currentBlocks = AITextFineBlockSegmenter.refine([
                AITextProviderBlock(index: 0, text: growing, title: "流式"),
            ])
            let stableCount = max(0, previousPrefixBlocks.count - 1)
            guard Array(currentBlocks.prefix(stableCount))
                == Array(previousPrefixBlocks.prefix(stableCount)) else { return false }
            previousPrefixBlocks = currentBlocks
        }
        let manyClauses = (1 ... (AITextRuntimeLimits.maximumBlockCount + 1))
            .map { "第\($0)段，" }
            .joined()
        let capped = AITextFineBlockSegmenter.refine([
            AITextProviderBlock(index: 0, text: manyClauses, title: nil),
        ])
        guard capped.count == AITextRuntimeLimits.maximumBlockCount,
              capped.map(\.text).joined() == manyClauses,
              capped.last?.text.contains(
                  "第\(AITextRuntimeLimits.maximumBlockCount + 1)段"
              ) == true else { return false }
        let atCapacity = SemanticBlockSegmenter.refine(
            [SemanticLogicalBlock(
                sourceIndex: 0,
                text: (1...SemanticBlockSegmenter.maximumWorkbenchSegments)
                    .map { "u\($0)，" }.joined(),
                title: nil
            )],
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        let overCapacity = SemanticBlockSegmenter.refine(
            [SemanticLogicalBlock(
                sourceIndex: 0,
                text: (1...(SemanticBlockSegmenter.maximumWorkbenchSegments + 1))
                    .map { "u\($0)，" }.joined(),
                title: nil
            )],
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        let oldTextByKey = Dictionary(uniqueKeysWithValues: atCapacity.map {
            ($0.key, $0.text)
        })
        guard overCapacity.allSatisfy({ fragment in
            oldTextByKey[fragment.key].map { fragment.text.hasPrefix($0) } ?? true
        }) else { return false }
        let partial = AITextPartialJSONBlocks.decode(
            "{\"blocks\":[{\"text\":\"首块\\n正在生"
        )
        guard partial.count == 1,
              partial[0].index == 0,
              partial[0].text == "首块\n正在生" else { return false }
        let twoPartial = AITextPartialJSONBlocks.decode(
            "{\"blocks\":[{\"text\":\"第一块\"},{\"text\":\"第二"
        )
        guard twoPartial.map(\.text) == ["第一块", "第二"] else { return false }

        let alternatives = """
        {"blocks":[{"text":"修复一个问题。不要拆分。","title":"ignored"},{"text":"修复仪表问题。","title":null},{"text":"修复一格问题。","title":null}]}
        """
        guard let guesses = try? AITextResultDecoder
            .decodeAlternativeGuesses(alternatives),
              guesses.map(\.index) == [0, 1, 2],
              guesses.map(\.text) == [
                "修复一个问题。不要拆分。",
                "修复仪表问题。",
                "修复一格问题。",
              ],
              guesses.allSatisfy({ $0.title == nil }),
              (try? AITextResultDecoder.decodeAlternativeGuesses(
                """
                {"blocks":[{"text":"一","title":null},{"text":"二","title":null},{"text":"三","title":null},{"text":"四","title":null}]}
                """
              )) == nil,
              (try? AITextResultDecoder.decodeAlternativeGuesses("plain text")) == nil else {
            return false
        }
        guard let uppercaseFencedGuesses = try? AITextResultDecoder
            .decodeAlternativeGuesses("```JSON\n\(alternatives)\n```"),
              uppercaseFencedGuesses == guesses else { return false }
        let alternativePartial = AITextProviderStreamingOutput.blocks(
            from: "{\"blocks\":[{\"text\":\"第一句，第二",
            outputContract: .alternativeGuesses
        )
        guard alternativePartial.count == 1,
              alternativePartial.first?.text == "第一句，第二" else { return false }
        let uppercaseFencedPartial = AITextProviderStreamingOutput.blocks(
            from: "```JSON\n{\"blocks\":[{\"text\":\"大写围栏也能流式",
            outputContract: .alternativeGuesses
        )
        guard uppercaseFencedPartial.count == 1,
              uppercaseFencedPartial.first?.text == "大写围栏也能流式" else {
            return false
        }
        return (try? AITextResultDecoder.decodeFinalText("   ")) == nil
    }

    private static func streamParsers() -> Bool {
        let codexObject: [String: Any] = [
            "type": "item.completed",
            "item": [
                "type": "agent_message",
                "text": "{\"blocks\":[{\"text\":\"codex result\"}]}",
            ],
        ]
        guard let codexLine = try? JSONSerialization.data(withJSONObject: codexObject) else {
            return false
        }
        var codex = AITextCodexJSONStreamParser()
        let split = max(1, codexLine.count / 2)
        guard (try? codex.append(Data(codexLine[..<split])))?.isEmpty == true else {
            return false
        }
        var secondHalf = Data(codexLine[split...])
        secondHalf.append(0x0A)
        guard let snapshots = try? codex.append(secondHalf),
              snapshots.last == "{\"blocks\":[{\"text\":\"codex result\"}]}" else {
            return false
        }

        let claudeDelta: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "text_delta", "text": "partial"],
            ],
        ]
        let claudeResultText = "{\"blocks\":[{\"text\":\"claude result\",\"title\":null}]}"
        let claudeResult: [String: Any] = [
            "type": "result",
            "result": claudeResultText,
        ]
        let claudeThinking: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_delta",
                "delta": ["type": "thinking_delta", "thinking": "must stay private"],
            ],
        ]
        guard let deltaData = try? JSONSerialization.data(withJSONObject: claudeDelta),
              let thinkingData = try? JSONSerialization.data(withJSONObject: claudeThinking),
              let resultData = try? JSONSerialization.data(withJSONObject: claudeResult) else {
            return false
        }
        var claude = AITextClaudeJSONStreamParser()
        var fixture = Data()
        fixture.append(deltaData)
        fixture.append(0x0A)
        fixture.append(thinkingData)
        fixture.append(0x0A)
        fixture.append(resultData)
        fixture.append(0x0A)
        guard let claudeBatch = try? claude.append(fixture),
              claudeBatch.snapshots == ["partial"],
              claudeBatch.activities.contains(where: { $0.kind == .composing }),
              claudeBatch.activities.contains(where: { $0.kind == .reasoning }),
              !claudeBatch.snapshots.contains(where: { $0.contains("must stay private") }),
              let final = claude.finalText,
              let finalBlocks = try? AITextResultDecoder.decodeFinalText(final),
              finalBlocks.first?.text == "claude result" else { return false }

        let allowedRate: [String: Any] = [
            "type": "rate_limit_event",
            "rate_limit_info": ["status": "allowed"],
        ]
        let warningRate: [String: Any] = [
            "type": "rate_limit_event",
            "rate_limit_info": ["status": "allowed_warning"],
        ]
        guard let allowedRateData = try? JSONSerialization.data(withJSONObject: allowedRate),
              let warningRateData = try? JSONSerialization.data(withJSONObject: warningRate) else {
            return false
        }
        var rateFixture = Data()
        rateFixture.append(allowedRateData)
        rateFixture.append(0x0A)
        rateFixture.append(warningRateData)
        rateFixture.append(0x0A)
        var rateParser = AITextClaudeJSONStreamParser()
        guard let rateBatch = try? rateParser.append(rateFixture),
              rateBatch.activities.count == 1,
              rateBatch.activities.first?.message == "Claude Code 接近用量限制" else {
            return false
        }

        let forbiddenTool: [String: Any] = [
            "type": "stream_event",
            "event": [
                "type": "content_block_start",
                "content_block": ["type": "server_tool_use"],
            ],
        ]
        guard var forbiddenData = try? JSONSerialization.data(withJSONObject: forbiddenTool) else {
            return false
        }
        forbiddenData.append(0x0A)
        var forbiddenParser = AITextClaudeJSONStreamParser()
        do {
            _ = try forbiddenParser.append(forbiddenData)
            return false
        } catch {}

        let eventOne = "data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n"
        let eventTwo = "data: {\"choices\":[{\"delta\":{\"content\":\" two\"}}]}\r\n\r\n"
        let bytes = Data((eventOne + eventTwo).utf8)
        var sse = AITextSSEDecoder()
        let boundary = bytes.count / 3
        guard (try? sse.append(Data(bytes[..<boundary])))?.isEmpty == true,
              let payloads = try? sse.append(Data(bytes[boundary...])),
              payloads.count == 2,
              (try? AITextOpenAIResponseDecoder.streamDelta(from: payloads[0])) == "one",
              (try? AITextOpenAIResponseDecoder.streamDelta(from: payloads[1])) == " two" else {
            return false
        }
        let unfinishedPayload = "{\"choices\":[{\"delta\":{\"content\":\"x\"},\"finish_reason\":null}]}"
        let finishedPayload = "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
        guard let unfinished = try? AITextOpenAIResponseDecoder.streamUpdate(
            from: unfinishedPayload
        ),
        unfinished.contentDelta == "x",
        !unfinished.finished,
        (try? AITextOpenAIResponseDecoder.streamUpdate(from: finishedPayload))?.finished == true else {
            return false
        }

        // Feed a complete Chinese alternative stream one byte at a time. This
        // deterministically cuts through UTF-8 scalars, JSON payloads, CRLF
        // frame boundaries, and the protocol terminator without a real API.
        let alternativeDeltas = [
            "{\"blocks\":[{\"text\":\"我想修",
            "复这个分词问题。\",\"title\":null},{\"text\":\"另一",
            "种理解。\",\"title\":null}]}",
        ]
        var alternativeWire = Data()
        for delta in alternativeDeltas {
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "choices": [["delta": ["content": delta]]],
            ]), let payload = String(data: data, encoding: .utf8) else {
                return false
            }
            alternativeWire.append(Data("data: \(payload)\r\n\r\n".utf8))
        }
        alternativeWire.append(Data("data: [DONE]\r\n\r\n".utf8))
        guard alternativeWire.range(of: Data("我".utf8)) != nil else { return false }

        var bytewiseSSE = AITextSSEDecoder()
        var bytewisePayloads: [String] = []
        for byte in alternativeWire {
            guard let decoded = try? bytewiseSSE.append(Data([byte])) else {
                return false
            }
            bytewisePayloads.append(contentsOf: decoded)
        }
        guard bytewisePayloads.count == alternativeDeltas.count + 1,
              bytewisePayloads.last == "[DONE]" else { return false }

        var cumulativeAlternative = ""
        var alternativeSnapshots: [[AITextProviderBlock]] = []
        for payload in bytewisePayloads.dropLast() {
            guard let delta = try? AITextOpenAIResponseDecoder.streamDelta(
                from: payload
            ) else { return false }
            cumulativeAlternative += delta
            alternativeSnapshots.append(AITextProviderStreamingOutput.blocks(
                from: cumulativeAlternative,
                outputContract: .alternativeGuesses
            ))
        }
        guard alternativeSnapshots.count == 3,
              alternativeSnapshots[0].map(\.text) == ["我想修"],
              alternativeSnapshots[1].map(\.text)
                == ["我想修复这个分词问题。", "另一"],
              alternativeSnapshots[2].map(\.text)
                == ["我想修复这个分词问题。", "另一种理解。"] else {
            return false
        }
        return true
    }

    private static func fakeCLIRunners() -> Bool {
        let fakeExecutable = URL(fileURLWithPath: "/usr/bin/true")
        if let realCodexPath = ProcessInfo.processInfo.environment[
            "RIMEBUFFER_CODEX_CAPABILITY_SMOKE_PATH"
        ], !realCodexPath.isEmpty {
            let realCodexURL = URL(fileURLWithPath: realCodexPath)
            guard AITextCodexCompatibility.isSupported(
                executableURL: realCodexURL,
                environment: ProcessInfo.processInfo.environment
            ) else {
                print("AI text CLI smoke failed: real Codex capability probe")
                return false
            }
        }
        if let realClaudePath = ProcessInfo.processInfo.environment[
            "RIMEBUFFER_CLAUDE_CAPABILITY_SMOKE_PATH"
        ], !realClaudePath.isEmpty {
            let realClaudeURL = URL(fileURLWithPath: realClaudePath)
            guard AITextClaudeCompatibility.isSupported(
                executableURL: realClaudeURL,
                environment: ProcessInfo.processInfo.environment
            ) else {
                print("AI text CLI smoke failed: real Claude capability probe")
                return false
            }
        }
        let codexWorkspace = URL(fileURLWithPath: "/tmp/rime-codex-app-server-smoke")
        let codexArguments = CodexCLITextProvider.appServerArguments(
            workspaceURL: codexWorkspace
        )
        let codexEnvironment = AITextCLIExecutableLocator.sanitizedEnvironment(
            for: .codexCLI,
            from: [
                "HOME": "/tmp",
                "CODEX_HOME": "/tmp/codex",
                "OPENAI_API_KEY": "must-not-leak",
                "CODEX_API_KEY": "must-not-leak",
                "ANTHROPIC_API_KEY": "must-not-leak",
            ]
        )
        let codexCandidates = AITextCLIExecutableLocator.candidatePaths(
            for: .codexCLI,
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
            homeDirectory: "/Users/smoke"
        )
        let rejectedCandidate = URL(fileURLWithPath: "/usr/bin/false")
        let acceptedCandidate = URL(fileURLWithPath: "/usr/bin/true")
        let compatibleFallback = AITextCLIExecutableLocator.firstCompatibleExecutable(
            in: [rejectedCandidate, acceptedCandidate],
            compatibility: { $0 == acceptedCandidate }
        )
        let invalidPinnedExecutable = AITextCLIExecutableLocator.compatibleExecutable(
            for: .codexCLI,
            environment: ["RIMEBUFFER_CODEX_PATH": "/tmp/rimebuffer-missing-codex"],
            compatibility: { _ in true }
        )
        let locatorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-CLI-Locator-Smoke-\(UUID().uuidString)",
                                   isDirectory: true)
        defer { try? FileManager.default.removeItem(at: locatorRoot) }
        let pinnedSymlink = locatorRoot.appendingPathComponent("codex")
        let nvm9Root = locatorRoot.appendingPathComponent(
            ".nvm/versions/node/v9.0.0",
            isDirectory: true
        )
        let nvm22Root = locatorRoot.appendingPathComponent(
            ".nvm/versions/node/v22.1.0",
            isDirectory: true
        )
        let cursorExtensionRoot = locatorRoot.appendingPathComponent(
            ".cursor/extensions/openai.chatgpt-0.999.0",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: locatorRoot,
                                                    withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: nvm9Root,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: nvm22Root,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: cursorExtensionRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: pinnedSymlink,
                                                       withDestinationURL: acceptedCandidate)
        } catch {
            return false
        }
        let managedCodexPaths = AITextCLIExecutableLocator.discoveredManagedInstallPaths(
            for: .codexCLI,
            homeDirectory: locatorRoot.path,
            fileManager: .default
        )
        let nvm9Candidate = nvm9Root.appendingPathComponent("bin/codex").path
        let nvm22Candidate = nvm22Root.appendingPathComponent("bin/codex").path
        #if arch(arm64)
        let cursorPlatform = "macos-aarch64"
        #else
        let cursorPlatform = "macos-x86_64"
        #endif
        let cursorCandidate = cursorExtensionRoot
            .appendingPathComponent("bin/\(cursorPlatform)/codex")
            .path
        let managedRuntimeEnvironment = AITextCLIExecutableLocator.sanitizedEnvironment(
            for: .codexCLI,
            executableURL: URL(fileURLWithPath: nvm22Candidate),
            from: ["HOME": locatorRoot.path]
        )
        func makeCodexCapabilityExecutable(
            name: String,
            initializeResult: String = #"{"id":1,"result":{"userAgent":"smoke"}}"#,
            mcpResult: String = #"{"id":2,"result":{"data":[],"nextCursor":null}}"#,
            responds: Bool = true,
            floodsOutput: Bool = false
        ) -> URL? {
            let executable = locatorRoot.appendingPathComponent(name)
            let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              exit 64
            fi
            if [ "$1" != "app-server" ]; then
              exit 64
            fi
            if [ "\(floodsOutput ? "1" : "0")" = "1" ]; then
              /usr/bin/yes '{"method":"capability/notice"}' | /usr/bin/head -c 300000
              /bin/sleep 5
              exit 0
            fi
            if [ "\(responds ? "1" : "0")" != "1" ]; then
              while IFS= read -r line; do :; done
              exit 0
            fi
            seen_initialize=0
            while IFS= read -r line; do
              case "$line" in
                *mcpServerStatus*)
                  printf '%s\\n' '\(mcpResult)'
                  ;;
                *initialize*)
                  if [ "$seen_initialize" = "0" ]; then
                    seen_initialize=1
                    printf '%s\\n' '\(initializeResult)'
                  fi
                  ;;
              esac
            done
            """
            do {
                try Data(script.utf8).write(to: executable, options: .atomic)
                guard chmod(executable.path, S_IRWXU) == 0 else { return nil }
                return executable
            } catch {
                return nil
            }
        }
        func makeClaudeCapabilityExecutable(name: String) -> URL? {
            let executable = locatorRoot.appendingPathComponent(name)
            let options = [
                "--print", "--verbose", "--output-format",
                "--include-partial-messages", "--tools",
                "--disable-slash-commands", "--safe-mode", "--strict-mcp-config",
                "--no-session-persistence", "--permission-mode", "--no-chrome",
            ].joined(separator: "\n")
            let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              exit 64
            fi
            if [ "$1" = "--help" ]; then
              printf '%s\\n' '\(options)'
              exit 0
            fi
            exit 64
            """
            do {
                try Data(script.utf8).write(to: executable, options: .atomic)
                guard chmod(executable.path, S_IRWXU) == 0 else { return nil }
                return executable
            } catch {
                return nil
            }
        }
        func makeBunManagedCodexExecutable() -> URL? {
            let bunBin = locatorRoot.appendingPathComponent(
                ".bun/bin",
                isDirectory: true
            )
            let targetDirectory = locatorRoot.appendingPathComponent(
                ".bun/install/global/node_modules/@openai/codex/bin",
                isDirectory: true
            )
            let bunRuntime = bunBin.appendingPathComponent("bun")
            let target = targetDirectory.appendingPathComponent("codex.js")
            let link = bunBin.appendingPathComponent("codex")
            let runtimeScript = """
            #!/bin/sh
            exec /bin/sh "$@"
            """
            let codexScript = """
            #!/usr/bin/env bun
            if [ "$1" != "app-server" ]; then
              exit 64
            fi
            seen_initialize=0
            while IFS= read -r line; do
              case "$line" in
                *mcpServerStatus*)
                  printf '%s\\n' '{"id":2,"result":{"data":[],"nextCursor":null}}'
                  ;;
                *initialize*)
                  if [ "$seen_initialize" = "0" ]; then
                    seen_initialize=1
                    printf '%s\\n' '{"id":1,"result":{"userAgent":"bun-smoke"}}'
                  fi
                  ;;
              esac
            done
            """
            do {
                try FileManager.default.createDirectory(
                    at: bunBin,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createDirectory(
                    at: targetDirectory,
                    withIntermediateDirectories: true
                )
                try Data(runtimeScript.utf8).write(to: bunRuntime, options: .atomic)
                try Data(codexScript.utf8).write(to: target, options: .atomic)
                guard chmod(bunRuntime.path, S_IRWXU) == 0,
                      chmod(target.path, S_IRWXU) == 0 else {
                    return nil
                }
                try FileManager.default.createSymbolicLink(
                    at: link,
                    withDestinationURL: target
                )
                return link
            } catch {
                return nil
            }
        }
        guard let futureCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-future"
        ),
        let versionlessCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-without-version-command"
        ),
        let failedProtocolCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-bad-protocol",
            initializeResult: #"{"id":1,"error":{"message":"unsupported"}}"#
        ),
        let unsafeMCPCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-unsafe-mcp",
            mcpResult: #"{"id":2,"result":{"data":[{"name":"unsafe"}],"nextCursor":null}}"#
        ),
        let timeoutCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-timeout",
            responds: false
        ),
        let outputFloodCodexExecutable = makeCodexCapabilityExecutable(
            name: "codex-output-flood",
            floodsOutput: true
        ),
        let futureClaudeExecutable = makeClaudeCapabilityExecutable(
            name: "claude-future"
        ),
        let bunManagedCodexExecutable = makeBunManagedCodexExecutable() else {
            return false
        }
        var compatibilitySawCanonicalURL = false
        let canonicalPinnedExecutable = AITextCLIExecutableLocator.compatibleExecutable(
            for: .codexCLI,
            environment: ["RIMEBUFFER_CODEX_PATH": pinnedSymlink.path],
            compatibility: { candidate in
                compatibilitySawCanonicalURL = candidate == acceptedCandidate.resolvingSymlinksInPath()
                return true
            }
        )
        let futureCodexSupported = AITextCodexCompatibility.isSupported(
            executableURL: futureCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let versionlessCodexSupported = AITextCodexCompatibility.isSupported(
            executableURL: versionlessCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let failedProtocolCodexRejected = !AITextCodexCompatibility.isSupported(
            executableURL: failedProtocolCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let unsafeMCPCodexRejected = !AITextCodexCompatibility.isSupported(
            executableURL: unsafeMCPCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let timeoutCodexRejected = !AITextCodexCompatibility.isSupported(
            executableURL: timeoutCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let outputFloodCodexRejected = !AITextCodexCompatibility.isSupported(
            executableURL: outputFloodCodexExecutable,
            environment: ["HOME": "/tmp"]
        )
        let bunManagedCodexSupported = AITextCodexCompatibility.isSupported(
            executableURL: bunManagedCodexExecutable,
            environment: ["HOME": locatorRoot.path]
        )
        let futureClaudeSupported = AITextClaudeCompatibility.isSupported(
            executableURL: futureClaudeExecutable,
            environment: ["HOME": "/tmp"]
        )
        guard futureCodexSupported,
              versionlessCodexSupported,
              failedProtocolCodexRejected,
              unsafeMCPCodexRejected,
              timeoutCodexRejected,
              outputFloodCodexRejected,
              bunManagedCodexSupported,
              futureClaudeSupported else {
            print(
                "AI text CLI smoke failed: capability matrix "
                    + "codex=\(futureCodexSupported) "
                    + "noVersion=\(versionlessCodexSupported) "
                    + "protocol=\(failedProtocolCodexRejected) "
                    + "mcp=\(unsafeMCPCodexRejected) "
                    + "timeout=\(timeoutCodexRejected) "
                    + "flood=\(outputFloodCodexRejected) "
                    + "bun=\(bunManagedCodexSupported) "
                    + "claude=\(futureClaudeSupported)"
            )
            return false
        }
        guard codexArguments.first == "app-server",
              codexArguments.suffix(2) == ["--listen", "stdio://"],
              codexArguments.contains("--strict-config"),
              codexArguments.contains("default_permissions=\"rimebuffer\""),
              !codexArguments.contains("--sandbox"),
              codexArguments.contains("permissions.rimebuffer.network.enabled=false"),
              codexArguments.contains("tools.experimental_request_user_input={enabled=false}"),
              codexArguments.contains("web_search=\"disabled\""),
              codexArguments.contains(where: {
                  $0.hasPrefix("permissions.rimebuffer.filesystem=")
                      && $0.contains(codexWorkspace.path)
              }),
              codexEnvironment["OPENAI_API_KEY"] == nil,
              codexEnvironment["CODEX_API_KEY"] == nil,
              codexEnvironment["CODEX_HOME"] == nil,
              codexEnvironment["ANTHROPIC_API_KEY"] == nil,
              codexCandidates.first == AITextCLIExecutableLocator.bundledChatGPTCodexPath,
              codexCandidates.contains("/Users/smoke/.volta/bin/codex"),
              codexCandidates.contains("/Users/smoke/.asdf/shims/codex"),
              codexCandidates.contains("/Users/smoke/.local/share/mise/shims/codex"),
              codexCandidates.contains("/Users/smoke/.bun/bin/codex"),
              codexCandidates.contains("/Users/smoke/.npm-global/bin/codex"),
              codexCandidates.contains("/Users/smoke/Library/pnpm/codex"),
              (managedCodexPaths.firstIndex(of: nvm22Candidate) ?? Int.max)
                < (managedCodexPaths.firstIndex(of: nvm9Candidate) ?? Int.max),
              managedCodexPaths.contains(cursorCandidate),
              managedRuntimeEnvironment["PATH"]?.hasPrefix(
                nvm22Root.appendingPathComponent("bin").path + ":"
              ) == true,
              compatibleFallback == acceptedCandidate,
              invalidPinnedExecutable == nil,
              compatibilitySawCanonicalURL,
              canonicalPinnedExecutable == acceptedCandidate.resolvingSymlinksInPath(),
              (codexCandidates.firstIndex(
                of: AITextCLIExecutableLocator.bundledChatGPTCodexPath
              ) ?? Int.max)
                < (codexCandidates.firstIndex(of: "/opt/homebrew/bin/codex") ?? Int.max),
              AITextClaudeCompatibility.helpAdvertisesOption(
                "--print",
                in: "  -p, --print <prompt>  Print a response"
              ),
              !AITextClaudeCompatibility.helpAdvertisesOption(
                "--print",
                in: "  --other  Compatibility note mentioning --print"
              )
              else {
            print("AI text CLI smoke failed: capability/isolation invariants")
            return false
        }

        let ordinaryFutureCodex = CodexCLITextProvider(
            environment: ["HOME": "/tmp"],
            homeStore: AITextCodexHomeStore(
                rootDirectory: locatorRoot.appendingPathComponent("ordinary-future-home")
            ),
            executableResolver: { futureCodexExecutable }
        )
        guard waitUntil(timeout: 2, {
            if case let .unavailable(message) = ordinaryFutureCodex.availability {
                return message.contains("尚未完成")
            }
            return false
        }) else { return false }

        let streamFutureCodex = CodexCLITextProvider(
            environment: ["HOME": "/tmp"],
            homeStore: AITextCodexHomeStore(
                rootDirectory: locatorRoot.appendingPathComponent("stream-future-home")
            ),
            inferenceProfile: .streamInput,
            executableResolver: { futureCodexExecutable }
        )
        guard waitUntil(timeout: 2, {
            if case let .unavailable(message) = streamFutureCodex.availability {
                return message.contains("尚未完成")
            }
            return false
        }) else { return false }

        guard AITextFoundationCLIStreamingSmoke.run() else {
            print("AI text CLI smoke failed: process streaming")
            return false
        }
        guard AITextCodexAppServerProtocolSmoke.run() else {
            print("AI text CLI smoke failed: Codex app-server protocol")
            return false
        }
        guard AITextCodexLoginProtocolSmoke.run() else {
            print("AI text CLI smoke failed: Codex login protocol")
            return false
        }
        guard AITextCodexLoginTransportSmoke.run() else {
            print("AI text CLI smoke failed: Codex login transport")
            return false
        }
        guard AITextClaudeLoginTransportSmoke.run() else {
            print("AI text CLI smoke failed: Claude login transport")
            return false
        }
        let codexHomeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-Codex-Home-Smoke-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHomeRoot) }
        let codexHome = AITextCodexHomeStore(rootDirectory: codexHomeRoot)
        do {
            try codexHome.prepare()
            guard let config = try? String(contentsOf: codexHome.configurationURL,
                                           encoding: .utf8),
                  config.contains("forced_login_method = \"chatgpt\""),
                  config.contains("[mcp_servers]"),
                  !config.contains("[mcp_servers.") else { return false }
            let codexProbeGate = DispatchSemaphore(value: 0)
            let nonblockingCodex = CodexCLITextProvider(
                environment: ["HOME": "/tmp"],
                homeStore: codexHome,
                executableResolver: { fakeExecutable },
                compatibilityResolver: { _ in
                    codexProbeGate.wait()
                    return true
                }
            )
            let codexProbeStartedAt = ProcessInfo.processInfo.systemUptime
            let initialCodexAvailability = nonblockingCodex.availability
            let codexProbeCallDuration = ProcessInfo.processInfo.systemUptime
                - codexProbeStartedAt
            guard case let .unavailable(codexProbeMessage) = initialCodexAvailability,
                  codexProbeMessage.contains("正在检查"),
                  codexProbeCallDuration < 0.1 else {
                codexProbeGate.signal()
                return false
            }
            codexProbeGate.signal()
            guard waitUntil(timeout: 2, {
                if case let .unavailable(message) = nonblockingCodex.availability {
                    return message.contains("尚未完成")
                }
                return false
            }) else { return false }

            let codexCompatibilityChecks = AITextSmokeCounter()
            let refreshableCodex = CodexCLITextProvider(
                environment: ["HOME": "/tmp"],
                homeStore: codexHome,
                executableResolver: { fakeExecutable },
                compatibilityResolver: { _ in
                    codexCompatibilityChecks.increment()
                    return true
                }
            )
            guard case .unavailable = refreshableCodex.availability,
                  waitUntil(timeout: 2, { codexCompatibilityChecks.value == 1 }) else {
                return false
            }
            let auth: [String: Any] = [
                "auth_mode": "chatgpt",
                "tokens": ["access_token": "access", "refresh_token": "refresh"],
            ]
            let authData = try JSONSerialization.data(withJSONObject: auth)
            try authData.write(to: codexHome.authenticationURL, options: .atomic)
            guard chmod(codexHome.authenticationURL.path, S_IRUSR | S_IWUSR) == 0,
                  codexHome.hasChatGPTCredential,
                  waitUntil(timeout: 2, { refreshableCodex.availability == .ready }) else {
                return false
            }
        } catch {
            return false
        }
        let unsupportedCodex = CodexCLITextProvider(
            environment: ["HOME": "/tmp"],
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in false }
        )
        guard case .unavailable = unsupportedCodex.availability else { return false }
        var unsupportedResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = unsupportedCodex.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must-not-send"),
            onEvent: { _ in },
            completion: { unsupportedResult = $0 }
        )
        guard case .failure(.unavailable)? = unsupportedResult else { return false }

        let unsupportedStreamCodex = CodexCLITextProvider(
            environment: ["HOME": "/tmp"],
            inferenceProfile: .streamInput,
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in false }
        )
        guard waitUntil(timeout: 2, {
            if case let .unavailable(message) = unsupportedStreamCodex.availability {
                return message.contains("app-server 握手检查")
            }
            return false
        }) else { return false }
        var unsupportedStreamResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = unsupportedStreamCodex.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must-not-send-stream"),
            onEvent: { _ in },
            completion: { unsupportedStreamResult = $0 }
        )
        guard case let .failure(.unavailable(message))? = unsupportedStreamResult,
              message.contains("app-server 握手检查") else { return false }

        let authenticationGate = DispatchSemaphore(value: 0)
        let nonblockingClaude = ClaudeCodeCLITextProvider(
            environment: ["HOME": "/tmp"],
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in true },
            authenticationResolver: { _ in
                authenticationGate.wait()
                return true
            }
        )
        let probeStartedAt = ProcessInfo.processInfo.systemUptime
        let initialClaudeAvailability = nonblockingClaude.availability
        let probeCallDuration = ProcessInfo.processInfo.systemUptime - probeStartedAt
        guard case let .unavailable(probeMessage) = initialClaudeAvailability,
              probeMessage.contains("正在检查"),
              probeCallDuration < 0.1 else {
            authenticationGate.signal()
            return false
        }
        authenticationGate.signal()
        guard waitUntil(timeout: 2, { nonblockingClaude.availability == .ready }) else {
            return false
        }

        let claudeRunner = AITextSmokeRunner()
        let claude = ClaudeCodeCLITextProvider(runner: claudeRunner,
                                               environment: [
                                                   "HOME": "/tmp",
                                                   "CLAUDE_CONFIG_DIR": "/tmp/claude",
                                                   "ANTHROPIC_API_KEY": "anthropic-only",
                                                   "CLAUDE_CODE_OAUTH_TOKEN": "claude-only",
                                                   "OPENAI_API_KEY": "must-not-leak",
                                                   "CODEX_HOME": "/tmp/codex-must-not-leak",
                                               ],
                                               executableResolver: { fakeExecutable },
                                               compatibilityResolver: { _ in true },
                                               authenticationResolver: { _ in true })
        guard waitUntil(timeout: 2, { claude.availability == .ready }) else {
            return false
        }
        var claudeResultValue: Result<[AITextProviderBlock], AITextProviderError>?
        _ = claude.generate(AITextProviderRequest(requestID: UUID(), sourceText: "claude-source"),
                            onEvent: { _ in },
                            completion: { claudeResultValue = $0 })
        guard claudeRunner.specs.count == 1,
              !claudeRunner.specs[0].arguments.contains(where: { $0.contains("claude-source") }),
              String(data: claudeRunner.specs[0].standardInput, encoding: .utf8)?.contains("claude-source") == true,
              claudeRunner.specs[0].arguments.contains("--print"),
              claudeRunner.specs[0].arguments.contains("--verbose"),
              claudeRunner.specs[0].arguments.contains("--strict-mcp-config"),
              !claudeRunner.specs[0].arguments.contains("--json-schema"),
              claudeRunner.specs[0].arguments.contains("--no-chrome"),
              claudeRunner.specs[0].environment["ANTHROPIC_API_KEY"] == nil,
              claudeRunner.specs[0].environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil,
              claudeRunner.specs[0].environment["CLAUDE_CONFIG_DIR"] == nil,
              claudeRunner.specs[0].environment["TMPDIR"] == claudeRunner.specs[0].currentDirectoryURL.path,
              claudeRunner.specs[0].environment["OPENAI_API_KEY"] == nil,
              claudeRunner.specs[0].environment["CODEX_HOME"] == nil else {
            return false
        }
        let claudeObject: [String: Any] = [
            "type": "result",
            "result": "{\"blocks\":[{\"text\":\"claude ok\",\"title\":null}]}",
        ]
        guard var claudeData = try? JSONSerialization.data(withJSONObject: claudeObject) else {
            return false
        }
        claudeData.append(0x0A)
        claudeRunner.succeed(request: 0, chunks: [claudeData])
        guard case let .success(blocks)? = claudeResultValue,
              blocks.first?.text == "claude ok" else { return false }
        var preparedClaudeResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = claude.generate(
            AITextProviderRequest(
                requestID: UUID(),
                sourceText: "must-not-be-wrapped",
                preparedPrompt: "prepared-claude-prompt"
            ),
            onEvent: { _ in },
            completion: { preparedClaudeResult = $0 }
        )
        guard claudeRunner.specs.count == 2,
              String(data: claudeRunner.specs[1].standardInput, encoding: .utf8)
                == "prepared-claude-prompt" else { return false }
        claudeRunner.succeed(request: 1, chunks: [claudeData])
        guard case .success? = preparedClaudeResult,
              AITextCLIExecutableLocator.bundledChatGPTCodexPath
                == "/Applications/ChatGPT.app/Contents/Resources/codex",
              AITextCodexLoginPresentation.buttonTitle(
                isRunning: false,
                hasCredential: true
              ) == "重新授权 Codex",
              AITextCodexLoginPresentation.buttonTitle(
                isRunning: false,
                hasCredential: false
              ) == "登录 Codex",
              AITextCodexLoginPresentation.buttonTitle(
                isRunning: true,
                hasCredential: true
              ) == "取消登录",
              AITextCodexLoginPresentation.idleMessage(
                hasCredential: true
              ).contains("已保存在"),
              AITextClaudeLoginPresentation.buttonTitle(
                isRunning: false,
                authenticationStatus: true
              ) == "重新授权 Claude",
              AITextClaudeLoginPresentation.buttonTitle(
                isRunning: false,
                authenticationStatus: nil
              ) == "授权 Claude",
              AITextClaudeLoginPresentation.idleMessage(
                authenticationStatus: nil
              ).contains("状态未知")
              else { return false }

        let unsupportedClaudeRunner = AITextSmokeRunner()
        let unsupportedClaude = ClaudeCodeCLITextProvider(
            runner: unsupportedClaudeRunner,
            environment: ["HOME": "/tmp"],
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in false }
        )
        guard case .unavailable = unsupportedClaude.availability else { return false }
        var unsupportedClaudeResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = unsupportedClaude.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must-not-send"),
            onEvent: { _ in },
            completion: { unsupportedClaudeResult = $0 }
        )
        guard unsupportedClaudeRunner.specs.isEmpty,
              case .failure(.unavailable)? = unsupportedClaudeResult else { return false }

        let signedOutClaudeRunner = AITextSmokeRunner()
        let signedOutAuthenticationChecks = AITextSmokeCounter()
        let signedOutClaude = ClaudeCodeCLITextProvider(
            runner: signedOutClaudeRunner,
            environment: ["HOME": "/tmp"],
            executableResolver: { fakeExecutable },
            compatibilityResolver: { _ in true },
            authenticationResolver: { _ in
                signedOutAuthenticationChecks.increment()
                return false
            }
        )
        guard waitUntil(timeout: 2, {
                  if case .unavailable = signedOutClaude.availability {
                      return signedOutAuthenticationChecks.value == 1
                  }
                  return false
              }),
              case .unavailable = signedOutClaude.availability,
              case .unavailable = signedOutClaude.availability,
              signedOutAuthenticationChecks.value == 1 else { return false }
        var signedOutClaudeResult: Result<[AITextProviderBlock], AITextProviderError>?
        _ = signedOutClaude.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must-not-send"),
            onEvent: { _ in },
            completion: { signedOutClaudeResult = $0 }
        )
        guard signedOutClaudeRunner.specs.isEmpty,
              case .failure(.unavailable)? = signedOutClaudeResult,
              signedOutAuthenticationChecks.value == 1 else { return false }
        signedOutClaude.authenticationDidChange(true)
        guard signedOutClaude.availability == .ready,
              signedOutAuthenticationChecks.value == 1 else { return false }
        return true
    }

    private static func configurationStorageAndRequest() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-AI-Smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenAICompatibleConfigurationStore(rootDirectory: root)
        var configurationChangeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .openAICompatibleConfigurationDidChange,
            object: store,
            queue: nil
        ) { _ in
            configurationChangeCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let configuration = OpenAICompatibleConfiguration(baseURL: "https://example.com/v1/",
                                                           model: "example-model",
                                                           apiKey: "secret-value")
        do {
            try store.save(configuration)
            let reloadedStore = OpenAICompatibleConfigurationStore(rootDirectory: root)
            guard try store.load() == configuration,
                  try reloadedStore.load() == configuration,
                  configurationChangeCount == 1 else { return false }
        } catch {
            return false
        }
        var info = stat()
        guard lstat(store.configurationURL.path, &info) == 0,
              (info.st_mode & 0o777) == 0o600 else { return false }
        guard let endpoint = try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "https://example.com/v1/"
        ), endpoint.absoluteString == "https://example.com/v1/chat/completions" else {
            return false
        }
        guard (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "http://example.com/v1"
        )) == nil,
        (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "http://127.0.0.1:8080/v1"
        )) != nil,
        (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "https://apidoc.cometapi.com/v1"
        )) == nil,
        (try? OpenAICompatibleEndpoint.chatCompletionsURL(
            from: "https://user:password@example.com/v1"
        )) == nil else { return false }

        guard let request = try? AITextOpenAIRequestBuilder.makeRequest(
            configuration: configuration,
            sourceText: "request-source"
        ),
        request.url == endpoint,
        request.httpMethod == "POST",
        request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value",
        let body = request.httpBody,
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        object["model"] as? String == "example-model",
        object["stream"] as? Bool == true,
        object["temperature"] == nil,
        object["thinking"] == nil,
        object["response_format"] == nil,
        object["max_tokens"] == nil else { return false }

        guard let preparedRequest = try? AITextOpenAIRequestBuilder.makeRequest(
            configuration: configuration,
            sourceText: "must-not-be-user-content",
            preparedPrompt: "prepared-openai-prompt"
        ),
        let preparedBody = preparedRequest.httpBody,
        let preparedObject = try? JSONSerialization.jsonObject(with: preparedBody)
            as? [String: Any],
        let messages = preparedObject["messages"] as? [[String: Any]],
        messages.last?["content"] as? String == "prepared-openai-prompt" else {
            return false
        }

        guard let alternativesRequest = try? AITextOpenAIRequestBuilder.makeRequest(
            configuration: configuration,
            sourceText: "continuous-full-pinyin",
            preparedPrompt: "prepared-stream-prompt",
            outputContract: .alternativeGuesses
        ),
        let alternativesBody = alternativesRequest.httpBody,
        !String(decoding: alternativesBody, as: UTF8.self).contains("secret-value"),
        let alternativesObject = try? JSONSerialization.jsonObject(
            with: alternativesBody
        ) as? [String: Any],
        alternativesObject["model"] as? String == "example-model",
        alternativesObject["temperature"] as? Double == 0.2,
        let thinking = alternativesObject["thinking"] as? [String: Any],
        thinking["type"] as? String == "disabled",
        let responseFormat = alternativesObject["response_format"] as? [String: Any],
        responseFormat["type"] as? String == "json_object",
        alternativesObject["max_tokens"] as? Int == 1_024,
        alternativesObject["reasoning_effort"] == nil,
        let alternativesMessages = alternativesObject["messages"] as? [[String: Any]],
        let alternativesSystem = alternativesMessages.first?["content"] as? String,
        alternativesSystem.contains("1 to 3 complete"),
        alternativesSystem.contains("mutually exclusive"),
        alternativesSystem.contains("minimumGuessCount"),
        alternativesMessages.last?["content"] as? String == "prepared-stream-prompt" else {
            return false
        }

        do {
            let legacy = OpenAICompatibleConfiguration(
                baseURL: "https://apidoc.cometapi.com/v1/",
                model: "deepseek-v4-flash",
                apiKey: "legacy-test-only"
            )
            let legacyData = try JSONEncoder().encode(legacy)
            try legacyData.write(to: store.configurationURL, options: .atomic)
            guard chmod(store.configurationURL.path, S_IRUSR | S_IWUSR) == 0,
                  let migrated = try store.load(),
                  migrated.baseURL == "https://api.cometapi.com/v1",
                  migrated.model == legacy.model,
                  migrated.apiKey == legacy.apiKey,
                  configurationChangeCount == 2,
                  try OpenAICompatibleConfigurationStore(rootDirectory: root).load()
                    == migrated else { return false }
        } catch {
            return false
        }

        do {
            try store.delete()
            guard configurationChangeCount == 3 else { return false }
            let target = root.appendingPathComponent("outside")
            try Data("{}".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: store.configurationURL,
                                                       withDestinationURL: target)
            do {
                _ = try store.load()
                return false
            } catch {
                // A symlink must fail closed.
            }
        } catch {
            return false
        }
        return true
    }

    private static func openAIStreamingOperation() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RimeBuffer-OpenAI-Stream-Smoke-\(UUID().uuidString)",
                                    isDirectory: true)
        defer {
            AITextSmokeURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let store = OpenAICompatibleConfigurationStore(rootDirectory: root)
        do {
            try store.save(OpenAICompatibleConfiguration(baseURL: "https://example.com/v1",
                                                         model: "stream-model",
                                                         apiKey: ""))
        } catch {
            return false
        }
        let sessionConfiguration: () -> URLSessionConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AITextSmokeURLProtocol.self]
            return configuration
        }
        let provider = OpenAICompatibleTextProvider(
            configurationStore: store,
            sessionConfigurationFactory: sessionConfiguration
        )

        func payload(_ content: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [
                "choices": [["delta": ["content": content]]],
            ]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let first = payload("{\"blocks\":[{\"text\":\"流"),
              let second = payload("式。\",\"title\":null}]}") else { return false }
        AITextSmokeURLProtocol.install { protocolInstance in
            guard let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            ) else { return }
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didReceive: response,
                                                 cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data("data: \(first)\n\n".utf8))
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data("data: \(second)\n\n".utf8))
            // Deliberately omit didFinishLoading: [DONE] must settle the request
            // even when a compatible server keeps the HTTP body alive.
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data("data: [DONE]\n\n".utf8))
            // Any transport callbacks queued after the protocol terminator
            // must be ignored by the settled operation.
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data("data: {not-json}\n\n".utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let recorder = AITextOpenAISmokeRecorder()
        _ = provider.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "stream source"),
            onEvent: { recorder.record($0) },
            completion: { recorder.record($0) }
        )
        guard runLoopUntil({ !recorder.snapshot().results.isEmpty }) else { return false }
        _ = runLoopUntil(timeout: 0.05) { false }
        let streamed = recorder.snapshot()
        guard streamed.results.count == 1,
              !streamed.eventAfterCompletion,
              case let .success(blocks) = streamed.results[0],
              blocks.map(\.text).joined() == "流式。",
              streamed.events.contains(where: {
                  if case .activity(.init(kind: .composing,
                                         message: "Open API 正在流式返回")) = $0 {
                      return true
                  }
                  return false
              }),
              streamed.events.contains(where: {
                  if case .blockSnapshot = $0 { return true }
                  return false
              }) else { return false }

        guard let alternativesFirst = payload(
            "{\"blocks\":[{\"text\":\"完整第一句。仍是同一个猜测。\",\"title\":null},{\"text\":\"另一"
        ),
        let alternativesSecond = payload("种理解。\",\"title\":null}]}") else {
            return false
        }
        AITextSmokeURLProtocol.install { protocolInstance in
            guard let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            ) else { return }
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didReceive: response,
                                                 cacheStoragePolicy: .notAllowed)
            let frames = "data: \(alternativesFirst)\n\ndata: \(alternativesSecond)\n\ndata: [DONE]\n\n"
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data(frames.utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let alternativesRecorder = AITextOpenAISmokeRecorder()
        _ = provider.generate(
            AITextProviderRequest(
                requestID: UUID(),
                sourceText: "complete stream source",
                preparedPrompt: "complete stream prompt",
                outputContract: .alternativeGuesses
            ),
            onEvent: { alternativesRecorder.record($0) },
            completion: { alternativesRecorder.record($0) }
        )
        guard runLoopUntil({ !alternativesRecorder.snapshot().results.isEmpty }) else {
            return false
        }
        let alternativeStream = alternativesRecorder.snapshot()
        guard alternativeStream.results.count == 1,
              case let .success(alternativeBlocks) = alternativeStream.results[0],
              alternativeBlocks.map(\.text) == [
                "完整第一句。仍是同一个猜测。",
                "另一种理解。",
              ],
              alternativeStream.events.contains(where: {
                guard case let .blockSnapshot(block) = $0 else { return false }
                return block.index == 0
                    && block.text.contains("完整第一句。仍是同一个猜测。")
              }) else { return false }

        AITextSmokeURLProtocol.install { protocolInstance in
            guard let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else { return }
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didReceive: response,
                                                 cacheStoragePolicy: .notAllowed)
        }
        let unsupportedRecorder = AITextOpenAISmokeRecorder()
        _ = provider.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "must stream"),
            onEvent: { _ in },
            completion: { unsupportedRecorder.record($0) }
        )
        guard runLoopUntil({ !unsupportedRecorder.snapshot().results.isEmpty }) else {
            return false
        }
        let unsupported = unsupportedRecorder.snapshot().results
        guard unsupported.count == 1,
              case let .failure(.invalidConfiguration(message)) = unsupported[0],
              message.contains("流式") else { return false }

        let transportReady = DispatchSemaphore(value: 0)
        let releaseTransport = DispatchSemaphore(value: 0)
        AITextSmokeURLProtocol.install { protocolInstance in
            guard let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            ) else { return }
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didReceive: response,
                                                 cacheStoragePolicy: .notAllowed)
            transportReady.signal()
            _ = releaseTransport.wait(timeout: .now() + 1)
            let frames = "data: \(first)\n\ndata: \(second)\n\ndata: [DONE]\n\n"
            protocolInstance.client?.urlProtocol(protocolInstance,
                                                 didLoad: Data(frames.utf8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let raceRecorder = AITextOpenAISmokeRecorder()
        let raceTask = provider.generate(
            AITextProviderRequest(requestID: UUID(), sourceText: "cancel race"),
            onEvent: { raceRecorder.record($0) },
            completion: { raceRecorder.record($0) }
        )
        guard transportReady.wait(timeout: .now() + 1) == .success else { return false }
        let cancelIssued = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            raceTask.cancel()
            cancelIssued.signal()
        }
        releaseTransport.signal()
        guard cancelIssued.wait(timeout: .now() + 1) == .success,
              runLoopUntil({ !raceRecorder.snapshot().results.isEmpty }) else { return false }
        _ = runLoopUntil(timeout: 0.05) { false }
        let raced = raceRecorder.snapshot()
        guard raced.results.count == 1,
              !raced.eventAfterCompletion else { return false }
        return true
    }

    private static func runLoopUntil(timeout: TimeInterval = 1,
                                     _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            _ = RunLoop.main.run(mode: .default,
                                 before: min(deadline, Date().addingTimeInterval(0.01)))
        } while Date() < deadline
        return predicate()
    }

    private static func connectorSelectionAndUnifiedWorkspace() -> Bool {
        let defaultsName = "RimeBuffer.AIConnectorSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else { return false }
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let selection = AITextConnectorSelectionStore(defaults: defaults)
        let codex = AITextSmokeProvider(kind: .codexCLI)
        let claude = AITextSmokeProvider(kind: .claudeCodeCLI)
        let openAI = AITextSmokeProvider(kind: .openAICompatible)
        let registry = AITextConnectorRegistry(
            selectionStore: selection,
            providers: [codex, claude, openAI]
        )
        guard selection.selectedKind == .codexCLI,
              registry.selectedKind == .codexCLI,
              (registry.selectedProvider as? AITextSmokeProvider) === codex,
              registry.provider(for: .openAICompatible)?.kind == .openAICompatible else {
            return false
        }

        let source = BufferModel()
        source.stageExternal("connector-source", origin: .rime)
        let workspace = AITextPluginWorkspace(
            provider: registry,
            sourceModel: source,
            pluginKey: AITextBuiltInPluginID.key,
            isSelected: { true }
        )
        workspace.start()
        defer { workspace.stop() }
        guard workspace.pluginKey == AITextBuiltInPluginID.key,
              workspace.deliveryWorkspaceID == "ai-text",
              workspace.generate(),
              codex.requests.count == 1 else { return false }

        guard registry.select(.claudeCodeCLI),
              codex.cancellations[0].wasCancelled,
              workspace.outputBlocks.isEmpty,
              workspace.kind == .claudeCodeCLI,
              AITextConnectorSelectionStore(defaults: defaults).selectedKind
                == .claudeCodeCLI,
              (registry.selectedProvider as? AITextSmokeProvider) === claude,
              workspace.generate(),
              claude.requests.count == 1 else { return false }
        claude.finish(.success([
            AITextProviderBlock(index: 0, text: "selected connector", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.deliveryPendingBlocks.first?.origin
                == .processor(id: AITextProviderKind.claudeCodeCLI.processorID,
                              allowsRemoteMirror: true),
              AITextProviderError.unavailable("connector detail").localizedDescription
                == "connector detail" else { return false }
        return true
    }

    private static func workspaceGatesAndDelivery() -> Bool {
        let source = BufferModel()
        let provider = AITextSmokeProvider()
        let selection = AITextSmokeSelection()
        let workspace = AITextPluginWorkspace(provider: provider,
                                              sourceModel: source,
                                              isSelected: { selection.selected })
        workspace.start()
        defer { workspace.stop() }
        guard workspace.primaryAction == .disabled,
              !workspace.generate(),
              provider.requests.isEmpty else { return false }
        source.stageExternal("source", origin: .rime)
        guard workspace.canGenerate,
              workspace.primaryAction == .requestGeneration,
              workspace.generate(),
              workspace.primaryAction == .generating,
              provider.requests.count == 1 else {
            return false
        }
        provider.emitActivity("正在认真组织回复", request: 0)
        guard workspace.statusText.contains("正在认真组织回复"),
              workspace.outputBlocks.isEmpty,
              workspace.phase == .running else { return false }
        provider.emit(AITextProviderBlock(index: 0, text: "draft", title: nil), request: 0)
        guard let partialID = workspace.outputBlocks.first?.id,
              workspace.outputBlocks.first?.incomplete == true,
              workspace.deliveryPendingBlocks.isEmpty,
              workspace.primaryAction == .generating,
              workspace.hasIncompleteDeliveryBlocks else { return false }
        provider.emit(AITextProviderBlock(index: 0, text: "draft updated", title: nil), request: 0)
        guard workspace.outputBlocks.first?.id == partialID else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "final one", title: nil),
            AITextProviderBlock(index: 1, text: "final two", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 2,
              workspace.outputBlocks[0].id == partialID,
              workspace.railSnapshot.outputBlocks.count == 2,
              workspace.primaryAction == .deliver,
              source.stagedText == "source" else { return false }

        let firstGeneration = workspace.deliveryGeneration
        let firstID = workspace.outputBlocks[0].id
        let firstReceipt = workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: [firstID],
            generation: firstGeneration
        )
        guard source.stagedText == "source",
              workspace.outputBlocks.count == 1,
              workspace.primaryAction == .deliver,
              firstReceipt == nil else {
            return false
        }
        let secondGeneration = workspace.deliveryGeneration
        let secondID = workspace.outputBlocks[0].id
        let secondReceipt = workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: [secondID],
            generation: secondGeneration
        )
        guard source.stagedText.isEmpty,
              workspace.outputBlocks.isEmpty,
              workspace.primaryAction == .disabled,
              secondReceipt == BufferDeliveryTerminalSourceReceipt(
                workspaceID: workspace.deliveryWorkspaceID,
                generation: secondGeneration,
                generationAfterConsumption: workspace.deliveryGeneration,
                consumedBlockIDs: Set([secondID])
              ) else {
            return false
        }

        source.stageExternal("stale", origin: .rime)
        guard workspace.primaryAction == .requestGeneration,
              workspace.generate(),
              provider.requests.count == 2 else { return false }
        workspace.reset()
        provider.emit(AITextProviderBlock(index: 0, text: "must-ignore", title: nil), request: 1)
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "must-ignore", title: nil),
        ]), request: 1)
        guard workspace.outputBlocks.isEmpty else { return false }

        guard workspace.generate(), provider.requests.count == 3 else { return false }
        provider.finish(.failure(.unavailable("retry")), request: 2)
        guard workspace.phase == .failed("retry"),
              workspace.primaryAction == .requestGeneration,
              workspace.generate(),
              provider.requests.count == 4 else { return false }
        source.append(" changed")
        guard provider.cancellations[3].wasCancelled,
              workspace.outputBlocks.isEmpty else { return false }
        guard workspace.generate(), provider.requests.count == 5 else { return false }
        workspace.setProtected(true)
        guard provider.cancellations[4].wasCancelled,
              !workspace.canGenerate,
              workspace.primaryAction == .disabled,
              workspace.outputBlocks.isEmpty else { return false }
        workspace.setProtected(false)
        return workspace.canGenerate && workspace.primaryAction == .requestGeneration
    }

    private static func workspaceForcesProviderSegmentation() -> Bool {
        let source = BufferModel()
        source.stageExternal("source", origin: .rime)
        let provider = AITextSmokeProvider()
        let workspace = AITextPluginWorkspace(provider: provider,
                                              sourceModel: source,
                                              isSelected: { true })
        workspace.start()
        defer { workspace.stop() }
        let coarse = (1...25).map { "第\($0)段，" }.joined()
        guard workspace.generate() else { return false }
        provider.emit(
            AITextProviderBlock(index: 0, text: coarse, title: "coarse"),
            request: 0
        )
        let partialIDs = workspace.outputBlocks.map(\.id)
        guard partialIDs.count > 1,
              workspace.outputBlocks.map(\.text).joined() == coarse,
              workspace.outputBlocks.allSatisfy(\.incomplete) else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: coarse, title: "coarse"),
        ]), request: 0)
        guard workspace.phase == .ready
            && workspace.outputBlocks.count == partialIDs.count
            && workspace.outputBlocks.count > AITextRuntimeLimits.maximumModelBlockCount
            && workspace.outputBlocks.map(\.id) == partialIDs
            && workspace.deliveryPendingBlocks.map(\.text).joined() == coarse else {
            return false
        }

        // Growing an earlier provider block must not steal the stable identity
        // of a later provider block. Provider indices remain logical here;
        // only the workspace creates child segments.
        let secondSource = BufferModel()
        secondSource.stageExternal("source", origin: .rime)
        let secondProvider = AITextSmokeProvider()
        let secondWorkspace = AITextPluginWorkspace(
            provider: secondProvider,
            sourceModel: secondSource,
            isSelected: { true }
        )
        secondWorkspace.start()
        defer { secondWorkspace.stop() }
        guard secondWorkspace.generate() else { return false }
        secondProvider.emit(
            AITextProviderBlock(index: 0, text: "第一段。", title: nil),
            request: 0
        )
        secondProvider.emit(
            AITextProviderBlock(index: 1, text: "后一段。", title: nil),
            request: 0
        )
        guard let laterID = secondWorkspace.outputBlocks.first(where: {
            $0.text == "后一段。"
        })?.id else { return false }
        secondProvider.emit(
            AITextProviderBlock(index: 0, text: "第一段。新增一段。", title: nil),
            request: 0
        )
        guard secondWorkspace.outputBlocks.first(where: {
            $0.text == "后一段。"
        })?.id == laterID else { return false }
        secondProvider.finish(.success([
            AITextProviderBlock(index: 0, text: "第一段。新增一段。", title: nil),
            AITextProviderBlock(index: 1, text: "后一段。", title: nil),
        ]), request: 0)
        guard secondWorkspace.phase == .ready
            && secondWorkspace.outputBlocks.first(where: {
                $0.text == "后一段。"
            })?.id == laterID else { return false }

        // A coarse plain-text provider result may exceed the per-delivery-block
        // limit while remaining within the wire budget. It must stay one
        // logical provider block until the workspace safely refines it.
        let largePlain = Array(repeating: "word", count: 5_000)
            .joined(separator: " ")
        guard largePlain.utf8.count > AITextRuntimeLimits.maximumBlockBytes,
              let decodedLarge = try? AITextResultDecoder.decodeFinalText(largePlain),
              decodedLarge.count == 1,
              AITextProviderStreamingOutput.blocks(from: largePlain).count == 1 else {
            return false
        }
        let escapedLarge = largePlain
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let partialStructuredLarge =
            "{\"blocks\":[{\"index\":0,\"text\":\"\(escapedLarge)"
        guard AITextProviderStreamingOutput.blocks(
            from: partialStructuredLarge
        ).first?.text == largePlain else {
            return false
        }
        let thirdSource = BufferModel()
        thirdSource.stageExternal("source", origin: .rime)
        let thirdProvider = AITextSmokeProvider()
        let thirdWorkspace = AITextPluginWorkspace(
            provider: thirdProvider,
            sourceModel: thirdSource,
            isSelected: { true }
        )
        thirdWorkspace.start()
        defer { thirdWorkspace.stop() }
        guard thirdWorkspace.generate() else { return false }
        thirdProvider.finish(.success(decodedLarge), request: 0)
        return thirdWorkspace.phase == .ready
            && thirdWorkspace.outputBlocks.count
                == SemanticBlockSegmenter.maximumWorkbenchSegments
            && thirdWorkspace.outputBlocks.map(\.text).joined() == largePlain
            && thirdWorkspace.outputBlocks.allSatisfy {
                $0.text.utf8.count <= AITextRuntimeLimits.maximumBlockBytes
            }
    }

    private static func remoteMirrorAndActionReview() -> Bool {
        let remoteSource = BufferModel()
        remoteSource.stageExternal("remote", origin: .remotePeer(deviceID: "peer"))
        let remoteProvider = AITextSmokeProvider(kind: .claudeCodeCLI)
        let remoteWorkspace = AITextPluginWorkspace(provider: remoteProvider,
                                                    sourceModel: remoteSource,
                                                    isSelected: { true })
        remoteWorkspace.start()
        defer { remoteWorkspace.stop() }
        guard remoteWorkspace.generate() else { return false }
        remoteProvider.finish(.success([
            AITextProviderBlock(index: 0, text: "derived", title: nil),
        ]), request: 0)
        guard let derived = remoteWorkspace.deliveryPendingBlocks.first,
              !derived.origin.allowsRemoteMirror else { return false }

        let actionSource = BufferModel()
        var focus = FocusEpochState()
        let token = focus.activate()
        let unreviewed = BufferModel.PluginMetadata(
            pluginId: "example.action",
            actionId: "reply",
            requestId: "request",
            contextId: "context",
            focusToken: token,
            runtimeIdentity: "runtime",
            reviewedAsPlainText: false
        )
        actionSource.stageExternal("bound",
                                   origin: .plugin(id: "example.action"),
                                   pluginMetadata: unreviewed)
        let actionProvider = AITextSmokeProvider(kind: .openAICompatible)
        let actionWorkspace = AITextPluginWorkspace(provider: actionProvider,
                                                    sourceModel: actionSource,
                                                    isSelected: { true })
        actionWorkspace.start()
        defer { actionWorkspace.stop() }
        guard !actionWorkspace.canGenerate,
              !actionWorkspace.generate(),
              actionProvider.requests.isEmpty else { return false }

        let reviewedSource = BufferModel()
        reviewedSource.stageExternal(
            "reviewed",
            origin: .plugin(id: "example.action"),
            pluginMetadata: unreviewed.markingReviewedAsPlainText()
        )
        let reviewedWorkspace = AITextPluginWorkspace(provider: actionProvider,
                                                      sourceModel: reviewedSource,
                                                      isSelected: { true })
        reviewedWorkspace.start()
        defer { reviewedWorkspace.stop() }
        return reviewedWorkspace.canGenerate
    }

    private static func waitUntil(timeout: TimeInterval,
                                  _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.current.run(mode: .default,
                                    before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

/// Pure/fake smoke: no URLSession is started and no executable is launched.
func runAITextPluginSmokeTest() -> Bool {
    let passed = AITextPluginSmoke.run()
    print(passed ? "AI text plugin smoke OK" : "FAILED: AI text plugin smoke")
    return passed
}

func runAITextTerminalDeliveryReceiptSmokeTest() -> Bool {
    let passed = AITextPluginSmoke.terminalDeliveryReceipt()
    print(passed
        ? "AI text terminal delivery receipt smoke OK"
        : "FAILED: AI text terminal delivery receipt smoke")
    return passed
}
