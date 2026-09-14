import AppKit
import Foundation

private final class AutoSendProbeSource: BufferDeliveryContentSource {
    var deliveryWorkspaceID = "auto-send-target-probe"
    var deliveryGeneration: UInt64 = 1
    var hasIncompleteDeliveryBlocks = false
    var supportsIncrementalDelivery = false
    var automaticDeliverySessionActive = true
    var deliveryPendingBlocks: [BufferModel.Block] = []

    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block? {
        guard generation == deliveryGeneration else { return nil }
        return deliveryPendingBlocks.first { $0.id == id }
    }

    func consumeDelivered(blockIDs: [UUID], generation: UInt64) {
        guard generation == deliveryGeneration else { return }
        deliveryPendingBlocks.removeAll { blockIDs.contains($0.id) }
    }

    func markDeliveryBlockStale(id: UUID, generation: UInt64) -> Bool { false }
}

/// Exercises the same monotonic state machine used by the live window and the
/// real delivery coordinator with inert source/focus/client dependencies.
func runBufferAutoSendClockSmoke() -> Bool {
    let source = AutoSendProbeSource()
    let first = BufferModel.Block(text: "first")
    let second = BufferModel.Block(text: "second")
    var clock = BufferAutoSendClock()
    func synchronize(_ blocks: [BufferModel.Block]) {
        clock.synchronize(sourceIdentity: ObjectIdentifier(source),
                          workspaceID: source.deliveryWorkspaceID,
                          blocks: blocks)
    }
    func near(_ value: TimeInterval?, _ expected: TimeInterval) -> Bool {
        abs((value ?? -1) - expected) < 0.000_001
    }
    synchronize([first])
    guard clock.tick(uptime: 100, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0 else {
        print("FAILED: a new auto-send block must start at zero")
        return false
    }
    _ = clock.tick(uptime: 100.5, canAge: true, lifetime: 1)
    synchronize([first, second])
    _ = clock.tick(uptime: 100.8, canAge: true, lifetime: 1)
    guard near(clock.ages[first.id], 0.8), clock.ages[second.id] == 0 else {
        print("FAILED: new blocks inherited an older block's tick interval")
        return false
    }
    clock.pause() // The exact method used by hide, focus loss and pause.
    _ = clock.tick(uptime: 500, canAge: true, lifetime: 1)
    guard near(clock.ages[first.id], 0.8), clock.ages[second.id] == 0,
          clock.tick(uptime: 500.3, canAge: true, lifetime: 1) == first.id,
          clock.ages[first.id] == 1,
          near(clock.ages[second.id], 0.3) else {
        print("FAILED: hidden time advanced ages or the ready head was removed before success")
        return false
    }
    synchronize([second]) // Only successful consumption retires first.
    guard clock.ages[first.id] == nil, near(clock.ages[second.id], 0.3) else {
        print("FAILED: consuming the head reset a younger block")
        return false
    }
    synchronize([])
    _ = clock.tick(uptime: 900, canAge: true, lifetime: 1)
    synchronize([first])
    guard clock.tick(uptime: 901, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0,
          clock.tick(uptime: 901.9, canAge: true, lifetime: 1) == nil,
          clock.tick(uptime: 902, canAge: true, lifetime: 1) == first.id else {
        print("FAILED: empty idle time was inherited by a new first block")
        return false
    }
    // An empty/refill transition occurs entirely between timer fires.
    synchronize([])
    synchronize([first])
    guard clock.tick(uptime: 903, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0 else {
        print("FAILED: between-tick drain/refill retained a stale countdown")
        return false
    }
    _ = clock.tick(uptime: 903.4, canAge: true, lifetime: 1)
    var revised = first
    revised.text = "edited first"
    synchronize([revised])
    guard clock.tick(uptime: 904, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0 else {
        print("FAILED: same-ID replacement retained the old text's lifetime")
        return false
    }
    _ = clock.tick(uptime: 904.4, canAge: true, lifetime: 1)
    _ = clock.tick(uptime: 920, canAge: false, lifetime: 1)
    _ = clock.tick(uptime: 950, canAge: true, lifetime: 1)
    guard near(clock.ages[first.id], 0.4) else {
        print("FAILED: unavailable/protected interval was credited after resume")
        return false
    }
    let otherSource = AutoSendProbeSource()
    clock.synchronize(sourceIdentity: ObjectIdentifier(otherSource),
                      workspaceID: source.deliveryWorkspaceID,
                      blocks: [revised])
    guard clock.tick(uptime: 960, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0 else {
        print("FAILED: a different concrete source inherited ages")
        return false
    }
    _ = clock.tick(uptime: 960.5, canAge: true, lifetime: 1)
    clock.synchronize(sourceIdentity: ObjectIdentifier(otherSource),
                      workspaceID: "another-workspace",
                      blocks: [revised])
    guard clock.tick(uptime: 970, canAge: true, lifetime: 1) == nil,
          clock.ages[first.id] == 0 else {
        print("FAILED: a different workspace inherited ages")
        return false
    }
    clock.reset() // Toggle off/protection forgets plaintext countdown state.
    guard clock.ages.isEmpty else { return false }

    let sourceModel = BufferModel() // Deliberately empty: target is separate.
    source.deliveryPendingBlocks = [first, second]
    source.hasIncompleteDeliveryBlocks = true
    var epochs = FocusEpochState()
    let token = epochs.activate()
    var currentToken: FocusToken? = token
    var composing = true
    var secure = false
    var acceptsDelivery = false
    var compositionResolutions = 0
    var deliveries: [String] = []
    var workbenchEpoch: UInt64 = 10
    var pendingValidation: ((ActionPluginDeliveryDecision) -> Void)?
    var routedSource = source
    let coordinator = BufferDeliveryCoordinator(
        model: sourceModel,
        dependencies: .init(
            resolveTarget: { expected in
                guard let currentToken,
                      expected == nil || expected == currentToken else { return nil }
                return .init(token: currentToken,
                             compositionActive: composing,
                             resolveComposition: { compositionResolutions += 1 },
                             deliver: { block in
                                 guard acceptsDelivery else { return false }
                                 deliveries.append(block.text)
                                 return true
                             })
            },
            secureInputEnabled: { secure },
            validatePlugin: { _, _, completion in
                pendingValidation = completion
            },
            refreshUI: {},
            workbenchSessionEpoch: { workbenchEpoch }
        ),
        contentSourceResolver: { routedSource }
    )
    guard coordinator.automaticDeliverySnapshot() == nil else {
        print("FAILED: an ordinary incomplete workspace became ageable")
        return false
    }
    source.supportsIncrementalDelivery = true
    guard let snapshot = coordinator.automaticDeliverySnapshot(),
          snapshot.blocks.map(\.id) == [first.id, second.id],
          sourceModel.blocks.isEmpty,
          coordinator.availability() == .blocked(.composing),
          BufferGeneratedResultCopyRules.freeze(protected: false, source: source) == nil else {
        print("FAILED: ready-prefix aging, source/target routing or incomplete-copy gate")
        return false
    }
    clock.synchronize(sourceIdentity: snapshot.sourceIdentity,
                      workspaceID: snapshot.workspaceID,
                      blocks: snapshot.blocks)
    _ = clock.tick(uptime: 1000, canAge: true, lifetime: 1)
    guard clock.tick(uptime: 1001, canAge: true, lifetime: 1) == first.id,
          coordinator.sendNextAutomatically(snapshot).blockedReason == .composing,
          compositionResolutions == 0, deliveries.isEmpty,
          source.deliveryPendingBlocks.count == 2 else {
        print("FAILED: aging while composing must never settle or insert composition")
        return false
    }
    composing = false
    guard coordinator.availability() == .ready,
          coordinator.sendNextAutomatically(snapshot).blockedReason == .deliveryRejected,
          clock.ages[first.id] == 1,
          source.deliveryPendingBlocks.count == 2 else {
        print("FAILED: failed auto-send consumed content or lost its age")
        return false
    }
    secure = true
    guard coordinator.automaticDeliverySnapshot() == nil,
          coordinator.sendNextAutomatically(snapshot).blockedReason == .secureInput else {
        print("FAILED: automatic delivery bypassed secure input")
        return false
    }
    secure = false
    source.automaticDeliverySessionActive = false
    guard coordinator.automaticDeliverySnapshot() == nil,
          coordinator.sendNextAutomatically(snapshot).blockedReason == .contentChanged else {
        print("FAILED: an explicitly paused source retained automatic delivery authority")
        return false
    }
    source.automaticDeliverySessionActive = true
    currentToken = nil
    guard coordinator.automaticDeliverySnapshot() == nil,
          coordinator.sendNextAutomatically(snapshot).blockedReason == .targetChanged else {
        print("FAILED: automatic delivery bypassed exact focus")
        return false
    }
    currentToken = token
    routedSource = otherSource
    guard coordinator.sendNextAutomatically(snapshot).blockedReason == .contentChanged else {
        print("FAILED: a timer lease sent a different source")
        return false
    }
    routedSource = source
    source.deliveryPendingBlocks[0] = revised
    guard coordinator.sendNextAutomatically(snapshot).blockedReason == .contentChanged else {
        print("FAILED: a timer lease sent replacement head text")
        return false
    }
    source.deliveryPendingBlocks[0] = first
    source.deliveryGeneration += 1
    guard coordinator.sendNextAutomatically(snapshot).blockedReason == .contentChanged,
          let current = coordinator.automaticDeliverySnapshot() else {
        print("FAILED: automatic delivery accepted a stale generation")
        return false
    }
    clock.synchronize(sourceIdentity: current.sourceIdentity,
                      workspaceID: current.workspaceID,
                      blocks: current.blocks)
    guard clock.ages[first.id] == 1 else {
        print("FAILED: an unrelated tail generation reset stable-prefix ages")
        return false
    }
    acceptsDelivery = true
    let delivered = coordinator.sendNextAutomatically(current)
    guard delivered.sentCount == 1, delivered.terminalDrain == nil,
          deliveries == [first.text],
          source.deliveryPendingBlocks.map(\.id) == [second.id] else {
        print("FAILED: automatic prefix send lost ordering or falsely drained an incomplete tail")
        return false
    }
    let tail = coordinator.sendAll(resolveCompositionIfNeeded: false, expectedToken: token)
    guard tail.sentCount == 1, tail.terminalDrain == nil,
          source.deliveryPendingBlocks.isEmpty,
          source.hasIncompleteDeliveryBlocks,
          compositionResolutions == 0 else {
        print("FAILED: ready-prefix drain closed over pending untranslated source")
        return false
    }
    // An async plugin response must not send after the workbench was hidden
    // or explicitly paused while target validation was outstanding.
    let pluginBlock = BufferModel.Block(
        text: "Deferred plugin target",
        origin: .plugin(id: "auto-probe"),
        pluginMetadata: .init(pluginId: "auto-probe",
                              actionId: "generate",
                              requestId: "auto-probe-request",
                              contextId: "auto-probe-context",
                              focusToken: token,
                              runtimeIdentity: "auto-probe-runtime")
    )
    source.deliveryPendingBlocks = [pluginBlock]
    source.hasIncompleteDeliveryBlocks = false
    guard let deferredSnapshot = coordinator.automaticDeliverySnapshot() else { return false }
    workbenchEpoch += 1
    guard coordinator.sendNextAutomatically(deferredSnapshot).blockedReason == .contentChanged,
          let currentDeferredSnapshot = coordinator.automaticDeliverySnapshot() else {
        print("FAILED: a hidden/reopened workbench reused an older timer snapshot")
        return false
    }
    var deferredResult: BufferDeliveryCoordinator.SendResult?
    guard coordinator.sendNextAutomatically(currentDeferredSnapshot, completion: {
        deferredResult = $0
    }).deferred, let validation = pendingValidation else { return false }
    pendingValidation = nil
    workbenchEpoch += 1
    validation(.allowed)
    guard deferredResult?.sentCount == 0,
          deferredResult?.blockedReason == .contentChanged,
          source.deliveryPendingBlocks.count == 1,
          deliveries == [first.text, second.text],
          let pauseSnapshot = coordinator.automaticDeliverySnapshot() else {
        print("FAILED: deferred auto-send survived workbench session invalidation")
        return false
    }
    deferredResult = nil
    guard coordinator.sendNextAutomatically(pauseSnapshot, completion: {
        deferredResult = $0
    }).deferred, let pauseValidation = pendingValidation else { return false }
    pendingValidation = nil
    source.automaticDeliverySessionActive = false
    pauseValidation(.allowed)
    guard deferredResult?.blockedReason == .contentChanged,
          source.deliveryPendingBlocks.count == 1,
          deliveries == [first.text, second.text] else {
        print("FAILED: deferred auto-send survived explicit source pause")
        return false
    }
    // A live client whose box cannot be named is not a target: nothing is
    // offered for sending and the countdown never starts.
    let boxSource = AutoSendProbeSource()
    boxSource.deliveryPendingBlocks = [BufferModel.Block(text: "box")]
    let unlocked = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: .init(
            resolveTarget: { _ in
                .init(token: token,
                      compositionActive: false,
                      resolveComposition: {},
                      deliver: { _ in true })
            },
            secureInputEnabled: { false },
            validatePlugin: { _, _, completion in completion(.allowed) },
            refreshUI: {},
            targetBoxPermitsDelivery: { _ in false }
        ),
        contentSourceResolver: { boxSource }
    )
    guard unlocked.availability() == .blocked(.targetBoxUnverified),
          unlocked.automaticDeliverySnapshot() == nil else {
        print("FAILED: an unidentified box must block sending and auto-send")
        return false
    }
    return runAutoSendLifetimeChoiceSmoke()
        && runIncrementalTranslationChipAppearanceSmoke()
}

/// The lifetime is now the user's to pick in the toolbar, so the clock has to
/// hold a block for exactly the chosen window rather than a built-in one, and
/// a longer choice must not let an already-aged block leave early.
private func runAutoSendLifetimeChoiceSmoke() -> Bool {
    let source = AutoSendProbeSource()
    let block = BufferModel.Block(text: "held")
    var clock = BufferAutoSendClock()
    clock.synchronize(sourceIdentity: ObjectIdentifier(source),
                      workspaceID: source.deliveryWorkspaceID,
                      blocks: [block])
    _ = clock.tick(uptime: 10, canAge: true, lifetime: 3)
    guard clock.tick(uptime: 11, canAge: true, lifetime: 3) == nil,
          clock.tick(uptime: 12.9, canAge: true, lifetime: 3) == nil,
          clock.tick(uptime: 13, canAge: true, lifetime: 3) == block.id else {
        print("FAILED: a three-second choice must deliver at three seconds")
        return false
    }

    // Raising the choice mid-countdown extends the wait rather than firing on
    // the age the shorter window had already accumulated.
    var raised = BufferAutoSendClock()
    raised.synchronize(sourceIdentity: ObjectIdentifier(source),
                       workspaceID: source.deliveryWorkspaceID,
                       blocks: [block])
    _ = raised.tick(uptime: 20, canAge: true, lifetime: 1)
    guard raised.tick(uptime: 21, canAge: true, lifetime: 5) == nil,
          raised.tick(uptime: 25, canAge: true, lifetime: 5) == block.id else {
        print("FAILED: raising the lifetime must extend the remaining wait")
        return false
    }

    // Every value the toolbar offers is a real countdown; none may read as
    // "never age", which is what a zero or unset preference would mean.
    guard BufferWindowController.autoSendLifetimeChoices.allSatisfy({ $0 > 0 }),
          BufferWindowController.autoSendLifetimeChoices
            .contains(BufferWindowController.defaultAutoSendLifetime) else {
        print("FAILED: toolbar lifetime choices must all be real countdowns")
        return false
    }
    return true
}

private func runIncrementalTranslationChipAppearanceSmoke() -> Bool {
    let prefixID = UUID()
    let tailID = UUID()
    let prefix = TranslationOutputBlock(id: prefixID,
                                        text: "Stable translated sentence.",
                                        deliveryReady: true)
    let tail = TranslationOutputBlock(id: tailID,
                                      text: "Earlier tail preview")
    let view = BufferInlineView(frame: NSRect(x: 0, y: 0, width: 760, height: 78))
    view.renderTranslationForPreview(.init(sourceText: "Editing the next sentence",
                                          outputBlocks: [prefix, tail],
                                          phase: .translating,
                                          message: nil))
    guard view.renderedTranslationTargetOpacities[prefixID] == 1,
          view.renderedTranslationTargetOpacities[tailID] == 0.7 else {
        print("FAILED: a ready translation prefix looked stale while its tail translated")
        return false
    }
    view.setAutoSendFade([prefixID: 0.5])
    guard let prefixOpacity = view.renderedTranslationTargetOpacities[prefixID],
          abs(prefixOpacity - 0.725) < 0.000_001,
          view.renderedTranslationTargetOpacities[tailID] == 0.7 else {
        print("FAILED: target countdown fade overwrote per-chip readiness appearance")
        return false
    }
    view.setAutoSendFade([:])
    view.renderTranslationForPreview(.init(sourceText: "Unchanged source",
                                          outputBlocks: [tail],
                                          phase: .ready,
                                          message: nil))
    guard view.renderedTranslationTargetOpacities[tailID] == 1 else {
        print("FAILED: default deliveryReady changed other plugins' complete-result appearance")
        return false
    }
    view.refresh(shielded: true, translationSnapshot: nil)
    guard view.renderedTranslationTargetOpacities.isEmpty else {
        print("FAILED: protected translation retained target chips")
        return false
    }
    return true
}
