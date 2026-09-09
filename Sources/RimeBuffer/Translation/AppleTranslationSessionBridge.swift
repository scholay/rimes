import Foundation
import SwiftUI
import Translation

/// Turns a language pair into a live `TranslationSession`.
///
/// Apple hands a session to a SwiftUI `.translationTask` and nowhere else, and
/// only when the view is attached to a real window — a detached or hidden host
/// never receives one. That single constraint is why translating a string is
/// not a function call in this app, and it is the whole of what this type
/// exists to absorb.
///
/// The bridge is generic over the work: it owns session lifetime, request
/// identity and cancellation, while each client supplies the closure that runs
/// against the session. One instance per host view — two hosts sharing an
/// instance would run the same task twice.
@available(macOS 15.0, *)
final class AppleTranslationSessionBridge: ObservableObject {
    struct Work: Identifiable {
        let id: UInt64
        let configuration: TranslationSession.Configuration
        let sourceLanguageID: String
        let targetLanguageID: String
        let run: (TranslationSession) async -> Void
    }

    @Published private(set) var work: Work?
    private var configuration: TranslationSession.Configuration?
    private var pair: (String, String)?
    private var nextID: UInt64 = 0

    /// Reuses the configuration when the pair is unchanged, invalidating it so
    /// SwiftUI starts a new task; a changed pair needs a new configuration
    /// object or the session keeps the previous languages.
    @discardableResult
    func submit(sourceLanguageID: String,
                targetLanguageID: String,
                run: @escaping (TranslationSession) async -> Void) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(.main))
        let next: TranslationSession.Configuration
        if pair?.0 == sourceLanguageID, pair?.1 == targetLanguageID,
           var current = configuration {
            current.invalidate()
            next = current
        } else {
            pair = (sourceLanguageID, targetLanguageID)
            // An empty source means "detect it". Codex writes in whichever
            // language the session is running in, and a run routinely mixes
            // both, so pinning the source would mistranslate half of it.
            next = TranslationSession.Configuration(
                source: sourceLanguageID.isEmpty
                    ? nil
                    : Locale.Language(identifier: sourceLanguageID),
                target: Locale.Language(identifier: targetLanguageID)
            )
        }
        configuration = next
        nextID &+= 1
        let id = nextID
        work = Work(id: id,
                    configuration: next,
                    sourceLanguageID: sourceLanguageID,
                    targetLanguageID: targetLanguageID,
                    run: run)
        return id
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        work = nil
        pair = nil
        configuration = nil
    }

    func isCurrent(_ id: UInt64) async -> Bool {
        await MainActor.run { [weak self] in self?.work?.id == id }
    }

    /// A session whose languages disagree with what was asked for would
    /// silently translate into the wrong language, so every client checks
    /// this before using one.
    func session(_ session: TranslationSession, matches work: Work) -> Bool {
        guard let target = session.targetLanguage?.minimalIdentifier,
              TranslationLanguageIdentity.matches(
                target, expected: work.targetLanguageID) else {
            return false
        }
        // A detected source has nothing to check against; the target is what
        // a mismatch would silently get wrong.
        guard !work.sourceLanguageID.isEmpty else { return true }
        guard let source = session.sourceLanguage?.minimalIdentifier else {
            return false
        }
        return TranslationLanguageIdentity.matches(
            source, expected: work.sourceLanguageID)
    }

    /// The host must be added to a live window's view hierarchy. It is sized
    /// to a near-invisible point rather than hidden, because `isHidden` and
    /// detachment both stop the session arriving.
    func makeHostView() -> NSView {
        let host = NSHostingView(rootView: AppleTranslationBridgeRoot(bridge: self))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.alphaValue = 0.001
        return host
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationBridgeRoot: View {
    @ObservedObject var bridge: AppleTranslationSessionBridge

    var body: some View {
        Group {
            if let work = bridge.work {
                AppleTranslationWorkView(work: work).id(work.id)
            } else {
                Color.clear
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .allowsHitTesting(false)
    }
}

@available(macOS 15.0, *)
private struct AppleTranslationWorkView: View {
    let work: AppleTranslationSessionBridge.Work

    var body: some View {
        Color.clear
            .translationTask(work.configuration) { session in
                await work.run(session)
            }
    }
}

/// Translates loose strings. The workbench plugin tracks source units,
/// generations and delivery; a caller that only wants one sentence rewritten
/// should not have to adopt any of that.
@available(macOS 15.0, *)
final class AppleTranslationStringService {
    enum Failure: Error, Equatable {
        case sessionLanguagesDisagree
        case superseded
        case failed(String)
    }

    private let bridge = AppleTranslationSessionBridge()
    private var queue: [(String, String, String, (Result<String, Failure>) -> Void)] = []
    private var busy = false

    var sourceLanguageID: String
    var targetLanguageID: String

    /// An empty source language asks the framework to detect it.
    init(sourceLanguageID: String = "", targetLanguageID: String = "zh-Hans") {
        self.sourceLanguageID = sourceLanguageID
        self.targetLanguageID = targetLanguageID
    }

    func makeHostView() -> NSView { bridge.makeHostView() }

    /// Serialized: `.translationTask` yields one session per configuration, so
    /// overlapping requests would cancel each other rather than run together.
    func translate(_ text: String,
                   from source: String? = nil,
                   to target: String? = nil,
                   completion: @escaping (Result<String, Failure>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.success(text))
            return
        }
        queue.append((text,
                      source ?? sourceLanguageID,
                      target ?? targetLanguageID,
                      completion))
        drain()
    }

    func cancelAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        let pending = queue
        queue.removeAll()
        busy = false
        bridge.cancel()
        pending.forEach { $0.3(.failure(.superseded)) }
    }

    private func drain() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (text, source, target, completion) = queue.removeFirst()
        let id = bridge.submit(sourceLanguageID: source,
                               targetLanguageID: target) { [weak self] session in
            await self?.run(session: session,
                            id: 0,
                            text: text,
                            completion: completion)
        }
        _ = id
    }

    private func run(session: TranslationSession,
                     id: UInt64,
                     text: String,
                     completion: @escaping (Result<String, Failure>) -> Void) async {
        let work = await MainActor.run { self.bridge.work }
        if let work, !bridge.session(session, matches: work) {
            await finish(.failure(.sessionLanguagesDisagree),
                         completion: completion)
            return
        }
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            let response = try await session.translate(text)
            try Task.checkCancellation()
            await finish(.success(response.targetText), completion: completion)
        } catch is CancellationError {
            await finish(.failure(.superseded), completion: completion)
        } catch {
            await finish(.failure(.failed(error.localizedDescription)),
                         completion: completion)
        }
    }

    private func finish(_ result: Result<String, Failure>,
                        completion: @escaping (Result<String, Failure>) -> Void) async {
        await MainActor.run {
            self.busy = false
            completion(result)
            self.drain()
        }
    }
}
