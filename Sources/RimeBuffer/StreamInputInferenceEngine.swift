import Foundation

/// Frozen input shared by every consciousness-stream inference module. Focus
/// authority deliberately stays in StreamInputWorkspace; engines can propose
/// text, but cannot authorize or deliver it.
/// Which decoder a request may use. The on-device engine is a peer of the
/// connector-backed models, not a privileged pre-stage.
enum StreamInputEngineRole: String, CaseIterable, Equatable {
    case local
    case connector
}

struct StreamInputInferenceRequest: Equatable {
    let requestID: UUID
    let sourceText: String
    let automaticSyllableSpaceOffsets: Set<Int>
    let settings: StreamInputPluginSettings
    let enforcingMinimumAfterRetry: Bool
    let excludedGuesses: [String]
}

/// A small module boundary keeps the local decoder replaceable without making
/// it an AI connector or giving it a second delivery path.
protocol StreamInputInferenceEngine: AnyObject {
    var displayName: String { get }
    var availability: AITextProviderAvailability { get }

    func prepare()
    func reset()

    @discardableResult
    func infer(
        _ request: StreamInputInferenceRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable
}

extension StreamInputInferenceEngine {
    func prepare() {}
    func reset() {}
}

/// Preserves the existing hosted-model implementation as one ordinary module.
final class AIStreamInputInferenceEngine: StreamInputInferenceEngine {
    let provider: any AITextProvider

    init(provider: any AITextProvider) {
        self.provider = provider
    }

    var displayName: String { provider.kind.displayName }
    var availability: AITextProviderAvailability { provider.availability }

    @discardableResult
    func infer(
        _ request: StreamInputInferenceRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        let providerRequest = AITextProviderRequest(
            requestID: request.requestID,
            sourceText: request.sourceText,
            preparedPrompt: StreamInputPrompt.request(
                for: request.sourceText,
                automaticSyllableSpaceOffsets:
                    request.automaticSyllableSpaceOffsets,
                maximumGuessCount: request.settings.candidateCount,
                responsePace: request.settings.responsePace,
                enforcingMinimumAfterRetry:
                    request.enforcingMinimumAfterRetry,
                excludedGuesses: request.excludedGuesses
            ),
            outputContract: .alternativeGuesses,
            maximumAlternativeGuessCount: request.settings.candidateCount
        )
        return provider.generate(
            providerRequest,
            onEvent: onEvent,
            completion: completion
        )
    }
}

private final class StreamInputInferenceCancellation: AITextCancellable {
    private let lock = NSLock()
    // Keep every installed stage. A module is permitted to complete
    // synchronously, so replacing one task with the next could otherwise let
    // the outer install overwrite the currently active fallback task.
    private var downstream: [any AITextCancellable] = []
    private(set) var isCancelled = false

    func install(_ task: any AITextCancellable) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        downstream.append(task)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let tasks = downstream
        downstream.removeAll(keepingCapacity: false)
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    func ifActive(_ operation: () -> Void) {
        lock.lock()
        let active = !isCancelled
        lock.unlock()
        if active { operation() }
    }
}

/// A provider completion is an untrusted asynchronous boundary. Close one
/// attempt exactly once so a buggy connector cannot start multiple fallbacks
/// or keep emitting snapshots after it has declined the request.
private final class StreamInputInferenceAttemptGate {
    private let lock = NSLock()
    private var open = true

    func closeOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return false }
        open = false
        return true
    }

    func ifOpen(_ operation: () -> Void) {
        lock.lock()
        let shouldRun = open
        lock.unlock()
        if shouldRun { operation() }
    }
}

/// Runs modules in the order the request's settings ask for. A module may
/// decline an input with an ordinary failure; the next module then gets the
/// same immutable request. The on-device decoder is one selectable model among
/// the connectors rather than a fixed first stage, so a request may name it
/// alone, name a connector alone, or keep the local-first hand-off that lets
/// Rime answer ordinary pinyin and a model handle typos, Latin fragments, and
/// long input.
final class StreamInputModularInferenceEngine: StreamInputInferenceEngine {
    private let modulesByRole: [StreamInputEngineRole: any StreamInputInferenceEngine]
    private let modules: [any StreamInputInferenceEngine]

    init(modulesByRole: [StreamInputEngineRole: any StreamInputInferenceEngine]) {
        precondition(!modulesByRole.isEmpty)
        self.modulesByRole = modulesByRole
        self.modules = StreamInputEngineRole.allCases.compactMap {
            modulesByRole[$0]
        }
    }

    convenience init(modules: [any StreamInputInferenceEngine]) {
        precondition(!modules.isEmpty)
        var mapped: [StreamInputEngineRole: any StreamInputInferenceEngine] = [:]
        for (index, module) in modules.enumerated() {
            let role = StreamInputEngineRole.allCases.indices.contains(index)
                ? StreamInputEngineRole.allCases[index]
                : .connector
            mapped[role] = module
        }
        self.init(modulesByRole: mapped)
    }

    /// The subset this request actually asked for, in order.
    private func modules(
        for request: StreamInputInferenceRequest
    ) -> [any StreamInputInferenceEngine] {
        let selected = request.settings.engineRoles.compactMap {
            modulesByRole[$0]
        }
        return selected.isEmpty ? modules : selected
    }

    var displayName: String { "本地模块引擎" }

    var availability: AITextProviderAvailability {
        if modules.contains(where: {
            if case .ready = $0.availability { return true }
            return false
        }) {
            return .ready
        }
        let messages = modules.compactMap { module -> String? in
            if case let .unavailable(message) = module.availability {
                return message
            }
            return nil
        }
        return .unavailable(messages.last ?? "意识流推断引擎不可用")
    }

    func prepare() {
        modules.forEach { $0.prepare() }
    }

    func reset() {
        modules.forEach { $0.reset() }
    }

    @discardableResult
    func infer(
        _ request: StreamInputInferenceRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        let cancellation = StreamInputInferenceCancellation()

        func continueOnMain(_ index: Int, lastError: AITextProviderError) {
            if Thread.isMainThread {
                attempt(index, lastError: lastError)
            } else {
                DispatchQueue.main.async {
                    cancellation.ifActive {
                        attempt(index, lastError: lastError)
                    }
                }
            }
        }

        let activeModules = modules(for: request)
        func attempt(_ index: Int, lastError: AITextProviderError?) {
            cancellation.ifActive {
                guard index < activeModules.count else {
                    completion(.failure(lastError ?? .failed))
                    return
                }
                let module = activeModules[index]
                guard case .ready = module.availability else {
                    let unavailable: AITextProviderError
                    if case let .unavailable(message) = module.availability {
                        unavailable = .unavailable(message)
                    } else {
                        unavailable = .failed
                    }
                    attempt(index + 1, lastError: unavailable)
                    return
                }
                let attemptGate = StreamInputInferenceAttemptGate()
                let task = module.infer(
                    request,
                    onEvent: { event in
                        attemptGate.ifOpen {
                            cancellation.ifActive { onEvent(event) }
                        }
                    },
                    completion: { result in
                        guard attemptGate.closeOnce() else { return }
                        cancellation.ifActive {
                            switch result {
                            case let .success(blocks) where !blocks.isEmpty:
                                completion(.success(blocks))
                            case .success:
                                continueOnMain(
                                    index + 1,
                                    lastError: .invalidResult
                                )
                            case let .failure(error):
                                if error == .cancelled {
                                    completion(.failure(.cancelled))
                                } else {
                                    continueOnMain(index + 1, lastError: error)
                                }
                            }
                        }
                    }
                )
                cancellation.install(task)
            }
        }

        attempt(0, lastError: nil)
        return cancellation
    }
}

/// Fast, fully local sentence decoder backed by a private librime session.
/// The hidden schema enables Octagram when its model is bundled. Queries are
/// bounded and serialized so they cannot pile up behind the bridge mutex.
final class RimeOctagramStreamInputEngine: StreamInputInferenceEngine {
    static let shared = RimeOctagramStreamInputEngine()

    static let maximumInputBytes = 512
    static let maximumClauseCount = 8
    private static let schemaID = "stream_input_local"
    private static let requiredSharedDataFiles = [
        "stream_input_local.schema.yaml",
        "grammar.yaml",
        "zh-hans-t-essay-bgw.gram",
    ]

    private let queue = DispatchQueue(
        label: "RimeBuffer.StreamInput.LocalInference",
        qos: .userInteractive
    )
    private let rime = RimeEngine()
    private var session: UInt64 = 0

    var displayName: String { "本地 Rime + Octagram" }
    // Preparation is lazy and failure is retryable; the modular engine will
    // fall through to AI if the bundled runtime or schema is unavailable.
    var availability: AITextProviderAvailability { .ready }

    func prepare() {
        queue.async { [weak self] in
            _ = self?.ensureSession()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self, self.rime.sessionExists(self.session) else { return }
            self.rime.clearComposition(session: self.session)
        }
    }

    @discardableResult
    func infer(
        _ request: StreamInputInferenceRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        let cancellation = StreamInputInferenceCancellation()
        queue.async { [weak self] in
            cancellation.ifActive {
                guard let self else {
                    completion(.failure(.failed))
                    return
                }
                onEvent(.activity(AITextProviderActivity(
                    kind: .reasoning,
                    message: "本地引擎正在解码"
                )))
                let started = DispatchTime.now().uptimeNanoseconds
                let result = self.decode(request)
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                let candidateCount = (try? result.get().count) ?? 0
                IMELog.write(
                    "stream local inference bytes=\(request.sourceText.utf8.count) candidates=\(candidateCount) elapsedMicros=\(elapsed / 1_000)"
                )
                cancellation.ifActive { completion(result) }
            }
        }
        return cancellation
    }

    private func ensureSession() -> Bool {
        if rime.sessionExists(session) { return true }
        session = 0
        guard Self.requiredSharedDataFiles.allSatisfy(
            rime.hasSharedDataFile
        ) else {
            IMELog.write("stream local engine unavailable: required data missing")
            return false
        }
        guard rime.start(), rime.hasOctagram else {
            IMELog.write("stream local engine unavailable: Octagram module missing")
            return false
        }
        let newSession = rime.createSession()
        guard newSession != 0 else { return false }
        guard rime.selectSchema(Self.schemaID, session: newSession) else {
            rime.destroySession(newSession)
            return false
        }
        session = newSession
        rime.setOption("ascii_mode", false, session: session)
        IMELog.write("stream local engine ready schema=\(Self.schemaID)")
        return true
    }

    private func decode(
        _ request: StreamInputInferenceRequest
    ) -> Result<[AITextProviderBlock], AITextProviderError> {
        guard request.sourceText.utf8.count <= Self.maximumInputBytes,
              let split = Self.clauseSplit(
                rawInput: request.sourceText,
                automaticSyllableSpaceOffsets:
                    request.automaticSyllableSpaceOffsets
              ),
              case let clauses = split.clauses,
              clauses.count <= Self.maximumClauseCount,
              ensureSession() else {
            return .failure(.invalidResult)
        }

        let limit = request.settings.candidateCount
        var candidatesByClause: [[String]] = []
        for clause in clauses {
            guard let decoded = rime.decodeCandidateTexts(
                input: clause,
                maximumCount: limit,
                session: session
            ) else {
                let failedSession = session
                session = 0
                rime.destroySession(failedSession)
                return .failure(.failed)
            }
            var seen = Set<String>()
            let usable = decoded.compactMap { raw -> String? in
                guard let text = Self.usableCandidate(raw),
                      seen.insert(text).inserted else { return nil }
                return text
            }
            guard !usable.isEmpty else { return .failure(.invalidResult) }
            candidatesByClause.append(usable)
        }

        let excluded = Set(request.excludedGuesses)
        let combined = Self.combine(
            candidatesByClause,
            separators: split.separators,
            maximumCount: limit
        ).filter { !excluded.contains($0) }
        guard !combined.isEmpty else { return .failure(.invalidResult) }
        return .success(combined.enumerated().map { index, text in
            AITextProviderBlock(index: index, text: text, title: nil)
        })
    }

    /// Soft spaces inserted by chord spelling are Rime syllable delimiters;
    /// user-authored spaces are semantic clause boundaries.
    static func rimeClauses(
        rawInput: String,
        automaticSyllableSpaceOffsets: Set<Int>
    ) -> [String]? {
        clauseSplit(rawInput: rawInput,
                    automaticSyllableSpaceOffsets: automaticSyllableSpaceOffsets)?
            .clauses
    }

    /// Clauses plus the separator that closed each one. A Space contributes no
    /// text of its own; an explicit comma is the only boundary that writes a
    /// character into the result.
    static func clauseSplit(
        rawInput: String,
        automaticSyllableSpaceOffsets: Set<Int>
    ) -> (clauses: [String], separators: [String])? {
        let bytes = Array(rawInput.utf8)
        guard !bytes.isEmpty,
              bytes.allSatisfy({ byte in
                (0x61...0x7A).contains(byte) || byte == 0x20 || byte == 0x2C
              }) else { return nil }
        var clauses: [String] = []
        // `separators[i]` joins clause i to clause i + 1.
        var separators: [String] = []
        var current: [UInt8] = []
        var pendingSeparator: String?
        @discardableResult
        func flushCurrent() -> Bool {
            while current.last == 0x27 { current.removeLast() }
            guard !current.isEmpty else { return false }
            if !clauses.isEmpty { separators.append(pendingSeparator ?? "") }
            pendingSeparator = nil
            clauses.append(String(decoding: current, as: UTF8.self))
            current.removeAll(keepingCapacity: true)
            return true
        }
        for (offset, byte) in bytes.enumerated() {
            if byte == 0x2C {
                flushCurrent()
                // A comma survives even when it follows another boundary, so
                // the punctuation the user asked for is never dropped.
                pendingSeparator = clauses.isEmpty ? nil : "，"
            } else if byte == 0x20 {
                if automaticSyllableSpaceOffsets.contains(offset) {
                    if !current.isEmpty, current.last != 0x27 {
                        current.append(0x27)
                    }
                } else if !current.isEmpty {
                    flushCurrent()
                }
            } else {
                current.append(byte)
            }
        }
        flushCurrent()
        return clauses.isEmpty ? nil : (clauses, separators)
    }

    static func combine(
        _ candidatesByClause: [[String]],
        separators: [String] = [],
        maximumCount: Int
    ) -> [String] {
        struct Path {
            let text: String
            let rank: Int
            let order: Int
        }
        let limit = min(max(maximumCount, 1), 5)
        var paths = [Path(text: "", rank: 0, order: 0)]
        for (clauseIndex, candidates) in candidatesByClause.enumerated() {
            let separator = clauseIndex > 0 && clauseIndex - 1 < separators.count
                ? separators[clauseIndex - 1]
                : ""
            var next: [Path] = []
            for path in paths {
                for (candidateRank, candidate) in candidates.enumerated() {
                    // A user pause is a segmentation boundary, not punctuation:
                    // its separator is empty and the host segmenter chunks the
                    // bare concatenation for delivery. Only a comma the user
                    // typed contributes a character of its own.
                    next.append(Path(
                        text: path.text + separator + candidate,
                        rank: path.rank + candidateRank,
                        order: next.count
                    ))
                }
            }
            next.sort {
                $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank
            }
            var seen = Set<String>()
            paths = next.filter { seen.insert($0.text).inserted }.prefix(limit)
                .map { $0 }
        }
        return paths.map(\.text)
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0x20000...0x2EBEF:
                return true
            default:
                return false
            }
        }
    }

    /// commit_text_preview deliberately preserves an unconverted raw tail.
    /// That makes the bridge lossless; the local sentence module must then
    /// decline such mixed previews so the AI fallback can interpret them.
    static func usableCandidate(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              containsHan(text),
              !text.unicodeScalars.contains(where: { scalar in
                  (0x41...0x5A).contains(scalar.value)
                      || (0x61...0x7A).contains(scalar.value)
              }) else { return nil }
        return text
    }
}
