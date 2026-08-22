import Foundation

/// External foreground identity used only by the optional privacy purge. Our
/// own settings/editor windows are deliberately represented as `nil`, so an
/// A -> ETInput -> A round trip is not mistaken for an application switch.
struct ForegroundApplicationIdentity: Equatable {
    let bundleID: String?
    let processIdentifier: pid_t
}

/// One uninterrupted direct-text capture lease. Runtime callers bind it to
/// the exact IMK focus token; the testing case keeps BufferModel smoke tests
/// deterministic without manufacturing focus-coordinator state.
enum DirectInputRunOwner: Hashable {
    case focus(FocusToken)
    case testing(Int)
}

/// Where the exact focused IMK client's next editing event is routed.  This
/// is deliberately independent from both workbench visibility and staged
/// content: a visible/non-empty Buffer may still leave typing in the host.
enum BufferInputRoute: Equatable {
    case directToHost
    case captureToBuffer
}

enum BufferPrivacyTransitionRules {
    static func externalIdentity(bundleID: String?,
                                 processIdentifier: pid_t,
                                 ownBundleID: String,
                                 ownProcessIdentifier: pid_t) -> ForegroundApplicationIdentity? {
        if bundleID == ownBundleID || processIdentifier == ownProcessIdentifier {
            return nil
        }
        guard let bundleID else {
            guard processIdentifier > 0 else { return nil }
            return ForegroundApplicationIdentity(bundleID: nil,
                                                 processIdentifier: processIdentifier)
        }
        return ForegroundApplicationIdentity(bundleID: bundleID,
                                             processIdentifier: processIdentifier)
    }

    /// Bundle identity is authoritative when both observations have it. PID is
    /// only a bridge while one side is temporarily missing a bundle, so a
    /// recycled PID can never equate two known, different applications.
    static func sameApplication(_ lhs: ForegroundApplicationIdentity,
                                _ rhs: ForegroundApplicationIdentity) -> Bool {
        if let leftBundleID = lhs.bundleID,
           let rightBundleID = rhs.bundleID {
            return leftBundleID == rightBundleID
        }
        return lhs.processIdentifier > 0
            && lhs.processIdentifier == rhs.processIdentifier
    }

    static func shouldDiscard(previousExternal: ForegroundApplicationIdentity?,
                              activatedExternal: ForegroundApplicationIdentity?,
                              resetOnSwitch: Bool,
                              holdsExternalContent: Bool) -> Bool {
        guard resetOnSwitch,
              !holdsExternalContent,
              let previousExternal,
              let activatedExternal else { return false }
        return !sameApplication(previousExternal, activatedExternal)
    }

    static func updatedPrevious(_ previousExternal: ForegroundApplicationIdentity?,
                                activatedExternal: ForegroundApplicationIdentity?)
        -> ForegroundApplicationIdentity? {
        guard let activatedExternal else { return previousExternal }
        guard let previousExternal,
              sameApplication(previousExternal, activatedExternal) else {
            return activatedExternal
        }
        // Do not let a transient PID-only observation erase a known bundle;
        // retaining the strong identity lets a later PID reuse be detected.
        if previousExternal.bundleID != nil,
           activatedExternal.bundleID == nil {
            return previousExternal
        }
        return activatedExternal
    }
}

/// Ordered staging buffer. Rime commits establish block boundaries before they
/// enter this model, so editing and delivery can preserve identity/provenance
/// without reviving the old diff/reconcile machinery.
final class BufferModel {
    static let shared = BufferModel()

    struct PluginMetadata: Equatable {
        let pluginId: String
        let actionId: String
        let requestId: String
        let contextId: String
        /// Original IMK focus authority, when generation began with a live
        /// target. Context-only generation may deliberately remain unbound.
        let focusToken: FocusToken?
        let runtimeIdentity: String
        let title: String?
        let targetSummary: String?
        let stale: Bool
        /// Visible streamed output remains fail-closed until its terminal frame
        /// and final target status both validate under the original lease.
        let incomplete: Bool
        let streamProtocolVersion: Int?
        let streamIndex: Int?
        /// The result is ordinary reviewed text rather than a target-bound
        /// delivery grant. This covers accepted stale inbox results and
        /// context-only generation that never held IMK focus authority.
        let reviewedAsPlainText: Bool

        init(pluginId: String,
             actionId: String,
             requestId: String,
             contextId: String,
             focusToken: FocusToken?,
             runtimeIdentity: String,
             title: String? = nil,
             targetSummary: String? = nil,
             stale: Bool = false,
             incomplete: Bool = false,
             streamProtocolVersion: Int? = nil,
             streamIndex: Int? = nil,
             reviewedAsPlainText: Bool = false) {
            self.pluginId = pluginId
            self.actionId = actionId
            self.requestId = requestId
            self.contextId = contextId
            self.focusToken = focusToken
            self.runtimeIdentity = runtimeIdentity
            self.title = title
            self.targetSummary = targetSummary
            self.stale = stale
            self.incomplete = incomplete
            self.streamProtocolVersion = streamProtocolVersion
            self.streamIndex = streamIndex
            self.reviewedAsPlainText = reviewedAsPlainText
        }

        func markingStale() -> PluginMetadata {
            PluginMetadata(pluginId: pluginId,
                           actionId: actionId,
                           requestId: requestId,
                           contextId: contextId,
                           focusToken: focusToken,
                           runtimeIdentity: runtimeIdentity,
                           title: title,
                           targetSummary: targetSummary,
                           stale: true,
                           incomplete: false,
                           streamProtocolVersion: streamProtocolVersion,
                           streamIndex: streamIndex,
                           reviewedAsPlainText: false)
        }

        func markingReviewedAsPlainText() -> PluginMetadata {
            PluginMetadata(pluginId: pluginId,
                           actionId: actionId,
                           requestId: requestId,
                           contextId: contextId,
                           focusToken: focusToken,
                           runtimeIdentity: runtimeIdentity,
                           title: title,
                           targetSummary: targetSummary,
                           stale: false,
                           incomplete: false,
                           streamProtocolVersion: nil,
                           streamIndex: nil,
                           reviewedAsPlainText: true)
        }
    }

    enum MutationReason: Equatable {
        case ordinary
        case transient
        case inputRoute
        case pluginStreamUpdate
        case pluginStreamFinalization
        case pluginStreamCancellation
        case blockRemoval
        case pause
        case privacyDiscard
    }

    struct PluginStreamUpdate {
        let id: UUID
        let index: Int
        let text: String
        let origin: Origin
        let metadata: PluginMetadata
    }

    struct PluginStreamFinalBlock {
        let id: UUID
        let index: Int
        let text: String
        let origin: Origin
        let metadata: PluginMetadata
    }

    struct Block {
        let id: UUID
        var text: String
        let origin: Origin
        let createdAt: Date
        var pluginMetadata: PluginMetadata?

        init(id: UUID = UUID(),
             text: String,
             origin: Origin = .rime,
             createdAt: Date = Date(),
             pluginMetadata: PluginMetadata? = nil) {
            self.id = id
            self.text = text
            self.origin = origin
            self.createdAt = createdAt
            self.pluginMetadata = pluginMetadata
        }
    }

    private(set) var blocks: [Block] = []
    private(set) var insertionIndex = 0
    /// Block-level selection owned by the workbench. The panel is deliberately
    /// not an editable NSTextView, so Select All is represented explicitly and
    /// the next local text/paste/backspace operation applies to this selection.
    private(set) var allContentSelected = false
    private(set) var transientEnabled = false
    private(set) var loadingMessage: String?
    private(set) var loadingRequestId: String?
    private(set) var transientLoadingActive = false
    private(set) var lastMutationReason: MutationReason = .ordinary
    private(set) var changeCount = 0
    private var captureRouteEnabled = false
    private(set) var captureFocusToken: FocusToken?
    private(set) var inputRouteGeneration: UInt64 = 0
    private struct DirectInputRun {
        let owner: DirectInputRunOwner
        var blockIDs: [UUID]

        var tailID: UUID? { blockIDs.last }
    }
    private var directInputRun: DirectInputRun?

    var stagedText: String { blocks.map(\.text).joined() }
    var stagedCharacterCount: Int { stagedText.count }
    var pendingDeliveryBlocks: [Block] {
        blocks.filter { $0.pluginMetadata?.incomplete != true }
    }
    var pendingDeliveryCount: Int { pendingDeliveryBlocks.count }
    var hasIncompletePluginBlocks: Bool {
        blocks.contains { $0.pluginMetadata?.incomplete == true }
    }

    /// External content exists to be sent to another app, so an optional
    /// app-switch cleanup must never erase it automatically.
    var holdsExternalContent: Bool {
        blocks.contains { $0.origin != .rime }
    }

    var shouldDisplay: Bool {
        active || !blocks.isEmpty || loadingMessage != nil
    }

    /// Interaction mode (typing, Return, deletion and navigation). External
    /// content never activates it implicitly; only an explicit capture route
    /// may own editing events.
    var active: Bool { inputRoute == .captureToBuffer }

    var inputRoute: BufferInputRoute {
        captureRouteEnabled ? .captureToBuffer : .directToHost
    }

    /// Processing remains available while the visible workbench owns staged
    /// content, even if physical keys have been returned to the host field.
    /// Closing the workbench clears `transientEnabled` through the pause path.
    var processingActive: Bool { captureRouteEnabled || transientEnabled }

    /// Wired to the independent workbench window in main.swift.
    var onChange: (() -> Void)?

    var enabled: Bool {
        get { captureRouteEnabled }
        set {
            guard captureRouteEnabled != newValue
                    || (!newValue && captureFocusToken != nil) else { return }
            captureRouteEnabled = newValue
            // Direct writes are retained for deterministic smoke tests and
            // compatibility call sites. Runtime capture uses
            // `activateCapture(for:)` so it is bound to one exact FocusToken.
            if !newValue { captureFocusToken = nil }
            if !newValue, !blocks.isEmpty { transientEnabled = true }
            inputRouteGeneration &+= 1
            UserDefaults.standard.set(newValue, forKey: "bufferEnabled")
            if !newValue { directInputRun = nil }
            if !newValue, !blocks.isEmpty {
                IMELog.write("buffer mode off; preserving \(blocks.count) queued blocks")
            }
            notifyChange(reason: .inputRoute)
        }
    }

    /// Explicitly grant capture to one trusted external focus. A later focus
    /// token can never inherit this route.
    func activateCapture(for token: FocusToken) {
        let changed = !captureRouteEnabled || captureFocusToken != token
        captureRouteEnabled = true
        captureFocusToken = token
        UserDefaults.standard.set(true, forKey: "bufferEnabled")
        guard changed else { return }
        inputRouteGeneration &+= 1
        directInputRun = nil
        IMELog.write("buffer input route -> capture token=\(token)")
        notifyChange(reason: .inputRoute)
    }

    func capturesInput(for token: FocusToken?) -> Bool {
        guard captureRouteEnabled else { return false }
        // A nil grant exists only for isolated legacy/model smoke tests. Live
        // controller paths always establish and validate an exact token.
        guard let captureFocusToken else { return token == nil }
        return captureFocusToken == token
    }

    /// Revoke key ownership without altering staged blocks or derived results.
    func routeDirectPreservingContent(reason: String) {
        guard captureRouteEnabled || captureFocusToken != nil else { return }
        captureRouteEnabled = false
        captureFocusToken = nil
        if !blocks.isEmpty { transientEnabled = true }
        inputRouteGeneration &+= 1
        UserDefaults.standard.set(false, forKey: "bufferEnabled")
        directInputRun = nil
        IMELog.write("buffer input route -> direct reason=\(reason) blocks=\(blocks.count)")
        notifyChange(reason: .inputRoute)
    }

    /// Showing a previously paused workbench re-enables source/result
    /// processing without claiming the focused application's key events.
    func resumeWorkbenchProcessing() {
        guard !processingActive, !blocks.isEmpty else { return }
        transientEnabled = true
        IMELog.write("buffer processing resumed blocks=\(blocks.count)")
        notifyChange(reason: .inputRoute)
    }

    /// A persistent workbench preserves content across applications by default.
    /// The old default-on reset remains available as an explicit privacy option.
    var resetOnAppSwitch: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "bufferResetOnAppSwitch.v2") != nil {
                return defaults.bool(forKey: "bufferResetOnAppSwitch.v2")
            }
            // Migrate the former inverted preference when it was explicitly
            // stored; a fresh install keeps the new workbench-safe default.
            if defaults.object(forKey: "bufferKeepOnAppSwitch") != nil {
                return !defaults.bool(forKey: "bufferKeepOnAppSwitch")
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: "bufferResetOnAppSwitch.v2") }
    }

    /// Stage accepted external text without changing the current input route.
    /// Visibility and content never grant keyboard ownership implicitly.
    func stageExternal(_ text: String,
                       origin: Origin,
                       pluginMetadata: PluginMetadata? = nil) {
        transientEnabled = true
        append(text, origin: origin, pluginMetadata: pluginMetadata)
    }

    /// Host-side normalization for plugin results that arrive as one coarse
    /// logical block. Every child retains the same origin and delivery
    /// authority; segmentation never launders plugin provenance.
    func stageExternalSemantic(_ text: String,
                               origin: Origin,
                               pluginMetadata: PluginMetadata? = nil) {
        transientEnabled = true
        let fragments = SemanticBlockSegmenter.refine(
            [SemanticLogicalBlock(sourceIndex: 0,
                                  text: text,
                                  title: pluginMetadata?.title)],
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        for fragment in fragments {
            append(fragment.text,
                   origin: origin,
                   pluginMetadata: pluginMetadata)
        }
    }

    func append(_ text: String,
                origin: Origin = .rime,
                pluginMetadata: PluginMetadata? = nil) {
        guard !text.isEmpty else { return }
        if !captureRouteEnabled { transientEnabled = true }
        if origin == .rime, pluginMetadata == nil {
            removeSelectedContentBeforeLocalInsertion()
        }
        directInputRun = nil
        let index = clampedInsertionIndex()
        blocks.insert(Block(text: text,
                            origin: origin,
                            pluginMetadata: pluginMetadata),
                      at: index)
        insertionIndex = index + 1
        IMELog.write("buffer insert block at \(index) origin=\(origin.tag) count=\(blocks.count)")
        notifyChange()
    }

    /// Append one or more printable characters from an ASCII/direct input
    /// event. The open tail keeps its UUID while it grows; when the shared
    /// segmenter closes a short phrase, a new tail block is created. This gives
    /// English immediate workbench visibility without producing one block per
    /// physical key.
    @discardableResult
    func appendDirectInputFragment(_ text: String,
                                   owner: DirectInputRunOwner) -> UUID? {
        guard !text.isEmpty else { return nil }
        removeSelectedContentBeforeLocalInsertion()
        let existingIndex: Int?
        if let run = directInputRun,
           run.owner == owner,
           let tailID = run.tailID,
           let index = blocks.firstIndex(where: { $0.id == tailID }),
           index == insertionIndex - 1,
           blocks[index].origin == .rime,
           blocks[index].pluginMetadata == nil {
            existingIndex = index
        } else {
            directInputRun = nil
            existingIndex = nil
        }

        let prefix = existingIndex.map { blocks[$0].text } ?? ""
        let segments = SemanticBlockSegmenter.segments(from: prefix + text)
        guard !segments.isEmpty else { return nil }

        var runIDs = existingIndex == nil ? [] : (directInputRun?.blockIDs ?? [])
        var tailID: UUID
        if let existingIndex {
            blocks[existingIndex].text = segments[0]
            tailID = blocks[existingIndex].id
            var insertion = existingIndex + 1
            for segment in segments.dropFirst() {
                let block = Block(text: segment)
                tailID = block.id
                runIDs.append(block.id)
                blocks.insert(block, at: insertion)
                insertion += 1
            }
            insertionIndex = insertion
        } else {
            var insertion = clampedInsertionIndex()
            tailID = UUID()
            for segment in segments {
                let block = Block(text: segment)
                tailID = block.id
                runIDs.append(block.id)
                blocks.insert(block, at: insertion)
                insertion += 1
            }
            insertionIndex = insertion
        }
        directInputRun = DirectInputRun(owner: owner, blockIDs: runIDs)
        IMELog.write("buffer direct input fragments=\(segments.count) blocks=\(blocks.count)")
        notifyChange()
        return tailID
    }

    /// Character-level editing is reserved for the still-open direct tail.
    /// Completed Rime/plugin blocks retain the workbench's block-level delete
    /// semantics.
    @discardableResult
    func deleteBackwardInDirectInput(owner: DirectInputRunOwner) -> Bool {
        if removeSelectedContentForDeletion() { return true }
        guard var run = directInputRun,
              run.owner == owner,
              let tailID = run.tailID,
              let index = blocks.firstIndex(where: { $0.id == tailID }),
              index == insertionIndex - 1,
              blocks[index].origin == .rime,
              blocks[index].pluginMetadata == nil else {
            directInputRun = nil
            return false
        }
        if blocks[index].text.count > 1 {
            blocks[index].text.removeLast()
            IMELog.write("buffer direct input delete block=\(tailID)")
            notifyChange(reason: .blockRemoval)
            return true
        }
        blocks.remove(at: index)
        insertionIndex = index
        run.blockIDs.removeLast()
        directInputRun = run.blockIDs.isEmpty ? nil : run
        settleTransientIfIdle()
        IMELog.write("buffer direct input delete removed block=\(tailID)")
        notifyChange(reason: .blockRemoval)
        return true
    }

    func finishDirectInputRun(owner: DirectInputRunOwner? = nil) {
        guard owner == nil || directInputRun?.owner == owner else { return }
        directInputRun = nil
    }

    func beginTransientLoading(requestId: String, message: String) {
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        transientLoadingActive = true
        IMELog.write("buffer transient loading request=\(requestId) message=\(IMELog.redact(message))")
        notifyChange(reason: .transient)
    }

    /// Refresh the visible activity for the same asynchronous request without
    /// changing its lease or treating a heartbeat as generated content.
    func updateTransientLoading(requestId: String, message: String) {
        guard loadingRequestId == requestId,
              transientLoadingActive,
              loadingMessage != message else { return }
        loadingMessage = message
        notifyChange(reason: .transient)
    }

    func appendMarineDraft(_ text: String, requestId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        transientEnabled = true
        if loadingRequestId == requestId {
            loadingRequestId = nil
            loadingMessage = nil
            transientLoadingActive = false
        }
        let fragments = SemanticBlockSegmenter.refine(
            [SemanticLogicalBlock(sourceIndex: 0, text: text, title: nil)],
            maximumSegments: SemanticBlockSegmenter.maximumWorkbenchSegments
        )
        for fragment in fragments {
            append(fragment.text, origin: .marine)
        }
        IMELog.write("buffer marine draft loaded request=\(requestId) chars=\(text.count) blocks=\(fragments.count)")
    }

    func failTransientLoading(requestId: String, message: String) {
        guard loadingRequestId == nil || loadingRequestId == requestId else { return }
        transientEnabled = true
        loadingRequestId = requestId
        loadingMessage = message
        transientLoadingActive = false
        IMELog.write("buffer transient failed request=\(requestId) message=\(IMELog.redact(message))")
        notifyChange(reason: .transient)
    }

    /// Settle only the matching asynchronous placeholder. A stale completion
    /// must never erase a newer plugin/Marine request's status.
    func finishTransientLoading(requestId: String) {
        guard loadingRequestId == requestId else { return }
        loadingRequestId = nil
        loadingMessage = nil
        transientLoadingActive = false
        settleTransientIfIdle()
        notifyChange(reason: .transient)
    }

    /// Safe close-window behavior: stop invisible capture/interaction while
    /// preserving every staged block. Transient loading/error state is dropped
    /// because the simplified workbench intentionally has no manual Clear.
    func pauseCapturePreservingContent() {
        captureRouteEnabled = false
        captureFocusToken = nil
        inputRouteGeneration &+= 1
        UserDefaults.standard.set(false, forKey: "bufferEnabled")
        transientEnabled = false
        loadingRequestId = nil
        loadingMessage = nil
        transientLoadingActive = false
        directInputRun = nil
        IMELog.write("buffer capture paused; preserved blocks=\(blocks.count), cleared transient state")
        notifyChange(reason: .pause)
    }

    /// Move the block caret to an explicit gap selected by the logical input
    /// surface. Character-level editing is intentionally not implied.
    @discardableResult
    func setInsertionPoint(_ index: Int) -> Bool {
        let target = min(max(index, 0), blocks.count)
        let changed = insertionIndex != target || allContentSelected
        insertionIndex = target
        allContentSelected = false
        directInputRun = nil
        if changed { notifyPresentationChange() }
        return true
    }

    /// Delete the complete block immediately after the logical caret.
    @discardableResult
    func deleteForwardAtInsertionPoint() -> Bool {
        if removeSelectedContentForDeletion() { return true }
        let index = clampedInsertionIndex()
        guard blocks.indices.contains(index) else { return false }
        let removed = blocks.remove(at: index)
        if directInputRun?.blockIDs.contains(removed.id) == true {
            directInputRun = nil
        }
        clampInsertionIndexInPlace()
        settleTransientIfIdle()
        IMELog.write("buffer delete-forward block id=\(removed.id) origin=\(removed.origin.tag)")
        notifyChange(reason: .blockRemoval)
        return true
    }

    /// Select every staged block without changing source text or its delivery
    /// generation. Derived plugins therefore keep a valid ready result while
    /// the source rail merely changes its visual selection state.
    @discardableResult
    func selectAllContent() -> Bool {
        let selected = !blocks.isEmpty
        guard allContentSelected != selected else { return true }
        allContentSelected = selected
        directInputRun = nil
        notifyPresentationChange()
        return true
    }

    func clearAllContentSelection(notify: Bool = true) {
        guard allContentSelected else { return }
        allContentSelected = false
        if notify { notifyPresentationChange() }
    }

    /// Insert explicit clipboard text at the block caret, or replace the
    /// complete workbench selection. The shared semantic segmenter keeps paste
    /// behavior aligned with AI/translation/plugin output while preserving the
    /// exact concatenated text, including whitespace-only input.
    @discardableResult
    func insertPastedText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var segments = SemanticBlockSegmenter.segments(from: text)
        guard !segments.isEmpty else { return false }
        if segments.count > SemanticBlockSegmenter.maximumWorkbenchSegments {
            let maximum = SemanticBlockSegmenter.maximumWorkbenchSegments
            var compacted: [String] = []
            compacted.reserveCapacity(maximum)
            var cursor = 0
            for index in 0..<maximum {
                let remaining = segments.count - cursor
                let groups = maximum - index
                let take = Int(ceil(Double(remaining) / Double(groups)))
                compacted.append(segments[cursor..<cursor + take].joined())
                cursor += take
            }
            segments = compacted
        }

        removeSelectedContentBeforeLocalInsertion()
        if !captureRouteEnabled { transientEnabled = true }
        directInputRun = nil
        var insertion = clampedInsertionIndex()
        for segment in segments {
            blocks.insert(Block(text: segment), at: insertion)
            insertion += 1
        }
        insertionIndex = insertion
        IMELog.write("buffer pasted chars=\(text.count) fragments=\(segments.count)")
        notifyChange()
        return true
    }

    @discardableResult
    func removeLastBlock() -> Bool {
        if removeSelectedContentForDeletion() { return true }
        guard let removed = blocks.popLast() else { return false }
        if directInputRun?.blockIDs.contains(removed.id) == true { directInputRun = nil }
        clampInsertionIndexInPlace()
        IMELog.write("buffer remove last block \(IMELog.redact(removed.text)) remaining=\(blocks.count)")
        settleTransientIfIdle()
        notifyChange(reason: .blockRemoval)
        return true
    }

    /// Translation presents the source as one continuous buffer even though
    /// Rime commit boundaries remain internally available for provenance.
    @discardableResult
    func removeLastCharacter() -> Bool {
        if removeSelectedContentForDeletion() { return true }
        guard let index = blocks.indices.last else { return false }
        directInputRun = nil
        if blocks[index].text.count <= 1 {
            return removeBlock(id: blocks[index].id)
        }
        blocks[index].text.removeLast()
        IMELog.write("buffer remove last character block=\(blocks[index].id) origin=\(blocks[index].origin.tag)")
        notifyChange(reason: .blockRemoval)
        return true
    }

    @discardableResult
    func removeBlock(id: UUID) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return false }
        let removed = blocks.remove(at: index)
        if directInputRun?.blockIDs.contains(removed.id) == true { directInputRun = nil }
        if insertionIndex > index { insertionIndex -= 1 }
        clampInsertionIndexInPlace()
        settleTransientIfIdle()
        IMELog.write("buffer remove block id=\(id) origin=\(removed.origin.tag)")
        notifyChange(reason: .blockRemoval)
        return true
    }

    func block(id: UUID) -> Block? {
        blocks.first(where: { $0.id == id })
    }

    /// Apply coalesced full snapshots for one invocation with one notification.
    /// UUIDs are allocated once by the host for each logical stream index.
    @discardableResult
    func applyPluginStreamUpdates(requestId: String,
                                  updates: [PluginStreamUpdate]) -> Bool {
        guard !updates.isEmpty,
              Set(updates.map(\.id)).count == updates.count,
              Set(updates.map(\.index)).count == updates.count,
              updates.allSatisfy({ update in
                  !update.text.isEmpty
                      && update.metadata.requestId == requestId
                      && update.metadata.incomplete
                      && update.metadata.streamIndex == update.index
                      && streamOriginMatches(update.origin, metadata: update.metadata)
              }) else { return false }

        // Validate the whole batch before touching the model. A malformed or
        // stale coalesced update must never leave an earlier item applied.
        for update in updates {
            if let sameLogicalBlock = blocks.first(where: {
                $0.id != update.id
                    && $0.pluginMetadata?.requestId == requestId
                    && $0.pluginMetadata?.streamIndex == update.index
            }) {
                IMELog.write("buffer plugin stream duplicate logical block id=\(sameLogicalBlock.id)")
                return false
            }
            guard let existingIndex = blocks.firstIndex(where: { $0.id == update.id }) else {
                continue
            }
            guard let existingMetadata = blocks[existingIndex].pluginMetadata,
                  streamLeaseMatches(existingMetadata, update.metadata),
                  blocks[existingIndex].origin == update.origin else { return false }
        }

        directInputRun = nil
        for update in updates.sorted(by: { $0.index < $1.index }) {
            if let existingIndex = blocks.firstIndex(where: { $0.id == update.id }) {
                blocks[existingIndex].text = update.text
                blocks[existingIndex].pluginMetadata = update.metadata
            } else {
                let index = insertionIndexForStreamBlock(requestId: requestId,
                                                         streamIndex: update.index)
                blocks.insert(Block(id: update.id,
                                    text: update.text,
                                    origin: update.origin,
                                    pluginMetadata: update.metadata),
                              at: index)
                if index <= insertionIndex { insertionIndex += 1 }
                clampInsertionIndexInPlace()
            }
        }
        transientEnabled = true
        if loadingRequestId == requestId {
            loadingRequestId = nil
            loadingMessage = nil
            transientLoadingActive = false
        }
        IMELog.write("buffer plugin stream update request=\(requestId) blocks=\(updates.count)")
        notifyChange(reason: .pluginStreamUpdate)
        return true
    }

    /// Reconcile provisional snapshots with the authoritative terminal array.
    /// Existing indices retain their UUIDs; terminal-only indices use UUIDs
    /// supplied by the host. The entire promotion emits one model change.
    @discardableResult
    func finalizePluginStream(requestId: String,
                              partialBlockIDs: Set<UUID>,
                              blocks finalBlocks: [PluginStreamFinalBlock]) -> Bool {
        guard !finalBlocks.isEmpty,
              Set(finalBlocks.map(\.id)).count == finalBlocks.count,
              Set(finalBlocks.map(\.index)).count == finalBlocks.count,
              finalBlocks.allSatisfy({ block in
                  !block.text.isEmpty
                      && block.metadata.requestId == requestId
                      && !block.metadata.incomplete
                      && !block.metadata.stale
                      && block.metadata.streamIndex == block.index
                      && streamOriginMatches(block.origin, metadata: block.metadata)
              }) else { return false }

        let livePartialIDs = Set(blocks.compactMap { block -> UUID? in
            guard block.pluginMetadata?.requestId == requestId,
                  block.pluginMetadata?.incomplete == true else { return nil }
            return block.id
        })
        guard livePartialIDs == partialBlockIDs else { return false }

        for id in partialBlockIDs {
            guard let existing = blocks.first(where: { $0.id == id }),
                  existing.pluginMetadata?.requestId == requestId,
                  existing.pluginMetadata?.incomplete == true else { return false }
        }

        // Promotion is transactional as well: validate every surviving UUID
        // before removing superseded provisional blocks or changing text.
        for final in finalBlocks {
            if blocks.contains(where: {
                $0.id != final.id
                    && $0.pluginMetadata?.requestId == requestId
                    && $0.pluginMetadata?.streamIndex == final.index
            }) {
                return false
            }
            guard let existingIndex = blocks.firstIndex(where: { $0.id == final.id }) else {
                continue
            }
            guard let existingMetadata = blocks[existingIndex].pluginMetadata,
                  existingMetadata.requestId == requestId,
                  existingMetadata.incomplete,
                  streamAuthorityMatches(existingMetadata, final.metadata),
                  blocks[existingIndex].origin == final.origin else { return false }
        }

        directInputRun = nil
        let finalIDs = Set(finalBlocks.map(\.id))
        removeBlocksWithoutNotification(ids: partialBlockIDs.subtracting(finalIDs),
                                        requestId: requestId,
                                        requireIncomplete: true)

        for final in finalBlocks.sorted(by: { $0.index < $1.index }) {
            if let existingIndex = blocks.firstIndex(where: { $0.id == final.id }) {
                blocks[existingIndex].text = final.text
                blocks[existingIndex].pluginMetadata = final.metadata
            } else {
                let index = insertionIndexForStreamBlock(requestId: requestId,
                                                         streamIndex: final.index)
                blocks.insert(Block(id: final.id,
                                    text: final.text,
                                    origin: final.origin,
                                    pluginMetadata: final.metadata),
                              at: index)
                if index <= insertionIndex { insertionIndex += 1 }
                clampInsertionIndexInPlace()
            }
        }
        transientEnabled = true
        if loadingRequestId == requestId {
            loadingRequestId = nil
            loadingMessage = nil
            transientLoadingActive = false
        }
        IMELog.write("buffer plugin stream finalized request=\(requestId) blocks=\(finalBlocks.count)")
        notifyChange(reason: .pluginStreamFinalization)
        return true
    }

    /// Cancellation removes only provisional UUIDs owned by this invocation.
    /// Finalized results and other requests cannot match this mutation.
    func removePluginStreamBlocks(requestId: String, blockIDs: Set<UUID>) {
        let before = blocks.count
        removeBlocksWithoutNotification(ids: blockIDs,
                                        requestId: requestId,
                                        requireIncomplete: true)
        guard blocks.count != before else { return }
        if let run = directInputRun,
           !run.blockIDs.allSatisfy({ id in blocks.contains(where: { $0.id == id }) }) {
            directInputRun = nil
        }
        settleTransientIfIdle()
        IMELog.write("buffer plugin stream removed request=\(requestId) blocks=\(before - blocks.count)")
        notifyChange(reason: .pluginStreamCancellation)
    }

    @discardableResult
    func markPluginBlockStale(id: UUID) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == id }),
              let metadata = blocks[index].pluginMetadata,
              !metadata.stale,
              !metadata.reviewedAsPlainText else { return false }
        blocks[index].pluginMetadata = metadata.markingStale()
        IMELog.write("buffer plugin block marked stale id=\(id)")
        notifyChange()
        return true
    }

    @discardableResult
    func moveInsertionPoint(delta: Int) -> Bool {
        directInputRun = nil
        if allContentSelected {
            allContentSelected = false
            insertionIndex = delta < 0 ? 0 : blocks.count
            IMELog.write("buffer selection collapsed index=\(insertionIndex)")
            notifyPresentationChange()
            return true
        }
        let old = clampedInsertionIndex()
        let next = min(max(old + delta, 0), blocks.count)
        insertionIndex = next
        guard next != old else {
            IMELog.write("buffer insertion point edge index=\(next) count=\(blocks.count)")
            return false
        }
        IMELog.write("buffer insertion point \(old)->\(next) count=\(blocks.count)")
        notifyChange()
        return true
    }

    /// Consume accepted delivery attempts from the live workbench in one model
    /// mutation. No plaintext delivery history is retained.
    func consumeDelivered(blockIDs: [UUID]) {
        guard !blockIDs.isEmpty else { return }
        let ids = Set(blockIDs)
        let deliveredIndexes = blocks.indices.filter {
            ids.contains(blocks[$0].id) && blocks[$0].pluginMetadata?.incomplete != true
        }
        guard !deliveredIndexes.isEmpty else { return }

        let removedBeforeInsertion = deliveredIndexes.reduce(into: 0) { count, index in
            if index < insertionIndex { count += 1 }
        }
        blocks.removeAll { ids.contains($0.id) && $0.pluginMetadata?.incomplete != true }
        if let run = directInputRun,
           !run.blockIDs.allSatisfy({ id in blocks.contains(where: { $0.id == id }) }) {
            directInputRun = nil
        }
        insertionIndex -= removedBeforeInsertion
        clampInsertionIndexInPlace()
        settleTransientIfIdle()
        IMELog.write("buffer delivery consumed blocks=\(deliveredIndexes.count) remaining=\(blocks.count)")
        notifyChange()
    }

    /// Non-recoverable privacy cleanup used by automatic safety transitions.
    func discardForPrivacy() {
        let blockCount = blocks.count
        blocks.removeAll()
        insertionIndex = 0
        loadingRequestId = nil
        loadingMessage = nil
        transientLoadingActive = false
        transientEnabled = false
        directInputRun = nil
        IMELog.write("buffer privacy discard blocks=\(blockCount)")
        notifyChange(reason: .privacyDiscard)
    }

    private func removeSelectedContentBeforeLocalInsertion() {
        guard allContentSelected else { return }
        blocks.removeAll()
        insertionIndex = 0
        directInputRun = nil
        allContentSelected = false
    }

    @discardableResult
    private func removeSelectedContentForDeletion() -> Bool {
        guard allContentSelected else { return false }
        let removed = blocks.count
        blocks.removeAll()
        insertionIndex = 0
        directInputRun = nil
        allContentSelected = false
        settleTransientIfIdle()
        IMELog.write("buffer selected content removed blocks=\(removed)")
        notifyChange(reason: .blockRemoval)
        return true
    }

    private func clampedInsertionIndex() -> Int {
        min(max(insertionIndex, 0), blocks.count)
    }

    private func clampInsertionIndexInPlace() {
        insertionIndex = clampedInsertionIndex()
    }

    private func settleTransientIfIdle() {
        if transientEnabled, blocks.isEmpty, loadingMessage == nil {
            transientEnabled = false
        }
    }

    private func insertionIndexForStreamBlock(requestId: String,
                                              streamIndex: Int) -> Int {
        let sameRequest = blocks.indices.filter {
            blocks[$0].pluginMetadata?.requestId == requestId
                && blocks[$0].pluginMetadata?.streamIndex != nil
        }
        if let before = sameRequest.first(where: {
            (blocks[$0].pluginMetadata?.streamIndex ?? Int.max) > streamIndex
        }) {
            return before
        }
        if let last = sameRequest.last { return last + 1 }
        return clampedInsertionIndex()
    }

    private func removeBlocksWithoutNotification(ids: Set<UUID>,
                                                 requestId: String,
                                                 requireIncomplete: Bool) {
        let indexes = blocks.indices.filter { index in
            let block = blocks[index]
            guard ids.contains(block.id),
                  block.pluginMetadata?.requestId == requestId else { return false }
            return !requireIncomplete || block.pluginMetadata?.incomplete == true
        }
        let removedBeforeInsertion = indexes.reduce(into: 0) { count, index in
            if index < insertionIndex { count += 1 }
        }
        blocks.removeAll { block in
            guard ids.contains(block.id),
                  block.pluginMetadata?.requestId == requestId else { return false }
            return !requireIncomplete || block.pluginMetadata?.incomplete == true
        }
        insertionIndex -= removedBeforeInsertion
        clampInsertionIndexInPlace()
    }

    private func streamOriginMatches(_ origin: Origin,
                                     metadata: PluginMetadata) -> Bool {
        guard case let .plugin(pluginID) = origin else { return false }
        return pluginID == metadata.pluginId
    }

    private func streamLeaseMatches(_ lhs: PluginMetadata,
                                    _ rhs: PluginMetadata) -> Bool {
        lhs.incomplete
            && rhs.incomplete
            && lhs.streamIndex == rhs.streamIndex
            && streamAuthorityMatches(lhs, rhs)
    }

    private func streamAuthorityMatches(_ lhs: PluginMetadata,
                                        _ rhs: PluginMetadata) -> Bool {
        lhs.pluginId == rhs.pluginId
            && lhs.actionId == rhs.actionId
            && lhs.requestId == rhs.requestId
            && lhs.contextId == rhs.contextId
            && lhs.focusToken == rhs.focusToken
            && lhs.runtimeIdentity == rhs.runtimeIdentity
            && lhs.streamProtocolVersion == rhs.streamProtocolVersion
    }

    private func notifyChange(reason: MutationReason = .ordinary) {
        // Loading/error heartbeats are presentation-only and must not make a
        // user's Select All evaporate while an Action plugin is still working.
        // Every actual source/block mutation uses a non-transient reason.
        if reason != .transient && reason != .inputRoute {
            allContentSelected = false
        }
        lastMutationReason = reason
        if reason != .inputRoute { changeCount += 1 }
        onChange?()
        NotificationCenter.default.post(name: .bufferModelDidChange, object: self)
    }

    private func notifyPresentationChange() {
        onChange?()
    }
}

extension Notification.Name {
    static let bufferModelDidChange = Notification.Name("BufferModelDidChange")
}
