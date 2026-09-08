import Foundation

private final class TranslationLifecycleTask: AITextCancellable {
    func cancel() {}
}

private final class TranslationLifecycleProvider: AITextProvider {
    let kind: AITextProviderKind = .openAICompatible
    var availability: AITextProviderAvailability = .ready
    var requests: [AITextProviderRequest] = []
    var completions: [(Result<[AITextProviderBlock], AITextProviderError>) -> Void] = []

    func generate(_ request: AITextProviderRequest,
                  onEvent: @escaping (AITextProviderEvent) -> Void,
                  completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void
    ) -> any AITextCancellable {
        requests.append(request)
        completions.append(completion)
        return TranslationLifecycleTask()
    }

    func complete(_ index: Int, _ text: String) {
        guard completions.indices.contains(index) else {
            print("FAILED: missing translation fixture request \(index)")
            return
        }
        completions[index](.success([AITextProviderBlock(index: 0, text: text, title: nil)]))
    }
}

private final class TranslationLifecycleSelection {
    var selected = true
}

private final class TranslationLifecycleHarness {
    let suite = "RimeBuffer.TranslationLifecycleSmoke.\(UUID().uuidString)"
    let defaults: UserDefaults
    let model = BufferModel()
    let provider = TranslationLifecycleProvider()
    let selection = TranslationLifecycleSelection()
    let workspace: AppleTranslationWorkspace

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(RealtimeTranslationProviderKind.aiConnector.rawValue,
                     forKey: RealtimeTranslationConfigurationKey.provider)
        let selection = selection
        workspace = AppleTranslationWorkspace(
            defaults: defaults, sourceModel: model, aiProvider: provider,
            isSelected: { selection.selected }
        )
        workspace.start(loadSupportedLanguages: false)
    }

    deinit {
        workspace.stop()
        defaults.removePersistentDomain(forName: suite)
    }

    func request() { workspace.translatePendingNowForSmoke() }

    func direct(_ text: String, owner: Int) {
        // Simulate an active workbench without writing live capture settings.
        model.stageExternal("", origin: .rime)
        _ = model.appendDirectInputFragment(text, owner: .testing(owner))
    }

    @discardableResult
    func send(_ count: Int = 1) -> BufferDeliveryTerminalSourceReceipt? {
        guard workspace.prepareForDelivery() else { return nil }
        return workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: Array(workspace.deliveryPendingBlocks.prefix(count).map(\.id)),
            generation: workspace.deliveryGeneration
        )
    }
}

func runTranslationLifecycleSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: translation lifecycle \(message)")
        return false
    }
    guard runBufferSourceSliceSmokeTest() else { return false }

    // Two sentences in the SAME block. Editing the later sentence must not
    // invalidate the earlier in-flight job, result IDs, or countdown identity.
    do {
        let h = TranslationLifecycleHarness()
        h.model.append("第一句。第二句正在编辑")
        h.request()
        guard h.provider.requests.map(\.sourceText) == ["第一句。"] else {
            return fail("sentence request boundary")
        }
        guard h.model.removeLastCharacter() else { return fail("tail edit") }
        h.provider.complete(0, "This first sentence has several translated output blocks.")
        let ready = h.workspace.deliveryPendingBlocks
        guard ready.count > 1, h.workspace.hasIncompleteDeliveryBlocks,
              h.provider.requests.count == 2,
              h.provider.requests[1].sourceText == "第二句正在编" else {
            return fail("stable earlier completion while tail changes")
        }
        let sourceID = h.model.blocks[0].id
        guard h.send() == nil,
              h.model.stagedText == "第二句正在编",
              h.model.blocks[0].id == sourceID,
              h.workspace.deliveryPendingBlocks.map(\.id) == ready.dropFirst().map(\.id)
        else { return fail("partial delivery retires exact source but preserves target suffix") }
        guard h.model.removeLastCharacter() else { return fail("second tail edit") }
        h.provider.complete(1, "OBSOLETE TAIL MUST NEVER SEND")
        guard h.provider.requests.count == 3,
              h.provider.requests[2].sourceText == "第二句正在",
              h.workspace.deliveryPendingBlocks.map(\.id) == ready.dropFirst().map(\.id),
              !h.workspace.outputBlocks.contains(where: { $0.text.contains("OBSOLETE") })
        else { return fail("stale tail completion and sent-prefix resurrection") }
        h.provider.complete(2, "The second sentence is still being edited.")
        guard !h.workspace.hasIncompleteDeliveryBlocks,
              h.workspace.deliveryPendingBlocks.first?.id == ready[1].id,
              h.provider.requests.dropFirst().allSatisfy({ !$0.sourceText.contains("第一句") })
        else { return fail("new translation excludes retired source") }
        guard h.send(h.workspace.deliveryPendingBlocks.count) != nil,
              h.model.blocks.isEmpty, h.workspace.deliveryPendingBlocks.isEmpty
        else { return fail("terminal drain of frozen and current units") }
    }

    // Punctuation-free direct input retains its UUID while growing. A partial
    // send seals the translated snapshot; later typing starts fresh source.
    do {
        let h = TranslationLifecycleHarness()
        h.direct("a draft", owner: 71)
        h.request()
        h.provider.complete(0, "An unfinished draft with several output pieces")
        let original = h.workspace.deliveryPendingBlocks
        guard original.count > 1 else { return fail("multi-chip direct draft") }
        h.send()
        guard h.model.blocks.isEmpty,
              h.workspace.deliveryPendingBlocks.map(\.id) == original.dropFirst().map(\.id)
        else { return fail("source-empty frozen target must remain deliverable") }
        h.direct("new words", owner: 71)
        h.request()
        guard h.provider.requests.last?.sourceText == "new words",
              h.workspace.deliveryPendingBlocks.first?.id == original[1].id else {
            return fail("direct append after partial send")
        }
    }

    // Before any delivery, edits revoke only the affected unit and its UUIDs.
    do {
        let h = TranslationLifecycleHarness()
        h.direct("draft", owner: 72)
        h.request()
        h.provider.complete(0, "Draft")
        let oldID = h.workspace.deliveryPendingBlocks.first?.id
        h.direct(" changed", owner: 72)
        guard h.workspace.deliveryPendingBlocks.isEmpty else {
            return fail("mutable same-UUID source must revoke old target")
        }
        h.request()
        h.provider.complete(1, "Changed draft")
        guard h.workspace.deliveryPendingBlocks.first?.id != oldID else {
            return fail("changed translation starts a fresh lifetime")
        }
    }

    // Ordinary protection, owner changes and refresh must not discard the
    // only remaining copy of an already-started translation. Privacy discard
    // is the intentional irreversible exception.
    do {
        let h = TranslationLifecycleHarness()
        h.model.append("保留后缀")
        h.request()
        h.provider.complete(0, "Keep this remaining translation across lifecycle changes")
        h.send()
        let suffix = h.workspace.deliveryPendingBlocks
        guard !suffix.isEmpty else { return fail("lifecycle suffix fixture") }
        h.workspace.setProtected(true)
        guard h.workspace.deliveryPendingBlocks.isEmpty,
              h.workspace.outputBlocks.isEmpty else { return fail("protected output exposure") }
        h.workspace.setProtected(false)
        guard h.workspace.deliveryPendingBlocks.map(\.id) == suffix.map(\.id) else {
            return fail("protection must preserve pending immutable output")
        }
        h.selection.selected = false
        h.workspace.resetAndRefresh()
        guard h.workspace.deliveryPendingBlocks.isEmpty else { return fail("inactive owner authority") }
        h.selection.selected = true
        h.workspace.resetAndRefresh()
        guard h.workspace.deliveryPendingBlocks.map(\.id) == suffix.map(\.id),
              h.provider.requests.count == 1 else { return fail("owner/refresh replay") }
        h.workspace.setTargetLanguage("ja")
        h.workspace.resetAndRefresh()
        guard h.workspace.deliveryPendingBlocks.map(\.id) == suffix.map(\.id),
              h.provider.requests.count == 1 else { return fail("configuration replay") }
        h.model.discardForPrivacy()
        guard h.workspace.outputBlocks.isEmpty,
              h.workspace.deliveryPendingBlocks.isEmpty else { return fail("privacy must discard retained output") }
    }

    // Tokenization is lossless even around whitespace, paragraphs and emoji;
    // target sentence joins retain readable spacing without retranslating context.
    do {
        let text = "  Hello world.\n第二句👩🏽‍💻。  unfinished tail  "
        let units = TranslationSourceUnitBuilder.build(from: [.init(text: text)])
        guard units.count >= 3, units.map(\.sourceText).joined() == text,
              units.allSatisfy({ !$0.slices.isEmpty }) else {
            return fail("lossless multilingual sentence ownership")
        }
        let longText = String(repeating: "一句。", count: 250)
        let bounded = TranslationSourceUnitBuilder.build(from: [.init(text: longText)])
        guard bounded.count == SemanticBlockSegmenter.maximumWorkbenchSegments,
              bounded.map(\.sourceText).joined() == longText else {
            return fail("bounded, lossless source-unit fan-out")
        }
        let openTail = TranslationSourceUnitBuilder.build(from: [.init(text: "  尾段")])[0]
        guard TranslationSourceUnitBuilder.translatedText("Tail", for: openTail,
                                                          targetLanguageID: "en") == "  Tail ",
              TranslationSourceUnitBuilder.translatedText("尾段", for: openTail,
                                                          targetLanguageID: "zh-Hans") == "  尾段" else {
            return fail("independently sealed tail spacing")
        }
    }

    // BufferModel refreshes its UI before posting the workspace notification.
    // Readiness/copy checks in that window must see the edited unit revoked,
    // without throwing away the unchanged earlier unit's clock identity.
    do {
        let h = TranslationLifecycleHarness()
        h.model.append("前句。后句")
        h.request()
        h.provider.complete(0, "Earlier sentence.")
        let prefix = h.workspace.deliveryPendingBlocks.map(\.id)
        var observed: [UUID] = []
        var copiedIncomplete = false
        h.model.onChange = {
            observed = h.workspace.deliveryPendingBlocks.map(\.id)
            copiedIncomplete = BufferGeneratedResultCopyRules.freeze(
                protected: false, source: h.workspace
            ) != nil
        }
        _ = h.model.removeLastCharacter()
        h.model.onChange = nil
        guard !prefix.isEmpty, observed == prefix, !copiedIncomplete else {
            return fail("reentrant refresh loses stable prefix or copies incomplete tail")
        }
    }

    for appendInSameBlock in [false, true] {
        let h = TranslationLifecycleHarness()
        h.direct("old draft", owner: 73)
        h.request()
        h.provider.complete(0, "The original translation has several pending pieces")
        let original = h.workspace.deliveryPendingBlocks
        guard original.count > 1 else { return fail("reentrant fixture") }
        var epochs = FocusEpochState()
        let token = epochs.activate()
        var inserted: [String] = []
        let coordinator = BufferDeliveryCoordinator(
            model: h.model,
            dependencies: .init(
                resolveTarget: { _ in
                    .init(token: token, compositionActive: false,
                          resolveComposition: {}, deliver: { block in
                              inserted.append(block.text)
                              if appendInSameBlock {
                                  h.direct(" NEW", owner: 73)
                              } else {
                                  h.model.append("NEW")
                              }
                              return true
                          })
                },
                secureInputEnabled: { false },
                validatePlugin: { _, _, completion in completion(.allowed) },
                refreshUI: {}
            ),
            contentSourceResolver: { h.workspace }
        )
        let result = coordinator.sendNext()
        guard result.sentCount == 1, result.terminalDrain == nil,
              inserted == [original[0].text],
              h.workspace.deliveryPendingBlocks.map(\.id) == original.dropFirst().map(\.id),
              h.model.stagedText.trimmingCharacters(in: .whitespaces) == "NEW" else {
            return fail("accepted delivery source drift, same UUID=\(appendInSameBlock)")
        }
        h.request()
        guard h.provider.requests.last?.sourceText.trimmingCharacters(in: .whitespaces) == "NEW" else {
            return fail("reentrant accepted source was translated again")
        }
    }

    // If the exact original is overwritten inside insertText, the accepted
    // target must never return. Do not guess an alignment with the edited text.
    do {
        let h = TranslationLifecycleHarness()
        h.model.append("原始正文")
        h.request()
        h.provider.complete(0, "The original text has several translated pieces")
        let first = h.workspace.deliveryPendingBlocks[0]
        let sourceID = h.model.blocks[0].id
        guard h.workspace.prepareForDelivery() else { return fail("overwrite preflight") }
        let generation = h.workspace.deliveryGeneration
        _ = h.model.removeLastCharacter()
        _ = h.workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: [first.id], generation: generation
        )
        guard !h.workspace.outputBlocks.contains(where: { $0.id == first.id }),
              h.workspace.hasIncompleteDeliveryBlocks,
              BufferGeneratedResultCopyRules.freeze(protected: false, source: h.workspace) == nil
        else { return fail("ambiguous edit must not resurrect accepted output") }
        h.request()
        guard h.provider.requests.count == 1 else { return fail("ambiguous source was retranslated") }
        _ = h.model.removeBlock(id: sourceID)
        h.model.append("新的正文")
        h.request()
        guard h.provider.requests.last?.sourceText == "新的正文" else {
            return fail("explicit source replacement must resolve ambiguity")
        }
    }

    do {
        let h = TranslationLifecycleHarness()
        h.model.append("隐私正文")
        h.request()
        h.provider.complete(0, "Private source with several translated output pieces")
        let first = h.workspace.deliveryPendingBlocks[0]
        guard h.workspace.prepareForDelivery() else { return fail("privacy preflight") }
        let generation = h.workspace.deliveryGeneration
        h.model.discardForPrivacy()
        _ = h.workspace.consumeDeliveredAndReportTerminalDrain(
            blockIDs: [first.id], generation: generation
        )
        guard h.workspace.outputBlocks.isEmpty else { return fail("privacy revoked receipt resurrected output") }
        h.model.append("暂停前的正文")
        h.request()
        h.provider.complete(1, "A pending translation with several remaining pieces")
        h.send()
        h.workspace.stop()
        h.model.discardForPrivacy()
        h.workspace.start(loadSupportedLanguages: false)
        guard h.workspace.outputBlocks.isEmpty else { return fail("stop/start resurrected retired plaintext") }
    }
    print("PASS: translation lifecycle exact source retirement, stable prefix, mutable tail, no replay, privacy")
    return true
}
