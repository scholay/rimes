import Cocoa
import Carbon.HIToolbox
import InputMethodKit

enum ClipboardHistoryWindowVisibilityRules {
    static func isVisibleOnActiveSpace(isOrdered: Bool, isOnActiveSpace: Bool) -> Bool {
        isOrdered && isOnActiveSpace
    }
}

enum ClipboardHistoryEventRoute: Equatable {
    case handledBySurface
    case routeToRime
    case passThrough
}

enum ClipboardHistoryWindowLifecycleRules {
    static func captureState(
        windowVisibleOnActiveSpace: Bool,
        captureEnabled: Bool,
        secureInput: Bool,
        screenLocked: Bool,
        sessionInactive: Bool,
        sleeping: Bool
    ) -> ClipboardHistoryCaptureState {
        var protection: ClipboardHistoryProtection = []
        if secureInput { protection.insert(.secureInput) }
        if screenLocked { protection.insert(.screenLocked) }
        if sessionInactive || sleeping { protection.insert(.sessionInactive) }
        return ClipboardHistoryCaptureState(
            windowVisible: windowVisibleOnActiveSpace,
            captureEnabled: captureEnabled,
            protection: protection
        )
    }
}

enum ClipboardHistoryActivationRules {
    static func canInsertEveryItemAsPlainText(
        items: [ClipboardHistoryItem],
        archives: [ClipboardPasteboardArchive]
    ) -> Bool {
        guard !items.isEmpty, items.count == archives.count else { return false }
        return zip(items, archives).allSatisfy { pair in
            let (item, archive) = pair
            // Direct IME insertion is lossless only when the stored payload is
            // ordinary plain text. Rich or future representations must be
            // restored to the pasteboard for the user's normal Command-V.
            return (item.kind == .text || item.kind == .link)
                && item.textCompleteness == .complete
                && !(item.canonicalText ?? "").isEmpty
                && !archive.requiresPasteboardRestorationForTextInsertion
        }
    }

    static func shouldAttemptDirectTextDelivery(
        mode: ClipboardHistoryPresentationMode,
        currentSourceIsOwn: Bool,
        allItemsAreCompletePlainText: Bool
    ) -> Bool {
        mode == .borrowedRime
            && currentSourceIsOwn
            && allItemsAreCompletePlainText
    }
}

enum ClipboardHistoryPresentationMode: Equatable {
    case borrowedRime
    case standalonePasteboard

    static func resolve(currentSourceIsOwn: Bool) -> Self {
        currentSourceIsOwn ? .borrowedRime : .standalonePasteboard
    }
}

private final class ClipboardHistoryPanel: NSPanel {
    var acceptsKeyInput = false
    var standaloneKeyEquivalentHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { acceptsKeyInput }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if acceptsKeyInput,
           standaloneKeyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

func clipboardHistoryStandalonePanelKeyboardProbe() -> Bool {
    let panel = ClipboardHistoryPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
    panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
    panel.contentView?.addSubview(field)
    let rejectsBorrowedKeyInput = !panel.canBecomeKey
    panel.acceptsKeyInput = true
    let acceptsStandaloneKeyInput = panel.canBecomeKey
        && panel.makeFirstResponder(field)
        && panel.firstResponder != nil
    var routedKeyEquivalent = false
    panel.standaloneKeyEquivalentHandler = { _ in
        routedKeyEquivalent = true
        return true
    }
    let commandC = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 1,
        windowNumber: 0,
        context: nil,
        characters: "c",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_C)
    )
    let handlesStandaloneKeyEquivalent = commandC.map {
        panel.performKeyEquivalent(with: $0)
    } == true && routedKeyEquivalent
    panel.orderOut(nil)
    return rejectsBorrowedKeyInput
        && acceptsStandaloneKeyInput
        && handlesStandaloneKeyEquivalent
}

private final class ClipboardHistoryChromeView: NSVisualEffectView {
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        borderLayer.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(1, scale)
        layer?.cornerRadius = ClipboardHistoryWindowMetrics.cornerRadius
        layer?.masksToBounds = true
        borderLayer.frame = bounds
        borderLayer.lineWidth = lineWidth
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: ClipboardHistoryWindowMetrics.cornerRadius,
            cornerHeight: ClipboardHistoryWindowMetrics.cornerRadius,
            transform: nil
        )
    }

    func applyAppearance() {
        material = RimeUI.isDark ? .hudWindow : .popover
        blendingMode = .behindWindow
        state = .active
        appearance = RimeUI.appKitAppearance
        layer?.backgroundColor = RimeUI.workbenchChrome.cgColor
        borderLayer.strokeColor = RimeUI.borderStrong.cgColor
        needsLayout = true
    }
}

/// Clipboard History has two explicit presentation modes. With RIMES selected,
/// the nonactivating panel borrows an exact external FocusToken for logical
/// search and plain-text delivery. With another input method selected, it is a
/// key-capable AppKit search surface whose activation only prepares the system
/// pasteboard. It is never a Buffer source or destination.
final class ClipboardHistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryWindowController()

    private enum Key {
        static let captureEnabled = "clipboardHistory.captureEnabled.v1"
        static let legacyRailEnabled = "bufferWindow.clipboardRailEnabled.v1"
    }

    private let panel: ClipboardHistoryPanel
    private let chrome = ClipboardHistoryChromeView(frame: .zero)
    private let historyModel: ClipboardHistoryModel
    private let pane: ClipboardHistoryPaneView
    private var observers: [NSObjectProtocol] = []
    private var secureInputTimer: Timer?
    private var lastSecureInputState = IsSecureEventInputEnabled()
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var hiddenForSession = false
    private var presentationIntent = false
    private var presentationTargetToken: FocusToken?
    private weak var presentationTargetController: RimeBufferController?
    private var presentationMode: ClipboardHistoryPresentationMode = .borrowedRime
    private var standaloneFocusRegistered = false
    private var explicitCaptureGeneration: UInt64 = 0
    private var consumedKeyCodes: Set<UInt16> = []
    private var lastHandledKeyCode: UInt16?
    private var lastHandledClientIdentity: ObjectIdentifier?
    private var lastHandledKeyUptime: TimeInterval = 0
    private var richActivationGeneration: UInt64 = 0
    private var richActivationInFlight = false

    var isVisible: Bool {
        ClipboardHistoryWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace
        )
    }

    var captureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.captureEnabled) }
        set {
            guard newValue != captureEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Key.captureEnabled)
            if !newValue { retireSearchCompositionIfNeeded() }
            syncCaptureState()
            if newValue, isVisible { scheduleExplicitCapture() }
        }
    }

    private override init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.captureEnabled) == nil {
            let migrated = defaults.object(forKey: Key.legacyRailEnabled)
                .map { _ in defaults.bool(forKey: Key.legacyRailEnabled) } ?? true
            defaults.set(migrated, forKey: Key.captureEnabled)
        }

        let model = MainActor.assumeIsolated { ClipboardHistoryModel() }
        historyModel = model
        pane = MainActor.assumeIsolated { ClipboardHistoryPaneView(model: model) }
        panel = ClipboardHistoryPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: ClipboardHistoryWindowMetrics.preferredWidth,
                height: ClipboardHistoryWindowMetrics.preferredHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        installObservers()
        MainActor.assumeIsolated { historyModel.start() }
        syncCaptureState()
    }

    deinit {
        secureInputTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        syncCaptureState()
    }

    @discardableResult
    func flushPersistenceBeforeTermination(
        timeout: TimeInterval = 5
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            historyModel.flushPersistence(timeout: timeout)
        }
    }

    func toggleVisibility() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        dispatchPrecondition(condition: .onQueue(.main))
        let secureInputAtInvocation = IsSecureEventInputEnabled()
        guard !sessionProtectionActive, !secureInputAtInvocation else {
            syncCaptureState(secureInputEnabled: secureInputAtInvocation)
            IMELog.write("clipboard window show blocked by protection")
            return
        }

        let mode = ClipboardHistoryPresentationMode.resolve(
            currentSourceIsOwn: RimeInputSourceAuthority.currentSourceIsOwn()
        )
        presentationMode = mode
        presentationIntent = true
        hiddenForSession = false
        consumedKeyCodes.removeAll()
        MainActor.assumeIsolated {
            pane.resetSearch()
            pane.setStandaloneSearchEnabled(mode == .standalonePasteboard)
        }

        let initialTarget: FocusLease?
        switch mode {
        case .borrowedRime:
            initialTarget = InputFocusCoordinator.shared.liveTarget(
                forceOverlayVisibilityRefresh: true
            )
            if let initialTarget,
               initialTarget.isExternalTarget,
               initialTarget.compositionActive {
                initialTarget.controller?.resolveCompositionForWorkbenchTransition(
                    target: initialTarget
                )
            }
            presentationTargetToken = initialTarget.flatMap { target in
                guard target.isExternalTarget,
                      InputFocusCoordinator.shared.liveTarget(
                        expected: target.token,
                        forceOverlayVisibilityRefresh: true
                      ) === target else { return nil }
                return target.token
            }
            presentationTargetController = presentationTargetToken == nil
                ? nil
                : initialTarget?.controller
            if let initialTarget,
               presentationTargetToken == initialTarget.token,
               initialTarget.controller?.beginClipboardSearch(
                expected: initialTarget
               ) != true {
                presentationTargetToken = nil
                presentationTargetController = nil
                IMELog.write("clipboard search target preparation rejected")
            }
        case .standalonePasteboard:
            initialTarget = nil
            detachPresentationTargetAndRetireSearch(
                restoreHostPresentation: false
            )
        }

        positionOnCurrentScreen(target: initialTarget)
        if panel.isVisible, !panel.isOnActiveSpace { panel.orderOut(nil) }
        applyAppearance()
        panel.acceptsKeyInput = mode == .standalonePasteboard
        if mode == .standalonePasteboard {
            registerStandaloneFocusIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.pane.focusStandaloneSearch()
                }
            }
        } else {
            panel.orderFrontRegardless()
        }
        syncCaptureState()
        scheduleExplicitCapture()
        RimeBufferController.refreshActiveUI()
        let targetDescription = presentationTargetToken?.description ?? "none"
        IMELog.write(
            "clipboard window shown mode=\(mode) target=\(targetDescription)"
        )
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        hideImmediately()
    }

    private func hideImmediately() {
        dispatchPrecondition(condition: .onQueue(.main))
        presentationIntent = false
        detachPresentationTargetAndRetireSearch(
            restoreHostPresentation:
                RimeInputSourceAuthority.currentSourceIsOwn()
        )
        richActivationGeneration &+= 1
        richActivationInFlight = false
        hiddenForSession = false
        explicitCaptureGeneration &+= 1
        MainActor.assumeIsolated {
            pane.resetSearch()
            pane.setStandaloneSearchEnabled(false)
        }
        panel.orderOut(nil)
        panel.acceptsKeyInput = false
        if standaloneFocusRegistered {
            StandaloneWindowFocusCoordinator.shared.windowWillClose(panel)
            standaloneFocusRegistered = false
        }
        presentationMode = .borrowedRime
        syncCaptureState()
        IMELog.write("clipboard window hidden")
    }

    /// The standalone panel stays nonactivating, so its logical search field
    /// borrows the current controller's Rime session while retaining the exact
    /// external client as a later delivery target.
    func capturesSearchInput(
        expected token: FocusToken,
        client: IMKTextInput
    ) -> Bool {
        guard isVisible,
              presentationTargetToken == token,
              captureState().allowsContentPresentation,
              let target = InputFocusCoordinator.shared.interactionTarget(
                expected: token
              ),
              target.isExternalTarget,
              target.clientIdentity == ObjectIdentifier(client as AnyObject)
        else { return false }
        return true
    }

    @discardableResult
    func appendSearchText(
        _ text: String,
        expected token: FocusToken,
        client: IMKTextInput
    ) -> Bool {
        guard capturesSearchInput(expected: token, client: client) else {
            return false
        }
        return MainActor.assumeIsolated { pane.appendSearchText(text) }
    }

    func updateSearchComposition(
        _ text: String,
        expected token: FocusToken,
        client: IMKTextInput
    ) -> NSRect? {
        guard capturesSearchInput(expected: token, client: client) else {
            return nil
        }
        return MainActor.assumeIsolated {
            pane.updateComposingText(text)
            return pane.searchCaretRectOnScreen()
        }
    }

    func searchCaretScreenRect(expected token: FocusToken) -> NSRect? {
        guard isVisible,
              presentationTargetToken == token,
              captureState().allowsContentPresentation,
              InputFocusCoordinator.shared.interactionTarget(
                expected: token
              ) != nil else { return nil }
        return MainActor.assumeIsolated { pane.searchCaretRectOnScreen() }
    }

    func clearSearchComposition() {
        MainActor.assumeIsolated { pane.updateComposingText("") }
    }

    func focusDidChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isVisible else { return }
        guard let presentationTargetToken else {
            // `hide()` clears its target before it orders the panel out. A
            // composition-state callback can arrive in that interval; do not
            // let it rebound the closing surface to the same host lease.
            guard presentationIntent,
                  RimeInputSourceAuthority.currentSourceIsOwn(),
                  let target = InputFocusCoordinator.shared.liveTarget(
                    forceOverlayVisibilityRefresh: true
                  ),
                  target.isExternalTarget else { return }
            self.presentationTargetToken = target.token
            presentationTargetController = target.controller
            RimeBufferController.refreshActiveUI()
            IMELog.write("clipboard window rebound target=\(target.token)")
            return
        }
        guard InputFocusCoordinator.shared.liveTarget(
            expected: presentationTargetToken,
            forceOverlayVisibilityRefresh: true
        ) != nil else {
            hide()
            return
        }
    }

    func focusInvalidated(_ token: FocusToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard presentationTargetToken == token else { return }
        hide()
    }

    /// A foreign input source retires only borrowed IMK authority. The visible
    /// surface remains usable through its native AppKit field and pasteboard.
    func inputSourceDidChangeAwayFromRIMES() {
        dispatchPrecondition(condition: .onQueue(.main))
        detachPresentationTargetAndRetireSearch(
            restoreHostPresentation: false
        )
        presentationMode = .standalonePasteboard
        // Configure key/search behavior even while the panel is ordered on a
        // different Space or temporarily hidden for lock/sleep protection.
        // Those transitions do not call `show()` again before restoring it.
        panel.acceptsKeyInput = true
        MainActor.assumeIsolated {
            pane.setStandaloneSearchEnabled(true)
        }
        if presentationIntent, panel.isVisible {
            registerStandaloneFocusIfNeeded()
        }
        if isVisible {
            // Source-change observation itself stays passive. Activating the
            // application here could race macOS per-document input-source
            // restoration; the native field takes focus on the user's next
            // click without selecting or switching any input source in code.
            panel.orderFrontRegardless()
        }
        consumedKeyCodes.removeAll()
        lastHandledKeyCode = nil
        lastHandledClientIdentity = nil
        IMELog.write("clipboard switched to standalone pasteboard mode")
    }

    /// IMK routing entry. Key-up ownership survives a successful Return that
    /// closes the panel, preventing the release from leaking into the host.
    @discardableResult
    func route(_ event: NSEvent, client: IMKTextInput) -> ClipboardHistoryEventRoute {
        dispatchPrecondition(condition: .onQueue(.main))
        if event.type == .keyUp {
            return consumedKeyCodes.remove(event.keyCode) != nil
                ? .handledBySurface
                : .passThrough
        }
        guard event.type == .keyDown else { return .passThrough }
        // A fresh physical keyDown retires command-callback ownership from the
        // preceding press before this event decides whether Clip owns it.
        lastHandledKeyCode = nil
        lastHandledClientIdentity = nil
        let isReturnKey = [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
            .contains(event.keyCode)
        let intentModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        let visible = isVisible
        let token = presentationTargetToken
        let target = token.flatMap {
            InputFocusCoordinator.shared.liveTarget(
                expected: $0,
                forceOverlayVisibilityRefresh: true
            )
        }
        let targetIsExternal = target?.isExternalTarget == true
        let clientMatches = target?.clientIdentity
            == ObjectIdentifier(client as AnyObject)
        let secureInput = IsSecureEventInputEnabled()
        guard visible,
              let token,
              let target,
              targetIsExternal,
              clientMatches,
              !secureInput else {
            if isReturnKey {
                IMELog.write(
                    "clipboard return route=pass modifiers=\(intentModifiers.rawValue) "
                        + "visible=\(visible) token=\(token != nil) "
                        + "target=\(target != nil) external=\(targetIsExternal) "
                        + "client=\(clientMatches) secure=\(secureInput)"
                )
            }
            return .passThrough
        }

        let searchCompositionIsActive = target.controller?
            .clipboardSearchCompositionIsActive(
            expected: token,
            client: client
        ) == true
        if Self.shouldRouteSearchCompositionEventToRime(
            event,
            compositionActive: searchCompositionIsActive
        ) {
            if isReturnKey {
                IMELog.write(
                    "clipboard return route=rime modifiers=\(intentModifiers.rawValue) "
                        + "composition=\(searchCompositionIsActive)"
                )
            }
            armEventOwnership(event, client: client)
            return .routeToRime
        }

        if isReturnKey,
           searchCompositionIsActive,
           target.controller?.discardClipboardSearchCompositionForActivation(
            expected: token,
            client: client
           ) != true {
            armEventOwnership(event, client: client)
            IMELog.write(
                "clipboard return consumed; search composition retirement failed"
            )
            return .handledBySurface
        }

        // Arm callback suppression before the action. Delivery can synchronously
        // re-enter a host, so recording only after Return finishes is too late.
        lastHandledKeyCode = event.keyCode
        lastHandledClientIdentity = ObjectIdentifier(client as AnyObject)
        lastHandledKeyUptime = ProcessInfo.processInfo.systemUptime
        let handled = MainActor.assumeIsolated { pane.handleKeyDown(event) }
        if handled {
            if isReturnKey {
                IMELog.write(
                    "clipboard return route=surface modifiers=\(intentModifiers.rawValue) "
                        + "composition=\(searchCompositionIsActive)"
                )
            }
            consumedKeyCodes.insert(event.keyCode)
            return .handledBySurface
        }
        if Self.isPlainSearchInputEvent(event) {
            consumedKeyCodes.insert(event.keyCode)
            return .routeToRime
        }
        lastHandledKeyCode = nil
        lastHandledClientIdentity = nil
        return .passThrough
    }

    /// Suppresses AppKit command callbacks corresponding to an IMK keyDown we
    /// already handled. Some hosts send both paths even after `handle` returns
    /// true; consuming the duplicate prevents Return/Delete/Escape leakage.
    func consumeCommandIfRecentlyHandled(
        _ selector: Selector,
        client: IMKTextInput?
    ) -> Bool {
        guard let lastHandledKeyCode,
              Self.hardwareKeyCodes(for: selector).contains(lastHandledKeyCode),
              ProcessInfo.processInfo.systemUptime - lastHandledKeyUptime < 0.5 else {
            return false
        }
        if let client,
           lastHandledClientIdentity != ObjectIdentifier(client as AnyObject) {
            return false
        }
        return true
    }

    /// Some AppKit hosts report Return only through `didCommand(by:)` and do
    /// not first send the input method a keyDown event. When Clip owns the
    /// exact external client, that command must still activate the selected
    /// history item instead of committing the borrowed Rime search session.
    /// The command remains consumed even when activation cannot start, so a
    /// failed image delivery never leaks a newline into the host field.
    func consumeActivationCommandIfVisible(
        client: IMKTextInput?,
        controller: RimeBufferController
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              isVisible,
              captureState().allowsContentPresentation,
              let client,
              let token = presentationTargetToken,
              let target = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              target.isExternalTarget,
              target.controller === controller,
              target.clientIdentity == ObjectIdentifier(client as AnyObject),
              !IsSecureEventInputEnabled() else { return false }

        if controller.clipboardSearchCompositionIsActive(
            expected: token,
            client: client
        ), !controller.discardClipboardSearchCompositionForActivation(
            expected: token,
            client: client
        ) {
            IMELog.write(
                "clipboard activation command consumed; search retirement failed"
            )
            return true
        }
        let activated = MainActor.assumeIsolated {
            pane.activateSelectedItems()
        }
        IMELog.write(
            activated
                ? "clipboard activation command accepted"
                : "clipboard activation command consumed without activation"
        )
        return true
    }

    func clearHistory() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !MainActor.assumeIsolated({ historyModel.isContentShielded }) else {
            return
        }
        MainActor.assumeIsolated { historyModel.clear() }
    }

    private func buildWindow() {
        panel.level = CandidatePanelLevelRules.workbenchStandard
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.standaloneKeyEquivalentHandler = { [weak self] event in
            guard let self,
                  self.presentationMode == .standalonePasteboard else {
                return false
            }
            return MainActor.assumeIsolated {
                self.pane.handleStandaloneKeyEquivalent(event)
            }
        }
        panel.setAccessibilityTitle("RIMES Clipboard History")

        chrome.translatesAutoresizingMaskIntoConstraints = false
        pane.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 2),
            pane.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -2),
            pane.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 2),
            pane.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -2),
        ])
        panel.contentView = chrome

        MainActor.assumeIsolated {
            pane.onActivate = { [weak self] items in
                self?.deliver(items) ?? false
            }
            pane.onCopy = { [weak self] items in self?.copy(items) ?? false }
            pane.onClose = { [weak self] in self?.hide() }
        }
        applyAppearance()
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        chrome.applyAppearance()
        panel.invalidateShadow()
    }

    private func positionOnCurrentScreen(target: FocusLease?) {
        let targetRect = target.flatMap { lease in
            lease.controller?.workbenchCaretRect(expected: lease)
        }
        let screen = targetRect.flatMap { rect in
            NSScreen.screens.first { $0.visibleFrame.intersects(rect) }
        } ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(
            ClipboardHistoryWindowMetrics.preferredWidth,
            max(1, visible.width - 32)
        )
        let height = min(ClipboardHistoryWindowMetrics.preferredHeight, visible.height)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + min(24, max(0, visible.height - height)),
            width: width,
            height: height
        )
        panel.setFrame(frame, display: false)
    }

    private func captureState(
        secureInputEnabled: Bool? = nil
    ) -> ClipboardHistoryCaptureState {
        ClipboardHistoryWindowLifecycleRules.captureState(
            windowVisibleOnActiveSpace: isVisible && !hiddenForSession,
            captureEnabled: captureEnabled,
            secureInput: secureInputEnabled ?? IsSecureEventInputEnabled(),
            screenLocked: screenLocked,
            sessionInactive: sessionInactive,
            sleeping: sleeping
        )
    }

    private func syncCaptureState(secureInputEnabled: Bool? = nil) {
        let state = captureState(secureInputEnabled: secureInputEnabled)
        MainActor.assumeIsolated {
            historyModel.update(
                windowVisible: state.windowVisible,
                captureEnabled: state.captureEnabled,
                protection: state.protection
            )
            pane.reloadFromModel()
        }
    }

    private func scheduleExplicitCapture() {
        explicitCaptureGeneration &+= 1
        let generation = explicitCaptureGeneration
        DispatchQueue.main.async { [weak self] in
            self?.performExplicitCapture(generation: generation, mayRetry: true)
        }
    }

    private func performExplicitCapture(generation: UInt64, mayRetry: Bool) {
        guard generation == explicitCaptureGeneration,
              presentationIntent,
              captureEnabled else { return }
        syncCaptureState()
        let state = captureState()
        if state.allowsClipboardObservation {
            _ = MainActor.assumeIsolated {
                historyModel.captureCurrentIfEligible()
            }
            return
        }
        guard mayRetry,
              panel.isVisible,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.performExplicitCapture(generation: generation, mayRetry: false)
        }
    }

    private func deliver(_ items: [ClipboardHistoryItem]) -> Bool {
        guard isVisible,
              captureState().allowsContentPresentation,
              !items.isEmpty else {
            IMELog.write(
                "clipboard activation rejected visible=\(isVisible) "
                    + "presentable=\(captureState().allowsContentPresentation) "
                    + "items=\(items.count)"
            )
            return false
        }
        return activateArchives(items, closesAfterWrite: true)
    }

    private func copy(_ items: [ClipboardHistoryItem]) -> Bool {
        guard isVisible, captureState().allowsContentPresentation,
              !items.isEmpty else {
            NSSound.beep()
            return false
        }
        return activateArchives(items, closesAfterWrite: false)
    }

    /// A successful archive write puts the selected cards first in both the
    /// system pasteboard and history. Close silently so the user can paste the
    /// exact rich value with an ordinary Command-V in the target application.
    private func closePreparedArchiveActivation() {
        dispatchPrecondition(condition: .onQueue(.main))
        richActivationInFlight = false
        IMELog.write("clipboard archive activation settled pasteboard-ready=true")
        hideImmediately()
    }

    private func activateArchives(
        _ items: [ClipboardHistoryItem],
        closesAfterWrite: Bool
    ) -> Bool {
        guard !richActivationInFlight else {
            IMELog.write(
                "clipboard activation ignored while another activation is in flight"
            )
            return false
        }
        let expectedToken = presentationTargetToken

        richActivationGeneration &+= 1
        let generation = richActivationGeneration
        let expectedPasteboardChangeCount = NSPasteboard.general.changeCount
        richActivationInFlight = true
        let itemIDs = items.map(\.id)
        IMELog.write(
            "clipboard activation loading items=\(items.count) kinds="
                + items.map { $0.kind.rawValue }.joined(separator: ",")
        )
        MainActor.assumeIsolated {
            historyModel.loadArchives(ids: itemIDs) { [weak self] archives in
                guard let self else { return }
                guard self.richActivationGeneration == generation else {
                    IMELog.write("clipboard activation archive callback superseded")
                    return
                }
                self.richActivationInFlight = false
                guard self.isVisible,
                      self.captureState().allowsContentPresentation,
                      let archives,
                      archives.count == items.count else {
                    IMELog.write(
                        "clipboard activation archive callback rejected "
                            + "visible=\(self.isVisible) "
                            + "presentable=\(self.captureState().allowsContentPresentation) "
                            + "archives=\(archives?.count ?? -1) items=\(items.count)"
                    )
                    return
                }
                IMELog.write(
                    "clipboard activation archives ready count=\(archives.count)"
                )

                if closesAfterWrite {
                    let canInsertEveryItem = ClipboardHistoryActivationRules
                        .canInsertEveryItemAsPlainText(
                            items: items,
                            archives: archives
                        )
                    let canUseBorrowedRimeTarget = ClipboardHistoryActivationRules
                        .shouldAttemptDirectTextDelivery(
                            mode: self.presentationMode,
                            currentSourceIsOwn: RimeInputSourceAuthority
                                .currentSourceIsOwn(),
                            allItemsAreCompletePlainText: canInsertEveryItem
                        )
                    if canUseBorrowedRimeTarget {
                        let target = expectedToken.flatMap {
                            InputFocusCoordinator.shared.liveTarget(
                                expected: $0,
                                forceOverlayVisibilityRefresh: true
                            )
                        }
                        var deliveredIDs: [UUID] = []
                        if let expectedToken,
                           self.presentationTargetToken == expectedToken,
                           let target,
                           target.isExternalTarget,
                           let controller = target.controller {
                            for item in items {
                                guard self.isVisible,
                                      self.presentationTargetToken == expectedToken,
                                      self.captureState().allowsContentPresentation,
                                      let canonicalText = item.canonicalText,
                                      controller.deliverClipboardHistoryText(
                                        canonicalText,
                                        expected: expectedToken
                                      ) else { break }
                                deliveredIDs.append(item.id)
                            }
                        } else {
                            IMELog.write(
                                "clipboard text activation has no exact target; "
                                    + "falling back to pasteboard"
                            )
                        }
                        if deliveredIDs.count == items.count {
                            MainActor.assumeIsolated {
                                _ = self.historyModel.promote(ids: deliveredIDs)
                            }
                            self.hide()
                            return
                        }
                        if !deliveredIDs.isEmpty {
                            let remaining = items.dropFirst(deliveredIDs.count)
                                .map(\.id)
                            MainActor.assumeIsolated {
                                _ = self.historyModel.promote(ids: deliveredIDs)
                                _ = self.historyModel.select(
                                    ids: remaining,
                                    focusedID: remaining.first
                                )
                            }
                            IMELog.write(
                                "clipboard text activation partially delivered; "
                                    + "remaining=\(remaining.count)"
                            )
                            return
                        }
                        IMELog.write(
                            "clipboard text activation delivered no items; "
                                + "falling back to pasteboard"
                        )
                    }
                    IMELog.write(
                        "clipboard activation preparing pasteboard mode="
                            + "\(self.presentationMode)"
                    )
                }

                // IMKit can insert complete plain text through the exact focus
                // token, but it has no lossless primitive for HTML/RTF, images,
                // files, colors, or unknown UTIs. Restore those representations
                // exactly, promote the selected cards, and close silently. The
                // user can then paste the prepared value with ordinary Command-V.
                do {
                    let merged = try ClipboardPasteboardArchive.merging(archives)
                    guard !IsSecureEventInputEnabled(),
                          !self.sessionProtectionActive else {
                        IMELog.write(
                            "clipboard archive restore rejected by live protection"
                        )
                        return
                    }
                    let writtenChangeCount = try merged.write(
                        to: .general,
                        expectedChangeCount: expectedPasteboardChangeCount
                    )
                    MainActor.assumeIsolated {
                        _ = self.historyModel.promote(ids: itemIDs)
                        _ = self.historyModel.baselineAfterOwnPasteboardWrite(
                            expectedChangeCount: writtenChangeCount
                        )
                    }
                    self.syncCaptureState()
                    if closesAfterWrite {
                        self.closePreparedArchiveActivation()
                    }
                } catch {
                    IMELog.write(
                        "clipboard archive restore failed: "
                            + error.localizedDescription
                    )
                }
            }
        }
        return true
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.applyAppearance() })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activeSpaceDidChange()
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sessionInactive = true
            self?.protectForSession()
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sessionInactive = false
            self?.restoreAfterSessionProtection()
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleeping = true
            self?.protectForSession()
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleeping = false
            self?.restoreAfterSessionProtection()
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = true
            self?.protectForSession()
        })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = false
            self?.restoreAfterSessionProtection()
        })

        secureInputTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let secure = IsSecureEventInputEnabled()
            guard secure != self.lastSecureInputState else { return }
            self.lastSecureInputState = secure
            self.syncCaptureState(secureInputEnabled: secure)
            if secure {
                self.retireSearchCompositionIfNeeded()
                MainActor.assumeIsolated { self.pane.scrubForProtection() }
            }
        }
        if let secureInputTimer { RunLoop.main.add(secureInputTimer, forMode: .common) }
    }

    private func protectForSession() {
        explicitCaptureGeneration &+= 1
        hiddenForSession = panel.isVisible || presentationIntent
        retireSearchCompositionIfNeeded()
        presentationTargetToken = nil
        presentationTargetController = nil
        MainActor.assumeIsolated { pane.scrubForProtection() }
        panel.orderOut(nil)
        syncCaptureState()
    }

    /// `isOnActiveSpace` is part of the capture authority, but AppKit does not
    /// emit a window visibility callback when Mission Control changes Spaces.
    /// Close the read gate synchronously, then re-evaluate on the next main-loop
    /// turn after AppKit has updated the panel's Space membership. Resuming is
    /// baseline-only, so content copied during the transition is never imported.
    private func activeSpaceDidChange() {
        explicitCaptureGeneration &+= 1
        retireSearchCompositionIfNeeded()
        MainActor.assumeIsolated {
            historyModel.update(
                windowVisible: false,
                captureEnabled: captureEnabled,
                protection: captureState().protection
            )
            pane.reloadFromModel()
        }
        DispatchQueue.main.async { [weak self] in
            self?.syncCaptureState()
        }
    }

    private func restoreAfterSessionProtection() {
        syncCaptureState()
        guard hiddenForSession, presentationIntent, !sessionProtectionActive else { return }
        hiddenForSession = false
        positionOnCurrentScreen(target: nil)
        if presentationMode == .standalonePasteboard {
            registerStandaloneFocusIfNeeded()
        }
        panel.orderFrontRegardless()
        syncCaptureState()
        // Passive restore deliberately establishes only a baseline; content
        // copied during the protected interval is never imported.
    }

    private var sessionProtectionActive: Bool {
        sessionInactive || screenLocked || sleeping
    }

    private func registerStandaloneFocusIfNeeded() {
        guard presentationIntent,
              presentationMode == .standalonePasteboard,
              !standaloneFocusRegistered else { return }
        StandaloneWindowFocusCoordinator.shared.windowWillPresent(panel)
        standaloneFocusRegistered = true
    }

    private func retireSearchCompositionIfNeeded() {
        guard let token = presentationTargetToken else {
            clearSearchComposition()
            return
        }
        presentationTargetController?.cancelClipboardSearchComposition(
            expected: token
        )
        clearSearchComposition()
    }

    private func detachPresentationTargetAndRetireSearch(
        restoreHostPresentation: Bool
    ) {
        let token = presentationTargetToken
        let controller = presentationTargetController
        presentationTargetToken = nil
        presentationTargetController = nil
        if let token {
            controller?.cancelClipboardSearchComposition(
                expected: token,
                restoreHostPresentation: restoreHostPresentation
            )
        }
        clearSearchComposition()
    }

    private func armEventOwnership(_ event: NSEvent, client: IMKTextInput) {
        lastHandledKeyCode = event.keyCode
        lastHandledClientIdentity = ObjectIdentifier(client as AnyObject)
        lastHandledKeyUptime = ProcessInfo.processInfo.systemUptime
        consumedKeyCodes.insert(event.keyCode)
    }

    static func isPlainSearchInputEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .function])
        guard modifiers.isEmpty,
              let characters = event.characters,
              !characters.isEmpty else { return false }
        return isLiteralSearchText(characters)
    }

    /// AppKit represents arrows and other Cocoa function keys with private-use
    /// Unicode scalars (for example, Up Arrow is U+F700). Those values are not
    /// text and must never become invisible bytes in the logical search query.
    static func isLiteralSearchText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            let isPrivateUse = (0xE000...0xF8FF).contains(value)
                || (0xF0000...0xFFFFD).contains(value)
                || (0x100000...0x10FFFD).contains(value)
            return !CharacterSet.controlCharacters.contains(scalar)
                && !isPrivateUse
        }
    }

    static func isRimeCompositionEditingEvent(_ event: NSEvent) -> Bool {
        let intentModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        guard intentModifiers.isEmpty else { return false }
        return [
            UInt16(kVK_Escape), UInt16(kVK_Tab),
            UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow),
            UInt16(kVK_UpArrow), UInt16(kVK_DownArrow),
            UInt16(kVK_Home), UInt16(kVK_End),
            UInt16(kVK_PageUp), UInt16(kVK_PageDown),
            UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter),
            UInt16(kVK_Delete), UInt16(kVK_ForwardDelete),
        ].contains(event.keyCode)
    }

    /// Return belongs to the selected Clipboard item even while the logical
    /// search field has an unfinished Rime preedit. The eventual successful
    /// activation closes the panel and retires that preedit; a failed activation
    /// remains owned by the surface so Return never leaks into the host field.
    static func shouldRouteSearchCompositionEventToRime(
        _ event: NSEvent,
        compositionActive: Bool
    ) -> Bool {
        guard compositionActive else { return false }
        let intentModifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        let isPlainActivationReturn = intentModifiers.isEmpty
            && [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
                .contains(event.keyCode)
        return !isPlainActivationReturn && isRimeCompositionEditingEvent(event)
    }

    static func hardwareKeyCodes(for selector: Selector) -> Set<UInt16> {
        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertLineBreak:",
             "insertNewlineIgnoringFieldEditor:",
             "insertParagraphSeparator:":
            return [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)]
        case "cancelOperation:": return [UInt16(kVK_Escape)]
        case "deleteBackward:": return [UInt16(kVK_Delete)]
        case "deleteForward:": return [UInt16(kVK_ForwardDelete)]
        case "moveLeft:": return [UInt16(kVK_LeftArrow)]
        case "moveRight:": return [UInt16(kVK_RightArrow)]
        case "moveUp:": return [UInt16(kVK_UpArrow)]
        case "moveDown:": return [UInt16(kVK_DownArrow)]
        case "pageUp:", "scrollPageUp:": return [UInt16(kVK_PageUp)]
        case "pageDown:", "scrollPageDown:": return [UInt16(kVK_PageDown)]
        case "moveToBeginningOfLine:", "moveToBeginningOfDocument:",
             "scrollToBeginningOfDocument:":
            return [UInt16(kVK_Home)]
        case "moveToEndOfLine:", "moveToEndOfDocument:",
             "scrollToEndOfDocument:":
            return [UInt16(kVK_End)]
        case "insertTab:", "insertBacktab:": return [UInt16(kVK_Tab)]
        case "copy:": return [UInt16(kVK_ANSI_C)]
        default: return []
        }
    }
}
