import Cocoa
import Carbon.HIToolbox
import QuartzCore

enum BufferCandidatePlacement: String, CaseIterable {
    case workbench
    case caret

    var title: String {
        switch self {
        case .workbench: return "显示在缓冲条下方"
        case .caret: return "跟随输入光标"
        }
    }
}

enum BufferWorkbenchLayoutMode: Equatable {
    case standard
    case singleDerived
    case derived(targetRows: Int)

    static let translation = BufferWorkbenchLayoutMode.derived(targetRows: 1)

    var targetRows: Int? {
        switch self {
        case .standard: return nil
        case .singleDerived: return 1
        case let .derived(targetRows): return min(max(targetRows, 1), 3)
        }
    }
}

/// Pure frame math shared by runtime restoration and the CLI smoke test.
enum BufferWindowGeometry {
    static let standardMinimumWidth: CGFloat = 520
    static let standardMaximumWidth: CGFloat = 1100
    static let collapsedHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 78
    static let translationCollapsedHeight: CGFloat = 78
    static let translationExpandedHeight: CGFloat = 112
    static let standardMinimumHeight = expandedHeight
    static let screenSafetyMargin: CGFloat = 8

    static func height(expanded: Bool,
                       mode: BufferWorkbenchLayoutMode = .standard) -> CGFloat {
        switch mode {
        case .standard, .singleDerived:
            return expanded ? expandedHeight : collapsedHeight
        case let .derived(targetRows):
            let extra = CGFloat(min(max(targetRows, 1), 3) - 1)
                * BufferInlineView.additionalTranslationTargetRowHeight
            return (expanded ? translationExpandedHeight : translationCollapsedHeight)
                + extra
        }
    }

    static func clampedFrame(_ proposed: NSRect,
                             expanded: Bool = true,
                             mode: BufferWorkbenchLayoutMode = .standard,
                             visibleFrames: [NSRect],
                             fallback: NSRect) -> NSRect {
        let screens = visibleFrames.isEmpty ? [fallback] : visibleFrames
        let target = screens.max { lhs, rhs in
            intersectionArea(proposed, lhs) < intersectionArea(proposed, rhs)
        }.flatMap { intersectionArea(proposed, $0) > 0 ? $0 : nil } ?? fallback

        let horizontalMargin = min(screenSafetyMargin, max(0, (target.width - 1) / 2))
        let verticalMargin = min(screenSafetyMargin, max(0, (target.height - 1) / 2))
        let safeTarget = target.insetBy(dx: horizontalMargin, dy: verticalMargin)
        let minimumWidth = min(standardMinimumWidth, safeTarget.width)
        let maximumWidth = min(standardMaximumWidth, safeTarget.width)
        let width = min(max(proposed.width, minimumWidth), maximumWidth)
        let height = min(height(expanded: expanded, mode: mode), safeTarget.height)
        var x = proposed.width == width ? proposed.minX : proposed.midX - width / 2
        // The 52pt predecessor and both current states preserve their bottom
        // edge, keeping the candidate panel stationary. Only the legacy 340pt
        // workbench migrates by preserving its old top edge.
        let maximumCurrentExpandedHeight = Self.height(
            expanded: true,
            mode: .derived(targetRows: 3)
        )
        var y = proposed.height <= maximumCurrentExpandedHeight + 1
            ? proposed.minY
            : proposed.maxY - height
        if proposed == .zero || intersectionArea(proposed, target) == 0 {
            x = safeTarget.midX - width / 2
            y = safeTarget.midY - height / 2
        }
        x = min(max(x, safeTarget.minX), max(safeTarget.minX, safeTarget.maxX - width))
        y = min(max(y, safeTarget.minY), max(safeTarget.minY, safeTarget.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func candidateAnchor(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 8,
               y: frame.minY,
               width: max(4, frame.width - 16),
               height: frame.height)
    }

    static func pixelAligned(_ frame: NSRect, scale: CGFloat) -> NSRect {
        guard scale > 0 else { return frame }
        func aligned(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        return NSRect(x: aligned(frame.minX),
                      y: aligned(frame.minY),
                      width: aligned(frame.width),
                      height: aligned(frame.height))
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}

/// `NSWindow.isVisible` means ordered, not necessarily visible on the active
/// macOS Space. Candidate routing and menu actions need the latter meaning or
/// an unpinned workbench left on another Space can swallow the caret panel.
enum BufferWindowVisibilityRules {
    static func isVisibleOnActiveSpace(isOrdered: Bool,
                                       isOnActiveSpace: Bool) -> Bool {
        isOrdered && isOnActiveSpace
    }
}

enum BufferWorkbenchControl: String, Equatable {
    case bufferRail
    case send
    case status
    case pluginActions
    case refresh
    case close
}

enum BufferMainControlRow: Equatable {
    case source
    case target
}

enum BufferWorkbenchCursorKind: Equatable {
    case arrow
    case pointingHand

    var cursor: NSCursor {
        switch self {
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        }
    }
}

enum BufferWorkbenchPointerState: Equatable {
    case idle
    case hovered
    case pressed
    case disabled
}

enum BufferWorkbenchToolbarPointerDisposition: Equatable {
    case dragWindow
    case interactWithControl
}

/// Empty toolbar chrome moves the workbench, while controls keep their normal
/// first-click behavior inside the nonactivating panel.
enum BufferWorkbenchToolbarDragRules {
    static func disposition(
        hitIsInteractiveControl: Bool
    ) -> BufferWorkbenchToolbarPointerDisposition {
        hitIsInteractiveControl ? .interactWithControl : .dragWindow
    }
}

/// Pure pointer-state policy shared by buttons, popups, and
/// `buffer-window-smoke`. The workbench is nonactivating, so AppKit does not
/// reliably synthesize these states for borderless controls on its own.
enum BufferWorkbenchPointerRules {
    static func state(enabled: Bool, hovered: Bool,
                      pressed: Bool) -> BufferWorkbenchPointerState {
        if !enabled { return .disabled }
        if pressed { return .pressed }
        if hovered { return .hovered }
        return .idle
    }

    static func cursor(enabled: Bool) -> BufferWorkbenchCursorKind {
        enabled ? .pointingHand : .arrow
    }

    static func backgroundColor(for state: BufferWorkbenchPointerState) -> NSColor {
        switch state {
        case .idle, .disabled:
            return .clear
        case .hovered:
            return RimeUI.accentBlue.withAlphaComponent(RimeUI.isNight ? 0.20 : 0.13)
        case .pressed:
            return RimeUI.accentBlue.withAlphaComponent(RimeUI.isNight ? 0.34 : 0.23)
        }
    }

    static func borderColor(for state: BufferWorkbenchPointerState) -> NSColor {
        switch state {
        case .idle, .disabled:
            return .clear
        case .hovered:
            return RimeUI.accentBlue.withAlphaComponent(0.48)
        case .pressed:
            return RimeUI.accentBlue.withAlphaComponent(0.78)
        }
    }
}

enum BufferWorkbenchMetrics {
    static let controlSize: CGFloat = 22
    static let mainSpacing: CGFloat = 3
    static let shelfSpacing: CGFloat = 4
    static let mainHorizontalInset: CGFloat = 5
    static let shelfHorizontalInset: CGFloat = 6
    static let shelfStatusWidth: CGFloat = 88
    static let translationVerticalInset: CGFloat = 5
    static let translationRailSpacing: CGFloat = 4

    static func railHeight(for mode: BufferWorkbenchLayoutMode) -> CGFloat {
        switch mode {
        case .standard, .singleDerived:
            return BufferInlineView.standardPreferredHeight
        case let .derived(targetRows):
            return BufferInlineView.translationPreferredHeight(targetRows: targetRows)
        }
    }

    static func mainBarHeight(for mode: BufferWorkbenchLayoutMode) -> CGFloat {
        mode.targetRows == nil ? 40 : railHeight(for: mode) + 6
    }

    /// Translation renders two equal rails inside a 5pt vertical inset with a
    /// 4pt separator. Main controls use the same centers so their hit targets,
    /// not just their artwork, line up with the source and target rows.
    static func mainControlYOffset(row: BufferMainControlRow,
                                   mode: BufferWorkbenchLayoutMode) -> CGFloat {
        guard case let .derived(targetRows) = mode else { return 0 }
        let normalizedTargetRows = min(max(targetRows, 1), 3)
        let offset = BufferInlineView.additionalTranslationTargetRowHeight
            * CGFloat(normalizedTargetRows) / 2
        // NSStackView lays this main bar out in a flipped view coordinate
        // system: the visually upper source row has the negative constant.
        return row == .source ? -offset : offset
    }
}

/// Pins the status and plugin controls to the leading edge while one dedicated
/// spacer absorbs every width change. Without that spacer, AppKit alternates
/// between stretching the empty plugin row and stretching the status label,
/// which makes the plugin menu jump between the left and right sides.
enum BufferWorkbenchShelfLayout {
    static let flexiblePriority = NSLayoutConstraint.Priority(rawValue: 1)
    static let statusWidthPriority = NSLayoutConstraint.Priority(rawValue: 749)

    static func configure(_ shelf: NSStackView,
                          status: NSView,
                          pluginActions: NSView,
                          flexibleSpace: NSView,
                          statusIndicators: NSView,
                          refresh: NSView,
                          close: NSView) {
        shelf.orientation = .horizontal
        shelf.alignment = .centerY
        shelf.distribution = .fill
        shelf.spacing = BufferWorkbenchMetrics.shelfSpacing
        shelf.detachesHiddenViews = false
        shelf.userInterfaceLayoutDirection = .leftToRight
        shelf.edgeInsets = NSEdgeInsets(
            top: 4,
            left: BufferWorkbenchMetrics.shelfHorizontalInset,
            bottom: 4,
            right: BufferWorkbenchMetrics.shelfHorizontalInset
        )

        status.translatesAutoresizingMaskIntoConstraints = false
        let statusWidth = status.widthAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.shelfStatusWidth
        )
        // Tiny screens may be narrower than the ordinary 520pt minimum, so
        // this stable column yields before the required translation controls.
        statusWidth.priority = statusWidthPriority
        statusWidth.isActive = true

        flexibleSpace.setContentHuggingPriority(flexiblePriority, for: .horizontal)
        flexibleSpace.setContentCompressionResistancePriority(flexiblePriority,
                                                              for: .horizontal)

        [status, pluginActions, flexibleSpace, statusIndicators, refresh, close].forEach {
            shelf.addArrangedSubview($0)
        }
    }
}

/// Shared by the live stack construction and the pure layout smoke test.
enum BufferWorkbenchLayout {
    static let mainBar: [BufferWorkbenchControl] = [
        .bufferRail, .send,
    ]
    static let toolbar: [BufferWorkbenchControl] = [
        .status, .pluginActions, .refresh, .close,
    ]
    static let hoverControls: Set<BufferWorkbenchControl> = [
        .send, .pluginActions, .refresh, .close,
    ]
    static let passiveControls: Set<BufferWorkbenchControl> = [.bufferRail, .status]
    static let toolbarAlwaysExpanded = true
    static let toolbarEmptySpaceDraggable = true
    static let windowBackgroundDraggable = false
}

enum BufferWorkbenchStatusText {
    static func text(for availability: BufferDeliveryCoordinator.Availability,
                     secureInput: Bool,
                     pluginFailure: String? = nil,
                     canGenerateWithoutFocus: Bool = false) -> String {
        if secureInput { return "安全输入，内容已隐藏" }
        if let pluginFailure = normalized(pluginFailure) { return pluginFailure }
        switch availability {
        case .ready:
            return "可发送"
        case let .blocked(reason):
            switch reason {
            case .noFocusedField:
                return canGenerateWithoutFocus
                    ? "可生成 · 发送前点选输入框"
                    : "等待输入框"
            case .composing: return "正在组字"
            case .secureInput: return "安全输入，内容已隐藏"
            case .nothingPending: return "等待内容"
            case .targetChanged: return "焦点已变化"
            case .deliveryRejected: return "发送失败"
            case .validatingPluginTarget: return "正在确认目标"
            case .stalePluginResult: return "插件结果已过期"
            case .pluginTargetChanged: return "评论目标已变化"
            case .pluginUnavailable: return "插件暂不可用"
            case .pluginResultIncomplete: return "插件正在生成"
            case .contentChanged: return "内容已变化"
            }
        }
    }

    static func help(for availability: BufferDeliveryCoordinator.Availability,
                     secureInput: Bool,
                     pluginFailure: String? = nil,
                     canGenerateWithoutFocus: Bool = false) -> String {
        if secureInput { return "安全输入已开启，缓冲内容已隐藏且不能发送" }
        if let pluginFailure = normalized(pluginFailure) {
            if pluginFailure.contains("未保存") {
                return "后台插件结果未进入收信箱；请清理收信箱后重新生成"
            }
            return "插件生成没有完成，请重新生成"
        }
        switch availability {
        case .ready:
            return "当前输入框可以接收缓冲内容"
        case let .blocked(reason):
            if reason == .noFocusedField, canGenerateWithoutFocus {
                return "可以先生成内容；发送前请点选要接收文字的外部输入框"
            }
            return reason.message
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private final class BufferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class BufferWorkbenchToolbarView: NSStackView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let control = interactiveControl(containing: hit)
        switch BufferWorkbenchToolbarDragRules.disposition(
            hitIsInteractiveControl: control != nil
        ) {
        case .dragWindow:
            return self
        case .interactWithControl:
            return control
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    private func interactiveControl(containing hit: NSView) -> NSControl? {
        var view: NSView? = hit
        while let current = view, current !== self {
            if let control = current as? NSControl {
                return control
            }
            view = current.superview
        }
        return nil
    }

    static func runHitTestProbe() -> Bool {
        let toolbar = BufferWorkbenchToolbarView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 32)
        )
        let button = NSButton(
            frame: NSRect(x: 8, y: 5, width: 40, height: 22)
        )
        let status = NSTextField(labelWithString: "状态")
        status.frame = NSRect(x: 56, y: 5, width: 48, height: 22)
        let emptySpace = NSView(
            frame: NSRect(x: 112, y: 5, width: 100, height: 22)
        )
        toolbar.addSubview(button)
        toolbar.addSubview(status)
        toolbar.addSubview(emptySpace)
        return toolbar.acceptsFirstMouse(for: nil)
            && toolbar.hitTest(NSPoint(x: 20, y: 16)) === button
            && toolbar.hitTest(NSPoint(x: 70, y: 16)) === status
            && toolbar.hitTest(NSPoint(x: 150, y: 16)) === toolbar
            && toolbar.hitTest(NSPoint(x: 220, y: 16)) === toolbar
    }
}

func runBufferWorkbenchToolbarHitTestProbe() -> Bool {
    BufferWorkbenchToolbarView.runHitTestProbe()
}

private final class FirstMousePopUpButton: NSPopUpButton {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerHovered = false
    private var pointerPressed = false
    private var previewPointerState: BufferWorkbenchPointerState?

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { pointerPressed = false }
            refreshInteractionAppearance()
        }
    }

    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        configurePointerFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePointerFeedback()
    }

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
        addCursorRect(bounds, cursor: BufferWorkbenchPointerRules.cursor(
            enabled: isEnabled
        ).cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerHovered = true
        refreshInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerHovered = false
        refreshInteractionAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pointerPressed = true
        refreshInteractionAppearance()
        defer {
            pointerPressed = false
            refreshInteractionAppearance()
        }
        super.mouseDown(with: event)
    }

    func refreshInteractionAppearance() {
        let state = previewPointerState ?? BufferWorkbenchPointerRules.state(
            enabled: isEnabled,
            hovered: pointerHovered,
            pressed: pointerPressed
        )
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = BufferWorkbenchPointerRules.backgroundColor(for: state).cgColor
        layer?.borderColor = BufferWorkbenchPointerRules.borderColor(for: state).cgColor
        layer?.borderWidth = (state == .idle || state == .disabled)
            ? 0
            : 1 / max(window?.backingScaleFactor ?? 2, 1)
        window?.invalidateCursorRects(for: self)
    }

    func setPreviewPointerState(_ state: BufferWorkbenchPointerState?) {
        previewPointerState = state
        refreshInteractionAppearance()
    }

    private func configurePointerFeedback() {
        wantsLayer = true
        layer?.masksToBounds = true
        refreshInteractionAppearance()
    }
}

/// `NSMenuItem.representedObject` cannot distinguish a missing value from an
/// object whose raw identifier happens to match another plugin domain. Keep
/// the complete namespaced key in one small reference box instead of relying
/// on menu indices or integer tags.
private final class BufferPluginMenuIdentity: NSObject {
    let key: PluginKey?

    init(_ key: PluginKey?) {
        self.key = key
    }
}

private final class BufferMainControlSlot: NSView {
    private let row: BufferMainControlRow
    private var heightConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!

    init(control: NSView, row: BufferMainControlRow) {
        self.row = row
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        let height = heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.railHeight(for: .standard)
        )
        let centerY = control.centerYAnchor.constraint(equalTo: centerYAnchor)
        heightConstraint = height
        centerYConstraint = centerY
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            height,
            control.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(for mode: BufferWorkbenchLayoutMode) {
        heightConstraint.constant = BufferWorkbenchMetrics.railHeight(for: mode)
        centerYConstraint.constant = BufferWorkbenchMetrics.mainControlYOffset(row: row,
                                                                                mode: mode)
    }
}

private final class BufferWorkbenchStatusIndicatorView: NSStackView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var tone: WorkbenchStatusIndicatorTone = .inactive

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 3
        edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        dot.layer?.cornerRadius = 2.5
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh,
                                                       for: .horizontal)
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ indicator: WorkbenchStatusIndicator) {
        tone = indicator.tone
        label.stringValue = indicator.text
        toolTip = indicator.detail
        label.toolTip = indicator.detail
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(indicator.text)
        setAccessibilityHelp(indicator.detail)
        applyAppearance()
    }

    func applyAppearance() {
        let color: NSColor
        switch tone {
        case .healthy: color = .systemGreen
        case .warning: color = .systemOrange
        case .inactive: color = RimeUI.textMuted
        }
        dot.layer?.backgroundColor = color.cgColor
        label.textColor = tone == .inactive ? RimeUI.textMuted : RimeUI.textSecondary
        layer?.backgroundColor = RimeUI.surface2.withAlphaComponent(0.74).cgColor
        layer?.borderColor = RimeUI.border.cgColor
        layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
    }
}

/// Keeps an action bound to its declarative identity instead of to a mutable
/// array index. Status polling may update titles/enabled state every second;
/// the button itself must remain in place while that happens.
private final class BufferPluginActionButton: FirstMouseButton {
    var pluginKey: ActionPluginKey?
}

/// The material clips to a continuous rounded rect while a separate inset
/// hairline remains fully inside the backing pixels. Keeping the stroke away
/// from the window boundary prevents the half-clipped fringe seen on Retina.
private final class BufferChromeView: NSVisualEffectView {
    private let fillLayer = CALayer()
    private let strokeLayer = CAShapeLayer()
    var fillColor: NSColor = .windowBackgroundColor {
        didSet { fillLayer.backgroundColor = fillColor.cgColor }
    }
    var strokeColor: NSColor = .separatorColor {
        didSet { strokeLayer.strokeColor = strokeColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        fillLayer.backgroundColor = fillColor.cgColor
        layer?.addSublayer(fillLayer)
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = strokeColor.cgColor
        strokeLayer.zPosition = 100
        layer?.addSublayer(strokeLayer)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(scale, 1)
        strokeLayer.contentsScale = scale
        fillLayer.contentsScale = scale
        fillLayer.frame = bounds
        strokeLayer.frame = bounds
        strokeLayer.lineWidth = lineWidth
        strokeLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: max(0, 9 - lineWidth / 2),
            cornerHeight: max(0, 9 - lineWidth / 2),
            transform: nil
        )
    }
}

/// Stable, nonactivating workbench window. It owns presentation only; all text
/// delivery still flows through BufferDeliveryCoordinator -> Delivery.insert.
final class BufferWindowController: NSObject, NSWindowDelegate {
    static let shared = BufferWindowController()

    private enum Key {
        static let visible = "bufferWindow.visible.v1"
        static let frame = "bufferWindow.frame.v2"
        static let legacyFrame = "bufferWindow.frame.v1"
        static let pinned = "bufferWindow.pinned.v1"
        static let placement = "bufferWindow.candidatePlacement.v1"
    }

    private let panel: BufferPanel
    private let outerContainer = NSView()
    private let visual = BufferChromeView()
    private let bufferRail = BufferInlineView()
    private lazy var translationBridgeView = AppleTranslationWorkspace.shared.makeBridgeView()
    private let utilityShelf = BufferWorkbenchToolbarView()
    private let shelfDivider = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pluginActionsControl = NSStackView()
    private let shelfFlexibleSpace = NSView()
    private let contextualStatusControl = NSStackView()
    private let pluginSelector = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let pluginLoadingIndicator = NSProgressIndicator()
    private let pluginButtonRow = NSStackView()
    private let builtInActionButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let builtInActionOptionPopup = FirstMousePopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let translationSourcePopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let translationTargetPopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let translationSwapButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let sendButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let sendButtonProgressIndicator = NSProgressIndicator()
    private let refreshButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private lazy var sendSlot = BufferMainControlSlot(control: sendButton, row: .target)
    private var hiddenForSession = false
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var adjustingFrame = false
    private var layoutMode: BufferWorkbenchLayoutMode = .standard
    private var mainBarHeightConstraint: NSLayoutConstraint?
    private var bufferRailHeightConstraint: NSLayoutConstraint?
    private var observers: [NSObjectProtocol] = []
    private var secureInputPollTimer: Timer?
    private var pluginStatusPollTimer: Timer?
    private var pluginSelectorRefreshScheduled = false
    private var lastSecureInputState = IsSecureEventInputEnabled()
    private var renderedPluginKeys: [ActionPluginPresentationKey] = []
    private var pluginActionButtons: [ActionPluginPresentationKey: BufferPluginActionButton] = [:]
    private var contextualStatusViews: [String: BufferWorkbenchStatusIndicatorView] = [:]
    private var renderingTranslationControls = false
    private var renderingAIControls = false
    private var renderingBuiltInActionControls = false
    private var renderedBuiltInActionHasOptions: Bool?
    private var renderedTranslationLanguages: [TranslationLanguageOption] = []
    private var renderedBuiltInActionOptions: [BuiltInBufferActionOption] = []
    private var sendButtonUsesAccent = false

    var isVisible: Bool {
        BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace
        )
    }
    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Key.pinned) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pinned)
            applyCollectionBehavior()
            refresh()
        }
    }
    var candidatePlacement: BufferCandidatePlacement {
        get {
            let raw = UserDefaults.standard.string(forKey: Key.placement)
            return raw.flatMap(BufferCandidatePlacement.init(rawValue:)) ?? .workbench
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.placement)
            RimeBufferController.refreshActiveUI()
            refresh()
        }
    }
    var shouldProjectCandidates: Bool {
        isVisible && !hiddenForSession && candidatePlacement == .workbench
    }
    var candidateAnchorRect: NSRect? {
        guard shouldProjectCandidates,
              !IsSecureEventInputEnabled(),
              !sessionProtectionActive else { return nil }
        return BufferWindowGeometry.candidateAnchor(for: panel.frame)
    }

    private override init() {
        let initialSnapshot = DerivedBufferWorkspaceRouter.selectedWorkspace?
            .railSnapshot
        let initialLayoutMode: BufferWorkbenchLayoutMode = initialSnapshot.map {
            $0.showsSourceRail
                ? .derived(targetRows: $0.targetRowCount)
                : .singleDerived
        } ?? .standard
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 760,
                                                height: BufferWindowGeometry.height(
                                                    expanded: BufferWorkbenchLayout
                                                        .toolbarAlwaysExpanded,
                                                    mode: initialLayoutMode
                                                )),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered,
                            defer: false)
        super.init()
        layoutMode = initialLayoutMode
        bufferRail.onDerivedTargetSelection = { [weak self] blockID in
            self?.selectDerivedTarget(blockID: blockID)
        }
        buildWindow()
        restoreFrame()
        installObservers()
    }

    func showOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: Key.visible) == nil
            ? BufferModel.shared.enabled
            : defaults.bool(forKey: Key.visible)
        if visible { show() }
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Key.visible)
        guard !sessionProtectionActive else {
            hiddenForSession = true
            return
        }
        hiddenForSession = false
        ActionPluginHost.shared.refreshStatuses(force: true)
        clampFrameToScreens()
        refresh()
        // Re-ordering is required for an unpinned panel that is still ordered
        // on another Space. `.moveToActiveSpace` applies when it is ordered
        // again; simply calling orderFront on the old ordered window may leave
        // it attached to the old Space.
        if panel.isVisible, !panel.isOnActiveSpace, !pinned {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
        RimeBufferController.refreshActiveUI()
    }

    /// Explicit user-facing open actions resume capture after a previous
    /// close-and-pause. Passive restoration still uses `show()` so it does not
    /// silently change the persisted buffer mode.
    func openAndResume() {
        BufferModel.shared.enabled = true
        show()
    }

    func hideWithoutPausing() {
        UserDefaults.standard.set(false, forKey: Key.visible)
        panel.orderOut(nil)
        RimeBufferController.refreshActiveUI()
    }

    /// The optional external-app privacy purge clears staged plaintext and all
    /// plugin state before a different application can become the target.
    func discardForPrivacyTransition() {
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BufferModel.shared.discardForPrivacy()
    }

    /// Product default: close means resolve the current composition into the
    /// buffer, pause capture, keep staged blocks, settle transient state, then hide.
    func closeAndPause() {
        if let target = InputFocusCoordinator.shared.owner,
           InputFocusCoordinator.shared.isCurrent(target.token),
           target.compositionActive {
            target.controller?.resolveCompositionForWorkbenchTransition(target: target)
        }
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BufferModel.shared.pauseCapturePreservingContent()
        hideWithoutPausing()
    }

    func toggleVisibility() {
        isVisible ? closeAndPause() : openAndResume()
    }

    func moveToCurrentScreen() {
        let point = NSEvent.mouseLocation
        let target = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = panel.frame
        frame.origin = NSPoint(x: target.midX - frame.width / 2,
                               y: target.midY - frame.height / 2)
        applyClampedFrame(frame,
                          visibleFrames: [target],
                          fallback: target,
                          display: true)
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    func setEnterHoldProgress(_ progress: Double?) {
        bufferRail.setEnterHoldProgress(progress)
    }

    /// Dev-only visual regression hook used by `panel-render`. Rendering the
    /// real controller prevents the preview and shipped workbench from drifting
    /// into two unrelated designs again.
    @discardableResult
    func renderForPreview(to path: String,
                          scale: CGFloat = 2,
                          translationSnapshot: TranslationRailSnapshot? = nil,
                          statusIndicators: [WorkbenchStatusIndicator]? = nil,
                          hoveredControl: BufferWorkbenchControl? = nil) -> Bool {
        let previewMode: BufferWorkbenchLayoutMode = translationSnapshot == nil
            ? DerivedBufferWorkspaceRouter.selectedWorkspace.map {
                let snapshot = $0.railSnapshot
                return snapshot.showsSourceRail
                    ? .derived(targetRows: snapshot.targetRowCount)
                    : .singleDerived
            } ?? .standard
            : (translationSnapshot?.showsSourceRail == false
                ? .singleDerived
                : .derived(targetRows: translationSnapshot?.targetRowCount ?? 1))
        syncLayoutMode(previewMode)
        adjustingFrame = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 760,
                              height: BufferWindowGeometry.height(
                                  expanded: BufferWorkbenchLayout
                                      .toolbarAlwaysExpanded,
                                  mode: previewMode
                              )),
                       display: false)
        adjustingFrame = false
        if let translationSnapshot {
            statusLabel.stringValue = translationSnapshot.showsSourceRail
                ? "译文可发送"
                : translationSnapshot.targetEmptyText
            _ = bufferRail.renderTranslationForPreview(translationSnapshot)
            applyAppearance()
        } else {
            refresh()
        }
        if let statusIndicators {
            reconcileContextualStatusIndicators(statusIndicators)
        }
        applyPreviewPointerState(hoveredControl)
        guard let contentView = panel.contentView else { return false }
        contentView.layoutSubtreeIfNeeded()
        let bounds = contentView.bounds
        let renderScale = max(1, scale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((bounds.width * renderScale).rounded()),
            pixelsHigh: Int((bounds.height * renderScale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let secureInputEnabled = IsSecureEventInputEnabled()
        let contentProtected = secureInputEnabled || sessionProtectionActive
        if contentProtected {
            BufferModel.shared.clearAllContentSelection(notify: false)
            // Scrub every text-bearing view before protection notifications or
            // frame changes can synchronously re-enter AppKit and repaint the
            // old source/candidates at a smaller layout.
            _ = bufferRail.refresh(
                shielded: true,
                translationSnapshot: nil
            )
        }
        pluginSelector.isEnabled = !contentProtected
        // Protect every stable derived singleton before resolving presentation
        // state. A secure refresh must not ask any source for a text snapshot.
        DerivedBufferWorkspaceRouter.setProtectedOnAll(contentProtected)
        BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(contentProtected)
        let derivedWorkspace = DerivedBufferWorkspaceRouter.selectedWorkspace
        let derivedWorkspaceSelected = derivedWorkspace != nil
        let builtInActionWorkspace = BuiltInBufferActionWorkspaceRouter.selectedWorkspace
        let builtInActionWorkspaceSelected = builtInActionWorkspace != nil
        // Never ask a protected workspace for plaintext merely to size the
        // panel. In the normal path this one frozen snapshot drives both
        // geometry and rendering so row count cannot tear across a refresh.
        let derivedSnapshot = contentProtected
            ? nil
            : derivedWorkspace?.railSnapshot
        let availability: BufferDeliveryCoordinator.Availability = contentProtected
            ? .blocked(.secureInput)
            : BufferDeliveryCoordinator.shared.availability()
        // Row reconciliation and panel geometry are one visual transaction.
        // Grow before attaching a new row; shrink only after stale rows have
        // been removed. Otherwise NSScrollView captures a 0pt/old document
        // frame and AppKit permanently breaks the third row's constraints.
        let nextLayoutMode: BufferWorkbenchLayoutMode = derivedWorkspaceSelected
            ? (derivedSnapshot?.showsSourceRail == false
                ? .singleDerived
                : .derived(targetRows: derivedSnapshot?.targetRowCount ?? 1))
            : .standard
        let layoutChanged = layoutMode != nextLayoutMode
        let grows = BufferWorkbenchMetrics.railHeight(for: nextLayoutMode)
            > BufferWorkbenchMetrics.railHeight(for: layoutMode)
        if layoutChanged {
            panel.disableScreenUpdatesUntilFlush()
        }
        if layoutChanged, grows {
            syncLayoutMode(nextLayoutMode)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        _ = bufferRail.refresh(
            shielded: contentProtected,
            translationSnapshot: derivedSnapshot
        )
        if layoutChanged, !grows {
            syncLayoutMode(nextLayoutMode)
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        bufferRail.reconcileTranslationDocumentGeometry()
        let pluginFailure = contentProtected
            || derivedWorkspaceSelected
            || builtInActionWorkspaceSelected
            ? nil
            : ActionPluginHost.shared.workbenchFailureMessage
        let canGenerateWithoutFocus = !contentProtected
            && !derivedWorkspaceSelected
            && !builtInActionWorkspaceSelected
            && ActionPluginHost.shared.presentations.contains {
                !$0.requiresFocus && $0.canInvoke
            }
        lastSecureInputState = secureInputEnabled
        if !contentProtected, let derivedWorkspace {
            statusLabel.stringValue = derivedWorkspace.statusText
        } else if !contentProtected, let builtInActionWorkspace {
            statusLabel.stringValue = builtInActionWorkspace.actionPresentation.statusText
        } else {
            statusLabel.stringValue = BufferWorkbenchStatusText.text(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
            )
        }
        statusLabel.toolTip = !contentProtected
            && (derivedWorkspaceSelected || builtInActionWorkspaceSelected)
            ? statusLabel.stringValue
            : BufferWorkbenchStatusText.help(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
        )
        statusLabel.textColor = RimeUI.textSecondary
        refreshContextualStatusIndicators(
            contentProtected ? nil : derivedWorkspace
        )

        assert(!contentProtected || bufferRail.isHidden,
               "secure input must leave the text-bearing rail hidden")
        refreshPrimaryAction(controls: WorkbenchManualGenerationRouter.selectedControls,
                             availability: availability,
                             contentProtected: contentProtected)
        refreshButton.isEnabled = BufferPluginSelectionStore.shared.activeKey != nil
            && !contentProtected
        refreshButton.toolTip = refreshButton.isEnabled
            ? "刷新或重置当前插件（保留缓冲正文）"
            : "当前没有可刷新的缓冲插件"
        refreshPluginActions()
        applyAppearance()
    }

    private func refreshContextualStatusIndicators(
        _ workspace: (any DerivedBufferWorkspace)?
    ) {
        let indicators = (workspace as? any WorkbenchStatusIndicatorProviding)?
            .workbenchStatusIndicators ?? []
        reconcileContextualStatusIndicators(indicators)
    }

    private func reconcileContextualStatusIndicators(
        _ indicators: [WorkbenchStatusIndicator]
    ) {
        let liveIdentifiers = Set(indicators.map(\.identifier))
        for identifier in contextualStatusViews.keys
            where !liveIdentifiers.contains(identifier) {
            guard let view = contextualStatusViews.removeValue(forKey: identifier) else {
                continue
            }
            contextualStatusControl.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, indicator) in indicators.enumerated() {
            let view = contextualStatusViews[indicator.identifier]
                ?? BufferWorkbenchStatusIndicatorView(frame: .zero)
            contextualStatusViews[indicator.identifier] = view
            view.update(indicator)
            if view.superview !== contextualStatusControl {
                contextualStatusControl.insertArrangedSubview(view, at: index)
            } else if contextualStatusControl.arrangedSubviews.indices.contains(index),
                      contextualStatusControl.arrangedSubviews[index] !== view {
                contextualStatusControl.removeArrangedSubview(view)
                contextualStatusControl.insertArrangedSubview(view, at: index)
            }
        }
    }

    /// Every ETInput-owned text field is an internal UI surface, not a draft
    /// source or a remote-mirroring target.
    func isOwnClient(bundleID: String) -> Bool {
        let own = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
        return bundleID == own
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame else { return }
        if let visibleFrame = panel.screen?.visibleFrame {
            syncMinimumSize(to: visibleFrame)
            if panel.frame.width > visibleFrame.width
                || panel.frame.height > visibleFrame.height {
                clampFrameToScreens()
                return
            }
        }
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjustingFrame else { return }
        clampFrameToScreens()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard !adjustingFrame else { return }
        let aligned = BufferWindowGeometry.pixelAligned(
            panel.frame,
            scale: panel.backingScaleFactor
        )
        if aligned != panel.frame {
            adjustingFrame = true
            panel.setFrame(aligned, display: true)
            adjustingFrame = false
        }
        visual.needsLayout = true
        bufferRail.needsLayout = true
        panel.invalidateShadow()
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = BufferWorkbenchLayout.windowBackgroundDraggable
        panel.minSize = NSSize(width: BufferWindowGeometry.standardMinimumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: BufferWorkbenchLayout
                                       .toolbarAlwaysExpanded,
                                   mode: layoutMode
                               ))
        panel.maxSize = NSSize(width: BufferWindowGeometry.standardMaximumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: BufferWorkbenchLayout
                                       .toolbarAlwaysExpanded,
                                   mode: layoutMode
                               ))
        panel.delegate = self
        applyCollectionBehavior()

        outerContainer.wantsLayer = true
        outerContainer.layer?.backgroundColor = NSColor.clear.cgColor
        visual.state = .active
        visual.blendingMode = .behindWindow
        visual.translatesAutoresizingMaskIntoConstraints = false
        outerContainer.addSubview(visual)
        NSLayoutConstraint.activate([
            visual.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor, constant: 2),
            visual.trailingAnchor.constraint(equalTo: outerContainer.trailingAnchor, constant: -2),
            visual.topAnchor.constraint(equalTo: outerContainer.topAnchor, constant: 2),
            visual.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor, constant: -2),
        ])
        panel.contentView = outerContainer

        outerContainer.addSubview(translationBridgeView)
        NSLayoutConstraint.activate([
            translationBridgeView.leadingAnchor.constraint(equalTo: outerContainer.leadingAnchor,
                                                            constant: 3),
            translationBridgeView.bottomAnchor.constraint(equalTo: outerContainer.bottomAnchor,
                                                           constant: -3),
            translationBridgeView.widthAnchor.constraint(equalToConstant: 1),
            translationBridgeView.heightAnchor.constraint(equalToConstant: 1),
        ])

        configureIconButton(sendButton, "paperplane.fill", "发送下一块", #selector(sendTapped))
        sendButtonProgressIndicator.style = .spinning
        sendButtonProgressIndicator.controlSize = .small
        sendButtonProgressIndicator.isDisplayedWhenStopped = false
        sendButtonProgressIndicator.isHidden = true
        sendButtonProgressIndicator.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addSubview(sendButtonProgressIndicator)
        NSLayoutConstraint.activate([
            sendButtonProgressIndicator.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            sendButtonProgressIndicator.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            sendButtonProgressIndicator.widthAnchor.constraint(equalToConstant: 12),
            sendButtonProgressIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
        configureIconButton(refreshButton,
                            "arrow.clockwise",
                            "刷新或重置当前插件（保留缓冲正文）",
                            #selector(refreshPluginTapped))
        configureIconButton(closeButton, "xmark", "关闭并暂停缓冲（保留内容）", #selector(closeTapped))

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.userInterfaceLayoutDirection = .leftToRight
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pluginSelector.controlSize = .mini
        pluginSelector.font = .systemFont(ofSize: 10, weight: .semibold)
        pluginSelector.imagePosition = .imageLeading
        pluginSelector.imageHugsTitle = true
        pluginSelector.target = self
        pluginSelector.action = #selector(bufferPluginSelectionChanged)
        pluginSelector.toolTip = "切换缓冲插件（⌘⇧↑/↓）"
        pluginSelector.translatesAutoresizingMaskIntoConstraints = false
        let pluginSelectorMinimumWidth = pluginSelector.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 64
        )
        pluginSelectorMinimumWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            pluginSelectorMinimumWidth,
            pluginSelector.widthAnchor.constraint(lessThanOrEqualToConstant: 108),
        ])
        pluginSelector.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        pluginSelector.setContentCompressionResistancePriority(.defaultLow,
                                                               for: .horizontal)

        pluginButtonRow.orientation = .horizontal
        pluginButtonRow.alignment = .centerY
        pluginButtonRow.distribution = .fill
        pluginButtonRow.spacing = 2
        pluginButtonRow.detachesHiddenViews = false
        pluginButtonRow.userInterfaceLayoutDirection = .leftToRight
        pluginButtonRow.setContentHuggingPriority(.required, for: .horizontal)
        pluginButtonRow.setContentCompressionResistancePriority(.required, for: .horizontal)

        for popup in [translationSourcePopup, translationTargetPopup] {
            popup.controlSize = .mini
            popup.font = .systemFont(ofSize: 10)
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        }
        translationSourcePopup.target = self
        translationSourcePopup.action = #selector(translationSourceChanged)
        translationTargetPopup.target = self
        translationTargetPopup.action = #selector(translationTargetChanged)

        builtInActionOptionPopup.controlSize = .mini
        builtInActionOptionPopup.font = .systemFont(ofSize: 10)
        builtInActionOptionPopup.target = self
        builtInActionOptionPopup.action = #selector(builtInActionOptionChanged)
        builtInActionOptionPopup.translatesAutoresizingMaskIntoConstraints = false
        builtInActionOptionPopup.widthAnchor.constraint(
            equalToConstant: 116
        ).isActive = true
        builtInActionOptionPopup.setContentHuggingPriority(
            .required,
            for: .horizontal
        )
        builtInActionOptionPopup.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        translationSwapButton.image = RimeUI.symbol("arrow.left.arrow.right",
                                                   pointSize: 9,
                                                   weight: .semibold)
        translationSwapButton.image?.isTemplate = true
        translationSwapButton.imagePosition = .imageOnly
        translationSwapButton.isBordered = false
        translationSwapButton.focusRingType = .none
        translationSwapButton.toolTip = "交换源语言和目标语言"
        translationSwapButton.target = self
        translationSwapButton.action = #selector(translationSwapTapped)
        translationSwapButton.translatesAutoresizingMaskIntoConstraints = false
        translationSwapButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        translationSwapButton.heightAnchor.constraint(equalToConstant: 18).isActive = true

        builtInActionButton.target = self
        builtInActionButton.action = #selector(builtInActionTapped)
        builtInActionButton.imagePosition = .imageLeading
        builtInActionButton.font = .systemFont(ofSize: 10, weight: .medium)
        builtInActionButton.isBordered = false
        builtInActionButton.focusRingType = .none
        builtInActionButton.controlSize = .small
        builtInActionButton.setContentHuggingPriority(.required, for: .horizontal)
        builtInActionButton.setContentCompressionResistancePriority(.required,
                                                                    for: .horizontal)

        pluginLoadingIndicator.style = .spinning
        pluginLoadingIndicator.controlSize = .small
        pluginLoadingIndicator.isDisplayedWhenStopped = false
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        pluginLoadingIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
        pluginLoadingIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
        pluginLoadingIndicator.setContentHuggingPriority(.required, for: .horizontal)
        pluginLoadingIndicator.setContentCompressionResistancePriority(.required,
                                                                       for: .horizontal)

        // This is one persistent region, not a transient list of buttons. The
        // plugin selector stays at its leading edge while status updates only
        // mutate the existing action controls in place.
        pluginActionsControl.orientation = .horizontal
        pluginActionsControl.alignment = .centerY
        pluginActionsControl.distribution = .fill
        pluginActionsControl.spacing = 4
        pluginActionsControl.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 3)
        pluginActionsControl.detachesHiddenViews = false
        pluginActionsControl.userInterfaceLayoutDirection = .leftToRight
        pluginActionsControl.wantsLayer = true
        pluginActionsControl.layer?.cornerRadius = 6
        pluginActionsControl.addArrangedSubview(pluginSelector)
        pluginActionsControl.addArrangedSubview(pluginLoadingIndicator)
        pluginActionsControl.addArrangedSubview(pluginButtonRow)
        pluginActionsControl.setContentHuggingPriority(.required, for: .horizontal)
        pluginActionsControl.setContentCompressionResistancePriority(.defaultHigh,
                                                                     for: .horizontal)

        contextualStatusControl.orientation = .horizontal
        contextualStatusControl.alignment = .centerY
        contextualStatusControl.distribution = .fill
        contextualStatusControl.spacing = 2
        contextualStatusControl.detachesHiddenViews = true
        contextualStatusControl.userInterfaceLayoutDirection = .leftToRight
        contextualStatusControl.setContentHuggingPriority(.required,
                                                          for: .horizontal)
        contextualStatusControl.setContentCompressionResistancePriority(
            .defaultHigh,
            for: .horizontal
        )

        BufferWorkbenchShelfLayout.configure(
            utilityShelf,
            status: statusLabel,
            pluginActions: pluginActionsControl,
            flexibleSpace: shelfFlexibleSpace,
            statusIndicators: contextualStatusControl,
            refresh: refreshButton,
            close: closeButton
        )

        shelfDivider.wantsLayer = true
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor

        let mainBar = NSStackView(
            views: BufferWorkbenchLayout.mainBar.map { view(for: $0) }
        )
        mainBar.orientation = .horizontal
        mainBar.alignment = .centerY
        mainBar.distribution = .fill
        mainBar.spacing = BufferWorkbenchMetrics.mainSpacing
        mainBar.detachesHiddenViews = false
        mainBar.userInterfaceLayoutDirection = .leftToRight
        mainBar.edgeInsets = NSEdgeInsets(
            top: 3,
            left: BufferWorkbenchMetrics.mainHorizontalInset,
            bottom: 3,
            right: BufferWorkbenchMetrics.mainHorizontalInset
        )

        let root = NSStackView(views: [utilityShelf, shelfDivider, mainBar])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(root)
        let mainBarHeight = mainBar.heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.mainBarHeight(for: layoutMode)
        )
        let railHeight = bufferRail.heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.railHeight(for: layoutMode)
        )
        mainBarHeightConstraint = mainBarHeight
        bufferRailHeightConstraint = railHeight
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            root.topAnchor.constraint(equalTo: visual.topAnchor),
            root.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            utilityShelf.heightAnchor.constraint(equalToConstant: 33),
            shelfDivider.heightAnchor.constraint(equalToConstant: 1),
            mainBarHeight,
            bufferRail.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            railHeight,
        ])
        updateMainControlAlignment(for: layoutMode)
        applyAppearance()
        rebuildPluginSelector()
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     _ symbol: String,
                                     _ toolTip: String,
                                     _ action: Selector) {
        button.image = RimeUI.symbol(symbol, pointSize: 11, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
    }

    private func view(for control: BufferWorkbenchControl) -> NSView {
        switch control {
        case .bufferRail: return bufferRail
        case .send: return sendSlot
        case .status: return statusLabel
        case .pluginActions: return pluginActionsControl
        case .refresh: return refreshButton
        case .close: return closeButton
        }
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        visual.material = RimeUI.isNight ? .hudWindow : .popover
        visual.fillColor = RimeUI.workbenchChrome
        visual.strokeColor = RimeUI.borderStrong
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        pluginActionsControl.layer?.backgroundColor = RimeUI.surface2.cgColor
        pluginActionsControl.layer?.borderColor = RimeUI.border.cgColor
        pluginActionsControl.layer?.borderWidth = 1 / max(panel.backingScaleFactor, 1)
        [refreshButton, closeButton, sendButton].forEach {
            $0.contentTintColor = RimeUI.textSecondary
            $0.refreshInteractionAppearance()
        }
        sendButton.contentTintColor = sendButtonUsesAccent && sendButton.isEnabled
            ? RimeUI.accentBlue
            : RimeUI.textSecondary
        translationSwapButton.contentTintColor = RimeUI.textSecondary
        translationSwapButton.refreshInteractionAppearance()
        pluginActionButtons.values.forEach {
            $0.contentTintColor = $0.isEnabled ? RimeUI.accentBlue : RimeUI.textSecondary
            $0.refreshInteractionAppearance()
        }
        builtInActionButton.contentTintColor = builtInActionButton.isEnabled
            ? RimeUI.accentBlue
            : RimeUI.textSecondary
        builtInActionButton.refreshInteractionAppearance()
        pluginSelector.refreshInteractionAppearance()
        builtInActionOptionPopup.refreshInteractionAppearance()
        translationSourcePopup.refreshInteractionAppearance()
        translationTargetPopup.refreshInteractionAppearance()
        contextualStatusViews.values.forEach { $0.applyAppearance() }
    }

    private func applyPreviewPointerState(_ hoveredControl: BufferWorkbenchControl?) {
        [sendButton, refreshButton, closeButton].forEach {
            $0.setPreviewPointerState(nil)
        }
        pluginSelector.setPreviewPointerState(nil)
        builtInActionOptionPopup.setPreviewPointerState(nil)
        translationSourcePopup.setPreviewPointerState(nil)
        translationTargetPopup.setPreviewPointerState(nil)
        translationSwapButton.setPreviewPointerState(nil)
        builtInActionButton.setPreviewPointerState(nil)
        pluginActionButtons.values.forEach { $0.setPreviewPointerState(nil) }

        switch hoveredControl {
        case .send:
            sendButton.setPreviewPointerState(.hovered)
        case .pluginActions:
            pluginSelector.setPreviewPointerState(.hovered)
        case .refresh:
            refreshButton.setPreviewPointerState(.hovered)
        case .close:
            closeButton.setPreviewPointerState(.hovered)
        case .bufferRail, .status, .none:
            break
        }
    }

    private func refreshPrimaryAction(
        controls: (any WorkbenchManualGenerationControls)?,
        availability: BufferDeliveryCoordinator.Availability,
        contentProtected: Bool
    ) {
        sendButton.imagePosition = .imageOnly
        sendButtonUsesAccent = false

        guard let controls else {
            setSendButtonGenerating(false)
            setSendButtonSymbol("paperplane.fill")
            sendButton.isEnabled = availability.canSend && !contentProtected
            sendButton.toolTip = availability.canSend ? "发送下一块" : availability.label
            sendButton.setAccessibilityLabel("发送下一块")
            return
        }

        switch controls.primaryAction {
        case .disabled:
            setSendButtonGenerating(false)
            setSendButtonSymbol("sparkles")
            sendButton.isEnabled = false
            sendButton.toolTip = contentProtected
                ? "安全输入已开启，AI 已暂停"
                : controls.generationStatusText
            sendButton.setAccessibilityLabel("AI 生成不可用")
        case .requestGeneration:
            setSendButtonGenerating(false)
            setSendButtonSymbol("sparkles")
            sendButton.isEnabled = !contentProtected
                && controls.canGenerate
                && !availability.blocksManualGenerationRequest
            sendButton.toolTip = sendButton.isEnabled
                ? controls.generationRequestDescription
                : (availability.blocksManualGenerationRequest
                    ? availability.label
                    : controls.generationStatusText)
            sendButton.setAccessibilityLabel("请求 AI 生成")
            sendButtonUsesAccent = true
        case .generating:
            sendButton.image = nil
            sendButton.isEnabled = false
            sendButton.toolTip = controls.generationStatusText
            sendButton.setAccessibilityLabel("AI 正在生成")
            setSendButtonGenerating(true)
        case .deliver:
            setSendButtonGenerating(false)
            setSendButtonSymbol("paperplane.fill")
            sendButton.isEnabled = availability.canSend && !contentProtected
            sendButton.toolTip = availability.canSend ? "发送下一块" : availability.label
            sendButton.setAccessibilityLabel("发送下一块 AI 内容")
            sendButtonUsesAccent = true
        }
    }

    private func setSendButtonGenerating(_ generating: Bool) {
        if generating {
            guard sendButtonProgressIndicator.isHidden else { return }
            sendButtonProgressIndicator.isHidden = false
            sendButtonProgressIndicator.startAnimation(nil)
        } else {
            guard !sendButtonProgressIndicator.isHidden else { return }
            sendButtonProgressIndicator.stopAnimation(nil)
            sendButtonProgressIndicator.isHidden = true
        }
    }

    private func setSendButtonSymbol(_ name: String) {
        sendButton.image = RimeUI.symbol(name, pointSize: 11, weight: .semibold)
        sendButton.image?.isTemplate = true
    }

    private func refreshPluginActions() {
        guard !lastSecureInputState, !sessionProtectionActive else {
            resetDerivedControlRendering()
            pluginLoadingIndicator.isHidden = true
            pluginLoadingIndicator.stopAnimation(nil)
            pluginSelector.toolTip = "安全输入已开启，插件控制已隐藏"
            return
        }
        if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace {
            if let controls = workspace as? any DerivedLanguagePairControls {
                refreshLanguageControls(workspace: workspace, controls: controls)
            } else if let controls = workspace as? any WorkbenchManualGenerationControls {
                refreshManualGenerationControls(workspace: workspace, controls: controls)
            } else {
                refreshDerivedWorkspaceWithoutControls(workspace)
            }
            return
        }
        if let workspace = BuiltInBufferActionWorkspaceRouter.selectedWorkspace {
            refreshBuiltInActionControls(workspace)
            return
        }
        if renderingTranslationControls
            || renderingAIControls
            || renderingBuiltInActionControls {
            resetDerivedControlRendering()
        }
        let allPresentations = ActionPluginHost.shared.presentations
        // A single prepared action shares the same primary generation surface
        // as the built-in AI workspace. Keep legacy and ambiguous actions in
        // the shelf, but do not render a second “generate” button for Marine.
        let presentations = ActionPluginPrimaryPresentationRules.secondary(
            in: allPresentations
        )
        let waitingForFirstContent = presentations.contains(where: \.waitingForFirstContent)
        pluginLoadingIndicator.isHidden = !waitingForFirstContent
        if waitingForFirstContent {
            pluginLoadingIndicator.startAnimation(nil)
        } else {
            pluginLoadingIndicator.stopAnimation(nil)
        }
        let pluginNames = allPresentations.reduce(into: [String]()) { names, presentation in
            guard !names.contains(presentation.pluginName) else { return }
            names.append(presentation.pluginName)
        }
        pluginSelector.toolTip = pluginNames.isEmpty
            ? "切换缓冲插件（⌘⇧↑/↓）"
            : "当前插件：\(pluginNames.joined(separator: "、"))（⌘⇧↑/↓ 切换）"

        let keys = presentations.map(\.presentationKey)
        if keys != renderedPluginKeys {
            renderedPluginKeys = keys
            let previousButtons = pluginActionButtons
            var nextButtons: [ActionPluginPresentationKey: BufferPluginActionButton] = [:]
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            for presentation in presentations {
                let button = previousButtons[presentation.presentationKey]
                    ?? BufferPluginActionButton(title: "",
                                                target: self,
                                                action: #selector(pluginActionTapped(_:)))
                button.pluginKey = presentation.key
                nextButtons[presentation.presentationKey] = button
                pluginButtonRow.addArrangedSubview(button)
            }
            pluginActionButtons = nextButtons
        }

        for presentation in presentations {
            guard let button = pluginActionButtons[presentation.presentationKey] else { continue }
            // The presentation key stays stable while status switches the
            // contextual wire action underneath this one visible control.
            button.pluginKey = presentation.key
            button.title = presentation.running ? "生成中…" : presentation.title
            button.image = RimeUI.symbol(presentation.running ? "hourglass" : presentation.symbol,
                                         pointSize: 10,
                                         weight: .semibold)
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.isBordered = false
            button.focusRingType = .none
            button.controlSize = .small
            button.isEnabled = presentation.canInvoke
            var help = "\(presentation.pluginName) · \(presentation.label)"
            if let summary = presentation.targetSummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                help += "\n\(summary)"
            }
            if !presentation.available { help += "\n等待插件提供投放目标" }
            button.toolTip = help
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
    }

    private func refreshBuiltInActionControls(
        _ workspace: any BuiltInBufferActionWorkspace
    ) {
        let presentation = workspace.actionPresentation
        let optionPresentation = workspace.optionPresentation
        let hasOptions = optionPresentation != nil
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（⌘⇧↑/↓ 切换）"
        pluginLoadingIndicator.isHidden = !presentation.isRunning
        presentation.isRunning
            ? pluginLoadingIndicator.startAnimation(nil)
            : pluginLoadingIndicator.stopAnimation(nil)

        if !renderingBuiltInActionControls
            || renderedBuiltInActionHasOptions != hasOptions {
            resetDerivedControlRendering()
            renderingBuiltInActionControls = true
            renderedBuiltInActionHasOptions = hasOptions
            if hasOptions {
                pluginButtonRow.addArrangedSubview(
                    builtInActionOptionPopup
                )
            }
            pluginButtonRow.addArrangedSubview(builtInActionButton)
        }

        if let optionPresentation {
            if renderedBuiltInActionOptions
                != optionPresentation.options {
                renderedBuiltInActionOptions =
                    optionPresentation.options
                builtInActionOptionPopup.removeAllItems()
                for option in optionPresentation.options {
                    builtInActionOptionPopup.addItem(
                        withTitle: option.title
                    )
                    builtInActionOptionPopup.lastItem?
                        .representedObject = option.identifier
                }
            }
            selectPopupExactly(
                builtInActionOptionPopup,
                representedValue:
                    optionPresentation.selectedIdentifier
            )
            builtInActionOptionPopup.isEnabled =
                optionPresentation.isEnabled
            builtInActionOptionPopup.toolTip =
                optionPresentation.toolTip
            builtInActionOptionPopup.setAccessibilityLabel(
                "\(workspace.workbenchDisplayName) 首选识别语言"
            )
        }

        builtInActionButton.title = presentation.title
        builtInActionButton.image = RimeUI.symbol(
            presentation.symbolName,
            pointSize: 10,
            weight: .semibold
        )
        builtInActionButton.image?.isTemplate = true
        builtInActionButton.isEnabled = presentation.isEnabled
        builtInActionButton.toolTip = presentation.toolTip
        builtInActionButton.setAccessibilityLabel(
            "\(workspace.workbenchDisplayName)：\(presentation.title)"
        )
    }

    private func refreshLanguageControls(workspace: any DerivedBufferWorkspace,
                                         controls: any DerivedLanguagePairControls) {
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（⌘⇧↑/↓ 切换）"
        let loading: Bool
        if lastSecureInputState || sessionProtectionActive {
            loading = false
        } else {
            switch workspace.railSnapshot.phase {
            case .waiting, .translating: loading = true
            default: loading = false
            }
        }
        pluginLoadingIndicator.isHidden = !loading
        loading ? pluginLoadingIndicator.startAnimation(nil)
                : pluginLoadingIndicator.stopAnimation(nil)

        if !renderingTranslationControls {
            renderingTranslationControls = true
            renderingAIControls = false
            renderingBuiltInActionControls = false
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            pluginButtonRow.addArrangedSubview(translationSourcePopup)
            pluginButtonRow.addArrangedSubview(translationSwapButton)
            pluginButtonRow.addArrangedSubview(translationTargetPopup)
        }

        if renderedTranslationLanguages != controls.languageOptions {
            renderedTranslationLanguages = controls.languageOptions
            translationSourcePopup.removeAllItems()
            translationTargetPopup.removeAllItems()
            for option in controls.languageOptions {
                translationSourcePopup.addItem(withTitle: option.title)
                translationSourcePopup.lastItem?.representedObject = option.identifier
                translationTargetPopup.addItem(withTitle: option.title)
                translationTargetPopup.lastItem?.representedObject = option.identifier
            }
        }
        selectPopup(translationSourcePopup,
                    representedValue: controls.sourceLanguageID)
        selectPopup(translationTargetPopup,
                    representedValue: controls.targetLanguageID)
        let controlsEnabled = !lastSecureInputState && !sessionProtectionActive
        translationSourcePopup.isEnabled = controlsEnabled
        translationTargetPopup.isEnabled = controlsEnabled
        translationSwapButton.isEnabled = controlsEnabled && controls.canSwapLanguages
    }

    private func refreshManualGenerationControls(
        workspace: any DerivedBufferWorkspace,
        controls _: any WorkbenchManualGenerationControls
    ) {
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（⌘⇧↑/↓ 切换）"
        // The target rail owns the animated first-content indicator. Keep the
        // shelf compact; the right-side primary button owns generation state.
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.stopAnimation(nil)

        if !renderingAIControls {
            renderingAIControls = true
            renderingTranslationControls = false
            renderingBuiltInActionControls = false
            renderedTranslationLanguages.removeAll()
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
        }
    }

    private func refreshDerivedWorkspaceWithoutControls(
        _ workspace: any DerivedBufferWorkspace
    ) {
        resetDerivedControlRendering()
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（⌘⇧↑/↓ 切换）"
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.stopAnimation(nil)
    }

    private func resetDerivedControlRendering() {
        renderingTranslationControls = false
        renderingAIControls = false
        renderingBuiltInActionControls = false
        renderedBuiltInActionHasOptions = nil
        renderedTranslationLanguages.removeAll()
        renderedBuiltInActionOptions.removeAll()
        renderedPluginKeys.removeAll()
        pluginActionButtons.removeAll()
        pluginButtonRow.arrangedSubviews.forEach {
            pluginButtonRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func selectPopup(_ popup: NSPopUpButton, representedValue: String) {
        guard let index = (0..<popup.numberOfItems).first(where: {
            guard let itemValue = popup.item(at: $0)?.representedObject as? String else {
                return false
            }
            return TranslationLanguageIdentity.matches(itemValue,
                                                       expected: representedValue)
        }) else { return }
        popup.selectItem(at: index)
    }

    private func selectPopupExactly(
        _ popup: NSPopUpButton,
        representedValue: String
    ) {
        guard let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == representedValue
        }) else { return }
        popup.select(item)
    }

    private func syncLayoutMode(_ nextMode: BufferWorkbenchLayoutMode) {
        updateMainControlAlignment(for: nextMode)
        guard layoutMode != nextMode else { return }
        layoutMode = nextMode
        mainBarHeightConstraint?.constant = BufferWorkbenchMetrics.mainBarHeight(for: nextMode)
        bufferRailHeightConstraint?.constant = BufferWorkbenchMetrics.railHeight(for: nextMode)
        var proposed = panel.frame
        proposed.size.height = BufferWindowGeometry.height(
            expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
            mode: nextMode
        )
        let fallback = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(proposed,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: panel.isVisible)
        visual.needsLayout = true
        bufferRail.needsLayout = true
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    private func updateMainControlAlignment(for mode: BufferWorkbenchLayoutMode) {
        sendSlot.update(for: mode)
    }

    private func applyCollectionBehavior() {
        panel.collectionBehavior = pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace]
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.clampFrameToScreens()
            candidateWindow.syncWorkbenchAnchor(self?.candidateAnchorRect)
        })
        observers.append(center.addObserver(forName: .rimeAppearanceDidChange,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .derivedBufferWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .builtInBufferActionWorkspaceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
            RimeBufferController.refreshActiveUI()
        })
        observers.append(center.addObserver(
            forName: .pluginConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[
                PluginConfigurationNotificationKey.pluginID
            ] as? String == BuiltInPluginID.remarkable else {
                return
            }
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .aiTextConnectorAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
            RimeBufferController.refreshActiveUI()
        })
        observers.append(center.addObserver(
            forName: .activeBufferPluginDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            BuiltInBufferActionWorkspaceRouter.activeSelectionDidChange()
            self?.schedulePluginSelectorRefresh()
            self?.refresh()
        })
        observers.append(center.addObserver(
            forName: .pluginRegistryDidChange,
            object: PluginRegistry.shared,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePluginSelectorRefresh()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refresh()
            RimeBufferController.refreshActiveUI()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sessionInactive = true
            self?.protectForSession(reason: "session resigned")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sessionInactive = false
            self?.restoreAfterSessionProtection()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.protectForSession(reason: "system sleep")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
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
            self?.protectForSession(reason: "screen locked")
        })
        observers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screenLocked = false
            self?.restoreAfterSessionProtection()
        })
        secureInputPollTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let secureInputEnabled = IsSecureEventInputEnabled()
            // Keep derived plaintext protected even while the workbench is
            // hidden. Session lifecycle flags remain authoritative: this poll
            // may synchronize secure-input protection, but it must never undo
            // lock/sleep/session-resign protection while any flag is active.
            DerivedBufferWorkspaceRouter.setProtectedOnAll(
                secureInputEnabled || self.sessionProtectionActive
            )
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(
                secureInputEnabled || self.sessionProtectionActive
            )
            guard secureInputEnabled != self.lastSecureInputState else { return }
            self.lastSecureInputState = secureInputEnabled
            if secureInputEnabled {
                ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            }
            if self.panel.isVisible {
                self.refresh()
            }
            RimeBufferController.refreshActiveUI()
        }
        if let secureInputPollTimer {
            RunLoop.main.add(secureInputPollTimer, forMode: .common)
        }
        pluginStatusPollTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  self.isVisible,
                  !self.hiddenForSession else { return }
            // refreshStatuses only contacts the selected external provider,
            // but its five-second manifest scan must keep running while a
            // built-in owns the workbench so a late Marine install is found.
            ActionPluginHost.shared.refreshStatuses()
        }
        if let pluginStatusPollTimer {
            RunLoop.main.add(pluginStatusPollTimer, forMode: .common)
        }
    }

    private func protectForSession(reason: String) {
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
        BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
        if let lease = InputFocusCoordinator.shared.invalidateAll(reason: reason) {
            lease.controller?.finalizeProtectedSession(lease, reason: reason)
            candidateWindow.hide(owner: lease.token)
        } else {
            candidateWindow.hideAll()
        }
        if panel.isVisible || UserDefaults.standard.bool(forKey: Key.visible) {
            hiddenForSession = true
            panel.orderOut(nil)
        }
    }

    private func restoreAfterSessionProtection() {
        DerivedBufferWorkspaceRouter.setProtectedOnAll(
            sessionProtectionActive || IsSecureEventInputEnabled()
        )
        BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(
            sessionProtectionActive || IsSecureEventInputEnabled()
        )
        guard hiddenForSession,
              !sessionProtectionActive,
              UserDefaults.standard.bool(forKey: Key.visible) else { return }
        hiddenForSession = false
        refresh()
        panel.orderFrontRegardless()
        RimeBufferController.refreshActiveUI()
    }

    private func restoreFrame() {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Key.frame).map(NSRectFromString)
            ?? defaults.string(forKey: Key.legacyFrame).map(NSRectFromString)
            ?? NSRect(x: fallback.midX - 340,
                      y: fallback.midY - BufferWindowGeometry.expandedHeight / 2,
                      width: 680,
                      height: BufferWindowGeometry.expandedHeight)
        applyClampedFrame(stored,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: false)
    }

    private func clampFrameToScreens() {
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(panel.frame,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: true)
        saveFrame()
    }

    private func applyClampedFrame(_ proposed: NSRect,
                                   visibleFrames: [NSRect],
                                   fallback: NSRect,
                                   display: Bool) {
        let clamped = BufferWindowGeometry.clampedFrame(
            proposed,
            expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
            mode: layoutMode,
            visibleFrames: visibleFrames,
            fallback: fallback
        )
        let frame = BufferWindowGeometry.pixelAligned(
            clamped,
            scale: panel.backingScaleFactor
        )
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visibleFrame = visibleFrames.first { $0.contains(center) } ?? fallback
        syncMinimumSize(to: visibleFrame)
        adjustingFrame = true
        panel.setFrame(frame, display: display)
        adjustingFrame = false
        visual.needsLayout = true
        panel.invalidateShadow()
    }

    private func syncMinimumSize(to visibleFrame: NSRect) {
        let usableWidth = max(1, visibleFrame.width - BufferWindowGeometry.screenSafetyMargin * 2)
        let targetHeight = min(BufferWindowGeometry.height(
            expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
            mode: layoutMode
        ),
                               visibleFrame.height)
        panel.minSize = NSSize(
            width: min(BufferWindowGeometry.standardMinimumWidth, usableWidth),
            height: targetHeight
        )
        panel.maxSize = NSSize(
            width: min(BufferWindowGeometry.standardMaximumWidth, usableWidth),
            height: targetHeight
        )
    }

    private var sessionProtectionActive: Bool {
        sessionInactive || screenLocked || sleeping
    }

    private func selectDerivedTarget(blockID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isVisible,
              !lastSecureInputState,
              !IsSecureEventInputEnabled(),
              !sessionProtectionActive,
              let lease = InputFocusCoordinator.shared.interactionTarget(),
              lease.isExternalTarget,
              let controls = DerivedBufferWorkspaceRouter
                .selectedWorkspace as? any DerivedResultSelectionControls,
              controls.ownsResultNavigation,
              controls.selectResult(blockID: blockID),
              InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
              ) === lease else {
            return
        }
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    private func saveFrame() {
        var canonical = panel.frame
        canonical.size.height = BufferWindowGeometry.expandedHeight
        UserDefaults.standard.set(NSStringFromRect(canonical), forKey: Key.frame)
    }

    // MARK: - Actions

    private func schedulePluginSelectorRefresh() {
        guard !pluginSelectorRefreshScheduled else { return }
        pluginSelectorRefreshScheduled = true
        // Registry and selection notifications can be emitted synchronously
        // from this popup's own action. Rebuilding on the next main-loop turn
        // avoids removing an NSMenuItem while AppKit is still dispatching it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pluginSelectorRefreshScheduled = false
            self.rebuildPluginSelector()
            self.refresh()
        }
    }

    private func rebuildPluginSelector() {
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        let activeKey = BufferPluginSelectionStore.shared.activeKey
        pluginSelector.removeAllItems()
        for entry in BufferPluginMenuCatalog.entries(from: plugins) {
            pluginSelector.addItem(withTitle: entry.title)
            pluginSelector.lastItem?.representedObject = BufferPluginMenuIdentity(entry.key)
            pluginSelector.lastItem?.image = PluginVisualIdentity.image(
                symbolName: entry.symbolName,
                accessibilityDescription: entry.title,
                pointSize: 10,
                weight: .semibold
            )
            pluginSelector.lastItem?.toolTip = entry.key == nil
                ? "使用默认缓冲，不加载插件"
                : "切换到 \(entry.title)"
        }
        let selectedIndex = (0..<pluginSelector.numberOfItems).first { index in
            guard let identity = pluginSelector.item(at: index)?.representedObject
                    as? BufferPluginMenuIdentity else { return false }
            return identity.key == activeKey
        } ?? 0
        pluginSelector.selectItem(at: selectedIndex)
    }

    @objc private func bufferPluginSelectionChanged() {
        guard !IsSecureEventInputEnabled(),
              let identity = pluginSelector.selectedItem?.representedObject
                as? BufferPluginMenuIdentity else {
            schedulePluginSelectorRefresh()
            return
        }
        do {
            if let key = identity.key {
                try PluginRegistry.shared.setBufferPluginActive(true, for: key)
            } else {
                BufferPluginSelectionStore.shared.clear()
            }
        } catch {
            NSSound.beep()
            IMELog.write("workbench plugin switch failed")
        }
        schedulePluginSelectorRefresh()
    }

    @objc private func sendTapped() {
        guard !sessionProtectionActive else { return }
        if IsSecureEventInputEnabled() {
            // Synchronize privacy immediately instead of waiting for the next
            // periodic secure-input refresh.
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
            refresh()
            return
        }
        if let controls = WorkbenchManualGenerationRouter.selectedControls {
            switch controls.primaryAction {
            case .requestGeneration:
                let availability = BufferDeliveryCoordinator.shared.availability()
                guard !availability.blocksManualGenerationRequest else {
                    NSSound.beep()
                    refresh()
                    return
                }
                if !controls.generate() { NSSound.beep() }
                refresh()
                RimeBufferController.refreshActiveUI()
                return
            case .generating, .disabled:
                return
            case .deliver:
                break
            }
        }
        _ = BufferDeliveryCoordinator.shared.sendNext(resolveCompositionIfNeeded: true)
        // Delivery.insert atomically replaces the idle marked guard. Restore it
        // for the still-current external lease before the next Return.
        RimeBufferController.refreshActiveUI()
    }

    @objc private func closeTapped() { closeAndPause() }

    @objc private func refreshPluginTapped() {
        guard BufferPluginSelectionStore.shared.activeKey != nil,
              !IsSecureEventInputEnabled() else { return }
        if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace {
            _ = workspace.requestRefresh()
        } else if let workspace = BuiltInBufferActionWorkspaceRouter.selectedWorkspace {
            _ = workspace.requestRefresh()
        } else {
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            ActionPluginHost.shared.refreshStatuses(force: true)
        }
        let kind = DerivedBufferWorkspaceRouter.selectedWorkspace?
            .deliveryWorkspaceID
            ?? BuiltInBufferActionWorkspaceRouter.selectedWorkspace?
                .workbenchDisplayName
            ?? "action"
        IMELog.write("buffer plugin refresh requested kind=\(kind)")
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func pluginActionTapped(_ sender: NSButton) {
        guard let key = (sender as? BufferPluginActionButton)?.pluginKey else { return }
        ActionPluginHost.shared.invoke(key)
    }

    @objc private func builtInActionTapped() {
        guard !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              let workspace = BuiltInBufferActionWorkspaceRouter.selectedWorkspace else {
            return
        }
        if !workspace.invoke() { NSSound.beep() }
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func builtInActionOptionChanged() {
        guard !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              let workspace =
                  BuiltInBufferActionWorkspaceRouter.selectedWorkspace,
              let identifier = builtInActionOptionPopup.selectedItem?
                  .representedObject as? String else {
            return
        }
        if !workspace.selectOption(identifier: identifier) {
            NSSound.beep()
        }
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func translationSourceChanged() {
        guard let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
                as? any DerivedLanguagePairControls,
              let value = translationSourcePopup.selectedItem?.representedObject as? String else {
            return
        }
        controls.setSourceLanguage(value)
    }

    @objc private func translationTargetChanged() {
        guard let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
                as? any DerivedLanguagePairControls,
              let value = translationTargetPopup.selectedItem?.representedObject as? String else {
            return
        }
        controls.setTargetLanguage(value)
    }

    @objc private func translationSwapTapped() {
        guard let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
                as? any DerivedLanguagePairControls else { return }
        if !controls.swapLanguages() { NSSound.beep() }
    }

}
