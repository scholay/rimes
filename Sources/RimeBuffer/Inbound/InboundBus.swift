import Foundation

/// How much an external source is trusted. Per the security review, an MCP
/// client's self-reported name is NOT verifiable, so MCP/HTTP/SSE default to
/// `.ask` (every item waits for a manual accept). Marine keeps its current
/// auto-into-buffer behavior via `.trusted` during the migration window.
enum SourceTrust: String {
    case ask       // item waits in the inbound rail for manual accept
    case trusted   // item drops straight into the buffer (never auto-delivered)
    case blocked   // item is discarded
}

/// A single item offered by an external source, awaiting the user's decision.
struct InboundItem: Identifiable, Equatable {
    let id: UUID
    let origin: Origin
    var title: String?
    var text: String
    var format: AITextContentFormat
    var streaming: Bool
    var state: State
    let createdAt: Date
    let pluginMetadata: BufferModel.PluginMetadata?
    /// Durable Mailbox conversation for this review item. The Buffer payload
    /// itself remains process-local; only the human-readable conversation is
    /// persisted by MailboxStore.
    var mailboxThreadID: UUID?

    enum State: Equatable { case pending, accepted, rejected }

    init(id: UUID = UUID(), origin: Origin, title: String? = nil, text: String,
         format: AITextContentFormat = .plain,
         streaming: Bool = false, state: State = .pending, createdAt: Date = Date(),
         pluginMetadata: BufferModel.PluginMetadata? = nil,
         mailboxThreadID: UUID? = nil) {
        self.id = id; self.origin = origin; self.title = title; self.text = text
        self.format = format
        self.streaming = streaming; self.state = state; self.createdAt = createdAt
        self.pluginMetadata = pluginMetadata
        self.mailboxThreadID = mailboxThreadID
    }
}

/// Aggregates every external source, applies per-source gating, and holds the
/// items awaiting acceptance. Providers (MCP/HTTP/SSE/SSH) call `submit`/stream
/// methods; the inbound-rail UI reads `pending` and calls `accept`/`reject`.
/// Called on the main thread (like BufferModel); providers hop to main before
/// submitting.
final class InboundBus {
    static let shared = InboundBus(
        mailboxStore: .shared,
        interactionBridge: .shared,
        restorePendingReviews: true
    )

    enum SubmissionRejection: Equatable {
        case empty
        case blocked
        case full
        case tooLarge
        case persistenceUnavailable
    }

    enum SubmissionResult: Equatable {
        case pending(UUID)
        case staged
        case rejected(SubmissionRejection)
    }

    enum StreamAppendResult: Equatable {
        case appended
        case notFound
        case tooLarge
    }

    /// Hard caps so a chatty or hostile local process can't exhaust memory / UI.
    /// Keep the gateway bounded even when a local client is chatty or hostile.
    static let maxPending = 50
    static let maxTextCount = 20_000
    /// A reviewed plugin result may be one coarse AI logical block. Keep the
    /// old aggregate memory envelope while allowing that one item to survive
    /// intact until acceptance applies host segmentation.
    static let maxReviewedPluginTextCount = 1_048_576
    static let maxPendingTextCount = 1_048_576

    private(set) var pending: [InboundItem] = []
    private var streamItemID: [String: UUID] = [:]   // provider streamID -> item id
    private var decidingItemIDs = Set<UUID>()
    private let mailboxStore: MailboxStore?
    private let interactionBridge: MailboxInteractionBridge?
    var onChange: (() -> Void)?

    var pendingCount: Int { pending.count }

    /// Isolated buses used by tests and plugin validation do not touch the
    /// user's durable Mailbox. Only the production singleton injects the
    /// shared store and opts into restart recovery.
    init(mailboxStore: MailboxStore? = nil,
         interactionBridge: MailboxInteractionBridge? = nil,
         restorePendingReviews: Bool = false) {
        self.mailboxStore = mailboxStore
        self.interactionBridge = interactionBridge
        if restorePendingReviews {
            restorePendingReviewsFromStore()
        }
    }

    /// Default trust per source family. Persisted overrides land in M2's
    /// connections settings page; for now these are the ship defaults.
    func trust(for origin: Origin) -> SourceTrust {
        switch origin {
        case .marine: return .trusted           // preserve current Marine flow
        case .plugin: return .ask               // stale/cancelled action results need review
        case .mcp, .http, .sse, .ssh: return .ask
        case .rime, .localInput, .clipboard, .processor, .remotePeer:
            return .ask // shouldn't arrive here; be safe
        }
    }

    /// Offer a complete item. Returns its id when it lands in the rail as
    /// pending, or nil when it was auto-accepted (trusted) or dropped.
    @discardableResult
    func submit(origin: Origin,
                text: String,
                title: String? = nil,
                format: AITextContentFormat = .plain,
                pluginMetadata: BufferModel.PluginMetadata? = nil) -> UUID? {
        guard case let .pending(id) = submitDetailed(origin: origin,
                                                    text: text,
                                                    title: title,
                                                    format: format,
                                                    pluginMetadata: pluginMetadata) else {
            return nil
        }
        return id
    }

    @discardableResult
    func submitDetailed(origin: Origin,
                        text: String,
                        title: String? = nil,
                        format: AITextContentFormat = .plain,
                        pluginMetadata: BufferModel.PluginMetadata? = nil) -> SubmissionResult {
        let isPlugin: Bool
        if case .plugin = origin { isPlugin = true } else { isPlugin = false }
        let clean: String
        if isPlugin {
            guard text.count <= Self.maxReviewedPluginTextCount else {
                return .rejected(.tooLarge)
            }
            clean = text
        } else {
            guard text.count <= Self.maxTextCount else {
                return .rejected(.tooLarge)
            }
            clean = text
        }
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.empty)
        }
        switch trust(for: origin) {
        case .blocked:
            IMELog.write("inbound dropped origin=\(origin.tag) chars=\(clean.count) (blocked)")
            return .rejected(.blocked)
        case .trusted:
            if case .plugin = origin {
                BufferModel.shared.stageExternalSemantic(
                    clean,
                    origin: origin,
                    pluginMetadata: pluginMetadata
                )
            } else {
                BufferModel.shared.stageExternal(clean,
                                                 origin: origin,
                                                 pluginMetadata: pluginMetadata)
            }
            IMELog.write("inbound trusted->buffer origin=\(origin.tag) chars=\(clean.count)")
            return .staged
        case .ask:
            let pendingCharacters = pending.reduce(0) { $0 + $1.text.count }
            guard pending.count < Self.maxPending,
                  pendingCharacters + clean.count <= Self.maxPendingTextCount else {
                IMELog.write("inbound dropped origin=\(origin.tag) (pending cap \(Self.maxPending))")
                return .rejected(.full)
            }
            let item = InboundItem(origin: origin,
                                   title: title,
                                   text: clean,
                                   format: format,
                                   pluginMetadata: pluginMetadata)
            pending.append(item)
            let attached = attachMailboxThread(toItemAt: pending.count - 1)
            if mailboxStore != nil, !attached {
                pending.removeAll(where: { $0.id == item.id })
                IMELog.write(
                    "inbound rejected origin=\(origin.tag) reason=mailbox-persistence"
                )
                return .rejected(.persistenceUnavailable)
            }
            IMELog.write("inbound pending+ origin=\(origin.tag) chars=\(clean.count) count=\(pending.count)")
            onChange?()
            return .pending(item.id)
        }
    }

    // MARK: streaming (SSE / MCP stream tools)

    /// Open a streaming placeholder item. Trusted sources still stream into the
    /// rail (not straight to buffer) so partial text stays reviewable.
    @discardableResult
    func beginStream(origin: Origin,
                     streamID: String,
                     title: String? = nil,
                     format: AITextContentFormat = .plain) -> UUID? {
        guard trust(for: origin) != .blocked else { return nil }
        guard pending.count < Self.maxPending else { return nil }
        let item = InboundItem(
            origin: origin,
            title: title,
            text: "",
            format: format,
            streaming: true
        )
        streamItemID[streamID] = item.id
        pending.append(item)
        IMELog.write("inbound stream begin origin=\(origin.tag) stream=\(streamID)")
        onChange?()
        return item.id
    }

    @discardableResult
    func appendStream(streamID: String, delta: String) -> StreamAppendResult {
        guard let id = streamItemID[streamID],
              let idx = pending.firstIndex(where: { $0.id == id }) else {
            return .notFound
        }
        guard delta.count <= Self.maxTextCount - pending[idx].text.count else {
            return .tooLarge
        }
        pending[idx].text += delta
        onChange?()
        return .appended
    }

    @discardableResult
    func endStream(streamID: String) -> Bool {
        guard let id = streamItemID.removeValue(forKey: streamID),
              let idx = pending.firstIndex(where: { $0.id == id }) else {
            return false
        }
        pending[idx].streaming = false
        let characterCount = pending[idx].text.count
        let attached = attachMailboxThread(toItemAt: idx)
        if mailboxStore != nil, !attached {
            pending.removeAll(where: { $0.id == id })
            IMELog.write(
                "inbound stream rejected stream=\(streamID) reason=mailbox-persistence"
            )
            onChange?()
            return false
        }
        IMELog.write("inbound stream end stream=\(streamID) chars=\(characterCount)")
        onChange?()
        return true
    }

    // MARK: user decisions

    /// Streaming items remain review-only until their provider explicitly ends
    /// the stream. This prevents a partial snapshot from being staged more than
    /// once while later deltas are still mutating the same pending item.
    func canAccept(_ id: UUID) -> Bool {
        pending.first(where: { $0.id == id })?.streaming == false
    }

    /// Accept a completed item: it becomes a buffer block carrying its origin.
    /// The model gate is authoritative even when a stale UI action arrives.
    @discardableResult
    func accept(_ id: UUID) -> Bool {
        guard decidingItemIDs.insert(id).inserted else { return false }
        defer { decidingItemIDs.remove(id) }
        guard let item = pending.first(where: { $0.id == id }),
              !item.streaming else { return false }

        if let threadID = item.mailboxThreadID {
            guard let mailboxStore else { return false }
            do {
                try mailboxStore.resolveReview(
                    threadID: threadID,
                    decision: .accept
                )
            } catch {
                IMELog.write("mailbox review resolve failed action=accept")
                return false
            }
        }

        let acceptedMetadata: BufferModel.PluginMetadata?
        if case .plugin = item.origin,
           let metadata = item.pluginMetadata,
           metadata.stale {
            acceptedMetadata = metadata.markingReviewedAsPlainText()
        } else {
            acceptedMetadata = item.pluginMetadata
        }
        if case .plugin = item.origin,
           let acceptedMetadata {
            BufferModel.shared.stageExternalSemantic(
                item.text,
                origin: item.origin,
                pluginMetadata: acceptedMetadata
            )
        } else {
            let locallyReviewedAsPlainText: Bool
            if case .plugin = item.origin,
               acceptedMetadata == nil {
                locallyReviewedAsPlainText = true
            } else {
                locallyReviewedAsPlainText = false
            }
            BufferModel.shared.stageExternal(item.text,
                                             origin: item.origin,
                                             pluginMetadata: acceptedMetadata,
                                             locallyReviewedAsPlainText:
                                                locallyReviewedAsPlainText)
        }
        IMELog.write("inbound accepted origin=\(item.origin.tag) chars=\(item.text.count)")
        if let threadID = item.mailboxThreadID {
            interactionBridge?.clearInboundReview(threadID: threadID)
        }
        pending.removeAll(where: { $0.id == id })
        streamItemID = streamItemID.filter { $0.value != id }
        onChange?()
        return true
    }

    @discardableResult
    func reject(_ id: UUID) -> Bool {
        guard decidingItemIDs.insert(id).inserted else { return false }
        defer { decidingItemIDs.remove(id) }
        guard let item = pending.first(where: { $0.id == id }) else {
            return false
        }
        if let threadID = item.mailboxThreadID {
            guard let mailboxStore else { return false }
            do {
                try mailboxStore.resolveReview(
                    threadID: threadID,
                    decision: .reject
                )
            } catch {
                IMELog.write("mailbox review resolve failed action=reject")
                return false
            }
            interactionBridge?.clearInboundReview(threadID: threadID)
        }
        streamItemID = streamItemID.filter { $0.value != id }
        IMELog.write("inbound rejected origin=\(item.origin.tag)")
        pending.removeAll(where: { $0.id == id })
        onChange?()
        return true
    }

    func clear() {
        let threadIDs = pending.compactMap(\.mailboxThreadID)
        pending.removeAll()
        streamItemID.removeAll()
        for threadID in threadIDs {
            interactionBridge?.clearInboundReview(threadID: threadID)
        }
        onChange?()
    }

    func pendingItem(mailboxThreadID: UUID) -> InboundItem? {
        pending.first(where: { $0.mailboxThreadID == mailboxThreadID })
    }

    @discardableResult
    private func attachMailboxThread(toItemAt index: Int) -> Bool {
        guard pending.indices.contains(index),
              pending[index].mailboxThreadID == nil,
              !pending[index].streaming else { return false }
        let item = pending[index]
        // Explicitly isolated buses retain the historical in-memory rail for
        // deterministic tests. Production always injects a store and may only
        // report pending after a durable Mailbox association exists.
        guard let mailboxStore else { return true }
        guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        do {
            let thread = try mailboxStore.createInboundThread(
                source: mailboxSource(for: item.origin),
                title: normalizedMailboxTitle(item.title),
                body: item.text,
                format: item.format,
                author: mailboxDisplayName(for: item.origin)
            )
            // Store observers run synchronously on the main thread. Resolve
            // the item again by stable identity after persistence so observer
            // reentry can never turn the old array index into a wrong binding.
            guard let currentIndex = pending.firstIndex(
                where: { $0.id == item.id }
            ), pending[currentIndex].mailboxThreadID == nil else {
                // An observer removed the process-local item while the Store
                // callback was being delivered. Close the durable review so
                // it cannot become a second, unactionable orphan.
                do {
                    try mailboxStore.resolveReview(
                        threadID: thread.id,
                        decision: .reject
                    )
                } catch {
                    // A pathological per-thread message limit may leave no
                    // room for the rejection status. Removing this just-made
                    // thread is safer than retaining an unresolvable review.
                    try? mailboxStore.deleteThread(id: thread.id)
                }
                return false
            }
            pending[currentIndex].mailboxThreadID = thread.id
            interactionBridge?.associateInboundReview(
                threadID: thread.id,
                itemID: item.id
            )
            return true
        } catch {
            // The production caller removes the unassociated item and returns
            // an explicit rejection. An isolated no-store test bus never
            // reaches this branch.
            IMELog.write("mailbox inbound persist failed origin=\(item.origin.tag)")
            return false
        }
    }

    private func mailboxSource(for origin: Origin) -> MailboxSource {
        switch origin {
        case let .mcp(client):
            let name = normalizedMailboxName(client, fallback: "MCP 客户端")
            return .mcp(client: name)
        case let .http(source):
            let name = normalizedMailboxName(source, fallback: "HTTP 来源")
            return .http(source: name)
        case let .sse(feed):
            let name = normalizedMailboxName(feed, fallback: "SSE 来源")
            return MailboxSource(
                kind: .sse,
                displayName: name,
                identifier: name,
                replyCapability: .localNotesOnly
            )
        case let .ssh(host):
            let name = normalizedMailboxName(host, fallback: "SSH 来源")
            return MailboxSource(
                kind: .ssh,
                displayName: name,
                identifier: name,
                replyCapability: .localNotesOnly
            )
        case let .plugin(id):
            let identifier = normalizedMailboxName(id, fallback: "unknown-plugin")
            return MailboxSource(
                kind: .plugin,
                displayName: "插件",
                identifier: identifier,
                replyCapability: .localNotesOnly
            )
        case .marine:
            return MailboxSource(
                kind: .other,
                displayName: "Marine Chrome",
                identifier: "marine",
                replyCapability: .localNotesOnly
            )
        case let .processor(id, _):
            return MailboxSource(
                kind: .other,
                displayName: "处理器",
                identifier: normalizedMailboxName(id, fallback: "processor"),
                replyCapability: .localNotesOnly
            )
        case let .remotePeer(deviceID):
            return MailboxSource(
                kind: .other,
                displayName: "配对设备",
                identifier: normalizedMailboxName(deviceID, fallback: "remote-peer"),
                replyCapability: .localNotesOnly
            )
        case .rime:
            return MailboxSource(
                kind: .other,
                displayName: "RIMES",
                identifier: "rime",
                replyCapability: .localNotesOnly
            )
        case let .localInput(inputSourceID):
            return MailboxSource(
                kind: .other,
                displayName: "本机输入",
                identifier: normalizedMailboxName(inputSourceID,
                                                  fallback: "local-input"),
                replyCapability: .localNotesOnly
            )
        case .clipboard:
            return MailboxSource(
                kind: .other,
                displayName: "剪贴板",
                identifier: "clipboard",
                replyCapability: .localNotesOnly
            )
        }
    }

    private func mailboxDisplayName(for origin: Origin) -> String {
        switch origin {
        case let .mcp(client): return normalizedMailboxAuthor(client, fallback: "MCP 客户端")
        case let .http(source): return normalizedMailboxAuthor(source, fallback: "HTTP 来源")
        case let .sse(feed): return normalizedMailboxAuthor(feed, fallback: "SSE 来源")
        case let .ssh(host): return normalizedMailboxAuthor(host, fallback: "SSH 来源")
        case .marine: return "Marine Chrome"
        case .plugin: return "插件"
        case .processor: return "处理器"
        case .remotePeer: return "配对设备"
        case .rime: return "RIMES"
        case .localInput: return "本机输入"
        case .clipboard: return "剪贴板"
        }
    }

    private func normalizedMailboxName(_ value: String,
                                       fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(512))
    }

    private func normalizedMailboxAuthor(_ value: String,
                                         fallback: String) -> String {
        String(normalizedMailboxName(value, fallback: fallback).prefix(128))
    }

    private func normalizedMailboxTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(256))
    }

    /// Rebuilds only explicit pending reviews from the private Mailbox file.
    /// No runtime authority, plugin metadata, or trust decision is inferred
    /// from display text. Unknown source kinds remain visible in Mailbox but
    /// are deliberately not actionable in the Buffer review rail.
    private func restorePendingReviewsFromStore() {
        guard let mailboxStore else { return }
        let candidates = mailboxStore.snapshot.threads
            .filter { $0.review?.state == .pending }
            .sorted { $0.sequence < $1.sequence }
        var totalCharacters = 0

        for thread in candidates {
            guard pending.count < Self.maxPending,
                  let review = thread.review,
                  let message = thread.messages.first(
                    where: { $0.id == review.messageID }
                  ),
                  let origin = restoredOrigin(for: thread.source) else {
                continue
            }
            let itemLimit: Int
            if case .plugin = origin {
                itemLimit = Self.maxReviewedPluginTextCount
            } else {
                itemLimit = Self.maxTextCount
            }
            guard message.body.count <= itemLimit,
                  totalCharacters + message.body.count
                    <= Self.maxPendingTextCount else {
                IMELog.write("mailbox pending restore skipped reason=capacity")
                continue
            }
            let item = InboundItem(
                id: review.messageID,
                origin: origin,
                title: thread.title,
                text: message.body,
                streaming: false,
                state: .pending,
                createdAt: message.createdAt,
                pluginMetadata: nil,
                mailboxThreadID: thread.id
            )
            pending.append(item)
            totalCharacters += message.body.count
            interactionBridge?.associateInboundReview(
                threadID: thread.id,
                itemID: item.id
            )
        }
        if !pending.isEmpty {
            IMELog.write("mailbox pending reviews restored count=\(pending.count)")
        }
    }

    private func restoredOrigin(for source: MailboxSource) -> Origin? {
        let identity = normalizedMailboxName(
            source.identifier ?? source.displayName,
            fallback: source.displayName
        )
        switch source.kind {
        case .mcp:
            return .mcp(client: identity)
        case .http:
            return .http(source: identity)
        case .sse:
            return .sse(feed: identity)
        case .ssh:
            return .ssh(host: identity)
        case .plugin:
            return .plugin(id: identity)
        case .codexCLI, .claudeCodeCLI, .openAICompatible, .other:
            return nil
        }
    }
}
