import Darwin
import Foundation

enum MailboxStoreError: LocalizedError, Equatable {
    case unsafePath
    case invalidPermissions
    case unreadable
    case corruptDocument
    case unsupportedSchema
    case oversized
    case capacityExceeded
    case invalidSource
    case invalidMessage
    case missingThread
    case generationAlreadyRunning
    case staleGeneration
    case continuationUnavailable
    case reviewUnavailable
    case reviewAlreadyResolved
    case persistenceUnavailable

    var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "Mailbox 存储路径不安全"
        case .invalidPermissions:
            return "Mailbox 存储权限不安全"
        case .unreadable:
            return "无法读取或保存 Mailbox"
        case .corruptDocument:
            return "Mailbox 数据文件已损坏"
        case .unsupportedSchema:
            return "Mailbox 数据版本不受支持"
        case .oversized:
            return "Mailbox 数据超过容量限制"
        case .capacityExceeded:
            return "Mailbox 已达到会话或消息数量上限"
        case .invalidSource:
            return "Mailbox 来源信息无效"
        case .invalidMessage:
            return "Mailbox 消息无效"
        case .missingThread:
            return "Mailbox 会话不存在"
        case .generationAlreadyRunning:
            return "Mailbox 会话正在生成"
        case .staleGeneration:
            return "Mailbox 生成任务已过期"
        case .continuationUnavailable:
            return "该来源只支持本地备注"
        case .reviewUnavailable:
            return "该会话没有可审核的外部消息"
        case .reviewAlreadyResolved:
            return "该外部消息已经完成审核"
        case .persistenceUnavailable:
            return "Mailbox 本地存储当前不可用"
        }
    }
}

struct MailboxStoreLimits: Equatable {
    var maximumThreads: Int
    var maximumMessagesPerThread: Int
    var maximumMessageCharacters: Int
    var maximumFileBytes: Int

    static let standard = MailboxStoreLimits(
        maximumThreads: 200,
        maximumMessagesPerThread: 200,
        maximumMessageCharacters: 1_048_576,
        maximumFileBytes: 16 * 1_048_576
    )
}

final class MailboxStoreObservation {
    fileprivate let id: UUID
    fileprivate weak var store: MailboxStore?

    fileprivate init(id: UUID, store: MailboxStore) {
        self.id = id
        self.store = store
    }

    func cancel() {
        store?.removeObserver(id: id)
        store = nil
    }

    deinit { cancel() }
}

/// Thread-safe, content-bearing storage for Mailbox only. Buffer blocks and
/// delivery history never enter this document.
///
/// Mutations are serialized under a private lock and persisted before they
/// become visible. Observer callbacks are delivered on the main thread and
/// outside the lock, so multiple views may observe and cancel independently.
final class MailboxStore {
    typealias Observer = (MailboxStoreEvent) -> Void

    private struct Document: Codable {
        var schemaVersion: Int
        var nextSequence: Int
        var threads: [MailboxThread]
    }

    /// A provider snapshot is intentionally process-local. It is projected
    /// into `MailboxStoreSnapshot` so an open Mailbox can render live output,
    /// but only the validated terminal response is written to mailbox.json.
    private struct StreamingPreview {
        let threadID: UUID
        let generationID: UUID
        var message: MailboxMessage
    }

    private static let schemaVersion = 1
    private static let temporaryPrefix = ".mailbox."
    private static let temporarySuffix = ".tmp"
    private static let maximumTitleCharacters = 256
    private static let maximumSourceFieldCharacters = 512
    private static let maximumAuthorCharacters = 128
    private static let maximumFailureCharacters = 2_048

    static let shared: MailboxStore = {
        do {
            return try MailboxStore()
        } catch {
            IMELog.write("mailbox persistence unavailable kind=initialization")
            return MailboxStore(unavailableBecause: error)
        }
    }()

    let storageDirectoryURL: URL
    let storageURL: URL
    let limits: MailboxStoreLimits

    private let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let dateProvider: () -> Date
    private let lock = NSLock()
    private var document: Document
    private var revision: UInt64 = 0
    private var observers: [UUID: Observer] = [:]
    private var streamingPreviews: [UUID: StreamingPreview] = [:]
    private var availability: MailboxPersistenceAvailability
    private var selectedThreadID: UUID?

    init(storageRoot: URL? = nil,
         fileManager: FileManager = .default,
         limits: MailboxStoreLimits = .standard,
         dateProvider: @escaping () -> Date = Date.init) throws {
        guard limits.maximumThreads > 0,
              limits.maximumMessagesPerThread > 0,
              limits.maximumMessageCharacters > 0,
              limits.maximumFileBytes > 0 else {
            throw MailboxStoreError.capacityExceeded
        }
        let root = Self.resolveStorageRoot(storageRoot, fileManager: fileManager)
        rootDirectoryURL = root
        storageDirectoryURL = root.appendingPathComponent(
            "mailbox",
            isDirectory: true
        )
        storageURL = storageDirectoryURL.appendingPathComponent(
            "mailbox.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        self.limits = limits
        self.dateProvider = dateProvider
        availability = .available
        selectedThreadID = nil

        var loaded = try Self.load(
            rootDirectoryURL: rootDirectoryURL,
            storageDirectoryURL: storageDirectoryURL,
            storageURL: storageURL,
            fileManager: fileManager,
            limits: limits
        )
        let recoveryDate = dateProvider()
        let recovered = Self.failInterruptedGenerations(
            in: &loaded,
            at: recoveryDate
        )
        try Self.validate(loaded, limits: limits)
        document = loaded
        if recovered {
            try persist(loaded)
        }
    }

    private init(unavailableBecause error: Error) {
        let fileManager = FileManager.default
        let root = Self.resolveStorageRoot(nil, fileManager: fileManager)
        rootDirectoryURL = root
        storageDirectoryURL = root.appendingPathComponent(
            "mailbox",
            isDirectory: true
        )
        storageURL = storageDirectoryURL.appendingPathComponent(
            "mailbox.json",
            isDirectory: false
        )
        self.fileManager = fileManager
        limits = .standard
        dateProvider = Date.init
        document = Self.emptyDocument()
        availability = .unavailable(
            (error as? LocalizedError)?.errorDescription
                ?? "Mailbox 本地存储不可用"
        )
        selectedThreadID = nil
    }

    var snapshot: MailboxStoreSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    func thread(id: UUID) -> MailboxThread? {
        lock.lock()
        defer { lock.unlock() }
        return document.threads.first(where: { $0.id == id })
    }

    @discardableResult
    func observe(deliverInitial: Bool = true,
                 _ observer: @escaping Observer) -> MailboxStoreObservation {
        let id = UUID()
        let initial: MailboxStoreEvent?
        lock.lock()
        observers[id] = observer
        initial = deliverInitial
            ? MailboxStoreEvent(change: .initial,
                                snapshot: makeSnapshotLocked())
            : nil
        lock.unlock()
        if let initial {
            Self.deliver(initial, to: [observer])
        }
        return MailboxStoreObservation(id: id, store: self)
    }

    /// Shares navigation between the standalone Mailbox and the Settings pane
    /// without turning a UI selection into durable message history.
    @discardableResult
    func selectThread(id: UUID?) -> Bool {
        var event: MailboxStoreEvent?
        var callbacks: [Observer] = []
        lock.lock()
        let validID = id.flatMap { requested in
            document.threads.contains(where: { $0.id == requested })
                ? requested
                : nil
        }
        if selectedThreadID != validID {
            selectedThreadID = validID
            revision &+= 1
            event = MailboxStoreEvent(
                change: .selectionChanged,
                snapshot: makeSnapshotLocked()
            )
            callbacks = Array(observers.values)
        }
        lock.unlock()
        if let event {
            Self.deliver(event, to: callbacks)
            return true
        }
        return false
    }

    /// Opening Mailbox should land on new work first. With no unread work it
    /// preserves a valid current selection, then falls back to the newest
    /// conversation.
    @discardableResult
    func selectLatestUnreadOrMostRecent() -> UUID? {
        let target: UUID?
        lock.lock()
        let sorted = sortedThreadsLocked()
        target = sorted.first(where: \.unread)?.id
            ?? selectedThreadID.flatMap { selected in
                sorted.contains(where: { $0.id == selected }) ? selected : nil
            }
            ?? sorted.first?.id
        lock.unlock()
        _ = selectThread(id: target)
        return target
    }

    /// Starts an AI conversation with the Buffer text as the first user turn.
    /// The caller retains the returned handle until the provider finishes.
    @discardableResult
    func beginAIConversation(source: MailboxSource,
                             title: String? = nil,
                             prompt: String,
                             author: String = "你",
                             format: AITextContentFormat = .plain) throws
        -> MailboxGenerationHandle {
        guard source.replyCapability == .aiContinuation,
              source.kind.isAIConnector else {
            throw MailboxStoreError.continuationUnavailable
        }
        let now = dateProvider()
        let generation = MailboxGeneration.generating(format: format, at: now)
        let message = MailboxMessage(
            role: .user,
            author: author,
            body: prompt,
            createdAt: now
        )
        let threadID = UUID()
        return try mutate { candidate in
            guard candidate.threads.count < limits.maximumThreads else {
                throw MailboxStoreError.capacityExceeded
            }
            // The generation is durable before the provider starts, so admit
            // it only when both the user turn and its terminal response fit.
            // `.generating` keeps the second slot reserved across later
            // mutations until completion or failure releases it.
            guard limits.maximumMessagesPerThread >= 2 else {
                throw MailboxStoreError.capacityExceeded
            }
            guard candidate.nextSequence > 0,
                  candidate.nextSequence < Int.max else {
                throw MailboxStoreError.capacityExceeded
            }
            let sequence = candidate.nextSequence
            let thread = MailboxThread(
                id: threadID,
                sequence: sequence,
                title: Self.normalizedOptional(title),
                source: source,
                messages: [message],
                generation: generation,
                unread: false,
                createdAt: now,
                updatedAt: now
            )
            candidate.threads.append(thread)
            candidate.nextSequence += 1
            return MailboxGenerationHandle(
                threadID: thread.id,
                generationID: generation.id,
                sequence: sequence
            )
        }
    }

    /// Creates a locally retained one-way push. Its composer supports notes,
    /// not an invented HTTP/MCP response channel.
    @discardableResult
    func createInboundThread(source: MailboxSource,
                             title: String? = nil,
                             body: String,
                             format: AITextContentFormat = .plain,
                             author: String? = nil) throws -> MailboxThread {
        guard source.replyCapability == .localNotesOnly,
              !source.kind.isAIConnector else {
            throw MailboxStoreError.invalidSource
        }
        let now = dateProvider()
        let threadID = UUID()
        let message = MailboxMessage(
            role: .inbound,
            format: format,
            author: author ?? source.displayName,
            body: body,
            createdAt: now
        )
        return try mutate(change: .completedMessage(threadID: threadID)) { candidate in
            guard candidate.threads.count < limits.maximumThreads,
                  candidate.nextSequence > 0,
                  candidate.nextSequence < Int.max else {
                throw MailboxStoreError.capacityExceeded
            }
            let thread = MailboxThread(
                id: threadID,
                sequence: candidate.nextSequence,
                title: Self.normalizedOptional(title),
                source: source,
                messages: [message],
                generation: nil,
                review: MailboxReview(
                    messageID: message.id,
                    state: .pending,
                    resolvedAt: nil
                ),
                unread: true,
                createdAt: now,
                updatedAt: now
            )
            candidate.threads.append(thread)
            candidate.nextSequence += 1
            return thread
        }
    }

    /// Adds another one-way message to an existing source thread.
    @discardableResult
    func appendInbound(threadID: UUID,
                       body: String,
                       format: AITextContentFormat = .plain,
                       author: String? = nil) throws -> UUID {
        let now = dateProvider()
        return try mutate(change: .completedMessage(threadID: threadID)) { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            guard Self.messageCapacityAllows(
                appending: 1,
                to: candidate.threads[index],
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let message = MailboxMessage(
                role: .inbound,
                format: format,
                author: author ?? candidate.threads[index].source.displayName,
                body: body,
                createdAt: now
            )
            candidate.threads[index].messages.append(message)
            candidate.threads[index].unread = true
            candidate.threads[index].updatedAt = now
            return message.id
        }
    }

    /// Persists a private annotation. It never changes generation state and
    /// never implies that text was sent to the source.
    @discardableResult
    func addLocalNote(threadID: UUID,
                      body: String,
                      author: String = "你") throws -> UUID {
        let now = dateProvider()
        return try mutate { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            guard Self.messageCapacityAllows(
                appending: 1,
                to: candidate.threads[index],
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let message = MailboxMessage(
                role: .user,
                kind: .localNote,
                author: author,
                body: body,
                createdAt: now
            )
            candidate.threads[index].messages.append(message)
            candidate.threads[index].updatedAt = now
            return message.id
        }
    }

    /// Appends the user turn and establishes a new tombstone boundary. The
    /// actual provider call remains outside this persistence layer.
    @discardableResult
    func beginAIReply(threadID: UUID,
                      body: String,
                      author: String = "你",
                      format: AITextContentFormat = .plain) throws
        -> MailboxGenerationHandle {
        let now = dateProvider()
        let generation = MailboxGeneration.generating(format: format, at: now)
        return try mutate { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            let thread = candidate.threads[index]
            guard thread.source.replyCapability == .aiContinuation,
                  thread.source.kind.isAIConnector else {
                throw MailboxStoreError.continuationUnavailable
            }
            if thread.generation?.phase == .generating {
                throw MailboxStoreError.generationAlreadyRunning
            }
            // One atomic admission decision covers both durable turns. Once
            // the generation is installed below, its `.generating` phase is
            // the reservation that prevents another mutation taking the
            // assistant's slot.
            guard Self.messageCapacityAllows(
                appending: 2,
                to: thread,
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let message = MailboxMessage(
                role: .user,
                author: author,
                body: body,
                createdAt: now
            )
            candidate.threads[index].messages.append(message)
            candidate.threads[index].generation = generation
            candidate.threads[index].unread = false
            candidate.threads[index].updatedAt = now
            return MailboxGenerationHandle(
                threadID: threadID,
                generationID: generation.id,
                sequence: thread.sequence
            )
        }
    }

    /// Publishes a stable, in-memory message for an active generation. The
    /// preview never marks the thread unread and never reaches durable history;
    /// completion replaces it atomically with the validated terminal body.
    @discardableResult
    func updateGenerationPreview(
        _ handle: MailboxGenerationHandle,
        response: String,
        author: String? = nil,
        format: AITextContentFormat = .plain
    ) throws -> UUID {
        var snapshot: MailboxStoreSnapshot!
        var callbacks: [Observer] = []
        let messageID: UUID

        lock.lock()
        do {
            guard case .available = availability else {
                throw MailboxStoreError.persistenceUnavailable
            }
            let index = try Self.currentGenerationIndex(handle, in: document)
            let existing = streamingPreviews[handle.generationID]
            guard Self.messageCapacityAllows(
                appending: 0,
                to: document.threads[index],
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let message = MailboxMessage(
                id: existing?.message.id ?? UUID(),
                role: .inbound,
                format: format,
                author: author ?? document.threads[index].source.displayName,
                body: response,
                createdAt: existing?.message.createdAt ?? dateProvider()
            )
            guard Self.validMessage(message, limits: limits) else {
                throw MailboxStoreError.invalidMessage
            }
            if existing?.message == message {
                lock.unlock()
                return message.id
            }
            streamingPreviews[handle.generationID] = StreamingPreview(
                threadID: handle.threadID,
                generationID: handle.generationID,
                message: message
            )
            messageID = message.id
            revision &+= 1
            snapshot = makeSnapshotLocked()
            callbacks = Array(observers.values)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        Self.deliver(
            MailboxStoreEvent(
                change: .generationProgressed(threadID: handle.threadID),
                snapshot: snapshot
            ),
            to: callbacks
        )
        return messageID
    }

    /// Accepts only a complete provider body for the exact current generation.
    /// Any process-local preview keeps its stable message identity while this
    /// terminal response becomes the first durable assistant message.
    @discardableResult
    func completeGeneration(_ handle: MailboxGenerationHandle,
                            response: String,
                            author: String? = nil,
                            format: AITextContentFormat = .plain) throws -> UUID {
        let now = dateProvider()
        return try mutate(change: .completedMessage(threadID: handle.threadID)) { candidate in
            let index = try Self.currentGenerationIndex(
                handle,
                in: candidate
            )
            // Completion consumes the slot already reserved by `.generating`;
            // do not count that reservation a second time here.
            guard Self.messageCapacityAllows(
                appending: 1,
                to: candidate.threads[index],
                limits: limits,
                preserveActiveGenerationReservation: false
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let preview = streamingPreviews[handle.generationID]
            let message = MailboxMessage(
                id: preview?.message.id ?? UUID(),
                role: .inbound,
                format: format,
                author: author ?? candidate.threads[index].source.displayName,
                body: response,
                createdAt: preview?.message.createdAt ?? now
            )
            let generation = candidate.threads[index].generation!
            candidate.threads[index].messages.append(message)
            candidate.threads[index].generation = generation.succeeding(at: now)
            candidate.threads[index].unread = true
            candidate.threads[index].updatedAt = now
            return message.id
        }
    }

    func failGeneration(_ handle: MailboxGenerationHandle,
                        message: String) throws {
        let now = dateProvider()
        try mutate(change: .generationFailed(threadID: handle.threadID)) { candidate in
            let index = try Self.currentGenerationIndex(
                handle,
                in: candidate
            )
            let generation = candidate.threads[index].generation!
            candidate.threads[index].generation = generation.failing(
                message: message,
                at: now
            )
            candidate.threads[index].unread = true
            candidate.threads[index].updatedAt = now
        }
    }

    @discardableResult
    func appendSystemMessage(threadID: UUID,
                             body: String) throws -> UUID {
        let now = dateProvider()
        return try mutate { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            guard Self.messageCapacityAllows(
                appending: 1,
                to: candidate.threads[index],
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }
            let message = MailboxMessage(
                role: .system,
                kind: .status,
                author: "Mailbox",
                body: body,
                createdAt: now
            )
            candidate.threads[index].messages.append(message)
            candidate.threads[index].updatedAt = now
            return message.id
        }
    }

    /// Commits the durable review decision and its visible system status in a
    /// single atomic document write. A repeated/stale UI action cannot append a
    /// second status or stage the same review again.
    @discardableResult
    func resolveReview(threadID: UUID,
                       decision: MailboxReviewDecision) throws -> UUID {
        let now = dateProvider()
        return try mutate { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            guard var review = candidate.threads[index].review else {
                throw MailboxStoreError.reviewUnavailable
            }
            guard review.state == .pending else {
                throw MailboxStoreError.reviewAlreadyResolved
            }
            guard Self.messageCapacityAllows(
                appending: 1,
                to: candidate.threads[index],
                limits: limits
            ) else {
                throw MailboxStoreError.capacityExceeded
            }

            let state: MailboxReviewState
            let statusBody: String
            switch decision {
            case .accept:
                state = .accepted
                statusBody = "已接受并加入 Buffer。"
            case .reject:
                state = .rejected
                statusBody = "已拒绝该外部推送。"
            }
            review.state = state
            review.resolvedAt = now
            let message = MailboxMessage(
                role: .system,
                kind: .status,
                author: "Mailbox",
                body: statusBody,
                createdAt: now
            )
            candidate.threads[index].review = review
            candidate.threads[index].messages.append(message)
            candidate.threads[index].updatedAt = now
            return message.id
        }
    }

    func markRead(threadID: UUID) throws {
        try mutate(change: .unreadChanged) { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == threadID }
            ) else {
                throw MailboxStoreError.missingThread
            }
            candidate.threads[index].unread = false
        }
    }

    func markAllRead() throws {
        try mutate(change: .unreadChanged) { candidate in
            for index in candidate.threads.indices {
                candidate.threads[index].unread = false
            }
        }
    }

    func deleteThread(id: UUID) throws {
        try mutate { candidate in
            guard let index = candidate.threads.firstIndex(
                where: { $0.id == id }
            ) else {
                throw MailboxStoreError.missingThread
            }
            candidate.threads.remove(at: index)
        }
    }

    /// Removes all Mailbox conversations but preserves the monotonic sequence
    /// counter so a deleted #03 is never silently reused as a different thread.
    func deleteAllThreads() throws {
        try mutate { candidate in
            candidate.threads.removeAll(keepingCapacity: false)
        }
    }

    fileprivate func removeObserver(id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    private func mutate<Result>(
        change: MailboxStoreChange = .contentChanged,
        _ operation: (inout Document) throws -> Result
    ) throws -> Result {
        var result: Result!
        var snapshot: MailboxStoreSnapshot!
        var callbacks: [Observer] = []

        lock.lock()
        do {
            guard case .available = availability else {
                throw MailboxStoreError.persistenceUnavailable
            }
            var candidate = document
            result = try operation(&candidate)
            try Self.validate(candidate, limits: limits)
            try persist(candidate)
            document = candidate
            pruneStreamingPreviewsLocked()
            if let selectedThreadID,
               !candidate.threads.contains(where: { $0.id == selectedThreadID }) {
                self.selectedThreadID = nil
            }
            revision &+= 1
            snapshot = makeSnapshotLocked()
            callbacks = Array(observers.values)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        Self.deliver(MailboxStoreEvent(change: change, snapshot: snapshot),
                     to: callbacks)
        return result
    }

    private func makeSnapshotLocked() -> MailboxStoreSnapshot {
        let previews = streamingPreviews.values.reduce(
            into: [UUID: MailboxGenerationPreview]()
        ) { result, preview in
            guard document.threads.contains(where: { thread in
                thread.id == preview.threadID
                    && thread.generation?.id == preview.generationID
                    && thread.generation?.phase == .generating
            }) else {
                return
            }
            result[preview.threadID] = MailboxGenerationPreview(
                threadID: preview.threadID,
                generationID: preview.generationID,
                message: preview.message
            )
        }
        return MailboxStoreSnapshot(
            revision: revision,
            threads: sortedThreadsLocked(),
            selectedThreadID: selectedThreadID,
            persistence: availability,
            generationPreviews: previews
        )
    }

    private func pruneStreamingPreviewsLocked() {
        streamingPreviews = streamingPreviews.filter { generationID, preview in
            document.threads.contains { thread in
                thread.id == preview.threadID
                    && thread.generation?.id == generationID
                    && thread.generation?.phase == .generating
            }
        }
    }

    private func sortedThreadsLocked() -> [MailboxThread] {
        document.threads.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.sequence > $1.sequence
        }
    }

    private static func deliver(_ event: MailboxStoreEvent,
                                to callbacks: [Observer]) {
        guard !callbacks.isEmpty else { return }
        let delivery = {
            for callback in callbacks {
                callback(event)
            }
        }
        if Thread.isMainThread {
            delivery()
        } else {
            DispatchQueue.main.async(execute: delivery)
        }
    }

    private static func currentGenerationIndex(
        _ handle: MailboxGenerationHandle,
        in document: Document
    ) throws -> Int {
        guard let index = document.threads.firstIndex(
            where: { $0.id == handle.threadID }
        ) else {
            throw MailboxStoreError.missingThread
        }
        guard let generation = document.threads[index].generation,
              generation.id == handle.generationID,
              generation.phase == .generating else {
            throw MailboxStoreError.staleGeneration
        }
        return index
    }

    private static func resolveStorageRoot(
        _ storageRoot: URL?,
        fileManager: FileManager
    ) -> URL {
        if let storageRoot {
            return storageRoot.standardizedFileURL
        }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["RIMEBUFFER_LOCAL_DATA_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
        }
        if let override = environment["RIMEBUFFER_USER_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .standardizedFileURL
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/\(RimesPaths.directoryName)", isDirectory: true)
            .standardizedFileURL
    }

    private static func emptyDocument() -> Document {
        Document(schemaVersion: schemaVersion, nextSequence: 1, threads: [])
    }

    private static func load(rootDirectoryURL: URL,
                             storageDirectoryURL: URL,
                             storageURL: URL,
                             fileManager: FileManager,
                             limits: MailboxStoreLimits) throws -> Document {
        var fileInfo = stat()
        if lstat(storageURL.path, &fileInfo) != 0 {
            guard errno == ENOENT else {
                throw MailboxStoreError.unreadable
            }
            var directoryInfo = stat()
            if lstat(storageDirectoryURL.path, &directoryInfo) == 0 {
                try validateSharedRootDirectory(rootDirectoryURL)
                try validatePrivateDirectory(storageDirectoryURL)
                try cleanupTemporaryFiles(
                    in: storageDirectoryURL,
                    fileManager: fileManager
                )
            } else if errno != ENOENT {
                throw MailboxStoreError.unreadable
            }
            return emptyDocument()
        }

        try validateSharedRootDirectory(rootDirectoryURL)
        try validatePrivateDirectory(storageDirectoryURL)
        try cleanupTemporaryFiles(
            in: storageDirectoryURL,
            fileManager: fileManager
        )
        let data = try readPrivateFile(at: storageURL, maximumBytes: limits.maximumFileBytes)
        let decoded: Document
        do {
            decoded = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw MailboxStoreError.corruptDocument
        }
        guard decoded.schemaVersion == schemaVersion else {
            throw MailboxStoreError.unsupportedSchema
        }
        try validate(decoded, limits: limits)
        return decoded
    }

    private static func failInterruptedGenerations(
        in document: inout Document,
        at date: Date
    ) -> Bool {
        var changed = false
        for index in document.threads.indices {
            guard let generation = document.threads[index].generation,
                  generation.phase == .generating else { continue }
            document.threads[index].generation = generation.failing(
                message: "应用重启，生成已中断",
                at: date
            )
            document.threads[index].unread = true
            document.threads[index].updatedAt = date
            changed = true
        }
        return changed
    }

    private static func validate(_ document: Document,
                                 limits: MailboxStoreLimits) throws {
        guard document.schemaVersion == schemaVersion else {
            throw MailboxStoreError.unsupportedSchema
        }
        guard document.threads.count <= limits.maximumThreads,
              document.nextSequence > 0 else {
            throw MailboxStoreError.capacityExceeded
        }

        var threadIDs = Set<UUID>()
        var sequences = Set<Int>()
        var messageIDs = Set<UUID>()
        var maximumSequence = 0

        for thread in document.threads {
            guard threadIDs.insert(thread.id).inserted,
                  thread.sequence > 0,
                  sequences.insert(thread.sequence).inserted,
                  Self.messageCapacityAllows(
                    appending: 0,
                    to: thread,
                    limits: limits
                  ),
                  Self.validDate(thread.createdAt),
                  Self.validDate(thread.updatedAt),
                  Self.validOptionalText(thread.title,
                                         maximum: maximumTitleCharacters),
                  Self.validSource(thread.source) else {
                throw MailboxStoreError.corruptDocument
            }
            maximumSequence = max(maximumSequence, thread.sequence)

            if let generation = thread.generation {
                guard Self.validGeneration(generation) else {
                    throw MailboxStoreError.corruptDocument
                }
            }

            if let review = thread.review {
                guard !thread.source.kind.isAIConnector,
                      thread.source.replyCapability == .localNotesOnly,
                      Self.validReview(review, in: thread) else {
                    throw MailboxStoreError.corruptDocument
                }
            }

            for message in thread.messages {
                guard messageIDs.insert(message.id).inserted,
                      Self.validMessage(message, limits: limits) else {
                    throw MailboxStoreError.invalidMessage
                }
            }
        }
        guard document.nextSequence > maximumSequence else {
            throw MailboxStoreError.corruptDocument
        }
    }

    private static func validSource(_ source: MailboxSource) -> Bool {
        guard validRequiredText(source.displayName,
                                maximum: maximumSourceFieldCharacters),
              validOptionalText(source.identifier,
                                maximum: maximumSourceFieldCharacters),
              validOptionalText(source.model,
                                maximum: maximumSourceFieldCharacters) else {
            return false
        }
        if let providerRoute = source.providerRoute {
            // Profile/model route snapshots are meaningful only for the
            // catalog-backed API connector. CLI sources retain their existing
            // process-owned selection and must never acquire a profile route.
            guard source.kind == .openAICompatible,
                  providerRoute.profileRevision > 0 else {
                return false
            }
        }
        if source.kind.isAIConnector {
            return source.replyCapability == .aiContinuation
        }
        return source.replyCapability == .localNotesOnly
    }

    private static func validMessage(_ message: MailboxMessage,
                                     limits: MailboxStoreLimits) -> Bool {
        guard validRequiredText(message.body,
                                maximum: limits.maximumMessageCharacters),
              validOptionalText(message.author,
                                maximum: maximumAuthorCharacters),
              validDate(message.createdAt) else {
            return false
        }
        switch message.kind {
        case .content:
            return message.role != .system
        case .localNote:
            return message.role == .user
        case .status:
            return message.role == .system
        }
    }

    /// A generating thread owns one future durable assistant slot. Every
    /// unrelated append includes that reservation in its capacity decision;
    /// terminal completion explicitly opts out because it consumes the slot.
    private static func messageCapacityAllows(
        appending additionalCount: Int,
        to thread: MailboxThread,
        limits: MailboxStoreLimits,
        preserveActiveGenerationReservation: Bool = true
    ) -> Bool {
        guard additionalCount >= 0,
              thread.messages.count <= limits.maximumMessagesPerThread else {
            return false
        }
        var remaining = limits.maximumMessagesPerThread - thread.messages.count
        if preserveActiveGenerationReservation,
           thread.generation?.phase == .generating {
            guard remaining > 0 else { return false }
            remaining -= 1
        }
        return additionalCount <= remaining
    }

    private static func validGeneration(_ generation: MailboxGeneration) -> Bool {
        guard validDate(generation.startedAt),
              generation.finishedAt.map(validDate) ?? true,
              validOptionalText(generation.failureMessage,
                                maximum: maximumFailureCharacters) else {
            return false
        }
        switch generation.phase {
        case .generating:
            return generation.finishedAt == nil
                && generation.failureMessage == nil
        case .succeeded:
            return generation.finishedAt != nil
                && generation.failureMessage == nil
        case .failed:
            return generation.finishedAt != nil
                && generation.failureMessage.map {
                    validRequiredText($0, maximum: maximumFailureCharacters)
                } == true
        }
    }

    private static func validReview(_ review: MailboxReview,
                                    in thread: MailboxThread) -> Bool {
        guard let reviewedMessage = thread.messages.first(
            where: { $0.id == review.messageID }
        ),
              reviewedMessage.role == .inbound,
              reviewedMessage.kind == .content else {
            return false
        }
        switch review.state {
        case .pending:
            return review.resolvedAt == nil
        case .accepted, .rejected:
            return review.resolvedAt.map(validDate) == true
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
    }

    private static func validRequiredText(_ value: String,
                                          maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= maximum
    }

    private static func validOptionalText(_ value: String?,
                                          maximum: Int) -> Bool {
        guard let value else { return true }
        return validRequiredText(value, maximum: maximum)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func persist(_ value: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw MailboxStoreError.unreadable
        }
        guard data.count <= limits.maximumFileBytes else {
            throw MailboxStoreError.oversized
        }

        try Self.ensureSharedRootDirectory(rootDirectoryURL,
                                           fileManager: fileManager)
        try Self.ensurePrivateDirectory(storageDirectoryURL,
                                        fileManager: fileManager)
        try Self.cleanupTemporaryFiles(in: storageDirectoryURL,
                                       fileManager: fileManager)
        try Self.rejectExistingNonRegularFile(at: storageURL)

        let temporaryURL = storageDirectoryURL.appendingPathComponent(
            "\(Self.temporaryPrefix)\(UUID().uuidString)\(Self.temporarySuffix)",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MailboxStoreError.unreadable
        }
        var shouldUnlink = true
        defer {
            close(descriptor)
            if shouldUnlink { unlink(temporaryURL.path) }
        }

        try Self.writeAll(data, to: descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0,
              rename(temporaryURL.path, storageURL.path) == 0 else {
            throw MailboxStoreError.unreadable
        }
        shouldUnlink = false
        // rename already made the candidate document authoritative. If this
        // filesystem refuses a directory fsync, reporting failure would leave
        // memory on the previous document while disk contains the new one.
        // Keep those views coherent and record the weaker crash-durability
        // guarantee without exposing any mailbox content in logs.
        do {
            try Self.fsyncDirectory(storageDirectoryURL)
        } catch {
            IMELog.write("mailbox directory sync unavailable after commit")
        }
    }

    private static func readPrivateFile(at url: URL,
                                        maximumBytes: Int) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == geteuid() else {
            throw MailboxStoreError.unsafePath
        }
        guard (before.st_mode & 0o777) == 0o600 else {
            throw MailboxStoreError.invalidPermissions
        }
        guard before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw MailboxStoreError.oversized
        }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MailboxStoreError.unreadable
        }
        defer { close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino else {
            throw MailboxStoreError.unsafePath
        }

        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MailboxStoreError.unreadable
            }
            data.append(buffer, count: count)
            guard data.count <= maximumBytes else {
                throw MailboxStoreError.oversized
            }
        }
        return data
    }

    private static func writeAll(_ data: Data,
                                 to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count <= 0 {
                    if errno == EINTR { continue }
                    throw MailboxStoreError.unreadable
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private static func ensureSharedRootDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else {
                throw MailboxStoreError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MailboxStoreError.unreadable
            }
        }
        try validateSharedRootDirectory(url)
    }

    private static func validateSharedRootDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw MailboxStoreError.unsafePath
        }
        let permissions = info.st_mode & 0o777
        guard (permissions & 0o700) == 0o700,
              (permissions & 0o022) == 0 else {
            throw MailboxStoreError.invalidPermissions
        }
    }

    private static func ensurePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw MailboxStoreError.unsafePath
            }
        } else {
            guard errno == ENOENT else {
                throw MailboxStoreError.unreadable
            }
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MailboxStoreError.unreadable
            }
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid() else {
                throw MailboxStoreError.unsafePath
            }
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw MailboxStoreError.invalidPermissions
        }
    }

    private static func validatePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid() else {
            throw MailboxStoreError.unsafePath
        }
        guard (info.st_mode & 0o777) == 0o700 else {
            throw MailboxStoreError.invalidPermissions
        }
    }

    private static func rejectExistingNonRegularFile(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid() else {
                throw MailboxStoreError.unsafePath
            }
        } else if errno != ENOENT {
            throw MailboxStoreError.unreadable
        }
    }

    private static func cleanupTemporaryFiles(
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw MailboxStoreError.unreadable
        }
        for name in names where name.hasPrefix(temporaryPrefix)
                && name.hasSuffix(temporarySuffix) {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o600 else {
                throw MailboxStoreError.unsafePath
            }
            guard unlink(url.path) == 0 else {
                throw MailboxStoreError.unreadable
            }
        }
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MailboxStoreError.unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              fsync(descriptor) == 0 else {
            throw MailboxStoreError.unreadable
        }
    }
}
