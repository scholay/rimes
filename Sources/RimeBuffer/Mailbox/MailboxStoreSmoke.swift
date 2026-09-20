import Darwin
import Foundation

/// Local persistence and review-boundary coverage. It never invokes an AI
/// provider or opens an AppKit window; the final check uses an isolated
/// delivery coordinator to prove a restored plugin review is ordinary text.
func runMailboxStoreSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: mailbox store \(message)")
        return false
    }

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-mailbox-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    func capacityLimits(_ maximumMessages: Int) -> MailboxStoreLimits {
        MailboxStoreLimits(
            maximumThreads: 4,
            maximumMessagesPerThread: maximumMessages,
            maximumMessageCharacters: 4_096,
            maximumFileBytes: 1_048_576
        )
    }

    guard MailboxPaneVisualSmoke.validate() else {
        return fail("compact transcript layout and Chinese relative date")
    }

    let bridge = MailboxInteractionBridge.shared
    let associationThreadID = UUID()
    var associationNotifications: [UUID] = []
    let associationObserver = NotificationCenter.default.addObserver(
        forName: .mailboxInboundReviewAssociationDidChange,
        object: bridge,
        queue: nil
    ) { notification in
        if let threadID = notification.userInfo?[
            MailboxInteractionBridge.notificationThreadIDKey
        ] as? UUID {
            associationNotifications.append(threadID)
        }
    }
    bridge.associateInboundReview(
        threadID: associationThreadID,
        itemID: UUID()
    )
    bridge.clearInboundReview(threadID: associationThreadID)
    NotificationCenter.default.removeObserver(associationObserver)
    guard associationNotifications == [associationThreadID, associationThreadID] else {
        return fail("inbound review association UI propagation")
    }

    var now = Date(timeIntervalSince1970: 1_800_000_000)
    do {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        // Schema-v1 sources did not carry a provider profile/model route.
        // Keep them readable without changing Mailbox's document version,
        // while proving a newer route reference survives a durable reload.
        let legacySourceData = Data(
            """
            {"kind":"openAICompatible","displayName":"OpenAI API","identifier":"legacy","model":"legacy-model","replyCapability":"aiContinuation"}
            """.utf8
        )
        let legacySource = try JSONDecoder().decode(
            MailboxSource.self,
            from: legacySourceData
        )
        guard legacySource.providerRoute == nil else {
            return fail("legacy source gained a provider route")
        }
        let expectedRoute = AIProviderRouteReference(
            profileID: UUID(),
            routeID: UUID(),
            profileRevision: 1
        )
        let snapshottedSource = MailboxSource.openAICompatible(
            identifier: "provider-profile",
            model: "routed-model",
            displayName: "Provider",
            providerRoute: expectedRoute
        )
        let routeSnapshotRoot = root.appendingPathComponent(
            "route-snapshot",
            isDirectory: true
        )
        let routeSnapshotStore = try MailboxStore(
            storageRoot: routeSnapshotRoot,
            limits: capacityLimits(2),
            dateProvider: { now }
        )
        let routeSnapshotHandle = try routeSnapshotStore.beginAIConversation(
            source: snapshottedSource,
            prompt: "route snapshot"
        )
        let reopenedRouteSnapshotStore = try MailboxStore(
            storageRoot: routeSnapshotRoot,
            limits: capacityLimits(2),
            dateProvider: { now }
        )
        guard let restoredRouteSnapshotThread = reopenedRouteSnapshotStore.thread(
            id: routeSnapshotHandle.threadID
        ), restoredRouteSnapshotThread.source.providerRoute == expectedRoute else {
            return fail("provider route snapshot persistence")
        }

        // Starting a provider task must never persist a user turn unless the
        // matching terminal assistant message can also fit. The failed
        // admissions below leave the candidate document unchanged.
        let oneSlotStore = try MailboxStore(
            storageRoot: root.appendingPathComponent(
                "one-slot",
                isDirectory: true
            ),
            limits: capacityLimits(1),
            dateProvider: { now }
        )
        let oneSlotBefore = oneSlotStore.snapshot
        do {
            _ = try oneSlotStore.beginAIConversation(
                source: .codexCLI(),
                prompt: "cannot reserve response"
            )
            return fail("one-slot AI conversation admitted")
        } catch MailboxStoreError.capacityExceeded {
            // Expected: a new conversation needs user + assistant slots.
        }
        guard oneSlotStore.snapshot == oneSlotBefore else {
            return fail("one-slot AI conversation was not atomic")
        }

        let threeSlotStore = try MailboxStore(
            storageRoot: root.appendingPathComponent(
                "three-slot",
                isDirectory: true
            ),
            limits: capacityLimits(3),
            dateProvider: { now }
        )
        let threeSlotInitial = try threeSlotStore.beginAIConversation(
            source: .codexCLI(),
            prompt: "first"
        )
        _ = try threeSlotStore.completeGeneration(
            threeSlotInitial,
            response: "second"
        )
        let threeSlotBeforeReply = threeSlotStore.snapshot
        let threeSlotBytesBeforeReply = try Data(
            contentsOf: threeSlotStore.storageURL
        )
        do {
            _ = try threeSlotStore.beginAIReply(
                threadID: threeSlotInitial.threadID,
                body: "only one slot remains"
            )
            return fail("AI reply admitted without terminal slot")
        } catch MailboxStoreError.capacityExceeded {
            // Expected: the user turn cannot consume the sole remaining slot.
        }
        guard threeSlotStore.snapshot == threeSlotBeforeReply,
              try Data(contentsOf: threeSlotStore.storageURL)
                == threeSlotBytesBeforeReply else {
            return fail("capacity-rejected AI reply was not atomic")
        }

        let fourSlotStore = try MailboxStore(
            storageRoot: root.appendingPathComponent(
                "four-slot",
                isDirectory: true
            ),
            limits: capacityLimits(4),
            dateProvider: { now }
        )
        let fourSlotInitial = try fourSlotStore.beginAIConversation(
            source: .codexCLI(),
            prompt: "one"
        )
        _ = try fourSlotStore.completeGeneration(
            fourSlotInitial,
            response: "two"
        )
        let exactBoundaryReply = try fourSlotStore.beginAIReply(
            threadID: fourSlotInitial.threadID,
            body: "three"
        )
        _ = try fourSlotStore.updateGenerationPreview(
            exactBoundaryReply,
            response: "four-partial"
        )
        let reservationBeforeInterleaving = fourSlotStore.snapshot
        let reservationBytesBeforeInterleaving = try Data(
            contentsOf: fourSlotStore.storageURL
        )
        do {
            _ = try fourSlotStore.addLocalNote(
                threadID: fourSlotInitial.threadID,
                body: "must not consume reserved slot"
            )
            return fail("active generation reservation was consumed")
        } catch MailboxStoreError.capacityExceeded {
            // Expected: the terminal response owns the final durable slot.
        }
        guard fourSlotStore.snapshot == reservationBeforeInterleaving,
              try Data(contentsOf: fourSlotStore.storageURL)
                == reservationBytesBeforeInterleaving else {
            return fail("reservation rejection was not atomic")
        }
        _ = try fourSlotStore.completeGeneration(
            exactBoundaryReply,
            response: "four"
        )
        guard let exactBoundaryThread = fourSlotStore.thread(
                id: fourSlotInitial.threadID
              ),
              exactBoundaryThread.messages.map(\.body)
                == ["one", "two", "three", "four"],
              exactBoundaryThread.generation?.phase == .succeeded else {
            return fail("reserved terminal slot did not complete")
        }

        let store = try MailboxStore(
            storageRoot: root,
            dateProvider: { now }
        )
        var events: [MailboxStoreChange] = []
        let observation = store.observe { events.append($0.change) }
        guard events == [.initial] else {
            return fail("initial observation")
        }

        let first = try store.beginAIConversation(
            source: .codexCLI(model: "smoke-model"),
            title: "First",
            prompt: "private prompt"
        )
        guard first.sequence == 1,
              store.snapshot.unreadCount == 0,
              events.last == .contentChanged else {
            return fail("begin generation")
        }

        let durableBeforePreview = try Data(contentsOf: store.storageURL)
        let firstPreviewID = try store.updateGenerationPreview(
            first,
            response: "partial one",
            author: "Codex",
            format: .plain
        )
        let previewRevision = store.snapshot.revision
        let secondPreviewID = try store.updateGenerationPreview(
            first,
            response: "partial two",
            author: "Codex",
            format: .plain
        )
        let previewSnapshot = store.snapshot
        guard firstPreviewID == secondPreviewID,
              previewSnapshot.revision > previewRevision,
              previewSnapshot.generationPreview(threadID: first.threadID)?
                .message.body == "partial two",
              previewSnapshot.generationPreview(threadID: first.threadID)?
                .message.id == firstPreviewID,
              previewSnapshot.unreadCount == 0,
              previewSnapshot.thread(id: first.threadID)?.messages.count == 1,
              store.thread(id: first.threadID)?.messages.count == 1,
              try Data(contentsOf: store.storageURL) == durableBeforePreview,
              events.last == .generationProgressed(threadID: first.threadID) else {
            return fail("transient generation preview")
        }

        now.addTimeInterval(1)
        let completedMessageID = try store.completeGeneration(
            first,
            response: "## Complete\n\n`response`",
            format: .markdown
        )
        let completedSnapshot = store.snapshot
        guard completedSnapshot.unreadCount == 1,
              completedSnapshot.thread(id: first.threadID)?
                .messages.last?.format == .markdown,
              completedSnapshot.thread(id: first.threadID)?
                .messages.last?.body == "## Complete\n\n`response`",
              completedSnapshot.thread(id: first.threadID)?
                .messages.last?.id == completedMessageID,
              completedMessageID == firstPreviewID,
              completedSnapshot.generationPreview(threadID: first.threadID) == nil,
              completedSnapshot.latestUnreadThreadID == first.threadID,
              MailboxToastStateRules.action(
                for: .completedMessage(threadID: first.threadID),
                targetThreadID: nil,
                snapshot: completedSnapshot
              ) == .present(threadID: first.threadID),
              MailboxToastStateRules.action(
                for: .unreadChanged,
                targetThreadID: first.threadID,
                snapshot: completedSnapshot
              ) == .keep,
              events.last == .completedMessage(threadID: first.threadID) else {
            return fail("complete generation event")
        }

        var directoryInfo = stat()
        var fileInfo = stat()
        guard lstat(store.storageDirectoryURL.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & 0o777) == 0o700,
              lstat(store.storageURL.path, &fileInfo) == 0,
              (fileInfo.st_mode & 0o777) == 0o600 else {
            return fail("private permissions")
        }

        _ = store.selectLatestUnreadOrMostRecent()
        let selectedUnreadSnapshot = store.snapshot
        guard selectedUnreadSnapshot.selectedThreadID == first.threadID,
              MailboxPaneStateRules.threadToMarkRead(
                renderedSnapshot: selectedUnreadSnapshot,
                storeSnapshot: selectedUnreadSnapshot,
                windowIsVisible: true,
                windowIsKey: true
              ) == first.threadID,
              MailboxPaneStateRules.threadToMarkRead(
                renderedSnapshot: selectedUnreadSnapshot,
                storeSnapshot: selectedUnreadSnapshot,
                windowIsVisible: true,
                windowIsKey: false
              ) == nil,
              events.last == .selectionChanged else {
            return fail("shared selection")
        }
        try store.markRead(threadID: first.threadID)
        let readSnapshot = store.snapshot
        guard readSnapshot.unreadCount == 0,
              MailboxToastStateRules.action(
                for: .completedMessage(threadID: first.threadID),
                targetThreadID: nil,
                snapshot: readSnapshot
              ) == .present(threadID: first.threadID),
              MailboxToastStateRules.action(
                for: .unreadChanged,
                targetThreadID: first.threadID,
                snapshot: readSnapshot
              ) == .keep,
              !MailboxPaneStateRules.shouldApply(
                currentRevision: readSnapshot.revision,
                incomingRevision: selectedUnreadSnapshot.revision
              ),
              MailboxPaneStateRules.threadToMarkRead(
                renderedSnapshot: selectedUnreadSnapshot,
                storeSnapshot: readSnapshot,
                windowIsVisible: true,
                windowIsKey: true
              ) == nil,
              events.last == .unreadChanged else {
            return fail("read state and stale pane snapshot rejection")
        }

        now.addTimeInterval(1)
        let pending = try store.beginAIReply(
            threadID: first.threadID,
            body: "follow up",
            format: .json
        )
        guard pending.threadID == first.threadID else {
            return fail("reply generation")
        }

        observation.cancel()
        let eventCountAfterCancel = events.count
        try store.markRead(threadID: first.threadID)
        guard events.count == eventCountAfterCancel else {
            return fail("observer cancellation")
        }

        // Simulate a v1 file whose plain user turn predates the `format`
        // field. The rest of the document, including the explicit Markdown
        // response, must remain byte-for-byte content compatible.
        var legacyRoot = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.storageURL)
        ) as? [String: Any]
        var legacyThreads = legacyRoot?["threads"] as? [[String: Any]]
        var legacyMessages = legacyThreads?.first?["messages"] as? [[String: Any]]
        guard legacyRoot != nil,
              legacyThreads?.isEmpty == false,
              legacyMessages?.isEmpty == false else {
            return fail("legacy format fixture")
        }
        legacyMessages?[0].removeValue(forKey: "format")
        legacyThreads?[0]["messages"] = legacyMessages
        legacyRoot?["threads"] = legacyThreads
        let legacyData = try JSONSerialization.data(withJSONObject: legacyRoot!)
        try legacyData.write(to: store.storageURL, options: .atomic)
        guard chmod(store.storageURL.path, 0o600) == 0 else {
            return fail("legacy format fixture permissions")
        }

        now.addTimeInterval(1)
        let reopened = try MailboxStore(
            storageRoot: root,
            dateProvider: { now }
        )
        guard let recovered = reopened.thread(id: first.threadID),
              recovered.sequence == 1,
              recovered.generation?.phase == .failed,
              recovered.generation?.expectedFormat == .json,
              recovered.messages.first?.format == .plain,
              recovered.messages.first(where: { $0.role == .inbound })?
                .format == .markdown,
              recovered.unread else {
            return fail("restart recovery")
        }
        do {
            _ = try reopened.completeGeneration(
                pending,
                response: "late response"
            )
            return fail("late completion accepted")
        } catch MailboxStoreError.staleGeneration {
            // Expected: restart tombstoned the in-flight generation.
        }

        now.addTimeInterval(1)
        let inbound = try reopened.createInboundThread(
            source: .http(source: "HTTP Push"),
            body: "{\"kind\":\"one-way payload\"}",
            format: .json
        )
        guard inbound.sequence == 2,
              inbound.messages.first?.format == .json,
              inbound.review?.state == .pending,
              inbound.review?.messageID == inbound.messages.first?.id,
              inbound.review?.resolvedAt == nil,
              reopened.snapshot.unreadCount == 2 else {
            return fail("one-way thread")
        }
        _ = try reopened.addLocalNote(
            threadID: inbound.id,
            body: "local only"
        )
        do {
            _ = try reopened.beginAIReply(
                threadID: inbound.id,
                body: "must not be sent"
            )
            return fail("one-way continuation accepted")
        } catch MailboxStoreError.continuationUnavailable {
            // Expected: HTTP/MCP-like threads only accept local notes.
        }

        now.addTimeInterval(1)
        _ = try reopened.resolveReview(
            threadID: inbound.id,
            decision: .accept
        )
        guard let resolved = reopened.thread(id: inbound.id),
              resolved.review?.state == .accepted,
              resolved.review?.resolvedAt == now,
              resolved.messages.filter({
                $0.role == .system
                    && $0.body == "已接受并加入 Buffer。"
              }).count == 1 else {
            return fail("atomic review resolution")
        }
        let afterResolution = reopened.snapshot
        do {
            _ = try reopened.resolveReview(
                threadID: inbound.id,
                decision: .reject
            )
            return fail("duplicate review resolution accepted")
        } catch MailboxStoreError.reviewAlreadyResolved {
            // Expected: stale buttons cannot resolve or append status twice.
        }
        guard reopened.snapshot == afterResolution else {
            return fail("duplicate review resolution was not atomic")
        }

        let reviewReopened = try MailboxStore(
            storageRoot: root,
            dateProvider: { now }
        )
        guard let persistedReview = reviewReopened.thread(id: inbound.id)?.review,
              persistedReview.state == .accepted,
              persistedReview.resolvedAt == now else {
            return fail("review restart persistence")
        }

        try reviewReopened.deleteThread(id: first.threadID)
        now.addTimeInterval(1)
        let third = try reviewReopened.createInboundThread(
            source: .mcp(client: "MCP Client"),
            body: "third payload"
        )
        guard third.sequence == 3 else {
            return fail("stable monotonic sequence")
        }

        let beforeOversized = reviewReopened.snapshot
        do {
            _ = try reviewReopened.addLocalNote(
                threadID: third.id,
                body: String(repeating: "x", count: 1_048_577)
            )
            return fail("oversized note accepted")
        } catch MailboxStoreError.invalidMessage {
            // Expected and atomic: the candidate document was never committed.
        }
        guard reviewReopened.snapshot == beforeOversized else {
            return fail("oversized mutation was not atomic")
        }

        // An ordinary test bus must not write fake pushes into the user's (or
        // this smoke's) Mailbox. Persistence is an explicit dependency.
        let isolatedBus = InboundBus()
        _ = isolatedBus.submit(
            origin: .http(source: "isolated"),
            text: "must remain process-local"
        )
        guard reviewReopened.snapshot == beforeOversized else {
            return fail("isolated inbound bus persisted data")
        }

        let durableBus = InboundBus(mailboxStore: reviewReopened)
        let longSource = String(repeating: "s", count: 900)
        let longTitle = String(repeating: "t", count: 900)
        guard let durableID = durableBus.submit(
            origin: .http(source: longSource),
            text: "durable review",
            title: longTitle
        ),
              let durableItem = durableBus.pending.first(
                where: { $0.id == durableID }
              ),
              let durableThreadID = durableItem.mailboxThreadID,
              let durableThread = reviewReopened.thread(id: durableThreadID),
              durableThread.title?.count == 256,
              durableThread.source.displayName.count == 512,
              durableThread.messages.first?.author?.count == 128 else {
            return fail("inbound normalization and persistence injection")
        }

        let pluginThread = try reviewReopened.createInboundThread(
            source: MailboxSource(
                kind: .plugin,
                displayName: "插件",
                identifier: "smoke-plugin",
                replyCapability: .localNotesOnly
            ),
            body: "restored plugin text"
        )

        let restoredBus = InboundBus(
            mailboxStore: reviewReopened,
            restorePendingReviews: true
        )
        guard restoredBus.pending.contains(where: {
            $0.mailboxThreadID == third.id
                && $0.id == third.review?.messageID
        }),
              restoredBus.pending.contains(where: {
                $0.mailboxThreadID == durableThreadID
                    && $0.pluginMetadata == nil
              }),
              restoredBus.pending.contains(where: {
                guard $0.mailboxThreadID == pluginThread.id,
                      $0.pluginMetadata == nil else { return false }
                if case let .plugin(id) = $0.origin {
                    return id == "smoke-plugin"
                }
                return false
              }) else {
            return fail("pending review restart recovery")
        }

        let model = BufferModel.shared
        let oldEnabled = model.enabled
        model.enabled = true
        model.discardForPrivacy()
        defer {
            model.discardForPrivacy()
            model.enabled = oldEnabled
        }
        guard let pluginReviewMessageID = pluginThread.review?.messageID,
              restoredBus.accept(pluginReviewMessageID),
              model.blocks.count == 1,
              let reviewedPluginBlock = model.blocks.first,
              reviewedPluginBlock.origin == .plugin(id: "smoke-plugin"),
              reviewedPluginBlock.pluginMetadata == nil,
              reviewedPluginBlock.locallyReviewedAsPlainText,
              AITextSourcePolicy.accepts(model.blocks),
              reviewReopened.thread(id: pluginThread.id)?.review?.state
                == .accepted else {
            return fail("restored plugin plain-text review")
        }

        var focusEpochs = FocusEpochState()
        let focus = focusEpochs.activate()
        var delivered: [String] = []
        var pluginValidationCalled = false
        let delivery = BufferDeliveryCoordinator(
            model: model,
            dependencies: .init(
                resolveTarget: { expected in
                    guard expected == nil || expected == focus else {
                        return nil
                    }
                    return .init(
                        token: focus,
                        compositionActive: false,
                        resolveComposition: {},
                        deliver: { block in
                            delivered.append(block.text)
                            return true
                        }
                    )
                },
                secureInputEnabled: { false },
                validatePlugin: { _, _, completion in
                    pluginValidationCalled = true
                    completion(.rejected(.stale))
                },
                refreshUI: {}
            ),
            contentSourceResolver: { model }
        )
        let deliveryResult = delivery.sendNext(expectedToken: focus)
        guard deliveryResult.succeeded,
              delivered == ["restored plugin text"],
              !pluginValidationCalled,
              model.blocks.isEmpty else {
            return fail("restored plugin ordinary delivery")
        }

        guard let durableReviewMessageID = durableThread.review?.messageID,
              restoredBus.reject(durableReviewMessageID),
              reviewReopened.thread(id: durableThreadID)?.review?.state
                == .rejected else {
            return fail("inbound bus durable rejection")
        }
    } catch {
        return fail("unexpected error \(error.localizedDescription)")
    }

    print("OK: mailbox-store-smoke")
    return true
}
