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
    var streaming: Bool
    var state: State
    let createdAt: Date
    let pluginMetadata: BufferModel.PluginMetadata?

    enum State: Equatable { case pending, accepted, rejected }

    init(id: UUID = UUID(), origin: Origin, title: String? = nil, text: String,
         streaming: Bool = false, state: State = .pending, createdAt: Date = Date(),
         pluginMetadata: BufferModel.PluginMetadata? = nil) {
        self.id = id; self.origin = origin; self.title = title; self.text = text
        self.streaming = streaming; self.state = state; self.createdAt = createdAt
        self.pluginMetadata = pluginMetadata
    }
}

/// Aggregates every external source, applies per-source gating, and holds the
/// items awaiting acceptance. Providers (MCP/HTTP/SSE/SSH) call `submit`/stream
/// methods; the inbound-rail UI reads `pending` and calls `accept`/`reject`.
/// Called on the main thread (like BufferModel); providers hop to main before
/// submitting.
final class InboundBus {
    static let shared = InboundBus()

    enum SubmissionRejection: Equatable {
        case empty
        case blocked
        case full
        case tooLarge
    }

    enum SubmissionResult: Equatable {
        case pending(UUID)
        case staged
        case rejected(SubmissionRejection)
    }

    /// Hard caps so a chatty or hostile local process can't exhaust memory / UI.
    /// (RemotePeer has its own pendingCap=50; the gateway needs the same guard.)
    static let maxPending = 50
    static let maxTextCount = 20_000
    /// A reviewed plugin result may be one coarse AI logical block. Keep the
    /// old aggregate memory envelope while allowing that one item to survive
    /// intact until acceptance applies host segmentation.
    static let maxReviewedPluginTextCount = 1_048_576
    static let maxPendingTextCount = 1_048_576

    private(set) var pending: [InboundItem] = []
    private var streamItemID: [String: UUID] = [:]   // provider streamID -> item id
    var onChange: (() -> Void)?

    var pendingCount: Int { pending.count }

    /// Default trust per source family. Persisted overrides land in M2's
    /// connections settings page; for now these are the ship defaults.
    func trust(for origin: Origin) -> SourceTrust {
        switch origin {
        case .marine: return .trusted           // preserve current Marine flow
        case .plugin: return .ask               // stale/cancelled action results need review
        case .mcp, .http, .sse, .ssh: return .ask
        case .rime, .processor, .remotePeer: return .ask // shouldn't arrive here; be safe
        }
    }

    /// Offer a complete item. Returns its id when it lands in the rail as
    /// pending, or nil when it was auto-accepted (trusted) or dropped.
    @discardableResult
    func submit(origin: Origin,
                text: String,
                title: String? = nil,
                pluginMetadata: BufferModel.PluginMetadata? = nil) -> UUID? {
        guard case let .pending(id) = submitDetailed(origin: origin,
                                                    text: text,
                                                    title: title,
                                                    pluginMetadata: pluginMetadata) else {
            return nil
        }
        return id
    }

    @discardableResult
    func submitDetailed(origin: Origin,
                        text: String,
                        title: String? = nil,
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
            clean = String(text.prefix(Self.maxTextCount))
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
                                   pluginMetadata: pluginMetadata)
            pending.append(item)
            IMELog.write("inbound pending+ origin=\(origin.tag) chars=\(clean.count) count=\(pending.count)")
            onChange?()
            return .pending(item.id)
        }
    }

    // MARK: streaming (SSE / MCP stream tools)

    /// Open a streaming placeholder item. Trusted sources still stream into the
    /// rail (not straight to buffer) so partial text stays reviewable.
    @discardableResult
    func beginStream(origin: Origin, streamID: String, title: String? = nil) -> UUID? {
        guard trust(for: origin) != .blocked else { return nil }
        guard pending.count < Self.maxPending else { return nil }
        let item = InboundItem(origin: origin, title: title, text: "", streaming: true)
        streamItemID[streamID] = item.id
        pending.append(item)
        IMELog.write("inbound stream begin origin=\(origin.tag) stream=\(streamID)")
        onChange?()
        return item.id
    }

    func appendStream(streamID: String, delta: String) {
        guard let id = streamItemID[streamID],
              let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[idx].text = String((pending[idx].text + delta).prefix(Self.maxTextCount))
        onChange?()
    }

    func endStream(streamID: String) {
        guard let id = streamItemID.removeValue(forKey: streamID),
              let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[idx].streaming = false
        IMELog.write("inbound stream end stream=\(streamID) chars=\(pending[idx].text.count)")
        onChange?()
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
        guard let idx = pending.firstIndex(where: { $0.id == id }),
              !pending[idx].streaming else { return false }
        let item = pending[idx]
        let acceptedMetadata: BufferModel.PluginMetadata?
        if case .plugin = item.origin,
           let metadata = item.pluginMetadata,
           metadata.stale {
            acceptedMetadata = metadata.markingReviewedAsPlainText()
        } else {
            acceptedMetadata = item.pluginMetadata
        }
        if case .plugin = item.origin {
            BufferModel.shared.stageExternalSemantic(
                item.text,
                origin: item.origin,
                pluginMetadata: acceptedMetadata
            )
        } else {
            BufferModel.shared.stageExternal(item.text,
                                             origin: item.origin,
                                             pluginMetadata: acceptedMetadata)
        }
        IMELog.write("inbound accepted origin=\(item.origin.tag) chars=\(item.text.count)")
        pending.remove(at: idx)
        onChange?()
        return true
    }

    func reject(_ id: UUID) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        streamItemID = streamItemID.filter { $0.value != id }
        IMELog.write("inbound rejected origin=\(pending[idx].origin.tag)")
        pending.remove(at: idx)
        onChange?()
    }

    func clear() {
        pending.removeAll()
        streamItemID.removeAll()
        onChange?()
    }
}
