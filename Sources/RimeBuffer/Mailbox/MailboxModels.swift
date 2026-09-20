import Foundation

enum MailboxMessageRole: String, Codable, CaseIterable {
    case inbound
    case user
    case system
}

/// Distinguishes a local-only annotation from text that belongs to the
/// provider conversation. The role controls the terminal prompt treatment,
/// while every message remains in the same aligned transcript column.
enum MailboxMessageKind: String, Codable {
    case content
    case localNote
    case status
}

struct MailboxMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: MailboxMessageRole
    let kind: MailboxMessageKind
    /// Presentation contract for the body. The exact original body remains
    /// durable; JSON pretty-printing and Markdown styling are view-only.
    let format: AITextContentFormat
    let author: String?
    let body: String
    let createdAt: Date

    init(id: UUID = UUID(),
         role: MailboxMessageRole,
         kind: MailboxMessageKind = .content,
         format: AITextContentFormat = .plain,
         author: String? = nil,
         body: String,
         createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.kind = kind
        self.format = format
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case kind
        case format
        case author
        case body
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(MailboxMessageRole.self, forKey: .role)
        kind = try values.decodeIfPresent(MailboxMessageKind.self, forKey: .kind)
            ?? .content
        if let rawFormat = try values.decodeIfPresent(String.self, forKey: .format) {
            format = AITextContentFormat(rawValue: rawFormat) ?? .plain
        } else {
            // v1 Mailbox files predate explicit content formats.
            format = .plain
        }
        author = try values.decodeIfPresent(String.self, forKey: .author)
        body = try values.decode(String.self, forKey: .body)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encode(kind, forKey: .kind)
        try values.encode(format.rawValue, forKey: .format)
        try values.encodeIfPresent(author, forKey: .author)
        try values.encode(body, forKey: .body)
        try values.encode(createdAt, forKey: .createdAt)
    }
}

enum MailboxReviewState: String, Codable, Equatable {
    case pending
    case accepted
    case rejected
}

/// Durable review state for a one-way inbound message. The message ID is the
/// stable identity used when InboundBus reconstructs its process-local review
/// rail after an application restart; display names are never used as trust
/// evidence.
struct MailboxReview: Codable, Equatable {
    let messageID: UUID
    var state: MailboxReviewState
    var resolvedAt: Date?
}

enum MailboxReviewDecision: Equatable {
    case accept
    case reject
}

enum MailboxSourceKind: String, Codable, CaseIterable {
    case codexCLI
    case claudeCodeCLI
    case openAICompatible
    case mcp
    case http
    case sse
    case ssh
    case plugin
    case other

    var isAIConnector: Bool {
        switch self {
        case .codexCLI, .claudeCodeCLI, .openAICompatible:
            return true
        case .mcp, .http, .sse, .ssh, .plugin, .other:
            return false
        }
    }
}

enum MailboxReplyCapability: String, Codable {
    /// A user message may start a new provider request. The caller is still
    /// responsible for invoking the connector and completing the generation.
    case aiContinuation
    /// The composer writes only a private local note. No response channel is
    /// implied for one-way HTTP, MCP, SSE, SSH, or plugin pushes.
    case localNotesOnly
}

/// Frozen choice for the first turn of a Mailbox-native conversation. A nil
/// model intentionally means the connector's verified default; CLI connectors
/// do not currently expose a model catalog and must not be given invented IDs.
/// A catalog-backed API route carries a non-secret revisioned reference so a
/// later reply cannot silently move to the currently selected provider.
struct MailboxNewConversationSelection: Equatable {
    let connectorKind: AITextProviderKind
    let modelID: String?
    let providerRoute: AIProviderRouteReference?

    init(connectorKind: AITextProviderKind,
         modelID: String?,
         providerRoute: AIProviderRouteReference? = nil) {
        self.connectorKind = connectorKind
        self.modelID = modelID
        self.providerRoute = providerRoute
    }
}

struct MailboxNewConversationModelOption: Equatable {
    let selection: MailboxNewConversationSelection
    let title: String
    let isPreferred: Bool
    let unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }
}

enum MailboxNewConversationModelCatalog {
    static func options(
        selectedKind: AITextProviderKind,
        selectionResolver: (AITextProviderKind) throws -> AITextGenerationSelection,
        availabilityResolver: (AITextProviderKind) -> AITextProviderAvailability
    ) -> [MailboxNewConversationModelOption] {
        AITextProviderKind.allCases.map { kind in
            let resolvedSelection: AITextGenerationSelection?
            let selectionFailure: String?
            do {
                resolvedSelection = try selectionResolver(kind)
                selectionFailure = nil
            } catch {
                resolvedSelection = nil
                selectionFailure = error.localizedDescription
            }
            // The current CLI adapters intentionally run their verified
            // defaults and do not expose a model catalog. Ignore any legacy
            // free-form model preference for those connectors instead of
            // presenting a choice the adapter cannot honor.
            let modelID = kind == .openAICompatible
                ? resolvedSelection?.modelID
                : nil
            let selection = MailboxNewConversationSelection(
                connectorKind: kind,
                modelID: modelID
            )
            let sourceTitle: String
            switch kind {
            case .codexCLI: sourceTitle = "Codex CLI"
            case .claudeCodeCLI: sourceTitle = "Claude Code"
            case .openAICompatible: sourceTitle = "OpenAI API"
            }
            let modelTitle = selection.modelID ?? "默认模型"
            let availabilityFailure: String?
            switch availabilityResolver(kind) {
            case .ready:
                availabilityFailure = nil
            case let .unavailable(message):
                availabilityFailure = message
            }
            let unavailableReason = selectionFailure ?? availabilityFailure
            return MailboxNewConversationModelOption(
                selection: selection,
                title: "\(sourceTitle) · \(modelTitle)"
                    + (unavailableReason == nil ? "" : " · 未连接"),
                isPreferred: kind == selectedKind,
                unavailableReason: unavailableReason
            )
        }
    }

    static func liveOptions() -> [MailboxNewConversationModelOption] {
        let legacyOptions = options(
            selectedKind: AITextConnectorSelectionStore.shared.selectedKind,
            selectionResolver: {
                try AITextGenerationPreferenceStore.shared.requestSelection(
                    connectorKind: $0
                )
            },
            availabilityResolver: {
                AITextConnectorRegistry.shared.availability(for: $0)
            }
        )
        let catalogStore = AIProviderProfileCatalogStore.shared
        let catalog: AIProviderProfileCatalog
        do {
            catalog = try catalogStore.loadMigratingLegacyOpenAICompatibleIfNeeded()
        } catch {
            // Retain the old three-connector picker if a catalog cannot be
            // read. It has no route reference, so it cannot accidentally
            // claim to represent an unavailable dynamic Provider.
            return legacyOptions
        }

        let mailboxBinding = catalog.binding(for: .mailbox)
        let selectedGenericRoute: AIProviderRouteReference?
        do {
            selectedGenericRoute = try AITextConnectorSelectionStore.shared
                .selectedProviderRouteReference(catalogStore: catalogStore)
        } catch {
            selectedGenericRoute = nil
        }
        var routeOptions: [MailboxNewConversationModelOption] = []
        for profile in catalog.profiles where profile.isEnabled {
            for route in profile.routes where route.isEnabled
                    && route.adapter == .openAIChatCompletions
                    && route.hasSelectedModel
                    && route.capabilities.contains(.textGeneration)
                    && route.capabilities.contains(.streamingText) {
                guard let reference = profile.reference(for: route.id),
                      let modelID = route.modelID else {
                    continue
                }
                let unavailableReason: String?
                do {
                    _ = try catalogStore.resolve(reference)
                    unavailableReason = nil
                } catch {
                    unavailableReason = "该 Provider 模型路由当前不可用"
                }
                let isMailboxBinding = mailboxBinding?.profileID == profile.id
                    && mailboxBinding?.routeID == route.id
                let isPreferred = isMailboxBinding
                    || (mailboxBinding == nil && selectedGenericRoute == reference)
                routeOptions.append(MailboxNewConversationModelOption(
                    selection: MailboxNewConversationSelection(
                        connectorKind: .openAICompatible,
                        modelID: modelID,
                        providerRoute: reference
                    ),
                    title: "\(profile.displayName) · \(route.displayName) · \(modelID)"
                        + (unavailableReason == nil ? "" : " · 未连接"),
                    isPreferred: isPreferred,
                    unavailableReason: unavailableReason
                ))
            }
        }

        guard !routeOptions.isEmpty else { return legacyOptions }
        // Catalog-backed API routes replace the singleton generic option. The
        // CLI options stay available and continue to use their own adapters.
        return legacyOptions.filter {
            $0.selection.connectorKind != .openAICompatible
        } + routeOptions
    }
}

/// Persisted source identity contains routing metadata, not credentials.
/// Names supplied by MCP/HTTP clients are display-only and are not trust proof.
struct MailboxSource: Codable, Equatable {
    let kind: MailboxSourceKind
    let displayName: String
    let identifier: String?
    let model: String?
    /// Non-secret provider/model identity frozen when the conversation starts.
    /// This remains optional so schema-v1 Mailbox documents, which predate the
    /// profile catalog, decode without rewriting their historical source.
    let providerRoute: AIProviderRouteReference?
    let replyCapability: MailboxReplyCapability

    init(kind: MailboxSourceKind,
         displayName: String,
         identifier: String? = nil,
         model: String? = nil,
         providerRoute: AIProviderRouteReference? = nil,
         replyCapability: MailboxReplyCapability) {
        self.kind = kind
        self.displayName = displayName
        self.identifier = identifier
        self.model = model
        self.providerRoute = providerRoute
        self.replyCapability = replyCapability
    }

    static func codexCLI(model: String? = nil) -> MailboxSource {
        MailboxSource(
            kind: .codexCLI,
            displayName: "Codex",
            identifier: "builtin.codex-cli",
            model: model,
            replyCapability: .aiContinuation
        )
    }

    static func claudeCodeCLI(model: String? = nil) -> MailboxSource {
        MailboxSource(
            kind: .claudeCodeCLI,
            displayName: "Claude Code",
            identifier: "builtin.claude-code-cli",
            model: model,
            replyCapability: .aiContinuation
        )
    }

    static func openAICompatible(identifier: String? = nil,
                                 model: String? = nil,
                                 displayName: String = "OpenAI API",
                                 providerRoute: AIProviderRouteReference? = nil)
        -> MailboxSource {
        MailboxSource(
            kind: .openAICompatible,
            displayName: displayName,
            identifier: identifier,
            model: model,
            providerRoute: providerRoute,
            replyCapability: .aiContinuation
        )
    }

    static func mcp(client: String) -> MailboxSource {
        MailboxSource(
            kind: .mcp,
            displayName: client,
            identifier: client,
            replyCapability: .localNotesOnly
        )
    }

    static func http(source: String) -> MailboxSource {
        MailboxSource(
            kind: .http,
            displayName: source,
            identifier: source,
            replyCapability: .localNotesOnly
        )
    }
}

enum MailboxGenerationPhase: String, Codable {
    case generating
    case succeeded
    case failed
}

/// Only the most recent generation is attached to a thread. Its UUID is a
/// tombstone boundary: late callbacks must present the exact current UUID.
/// A `.generating` value also reserves one durable message slot for the
/// terminal assistant response; ordinary mutations cannot consume that slot.
struct MailboxGeneration: Identifiable, Codable, Equatable {
    let id: UUID
    let phase: MailboxGenerationPhase
    /// Frozen response format for this turn. Optional so Mailbox files written
    /// before format-aware continuations remain decodable.
    let expectedFormat: AITextContentFormat?
    let startedAt: Date
    let finishedAt: Date?
    let failureMessage: String?

    static func generating(id: UUID = UUID(),
                           format: AITextContentFormat = .plain,
                           at date: Date = Date()) -> MailboxGeneration {
        MailboxGeneration(
            id: id,
            phase: .generating,
            expectedFormat: format,
            startedAt: date,
            finishedAt: nil,
            failureMessage: nil
        )
    }

    func succeeding(at date: Date) -> MailboxGeneration {
        MailboxGeneration(
            id: id,
            phase: .succeeded,
            expectedFormat: expectedFormat,
            startedAt: startedAt,
            finishedAt: date,
            failureMessage: nil
        )
    }

    func failing(message: String, at date: Date) -> MailboxGeneration {
        MailboxGeneration(
            id: id,
            phase: .failed,
            expectedFormat: expectedFormat,
            startedAt: startedAt,
            finishedAt: date,
            failureMessage: message
        )
    }
}

struct MailboxThread: Identifiable, Codable, Equatable {
    let id: UUID
    /// Monotonically assigned and never derived from the array index.
    let sequence: Int
    var title: String?
    let source: MailboxSource
    var messages: [MailboxMessage]
    var generation: MailboxGeneration?
    /// Present only when a one-way inbound message needs, or has received, a
    /// local Buffer review decision. Older Mailbox files decode this as nil.
    var review: MailboxReview? = nil
    var unread: Bool
    let createdAt: Date
    var updatedAt: Date

    var sequenceLabel: String {
        String(format: "#%02d", sequence)
    }

    var preview: String? {
        previewMessage?.body
    }

    var previewMessage: MailboxMessage? {
        messages.reversed().first(where: { $0.kind != .status })
            ?? messages.last
    }
}

/// Process-local output for an active provider generation. It is deliberately
/// separate from `MailboxThread.messages`: previews are display state, never
/// durable conversation history and never input to a later continuation.
struct MailboxGenerationPreview: Equatable {
    let threadID: UUID
    let generationID: UUID
    let message: MailboxMessage
}

/// A generation handle is intentionally small and safe to retain in provider
/// callbacks. The store accepts a completion only while both IDs are current.
struct MailboxGenerationHandle: Equatable {
    let threadID: UUID
    let generationID: UUID
    let sequence: Int
}

struct MailboxStoreSnapshot: Equatable {
    let revision: UInt64
    /// Newest activity first; persisted order is not an API contract.
    let threads: [MailboxThread]
    /// Runtime UI selection shared by the standalone and Settings panes. It is
    /// intentionally not written into the content-bearing JSON document.
    let selectedThreadID: UUID?
    let persistence: MailboxPersistenceAvailability
    let generationPreviews: [UUID: MailboxGenerationPreview]

    init(revision: UInt64,
         threads: [MailboxThread],
         selectedThreadID: UUID?,
         persistence: MailboxPersistenceAvailability,
         generationPreviews: [UUID: MailboxGenerationPreview] = [:]) {
        self.revision = revision
        self.threads = threads
        self.selectedThreadID = selectedThreadID
        self.persistence = persistence
        self.generationPreviews = generationPreviews
    }

    var unreadCount: Int {
        threads.reduce(0) { $0 + ($1.unread ? 1 : 0) }
    }

    func thread(id: UUID) -> MailboxThread? {
        threads.first(where: { $0.id == id })
    }

    func generationPreview(threadID: UUID) -> MailboxGenerationPreview? {
        generationPreviews[threadID]
    }

    var latestUnreadThreadID: UUID? {
        threads.first(where: \.unread)?.id
    }
}

enum MailboxStoreChange: Equatable {
    case initial
    case contentChanged
    case generationProgressed(threadID: UUID)
    case completedMessage(threadID: UUID)
    case generationFailed(threadID: UUID)
    case unreadChanged
    case selectionChanged
}

struct MailboxStoreEvent: Equatable {
    let change: MailboxStoreChange
    let snapshot: MailboxStoreSnapshot
}

enum MailboxPersistenceAvailability: Equatable {
    case available
    case unavailable(String)
}
