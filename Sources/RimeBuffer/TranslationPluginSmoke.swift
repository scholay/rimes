import Foundation

private final class TranslationSmokeDeliverySource: BufferDeliveryContentSource {
    let deliveryWorkspaceID = "translation-smoke"
    var deliveryGeneration: UInt64 = 1
    var hasIncompleteDeliveryBlocks = false
    var prepareAllowed = true
    var blocks: [BufferModel.Block]
    private(set) var consumedIDs: [UUID] = []
    private(set) var prepareCallCount = 0

    init(texts: [String], allowsRemoteMirror: Bool = true) {
        blocks = texts.map {
            BufferModel.Block(
                text: $0,
                origin: .processor(id: AppleTranslationWorkspace.processorID,
                                   allowsRemoteMirror: allowsRemoteMirror)
            )
        }
    }

    var deliveryPendingBlocks: [BufferModel.Block] {
        hasIncompleteDeliveryBlocks ? [] : blocks
    }

    func prepareForDelivery() -> Bool {
        prepareCallCount += 1
        return prepareAllowed
    }

    func deliveryBlock(id: UUID, generation: UInt64) -> BufferModel.Block? {
        guard generation == deliveryGeneration else { return nil }
        return blocks.first { $0.id == id }
    }

    func consumeDelivered(blockIDs: [UUID], generation: UInt64) {
        let ids = Set(blockIDs)
        let consumed = blocks.filter { ids.contains($0.id) }
        consumedIDs.append(contentsOf: consumed.map(\.id))
        blocks.removeAll { ids.contains($0.id) }
        if !consumed.isEmpty { deliveryGeneration &+= 1 }
    }

    func consumeDeliveredAndReportTerminalDrain(
        blockIDs: [UUID],
        generation: UInt64
    ) -> BufferDeliveryTerminalSourceReceipt? {
        let generationBeforeConsumption = deliveryGeneration
        let matchingIDs = Set(blocks.lazy.filter {
            blockIDs.contains($0.id)
        }.map(\.id))
        consumeDelivered(blockIDs: blockIDs, generation: generation)
        guard generation == generationBeforeConsumption,
              !matchingIDs.isEmpty,
              blocks.isEmpty else { return nil }
        return BufferDeliveryTerminalSourceReceipt(
            workspaceID: deliveryWorkspaceID,
            generation: generationBeforeConsumption,
            generationAfterConsumption: deliveryGeneration,
            consumedBlockIDs: matchingIDs
        )
    }

    func markDeliveryBlockStale(id: UUID, generation: UInt64) -> Bool { false }
}

private final class TranslationConfigurationNotificationProbe {
    private(set) var changedFieldIDs: Set<String> = []

    func reset() {
        changedFieldIDs.removeAll()
    }

    func record(_ notification: Notification) {
        guard notification.userInfo?[
            PluginConfigurationNotificationKey.pluginID
        ] as? String == BuiltInPluginID.appleTranslation else {
            return
        }
        changedFieldIDs.formUnion(
            notification.userInfo?[
                PluginConfigurationNotificationKey.changedFieldIDs
            ] as? [String] ?? []
        )
    }
}

func runTranslationPluginSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: translation plugin \(message)")
        return false
    }

    func runMainLoopUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while !predicate(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default,
                                    before: Date(timeIntervalSinceNow: 0.01))
        }
        return predicate()
    }

    guard TranslationRefreshPolicy.deadline(lastChange: 0.2, burstStarted: 0) == 0.5,
          TranslationRefreshPolicy.deadline(lastChange: 0.8, burstStarted: 0) == 0.9 else {
        return fail("debounce / maximum-wait policy")
    }
    let coarseTranslation = "This translation contains several useful words and another phrase. 最后一句，也要单独发送。"
    let translationSegments = SemanticBlockSegmenter.refine(
        [SemanticLogicalBlock(sourceIndex: 0,
                              text: coarseTranslation,
                              title: nil)],
        maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
    )
    guard translationSegments.count > 2,
          translationSegments.map(\.text).joined() == coarseTranslation else {
        return fail("shared semantic segmentation")
    }

    let defaultsName = "RimeBuffer.TranslationPluginSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsName) else {
        return fail("defaults suite")
    }
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let sourceDefaultsKey = "plugins.appleTranslation.sourceLanguage.v1"
    let targetDefaultsKey = "plugins.appleTranslation.targetLanguage.v1"
    let configurationDefaultsKey =
        "RimeBuffer.PluginConfiguration."
            + BuiltInPluginID.appleTranslation

    let missingSourceWorkspace = AppleTranslationWorkspace(
        defaults: defaults,
        sourceModel: BufferModel()
    )
    guard TranslationLanguageIdentity.matches(
            missingSourceWorkspace.sourceLanguageID,
            expected: AppleTranslationWorkspace.defaultSourceLanguageID
          ),
          defaults.string(forKey: sourceDefaultsKey)
            == AppleTranslationWorkspace.defaultSourceLanguageID else {
        return fail("missing source must migrate to Chinese")
    }

    defaults.set("auto", forKey: sourceDefaultsKey)
    defaults.set("zh", forKey: targetDefaultsKey)
    let automaticSourceWorkspace = AppleTranslationWorkspace(
        defaults: defaults,
        sourceModel: BufferModel()
    )
    guard TranslationLanguageIdentity.matches(
            automaticSourceWorkspace.sourceLanguageID,
            expected: AppleTranslationWorkspace.defaultSourceLanguageID
          ),
          TranslationLanguageIdentity.matches(
            automaticSourceWorkspace.targetLanguageID,
            expected: AppleTranslationWorkspace.defaultTargetLanguageID
          ),
          defaults.string(forKey: sourceDefaultsKey) != "auto" else {
        return fail("automatic source migration and distinct target")
    }

    defaults.set("ja", forKey: sourceDefaultsKey)
    defaults.set("en", forKey: targetDefaultsKey)
    let explicitSourceWorkspace = AppleTranslationWorkspace(
        defaults: defaults,
        sourceModel: BufferModel()
    )
    guard explicitSourceWorkspace.sourceLanguageID == "ja",
          explicitSourceWorkspace.targetLanguageID == "en" else {
        return fail("explicit source preservation")
    }

    let swapProbe = TranslationConfigurationNotificationProbe()
    let swapObserver = NotificationCenter.default.addObserver(
        forName: .pluginConfigurationDidChange,
        object: nil,
        queue: nil
    ) { notification in
        swapProbe.record(notification)
    }
    defer { NotificationCenter.default.removeObserver(swapObserver) }
    guard explicitSourceWorkspace.canSwapLanguages,
          explicitSourceWorkspace.swapLanguages(),
          explicitSourceWorkspace.sourceLanguageID == "en",
          explicitSourceWorkspace.targetLanguageID == "ja",
          defaults.string(forKey: sourceDefaultsKey) == "en",
          defaults.string(forKey: targetDefaultsKey) == "ja",
          defaults.dictionary(
            forKey: configurationDefaultsKey
          )?[RealtimeTranslationPluginConfigurationFieldID.sourceLanguage]
            as? String == "en",
          defaults.dictionary(
            forKey: configurationDefaultsKey
          )?[RealtimeTranslationPluginConfigurationFieldID.targetLanguage]
            as? String == "ja",
          swapProbe.changedFieldIDs == [
            RealtimeTranslationPluginConfigurationFieldID.sourceLanguage,
            RealtimeTranslationPluginConfigurationFieldID.targetLanguage,
          ] else {
        return fail("language swap persistence and refresh notification")
    }
    swapProbe.reset()
    explicitSourceWorkspace.setSourceLanguage("sv")
    guard explicitSourceWorkspace.sourceLanguageID == "sv",
          explicitSourceWorkspace.targetLanguageID == "ja",
          swapProbe.changedFieldIDs == [
            RealtimeTranslationPluginConfigurationFieldID.sourceLanguage,
          ] else {
        return fail("runtime-discovered language persistence")
    }
    swapProbe.reset()
    guard explicitSourceWorkspace.swapLanguages(),
          explicitSourceWorkspace.sourceLanguageID == "ja",
          explicitSourceWorkspace.targetLanguageID == "sv",
          swapProbe.changedFieldIDs == [
            RealtimeTranslationPluginConfigurationFieldID.sourceLanguage,
            RealtimeTranslationPluginConfigurationFieldID.targetLanguage,
          ] else {
        return fail("runtime-discovered language swap")
    }

    let currentJob = AppleTranslationWorkspace.Job(generation: 4,
                                                    sourceText: "你好",
                                                    sourceLanguageID: "zh-Hans",
                                                    targetLanguageID: "en")
    let supersedingJob = AppleTranslationWorkspace.Job(generation: 5,
                                                       sourceText: "你好！",
                                                       sourceLanguageID: "zh-Hans",
                                                       targetLanguageID: "en")
    guard TranslationResultGate.acceptsResponse(
            job: currentJob,
            activeJob: currentJob,
            active: true,
            responseSourceText: "你好",
            responseSourceLanguageID: "zh",
            responseTargetLanguageID: "en"
          ),
          !TranslationResultGate.acceptsResponse(
            job: currentJob,
            activeJob: supersedingJob,
            active: true,
            responseSourceText: "你好",
            responseSourceLanguageID: "zh",
            responseTargetLanguageID: "en"
          ),
          !TranslationResultGate.acceptsResponse(
            job: currentJob,
            activeJob: currentJob,
            active: true,
            responseSourceText: "你好！",
            responseSourceLanguageID: "zh",
            responseTargetLanguageID: "en"
          ),
          !TranslationResultGate.acceptsResponse(
            job: currentJob,
            activeJob: currentJob,
            active: true,
            responseSourceText: "你好",
            responseSourceLanguageID: "zh",
            responseTargetLanguageID: "ja"
          ),
          TranslationResultGate.isCurrent(job: currentJob,
                                          sourceText: "你好",
                                          sourceLanguageID: "zh",
                                          targetLanguageID: "en"),
          !TranslationResultGate.isCurrent(job: currentJob,
                                           sourceText: "你好！",
                                           sourceLanguageID: "zh",
                                           targetLanguageID: "en") else {
        return fail("latest-generation result gate")
    }

    let explicitSourceJob = AppleTranslationWorkspace.Job(
        generation: 6,
        sourceText: "你好",
        sourceLanguageID: "zh-Hans",
        targetLanguageID: "en-US"
    )
    guard TranslationResultGate.acceptsResponse(
            job: explicitSourceJob,
            activeJob: explicitSourceJob,
            active: true,
            responseSourceText: "你好",
            responseSourceLanguageID: "zh",
            responseTargetLanguageID: "en"
          ),
          !TranslationResultGate.acceptsResponse(
            job: explicitSourceJob,
            activeJob: explicitSourceJob,
            active: true,
            responseSourceText: "你好",
            responseSourceLanguageID: "ja",
            responseTargetLanguageID: "en"
          ),
          TranslationLanguageIdentity.supportedIdentifier(
            for: "zh-Hans",
            among: ["en", "zh", "zh-TW"]
          ) == "zh",
          TranslationResultGate.isCurrent(job: explicitSourceJob,
                                          sourceText: "你好",
                                          sourceLanguageID: "zh",
                                          targetLanguageID: "en") else {
        return fail("language alias and explicit-source validation")
    }

    let sourceModel = BufferModel()
    sourceModel.stageExternal("你好", origin: .rime)
    sourceModel.append("世界", origin: .remotePeer(deviceID: "peer"))
    guard sourceModel.stagedText == "你好世界",
          sourceModel.removeLastCharacter(),
          sourceModel.stagedText == "你好世" else {
        return fail("merged source buffer semantics")
    }

    var epochs = FocusEpochState()
    let focus = epochs.activate()
    let targetBinding = BufferModel.PluginMetadata(
        pluginId: "marine",
        actionId: "comment",
        requestId: "request",
        contextId: "context",
        focusToken: focus,
        runtimeIdentity: "runtime"
    )
    guard TranslationSourcePolicy.accepts([
        BufferModel.Block(text: "typed", origin: .rime),
        BufferModel.Block(text: "remote", origin: .remotePeer(deviceID: "peer")),
    ]),
    !TranslationSourcePolicy.accepts([
        BufferModel.Block(text: "bound",
                          origin: .plugin(id: "marine"),
                          pluginMetadata: targetBinding),
    ]),
    !TranslationSourcePolicy.accepts([
        BufferModel.Block(text: "unbound", origin: .plugin(id: "marine")),
    ]),
    TranslationSourcePolicy.accepts([
        BufferModel.Block(text: "reviewed",
                          origin: .plugin(id: "marine"),
                          pluginMetadata: targetBinding.markingReviewedAsPlainText()),
    ]) else {
        return fail("target-bound plugin source isolation")
    }
    var inserted: [String] = []
    var rejectSecond = false
    var mutateAfterFirst: (() -> Void)?
    var deliveryCalls = 0
    var terminalContexts: [BufferDeliveryCoordinator.TerminalDrainContext] = []
    let dependencies = BufferDeliveryCoordinator.Dependencies(
        resolveTarget: { expected in
            guard expected == nil || expected == focus else { return nil }
            return .init(token: focus,
                         compositionActive: false,
                         resolveComposition: {},
                         deliver: { block in
                             deliveryCalls += 1
                             if rejectSecond, deliveryCalls == 2 { return false }
                             inserted.append(block.text)
                             if deliveryCalls == 1 { mutateAfterFirst?() }
                             return true
                         })
        },
        secureInputEnabled: { false },
        validatePlugin: { _, _, completion in completion(.allowed) },
        refreshUI: {},
        workbenchSessionEpoch: { 41 },
        terminalDrainDelivered: { terminalContexts.append($0) }
    )

    let incomplete = TranslationSmokeDeliverySource(texts: ["Hello"])
    incomplete.hasIncompleteDeliveryBlocks = true
    let incompleteCoordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { incomplete }
    )
    guard incompleteCoordinator.availability() == .blocked(.pluginResultIncomplete),
          incompleteCoordinator.sendAll().blockedReason == .pluginResultIncomplete,
          incomplete.blocks.count == 1 else {
        return fail("incomplete target exposure")
    }

    let translated = TranslationSmokeDeliverySource(texts: ["Hello", " world"],
                                                     allowsRemoteMirror: false)
    guard translated.blocks.allSatisfy({ !$0.origin.allowsRemoteMirror }) else {
        return fail("processor mirror policy inheritance")
    }
    translated.prepareAllowed = false
    let prepareBlockedCoordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { translated }
    )
    let prepareBlocked = prepareBlockedCoordinator.sendNext(expectedToken: focus)
    guard prepareBlocked.sentCount == 0,
          prepareBlocked.blockedReason == .contentChanged,
          translated.prepareCallCount == 1,
          inserted.isEmpty,
          translated.blocks.count == 2 else {
        return fail("delivery preparation must precede host insertion")
    }
    translated.prepareAllowed = true
    inserted.removeAll()
    deliveryCalls = 0
    let coordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { translated }
    )
    let sent = coordinator.sendAll(expectedToken: focus)
    guard let terminalContext = sent.terminalDrain,
          sent.succeeded,
          sent.sentCount == 2,
          inserted == ["Hello", " world"],
          translated.blocks.isEmpty,
          translated.consumedIDs.count == 2,
          translated.prepareCallCount == 2,
          terminalContext.workspaceID == translated.deliveryWorkspaceID,
          terminalContext.workbenchSessionEpoch == 41,
          terminalContext.sourceGenerationAfterConsumption
            == translated.deliveryGeneration,
          terminalContext.matchesCurrentSource(translated),
          terminalContexts.isEmpty,
          runMainLoopUntil({ terminalContexts.count == 1 }),
          terminalContexts.first == sent.terminalDrain else {
        return fail("target-only send-all")
    }
    translated.deliveryGeneration &+= 1
    guard !terminalContext.matchesCurrentSource(translated) else {
        return fail("post-consumption generation must invalidate deferred close")
    }


    terminalContexts.removeAll()
    let oneAtATime = TranslationSmokeDeliverySource(texts: ["first", "last"])
    inserted.removeAll()
    deliveryCalls = 0
    let oneAtATimeCoordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { oneAtATime }
    )
    let firstResult = oneAtATimeCoordinator.sendNext(expectedToken: focus)
    guard firstResult.succeeded,
          firstResult.terminalDrain == nil,
          terminalContexts.isEmpty,
          oneAtATime.blocks.map(\.text) == ["last"] else {
        return fail("nonterminal source block requested workbench close")
    }
    let lastResult = oneAtATimeCoordinator.sendNext(expectedToken: focus)
    guard lastResult.succeeded,
          lastResult.terminalDrain != nil,
          terminalContexts.isEmpty,
          runMainLoopUntil({ terminalContexts.count == 1 }),
          terminalContexts.first == lastResult.terminalDrain else {
        return fail("last source block did not defer terminal callback")
    }

    let partial = TranslationSmokeDeliverySource(texts: ["one", "two"])
    terminalContexts.removeAll()
    inserted.removeAll()
    deliveryCalls = 0
    rejectSecond = true
    let partialCoordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { partial }
    )
    let partialResult = partialCoordinator.sendAll(expectedToken: focus)
    guard partialResult.sentCount == 1,
          partialResult.blockedReason == .deliveryRejected,
          inserted == ["one"],
          partial.blocks.map(\.text) == ["two"],
          partialResult.terminalDrain == nil,
          terminalContexts.isEmpty else {
        return fail("partial failure retention")
    }

    let changing = TranslationSmokeDeliverySource(texts: ["old-1", "old-2"])
    terminalContexts.removeAll()
    inserted.removeAll()
    deliveryCalls = 0
    rejectSecond = false
    mutateAfterFirst = { changing.deliveryGeneration &+= 1 }
    let changingCoordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: dependencies,
        contentSourceResolver: { changing }
    )
    let changingResult = changingCoordinator.sendAll(expectedToken: focus)
    mutateAfterFirst = nil
    guard changingResult.sentCount == 1,
          changingResult.blockedReason == .contentChanged,
          inserted == ["old-1"],
          changing.blocks.map(\.text) == ["old-2"],
          changingResult.terminalDrain == nil,
          terminalContexts.isEmpty else {
        return fail("live generation revalidation")
    }

    let ordinary = BufferModel()
    ordinary.append("default-1", origin: .rime)
    ordinary.append("default-2", origin: .rime)
    terminalContexts.removeAll()
    inserted.removeAll()
    deliveryCalls = 0
    let ordinaryCoordinator = BufferDeliveryCoordinator(
        model: ordinary,
        dependencies: dependencies,
        contentSourceResolver: { ordinary }
    )
    let ordinaryFirstResult = ordinaryCoordinator.sendNext(expectedToken: focus)
    guard ordinaryFirstResult.succeeded,
          ordinaryFirstResult.sentCount == 1,
          ordinaryFirstResult.terminalDrain == nil,
          inserted == ["default-1"],
          ordinary.blocks.map(\.text) == ["default-2"],
          terminalContexts.isEmpty else {
        return fail("nonterminal Default block requested workbench close")
    }
    let ordinaryLastResult = ordinaryCoordinator.sendNext(expectedToken: focus)
    guard ordinaryLastResult.succeeded,
          ordinaryLastResult.sentCount == 1,
          ordinaryLastResult.terminalDrain != nil,
          inserted == ["default-1", "default-2"],
          ordinary.blocks.isEmpty,
          terminalContexts.isEmpty,
          runMainLoopUntil({ terminalContexts.count == 1 }),
          terminalContexts.first == ordinaryLastResult.terminalDrain else {
        return fail("last Default block did not defer terminal callback")
    }

    print("translation plugin smoke OK")
    return true
}
