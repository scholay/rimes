import CryptoKit
import Foundation

/// A local-first prompt-library workspace. The editable upper rail remains the
/// ordinary BufferModel; only one explicitly selected prompt body can cross the
/// BufferDeliveryCoordinator boundary.
final class MyPromptWorkspace: DerivedBufferWorkspace,
                               DerivedResultSelectionControls {
    static let shared = MyPromptWorkspace()
    static let pluginKey = PluginKey(
        domain: .builtIn,
        rawID: BuiltInPluginID.myPrompt
    )
    static let processorID = "my-prompt"
    static let searchDebounce: TimeInterval = 0.060

    struct Candidate: Equatable {
        let recordID: String
        let title: String
        let snippet: String
        let systemPrompt: String
        let userPrompt: String?
    }

    struct RefreshReport: Equatable {
        let importedCount: Int
        let failedSourceCount: Int
    }

    struct Dependencies {
        let search: (_ query: String, _ limit: Int) throws -> [Candidate]
        let refresh: (
            _ settings: MyPromptPluginSettings,
            _ synchronizeRemoteRepositories: Bool
        ) throws -> RefreshReport
        let markUsed: (_ recordID: String) throws -> Void
        let performBackground: (@escaping () -> Void) -> Void

        static var live: Dependencies {
            MyPromptLiveDependencies.make()
        }
    }

    enum Phase: Equatable {
        case idle
        case waiting
        case searching
        case refreshing
        case ready
        case failed(String)
    }

    struct QuerySignature: Equatable {
        let text: String
        let blockIDs: [UUID]
        let changeCount: Int
        let allowsRemoteMirror: Bool
    }

    private struct PresentedCandidate: Equatable {
        let candidate: Candidate
        let railID: UUID
    }

    private struct DeliveryLease: Equatable {
        let candidate: PresentedCandidate
        let query: QuerySignature
        let includeUserPrompt: Bool
    }

    let workspacePluginKey = MyPromptWorkspace.pluginKey
    let workbenchDisplayName = "My Prompt"

    private let defaults: UserDefaults
    private let sourceModel: BufferModel
    private let selected: () -> Bool
    private let dependencies: Dependencies
    private var observers: [NSObjectProtocol] = []
    private var searchTimer: Timer?
    private var started = false
    private var protectedSession = false
    private var searchSuppressedForPrivacy = false
    private var configurationRefreshScheduled = false
    private var pendingConfigurationFieldIDs = Set<String>()
    private var pendingConfigurationRequiresRefresh = false
    private var refreshRequiredAfterProtection = false
    private var remoteSyncRequiredAfterProtection = false
    private var lifecycleEpoch: UInt64 = 0
    private var searchRevision: UInt64 = 0
    private var refreshRevision: UInt64 = 0
    private var refreshOperations = Set<UInt64>()
    private var generation: UInt64 = 0
    private var stableCandidateIDs: [String: UUID] = [:]
    private var candidates: [PresentedCandidate] = []
    private var selectedPosition = 0
    private var readyQuery: QuerySignature?
    private var deliveryLease: DeliveryLease?
    private var notice: String?
    private(set) var phase: Phase = .idle

    init(
        defaults: UserDefaults = .standard,
        sourceModel: BufferModel = .shared,
        selected: @escaping () -> Bool = {
            BufferPluginSelectionStore.shared.isSelected(
                MyPromptWorkspace.pluginKey
            )
        },
        dependencies: Dependencies = .live
    ) {
        self.defaults = defaults
        self.sourceModel = sourceModel
        self.selected = selected
        self.dependencies = dependencies
    }

    var isSelected: Bool { selected() }

    var isActive: Bool {
        started
            && isSelected
            && sourceModel.active
            && !protectedSession
    }

    var statusText: String {
        if !sourceModel.active { return "请先开启缓冲区" }
        if protectedSession { return "安全输入已开启" }
        switch phase {
        case .idle:
            return "输入关键词查找提示词"
        case .waiting:
            return "等待输入停顿"
        case .searching:
            return "正在本地检索"
        case .refreshing:
            return "正在更新提示词库"
        case .ready:
            if candidates.isEmpty {
                return notice ?? "没有匹配提示词"
            }
            if deliveryLease != nil {
                return "已确认提示词 · Enter 上屏"
            }
            let selection = min(selectedPosition + 1, candidates.count)
            let base = candidates.count > 1
                ? "找到 \(candidates.count) 条 · 已选 \(selection)/\(candidates.count) · ↑↓ 切换"
                : "找到 1 条提示词"
            if let notice, !notice.isEmpty {
                return "\(base) · \(notice)"
            }
            return base
        case let .failed(message):
            return message
        }
    }

    var railSnapshot: TranslationRailSnapshot {
        let railPhase: TranslationRailSnapshot.Phase
        let message: String?
        switch phase {
        case .idle:
            railPhase = .idle
            message = nil
        case .waiting:
            railPhase = .waiting
            message = nil
        case .searching, .refreshing:
            railPhase = .translating
            message = nil
        case .ready:
            railPhase = .ready
            message = candidates.isEmpty ? (notice ?? "没有匹配提示词") : nil
        case let .failed(value):
            railPhase = .failed
            message = value
        }

        let rows = candidates.enumerated().map { position, presented in
            TranslationOutputRow(
                key: stableRowKey(for: presented.candidate.recordID),
                blocks: [
                    TranslationOutputBlock(
                        id: presented.railID,
                        text: Self.presentationText(for: presented.candidate),
                        ordinal: candidates.count > 1 ? position + 1 : nil,
                        selected: phase == .ready
                            && position == selectedPosition
                    ),
                ]
            )
        }
        return TranslationRailSnapshot(
            sourceText: sourceModel.stagedText,
            sourceSelected: sourceModel.allContentSelected,
            outputBlocks: rows.flatMap(\.blocks),
            outputRows: rows.isEmpty ? nil : rows,
            phase: railPhase,
            message: message,
            sourceRole: "搜",
            targetRole: "词",
            sourceEmptyText: "输入关键词查找提示词",
            targetEmptyText: phase == .ready
                ? "没有匹配提示词"
                : "等待检索结果",
            waitingText: "等待输入停顿",
            processingText: phase == .refreshing
                ? "正在更新提示词库"
                : "正在本地检索",
            updatingText: "更新检索结果"
        )
    }

    var ownsResultNavigation: Bool {
        isActive
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .bufferModelDidChange,
            object: sourceModel,
            queue: .main
        ) { [weak self] _ in
            self?.sourceDidChange()
        })
        observers.append(center.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.selectionDidChange()
        })
        observers.append(center.addObserver(
            forName: .pluginConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[
                PluginConfigurationNotificationKey.pluginID
            ] as? String == BuiltInPluginID.myPrompt else {
                return
            }
            self?.scheduleConfigurationChange(
                changedFieldIDs: notification.userInfo?[
                    PluginConfigurationNotificationKey.changedFieldIDs
                ] as? [String]
            )
        })

        let settings = PluginConfigurationCatalog.myPromptSettings(
            defaults: defaults
        )
        beginRefresh(
            settings: settings,
            synchronizeRemoteRepositories: settings.syncRemoteOnStart
        )
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started else { return }
        started = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        configurationRefreshScheduled = false
        pendingConfigurationFieldIDs.removeAll()
        pendingConfigurationRequiresRefresh = false
        refreshRequiredAfterProtection = false
        remoteSyncRequiredAfterProtection = false
        tombstone(clearCandidates: true, nextPhase: .idle)
    }

    func setProtected(_ protected: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard protectedSession != protected else { return }
        protectedSession = protected
        if protected {
            tombstone(clearCandidates: true, nextPhase: .idle)
        } else if refreshRequiredAfterProtection {
            refreshRequiredAfterProtection = false
            let synchronizeRemoteRepositories =
                remoteSyncRequiredAfterProtection
            remoteSyncRequiredAfterProtection = false
            beginRefresh(
                settings: PluginConfigurationCatalog.myPromptSettings(
                    defaults: defaults
                ),
                synchronizeRemoteRepositories:
                    synchronizeRemoteRepositories
            )
        } else if searchSuppressedForPrivacy {
            phase = .idle
            notifyChange()
        } else if !refreshOperations.isEmpty {
            phase = .refreshing
            notifyChange()
        } else if isSelected {
            scheduleSearch()
        }
    }

    func workbenchWillPause() {
        dispatchPrecondition(condition: .onQueue(.main))
        tombstone(clearCandidates: true, nextPhase: .idle)
    }

    @discardableResult
    func requestRefresh() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started,
              !protectedSession,
              refreshOperations.isEmpty,
              phase != .refreshing else {
            return false
        }
        searchSuppressedForPrivacy = false
        beginRefresh(
            settings: PluginConfigurationCatalog.myPromptSettings(
                defaults: defaults
            ),
            synchronizeRemoteRepositories: true
        )
        return true
    }

    @discardableResult
    func moveResultSelection(delta: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ownsResultNavigation else { return false }
        guard phase == .ready,
              deliveryLease == nil,
              candidates.count > 1 else {
            return true
        }
        let next = min(
            max(selectedPosition + delta, 0),
            candidates.count - 1
        )
        selectCandidate(at: next)
        return true
    }

    @discardableResult
    func selectResult(blockID: UUID) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard ownsResultNavigation,
              phase == .ready,
              deliveryLease == nil,
              let position = candidates.firstIndex(where: {
                  $0.railID == blockID
              }) else {
            return false
        }
        selectCandidate(at: position)
        return true
    }

    func fireSearchDebounceForTesting() {
        searchTimer?.fire()
    }

    private func sourceDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        readyQuery = nil
        deliveryLease = nil
        candidates.removeAll(keepingCapacity: true)
        selectedPosition = 0
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        switch sourceModel.lastMutationReason {
        case .pause, .privacyDiscard:
            searchSuppressedForPrivacy = true
        case .transient:
            break
        default:
            searchSuppressedForPrivacy = false
        }
        guard !searchSuppressedForPrivacy else {
            phase = .idle
            notifyChange()
            return
        }
        guard isActive else {
            phase = .idle
            notifyChange()
            return
        }
        guard refreshOperations.isEmpty else {
            phase = .refreshing
            notifyChange()
            return
        }
        scheduleSearch()
    }

    private func selectionDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        lifecycleEpoch &+= 1
        generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        readyQuery = nil
        deliveryLease = nil
        candidates.removeAll(keepingCapacity: true)
        selectedPosition = 0
        notice = nil
        guard isActive else {
            phase = .idle
            notifyChange()
            return
        }
        searchSuppressedForPrivacy = false
        guard refreshOperations.isEmpty else {
            phase = .refreshing
            notifyChange()
            return
        }
        scheduleSearch()
    }

    private func scheduleConfigurationChange(
        changedFieldIDs: [String]?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let knownFieldIDs = Self.configurationFieldIDs
        if let changedFieldIDs, !changedFieldIDs.isEmpty {
            pendingConfigurationFieldIDs.formUnion(changedFieldIDs)
            if !changedFieldIDs.allSatisfy(knownFieldIDs.contains) {
                pendingConfigurationRequiresRefresh = true
            }
        } else {
            // Older or third-party senders might omit field provenance. A
            // complete refresh is the only safe interpretation in that case.
            pendingConfigurationRequiresRefresh = true
        }
        guard !configurationRefreshScheduled else { return }
        configurationRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.configurationRefreshScheduled else { return }
            self.configurationRefreshScheduled = false
            guard self.started else { return }
            let changedFieldIDs = self.pendingConfigurationFieldIDs
            let requiresRefresh = self.pendingConfigurationRequiresRefresh
            self.pendingConfigurationFieldIDs.removeAll()
            self.pendingConfigurationRequiresRefresh = false
            self.configurationDidChange(
                changedFieldIDs: changedFieldIDs,
                requiresRefresh: requiresRefresh
            )
        }
    }

    private func configurationDidChange(
        changedFieldIDs: Set<String>,
        requiresRefresh: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let libraryChanged = changedFieldIDs.contains(
            MyPromptPluginConfigurationFieldID.libraryDirectory
        )
        let remoteRepositoriesChanged = changedFieldIDs.contains(
            MyPromptPluginConfigurationFieldID.remoteRepositories
        )
        if requiresRefresh
            || libraryChanged
            || remoteRepositoriesChanged {
            invalidateForConfigurationChange(clearCandidates: true)
            guard !protectedSession else {
                refreshRequiredAfterProtection = true
                remoteSyncRequiredAfterProtection =
                    remoteSyncRequiredAfterProtection
                    || remoteRepositoriesChanged
                phase = .idle
                notifyChange()
                return
            }
            beginRefresh(
                settings: PluginConfigurationCatalog.myPromptSettings(
                    defaults: defaults
                ),
                synchronizeRemoteRepositories: remoteRepositoriesChanged
            )
            return
        }

        if changedFieldIDs.contains(
            MyPromptPluginConfigurationFieldID.includeUserPrompt
        ) {
            generation &+= 1
            deliveryLease = nil
        }

        if changedFieldIDs.contains(
            MyPromptPluginConfigurationFieldID.resultLimit
        ) {
            invalidateForConfigurationChange(clearCandidates: true)
            if refreshOperations.isEmpty {
                scheduleSearch()
            } else {
                phase = .refreshing
                notifyChange()
            }
            return
        }

        // includeUserPrompt changes affect only delivery composition.
        // syncRemoteOnStart is read at the next startup and needs no live work.
        if changedFieldIDs.contains(
            MyPromptPluginConfigurationFieldID.includeUserPrompt
        ) {
            notifyChange()
        }
    }

    private func invalidateForConfigurationChange(clearCandidates: Bool) {
        lifecycleEpoch &+= 1
        generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        readyQuery = nil
        deliveryLease = nil
        if clearCandidates {
            candidates.removeAll(keepingCapacity: true)
            selectedPosition = 0
        }
        notice = nil
    }

    private static let configurationFieldIDs: Set<String> = [
        MyPromptPluginConfigurationFieldID.libraryDirectory,
        MyPromptPluginConfigurationFieldID.remoteRepositories,
        MyPromptPluginConfigurationFieldID.resultLimit,
        MyPromptPluginConfigurationFieldID.includeUserPrompt,
        MyPromptPluginConfigurationFieldID.syncRemoteOnStart,
    ]

    private func beginRefresh(
        settings: MyPromptPluginSettings,
        synchronizeRemoteRepositories: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard started, !protectedSession else { return }
        refreshRevision &+= 1
        let revision = refreshRevision
        refreshOperations.insert(revision)
        generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        readyQuery = nil
        deliveryLease = nil
        candidates.removeAll(keepingCapacity: true)
        selectedPosition = 0
        notice = nil
        phase = .refreshing
        notifyChange()

        dependencies.performBackground { [weak self] in
            guard let self else { return }
            let result: Result<RefreshReport, Error>
            do {
                result = .success(
                    try self.dependencies.refresh(
                        settings,
                        synchronizeRemoteRepositories
                    )
                )
            } catch {
                result = .failure(error)
            }
            self.performOnMain { workspace in
                workspace.finishRefresh(
                    result,
                    revision: revision
                )
            }
        }
    }

    private func finishRefresh(
        _ result: Result<RefreshReport, Error>,
        revision: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard refreshOperations.remove(revision) != nil else {
            return
        }
        guard started,
              !protectedSession else {
            return
        }
        guard revision == refreshRevision else {
            if isActive,
               !searchSuppressedForPrivacy,
               refreshOperations.isEmpty {
                scheduleSearch()
            } else {
                phase = isActive
                    && !searchSuppressedForPrivacy
                    && !refreshOperations.isEmpty
                    ? .refreshing
                    : .idle
                notifyChange()
            }
            return
        }
        switch result {
        case let .success(report):
            notice = report.failedSourceCount > 0
                ? "\(report.failedSourceCount) 个来源更新失败"
                : nil
            if isActive, !searchSuppressedForPrivacy {
                scheduleSearch()
            } else {
                phase = .idle
                notifyChange()
            }
        case .failure:
            phase = .failed("提示词索引更新失败")
            notifyChange()
        }
    }

    private func scheduleSearch() {
        dispatchPrecondition(condition: .onQueue(.main))
        searchTimer?.invalidate()
        searchTimer = nil
        guard isActive, !searchSuppressedForPrivacy else {
            phase = .idle
            notifyChange()
            return
        }
        searchRevision &+= 1
        let revision = searchRevision
        let epoch = lifecycleEpoch
        let signature = currentQuerySignature()
        phase = .waiting
        notifyChange()
        let timer = Timer(
            timeInterval: Self.searchDebounce,
            repeats: false
        ) { [weak self] _ in
            self?.beginSearch(
                signature: signature,
                revision: revision,
                epoch: epoch
            )
        }
        searchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func beginSearch(
        signature: QuerySignature,
        revision: UInt64,
        epoch: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        searchTimer?.invalidate()
        searchTimer = nil
        guard searchAuthorityMatches(
            signature: signature,
            revision: revision,
            epoch: epoch
        ) else {
            return
        }
        phase = .searching
        notifyChange()
        let limit = PluginConfigurationCatalog.myPromptSettings(
            defaults: defaults
        ).resultLimit
        dependencies.performBackground { [weak self] in
            guard let self else { return }
            let result: Result<[Candidate], Error>
            do {
                result = .success(
                    try self.dependencies.search(signature.text, limit)
                )
            } catch {
                result = .failure(error)
            }
            self.performOnMain { workspace in
                workspace.finishSearch(
                    result,
                    signature: signature,
                    revision: revision,
                    epoch: epoch,
                    limit: limit
                )
            }
        }
    }

    private func finishSearch(
        _ result: Result<[Candidate], Error>,
        signature: QuerySignature,
        revision: UInt64,
        epoch: UInt64,
        limit: Int
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard searchAuthorityMatches(
            signature: signature,
            revision: revision,
            epoch: epoch
        ) else {
            return
        }
        deliveryLease = nil
        selectedPosition = 0
        switch result {
        case let .success(found):
            var seen = Set<String>()
            candidates = found.compactMap { candidate in
                let recordID = candidate.recordID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !recordID.isEmpty,
                      !candidate.systemPrompt.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ).isEmpty,
                      seen.insert(recordID).inserted else {
                    return nil
                }
                return PresentedCandidate(
                    candidate: candidate,
                    railID: stableCandidateID(for: recordID)
                )
            }
            .prefix(min(max(limit, 1), 3))
            .map { $0 }
            readyQuery = signature
            phase = .ready
        case .failure:
            candidates.removeAll(keepingCapacity: true)
            readyQuery = nil
            phase = .failed("提示词检索失败")
        }
        notifyChange()
    }

    private func searchAuthorityMatches(
        signature: QuerySignature,
        revision: UInt64,
        epoch: UInt64
    ) -> Bool {
        started
            && isActive
            && epoch == lifecycleEpoch
            && revision == searchRevision
            && signature == currentQuerySignature()
    }

    private func selectCandidate(at position: Int) {
        guard candidates.indices.contains(position),
              selectedPosition != position else {
            return
        }
        generation &+= 1
        selectedPosition = position
        notifyChange()
    }

    private func currentQuerySignature() -> QuerySignature {
        QuerySignature(
            text: sourceModel.stagedText,
            blockIDs: sourceModel.blocks.map(\.id),
            changeCount: sourceModel.changeCount,
            allowsRemoteMirror: sourceModel.blocks.allSatisfy {
                $0.origin.allowsRemoteMirror
            }
        )
    }

    private func stableCandidateID(for recordID: String) -> UUID {
        if let persistedID = UUID(uuidString: recordID) {
            return persistedID
        }
        if let existing = stableCandidateIDs[recordID] {
            return existing
        }
        let value = UUID()
        stableCandidateIDs[recordID] = value
        return value
    }

    private func stableRowKey(for recordID: String) -> Int {
        var hash = Hasher()
        hash.combine("my-prompt")
        hash.combine(recordID)
        return hash.finalize()
    }

    private func tombstone(
        clearCandidates: Bool,
        nextPhase: Phase
    ) {
        lifecycleEpoch &+= 1
        refreshRevision &+= 1
        searchRevision &+= 1
        generation &+= 1
        searchTimer?.invalidate()
        searchTimer = nil
        readyQuery = nil
        deliveryLease = nil
        if clearCandidates {
            candidates.removeAll(keepingCapacity: true)
            selectedPosition = 0
        }
        notice = nil
        phase = nextPhase
        notifyChange()
    }

    private func performOnMain(
        _ operation: @escaping (MyPromptWorkspace) -> Void
    ) {
        if Thread.isMainThread {
            operation(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                operation(self)
            }
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(
            name: .derivedBufferWorkspaceDidChange,
            object: self
        )
    }

    private static func presentationText(for candidate: Candidate) -> String {
        let title = compact(candidate.title, maximumCharacters: 80)
        let snippet = compact(candidate.snippet, maximumCharacters: 140)
        if title.isEmpty { return snippet.isEmpty ? "未命名提示词" : snippet }
        if snippet.isEmpty || snippet == title { return title }
        return "\(title) · \(snippet)"
    }

    private static func compact(
        _ raw: String,
        maximumCharacters: Int
    ) -> String {
        let value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "…"
    }

    // MARK: BufferDeliveryContentSource

    var deliveryWorkspaceID: String { "my-prompt" }
    var deliveryGeneration: UInt64 { generation }

    var hasIncompleteDeliveryBlocks: Bool {
        guard isActive else { return false }
        return phase == .waiting
            || phase == .searching
            || phase == .refreshing
    }

    var deliveryPendingBlocks: [BufferModel.Block] {
        guard phase == .ready,
              currentQuerySignatureMatchesReadyState,
              let presented = selectedCandidate,
              let query = deliveryLease?.query ?? readyQuery else {
            return []
        }
        let settings = PluginConfigurationCatalog.myPromptSettings(
            defaults: defaults
        )
        guard let body = Self.deliveryBody(
            for: presented.candidate,
            includeUserPrompt: deliveryLease?.includeUserPrompt
                ?? settings.includeUserPrompt
        ) else {
            return []
        }
        return [
            BufferModel.Block(
                id: presented.railID,
                text: body,
                origin: .processor(
                    id: Self.processorID,
                    allowsRemoteMirror: query.allowsRemoteMirror
                )
            ),
        ]
    }

    @discardableResult
    func prepareForDelivery() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isActive,
              phase == .ready,
              currentQuerySignatureMatchesReadyState,
              let presented = selectedCandidate,
              let readyQuery else {
            return false
        }
        if let deliveryLease {
            return deliveryLease.candidate.railID == presented.railID
                && deliveryLease.query == currentQuerySignature()
        }
        let includeUserPrompt = PluginConfigurationCatalog.myPromptSettings(
            defaults: defaults
        ).includeUserPrompt
        guard Self.deliveryBody(
            for: presented.candidate,
            includeUserPrompt: includeUserPrompt
        ) != nil else {
            return false
        }
        deliveryLease = DeliveryLease(
            candidate: presented,
            query: readyQuery,
            includeUserPrompt: includeUserPrompt
        )
        candidates = [presented]
        selectedPosition = 0
        generation &+= 1
        notifyChange()
        return true
    }

    func deliveryBlock(
        id: UUID,
        generation: UInt64
    ) -> BufferModel.Block? {
        guard self.generation == generation,
              isActive,
              phase == .ready,
              let deliveryLease,
              deliveryLease.query == currentQuerySignature(),
              deliveryLease.candidate.railID == id,
              let body = Self.deliveryBody(
                  for: deliveryLease.candidate.candidate,
                  includeUserPrompt: deliveryLease.includeUserPrompt
              ) else {
            return nil
        }
        return BufferModel.Block(
            id: id,
            text: body,
            origin: .processor(
                id: Self.processorID,
                allowsRemoteMirror:
                    deliveryLease.query.allowsRemoteMirror
            )
        )
    }

    func consumeDelivered(
        blockIDs: [UUID],
        generation: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.generation == generation,
              let deliveryLease,
              blockIDs.contains(deliveryLease.candidate.railID),
              deliveryLease.query == currentQuerySignature() else {
            return
        }
        let recordID = deliveryLease.candidate.candidate.recordID
        let queryBlockIDs = deliveryLease.query.blockIDs

        self.deliveryLease = nil
        readyQuery = nil
        candidates.removeAll(keepingCapacity: true)
        selectedPosition = 0
        phase = .idle
        self.generation &+= 1
        searchRevision &+= 1
        searchTimer?.invalidate()
        searchTimer = nil

        dependencies.performBackground { [dependencies] in
            try? dependencies.markUsed(recordID)
        }
        sourceModel.consumeDelivered(blockIDs: queryBlockIDs)
        notifyChange()
    }

    func markDeliveryBlockStale(
        id: UUID,
        generation: UInt64
    ) -> Bool {
        false
    }

    private var selectedCandidate: PresentedCandidate? {
        guard candidates.indices.contains(selectedPosition) else {
            return nil
        }
        return candidates[selectedPosition]
    }

    /// Search completion is authorized only against the frozen signature. Once
    /// ready, every source mutation clears candidates synchronously, so this
    /// check remains exact without retaining a second plaintext query copy.
    private var currentQuerySignatureMatchesReadyState: Bool {
        guard phase == .ready,
              let readyQuery,
              readyQuery == currentQuerySignature() else {
            return false
        }
        if let deliveryLease {
            return deliveryLease.query == readyQuery
        }
        return true
    }

    private static func deliveryBody(
        for candidate: Candidate,
        includeUserPrompt: Bool
    ) -> String? {
        let system = candidate.systemPrompt
        guard !system.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return nil }
        guard includeUserPrompt,
              let userPrompt = candidate.userPrompt,
              !userPrompt.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            return system
        }
        return "\(system)\n\n\(userPrompt)"
    }
}

/// Live data-layer wiring is intentionally kept behind closure dependencies so
/// smoke tests can deterministically hold and release background callbacks.
private enum MyPromptLiveDependencies {
    private static let queue = DispatchQueue(
        label: "RimeBuffer.MyPrompt",
        qos: .userInitiated
    )
    private static let serviceLock = NSLock()
    private static var cachedService: MyPromptLiveServices?

    static func make() -> MyPromptWorkspace.Dependencies {
        MyPromptWorkspace.Dependencies(
            search: { query, limit in
                try service().search(query, limit: limit)
            },
            refresh: { settings, synchronizeRemoteRepositories in
                try service().refresh(
                    settings: settings,
                    synchronizeRemoteRepositories:
                        synchronizeRemoteRepositories
                )
            },
            markUsed: { recordID in
                guard let promptID = UUID(uuidString: recordID) else {
                    throw MyPromptLiveDependencyError.invalidRecordID
                }
                try service().markUsed(promptID: promptID)
            },
            performBackground: { operation in
                queue.async(execute: operation)
            }
        )
    }

    private static func service() throws -> MyPromptLiveServices {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        if let cachedService { return cachedService }
        let service = try MyPromptLiveServices()
        cachedService = service
        return service
    }
}

private enum MyPromptLiveDependencyError: Error {
    case invalidRecordID
}

private final class MyPromptLiveServices {
    private let store: MyPromptStore
    private let importer: MyPromptImporter
    private let remoteSynchronizer: MyPromptRemoteRepositorySynchronizer
    private let refreshLock = NSLock()
    private let dataRoot: URL

    init() throws {
        let root = PluginConfigurationCatalog.defaultMyPromptDataRoot
        dataRoot = root
        store = try MyPromptStore(rootDirectory: root)
        importer = MyPromptImporter()
        remoteSynchronizer = MyPromptRemoteRepositorySynchronizer()
    }

    func search(
        _ query: String,
        limit: Int
    ) throws -> [MyPromptWorkspace.Candidate] {
        try store.search(query, limit: limit).map { result in
            MyPromptWorkspace.Candidate(
                recordID: result.record.id.uuidString.lowercased(),
                title: result.title,
                snippet: result.snippet,
                systemPrompt: result.systemPrompt,
                userPrompt: result.userPrompt
            )
        }
    }

    func markUsed(promptID: UUID) throws {
        try store.markUsed(promptID: promptID)
    }

    func refresh(
        settings: MyPromptPluginSettings,
        synchronizeRemoteRepositories: Bool
    ) throws -> MyPromptWorkspace.RefreshReport {
        refreshLock.lock()
        defer { refreshLock.unlock() }

        if !FileManager.default.fileExists(
            atPath: settings.libraryDirectoryURL.path
        ) {
            try FileManager.default.createDirectory(
                at: settings.libraryDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let localSource = MyPromptSource.local(
            settings.libraryDirectoryURL
        )
        let configuredRemoteSourceIDs = Set(
            settings.remoteRepositoryURLs.map(Self.remoteSourceID)
        )
        // Remove sources that no longer belong to the active configuration
        // before scanning the new local path. If that new path is malformed,
        // a later query must not silently fall back to a previously configured
        // library. A still-configured source keeps its last good snapshot when
        // its current refresh fails.
        for source in try store.sources() {
            let remainsConfigured: Bool
            if source.kind == .remoteSnapshot {
                remainsConfigured = configuredRemoteSourceIDs.contains(
                    source.id
                )
            } else {
                remainsConfigured = source.id == localSource.id
            }
            if !remainsConfigured {
                try store.removeSource(id: source.id)
            }
        }
        let importedLocalCount: Int
        do {
            let localImport = try importer.scan(
                rootURL: settings.libraryDirectoryURL,
                source: localSource
            )
            importedLocalCount = try store.replaceSource(with: localImport)
        } catch MyPromptImporterError.noPrompts {
            // A newly created library is a valid empty starting point. Replace
            // the prior snapshot as well, so deleting every local prompt does
            // not leave stale searchable records behind.
            importedLocalCount = try store.replaceSource(
                localSource,
                records: []
            )
        }
        var importedCount = importedLocalCount
        var failedSourceCount = 0

        guard synchronizeRemoteRepositories,
              !settings.remoteRepositoryURLs.isEmpty else {
            return MyPromptWorkspace.RefreshReport(
                importedCount: importedCount,
                failedSourceCount: failedSourceCount
            )
        }

        let synchronization = remoteSynchronizer.synchronize(
            repositories: settings.remoteRepositoryURLs,
            checkoutsRoot: dataRoot.appendingPathComponent(
                "repositories",
                isDirectory: true
            )
        )
        failedSourceCount += synchronization.failedCount
        for snapshot in synchronization.snapshots {
            let source = MyPromptSource(
                id: snapshot.sourceID,
                kind: .remoteSnapshot,
                displayName: snapshot.displayName,
                location: snapshot.repositoryURL.absoluteString
            )
            do {
                let result = try importer.scan(
                    rootURL: snapshot.checkoutURL,
                    source: source
                )
                importedCount += try store.replaceSource(with: result)
            } catch {
                failedSourceCount += 1
            }
        }
        return MyPromptWorkspace.RefreshReport(
            importedCount: importedCount,
            failedSourceCount: failedSourceCount
        )
    }

    private static func remoteSourceID(_ repository: URL) -> String {
        let digest = SHA256.hash(
            data: Data(repository.absoluteString.utf8)
        )
        let identity = digest.prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
        return "git:\(identity)"
    }
}
