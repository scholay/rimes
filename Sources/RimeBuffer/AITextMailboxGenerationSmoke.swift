import Foundation

private final class AITextMailboxSmokeCancellation: AITextCancellable {
    private(set) var wasCancelled = false
    func cancel() { wasCancelled = true }
}

private final class AITextMailboxSmokeProvider: AITextProvider {
    let kind: AITextProviderKind
    var availability: AITextProviderAvailability = .ready
    private(set) var requests: [AITextProviderRequest] = []
    private(set) var cancellations: [AITextMailboxSmokeCancellation] = []
    private var events: [(AITextProviderEvent) -> Void] = []
    private var completions: [
        (Result<[AITextProviderBlock], AITextProviderError>) -> Void
    ] = []

    init(kind: AITextProviderKind = .codexCLI) {
        self.kind = kind
    }

    @discardableResult
    func generate(
        _ request: AITextProviderRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (
            Result<[AITextProviderBlock], AITextProviderError>
        ) -> Void
    ) -> any AITextCancellable {
        requests.append(request)
        events.append(onEvent)
        completions.append(completion)
        let cancellation = AITextMailboxSmokeCancellation()
        cancellations.append(cancellation)
        return cancellation
    }

    func emit(_ event: AITextProviderEvent, request index: Int) {
        events[index](event)
    }

    func finish(
        _ result: Result<[AITextProviderBlock], AITextProviderError>,
        request index: Int
    ) {
        completions[index](result)
    }
}

private final class AITextMailboxSmokeStore: AITextMailboxPersisting {
    private(set) var threads: [MailboxThread] = []
    private(set) var previewResponses: [UUID: String] = [:]
    private(set) var previewFormats: [UUID: AITextContentFormat] = [:]
    private(set) var completedResponses: [UUID: String] = [:]
    private(set) var completedFormats: [UUID: AITextContentFormat] = [:]
    private(set) var completionCounts: [UUID: Int] = [:]
    private(set) var failedMessages: [UUID: String] = [:]
    private(set) var localNoteCount = 0
    private var nextSequence = 1

    var snapshot: MailboxStoreSnapshot {
        MailboxStoreSnapshot(
            revision: UInt64(threads.count + completedResponses.count
                + failedMessages.count + localNoteCount),
            threads: threads,
            selectedThreadID: nil,
            persistence: .available
        )
    }

    func thread(id: UUID) -> MailboxThread? {
        threads.first(where: { $0.id == id })
    }

    func beginAIConversation(
        source: MailboxSource,
        title: String?,
        prompt: String,
        author: String,
        format: AITextContentFormat
    ) throws -> MailboxGenerationHandle {
        let handle = nextHandle()
        let now = Date()
        threads.append(MailboxThread(
            id: handle.threadID,
            sequence: handle.sequence,
            title: title,
            source: source,
            messages: [MailboxMessage(role: .user,
                                      author: author,
                                      body: prompt,
                                      createdAt: now)],
            generation: .generating(
                id: handle.generationID,
                format: format,
                at: now
            ),
            unread: false,
            createdAt: now,
            updatedAt: now
        ))
        return handle
    }

    func beginAIReply(
        threadID: UUID,
        body: String,
        author: String,
        format: AITextContentFormat
    ) throws -> MailboxGenerationHandle {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw MailboxStoreError.missingThread
        }
        let generation = MailboxGeneration.generating(format: format)
        threads[index].messages.append(MailboxMessage(role: .user,
                                                      author: author,
                                                      body: body))
        threads[index].generation = generation
        threads[index].unread = false
        return MailboxGenerationHandle(
            threadID: threadID,
            generationID: generation.id,
            sequence: threads[index].sequence
        )
    }

    func updateGenerationPreview(
        _ handle: MailboxGenerationHandle,
        response: String,
        author: String?,
        format: AITextContentFormat
    ) throws -> UUID {
        guard currentIndex(handle) != nil else {
            throw MailboxStoreError.staleGeneration
        }
        previewResponses[handle.generationID] = response
        previewFormats[handle.generationID] = format
        return UUID()
    }

    func completeGeneration(
        _ handle: MailboxGenerationHandle,
        response: String,
        author: String?,
        format: AITextContentFormat
    ) throws -> UUID {
        guard let index = currentIndex(handle) else {
            throw MailboxStoreError.staleGeneration
        }
        let message = MailboxMessage(role: .inbound,
                                     format: format,
                                     author: author,
                                     body: response)
        threads[index].messages.append(message)
        threads[index].generation = threads[index].generation?.succeeding(at: Date())
        threads[index].unread = true
        previewResponses.removeValue(forKey: handle.generationID)
        previewFormats.removeValue(forKey: handle.generationID)
        completedResponses[handle.generationID] = response
        completedFormats[handle.generationID] = format
        completionCounts[handle.generationID, default: 0] += 1
        return message.id
    }

    func failGeneration(
        _ handle: MailboxGenerationHandle,
        message: String
    ) throws {
        guard let index = currentIndex(handle) else {
            throw MailboxStoreError.staleGeneration
        }
        threads[index].generation = threads[index].generation?.failing(
            message: message,
            at: Date()
        )
        threads[index].unread = true
        previewResponses.removeValue(forKey: handle.generationID)
        previewFormats.removeValue(forKey: handle.generationID)
        failedMessages[handle.generationID] = message
    }

    func addLocalNote(
        threadID: UUID,
        body: String,
        author: String
    ) throws -> UUID {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else {
            throw MailboxStoreError.missingThread
        }
        let message = MailboxMessage(role: .user,
                                     kind: .localNote,
                                     author: author,
                                     body: body)
        threads[index].messages.append(message)
        localNoteCount += 1
        return message.id
    }

    func addLocalThread() -> UUID {
        let id = UUID()
        let now = Date()
        threads.append(MailboxThread(
            id: id,
            sequence: nextSequence,
            title: "HTTP",
            source: .http(source: "HTTP Push"),
            messages: [MailboxMessage(role: .inbound,
                                      author: "HTTP Push",
                                      body: "draft")],
            generation: nil,
            unread: true,
            createdAt: now,
            updatedAt: now
        ))
        nextSequence += 1
        return id
    }

    func addAIThread(
        source: MailboxSource,
        format: AITextContentFormat,
        userBody: String = "first question",
        assistantBody: String = "first answer"
    ) -> UUID {
        let id = UUID()
        let now = Date()
        threads.append(MailboxThread(
            id: id,
            sequence: nextSequence,
            title: "AI conversation",
            source: source,
            messages: [
                MailboxMessage(
                    role: .user,
                    format: .plain,
                    author: "你",
                    body: userBody,
                    createdAt: now
                ),
                MailboxMessage(
                    role: .inbound,
                    format: format,
                    author: source.displayName,
                    body: assistantBody,
                    createdAt: now
                ),
            ],
            generation: nil,
            unread: false,
            createdAt: now,
            updatedAt: now
        ))
        nextSequence += 1
        return id
    }

    private func nextHandle() -> MailboxGenerationHandle {
        let handle = MailboxGenerationHandle(
            threadID: UUID(),
            generationID: UUID(),
            sequence: nextSequence
        )
        nextSequence += 1
        return handle
    }

    private func currentIndex(_ handle: MailboxGenerationHandle) -> Int? {
        threads.firstIndex {
            $0.id == handle.threadID
                && $0.generation?.id == handle.generationID
                && $0.generation?.phase == .generating
        }
    }
}

private enum AITextMailboxGenerationSmoke {
    static func run() -> Bool {
        Thread.isMainThread
            && promptPlanning()
            && preferencesRoundTrip()
            && inlineOutputMenuOnly()
            && inlineSelectionSnapshotAndRouting()
            && directConversationStart()
            && dynamicProviderRouteFreezeAndRecovery()
            && mailboxJSONValidation()
            && mailboxCapacityAdmission()
            && backgroundTerminalLifecycle()
    }

    private static func promptPlanning() -> Bool {
        do {
            let initial = try AITextRequestPlanner.initialPrompt(
                sourceText: "payload-原文",
                mode: .polish,
                output: .markdown
            )
            guard initial.contains(
                "Rewrite the source clearly while preserving its meaning"
            ), initial.contains(
                "Put the complete valid Markdown document"
            ), initial.contains("USER_PAYLOAD_JSON:"),
              initial.contains("\"source\":\"payload-原文\""),
              !initial.contains("(instruction)"),
              !initial.contains("(formatInstruction)"),
              !initial.contains("(encoded)") else {
                return false
            }

            let continuation = try AITextRequestPlanner.continuationPrompt(
                turns: [
                    AITextConversationPromptTurn(
                        role: .assistant,
                        content: "prior-answer"
                    ),
                    AITextConversationPromptTurn(
                        role: .user,
                        content: "follow-up"
                    ),
                ]
            )
            return continuation.contains("CONVERSATION_JSON:")
                && continuation.contains("\"content\":\"prior-answer\"")
                && continuation.contains("\"content\":\"follow-up\"")
                && !continuation.contains("(encoded)")
        } catch {
            return false
        }
    }

    private static func preferencesRoundTrip() -> Bool {
        let suite = "RimeBuffer.AITextMailboxPreferencesSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AITextGenerationPreferenceStore(defaults: defaults)
        guard store.mode == .ask,
              store.output == .plain,
              store.destination == .inline,
              store.format == .plain,
              store.modelID(for: .openAICompatible) == nil else {
            return false
        }
        store.mode = .summarize
        store.output = .mailbox
        store.set(destination: .mailbox, format: .markdown)
        do {
            try store.setModelID("  model-frozen  ", for: .openAICompatible)
        } catch {
            return false
        }
        let selection = store.selection(connectorKind: .openAICompatible)
        guard selection == AITextGenerationSelection(
            connectorKind: .openAICompatible,
            modelID: "model-frozen",
            mode: .summarize,
            destination: .inline,
            format: .markdown
        ) else {
            return false
        }

        // Retired preference migration is a persisted, idempotent matrix. Only
        // a valid v2 format paired with destination=mailbox is preserved;
        // missing/corrupt v2 data and v1-only Mailbox values become Plain.
        let cases: [(String?, String?, String?, AITextContentFormat)] = [
            (nil, nil, AITextGenerationOutput.mailbox.rawValue, .plain),
            (nil, AITextContentFormat.json.rawValue,
             AITextGenerationOutput.mailbox.rawValue, .plain),
            (AITextGenerationDestination.mailbox.rawValue, nil,
             AITextGenerationOutput.markdown.rawValue, .plain),
            (AITextGenerationDestination.mailbox.rawValue, "corrupt-format",
             AITextGenerationOutput.json.rawValue, .plain),
            (AITextGenerationDestination.mailbox.rawValue,
             AITextContentFormat.plain.rawValue,
             AITextGenerationOutput.mailbox.rawValue, .plain),
            (AITextGenerationDestination.mailbox.rawValue,
             AITextContentFormat.markdown.rawValue,
             AITextGenerationOutput.plain.rawValue, .markdown),
            (AITextGenerationDestination.mailbox.rawValue,
             AITextContentFormat.json.rawValue,
             "corrupt-output", .json),
            ("corrupt-destination", AITextContentFormat.markdown.rawValue,
             AITextGenerationOutput.mailbox.rawValue, .plain),
            (AITextGenerationDestination.inline.rawValue,
             AITextContentFormat.json.rawValue,
             AITextGenerationOutput.mailbox.rawValue, .plain),
        ]
        return cases.allSatisfy {
            migratedPreferenceCase(
                destinationRaw: $0.0,
                formatRaw: $0.1,
                outputRaw: $0.2,
                expectedFormat: $0.3
            )
        }
    }

    private static func migratedPreferenceCase(
        destinationRaw: String?,
        formatRaw: String?,
        outputRaw: String?,
        expectedFormat: AITextContentFormat
    ) -> Bool {
        let suite = "RimeBuffer.AITextMailboxMigrationSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let destinationKey = "plugins.ai-text.generation.destination.v2"
        let formatKey = "plugins.ai-text.generation.format.v2"
        let outputKey = "plugins.ai-text.generation.output.v1"
        if let destinationRaw { defaults.set(destinationRaw, forKey: destinationKey) }
        if let formatRaw { defaults.set(formatRaw, forKey: formatKey) }
        if let outputRaw { defaults.set(outputRaw, forKey: outputKey) }

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .aiTextGenerationPreferencesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = AITextGenerationPreferenceStore(defaults: defaults)
        let firstDomain = defaults.persistentDomain(forName: suite)
        let second = AITextGenerationPreferenceStore(defaults: defaults)
        let secondDomain = defaults.persistentDomain(forName: suite)
        return first.destination == .inline
            && first.format == expectedFormat
            && first.output.rawValue == expectedFormat.rawValue
            && second.destination == .inline
            && second.format == expectedFormat
            && second.output.rawValue == expectedFormat.rawValue
            && defaults.string(forKey: destinationKey)
                == AITextGenerationDestination.inline.rawValue
            && defaults.string(forKey: formatKey) == expectedFormat.rawValue
            && defaults.string(forKey: outputKey) == expectedFormat.rawValue
            && NSDictionary(dictionary: firstDomain ?? [:]).isEqual(
                to: secondDomain ?? [:]
            )
            && notificationCount == 0
    }

    private static func inlineOutputMenuOnly() -> Bool {
        runAITextOutputPopupMenuProbe()
    }

    private static func inlineSelectionSnapshotAndRouting() -> Bool {
        let source = BufferModel()
        source.stageExternal("inline-source", origin: .rime)
        let provider = AITextMailboxSmokeProvider(kind: .codexCLI)
        var selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: "inline-model",
            mode: .summarize,
            output: .json
        )
        let workspace = AITextPluginWorkspace(
            provider: provider,
            sourceModel: source,
            generationSelectionResolver: { _ in selection },
            isSelected: { true }
        )
        workspace.start()
        defer { workspace.stop() }

        guard workspace.generate(), provider.requests.count == 1,
              provider.requests[0].modelID == "inline-model",
              provider.requests[0].preparedPrompt?.contains(
                "Summarize the source faithfully and concisely."
              ) == true,
              provider.requests[0].preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true,
              provider.requests[0].preparedPrompt?.contains(
                "\"source\":\"inline-source\""
              ) == true else {
            return false
        }
        let frozenPrompt = provider.requests[0].preparedPrompt
        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .translate,
            output: .plain
        )
        guard provider.requests[0].modelID == "inline-model",
              provider.requests[0].preparedPrompt == frozenPrompt else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "{\"answer\":",
            title: nil
        )), request: 0)
        guard workspace.outputBlocks.isEmpty else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"answer\":", title: nil),
            AITextProviderBlock(index: 1, text: "\"inline-result\"}", title: nil),
        ]), request: 0)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 1,
              workspace.outputBlocks[0].text
                == "{\"answer\":\n\n\"inline-result\"}" else {
            return false
        }
        workspace.reset()

        let retiredDestinationSelection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            destination: .mailbox,
            format: .markdown
        )
        guard retiredDestinationSelection.destination == .inline,
              retiredDestinationSelection.format == .markdown else {
            return false
        }

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .json
        )
        guard workspace.generate(), provider.requests.count == 2 else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "not-json", title: nil),
        ]), request: 1)
        guard workspace.phase == .failed(
            AITextProviderError.invalidResult.userFacingMessage
        ), workspace.outputBlocks.isEmpty else {
            return false
        }
        workspace.reset()

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .markdown
        )
        guard workspace.generate(), provider.requests.count == 3 else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "# Title",
            title: nil
        )), request: 2)
        guard workspace.outputBlocks.isEmpty else { return false }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "# Title", title: nil),
            AITextProviderBlock(index: 1, text: "Body", title: nil),
        ]), request: 2)
        guard workspace.phase == .ready,
              workspace.outputBlocks.count == 1,
              workspace.outputBlocks[0].text == "# Title\n\nBody" else {
            return false
        }
        workspace.reset()

        selection = AITextGenerationSelection(
            connectorKind: .codexCLI,
            modelID: nil,
            mode: .ask,
            output: .mailbox
        )
        guard selection.destination == .inline,
              selection.format == .plain else {
            return false
        }
        let result = AITextGenerationCommandRouter.request(
            controls: workspace
        )
        guard result == .inlineStarted,
              provider.requests.count == 4,
              provider.requests[3].preparedPrompt?.contains(
                "The block text must be directly readable plain content."
              ) == true else {
            return false
        }
        return true
    }

    private static func directConversationStart() -> Bool {
        let source = BufferModel()
        source.stageExternal("buffer-must-remain", origin: .rime)
        let provider = AITextMailboxSmokeProvider(kind: .openAICompatible)
        let store = AITextMailboxSmokeStore()
        var resolvedKinds: [AITextProviderKind] = []
        let coordinator = AITextMailboxGenerationCoordinator(
            dependencies: .init(
                store: store,
                providerResolver: { kind in
                    resolvedKinds.append(kind)
                    return kind == provider.kind ? provider : nil
                }
            )
        )

        var startResult: Result<MailboxGenerationHandle, Error>?
        coordinator.startMailboxConversation(
            selection: MailboxNewConversationSelection(
                connectorKind: .openAICompatible,
                modelID: "  direct-model  "
            ),
            body: "  first direct question  "
        ) {
            startResult = $0
        }
        guard let startResult else { return false }
        let handle: MailboxGenerationHandle
        switch startResult {
        case let .success(value):
            handle = value
        case .failure:
            return false
        }

        guard let expectedPrompt = try? AITextRequestPlanner.initialPrompt(
            sourceText: "first direct question",
            mode: .ask,
            format: .plain
        ),
              resolvedKinds == [.openAICompatible],
              coordinator.activeJobCount == 1,
              provider.requests.count == 1,
              let request = provider.requests.first,
              request == AITextProviderRequest(
                requestID: request.requestID,
                sourceText: "first direct question",
                preparedPrompt: expectedPrompt,
                modelID: "direct-model"
              ),
              let thread = store.thread(id: handle.threadID),
              thread.source == .openAICompatible(model: "direct-model"),
              thread.messages.count == 1,
              let firstMessage = thread.messages.first,
              firstMessage.role == .user,
              firstMessage.kind == .content,
              firstMessage.format == .plain,
              firstMessage.author == "你",
              firstMessage.body == "first direct question",
              thread.generation?.id == handle.generationID,
              thread.generation?.expectedFormat == .plain,
              source.stagedText == "buffer-must-remain" else {
            return false
        }

        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "direct answer", title: nil),
        ]), request: 0)
        guard coordinator.activeJobCount == 0,
              store.completedResponses[handle.generationID] == "direct answer",
              store.completedFormats[handle.generationID] == .plain,
              source.stagedText == "buffer-must-remain" else {
            return false
        }

        let admittedThreadCount = store.threads.count
        let admittedRequestCount = provider.requests.count
        let selection = MailboxNewConversationSelection(
            connectorKind: .openAICompatible,
            modelID: "direct-model"
        )
        var emptyError: AITextMailboxGenerationError?
        coordinator.startMailboxConversation(
            selection: selection,
            body: " \n\t "
        ) { result in
            if case let .failure(error) = result {
                emptyError = error as? AITextMailboxGenerationError
            }
        }
        var oversizedError: AITextMailboxGenerationError?
        coordinator.startMailboxConversation(
            selection: selection,
            body: String(
                repeating: "a",
                count: AITextRuntimeLimits.maximumSourceBytes + 1
            )
        ) { result in
            if case let .failure(error) = result {
                oversizedError = error as? AITextMailboxGenerationError
            }
        }
        return store.threads.count == admittedThreadCount
            && provider.requests.count == admittedRequestCount
            && resolvedKinds == [.openAICompatible]
            && emptyError == .invalidMessage
            && oversizedError == .invalidMessage
            && source.stagedText == "buffer-must-remain"
    }

    /// A dynamic API conversation must retain its exact profile/model revision
    /// for every turn. If that revision becomes stale, or a new-style source
    /// somehow loses its route reference, Mailbox must not fall back to the
    /// current OpenAI-compatible selection.
    private static func dynamicProviderRouteFreezeAndRecovery() -> Bool {
        let profileID = UUID()
        let routeID = UUID()
        let reference = AIProviderRouteReference(
            profileID: profileID,
            routeID: routeID,
            profileRevision: 1
        )
        let route = AIModelRoute(
            id: routeID,
            displayName: "Frozen chat",
            modelID: "frozen-model",
            adapter: .openAIChatCompletions,
            capabilities: [.textGeneration, .streamingText]
        )
        let profile = AIProviderProfile(
            id: profileID,
            displayName: "Frozen Provider",
            baseURL: "https://provider.example/v1",
            routes: [route],
            requiresAPIKey: true,
            revision: 1
        )
        let resolved = AIProviderResolvedRoute(
            reference: reference,
            profile: profile,
            route: route,
            apiKey: nil
        )
        let legacyReference = AIProviderRouteReference(
            profileID: AIProviderProfile.legacyOpenAICompatibleID,
            routeID: AIProviderProfile.legacyOpenAICompatibleRouteID,
            profileRevision: 1
        )
        let legacyRoute = AIModelRoute(
            id: legacyReference.routeID,
            displayName: "Migrated legacy chat",
            modelID: "legacy-stable-model",
            adapter: .openAIChatCompletions,
            capabilities: [.textGeneration, .streamingText]
        )
        let legacyProfile = AIProviderProfile(
            id: legacyReference.profileID,
            displayName: "CometAPI",
            baseURL: "https://legacy.example/v1",
            routes: [legacyRoute],
            requiresAPIKey: true,
            revision: 1
        )
        let resolvedLegacy = AIProviderResolvedRoute(
            reference: legacyReference,
            profile: legacyProfile,
            route: legacyRoute,
            apiKey: nil
        )
        let provider = AITextMailboxSmokeProvider(kind: .openAICompatible)
        let store = AITextMailboxSmokeStore()
        var routeIsAvailable = true
        let coordinator = AITextMailboxGenerationCoordinator(
            dependencies: .init(
                store: store,
                providerResolver: { kind in
                    kind == .openAICompatible ? provider : nil
                },
                providerRouteResolver: { requested in
                    if requested == reference, routeIsAvailable {
                        return resolved
                    }
                    if requested == legacyReference {
                        return resolvedLegacy
                    }
                    throw AIProviderProfileStoreError.staleRoute
                },
                legacyProviderRouteReferenceResolver: { legacyReference }
            )
        )

        let handle: MailboxGenerationHandle
        do {
            handle = try coordinator.startConversation(
                connectorKind: .openAICompatible,
                modelID: "ignored-model",
                providerRoute: reference,
                prompt: "first routed question"
            )
        } catch {
            return false
        }
        guard provider.requests.count == 1,
              provider.requests[0].modelID == "frozen-model",
              provider.requests[0].providerRoute == reference,
              let thread = store.thread(id: handle.threadID),
              thread.source.providerRoute == reference,
              thread.source.identifier == profileID.uuidString else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "first routed answer", title: nil),
        ]), request: 0)

        routeIsAvailable = false
        let requestCountBeforeStaleReply = provider.requests.count
        let messageCountBeforeStaleReply = thread.messages.count + 1
        do {
            _ = try coordinator.submitComposer(
                threadID: handle.threadID,
                body: "must not reroute"
            )
            return false
        } catch let error as AITextMailboxGenerationError {
            guard case .connectorUnavailable = error else { return false }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeStaleReply,
              store.thread(id: handle.threadID)?.messages.count
                == messageCountBeforeStaleReply else {
            return false
        }

        let missingReferenceThread = store.addAIThread(
            source: .openAICompatible(
                identifier: profileID.uuidString,
                model: "frozen-model",
                displayName: "Frozen Provider"
            ),
            format: .plain
        )
        do {
            _ = try coordinator.submitComposer(
                threadID: missingReferenceThread,
                body: "missing route"
            )
            return false
        } catch let error as AITextMailboxGenerationError {
            guard case .connectorUnavailable = error else { return false }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeStaleReply else {
            return false
        }

        // Pre-catalog sources remain compatible only through their stable
        // migrated legacy route—not through the currently selected provider.
        let legacyThread = store.addAIThread(
            source: .openAICompatible(model: "legacy-model"),
            format: .plain
        )
        do {
            _ = try coordinator.submitComposer(
                threadID: legacyThread,
                body: "legacy continuation"
            )
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeStaleReply + 1,
              provider.requests.last?.modelID == "legacy-stable-model",
              provider.requests.last?.providerRoute == legacyReference else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "legacy answer", title: nil),
        ]), request: requestCountBeforeStaleReply)
        return coordinator.activeJobCount == 0
    }

    private static func mailboxJSONValidation() -> Bool {
        let source = BufferModel()
        source.stageExternal("buffer-must-remain", origin: .rime)
        let provider = AITextMailboxSmokeProvider()
        let store = AITextMailboxSmokeStore()
        let coordinator = AITextMailboxGenerationCoordinator(
            dependencies: .init(
                store: store,
                providerResolver: { _ in provider }
            )
        )
        let firstThreadID = store.addAIThread(
            source: .codexCLI(),
            format: .json,
            assistantBody: "{\"first\":true}"
        )
        guard case let .generationStarted(first) = try? coordinator.submitComposer(
            threadID: firstThreadID,
            body: "json-source"
        ),
              provider.requests.first?.preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: #"{"unfinished":"#,
            title: nil
        )), request: 0)
        guard store.previewResponses[first.generationID]
                == #"{"unfinished":"#,
              store.previewFormats[first.generationID] == .plain else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "not-json", title: nil),
        ]), request: 0)
        guard store.completedResponses[first.generationID] == nil,
              store.failedMessages[first.generationID] != nil,
              source.stagedText == "buffer-must-remain" else {
            return false
        }

        guard case let .generationStarted(retry) = try? coordinator.submitComposer(
            threadID: first.threadID,
            body: "retry json"
        ), provider.requests.count == 2,
              provider.requests[1].preparedPrompt?.contains(
                "Put one complete valid JSON value"
              ) == true else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"retried\":true}", title: nil),
        ]), request: 1)
        guard store.completedFormats[retry.generationID] == .json else {
            return false
        }

        let secondThreadID = store.addAIThread(
            source: .codexCLI(),
            format: .json,
            assistantBody: "{\"seed\":true}"
        )
        guard case let .generationStarted(second) = try? coordinator.submitComposer(
            threadID: secondThreadID,
            body: "second json"
        ) else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "{\"ok\":true}", title: nil),
        ]), request: 2)
        guard store.completedResponses[second.generationID] == "{\"ok\":true}",
              store.completedFormats[second.generationID] == .json else {
            return false
        }

        let markdownThreadID = store.addAIThread(
            source: .codexCLI(),
            format: .markdown,
            assistantBody: "# Seed"
        )
        guard case let .generationStarted(third) = try? coordinator.submitComposer(
            threadID: markdownThreadID,
            body: "markdown-source"
        ) else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "# Streaming",
            title: nil
        )), request: 3)
        guard store.previewResponses[third.generationID] == "# Streaming",
              store.previewFormats[third.generationID] == .plain else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "# Streaming", title: nil),
            AITextProviderBlock(index: 1, text: "Complete", title: nil),
        ]), request: 3)
        return store.completedResponses[third.generationID]
                == "# Streaming\n\nComplete"
            && store.completedFormats[third.generationID] == .markdown
            && store.previewResponses[third.generationID] == nil
            && store.completedFormats[second.generationID] == .json
            && source.stagedText == "buffer-must-remain"
    }

    /// Integration boundary: coordinator admission must fail before launching
    /// the provider when only the user slot, but not its assistant slot, fits.
    private static func mailboxCapacityAdmission() -> Bool {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "rimebuffer-ai-mailbox-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }

        do {
            let store = try MailboxStore(
                storageRoot: root,
                limits: MailboxStoreLimits(
                    maximumThreads: 2,
                    maximumMessagesPerThread: 3,
                    maximumMessageCharacters: 4_096,
                    maximumFileBytes: 1_048_576
                )
            )
            let initial = try store.beginAIConversation(
                source: .codexCLI(model: "capacity-model"),
                prompt: "first"
            )
            _ = try store.completeGeneration(initial, response: "second")

            let provider = AITextMailboxSmokeProvider()
            let coordinator = AITextMailboxGenerationCoordinator(
                dependencies: .init(
                    store: store,
                    providerResolver: { _ in provider }
                )
            )
            let before = store.snapshot
            do {
                _ = try coordinator.submitComposer(
                    threadID: initial.threadID,
                    body: "must be rejected before provider launch"
                )
                return false
            } catch let error as AITextMailboxGenerationError {
                guard error == .persistence(
                    MailboxStoreError.capacityExceeded.localizedDescription
                ) else {
                    return false
                }
            }
            return provider.requests.isEmpty
                && coordinator.activeJobCount == 0
                && store.snapshot == before
                && store.thread(id: initial.threadID)?.messages.map(\.body)
                    == ["first", "second"]
        } catch {
            return false
        }
    }

    private static func backgroundTerminalLifecycle() -> Bool {
        let source = BufferModel()
        source.stageExternal("source", origin: .rime)
        let provider = AITextMailboxSmokeProvider()
        let store = AITextMailboxSmokeStore()
        var notices: [AITextMailboxGenerationNotice] = []
        let coordinator = AITextMailboxGenerationCoordinator(
            dependencies: .init(
                store: store,
                providerResolver: { kind in
                    kind == provider.kind ? provider : nil
                },
                notice: { notices.append($0) }
            )
        )
        let first: MailboxGenerationHandle
        do {
            first = try coordinator.startConversation(
                connectorKind: .codexCLI,
                modelID: "model-frozen",
                prompt: "source"
            )
        } catch {
            return false
        }
        guard let expectedPrompt = try? AITextRequestPlanner.initialPrompt(
            sourceText: "source",
            mode: .ask,
            format: .plain
        ), coordinator.activeJobCount == 1,
              provider.requests.count == 1,
              provider.requests[0].modelID == "model-frozen",
              provider.requests[0].sourceText == "source",
              provider.requests[0].preparedPrompt == expectedPrompt else {
            return false
        }

        source.pauseCapturePreservingContent()
        guard provider.cancellations.first?.wasCancelled == false else {
            return false
        }
        provider.emit(.activity(AITextProviderActivity(
            kind: .reasoning,
            message: "hidden lifecycle only"
        )), request: 0)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 1,
            text: "tail",
            title: nil
        )), request: 0)
        guard store.previewResponses[first.generationID] == "tail",
              store.previewFormats[first.generationID] == .plain,
              store.completedResponses.isEmpty,
              store.threads.first(where: { $0.id == first.threadID })?.unread == false,
              notices.isEmpty,
              source.stagedText == "source" else {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "head-one",
            title: nil
        )), request: 0)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "head-two",
            title: nil
        )), request: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard store.previewResponses[first.generationID]
                == "head-two\n\ntail",
              store.completedResponses.isEmpty,
              notices.isEmpty else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "complete-one", title: nil),
            AITextProviderBlock(index: 1, text: "complete-two", title: nil),
        ]), request: 0)
        guard coordinator.activeJobCount == 0,
              store.completedResponses[first.generationID]
                == "complete-one\n\ncomplete-two",
              store.completedFormats[first.generationID] == .plain,
              store.completionCounts[first.generationID] == 1,
              store.previewResponses[first.generationID] == nil,
              source.stagedText == "source",
              notices == [.completed(
                threadID: first.threadID,
                sequence: first.sequence,
                unreadCount: 1
              )] else {
            return false
        }

        let failed: MailboxGenerationHandle
        do {
            failed = try coordinator.startConversation(
                connectorKind: .codexCLI,
                modelID: "model-frozen",
                prompt: "retry source"
            )
        } catch {
            return false
        }
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "discard-on-failure",
            title: nil
        )), request: 1)
        guard store.previewResponses[failed.generationID]
                == "discard-on-failure" else {
            return false
        }
        provider.finish(.failure(.failed), request: 1)
        provider.finish(.failure(.failed), request: 1)
        provider.emit(.blockSnapshot(AITextProviderBlock(
            index: 0,
            text: "late partial",
            title: nil
        )), request: 1)
        guard store.failedMessages[failed.generationID]
                == AITextProviderError.failed.userFacingMessage,
              source.stagedText == "source",
              store.previewResponses[failed.generationID] == nil,
              store.completedResponses[failed.generationID] == nil,
              notices.filter({
                  if case .failed(_, _) = $0 { return true }
                  return false
              }).count == 1 else {
            return false
        }

        let requestCountBeforeNote = provider.requests.count
        let localThreadID = store.addLocalThread()
        do {
            guard case .localNoteAdded(_) = try coordinator.submitComposer(
                threadID: localThreadID,
                body: "private note"
            ) else {
                return false
            }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeNote,
              store.localNoteCount == 1 else {
            return false
        }

        do {
            guard case .generationStarted(_) = try coordinator.submitComposer(
                threadID: first.threadID,
                body: "continue"
            ) else {
                return false
            }
        } catch {
            return false
        }
        guard provider.requests.count == requestCountBeforeNote + 1,
              provider.requests.last?.modelID == "model-frozen",
              provider.requests.last?.preparedPrompt?.contains(
                "CONVERSATION_JSON"
              ) == true else {
            return false
        }
        provider.finish(.success([
            AITextProviderBlock(index: 0, text: "continued", title: nil),
        ]), request: 2)
        return provider.cancellations.allSatisfy { !$0.wasCancelled }
    }
}

/// Pure/fake smoke. It launches no CLI and performs no network request.
func runAITextMailboxGenerationSmokeTest() -> Bool {
    AITextMailboxGenerationSmoke.run()
}
