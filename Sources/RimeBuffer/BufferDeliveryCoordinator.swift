import Cocoa
import Carbon.HIToolbox

/// A source emits this receipt only when consuming the accepted UUIDs has
/// atomically exhausted its current delivery source. This covers Default and
/// every Buffer plugin through the same completion transaction.
struct BufferDeliveryTerminalSourceReceipt: Equatable {
    let workspaceID: String
    /// Source generation that was current immediately before the atomic
    /// consumption. It must still equal the generation frozen by send().
    let generation: UInt64
    /// Source generation after every synchronous mutation caused by the
    /// terminal consumption has settled.
    let generationAfterConsumption: UInt64
    let consumedBlockIDs: Set<UUID>
}

/// A delivery workspace exposes stable block identities, while requiring the
/// coordinator to re-read each block immediately before insertion. This lets
/// ordinary BufferModel blocks and derived translation blocks share the one
/// authorized Delivery.insert path without freezing stale plaintext copies.
protocol BufferDeliveryContentSource: AnyObject {
    var deliveryWorkspaceID: String { get }
    var deliveryGeneration: UInt64 { get }
    var hasIncompleteDeliveryBlocks: Bool { get }
    var deliveryPendingBlocks: [BufferModel.Block] { get }
    /// Final mutable preflight immediately before the coordinator freezes a
    /// generation. Most sources are already committed; candidate workspaces
    /// use this seam to make the highlighted interpretation exclusive.
    @discardableResult func prepareForDelivery() -> Bool
    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block?
    func consumeDelivered(blockIDs: [UUID], generation: UInt64)
    /// Consume accepted blocks and report an atomic terminal drain. The
    /// receipt must be derived from the same synchronous mutation rather than
    /// inferred later from router or presentation state.
    func consumeDeliveredAndReportTerminalDrain(
        blockIDs: [UUID],
        generation: UInt64
    ) -> BufferDeliveryTerminalSourceReceipt?
    @discardableResult
    func markDeliveryBlockStale(id: UUID, generation: UInt64) -> Bool
}

extension BufferDeliveryContentSource {
    @discardableResult
    func prepareForDelivery() -> Bool { true }

    func consumeDeliveredAndReportTerminalDrain(
        blockIDs: [UUID],
        generation: UInt64
    ) -> BufferDeliveryTerminalSourceReceipt? {
        guard deliveryGeneration == generation,
              !blockIDs.isEmpty else { return nil }
        let requestedIDs = Set(blockIDs)
        let matchedIDs = Set(deliveryPendingBlocks.lazy.filter {
            requestedIDs.contains($0.id)
        }.map(\.id))
        guard matchedIDs == requestedIDs else { return nil }
        consumeDelivered(blockIDs: blockIDs, generation: generation)
        guard deliveryPendingBlocks.isEmpty,
              !hasIncompleteDeliveryBlocks,
              matchedIDs.allSatisfy({ id in
                  deliveryBlock(id: id, generation: deliveryGeneration) == nil
              }) else { return nil }
        return BufferDeliveryTerminalSourceReceipt(
            workspaceID: deliveryWorkspaceID,
            generation: generation,
            generationAfterConsumption: deliveryGeneration,
            consumedBlockIDs: matchedIDs
        )
    }
}

extension BufferModel: BufferDeliveryContentSource {
    var deliveryWorkspaceID: String { "source-buffer" }
    var deliveryGeneration: UInt64 { UInt64(changeCount) }
    var hasIncompleteDeliveryBlocks: Bool { hasIncompletePluginBlocks }
    var deliveryPendingBlocks: [Block] { pendingDeliveryBlocks }

    func deliveryBlock(id: UUID, generation: UInt64) -> Block? {
        guard deliveryGeneration == generation else { return nil }
        return block(id: id)
    }

    func consumeDelivered(blockIDs: [UUID], generation: UInt64) {
        consumeDelivered(blockIDs: blockIDs)
    }

    func markDeliveryBlockStale(id: UUID, generation: UInt64) -> Bool {
        guard deliveryGeneration == generation else { return false }
        return markPluginBlockStale(id: id)
    }
}

enum BufferDeliveryContentRouter {
    static func current(sourceModel: BufferModel = .shared) -> any BufferDeliveryContentSource {
        if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace {
            return workspace
        }
        // A sole prepared Action Plugin owns the same primary generation /
        // delivery surface as the built-in AI workspace. Its filtered source
        // prevents unrelated BufferModel text from being sent merely because
        // a matching generated block exists later in the shared model.
        if sourceModel === BufferModel.shared,
           ActionPluginHost.shared.primaryGenerationPresentation != nil {
            return ActionPluginHost.shared
        }
        return sourceModel
    }
}

/// The only coordinator allowed to turn staged blocks into Delivery.insert
/// calls. Plugin-origin blocks add an asynchronous, target-bound status check
/// immediately before insertion; ordinary blocks retain the synchronous path.
final class BufferDeliveryCoordinator {
    static let shared = BufferDeliveryCoordinator()

    enum BlockedReason: Equatable {
        case noFocusedField
        case composing
        case secureInput
        case nothingPending
        case targetChanged
        case deliveryRejected
        case validatingPluginTarget
        case stalePluginResult
        case pluginTargetChanged
        case pluginUnavailable
        case pluginResultIncomplete
        case contentChanged

        var message: String {
            switch self {
            case .noFocusedField: return "请先点选要接收文字的外部文本框"
            case .composing: return "正在组字，结束组字后才能发送"
            case .secureInput: return "安全输入已开启，发送被保护性禁用"
            case .nothingPending: return "缓冲区没有待发送内容"
            case .targetChanged: return "输入焦点已经变化，发送已停止"
            case .deliveryRejected: return "目标拒绝了发送，未发送内容仍然保留"
            case .validatingPluginTarget: return "正在确认插件目标"
            case .stalePluginResult: return "插件结果已过期，请重新生成"
            case .pluginTargetChanged: return "评论目标已经变化，请重新生成回复"
            case .pluginUnavailable: return "插件服务暂时不可用，内容仍保留在缓冲区"
            case .pluginResultIncomplete: return "插件仍在生成，完成后才能发送"
            case .contentChanged: return "缓冲内容已变化，请重新确认"
            }
        }
    }

    enum Availability: Equatable {
        case ready
        case blocked(BlockedReason)

        var canSend: Bool {
            if case .ready = self { return true }
            return false
        }

        /// AI generation snapshots the committed source rail. Starting it
        /// while the focused client still owns preedit would omit that text,
        /// then the later composition settlement would invalidate the request.
        var blocksManualGenerationRequest: Bool {
            if case .blocked(.composing) = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .ready: return "可发送"
            case let .blocked(reason): return reason.message
            }
        }
    }

    struct SendResult: Equatable {
        let sentCount: Int
        let blockedReason: BlockedReason?
        let deferred: Bool
        let terminalDrain: TerminalDrainContext?

        init(sentCount: Int,
             blockedReason: BlockedReason?,
             deferred: Bool = false,
             terminalDrain: TerminalDrainContext? = nil) {
            self.sentCount = sentCount
            self.blockedReason = blockedReason
            self.deferred = deferred
            self.terminalDrain = terminalDrain
        }

        var succeeded: Bool { sentCount > 0 && blockedReason == nil }
    }

    /// Immutable hand-off for the workbench's guarded close. The coordinator
    /// emits it on the next main-loop turn; the UI remains responsible for
    /// checking its own presentation/session epoch and the exact focus token.
    struct TerminalDrainContext: Equatable {
        let attemptID: UUID
        let sourceIdentity: ObjectIdentifier
        let workspaceID: String
        let sourceGeneration: UInt64
        let sourceGenerationAfterConsumption: UInt64
        let workbenchSessionEpoch: UInt64
        let targetToken: FocusToken
        let deliveredBlockIDs: [UUID]

        /// The workbench calls this on the deferred callback turn. Identity and
        /// workspace prevent an owner switch; the post-consumption generation
        /// prevents an older terminal receipt from closing over newer content.
        func matchesCurrentSource(
            _ source: any BufferDeliveryContentSource
        ) -> Bool {
            ObjectIdentifier(source) == sourceIdentity
                && source.deliveryWorkspaceID == workspaceID
                && source.deliveryGeneration
                    == sourceGenerationAfterConsumption
        }
    }

    struct DeliveryTarget {
        let token: FocusToken
        let compositionActive: Bool
        let resolveComposition: () -> Void
        let deliver: (BufferModel.Block) -> Bool
    }

    struct Dependencies {
        let resolveTarget: (FocusToken?) -> DeliveryTarget?
        let secureInputEnabled: () -> Bool
        let validatePlugin: (
            BufferModel.PluginMetadata,
            FocusToken,
            @escaping (ActionPluginDeliveryDecision) -> Void
        ) -> Void
        let refreshUI: () -> Void
        let workbenchSessionEpoch: () -> UInt64
        let terminalDrainDelivered: (TerminalDrainContext) -> Void

        init(resolveTarget: @escaping (FocusToken?) -> DeliveryTarget?,
             secureInputEnabled: @escaping () -> Bool,
             validatePlugin: @escaping (
                BufferModel.PluginMetadata,
                FocusToken,
                @escaping (ActionPluginDeliveryDecision) -> Void
             ) -> Void,
             refreshUI: @escaping () -> Void,
             workbenchSessionEpoch: @escaping () -> UInt64 = { 0 },
             terminalDrainDelivered: @escaping (
                TerminalDrainContext
             ) -> Void = { _ in }) {
            self.resolveTarget = resolveTarget
            self.secureInputEnabled = secureInputEnabled
            self.validatePlugin = validatePlugin
            self.refreshUI = refreshUI
            self.workbenchSessionEpoch = workbenchSessionEpoch
            self.terminalDrainDelivered = terminalDrainDelivered
        }

        static var live: Dependencies {
            Dependencies(
                resolveTarget: { expectedToken in
                    let lease = expectedToken.flatMap {
                        InputFocusCoordinator.shared.liveTarget(expected: $0)
                    } ?? (expectedToken == nil
                        ? InputFocusCoordinator.shared.liveTarget()
                        : nil)
                    guard let lease,
                          let controller = lease.controller else { return nil }
                    return DeliveryTarget(
                        token: lease.token,
                        compositionActive: lease.compositionActive,
                        resolveComposition: {
                            controller.resolveCompositionForBufferDelivery(target: lease)
                        },
                        deliver: { block in
                            guard let current = InputFocusCoordinator.shared.liveTarget(
                                expected: lease.token
                            ), current === lease else { return false }
                            return controller.deliverBufferedBlock(block.text,
                                                                  origin: block.origin,
                                                                  target: current)
                        }
                    )
                },
                secureInputEnabled: { IsSecureEventInputEnabled() },
                validatePlugin: { metadata, token, completion in
                    ActionPluginHost.shared.validateForDelivery(
                        metadata: metadata,
                        expectedFocusToken: token,
                        completion: completion
                    )
                },
                refreshUI: { RimeBufferController.refreshActiveUI() },
                workbenchSessionEpoch: {
                    BufferWindowController.shared.workbenchSessionEpoch
                },
                terminalDrainDelivered: { context in
                    BufferWindowController.shared
                        .closeAfterTerminalDrain(context)
                }
            )
        }
    }

    private let model: BufferModel
    private let dependencies: Dependencies
    private let contentSourceResolver: () -> any BufferDeliveryContentSource
    private var activeOperationID: UUID?
    private(set) var lastBlockedReason: BlockedReason?

    init(model: BufferModel = .shared,
         dependencies: Dependencies = .live,
         contentSourceResolver: (() -> any BufferDeliveryContentSource)? = nil) {
        self.model = model
        self.dependencies = dependencies
        if let contentSourceResolver {
            self.contentSourceResolver = contentSourceResolver
        } else if model === BufferModel.shared {
            self.contentSourceResolver = {
                BufferDeliveryContentRouter.current(sourceModel: model)
            }
        } else {
            self.contentSourceResolver = { model }
        }
    }

    func availability() -> Availability {
        if activeOperationID != nil {
            return .blocked(.validatingPluginTarget)
        }
        guard let target = dependencies.resolveTarget(nil) else {
            return .blocked(.noFocusedField)
        }
        if target.compositionActive {
            return .blocked(.composing)
        }
        if dependencies.secureInputEnabled() {
            return .blocked(.secureInput)
        }
        let source = contentSourceResolver()
        if source.hasIncompleteDeliveryBlocks {
            return .blocked(.pluginResultIncomplete)
        }
        let pending = source.deliveryPendingBlocks
        if pending.isEmpty {
            return .blocked(.nothingPending)
        }
        if pending.contains(where: { invalidPluginMetadata(in: $0) || $0.pluginMetadata?.stale == true }) {
            return .blocked(.stalePluginResult)
        }
        return .ready
    }

    @discardableResult
    func sendNext(resolveCompositionIfNeeded: Bool = true,
                  expectedToken: FocusToken? = nil,
                  completion: ((SendResult) -> Void)? = nil) -> SendResult {
        send(all: false,
             resolveCompositionIfNeeded: resolveCompositionIfNeeded,
             expectedToken: expectedToken,
             completion: completion)
    }

    @discardableResult
    func sendAll(resolveCompositionIfNeeded: Bool = true,
                 expectedToken: FocusToken? = nil,
                 completion: ((SendResult) -> Void)? = nil) -> SendResult {
        send(all: true,
             resolveCompositionIfNeeded: resolveCompositionIfNeeded,
             expectedToken: expectedToken,
             completion: completion)
    }

    private func send(all: Bool,
                      resolveCompositionIfNeeded: Bool,
                      expectedToken: FocusToken?,
                      completion: ((SendResult) -> Void)?) -> SendResult {
        dispatchPrecondition(condition: .onQueue(.main))
        let workbenchSessionEpoch = dependencies.workbenchSessionEpoch()
        guard activeOperationID == nil else {
            return finishImmediate(.init(sentCount: 0,
                                         blockedReason: .validatingPluginTarget),
                                   completion: completion)
        }
        guard var target = dependencies.resolveTarget(expectedToken) else {
            let reason: BlockedReason = expectedToken == nil ? .noFocusedField : .targetChanged
            IMELog.write("buffer send blocked: \(reason.message)")
            return finishImmediate(.init(sentCount: 0, blockedReason: reason),
                                   completion: completion)
        }

        if target.compositionActive {
            guard resolveCompositionIfNeeded else {
                return finishImmediate(.init(sentCount: 0, blockedReason: .composing),
                                       completion: completion)
            }
            target.resolveComposition()
            guard let refreshed = dependencies.resolveTarget(target.token) else {
                return finishImmediate(.init(sentCount: 0, blockedReason: .targetChanged),
                                       completion: completion)
            }
            target = refreshed
            guard !target.compositionActive else {
                return finishImmediate(.init(sentCount: 0, blockedReason: .composing),
                                       completion: completion)
            }
        }

        guard !dependencies.secureInputEnabled() else {
            IMELog.write("buffer send blocked: secure input")
            return finishImmediate(.init(sentCount: 0, blockedReason: .secureInput),
                                   completion: completion)
        }

        let source = contentSourceResolver()
        guard source.prepareForDelivery() else {
            return finishImmediate(.init(sentCount: 0,
                                         blockedReason: .contentChanged),
                                   completion: completion)
        }
        let sourceGeneration = source.deliveryGeneration
        let sourceWorkspaceID = source.deliveryWorkspaceID
        guard !source.hasIncompleteDeliveryBlocks else {
            return finishImmediate(.init(sentCount: 0,
                                         blockedReason: .pluginResultIncomplete),
                                   completion: completion)
        }

        let pending = source.deliveryPendingBlocks
        guard !pending.isEmpty else {
            return finishImmediate(.init(sentCount: 0, blockedReason: .nothingPending),
                                   completion: completion)
        }
        let selected = all ? pending : Array(pending.prefix(1))
        if let invalid = selected.first(where: {
            invalidPluginMetadata(in: $0) || $0.pluginMetadata?.stale == true
        }) {
            _ = source.markDeliveryBlockStale(id: invalid.id,
                                              generation: sourceGeneration)
            return finishImmediate(.init(sentCount: 0, blockedReason: .stalePluginResult),
                                   completion: completion)
        }

        let needsPluginValidation = selected.contains { pluginMetadata(in: $0) != nil }
        let attemptID = UUID()
        guard needsPluginValidation else {
            return sendSynchronously(selected.map(\.id),
                                     source: source,
                                     sourceWorkspaceID: sourceWorkspaceID,
                                     sourceGeneration: sourceGeneration,
                                     workbenchSessionEpoch: workbenchSessionEpoch,
                                     targetToken: target.token,
                                     attemptID: attemptID,
                                     completion: completion)
        }

        let operationID = attemptID
        activeOperationID = operationID
        lastBlockedReason = nil
        dependencies.refreshUI()
        continueAsync(operationID: operationID,
                      blockIDs: selected.map(\.id),
                      index: 0,
                      source: source,
                      sourceWorkspaceID: sourceWorkspaceID,
                      sourceGeneration: sourceGeneration,
                      workbenchSessionEpoch: workbenchSessionEpoch,
                      targetToken: target.token,
                      deliveredIDs: [],
                      completion: completion)
        return SendResult(sentCount: 0, blockedReason: nil, deferred: true)
    }

    private func sendSynchronously(_ blockIDs: [UUID],
                                   source: any BufferDeliveryContentSource,
                                   sourceWorkspaceID: String,
                                   sourceGeneration: UInt64,
                                   workbenchSessionEpoch: UInt64,
                                   targetToken: FocusToken,
                                   attemptID: UUID,
                                   completion: ((SendResult) -> Void)?) -> SendResult {
        var deliveredIDs: [UUID] = []
        var blockedReason: BlockedReason?
        for blockID in blockIDs {
            guard sourceIsCurrent(source,
                                  workspaceID: sourceWorkspaceID,
                                  generation: sourceGeneration),
                  let block = source.deliveryBlock(id: blockID,
                                                   generation: sourceGeneration) else {
                blockedReason = .contentChanged
                break
            }
            guard let current = dependencies.resolveTarget(targetToken) else {
                blockedReason = .targetChanged
                break
            }
            guard !current.compositionActive else {
                blockedReason = .composing
                break
            }
            guard !dependencies.secureInputEnabled() else {
                blockedReason = .secureInput
                break
            }
            guard current.deliver(block) else {
                blockedReason = dependencies.resolveTarget(targetToken) == nil
                    ? .targetChanged
                    : .deliveryRejected
                break
            }
            deliveredIDs.append(block.id)
            IMELog.write("buffer send accepted block=\(block.id) origin=\(block.origin.tag)")
        }
        let terminalContext = consumeDeliveredAndResolveTerminalDrain(
            deliveredIDs,
            source: source,
            sourceWorkspaceID: sourceWorkspaceID,
            sourceGeneration: sourceGeneration,
            workbenchSessionEpoch: workbenchSessionEpoch,
            targetToken: targetToken,
            attemptID: attemptID,
            blockedReason: blockedReason
        )
        let result = SendResult(sentCount: deliveredIDs.count,
                                blockedReason: blockedReason,
                                terminalDrain: terminalContext)
        return finishImmediate(result, completion: completion)
    }

    private func continueAsync(operationID: UUID,
                               blockIDs: [UUID],
                               index: Int,
                               source: any BufferDeliveryContentSource,
                               sourceWorkspaceID: String,
                               sourceGeneration: UInt64,
                               workbenchSessionEpoch: UInt64,
                               targetToken: FocusToken,
                               deliveredIDs: [UUID],
                               completion: ((SendResult) -> Void)?) {
        guard activeOperationID == operationID else { return }
        var cursor = index
        var accepted = deliveredIDs

        while blockIDs.indices.contains(cursor) {
            guard sourceIsCurrent(source,
                                  workspaceID: sourceWorkspaceID,
                                  generation: sourceGeneration) else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .contentChanged,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            guard !source.hasIncompleteDeliveryBlocks else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .pluginResultIncomplete,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            let blockID = blockIDs[cursor]
            guard let block = source.deliveryBlock(id: blockID,
                                                   generation: sourceGeneration) else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .contentChanged,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            guard let current = dependencies.resolveTarget(targetToken) else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: pluginMetadata(in: block) == nil
                                ? .targetChanged
                                : .pluginTargetChanged,
                            staleBlockID: pluginMetadata(in: block) == nil ? nil : block.id,
                            completion: completion)
                return
            }
            guard !current.compositionActive else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .composing,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            guard !dependencies.secureInputEnabled() else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .secureInput,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            if invalidPluginMetadata(in: block) {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .stalePluginResult,
                            staleBlockID: block.id,
                            completion: completion)
                return
            }
            if let metadata = pluginMetadata(in: block) {
                if metadata.stale {
                    finishAsync(operationID: operationID,
                                deliveredIDs: accepted,
                                source: source,
                                sourceWorkspaceID: sourceWorkspaceID,
                                sourceGeneration: sourceGeneration,
                                workbenchSessionEpoch: workbenchSessionEpoch,
                                targetToken: targetToken,
                                reason: .stalePluginResult,
                                staleBlockID: block.id,
                                completion: completion)
                    return
                }
                dependencies.validatePlugin(metadata, targetToken) { [weak self] decision in
                    let work: () -> Void = { [weak self] in
                        guard let self else { return }
                        self.handlePluginValidation(
                            decision,
                            metadata: metadata,
                            blockID: block.id,
                            operationID: operationID,
                            blockIDs: blockIDs,
                            nextIndex: cursor + 1,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            deliveredIDs: accepted,
                            completion: completion
                        )
                    }
                    if Thread.isMainThread {
                        work()
                    } else {
                        DispatchQueue.main.async(execute: work)
                    }
                }
                return
            }

            guard current.deliver(block) else {
                finishAsync(operationID: operationID,
                            deliveredIDs: accepted,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: dependencies.resolveTarget(targetToken) == nil
                                ? .targetChanged
                                : .deliveryRejected,
                            staleBlockID: nil,
                            completion: completion)
                return
            }
            accepted.append(block.id)
            IMELog.write("buffer send accepted block=\(block.id) origin=\(block.origin.tag)")
            dependencies.refreshUI()
            cursor += 1
        }

        finishAsync(operationID: operationID,
                    deliveredIDs: accepted,
                    source: source,
                    sourceWorkspaceID: sourceWorkspaceID,
                    sourceGeneration: sourceGeneration,
                    workbenchSessionEpoch: workbenchSessionEpoch,
                    targetToken: targetToken,
                    reason: nil,
                    staleBlockID: nil,
                    completion: completion)
    }

    private func handlePluginValidation(_ decision: ActionPluginDeliveryDecision,
                                        metadata: BufferModel.PluginMetadata,
                                        blockID: UUID,
                                        operationID: UUID,
                                        blockIDs: [UUID],
                                        nextIndex: Int,
                                        source: any BufferDeliveryContentSource,
                                        sourceWorkspaceID: String,
                                        sourceGeneration: UInt64,
                                        workbenchSessionEpoch: UInt64,
                                        targetToken: FocusToken,
                                        deliveredIDs: [UUID],
                                        completion: ((SendResult) -> Void)?) {
        guard activeOperationID == operationID else { return }
        switch decision {
        case .allowed:
            guard let current = dependencies.resolveTarget(targetToken),
                  !current.compositionActive,
                  !dependencies.secureInputEnabled(),
                  sourceIsCurrent(source,
                                  workspaceID: sourceWorkspaceID,
                                  generation: sourceGeneration),
                  !source.hasIncompleteDeliveryBlocks,
                  let liveBlock = source.deliveryBlock(id: blockID,
                                                       generation: sourceGeneration),
                  pluginMetadata(in: liveBlock) == metadata,
                  !metadata.stale,
                  !metadata.incomplete else {
                finishAsync(operationID: operationID,
                            deliveredIDs: deliveredIDs,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: .pluginTargetChanged,
                            staleBlockID: blockID,
                            completion: completion)
                return
            }
            guard current.deliver(liveBlock) else {
                finishAsync(operationID: operationID,
                            deliveredIDs: deliveredIDs,
                            source: source,
                            sourceWorkspaceID: sourceWorkspaceID,
                            sourceGeneration: sourceGeneration,
                            workbenchSessionEpoch: workbenchSessionEpoch,
                            targetToken: targetToken,
                            reason: dependencies.resolveTarget(targetToken) == nil
                                ? .pluginTargetChanged
                                : .deliveryRejected,
                            staleBlockID: dependencies.resolveTarget(targetToken) == nil
                                ? blockID
                                : nil,
                            completion: completion)
                return
            }
            IMELog.write("buffer plugin send accepted block=\(blockID) request=\(metadata.requestId)")
            dependencies.refreshUI()
            continueAsync(operationID: operationID,
                          blockIDs: blockIDs,
                          index: nextIndex,
                          source: source,
                          sourceWorkspaceID: sourceWorkspaceID,
                          sourceGeneration: sourceGeneration,
                          workbenchSessionEpoch: workbenchSessionEpoch,
                          targetToken: targetToken,
                          deliveredIDs: deliveredIDs + [blockID],
                          completion: completion)
        case let .rejected(failure):
            let reason: BlockedReason
            let staleBlockID: UUID?
            switch failure {
            case .stale:
                reason = .stalePluginResult
                staleBlockID = blockID
            case .targetChanged:
                reason = .pluginTargetChanged
                staleBlockID = blockID
            case .unavailable:
                reason = .pluginUnavailable
                staleBlockID = blockID
            }
            finishAsync(operationID: operationID,
                        deliveredIDs: deliveredIDs,
                        source: source,
                        sourceWorkspaceID: sourceWorkspaceID,
                        sourceGeneration: sourceGeneration,
                        workbenchSessionEpoch: workbenchSessionEpoch,
                        targetToken: targetToken,
                        reason: reason,
                        staleBlockID: staleBlockID,
                        completion: completion)
        }
    }

    private func finishAsync(operationID: UUID,
                             deliveredIDs: [UUID],
                             source: any BufferDeliveryContentSource,
                             sourceWorkspaceID: String,
                             sourceGeneration: UInt64,
                             workbenchSessionEpoch: UInt64,
                             targetToken: FocusToken,
                             reason: BlockedReason?,
                             staleBlockID: UUID?,
                             completion: ((SendResult) -> Void)?) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        // Capture diagnostic metadata under the frozen generation before any
        // model mutation advances it. When sendAll accepts an earlier block
        // and rejects a later plugin block, consumption and stale marking are
        // two mutations of the same logical completion transaction.
        let staleMetadata = staleBlockID.flatMap { blockID in
            source.deliveryBlock(id: blockID,
                                 generation: sourceGeneration)?.pluginMetadata
                ?? source.deliveryBlock(id: blockID,
                                        generation: source.deliveryGeneration)?.pluginMetadata
        }
        let terminalContext = consumeDeliveredAndResolveTerminalDrain(
            deliveredIDs,
            source: source,
            sourceWorkspaceID: sourceWorkspaceID,
            sourceGeneration: sourceGeneration,
            workbenchSessionEpoch: workbenchSessionEpoch,
            targetToken: targetToken,
            attemptID: operationID,
            blockedReason: reason
        )
        if let staleBlockID {
            // consumeDelivered may legitimately advance the source generation;
            // no user/event-loop work can interleave on this synchronous main-
            // thread path, so mark the still-present rejected block against the
            // source's immediately current generation.
            _ = source.markDeliveryBlockStale(id: staleBlockID,
                                              generation: source.deliveryGeneration)
        }
        if let reason,
           let metadata = staleMetadata {
            model.failTransientLoading(requestId: metadata.requestId,
                                       message: reason.message)
        }
        lastBlockedReason = reason
        if let reason {
            IMELog.write("buffer async send stopped reason=\(reason.message) sent=\(deliveredIDs.count)")
        }
        let result = SendResult(sentCount: deliveredIDs.count,
                                blockedReason: reason,
                                terminalDrain: terminalContext)
        completion?(result)
        dependencies.refreshUI()
        scheduleTerminalDrainCallback(for: result)
    }

    private func finishImmediate(_ result: SendResult,
                                 completion: ((SendResult) -> Void)?) -> SendResult {
        lastBlockedReason = result.blockedReason
        completion?(result)
        scheduleTerminalDrainCallback(for: result)
        return result
    }

    private func sourceIsCurrent(_ source: any BufferDeliveryContentSource,
                                 workspaceID: String,
                                 generation: UInt64) -> Bool {
        let current = contentSourceResolver()
        return ObjectIdentifier(current) == ObjectIdentifier(source)
            && current.deliveryWorkspaceID == workspaceID
            && source.deliveryWorkspaceID == workspaceID
            && source.deliveryGeneration == generation
    }

    private func consumeDeliveredAndResolveTerminalDrain(
        _ deliveredIDs: [UUID],
        source: any BufferDeliveryContentSource,
        sourceWorkspaceID: String,
        sourceGeneration: UInt64,
        workbenchSessionEpoch: UInt64,
        targetToken: FocusToken,
        attemptID: UUID,
        blockedReason: BlockedReason?
    ) -> TerminalDrainContext? {
        guard !deliveredIDs.isEmpty else { return nil }
        let receipt = source.consumeDeliveredAndReportTerminalDrain(
            blockIDs: deliveredIDs,
            generation: sourceGeneration
        )
        guard blockedReason == nil,
              let receipt,
              receipt.workspaceID == sourceWorkspaceID,
              receipt.generation == sourceGeneration,
              receipt.generationAfterConsumption == source.deliveryGeneration,
              receipt.consumedBlockIDs == Set(deliveredIDs) else {
            return nil
        }
        return TerminalDrainContext(
            attemptID: attemptID,
            sourceIdentity: ObjectIdentifier(source),
            workspaceID: sourceWorkspaceID,
            sourceGeneration: sourceGeneration,
            sourceGenerationAfterConsumption:
                receipt.generationAfterConsumption,
            workbenchSessionEpoch: workbenchSessionEpoch,
            targetToken: targetToken,
            deliveredBlockIDs: deliveredIDs
        )
    }

    private func scheduleTerminalDrainCallback(for result: SendResult) {
        guard let context = result.terminalDrain else { return }
        DispatchQueue.main.async { [dependencies] in
            dependencies.terminalDrainDelivered(context)
        }
    }

    private func pluginMetadata(in block: BufferModel.Block) -> BufferModel.PluginMetadata? {
        guard case let .plugin(pluginId) = block.origin,
              let metadata = block.pluginMetadata,
              metadata.pluginId == pluginId,
              !metadata.reviewedAsPlainText else { return nil }
        return metadata
    }

    private func invalidPluginMetadata(in block: BufferModel.Block) -> Bool {
        switch block.origin {
        case let .plugin(pluginId):
            guard let metadata = block.pluginMetadata else { return true }
            return metadata.pluginId != pluginId
                || (metadata.reviewedAsPlainText && metadata.stale)
        default:
            return block.pluginMetadata != nil
        }
    }
}
