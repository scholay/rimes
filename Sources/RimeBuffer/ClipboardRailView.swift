import Cocoa

/// Geometry shared with the React `ClipboardSurface`. Keeping the rail values
/// explicit makes later workbench integration independent from AppKit's
/// control-size defaults.
enum ClipboardRailMetrics {
    static let railHeight: CGFloat = 40
    static let railInset: CGFloat = 5
    static let cardHeight: CGFloat = 20
    static let cardSpacing: CGFloat = 3
    static let cardHorizontalInset: CGFloat = 4
    static let cardCornerRadius: CGFloat = 5
    static let maximumCardWidth: CGFloat = 220
    static let previewCharacterLimit = 160
    static let accessibilityCharacterLimit = 512
}

/// Small deterministic projection used by the standalone Clipboard smoke.
/// It intentionally contains geometry and state only, never clipboard text.
struct ClipboardRailViewSnapshot: Equatable {
    let railHeight: CGFloat
    let cardCount: Int
    let cardHeight: CGFloat
    let widestCardWidth: CGFloat
    let selectedCardBorderWidth: CGFloat?
    let isActive: Bool
    let isProtected: Bool
    let stateIsVisible: Bool
}

/// Compact, keyboard-addressable native counterpart of React's
/// `ClipboardSurface` rail. This view only asks the model for its already
/// privacy-gated projection and never reads or writes NSPasteboard itself.
@MainActor
final class ClipboardRailView: NSView {
    /// Return `true` only after the item was accepted by Buffer. Failed or
    /// missing callbacks leave history order unchanged.
    var onAddToBuffer: ((ClipboardHistoryItem) -> Bool)?

    private let model: ClipboardHistoryModel
    private let scrollView = ClipboardHorizontalScrollView()
    private let cardDocumentView = ClipboardCardDocumentView()
    private let stateContainer = NSView()
    private let stateIcon = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "")
    private var cardButtons: [UUID: ClipboardCardButton] = [:]
    private var modelObserver: UUID?
    private var appearanceObserver: NSObjectProtocol?

    private(set) var isRailActive = false

    init(model: ClipboardHistoryModel) {
        self.model = model
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: ClipboardRailMetrics.railHeight
        ))
        configureView()
        modelObserver = model.addObserver { [weak self] in
            self?.reloadFromModel()
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadFromModel()
            }
        }
        reloadFromModel()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let modelObserver {
            let observedModel = model
            Task { @MainActor in
                observedModel.removeObserver(modelObserver)
            }
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ClipboardRailMetrics.railHeight)
    }

    override var acceptsFirstResponder: Bool {
        model.isStarted
            && model.captureState.workbenchVisible
            && model.captureState.railEnabled
            && !model.isContentShielded
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let inset = ClipboardRailMetrics.railInset
        let cardY = floor((bounds.height - ClipboardRailMetrics.cardHeight) / 2)
        scrollView.frame = NSRect(
            x: inset,
            y: cardY,
            width: max(0, bounds.width - inset * 2),
            height: ClipboardRailMetrics.cardHeight
        )
        stateContainer.frame = bounds.insetBy(dx: inset, dy: inset)
        cardDocumentView.layoutCards(viewportWidth: scrollView.contentSize.width)
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsFirstResponder else {
            super.mouseDown(with: event)
            return
        }
        _ = window?.makeFirstResponder(self)
        setActive(true)
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    /// The workbench may route keys here even when its nonactivating panel
    /// cannot become key. Returns whether the event belongs to the rail.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard acceptsFirstResponder else { return false }
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(disallowed).isEmpty else { return false }

        switch event.keyCode {
        case 123: // left arrow
            setActive(true)
            _ = model.moveSelection(delta: -1)
            scrollSelectedIntoView()
            return true
        case 124: // right arrow
            setActive(true)
            _ = model.moveSelection(delta: 1)
            scrollSelectedIntoView()
            return true
        case 36, 76: // Return / keypad Enter
            _ = activateSelectedItem()
            return true
        case 51, 117: // Backspace / forward Delete
            _ = deleteSelectedItem()
            return true
        default:
            return false
        }
    }

    /// Visual keyboard ownership is separate from capture eligibility. The
    /// protected and disabled states always win over the requested active state.
    func setActive(_ active: Bool) {
        guard isRailActive != active else { return }
        isRailActive = active
        reloadFromModel()
    }

    /// Convenience forwarding API for the future Buffer workbench owner.
    func start() {
        model.start()
    }

    func stop() {
        model.stop()
    }

    func update(workbenchVisible: Bool,
                railEnabled: Bool,
                protection: ClipboardHistoryProtection) {
        model.update(
            workbenchVisible: workbenchVisible,
            railEnabled: railEnabled,
            protection: protection
        )
    }

    @discardableResult
    func activateSelectedItem() -> Bool {
        guard acceptsFirstResponder,
              let item = model.selectedItem,
              let onAddToBuffer,
              onAddToBuffer(item) else {
            return false
        }
        return model.promote(id: item.id)
    }

    /// Entry point for a future shelf Delete button; keyboard deletion routes
    /// through the same protected-state check in the model.
    @discardableResult
    func deleteSelectedItem() -> Bool {
        model.deleteSelected()
    }

    /// Force a visual refresh after the parent changes workbench chrome or its
    /// own active-section state.
    func reloadFromModel() {
        let protectedContent = model.isContentShielded
        let captureEnabled = model.isStarted
            && model.captureState.workbenchVisible
            && model.captureState.railEnabled
        let active = isRailActive && captureEnabled && !protectedContent

        applyRailAppearance(active: active, protectedContent: protectedContent)

        guard captureEnabled, !protectedContent else {
            removeAllCards()
            showState(message: stateMessage(), protectedContent: protectedContent, active: false)
            return
        }

        let visibleItems = model.visibleItems
        guard !visibleItems.isEmpty else {
            removeAllCards()
            showState(message: "剪贴板历史为空", protectedContent: false, active: active)
            return
        }

        stateContainer.isHidden = true
        scrollView.isHidden = false
        reconcileCards(items: visibleItems, active: active)
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollSelectedIntoView()
    }

    func snapshotForSmoke() -> ClipboardRailViewSnapshot {
        let buttons = cardDocumentView.cards
        let selectedBorder = buttons.first(where: { $0.itemID == model.selectedID })?
            .renderedBorderWidth
        return ClipboardRailViewSnapshot(
            railHeight: ClipboardRailMetrics.railHeight,
            cardCount: buttons.count,
            cardHeight: buttons.first?.frame.height ?? ClipboardRailMetrics.cardHeight,
            widestCardWidth: buttons.map(\.frame.width).max() ?? 0,
            selectedCardBorderWidth: selectedBorder,
            isActive: isRailActive && acceptsFirstResponder,
            isProtected: model.isContentShielded,
            stateIsVisible: !stateContainer.isHidden
        )
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("剪贴板历史卡片")

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = cardDocumentView
        addSubview(scrollView)

        stateIcon.imageScaling = .scaleProportionallyDown
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 10)
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.maximumNumberOfLines = 1
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        let stateStack = NSStackView(views: [stateIcon, stateLabel])
        stateStack.orientation = .horizontal
        stateStack.alignment = .centerY
        stateStack.spacing = 6
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor),
            stateStack.leadingAnchor.constraint(greaterThanOrEqualTo: stateContainer.leadingAnchor),
            stateStack.trailingAnchor.constraint(lessThanOrEqualTo: stateContainer.trailingAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 14),
            stateIcon.heightAnchor.constraint(equalToConstant: 14),
        ])
        addSubview(stateContainer)
    }

    private func reconcileCards(items: [ClipboardHistoryItem], active: Bool) {
        let validIDs = Set(items.map(\.id))
        let staleIDs = cardButtons.keys.filter { !validIDs.contains($0) }
        for id in staleIDs {
            cardButtons.removeValue(forKey: id)?.removeFromSuperview()
        }

        let orderedButtons = items.map { item -> ClipboardCardButton in
            let button: ClipboardCardButton
            if let existing = cardButtons[item.id] {
                button = existing
            } else {
                button = ClipboardCardButton(itemID: item.id)
                button.target = self
                button.action = #selector(cardPressed(_:))
                cardButtons[item.id] = button
            }
            button.update(
                text: item.text,
                selected: item.id == model.selectedID,
                railActive: active
            )
            return button
        }
        cardDocumentView.setCards(orderedButtons, viewportWidth: scrollView.contentSize.width)
    }

    private func removeAllCards() {
        cardButtons.values.forEach { $0.removeFromSuperview() }
        cardButtons.removeAll(keepingCapacity: false)
        cardDocumentView.setCards([], viewportWidth: scrollView.contentSize.width)
        scrollView.isHidden = true
    }

    @objc private func cardPressed(_ sender: ClipboardCardButton) {
        guard acceptsFirstResponder else { return }
        _ = window?.makeFirstResponder(self)
        setActive(true)
        guard model.select(id: sender.itemID) else { return }
        if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
            _ = activateSelectedItem()
        }
    }

    private func scrollSelectedIntoView() {
        guard let selectedID = model.selectedID,
              let card = cardButtons[selectedID],
              !scrollView.isHidden else { return }
        let visible = scrollView.documentVisibleRect
        let targetX: CGFloat
        if card.frame.width >= visible.width || card.frame.minX < visible.minX {
            targetX = card.frame.minX
        } else if card.frame.maxX > visible.maxX {
            targetX = card.frame.maxX - visible.width
        } else {
            return
        }

        let maximumX = max(0, cardDocumentView.frame.width - visible.width)
        let target = NSPoint(
            x: min(max(0, targetX), maximumX),
            y: scrollView.contentView.bounds.origin.y
        )
        if window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(target)
        }
    }

    private func stateMessage() -> String {
        let protection = model.activeProtection
        if protection.contains(.secureInput) {
            return "安全输入期间剪贴板历史已遮蔽"
        }
        if protection.contains(.screenLocked) {
            return "屏幕锁定期间剪贴板历史已遮蔽"
        }
        if protection.contains(.sessionInactive) {
            return "会话受保护，剪贴板历史已遮蔽"
        }
        if !model.captureState.railEnabled {
            return "剪贴板历史已关闭"
        }
        if !model.captureState.workbenchVisible {
            return "工作台隐藏时不会读取剪贴板"
        }
        if !model.isStarted {
            return "剪贴板历史尚未启动"
        }
        return "剪贴板历史为空"
    }

    private func showState(message: String,
                           protectedContent: Bool,
                           active: Bool) {
        stateLabel.stringValue = message
        let color: NSColor
        let iconName: String
        if protectedContent {
            color = ClipboardRailPalette.warningText
            iconName = "lock.fill"
        } else if active {
            color = RimeUI.accentTextColor
            iconName = "clipboard"
        } else {
            color = RimeUI.textMuted
            iconName = "clipboard"
        }
        stateLabel.textColor = color
        stateIcon.image = RimeUI.symbol(iconName, pointSize: 14, weight: .bold)
        stateIcon.image?.isTemplate = true
        stateIcon.contentTintColor = color
        stateContainer.isHidden = false
        scrollView.isHidden = true
        setAccessibilityHelp(message)
    }

    private func applyRailAppearance(active: Bool, protectedContent: Bool) {
        appearance = RimeUI.appKitAppearance
        if protectedContent {
            layer?.backgroundColor = RimeUI.surface2.cgColor
            layer?.borderColor = RimeUI.borderStrong.cgColor
        } else if active {
            layer?.backgroundColor = ClipboardRailPalette.bufferTargetRail.cgColor
            layer?.borderColor = RimeUI.accentTextColor.cgColor
        } else if model.isStarted
                    && model.captureState.workbenchVisible
                    && model.captureState.railEnabled {
            layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
            layer?.borderColor = RimeUI.borderStrong.cgColor
        } else {
            layer?.backgroundColor = RimeUI.surface2.cgColor
            layer?.borderColor = RimeUI.borderStrong.cgColor
        }
        layer?.borderWidth = 1
    }
}

private enum ClipboardRailPalette {
    static var bufferTargetRail: NSColor {
        switch RimeUI.appearance {
        case .night: return RimeUI.color(0x122A21)
        case .day: return RimeUI.color(0xE7F6EF)
        case .quiet: return RimeUI.color(0x272727)
        }
    }

    static var clipboardSelected: NSColor {
        switch RimeUI.appearance {
        case .night: return RimeUI.color(0x1A4430)
        case .day: return RimeUI.color(0xCDEBDE)
        case .quiet: return RimeUI.color(0x3C3C3C)
        }
    }

    static var warningText: NSColor {
        switch RimeUI.appearance {
        case .night, .quiet: return RimeUI.color(0xFF9230)
        case .day: return RimeUI.color(0x8A4B00)
        }
    }
}

private final class ClipboardCardDocumentView: NSView {
    private(set) var cards: [ClipboardCardButton] = []

    override var isFlipped: Bool { true }

    func setCards(_ cards: [ClipboardCardButton], viewportWidth: CGFloat) {
        self.cards = cards
        for card in cards where card.superview !== self {
            addSubview(card)
        }
        layoutCards(viewportWidth: viewportWidth)
    }

    func layoutCards(viewportWidth: CGFloat) {
        var x: CGFloat = 0
        for card in cards {
            let width = card.preferredCardWidth
            card.frame = NSRect(
                x: x,
                y: 0,
                width: width,
                height: ClipboardRailMetrics.cardHeight
            )
            x += width + ClipboardRailMetrics.cardSpacing
        }
        let contentWidth = cards.isEmpty ? 0 : x - ClipboardRailMetrics.cardSpacing
        frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewportWidth, contentWidth),
            height: ClipboardRailMetrics.cardHeight
        )
    }
}

private final class ClipboardHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.shift),
              abs(event.scrollingDeltaX) < 0.01,
              abs(event.scrollingDeltaY) >= 0.01,
              let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let maximumX = max(0, documentView.frame.width - contentSize.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x + event.scrollingDeltaY), maximumX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

private final class ClipboardCardButton: NSButton {
    let itemID: UUID
    private let valueLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isSelectedItem = false
    private var isRailActive = false
    private(set) var preferredCardWidth: CGFloat = 28
    private(set) var renderedBorderWidth: CGFloat = 1

    init(itemID: UUID) {
        self.itemID = itemID
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = ClipboardRailMetrics.cardCornerRadius
        layer?.masksToBounds = true

        valueLabel.font = .systemFont(ofSize: 10)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setAccessibilityElement(false)
        addSubview(valueLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        valueLabel.frame = bounds.insetBy(
            dx: ClipboardRailMetrics.cardHorizontalInset,
            dy: 1
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let replacement = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(replacement)
        trackingArea = replacement
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func update(text: String, selected: Bool, railActive: Bool) {
        let preview = Self.boundedPreview(
            text,
            maximumCharacters: ClipboardRailMetrics.previewCharacterLimit
        )
        let accessiblePreview = Self.boundedPreview(
            text,
            maximumCharacters: ClipboardRailMetrics.accessibilityCharacterLimit
        )
        valueLabel.stringValue = preview
        toolTip = accessiblePreview
        setAccessibilityLabel(accessiblePreview)
        setAccessibilityHelp(selected ? "已选择；双击加入 Buffer" : "单击选择；双击加入 Buffer")
        setAccessibilitySelected(selected)
        isSelectedItem = selected
        isRailActive = railActive

        let measured = ceil((preview as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10),
        ]).width) + ClipboardRailMetrics.cardHorizontalInset * 2
        preferredCardWidth = min(
            ClipboardRailMetrics.maximumCardWidth,
            max(28, measured)
        )
        applyAppearance()
    }

    private func applyAppearance() {
        let foreground: NSColor
        let background: NSColor
        let border: NSColor
        let borderWidth: CGFloat

        if isSelectedItem && isRailActive {
            foreground = RimeUI.selectedCandidateTextColor
            background = RimeUI.selectedCandidateBackgroundColor
            border = RimeUI.selectedCandidateTextColor
            borderWidth = 2
        } else if isSelectedItem {
            foreground = RimeUI.textPrimary
            background = ClipboardRailPalette.clipboardSelected
            border = RimeUI.accentTextColor
            borderWidth = 1
        } else if isHovered {
            foreground = RimeUI.textPrimary
            background = RimeUI.surface3
            border = RimeUI.borderStrong
            borderWidth = 1
        } else {
            foreground = RimeUI.textPrimary
            background = RimeUI.surface2
            border = RimeUI.border
            borderWidth = 1
        }

        valueLabel.textColor = foreground
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = borderWidth
        renderedBorderWidth = borderWidth
    }

    private static func boundedPreview(_ text: String,
                                       maximumCharacters: Int) -> String {
        let normalized = text.replacingOccurrences(
            of: "[\\r\\n\\t]+",
            with: " ",
            options: .regularExpression
        )
        guard normalized.count > maximumCharacters else { return normalized }
        return String(normalized.prefix(maximumCharacters)) + "…"
    }
}
