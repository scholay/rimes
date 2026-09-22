import Cocoa
import Carbon.HIToolbox

/// Geometry for the standalone, bottom-anchored Clipboard History timeline.
enum ClipboardHistoryWindowMetrics {
    static let preferredWidth: CGFloat = 940
    // Header, one card row and one hint line; no spare second-row band.
    static let preferredHeight: CGFloat = 208
    static let minimumWidth: CGFloat = 620
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 12
    static let cardWidth: CGFloat = 206
    static let cardHeight: CGFloat = 126
    static let cardSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 14
    static let previewCharacterLimit = 280
    static let accessibilityCharacterLimit = 512
    static let previewMaximumPixelSize = 512
    /// Keep the AppKit hierarchy bounded even when the durable store contains
    /// thousands of historical entries. Search still evaluates every loaded
    /// metadata row before this presentation cap is applied.
    static let maximumRenderedCards = 200
}

enum ClipboardHistorySearchRules {
    static func filter(_ items: [ClipboardHistoryItem], query: String)
        -> [ClipboardHistoryItem] {
        let terms = query.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            terms.allSatisfy { term in
                (item.searchText ?? item.canonicalText ?? item.displayText ?? "")
                    .localizedCaseInsensitiveContains(term)
                    || (item.sourceApplicationName?
                        .localizedCaseInsensitiveContains(term) ?? false)
                    || (item.sourceApplicationBundleIdentifier?
                        .localizedCaseInsensitiveContains(term) ?? false)
                    || item.kind.rawValue.localizedCaseInsensitiveContains(term)
                    || item.kind.searchAliases.localizedCaseInsensitiveContains(term)
            }
        }
    }
}

enum ClipboardHistoryScrollRules {
    static func horizontalDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        precise: Bool,
        shiftHeld: Bool
    ) -> CGFloat {
        let raw = abs(deltaX) > 0.01 ? deltaX : deltaY
        guard abs(raw) > 0.01 else { return 0 }
        let scale: CGFloat
        if shiftHeld {
            scale = precise ? 2.5 : 48
        } else if abs(deltaX) > 0.01 {
            scale = 1
        } else {
            scale = precise ? 1.35 : 32
        }
        // The two devices need opposite signs, so one shared rule cannot serve
        // both: macOS applies its natural-scroll inversion per input device,
        // and a wheel gesture mapped onto a horizontal rail is an app
        // convention rather than a reported axis. `hasPreciseScrollingDeltas`
        // separates them reliably — precise deltas come from the trackpad,
        // coarse steps from a wheel. The wheel direction is the one that
        // already matches expectation, so it keeps its negation and the
        // trackpad follows the content the other way.
        let signedRaw = precise ? raw : -raw
        let scaled = signedRaw * scale
        let maximumStep: CGFloat = precise ? 180 : 240
        return min(maximumStep, max(-maximumStep, scaled))
    }
}

struct ClipboardHistoryCardActionContext {
    let modifiers: NSEvent.ModifierFlags
    let clickCount: Int

    static let keyboard = ClipboardHistoryCardActionContext(
        modifiers: [],
        clickCount: 1
    )

    init(modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        self.clickCount = max(1, clickCount)
    }

    init(event: NSEvent) {
        self.init(modifiers: event.modifierFlags, clickCount: event.clickCount)
    }
}

struct ClipboardHistoryPaneSnapshot: Equatable {
    let cardCount: Int
    let selectedCardCount: Int
    let renderedThumbnailCount: Int
    let selectedCardBorderWidth: CGFloat?
    let queryCharacterCount: Int
    /// Whether the borrowed-Rime search box shows an insertion point, and
    /// where it sits. Typing used to change the text with nothing to say the
    /// box was live.
    let searchCaretVisible: Bool
    let searchCaretX: CGFloat
    let stateIsVisible: Bool
    let contentIsProtected: Bool
    let cardWidth: CGFloat
    let cardHeight: CGFloat
}

struct CapsuleRailPaneSnapshot: Equatable {
    let tab: CapsuleRailTab
    let cardCount: Int
    let selectedEntryID: UUID?
    let editableCardCount: Int
    let inCapsuleCardCount: Int
    let hint: String
    let stateMessage: String?
    let clearButtonVisible: Bool
    let countText: String
}

enum ClipboardHistoryStandaloneEditingRules {
    static func permitsSurfaceCommand(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    static func shouldDeleteSelectedCards(
        queryIsEmpty: Bool,
        selectedCount: Int,
        hasMarkedText: Bool
    ) -> Bool {
        guard !hasMarkedText else { return false }
        return queryIsEmpty || selectedCount > 1
    }
}

/// Paste-inspired visual timeline. RIMES mode feeds the logical search label
/// through the active IMK controller; standalone mode exposes a native AppKit
/// field so whichever input method is selected can edit the query normally.
/// This view never touches the pasteboard or an IMK client.
@MainActor
final class ClipboardHistoryPaneView: NSView, NSTextFieldDelegate {
    var onActivate: (([ClipboardHistoryItem]) -> Bool)?
    var onCopy: (([ClipboardHistoryItem]) -> Bool)?
    var onClose: (() -> Void)?
    /// Saved Capsule entries. The pane never asks to insert or copy a
    /// password, and the controller refuses one again before any write.
    var onActivateSaved: ((CapsuleRailEntry) -> Bool)?
    var onCopySaved: ((CapsuleRailEntry) -> Bool)?
    var onEditSaved: ((CapsuleRailEntry) -> Void)?
    var onDeleteSaved: ((CapsuleRailEntry) -> Void)?
    var onMigrateSaved: ((CapsuleRailEntry) -> Void)?
    var onMigrateHistory: ((ClipboardHistoryItem) -> Void)?
    var onRequestPasswordInput: (() -> Bool)?
    var onManage: (() -> Void)?
    var onCreateSaved: ((CapsuleEntryKind) -> Void)?
    /// Recent cards: ⌘S saves the selection; the menu's Edit action opens one
    /// as a new, unsaved entry in the compact detail form.
    var onSaveHistory: (([ClipboardHistoryItem]) -> Bool)?
    var onEditHistory: ((ClipboardHistoryItem) -> Void)?

    private let model: ClipboardHistoryModel
    private let library: CapsuleRailLibrary
    private let passcodeStore: CapsuleRevealPasscodeStore
    private var passwordCardID: UUID?
    private var passwordCard: CapsuleCardPasswordView?
    var hasPasswordInteraction: Bool { passwordCard != nil }
    private let titleLabel = NSTextField(labelWithString: "Capsule")
    private let tabStrip = CapsuleRailTabStrip()
    private let captureButton = ClipboardFirstMouseButton(title: "", target: nil, action: nil)
    private static let headerGlyphPointSize: CGFloat = 12
    private static let headerGlyphWeight: NSFont.Weight = .semibold
    private static let headerGlyphBox: CGFloat = 22
    private let capturesView = CaptureHistoryView()
    private let manageButton = ClipboardFirstMouseButton(title: "", target: nil, action: nil)
    private let createButton = ClipboardFirstMouseButton(title: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let searchShell = NSView()
    private let searchIcon = NSImageView()
    private let searchLabel = NSTextField(labelWithString: "")
    /// Under RIMES the search box is a label, not a field, so AppKit draws no
    /// insertion point and no focus ring: typing changed the text with no sign
    /// that the box was live. This is that missing caret.
    private let searchCaret = NSView()
    private var caretBlink: Timer?
    /// A caret that is always on says the box is focused when it is not.
    /// Clicking the box focuses it; clicking a card or the background takes
    /// it away, the way a real search field behaves. Typing focuses it too,
    /// because under RIMES every plain key is routed here.
    private var searchFocused = false
    private let standaloneSearchField = NSTextField()
    private let clearButton = ClipboardFirstMouseButton(title: "清空", target: nil, action: nil)
    private let closeButton = ClipboardFirstMouseButton(title: "", target: nil, action: nil)
    private let scrollView = ClipboardHistoryHorizontalScrollView()
    private let cardDocumentView = ClipboardHistoryCardDocumentView()
    private let stateContainer = NSView()
    private let stateIcon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var cardButtons: [UUID: ClipboardHistoryCardButton] = [:]
    private var modelObserver: UUID?
    private var appearanceObserver: NSObjectProtocol?
    private var viewportObserver: NSObjectProtocol?
    private var clearConfirmationGeneration: UInt64 = 0
    private var clearConfirmationArmed = false
    private var selectionAnchorID: UUID?
    /// Nonzero while a click is mutating the selection; see
    /// `handleCardInteraction`. A counter, not a flag, because activation can
    /// re-enter the model while the click is still on the stack.
    private var pointerDrivenSelectionDepth = 0
    private var visibleItemByID: [UUID: ClipboardHistoryItem] = [:]
    private let thumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()
    private let sourceIconCache = NSCache<NSString, NSImage>()
    private lazy var fallbackSourceIcon = RimeUI.symbol(
        "app.fill",
        pointSize: 14,
        weight: .regular
    )
    private var requestedThumbnailIDs = Set<UUID>()
    private var requestedSourceIconBundleIDs = Set<String>()
    private var assetGeneration: UInt64 = 0
    private(set) var query = ""
    private(set) var composingText = ""
    private(set) var standaloneSearchEnabled = false
    private(set) var selectedTab: CapsuleRailTab = .recent
    private var savedSelectedIDs: [CapsuleEntryKind: UUID] = [:]
    private var savedCardButtons: [UUID: ClipboardHistoryCardButton] = [:]
    private var visibleSavedEntryByID: [UUID: CapsuleRailEntry] = [:]
    private var savedThumbnailOperations: [UUID: Operation] = [:]
    private let savedThumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    init(model: ClipboardHistoryModel,
         library: CapsuleRailLibrary = .inert(),
         passcodeStore: CapsuleRevealPasscodeStore = .shared) {
        self.model = model
        self.library = library
        self.passcodeStore = passcodeStore
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: ClipboardHistoryWindowMetrics.preferredWidth,
            height: ClipboardHistoryWindowMetrics.preferredHeight
        ))
        capturesView.enabled = library.usesLiveCaptureHistory
        configureView()
        modelObserver = model.addObserver { [weak self] in self?.reloadFromModel() }
        library.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.concealCardPassword()
                self?.reloadFromModel()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyAppearance()
                self?.reloadFromModel()
            }
        }
        reloadFromModel()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let viewportObserver {
            NotificationCenter.default.removeObserver(viewportObserver)
        }
    }

    override var isFlipped: Bool { true }

    func resetSearch() {
        concealCardPassword()
        selectionAnchorID = model.selectedID
        if !query.isEmpty || !composingText.isEmpty {
            query = ""
            composingText = ""
            reloadFromModel()
        }
        if !standaloneSearchField.stringValue.isEmpty {
            standaloneSearchField.stringValue = ""
        }
    }

    func setStandaloneSearchEnabled(_ enabled: Bool) {
        guard standaloneSearchEnabled != enabled else {
            if enabled { standaloneSearchField.stringValue = query }
            return
        }
        standaloneSearchEnabled = enabled
        standaloneSearchField.stringValue = query
        standaloneSearchField.isHidden = !enabled
        searchLabel.isHidden = enabled
        updateHint()
        updateSearchPresentation()
    }

    func focusStandaloneSearch() {
        guard standaloneSearchEnabled else { return }
        window?.makeFirstResponder(standaloneSearchField)
    }

    func setStandaloneSearchTextForSmoke(_ text: String) {
        precondition(standaloneSearchEnabled)
        standaloneSearchField.stringValue = text
        controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: standaloneSearchField
        ))
    }

    func scrubForProtection() {
        concealCardPassword()
        query = ""
        composingText = ""
        selectionAnchorID = nil
        clearThumbnailState()
        clearSavedThumbnailState()
        removeAllCards()
        removeAllSavedCards()
        reloadFromModel()
    }

    /// Commits text produced by the existing Rime session into the logical
    /// search field. Physical alphabet keys never append here directly.
    @discardableResult
    func appendSearchText(_ text: String) -> Bool {
        guard !hasPasswordInteraction else { return true }
        guard !text.isEmpty,
              !text.contains("\0"),
              text.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { return false }
        composingText = ""
        query.append(contentsOf: text)
        setSearchFocused(true)
        reloadFromModel()
        return true
    }

    func updateComposingText(_ text: String) {
        guard text != composingText else { return }
        composingText = text
        reloadFromModel()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard standaloneSearchEnabled else { return }
        query = standaloneSearchField.stringValue
        composingText = ""
        reloadFromModel()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === standaloneSearchField,
              standaloneSearchEnabled else { return false }
        // Leave every command with the active third-party input method until
        // its marked text is settled. Owning Return/Escape/arrows here could
        // activate a card, close Clip, or move selection underneath composition.
        guard ClipboardHistoryStandaloneEditingRules.permitsSurfaceCommand(
            hasMarkedText: textView.hasMarkedText()
        ) else { return false }
        switch NSStringFromSelector(commandSelector) {
        case "insertTab:":
            selectTab(selectedTab.cycled(by: 1))
            return true
        case "insertBacktab:":
            selectTab(selectedTab.cycled(by: -1))
            return true
        case "insertNewline:", "insertLineBreak:",
             "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:":
            _ = activateSelectedItems()
            return true
        case "cancelOperation:":
            if query.isEmpty { onClose?() } else { resetSearch() }
            return true
        case "moveLeft:", "moveUp:":
            moveFilteredSelection(delta: -1, extending: false)
            return true
        case "moveRight:", "moveDown:":
            moveFilteredSelection(delta: 1, extending: false)
            return true
        case "deleteBackward:", "deleteForward:",
             "deleteBackwardByDecomposingPreviousCharacter:":
            // Saved entries are read-only here: Delete only edits the query.
            guard selectedTab == .recent else { return query.isEmpty }
            guard ClipboardHistoryStandaloneEditingRules
                .shouldDeleteSelectedCards(
                    queryIsEmpty: query.isEmpty,
                    selectedCount: selectedFilteredItems.count,
                    hasMarkedText: textView.hasMarkedText()
                ) else {
                // Keep ordinary editing and third-party IME composition inside
                // AppKit whenever this is a single-selection, nonempty query.
                return false
            }
            _ = deleteSelectedItems()
            return true
        default:
            return false
        }
    }

    /// AppKit sends Command-key equivalents through the panel instead of the
    /// text-field delegate. Keep those shortcuts with the active input method
    /// while its field editor owns marked text.
    func handleStandaloneKeyEquivalent(_ event: NSEvent) -> Bool {
        if hasPasswordInteraction {
            // Let unmodified physical key events reach the capture responder.
            // Only consume application commands, including Copy/Cut/Paste.
            return event.modifierFlags.contains(.command)
        }
        let hasMarkedText = (standaloneSearchField.currentEditor() as? NSTextView)?
            .hasMarkedText() == true
        return handleStandaloneKeyEquivalent(
            event,
            hasMarkedText: hasMarkedText
        )
    }

    func handleStandaloneKeyEquivalent(
        _ event: NSEvent,
        hasMarkedText: Bool
    ) -> Bool {
        guard standaloneSearchEnabled,
              ClipboardHistoryStandaloneEditingRules.permitsSurfaceCommand(
                hasMarkedText: hasMarkedText
              ) else { return false }
        return handleKeyDown(event)
    }

    /// CandidateWindow needs a screen-space caret even though the search box
    /// is a non-editable logical surface inside a nonactivating panel.
    func searchCaretRectOnScreen() -> NSRect? {
        layoutSubtreeIfNeeded()
        guard let window else { return nil }
        let labelRect = searchLabel.convert(searchLabel.bounds, to: nil)
        return window.convertToScreen(NSRect(
            x: caretX(in: labelRect),
            y: labelRect.minY,
            width: 1,
            height: max(1, labelRect.height)
        ))
    }

    /// Where the insertion point sits, measured once and used by both the
    /// drawn caret and the candidate-window anchor. Two measurements would
    /// drift apart and put the candidate list beside the wrong character.
    private func caretX(in labelRect: NSRect) -> CGFloat {
        let rendered = query + composingText
        guard !rendered.isEmpty else { return labelRect.minX }
        let width = ceil((rendered as NSString).size(withAttributes: [
            .font: searchLabel.font ?? NSFont.systemFont(ofSize: 12),
        ]).width)
        return min(labelRect.maxX, labelRect.minX + max(1, width))
    }

    /// Called before Rime or Buffer sees the event. Returns true only for a
    /// command owned by the visible Clip surface.
    @discardableResult
    func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let intentModifiers = modifiers.intersection([.command, .control, .option, .shift])
        let commandOnly = intentModifiers == [.command]

        if event.keyCode == UInt16(kVK_Tab),
           intentModifiers.isEmpty || intentModifiers == [.shift] {
            selectTab(selectedTab.cycled(by: intentModifiers == [.shift] ? -1 : 1))
            return true
        }
        if commandOnly, event.keyCode == UInt16(kVK_ANSI_F) { return true }
        if commandOnly, event.keyCode == UInt16(kVK_ANSI_S) {
            // Owned on every tab, so ⌘S never reaches the host app's Save.
            _ = saveSelectedItems()
            return true
        }
        if commandOnly, event.keyCode == UInt16(kVK_ANSI_C) {
            _ = copySelectedItems()
            return true
        }
        if commandOnly,
           let index = Self.commandDigitIndex(keyCode: event.keyCode) {
            _ = activateVisibleItem(at: index)
            return true
        }

        let hasCommandLikeModifier = !intentModifiers
            .intersection([.command, .control, .option]).isEmpty
        if hasCommandLikeModifier { return false }

        switch event.keyCode {
        case UInt16(kVK_Escape):
            if query.isEmpty && composingText.isEmpty { onClose?() } else { resetSearch() }
            return true
        case UInt16(kVK_LeftArrow):
            if selectedTab == .captures { capturesView.move(-1); return true }
            moveFilteredSelection(
                delta: -1,
                extending: intentModifiers == [.shift]
            )
            return true
        case UInt16(kVK_RightArrow):
            if selectedTab == .captures { capturesView.move(1); return true }
            moveFilteredSelection(
                delta: 1,
                extending: intentModifiers == [.shift]
            )
            return true
        case UInt16(kVK_UpArrow) where intentModifiers == [.shift]:
            moveFilteredSelection(delta: -1, extending: true)
            return true
        case UInt16(kVK_DownArrow) where intentModifiers == [.shift]:
            moveFilteredSelection(delta: 1, extending: true)
            return true
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
            let selectedCount = selectedFilteredItems.count
            let activated = activateSelectedItems()
            IMELog.write(
                "clipboard surface activation selected=\(selectedCount) "
                    + "query=\(query.count) composing=\(composingText.count) "
                    + "started=\(activated)"
            )
            return true
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            if selectedTab != .recent {
                // Saved entries are read-only here: Delete only edits the query.
                if !query.isEmpty {
                    query.removeLast()
                    reloadFromModel()
                } else if !composingText.isEmpty {
                    composingText = ""
                    reloadFromModel()
                }
                return true
            }
            if model.selectedIDs.count > 1
                    || (query.isEmpty && composingText.isEmpty) {
                _ = deleteSelectedItems()
            } else if !query.isEmpty {
                query.removeLast()
                reloadFromModel()
            } else {
                composingText = ""
                reloadFromModel()
            }
            return true
        default:
            break
        }

        // Printable input must continue through the current Rime session. Its
        // committed text returns through `appendSearchText`, which gives this
        // logical field Chinese composition without focusing an AppKit editor
        // or leaking raw Pinyin into the host.
        return false
    }

    @discardableResult
    func activateSelectedItems() -> Bool {
        if selectedTab == .captures { return capturesView.activate() }
        if selectedTab != .recent {
            guard !model.isContentShielded, model.captureState.windowVisible,
                  let entry = selectedSavedEntry else { return false }
            if CapsuleRailActivationRules.action(for: entry.kind) == .revealInPlace {
                return revealCardPassword(entry)
            }
            guard let onActivateSaved else { return false }
            return onActivateSaved(entry)
        }
        let items = selectedFilteredItems
        guard !items.isEmpty,
              let onActivate,
              onActivate(items) else { return false }
        // The controller promotes only after exact-focus delivery or lossless
        // pasteboard restoration succeeds. Async activation must not advertise
        // a recency update before the requested item was actually used.
        return true
    }

    @discardableResult
    func copySelectedItems() -> Bool {
        if selectedTab == .captures { return capturesView.copy() }
        if selectedTab != .recent {
            guard let entry = selectedSavedEntry,
                  CapsuleRailActivationRules.allowsCopy(entry.kind),
                  let onCopySaved else { return false }
            return onCopySaved(entry)
        }
        let items = selectedFilteredItems
        guard !items.isEmpty, let onCopy else { return false }
        return onCopy(items)
    }

    @discardableResult
    func saveSelectedItems() -> Bool {
        if selectedTab == .captures { return capturesView.collect() }
        guard selectedTab == .recent, let onSaveHistory else { return false }
        let items = selectedFilteredItems
        guard !items.isEmpty else { return false }
        return onSaveHistory(items)
    }

    @discardableResult
    func deleteSelectedItems() -> Bool {
        if selectedTab == .captures { return capturesView.remove() }
        guard selectedTab == .recent else { return false }
        let items = selectedFilteredItems
        guard !items.isEmpty else { return false }
        selectionAnchorID = nil
        return model.delete(ids: items.map(\.id))
    }

    func reloadFromModel() {
        let protectedContent = model.isContentShielded
        if protectedContent || !model.captureState.windowVisible {
            concealCardPassword()
        }
        if protectedContent {
            clearThumbnailState()
            clearSavedThumbnailState()
        }
        applyAppearance()
        updateSearchPresentation()
        tabStrip.select(selectedTab)
        clearButton.isHidden = selectedTab != .recent
        createButton.isHidden = selectedTab.savedKind == nil
        capturesView.isHidden = selectedTab != .captures
        if selectedTab == .captures {
            removeAllCards(); removeAllSavedCards()
            stateContainer.isHidden = true; scrollView.isHidden = true
            capturesView.protected = protectedContent || !model.captureState.windowVisible
            capturesView.query = query
            countLabel.stringValue = "CAPTURES"
            return
        }
        clearButton.isHidden = selectedTab != .recent
        if let kind = selectedTab.savedKind {
            reloadSavedEntries(kind: kind, protectedContent: protectedContent)
            return
        }
        removeAllSavedCards()
        guard model.captureState.captureEnabled,
              model.captureState.windowVisible,
              !protectedContent else {
            removeAllCards()
            showState(message: stateMessage(), protectedContent: protectedContent)
            updateCount(visibleCount: 0)
            return
        }

        let matches = matchingItems
        let visibleItems = Array(matches.prefix(
            ClipboardHistoryWindowMetrics.maximumRenderedCards
        ))
        updateCount(visibleCount: matches.count)
        guard !visibleItems.isEmpty else {
            removeAllCards()
            showState(
                message: query.isEmpty ? "尚无剪贴板记录" : "没有匹配的记录",
                protectedContent: false
            )
            return
        }

        let visibleIDs = Set(visibleItems.map(\.id))
        let visibleSelectedIDs = model.selectedIDs.intersection(visibleIDs)
        let focusedIDIsVisible = model.selectedID.map(visibleIDs.contains) ?? false
        if visibleSelectedIDs.isEmpty {
            _ = model.select(id: visibleItems[0].id)
            selectionAnchorID = visibleItems[0].id
        } else if visibleSelectedIDs != model.selectedIDs || !focusedIDIsVisible {
            let orderedSelection = visibleItems.filter {
                visibleSelectedIDs.contains($0.id)
            }.map(\.id)
            _ = model.select(
                ids: orderedSelection,
                focusedID: orderedSelection.first
            )
        }
        stateContainer.isHidden = true
        scrollView.isHidden = false
        reconcileCards(items: visibleItems)
        needsLayout = true
        layoutSubtreeIfNeeded()
        if pointerDrivenSelectionDepth == 0 {
            scrollSelectedIntoView()
        }
        requestAssetsForVisibleCards()
    }

    /// Smoke-only: the rail's horizontal scroll offset, so a test can prove a
    /// click leaves the card where the pointer already is.
    var scrollOriginXForSmoke: CGFloat {
        scrollView.contentView.bounds.origin.x
    }

    /// The captures tab shares the Recent band. Hand-counted constants had
    /// it starting 27pt lower and ending 21pt inside the hint row, which is
    /// the blank line above every capture card.
    var capturesBandMatchesRecentForSmoke: Bool {
        layoutSubtreeIfNeeded()
        return capturesView.frame.equalTo(scrollView.frame)
    }

    func snapshotForSmoke() -> ClipboardHistoryPaneSnapshot {
        let buttons = cardDocumentView.cards
        let selectedBorder = buttons.first(where: { $0.itemID == model.selectedID })?
            .renderedBorderWidth
        return ClipboardHistoryPaneSnapshot(
            cardCount: buttons.count,
            selectedCardCount: buttons.filter(\.isRenderedSelected).count,
            renderedThumbnailCount: buttons.filter(\.isThumbnailRendered).count,
            selectedCardBorderWidth: selectedBorder,
            queryCharacterCount: query.count,
            searchCaretVisible: !searchCaret.isHidden,
            searchCaretX: searchCaret.frame.minX,
            stateIsVisible: !stateContainer.isHidden,
            contentIsProtected: model.isContentShielded,
            cardWidth: buttons.first?.frame.width ?? ClipboardHistoryWindowMetrics.cardWidth,
            cardHeight: buttons.first?.frame.height ?? ClipboardHistoryWindowMetrics.cardHeight
        )
    }

    func capsuleRailSnapshotForSmoke() -> CapsuleRailPaneSnapshot {
        CapsuleRailPaneSnapshot(
            tab: selectedTab,
            cardCount: cardDocumentView.cards.count,
            selectedEntryID: selectedSavedEntry?.id,
            editableCardCount: cardDocumentView.cards.filter(\.isEditable).count,
            inCapsuleCardCount: cardDocumentView.cards.filter(\.isMarkedInCapsule).count,
            hint: hintLabel.stringValue,
            stateMessage: stateContainer.isHidden ? nil : stateLabel.stringValue,
            clearButtonVisible: !clearButton.isHidden,
            countText: countLabel.stringValue
        )
    }

    func selectTab(_ tab: CapsuleRailTab) {
        setSearchFocused(false)
        guard tab != selectedTab else { return }
        concealCardPassword()
        selectedTab = tab
        if tab == .captures { capturesView.reload() }
        if let kind = tab.savedKind, library.state(for: kind) == .idle {
            library.reload()
        }
        updateHint()
        reloadFromModel()
    }

    @discardableResult
    func handleSavedCardInteraction(id: UUID, clickCount: Int) -> Bool {
        guard let kind = selectedTab.savedKind,
              visibleSavedEntryByID[id] != nil else { return false }
        pointerDrivenSelectionDepth += 1
        defer { pointerDrivenSelectionDepth -= 1 }
        if passwordCardID != id { concealCardPassword() }
        savedSelectedIDs[kind] = id
        if clickCount >= 2 { return activateSelectedItems() }
        reloadFromModel()
        return true
    }

    private var filteredSavedEntries: [CapsuleRailEntry] {
        guard let kind = selectedTab.savedKind else { return [] }
        return Array(CapsuleRailSearchRules.filter(
            library.entries(for: kind),
            query: query
        ).prefix(ClipboardHistoryWindowMetrics.maximumRenderedCards))
    }

    private var selectedSavedEntry: CapsuleRailEntry? {
        guard let kind = selectedTab.savedKind else { return nil }
        let entries = filteredSavedEntries
        return entries.first { $0.id == savedSelectedIDs[kind] } ?? entries.first
    }

    private func updateHint() {
        let activation = standaloneSearchEnabled ? "↩ PREPARE CLIPBOARD" : "↩ INSERT"
        switch selectedTab {
        case .captures:
            hintLabel.stringValue = "← → SELECT   ↩ EDIT   ⌘C COPY   ⌘S SAVE TO CAPSULE   DELETE REMOVE   ESC CLOSE"
        case .recent:
            hintLabel.stringValue = standaloneSearchEnabled
                ? "TYPE TO SEARCH   ← → SELECT   ⇥ NEXT TAB   ↩ PREPARE CLIPBOARD   ⌘C COPY   ⌘S SAVE TO CAPSULE   DELETE REMOVE   ESC CLOSE"
                : "TYPE TO SEARCH   ← → SELECT   ⇧←→ / ⌘CLICK MULTI   ⇥ NEXT TAB   ↩ INSERT   ⌘C COPY   ⌘S SAVE TO CAPSULE   DELETE REMOVE   ESC CLOSE"
        case .saved(.password):
            hintLabel.stringValue = "↩ VERIFY PASSWORD IN CARD   ·   15 秒自动隐藏   ·   ⋯ EDIT / MOVE / DELETE"
        case .saved:
            hintLabel.stringValue = "TYPE TO SEARCH   ← → SELECT   ⇥ NEXT TAB   \(activation)   ⌘C COPY   ESC CLOSE"
        }
    }

    /// Saved entries render with the history card, read-only: no deletion and
    /// no multi-selection, and only history capture settings never hide them.
    private func reloadSavedEntries(kind: CapsuleEntryKind,
                                    protectedContent: Bool) {
        removeAllCards()
        guard model.captureState.windowVisible, !protectedContent else {
            removeAllSavedCards()
            showState(message: savedStateMessage(), protectedContent: protectedContent)
            countLabel.stringValue = ""
            return
        }
        let all = library.entries(for: kind)
        let matches = CapsuleRailSearchRules.filter(all, query: query)
        let visible = Array(matches.prefix(
            ClipboardHistoryWindowMetrics.maximumRenderedCards
        ))
        countLabel.stringValue = query.isEmpty
            ? CapsuleRailCountText.items(all.count)
            : "\(matches.count) / \(all.count)"
        guard !visible.isEmpty else {
            removeAllSavedCards()
            let message: String
            switch library.state(for: kind) {
            case .idle, .loading: message = "正在读取 Capsule"
            case .failed: message = "无法读取 Capsule"
            case .loaded: message = query.isEmpty ? "还没有\(kind.tabLabel)" : "没有匹配的条目"
            }
            showState(message: message, protectedContent: false)
            return
        }
        if !visible.contains(where: { $0.id == savedSelectedIDs[kind] }) {
            savedSelectedIDs[kind] = visible[0].id
        }
        stateContainer.isHidden = true
        scrollView.isHidden = false
        reconcileSavedCards(visible, selectedID: savedSelectedIDs[kind])
        needsLayout = true
        layoutSubtreeIfNeeded()
        if pointerDrivenSelectionDepth == 0 {
            scrollSelectedIntoView()
        }
        requestSavedThumbnailsForVisibleCards()
    }

    private func savedStateMessage() -> String {
        let protection = model.activeProtection
        if protection.contains(.secureInput) { return "安全输入期间已隐藏内容" }
        if protection.contains(.screenLocked) { return "屏幕锁定期间已隐藏内容" }
        if protection.contains(.sessionInactive) { return "当前会话已保护" }
        return "Capsule 已收起"
    }

    private func reconcileSavedCards(_ entries: [CapsuleRailEntry],
                                     selectedID: UUID?) {
        let validIDs = Set(entries.map(\.id))
        visibleSavedEntryByID = Dictionary(
            entries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in savedCardButtons.keys where !validIDs.contains(id) {
            if passwordCardID == id { concealCardPassword() }
            savedCardButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        let ordered = entries.enumerated().map { index, entry -> ClipboardHistoryCardButton in
            let button = savedCardButtons[entry.id]
                ?? ClipboardHistoryCardButton(itemID: entry.id)
            button.target = self
            button.action = #selector(savedCardPressed(_:))
            let id = entry.id
            button.makeActionsMenu = { [weak self] in
                self?.savedActionsMenu(id: id)
            }
            savedCardButtons[entry.id] = button
            button.update(
                entry: entry,
                quickIndex: index < 9 ? index + 1 : nil,
                thumbnail: savedThumbnailCache.object(forKey: entry.id as NSUUID),
                selected: entry.id == selectedID
            )
            return button
        }
        cardDocumentView.setCards(ordered, viewportWidth: scrollView.contentSize.width)
    }

    private func removeAllSavedCards() {
        concealCardPassword()
        guard !savedCardButtons.isEmpty else { return }
        savedCardButtons.values.forEach { $0.removeFromSuperview() }
        savedCardButtons.removeAll(keepingCapacity: false)
        visibleSavedEntryByID.removeAll(keepingCapacity: false)
        cardDocumentView.setCards([], viewportWidth: scrollView.contentSize.width)
    }

    private func requestSavedThumbnailsForVisibleCards() {
        guard !scrollView.isHidden, !model.isContentShielded else { return }
        let prefetch = scrollView.documentVisibleRect.insetBy(
            dx: -ClipboardHistoryWindowMetrics.cardWidth,
            dy: 0
        )
        for card in cardDocumentView.cards where card.frame.intersects(prefetch) {
            guard let entry = visibleSavedEntryByID[card.itemID],
                  entry.kind == .image || entry.kind == .pdf || entry.kind == .video,
                  let path = entry.payload,
                  savedThumbnailCache.object(forKey: entry.id as NSUUID) == nil,
                  savedThumbnailOperations[entry.id] == nil else { continue }
            let id = entry.id
            let generation = assetGeneration
            savedThumbnailOperations[id] = CapsuleMediaPreviewLoader.shared.load(
                kind: entry.kind,
                path: path
            ) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.savedThumbnailOperations[id] = nil
                    guard generation == self.assetGeneration,
                          !self.model.isContentShielded else { return }
                    let image: CGImage
                    switch result {
                    case let .image(cgImage): image = cgImage
                    case let .pdf(image: cgImage, pageCount: _): image = cgImage
                    case .unavailable: return
                    }
                    let rendered = NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    )
                    self.savedThumbnailCache.setObject(
                        rendered,
                        forKey: id as NSUUID,
                        cost: max(1, image.bytesPerRow * image.height)
                    )
                    self.savedCardButtons[id]?.setThumbnail(rendered)
                }
            }
        }
    }

    private func clearSavedThumbnailState() {
        savedThumbnailOperations.values.forEach { $0.cancel() }
        savedThumbnailOperations.removeAll(keepingCapacity: false)
        savedThumbnailCache.removeAllObjects()
    }

    private func editHistoryItem(id: UUID) {
        guard let item = visibleItemByID[id], let onEditHistory else { return }
        onEditHistory(item)
    }

    private func editSavedEntry(id: UUID) {
        concealCardPassword()
        guard let entry = visibleSavedEntryByID[id], let onEditSaved else { return }
        onEditSaved(entry)
    }

    func concealCardPassword() {
        let card = passwordCard
        passwordCard = nil
        if let id = passwordCardID { savedCardButtons[id]?.passwordContent = nil }
        passwordCardID = nil
        card?.onConceal = nil
        card?.conceal()
        card?.removeFromSuperview()
    }

    private func revealCardPassword(_ entry: CapsuleRailEntry) -> Bool {
        guard let button = savedCardButtons[entry.id],
              onRequestPasswordInput?() == true else { return false }
        concealCardPassword()
        let card = CapsuleCardPasswordView(store: passcodeStore, readSecret: { [library] in
            try library.readPassword(entry)
        }, presentationAllowed: { [weak self] in
            guard let self else { return false }
            return !self.model.isContentShielded && self.model.captureState.windowVisible
                && self.selectedSavedEntry == entry && self.passwordCardID == entry.id
                && self.window?.isVisible == true
        })
        card.onConceal = { [weak self] in self?.concealCardPassword() }
        passwordCardID = entry.id
        passwordCard = card
        button.passwordContent = card
        card.focus()
        return true
    }

    private func savedActionsMenu(id: UUID) -> NSMenu? {
        guard !model.isContentShielded, model.captureState.windowVisible,
              let entry = visibleSavedEntryByID[id] else { return nil }
        concealCardPassword()
        return CapsuleCardMenu.make([
            ("编辑", true, { [weak self] in self?.editSavedEntry(id: id) }),
            (entry.kind == .note ? "迁移为密码…" : "迁移（已在对应分类）", entry.kind == .note,
             { [weak self] in self?.onMigrateSaved?(entry) }),
            ("删除…", true, { [weak self] in self?.onDeleteSaved?(entry) }),
        ])
    }

    private func historyActionsMenu(id: UUID) -> NSMenu? {
        guard !model.isContentShielded, model.captureState.windowVisible,
              let item = visibleItemByID[id] else { return nil }
        let saveable = CapsuleRailSaveRules.isSaveable(item.kind)
        let destination = item.kind == .image ? "图片" : (item.kind == .files ? "对应文件分类" : "笔记")
        return CapsuleCardMenu.make([
            ("编辑", saveable, { [weak self] in self?.editHistoryItem(id: id) }),
            ("迁移到\(destination)", saveable, { [weak self] in self?.onMigrateHistory?(item) }),
            ("删除", true, { [weak self] in
                guard let self, !self.model.isContentShielded,
                      self.model.captureState.windowVisible else { return }
                _ = self.model.delete(ids: [id])
            }),
        ])
    }

    @objc private func savedCardPressed(_ sender: ClipboardHistoryCardButton) {
        setSearchFocused(false)
        _ = handleSavedCardInteraction(
            id: sender.itemID,
            clickCount: sender.actionContext.clickCount
        )
    }

    @objc private func capturePressed() { CaptureCoordinator.shared.showLauncher() }

    @objc private func managePressed() { onManage?() }
    @objc private func createPressed() {
        guard !model.isContentShielded, model.captureState.windowVisible,
              let kind = selectedTab.savedKind else { return }
        concealCardPassword()
        onCreateSaved?(kind)
    }

    /// Preview-only: shows the hover state of the card at `index`.
    func hoverCardForPreview(at index: Int) {
        guard cardDocumentView.cards.indices.contains(index) else { return }
        cardDocumentView.cards[index].setHoveredForPreview(true)
    }

    private var matchingItems: [ClipboardHistoryItem] {
        ClipboardHistorySearchRules.filter(model.visibleItems, query: query)
    }

    private var filteredItems: [ClipboardHistoryItem] {
        Array(matchingItems.prefix(ClipboardHistoryWindowMetrics.maximumRenderedCards))
    }

    private var selectedFilteredItems: [ClipboardHistoryItem] {
        let items = filteredItems
        let selected = items.filter { model.selectedIDs.contains($0.id) }
        if !selected.isEmpty { return selected }
        return items.first.map { [$0] } ?? []
    }

    private func configureView() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capsule")
        setAccessibilityHelp("输入以搜索；Tab 切换类型；左右键选择；回车上屏；Command-C 复制；Delete 删除；Escape 关闭")

        titleLabel.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        searchShell.wantsLayer = true
        searchShell.layer?.cornerRadius = 8
        searchShell.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = RimeUI.symbol("magnifyingglass", pointSize: 12, weight: .semibold)
        searchIcon.image?.isTemplate = true
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchLabel.font = .systemFont(ofSize: 12)
        searchLabel.lineBreakMode = .byTruncatingTail
        searchLabel.translatesAutoresizingMaskIntoConstraints = false
        standaloneSearchField.font = .systemFont(ofSize: 12)
        standaloneSearchField.placeholderString = "输入以搜索"
        standaloneSearchField.isBordered = false
        standaloneSearchField.isBezeled = false
        standaloneSearchField.drawsBackground = false
        standaloneSearchField.focusRingType = .none
        standaloneSearchField.usesSingleLineMode = true
        standaloneSearchField.delegate = self
        standaloneSearchField.isHidden = true
        standaloneSearchField.translatesAutoresizingMaskIntoConstraints = false
        searchCaret.wantsLayer = true
        searchCaret.layer?.cornerRadius = 1
        searchCaret.isHidden = true
        searchShell.addSubview(searchIcon)
        searchShell.addSubview(searchLabel)
        searchShell.addSubview(searchCaret)
        searchShell.addSubview(standaloneSearchField)
        NSLayoutConstraint.activate([
            searchShell.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            searchShell.heightAnchor.constraint(equalToConstant: 28),
            searchIcon.leadingAnchor.constraint(equalTo: searchShell.leadingAnchor, constant: 9),
            searchIcon.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),
            searchLabel.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 7),
            searchLabel.trailingAnchor.constraint(equalTo: searchShell.trailingAnchor, constant: -9),
            searchLabel.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            standaloneSearchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 3),
            standaloneSearchField.trailingAnchor.constraint(equalTo: searchShell.trailingAnchor, constant: -5),
            standaloneSearchField.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            standaloneSearchField.heightAnchor.constraint(equalToConstant: 22),
        ])
        // The tabs share the header, so the search box gives way first on a
        // narrow screen.
        let preferredSearchWidth = searchShell.widthAnchor.constraint(equalToConstant: 250)
        preferredSearchWidth.priority = .defaultHigh
        preferredSearchWidth.isActive = true

        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.setAccessibilityLabel("清空全部本地剪贴板历史")
        closeButton.image = RimeUI.symbol("xmark", pointSize: Self.headerGlyphPointSize,
                                          weight: Self.headerGlyphWeight)
        closeButton.image?.isTemplate = true
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("关闭 Capsule")
        tabStrip.onSelect = { [weak self] tab in
            MainActor.assumeIsolated { self?.selectTab(tab) }
        }
        manageButton.image = RimeUI.symbol("gearshape", pointSize: Self.headerGlyphPointSize,
                                           weight: Self.headerGlyphWeight)
        manageButton.image?.isTemplate = true
        manageButton.imagePosition = .imageOnly
        manageButton.isBordered = false
        manageButton.target = self
        manageButton.action = #selector(managePressed)
        manageButton.toolTip = "Capsule 管理"
        manageButton.setAccessibilityLabel("打开 Capsule 管理")

        captureButton.image = RimeUI.symbol("camera", pointSize: Self.headerGlyphPointSize,
                                            weight: Self.headerGlyphWeight)
        captureButton.image?.isTemplate = true
        captureButton.imagePosition = .imageOnly
        captureButton.target = self; captureButton.action = #selector(capturePressed)
        captureButton.isBordered = false
        captureButton.toolTip = "捕获屏幕"
        captureButton.setAccessibilityLabel("捕获屏幕")
        // The three header glyphs were drawn at 11/12/14pt in three weights
        // and had no frame of their own, so the camera sat larger than its
        // neighbours and the glyph box changed shape between display scales.
        // One size, one weight, one square each.
        createButton.image = RimeUI.symbol("plus", pointSize: Self.headerGlyphPointSize, weight: Self.headerGlyphWeight)
        createButton.image?.isTemplate = true
        createButton.imagePosition = .imageOnly
        createButton.isBordered = false
        createButton.target = self
        createButton.action = #selector(createPressed)
        createButton.toolTip = "新建当前分类内容"
        createButton.setAccessibilityLabel("新建 Capsule 内容")
        for button in [captureButton, createButton, manageButton, closeButton] {
            button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.headerGlyphBox),
                button.heightAnchor.constraint(equalToConstant: Self.headerGlyphBox),
            ])
        }
        let headerSpacer = NSView()
        let header = NSStackView(views: [
            titleLabel, countLabel, tabStrip, headerSpacer, searchShell,
            clearButton, captureButton, createButton, manageButton, closeButton,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = cardDocumentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capturesView)
        capturesView.isHidden = true; capturesView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.concealCardPassword()
                self?.requestAssetsForVisibleCards()
            }
        }

        stateIcon.imageScaling = .scaleProportionallyDown
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        let stateStack = NSStackView(views: [stateIcon, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 8
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stateStack)
        stateContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 16),
            stateIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        hintLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        hintLabel.identifier = NSUserInterfaceItemIdentifier("capsule-rail-hint")
        updateHint()
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(scrollView)
        addSubview(stateContainer)
        addSubview(hintLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ClipboardHistoryWindowMetrics.horizontalInset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ClipboardHistoryWindowMetrics.horizontalInset),
            header.topAnchor.constraint(equalTo: topAnchor, constant: ClipboardHistoryWindowMetrics.verticalInset),
            header.heightAnchor.constraint(equalToConstant: 30),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ClipboardHistoryWindowMetrics.horizontalInset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ClipboardHistoryWindowMetrics.horizontalInset),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            scrollView.heightAnchor.constraint(equalToConstant: ClipboardHistoryWindowMetrics.cardHeight),
            stateContainer.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stateContainer.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stateContainer.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            // The captures tab occupies the same band as Recent, so it is
            // pinned to that scroll view rather than to hand-counted numbers.
            // Those constants said 78pt from the top and 128pt tall while the
            // real band starts at 51 and is 126: an empty 27pt line above
            // every card, and a bottom edge running 21pt into the hint row.
            capturesView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            capturesView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            capturesView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            capturesView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
    }

    /// The caret belongs to the borrowed-Rime surface only. In standalone
    /// mode a real NSTextField is visible and AppKit draws its own.
    private var searchIsLive: Bool {
        !standaloneSearchEnabled && window != nil && searchFocused
    }

    func setSearchFocused(_ focused: Bool) {
        if focused { concealCardPassword() }
        guard focused != searchFocused else { return }
        searchFocused = focused
        refreshSearchCaret()
        applyAppearance()
    }

    /// Places the caret and restarts its blink. Called on every keystroke so
    /// the caret is solid while typing, the way a real field behaves.
    private func refreshSearchCaret(resetBlink: Bool = true) {
        guard searchIsLive else {
            searchCaret.isHidden = true
            caretBlink?.invalidate()
            caretBlink = nil
            return
        }
        let labelRect = searchLabel.frame
        let height = ceil((searchLabel.font ?? NSFont.systemFont(ofSize: 12)).ascender
            - (searchLabel.font ?? NSFont.systemFont(ofSize: 12)).descender) + 2
        searchCaret.frame = NSRect(
            x: caretX(in: labelRect),
            y: labelRect.midY - height / 2,
            width: 1.5,
            height: height
        )
        guard resetBlink else { return }
        searchCaret.isHidden = false
        caretBlink?.invalidate()
        // Match the system insertion point cadence.
        let period = UserDefaults.standard.object(
            forKey: "NSTextInsertionPointBlinkPeriodOn"
        ) as? Double
        let timer = Timer(
            timeInterval: (period.map { $0 / 1000 } ?? 0.53),
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.searchIsLive else { return }
                self.searchCaret.isHidden.toggle()
            }
        }
        caretBlink = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Ordering the panel out does not move the view between windows, so
    /// `viewDidMoveToWindow` never fires and the blink would tick forever in
    /// a resident input method. The controller parks it instead.
    func setSearchCaretActive(_ active: Bool) {
        if active {
            refreshSearchCaret()
        } else {
            caretBlink?.invalidate()
            caretBlink = nil
            searchCaret.isHidden = true
        }
    }

    /// Preview capture is a still frame, and the caret blinks. Force it on so
    /// a rendered preview shows the same focused search box the user sees.
    func showSearchCaretForCapture() {
        setSearchFocused(true)
        refreshSearchCaret()
        searchCaret.isHidden = !searchIsLive
    }

    private func updateSearchPresentation() {
        standaloneSearchField.textColor = RimeUI.textPrimary
        if standaloneSearchEnabled {
            searchShell.setAccessibilityLabel("Capsule 搜索")
            return
        }
        if query.isEmpty && composingText.isEmpty {
            searchLabel.stringValue = "直接输入以搜索"
            searchLabel.textColor = RimeUI.textMuted
            searchShell.setAccessibilityLabel("搜索 Capsule；直接输入")
        } else {
            let rendered = NSMutableAttributedString(
                string: query,
                attributes: [
                    .foregroundColor: RimeUI.textPrimary,
                    .font: searchLabel.font ?? NSFont.systemFont(ofSize: 12),
                ]
            )
            if !composingText.isEmpty {
                rendered.append(NSAttributedString(
                    string: composingText,
                    attributes: [
                        .foregroundColor: RimeUI.accentTextColor,
                        .font: searchLabel.font ?? NSFont.systemFont(ofSize: 12),
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                ))
            }
            searchLabel.attributedStringValue = rendered
            searchShell.setAccessibilityLabel("Capsule 搜索")
        }
        searchLabel.layoutSubtreeIfNeeded()
        refreshSearchCaret()
    }

    private func updateCount(visibleCount: Int) {
        countLabel.stringValue = query.isEmpty
            ? CapsuleRailCountText.items(model.itemCount)
            : "\(visibleCount) / \(model.itemCount)"
    }

    private func reconcileCards(items: [ClipboardHistoryItem]) {
        let validIDs = Set(items.map(\.id))
        visibleItemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for id in cardButtons.keys.filter({ !validIDs.contains($0) }) {
            cardButtons.removeValue(forKey: id)?.removeFromSuperview()
        }
        let ordered = items.enumerated().map { index, item -> ClipboardHistoryCardButton in
            let button = cardButtons[item.id] ?? ClipboardHistoryCardButton(itemID: item.id)
            button.target = self
            button.action = #selector(cardPressed(_:))
            cardButtons[item.id] = button
            button.update(
                item: item,
                quickIndex: index < 9 ? index + 1 : nil,
                sourceIcon: item.sourceApplicationBundleIdentifier.flatMap {
                    sourceIconCache.object(forKey: $0 as NSString)
                } ?? fallbackSourceIcon,
                thumbnail: thumbnailCache.object(forKey: item.id as NSUUID),
                selected: model.selectedIDs.contains(item.id),
                focused: item.id == model.selectedID,
                editable: CapsuleRailSaveRules.isSaveable(item.kind),
                inCapsule: library.isInCapsule(
                    historyItemID: item.id,
                    text: item.textCompleteness == .complete ? item.canonicalText : nil
                )
            )
            let id = item.id
            button.makeActionsMenu = { [weak self] in
                self?.historyActionsMenu(id: id)
            }
            return button
        }
        cardDocumentView.setCards(ordered, viewportWidth: scrollView.contentSize.width)
    }

    private func removeAllCards() {
        cardButtons.values.forEach { $0.removeFromSuperview() }
        cardButtons.removeAll(keepingCapacity: false)
        visibleItemByID.removeAll(keepingCapacity: false)
        cardDocumentView.setCards([], viewportWidth: scrollView.contentSize.width)
        scrollView.isHidden = true
    }

    private func showState(message: String, protectedContent: Bool) {
        stateLabel.stringValue = message
        stateLabel.textColor = protectedContent
            ? ClipboardHistoryPalette.warningText
            : RimeUI.textMuted
        stateIcon.image = RimeUI.symbol(
            protectedContent ? "lock.fill" : "clipboard",
            pointSize: 15,
            weight: .bold
        )
        stateIcon.image?.isTemplate = true
        stateIcon.contentTintColor = stateLabel.textColor
        stateContainer.isHidden = false
        scrollView.isHidden = true
        setAccessibilityHelp(message)
    }

    private func stateMessage() -> String {
        let protection = model.activeProtection
        if protection.contains(.secureInput) { return "安全输入期间已隐藏历史" }
        if protection.contains(.screenLocked) { return "屏幕锁定期间已隐藏历史" }
        if protection.contains(.sessionInactive) { return "当前会话已保护" }
        if !model.captureState.captureEnabled { return "剪贴板历史收录已关闭" }
        if !model.captureState.windowVisible { return "Capsule 已收起" }
        if !model.isStarted { return "剪贴板历史尚未启动" }
        return "尚无剪贴板记录"
    }

    private func moveFilteredSelection(delta: Int, extending: Bool) {
        if let kind = selectedTab.savedKind {
            let entries = filteredSavedEntries
            guard !entries.isEmpty else { return }
            let current = entries.firstIndex { $0.id == savedSelectedIDs[kind] } ?? 0
            let next = min(max(0, current + delta), entries.count - 1)
            savedSelectedIDs[kind] = entries[next].id
            reloadFromModel()
            return
        }
        let items = filteredItems
        guard !items.isEmpty else { return }
        let current = model.selectedID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        } ?? 0
        let next = min(max(0, current + delta), items.count - 1)
        let nextID = items[next].id
        if extending {
            let anchorID: UUID
            if let selectionAnchorID,
               model.selectedIDs.contains(selectionAnchorID),
               items.contains(where: { $0.id == selectionAnchorID }) {
                anchorID = selectionAnchorID
            } else {
                anchorID = items[current].id
                selectionAnchorID = anchorID
            }
            let anchor = items.firstIndex(where: { $0.id == anchorID }) ?? current
            let range = min(anchor, next)...max(anchor, next)
            _ = model.select(
                ids: range.map { items[$0].id },
                focusedID: nextID
            )
        } else {
            selectionAnchorID = nextID
            _ = model.select(id: nextID)
        }
        scrollSelectedIntoView()
    }

    @discardableResult
    private func activateVisibleItem(at index: Int) -> Bool {
        if let kind = selectedTab.savedKind {
            let entries = filteredSavedEntries
            guard entries.indices.contains(index) else { return false }
            savedSelectedIDs[kind] = entries[index].id
            return activateSelectedItems()
        }
        let items = filteredItems
        guard items.indices.contains(index), model.select(id: items[index].id) else {
            return false
        }
        selectionAnchorID = items[index].id
        return activateSelectedItems()
    }

    private func scrollSelectedIntoView() {
        let selectedCard: ClipboardHistoryCardButton?
        if let kind = selectedTab.savedKind {
            selectedCard = savedSelectedIDs[kind].flatMap { savedCardButtons[$0] }
        } else {
            selectedCard = model.selectedID.flatMap { cardButtons[$0] }
        }
        guard let card = selectedCard, !scrollView.isHidden else { return }
        let visible = scrollView.documentVisibleRect
        let targetX: CGFloat
        if card.frame.minX < visible.minX {
            targetX = card.frame.minX
        } else if card.frame.maxX > visible.maxX {
            targetX = card.frame.maxX - visible.width
        } else { return }
        let maximumX = max(0, cardDocumentView.frame.width - visible.width)
        let target = NSPoint(x: min(max(0, targetX), maximumX), y: 0)
        if window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(target)
        }
    }

    override func mouseDown(with event: NSEvent) {
        concealCardPassword()
        let point = convert(event.locationInWindow, from: nil)
        setSearchFocused(searchShell.frame.contains(point))
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A repeating timer on a hidden rail keeps the process awake for
        // nothing, so the blink lives exactly as long as the window does.
        if window == nil {
            concealCardPassword()
            caretBlink?.invalidate()
            caretBlink = nil
            searchCaret.isHidden = true
        } else {
            refreshSearchCaret()
            applyAppearance()
        }
    }

    override func layout() {
        super.layout()
        refreshSearchCaret(resetBlink: false)
    }

    private func applyAppearance() {
        appearance = RimeUI.appKitAppearance
        layer?.backgroundColor = RimeUI.workbenchChrome.cgColor
        searchShell.layer?.backgroundColor = RimeUI.surface2.cgColor
        searchShell.layer?.borderWidth = 1
        searchCaret.layer?.backgroundColor = RimeUI.accentTextColor.cgColor
        // The rail routes every plain keystroke to the search box while it is
        // open, so the box is always the focused surface. Say so.
        searchShell.layer?.borderColor = searchIsLive
            ? RimeUI.accentTextColor.withAlphaComponent(0.55).cgColor
            : RimeUI.borderStrong.cgColor
        titleLabel.textColor = RimeUI.textPrimary
        countLabel.textColor = RimeUI.textMuted
        searchIcon.contentTintColor = RimeUI.textMuted
        hintLabel.textColor = RimeUI.textMuted
        clearButton.contentTintColor = RimeUI.textSecondary
        closeButton.contentTintColor = RimeUI.textSecondary
        manageButton.contentTintColor = RimeUI.textSecondary
        tabStrip.applyAppearance()
        cardButtons.values.forEach { $0.refreshAppearance() }
        savedCardButtons.values.forEach { $0.refreshAppearance() }
    }

    private func requestAssetsForVisibleCards() {
        if selectedTab != .recent {
            requestSavedThumbnailsForVisibleCards()
            return
        }
        guard !scrollView.isHidden, !model.isContentShielded else { return }
        let prefetch = scrollView.documentVisibleRect.insetBy(
            dx: -ClipboardHistoryWindowMetrics.cardWidth,
            dy: 0
        )
        for card in cardDocumentView.cards where card.frame.intersects(prefetch) {
            guard let item = visibleItemByID[card.itemID] else { continue }
            requestSourceIconIfNeeded(for: item)
            requestThumbnailIfNeeded(for: item)
        }
    }

    private func requestThumbnailIfNeeded(for item: ClipboardHistoryItem) {
        guard item.kind.allowsImageThumbnail,
              thumbnailCache.object(forKey: item.id as NSUUID) == nil,
              requestedThumbnailIDs.insert(item.id).inserted else { return }
        let generation = assetGeneration
        model.loadImageThumbnail(
            id: item.id,
            maximumPixelSize: ClipboardHistoryWindowMetrics.previewMaximumPixelSize
        ) { [weak self] image in
            guard let self else { return }
            self.requestedThumbnailIDs.remove(item.id)
            guard generation == self.assetGeneration,
                  !self.model.isContentShielded,
                  let image else { return }
            let rendered = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            self.thumbnailCache.setObject(
                rendered,
                forKey: item.id as NSUUID,
                cost: max(1, image.bytesPerRow * image.height)
            )
            self.cardButtons[item.id]?.setThumbnail(rendered)
        }
    }

    private func requestSourceIconIfNeeded(for item: ClipboardHistoryItem) {
        guard let bundleIdentifier = item.sourceApplicationBundleIdentifier,
              !bundleIdentifier.isEmpty,
              sourceIconCache.object(forKey: bundleIdentifier as NSString) == nil,
              requestedSourceIconBundleIDs.insert(bundleIdentifier).inserted else {
            return
        }
        model.loadSourceApplicationIcon(
            bundleIdentifier: bundleIdentifier
        ) { [weak self] data in
            guard let self else { return }
            self.requestedSourceIconBundleIDs.remove(bundleIdentifier)
            let image = data.flatMap { NSImage(data: $0) }
                ?? self.workspaceIcon(bundleIdentifier: bundleIdentifier)
                ?? self.fallbackSourceIcon
            guard let image else { return }
            let cached = (image.copy() as? NSImage) ?? image
            cached.size = NSSize(width: 16, height: 16)
            self.sourceIconCache.setObject(
                cached,
                forKey: bundleIdentifier as NSString
            )
            for (id, visibleItem) in self.visibleItemByID
                where visibleItem.sourceApplicationBundleIdentifier
                    == bundleIdentifier {
                self.cardButtons[id]?.setSourceIcon(cached)
            }
        }
    }

    private func workspaceIcon(bundleIdentifier: String) -> NSImage? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private func clearThumbnailState() {
        assetGeneration &+= 1
        thumbnailCache.removeAllObjects()
        requestedThumbnailIDs.removeAll(keepingCapacity: false)
    }

    /// Selecting a card notifies the model synchronously, which reloads this
    /// pane. A reload normally scrolls the selection into view — correct for
    /// keyboard and search, wrong for a click: the rail would slide the card
    /// out from under the pointer, so the second click of a double click lands
    /// on a different card and the first click reads as having selected
    /// something else. Clicks therefore hold the rail still.
    @discardableResult
    func handleCardInteraction(
        itemID: UUID,
        modifiers rawModifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) -> Bool {
        pointerDrivenSelectionDepth += 1
        defer { pointerDrivenSelectionDepth -= 1 }
        let modifiers = rawModifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        if clickCount >= 2 {
            guard model.select(id: itemID) else { return false }
            selectionAnchorID = itemID
            return activateSelectedItems()
        }
        if modifiers == [.command] {
            guard model.toggleSelection(id: itemID) else { return false }
            selectionAnchorID = itemID
        } else if modifiers == [.shift],
                  let anchorID = selectionAnchorID,
                  model.selectedIDs.contains(anchorID),
                  let anchor = filteredItems.firstIndex(where: {
                      $0.id == anchorID
                  }),
                  let clicked = filteredItems.firstIndex(where: {
                      $0.id == itemID
                  }) {
            let range = min(anchor, clicked)...max(anchor, clicked)
            _ = model.select(
                ids: range.map { filteredItems[$0].id },
                focusedID: itemID
            )
        } else {
            guard model.select(id: itemID) else { return false }
            selectionAnchorID = itemID
        }
        return true
    }

    @objc private func cardPressed(_ sender: ClipboardHistoryCardButton) {
        setSearchFocused(false)
        let actionContext = sender.actionContext
        _ = handleCardInteraction(
            itemID: sender.itemID,
            modifiers: actionContext.modifiers,
            clickCount: actionContext.clickCount
        )
    }

    @objc private func clearPressed() {
        guard model.activeProtection.isEmpty else { return }
        guard clearConfirmationArmed else {
            clearConfirmationArmed = true
            clearConfirmationGeneration &+= 1
            let generation = clearConfirmationGeneration
            clearButton.title = "再次点击清空"
            clearButton.setAccessibilityHelp("再次点击将删除全部本地历史")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self,
                      self.clearConfirmationGeneration == generation else {
                    return
                }
                self.resetClearConfirmation()
            }
            return
        }
        resetClearConfirmation()
        model.clear()
    }

    private func resetClearConfirmation() {
        clearConfirmationGeneration &+= 1
        clearConfirmationArmed = false
        clearButton.title = "清空"
        clearButton.setAccessibilityHelp("需要连续确认两次")
    }

    @objc private func closePressed() { onClose?() }

    private static func commandDigitIndex(keyCode: UInt16) -> Int? {
        [
            UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
            UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
            UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
        ].firstIndex(of: keyCode)
    }
}

private enum ClipboardHistoryPalette {
    static var selectedBackground: NSColor {
        RimeUI.clipboardSelectedBackground
    }

    static var warningText: NSColor {
        RimeUI.warningTextColor
    }
}

private final class ClipboardHistoryCardDocumentView: NSView {
    private(set) var cards: [ClipboardHistoryCardButton] = []
    override var isFlipped: Bool { true }

    func setCards(_ cards: [ClipboardHistoryCardButton], viewportWidth: CGFloat) {
        self.cards = cards
        cards.filter { $0.superview !== self }.forEach(addSubview)
        layoutCards(viewportWidth: viewportWidth)
    }

    func layoutCards(viewportWidth: CGFloat) {
        var x: CGFloat = 0
        for card in cards {
            card.frame = NSRect(
                x: x,
                y: 0,
                width: ClipboardHistoryWindowMetrics.cardWidth,
                height: ClipboardHistoryWindowMetrics.cardHeight
            )
            x += ClipboardHistoryWindowMetrics.cardWidth
                + ClipboardHistoryWindowMetrics.cardSpacing
        }
        let contentWidth = cards.isEmpty ? 0 : x - ClipboardHistoryWindowMetrics.cardSpacing
        frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewportWidth, contentWidth),
            height: ClipboardHistoryWindowMetrics.cardHeight
        )
    }
}

private final class ClipboardHistoryHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = ClipboardHistoryScrollRules.horizontalDelta(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            shiftHeld: event.modifierFlags.contains(.shift)
        )
        guard abs(delta) > 0.01, let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let maximumX = max(0, documentView.frame.width - contentSize.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x + delta), maximumX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

private final class ClipboardHistoryCardButton: NSButton {
    let itemID: UUID
    private let quickLabel = NSTextField(labelWithString: "")
    private let sourceIconView = NSImageView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let previewImageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var selectedItem = false
    private var focusedItem = false
    private var itemKind: ClipboardItemKind = .unknown
    private(set) var actionContext = ClipboardHistoryCardActionContext.keyboard
    private(set) var renderedBorderWidth: CGFloat = 1
    /// Persistent upper-right menu shared by recent and saved cards.
    var makeActionsMenu: (() -> NSMenu?)?
    var passwordContent: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let passwordContent { addSubview(passwordContent) }
            needsLayout = true
        }
    }
    private let editButton = ClipboardFirstMouseButton(title: "", target: nil, action: nil)
    private let savedMarker = NSImageView()
    private var editable = false
    private var inCapsule = false
    var isMarkedInCapsule: Bool { inCapsule }
    private var allowsThumbnail = false
    private var savedTitle: String?
    private var savedPreview: String?
    var isEditable: Bool { editable }
    var isRenderedSelected: Bool { selectedItem }
    var isThumbnailRendered: Bool {
        previewImageView.image != nil && !previewImageView.isHidden
    }

    init(itemID: UUID) {
        self.itemID = itemID
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        quickLabel.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        quickLabel.alignment = .center
        sourceLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceIconView.imageScaling = .scaleProportionallyDown
        sourceIconView.isHidden = true
        timeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        timeLabel.alignment = .right
        previewLabel.font = .systemFont(ofSize: 12)
        previewLabel.maximumNumberOfLines = 4
        previewLabel.lineBreakMode = .byWordWrapping
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 7
        previewImageView.layer?.masksToBounds = true
        previewImageView.isHidden = true
        [quickLabel, sourceIconView, sourceLabel, timeLabel,
         previewLabel, previewImageView].forEach {
            $0.setAccessibilityElement(false)
            addSubview($0)
        }
        editButton.image = RimeUI.symbol("ellipsis", pointSize: 12, weight: .semibold)
        editButton.image?.isTemplate = true
        editButton.imagePosition = .imageOnly
        editButton.isBordered = false
        editButton.wantsLayer = true
        editButton.layer?.cornerRadius = 6
        editButton.target = self
        editButton.action = #selector(editPressed)
        editButton.toolTip = "更多操作"
        editButton.setAccessibilityLabel("更多操作：编辑、迁移、删除")
        editButton.isHidden = true
        addSubview(editButton)
        savedMarker.image = RimeUI.symbol("capsule.fill", pointSize: 8, weight: .semibold)
        savedMarker.image?.isTemplate = true
        savedMarker.imageScaling = .scaleNone
        savedMarker.toolTip = "已收入 Capsule"
        savedMarker.setAccessibilityElement(false)
        savedMarker.isHidden = true
        addSubview(savedMarker)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The preview label alone covers most of the card, and a plain
    /// NSTextField consumes the click that lands on it rather than passing it
    /// up. Answer as one control so a click anywhere on the card selects it,
    /// and so the second click of a double click still reaches this button
    /// with clickCount 2 instead of being counted against a subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        if !editButton.isHidden, editButton.frame.contains(local) {
            return editButton
        }
        if let passwordContent, passwordContent.frame.contains(local) {
            return passwordContent.hitTest(local)
        }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // NSButton sends its target/action synchronously while super is tracking
        // this press. Freeze the originating event here instead of consulting
        // NSApp.currentEvent later, where another event may already be current.
        actionContext = ClipboardHistoryCardActionContext(event: event)
        defer { actionContext = .keyboard }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        quickLabel.frame = NSRect(x: 10, y: 9, width: 28, height: 15)
        sourceIconView.frame = NSRect(x: 43, y: 8, width: 16, height: 16)
        sourceLabel.frame = NSRect(x: 64, y: 9, width: bounds.width - 133, height: 15)
        timeLabel.frame = NSRect(x: bounds.width - 66, y: 9, width: 56, height: 15)
        previewLabel.frame = NSRect(x: 11, y: 34, width: bounds.width - 22, height: bounds.height - 43)
        previewImageView.frame = NSRect(
            x: 11,
            y: 34,
            width: bounds.width - 22,
            height: bounds.height - 43
        )
        editButton.frame = NSRect(x: bounds.width - 32, y: isFlipped ? 5 : bounds.height - 29, width: 22, height: 22)
        passwordContent?.frame = NSRect(x: 10, y: isFlipped ? 34 : 8, width: bounds.width - 20, height: bounds.height - 42)
        // The collection marker stays beside the menu, never underneath it.
        savedMarker.frame = NSRect(
            x: bounds.width - 52,
            y: 10,
            width: 13,
            height: 13
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.set()
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        NSCursor.arrow.set()
        refreshAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(
        item: ClipboardHistoryItem,
        quickIndex: Int?,
        sourceIcon: NSImage?,
        thumbnail: NSImage?,
        selected: Bool,
        focused: Bool,
        editable: Bool = false,
        inCapsule: Bool = false
    ) {
        let fallbackPreview: String
        switch item.kind {
        case .text: fallbackPreview = "文本内容"
        case .link: fallbackPreview = "链接"
        case .image: fallbackPreview = "图片"
        case .files: fallbackPreview = "文件"
        case .color: fallbackPreview = "颜色"
        case .unknown: fallbackPreview = "剪贴板内容"
        }
        let previewSource = item.displayText
            ?? item.canonicalText
            ?? fallbackPreview
        let preview = Self.boundedPreview(
            previewSource,
            maximumCharacters: ClipboardHistoryWindowMetrics.previewCharacterLimit
        )
        let accessible = Self.boundedPreview(
            previewSource,
            maximumCharacters: ClipboardHistoryWindowMetrics.accessibilityCharacterLimit
        )
        quickLabel.stringValue = quickIndex.map { "⌘\($0)" }
            ?? item.kind.rawValue.uppercased()
        sourceLabel.stringValue = item.sourceApplicationName
            ?? item.kind.rawValue.uppercased()
        setSourceIcon(sourceIcon)
        timeLabel.stringValue = Self.relativeTimestamp(item.capturedAt)
        previewLabel.stringValue = preview
        itemKind = item.kind
        allowsThumbnail = item.kind.allowsImageThumbnail
        self.editable = editable
        self.inCapsule = inCapsule
        editButton.toolTip = "更多操作"
        needsLayout = true
        savedTitle = nil
        savedPreview = nil
        toolTip = nil
        setThumbnail(thumbnail)
        setAccessibilityLabel(
            "\(item.kind.rawValue)：\(accessible)" + (inCapsule ? " · 已收入 Capsule" : "")
        )
        let activationHelp = "双击或回车使用；富内容会复制，然后在目标中粘贴"
        setAccessibilityHelp(selected ? "已选择；\(activationHelp)" : "单击选择；\(activationHelp)")
        setAccessibilitySelected(selected)
        selectedItem = selected
        focusedItem = focused
        refreshAppearance()
    }

    func setSourceIcon(_ image: NSImage?) {
        sourceIconView.image = image
        sourceIconView.contentTintColor = image?.isTemplate == true
            ? RimeUI.textSecondary
            : nil
        sourceIconView.isHidden = image == nil
    }

    func setThumbnail(_ image: NSImage?) {
        previewImageView.image = image
        let shouldShowImage = allowsThumbnail && image != nil
        previewImageView.isHidden = !shouldShowImage
        previewLabel.isHidden = shouldShowImage
    }

    /// A saved Capsule entry. Image and PDF cards lead with their title and
    /// show a thumbnail; the others show the title above a short preview.
    func update(
        entry: CapsuleRailEntry,
        quickIndex: Int?,
        thumbnail: NSImage?,
        selected: Bool
    ) {
        let showsMedia = entry.kind == .image || entry.kind == .pdf
        quickLabel.stringValue = quickIndex.map { "⌘\($0)" }
            ?? entry.kind.displayName.uppercased()
        sourceLabel.stringValue = showsMedia || entry.kind == .password
            ? entry.title
            : entry.kind.displayName.uppercased()
        setSourceIcon(Self.symbol(for: entry.kind))
        timeLabel.stringValue = Self.relativeTimestamp(entry.updatedAt)
        savedTitle = entry.title
        savedPreview = Self.boundedPreview(
            entry.preview,
            maximumCharacters: ClipboardHistoryWindowMetrics.previewCharacterLimit
        )
        editable = true
        inCapsule = false
        editButton.toolTip = "更多操作"
        needsLayout = true
        allowsThumbnail = showsMedia
        toolTip = entry.title
        setThumbnail(thumbnail)
        let masked = entry.kind == .password ? " · 已脱敏" : ""
        setAccessibilityLabel("\(entry.kind.displayName)：\(entry.title)\(masked)")
        let help = CapsuleRailActivationRules.action(for: entry.kind) == .revealInPlace
            ? "双击或回车在卡片内验证口令查看；不会复制或发送密码"
            : "双击或回车放入目标输入框"
        setAccessibilityHelp(selected ? "已选择；\(help)" : "单击选择；\(help)")
        setAccessibilitySelected(selected)
        selectedItem = selected
        focusedItem = selected
        refreshAppearance()
    }

    private func renderSavedPreview() {
        guard let savedTitle else { return }
        let text = NSMutableAttributedString(string: savedTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: RimeUI.textPrimary,
        ])
        if let savedPreview, !savedPreview.isEmpty {
            text.append(NSAttributedString(string: "\n" + savedPreview, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: RimeUI.textSecondary,
            ]))
        }
        previewLabel.attributedStringValue = text
    }

    private static func symbol(for kind: CapsuleEntryKind) -> NSImage? {
        let name: String
        switch kind {
        case .note: name = "note.text"
        case .image: name = "photo"
        case .video: name = "video"
        case .pdf: name = "doc.richtext"
        case .skill: name = "wand.and.stars"
        case .password: name = "lock"
        }
        let image = RimeUI.symbol(name, pointSize: 12, weight: .regular)
        image?.isTemplate = true
        return image
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeActionsMenu?() }

    @objc private func editPressed() {
        guard let menu = makeActionsMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: editButton.frame.maxX, y: editButton.frame.minY), in: self)
    }

    func setHoveredForPreview(_ value: Bool) {
        hovered = value
        refreshAppearance()
    }

    func refreshAppearance() {
        let background: NSColor
        let border: NSColor
        if selectedItem {
            background = ClipboardHistoryPalette.selectedBackground
            border = RimeUI.accentBlue
            renderedBorderWidth = focusedItem ? 2 : 1.5
        } else if hovered {
            background = RimeUI.surface3
            border = RimeUI.borderStrong
            renderedBorderWidth = 1
        } else {
            background = RimeUI.surface2
            border = RimeUI.border
            renderedBorderWidth = 1
        }
        quickLabel.textColor = selectedItem ? RimeUI.accentBlue : RimeUI.textMuted
        sourceLabel.textColor = RimeUI.textSecondary
        if sourceIconView.image?.isTemplate == true {
            sourceIconView.contentTintColor = RimeUI.textSecondary
        }
        timeLabel.textColor = RimeUI.textMuted
        if savedTitle != nil {
            renderSavedPreview()
        } else {
            previewLabel.textColor = RimeUI.textPrimary
        }
        editButton.isHidden = false
        timeLabel.isHidden = true
        savedMarker.isHidden = !inCapsule
        savedMarker.contentTintColor = selectedItem ? RimeUI.accentBlue : RimeUI.textMuted
        editButton.contentTintColor = RimeUI.textPrimary
        editButton.layer?.backgroundColor = RimeUI.surface2.cgColor
        editButton.layer?.borderColor = RimeUI.borderStrong.cgColor
        editButton.layer?.borderWidth = 1
        previewImageView.layer?.backgroundColor = RimeUI.surface3.cgColor
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = renderedBorderWidth
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "NOW" }
        if seconds < 3_600 { return "\(seconds / 60)M" }
        if seconds < 86_400 { return "\(seconds / 3_600)H" }
        return "\(seconds / 86_400)D"
    }

    private static func boundedPreview(_ text: String, maximumCharacters: Int) -> String {
        let normalized = text.replacingOccurrences(
            of: "[\\r\\n\\t]+",
            with: " ",
            options: .regularExpression
        )
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }
}

class ClipboardFirstMouseButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : .arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// The rail's tab row: Recent, then one tab per saved Capsule kind. The
/// manager shows the same row, so both surfaces read as one Capsule.
final class CapsuleRailTabStrip: NSView {
    var onSelect: ((CapsuleRailTab) -> Void)?
    private let stack = NSStackView()
    private let tabScroll = NSScrollView()
    private var buttons: [CapsuleRailTabButton] = []
    private var selectedTab: CapsuleRailTab = .recent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.horizontalScrollElasticity = .automatic
        tabScroll.documentView = stack
        addSubview(tabScroll)
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        for tab in CapsuleRailTab.ordered {
            let button = CapsuleRailTabButton(tab: tab)
            button.target = self
            button.action = #selector(tabPressed(_:))
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Capsule 类型")
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 350, height: 28) }
    override func layout() {
        super.layout()
        tabScroll.frame = bounds
        stack.frame = NSRect(x: 0, y: 0, width: max(bounds.width, stack.fittingSize.width), height: 28)
    }

    func select(_ tab: CapsuleRailTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        applyAppearance()
        if let button = buttons.first(where: { $0.tab == tab }) { button.scrollToVisible(button.bounds) }
    }

    func applyAppearance() {
        layer?.backgroundColor = RimeUI.surface2.cgColor
        layer?.borderColor = RimeUI.border.cgColor
        buttons.forEach { $0.render(selected: $0.tab == selectedTab) }
    }

    @objc private func tabPressed(_ sender: CapsuleRailTabButton) {
        onSelect?(sender.tab)
    }
}

final class CapsuleRailTabButton: ClipboardFirstMouseButton {
    let tab: CapsuleRailTab
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let content = NSStackView()

    init(tab: CapsuleRailTab) {
        self.tab = tab
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6

        // NSButton's own image-beside-title layout puts a small symbol on a
        // different line from a CJK title. Lay the pair out explicitly and
        // centre both on the same axis.
        label.stringValue = tab.label
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.setAccessibilityElement(false)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 3
        content.translatesAutoresizingMaskIntoConstraints = false
        if tab == .saved(.password) {
            icon.image = RimeUI.symbol("lock.fill", pointSize: 8, weight: .semibold)
            icon.image?.isTemplate = true
            icon.imageScaling = .scaleNone
            icon.setAccessibilityElement(false)
            content.addArrangedSubview(icon)
        }
        content.addArrangedSubview(label)
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(tab.label)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        render(selected: tab == .recent)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(content.fittingSize.width) + 20, height: 22)
    }

    /// One control: a click on the label or the lock is a click on the tab.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    func render(selected: Bool) {
        let color = selected ? RimeUI.textPrimary : RimeUI.textMuted
        layer?.backgroundColor = selected
            ? RimeUI.clipboardSelectedBackground.cgColor
            : NSColor.clear.cgColor
        label.textColor = color
        icon.contentTintColor = color
        setAccessibilitySelected(selected)
    }
}
