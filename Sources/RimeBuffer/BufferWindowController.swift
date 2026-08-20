import Cocoa
import Carbon.HIToolbox
import QuartzCore

enum BufferCandidatePlacement: String, CaseIterable {
    case workbench
    case caret

    var title: String {
        switch self {
        case .workbench: return "跟随缓冲工作台"
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
        case let .derived(targetRows): return min(max(targetRows, 1), 5)
        }
    }
}

/// React's Buffer master has two presentation grammars. Live workspaces keep
/// source and result visible together, while explicit generators may exchange
/// the one visible rail after a request. This is presentation only: the
/// concrete workspace still owns both source and result until delivery is
/// confirmed through `BufferDeliveryCoordinator`.
enum BufferDerivedPresentationStyle: Equatable {
    case liveExpand
    case singleExchange
}

/// Explicit bridge from the React mode taxonomy to native ownership. A
/// Remarkable import has no derived source/result workspace: its recognized
/// text becomes ordinary BufferModel content, so pretending it is an exchange
/// rail would invent a second delivery authority.
enum BufferNativePresentationContract: Equatable {
    case standardBufferImport
    case derived(BufferDerivedPresentationStyle)
}

enum BufferDerivedPresentationRules {
    static func nativeContract(
        for pluginKey: PluginKey?
    ) -> BufferNativePresentationContract {
        if pluginKey == RemarkableWorkspace.pluginKey {
            return .standardBufferImport
        }
        if pluginKey == AITextBuiltInPluginID.key
            || pluginKey == MarineChromeWorkspace.pluginKey {
            return .derived(.singleExchange)
        }
        return .derived(.liveExpand)
    }

    static func style(for pluginKey: PluginKey?) -> BufferDerivedPresentationStyle {
        guard case let .derived(style) = nativeContract(for: pluginKey) else {
            // Remarkable never enters DerivedBufferWorkspaceRouter. This
            // fallback keeps previews fail-safe if a caller asks anyway.
            return .liveExpand
        }
        return style
    }

    static func exchangeShowsTarget(
        style: BufferDerivedPresentationStyle,
        phase: TranslationRailSnapshot.Phase,
        outputCount: Int
    ) -> Bool {
        guard style == .singleExchange else { return true }
        return phase == .waiting || phase == .translating || outputCount > 0
    }

    static func layoutMode(
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot?
    ) -> BufferWorkbenchLayoutMode {
        guard let snapshot else {
            return style == .singleExchange ? .singleDerived : .derived(targetRows: 1)
        }
        let showsTarget = exchangeShowsTarget(
            style: style,
            phase: snapshot.phase,
            outputCount: snapshot.outputBlocks.count
        )
        let showsSource = snapshot.showsSourceRail
            && !(style == .singleExchange && showsTarget)
        return showsSource && showsTarget
            ? .derived(targetRows: 1)
            : .singleDerived
    }

    static func showsExchangeActions(
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot?
    ) -> Bool {
        guard style == .singleExchange, let snapshot else { return false }
        return snapshot.phase == .ready && !snapshot.outputBlocks.isEmpty
    }
}

enum BufferOpeningSide: Equatable {
    case belowTarget
    case aboveTarget
    case bottomFallback
}

struct BufferOpeningPlacement: Equatable {
    let frame: NSRect
    let side: BufferOpeningSide
}

enum BufferCandidateSideRules {
    static func preferredSide(openingSide: BufferOpeningSide,
                              openingToken: FocusToken?,
                              candidateOwner: FocusToken?)
        -> CandidatePanelPreferredSide {
        openingSide == .aboveTarget
            && openingToken != nil
            && openingToken == candidateOwner
            ? .above
            : .below
    }

    static func requiresOutwardPlacement(openingSide: BufferOpeningSide,
                                         openingToken: FocusToken?,
                                         candidateOwner: FocusToken?) -> Bool {
        openingSide != .bottomFallback
            && openingToken != nil
            && openingToken == candidateOwner
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
    static let clipboardDividerHeight: CGFloat = 1
    static var clipboardSectionHeight: CGFloat {
        clipboardDividerHeight + ClipboardRailMetrics.railHeight
    }
    static let standardMinimumHeight = expandedHeight
    static let screenSafetyMargin: CGFloat = 8
    static let inputAnchorGap: CGFloat = 10
    static let fallbackBottomOffset: CGFloat = 120
    static var maximumRuntimeHeight: CGFloat {
        height(expanded: true,
               mode: .derived(targetRows: 5),
               clipboardRailEnabled: true)
    }

    static func clampedStandardWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, standardMinimumWidth), standardMaximumWidth)
    }

    static func height(expanded: Bool,
                       mode: BufferWorkbenchLayoutMode = .standard,
                       clipboardRailEnabled: Bool = false) -> CGFloat {
        let baseHeight: CGFloat
        switch mode {
        case .standard, .singleDerived:
            baseHeight = expanded ? expandedHeight : collapsedHeight
        case .derived:
            // Alternatives page inside one target rail. Candidate count no
            // longer changes the panel height or moves the host-side anchor.
            baseHeight = expanded ? translationExpandedHeight : translationCollapsedHeight
        }
        return baseHeight + (clipboardRailEnabled ? clipboardSectionHeight : 0)
    }

    static func clampedFrame(_ proposed: NSRect,
                             expanded: Bool = true,
                             mode: BufferWorkbenchLayoutMode = .standard,
                             clipboardRailEnabled: Bool = false,
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
        let height = min(
            height(expanded: expanded,
                   mode: mode,
                   clipboardRailEnabled: clipboardRailEnabled),
            safeTarget.height
        )
        var x = proposed.width == width ? proposed.minX : proposed.midX - width / 2
        // The 52pt predecessor and both current states preserve their bottom
        // edge, keeping the candidate panel stationary. Only the legacy 340pt
        // workbench migrates by preserving its old top edge.
        let maximumCurrentExpandedHeight = maximumRuntimeHeight
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

    /// Places a newly summoned workbench near the exact current input caret.
    /// The caller must supply only a fresh, token-validated host rect. Invalid
    /// or missing rects deliberately use a lower-center screen fallback rather
    /// than a remembered app/field coordinate.
    static func openingPlacement(currentFrame: NSRect,
                                 targetRect: NSRect?,
                                 visibleFrames: [NSRect],
                                 fallback: NSRect,
                                 forecastHeight: CGFloat = maximumRuntimeHeight)
        -> BufferOpeningPlacement {
        let screens = visibleFrames.isEmpty ? [fallback] : visibleFrames
        let targetScreen = targetRect.flatMap { rect in
            screens.first { isPlausibleInputAnchor(rect, visibleFrame: $0) }
        }
        let target = targetScreen ?? fallback
        let horizontalMargin = min(screenSafetyMargin, max(0, (target.width - 1) / 2))
        let verticalMargin = min(screenSafetyMargin, max(0, (target.height - 1) / 2))
        let safeTarget = target.insetBy(dx: horizontalMargin, dy: verticalMargin)
        let minimumWidth = min(standardMinimumWidth, safeTarget.width)
        let maximumWidth = min(standardMaximumWidth, safeTarget.width)
        let proposedWidth = currentFrame.width > 0 ? currentFrame.width : 680
        let proposedHeight = currentFrame.height > 0 ? currentFrame.height : expandedHeight
        let width = min(max(proposedWidth, minimumWidth), maximumWidth)
        let height = min(proposedHeight, safeTarget.height)
        // Forecast the largest current layout only to choose a stable side.
        // The real (usually 78pt) panel still sits exactly `inputAnchorGap`
        // from the input line instead of reserving invisible vertical space.
        let plannedHeight = min(max(height, forecastHeight), safeTarget.height)

        guard let targetRect, targetScreen != nil else {
            let availableTravel = max(0, safeTarget.height - height)
            let bottomOffset = min(fallbackBottomOffset, availableTravel / 4)
            return BufferOpeningPlacement(
                frame: NSRect(x: safeTarget.midX - width / 2,
                              y: safeTarget.minY + bottomOffset,
                              width: width,
                              height: height),
                side: .bottomFallback
            )
        }

        var x = targetRect.midX - width / 2
        x = min(max(x, safeTarget.minX), max(safeTarget.minX, safeTarget.maxX - width))

        let belowRoom = max(0, targetRect.minY - inputAnchorGap - safeTarget.minY)
        let aboveRoom = max(0, safeTarget.maxY - targetRect.maxY - inputAnchorGap)
        let belowY = targetRect.minY - inputAnchorGap - height
        let aboveY = targetRect.maxY + inputAnchorGap
        let side: BufferOpeningSide
        let y: CGFloat
        if belowRoom >= plannedHeight {
            side = .belowTarget
            y = belowY
        } else if aboveRoom >= plannedHeight {
            side = .aboveTarget
            y = aboveY
        } else {
            // On a short screen, prefer the side with enough room for the
            // current layout; otherwise choose the larger deterministic side.
            let belowFitsCurrent = belowRoom >= height
            let aboveFitsCurrent = aboveRoom >= height
            if belowFitsCurrent && (!aboveFitsCurrent || belowRoom >= aboveRoom) {
                side = .belowTarget
                y = belowY
            } else if aboveFitsCurrent {
                side = .aboveTarget
                y = aboveY
            } else if belowRoom >= aboveRoom {
                side = .belowTarget
                y = safeTarget.minY
            } else {
                side = .aboveTarget
                y = safeTarget.maxY - height
            }
        }
        return BufferOpeningPlacement(
            frame: NSRect(x: x, y: y, width: width, height: height),
            side: side
        )
    }

    static func isPlausibleInputAnchor(_ rect: NSRect,
                                       visibleFrames: [NSRect]) -> Bool {
        visibleFrames.contains { isPlausibleInputAnchor(rect, visibleFrame: $0) }
    }

    private static func isPlausibleInputAnchor(_ rect: NSRect,
                                               visibleFrame: NSRect) -> Bool {
        guard rect != .zero,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width >= 0,
              rect.height > 2,
              rect.height < 300 else { return false }
        // A caret is commonly zero-width, so point containment is intentional;
        // CGRect intersection would reject a perfectly valid insertion point.
        return visibleFrame.insetBy(dx: -screenSafetyMargin,
                                    dy: -screenSafetyMargin)
            .contains(rect.origin)
    }

    static func candidateAnchor(for frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 8,
               y: frame.minY,
               width: max(4, frame.width - 16),
               height: frame.height)
    }

    /// Contextual openings grow away from the input line: a below-target
    /// workbench keeps its top edge fixed, while an above-target workbench
    /// keeps its bottom edge fixed. Manual and fallback layouts retain the
    /// historical bottom-edge behavior in `clampedFrame`.
    static func resizedOutward(_ frame: NSRect,
                               height: CGFloat,
                               openingSide: BufferOpeningSide) -> NSRect {
        var resized = frame
        resized.size.height = height
        if openingSide == .belowTarget {
            resized.origin.y = frame.maxY - height
        }
        return resized
    }

    static func canonicalPersistedFrame(_ currentFrame: NSRect,
                                        persistedOrigin: NSPoint?,
                                        transientOpeningOrigin: Bool) -> NSRect {
        var canonical = currentFrame
        canonical.size.height = expandedHeight
        if transientOpeningOrigin, let persistedOrigin {
            canonical.origin = persistedOrigin
        }
        return canonical
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

/// One fail-closed state projection drives Clipboard polling, rendering, and
/// activation. Keeping it pure lets the integration smoke prove that every
/// lifecycle flag closes the same gate without touching the user's pasteboard.
enum ClipboardWorkbenchIntegrationRules {
    static func captureState(
        workbenchVisibleOnActiveSpace: Bool,
        hiddenForSession: Bool,
        railEnabled: Bool,
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
            workbenchVisible: workbenchVisibleOnActiveSpace && !hiddenForSession,
            railEnabled: railEnabled,
            protection: protection
        )
    }

    static func allowsAddToBuffer(_ state: ClipboardHistoryCaptureState) -> Bool {
        state.allowsClipboardObservation
    }
}

/// Keep enabled capture discoverable without turning the passive workbench
/// into a caret-following window. A newly trusted text focus may relocate it
/// only when the panel was stranded on another Space or physical display.
enum BufferWindowFocusFollowRules {
    static func shouldRelocate(
        bufferEnabled: Bool,
        presentationProtected: Bool,
        secureInput: Bool,
        hasTrustedExternalFocus: Bool,
        panelVisibleOnActiveSpace: Bool,
        targetScreenMatchesPanel: Bool
    ) -> Bool {
        bufferEnabled
            && !presentationProtected
            && !secureInput
            && hasTrustedExternalFocus
            && (!panelVisibleOnActiveSpace || !targetScreenMatchesPanel)
    }
}

enum BufferWindowCollectionBehaviorRules {
    static func behavior(pinned: Bool) -> NSWindow.CollectionBehavior {
        pinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }
}

enum BufferWindowOrderingRules {
    static func shouldOrderOutBeforeMoving(
        isOrdered: Bool,
        isOnActiveSpace: Bool,
        pinned: Bool
    ) -> Bool {
        isOrdered && !isOnActiveSpace && !pinned
    }
}

enum BufferWorkbenchControl: String, Equatable {
    case bufferRail
    case send
    case status
    case pluginActions
    case exchangeEdit
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
            return RimeUI.accentBlue.withAlphaComponent(RimeUI.isDark ? 0.20 : 0.13)
        case .pressed:
            return RimeUI.accentBlue.withAlphaComponent(RimeUI.isDark ? 0.34 : 0.23)
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
    static let primaryControlWidth: CGFloat = 58
    static let primaryControlHeight: CGFloat = 30
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

    /// Live-expand renders two equal rails inside a 5pt vertical inset with a
    /// 4pt separator. Paged alternatives stay in that one target rail, so the
    /// primary control never walks downward as the result count changes.
    static func mainControlYOffset(row: BufferMainControlRow,
                                   mode: BufferWorkbenchLayoutMode) -> CGFloat {
        guard case .derived = mode else { return 0 }
        let offset = BufferInlineView.additionalTranslationTargetRowHeight / 2
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
                          exchangeEdit: NSView,
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

        [status, pluginActions, flexibleSpace, statusIndicators,
         exchangeEdit, refresh, close].forEach {
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
        .status, .pluginActions, .exchangeEdit, .refresh, .close,
    ]
    static let hoverControls: Set<BufferWorkbenchControl> = [
        .send, .pluginActions, .exchangeEdit, .refresh, .close,
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

enum BufferWorkbenchStatusPresentation {
    enum Tone: Equatable {
        case neutral
        case accent
        case warning
        case danger
    }

    /// The React master reserves this column but leaves routine ready/idle
    /// prose blank; the rail and primary action already communicate those
    /// states. Failures, protection, focus blockers, and active work remain
    /// visible so the compact styling never hides an actionable condition.
    static func text(
        fallback: String,
        snapshot: TranslationRailSnapshot?
    ) -> String {
        if let snapshot {
            switch snapshot.phase {
            case .idle, .ready:
                return ""
            case .unavailable, .waiting, .translating, .failed:
                return fallback
            }
        }
        return fallback == "可发送" || fallback == "等待内容" ? "" : fallback
    }

    static func tone(snapshot: TranslationRailSnapshot?, text: String) -> Tone {
        if let snapshot {
            switch snapshot.phase {
            case .failed, .unavailable: return .danger
            case .waiting, .translating: return .neutral
            case .idle, .ready: return .accent
            }
        }
        if text.contains("安全输入") { return .warning }
        if text.contains("失败") || text.contains("过期") || text.contains("变化") {
            return .danger
        }
        return text.isEmpty ? .neutral : .accent
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

private final class FirstMousePopUpButton: RimeFixedAccentPopUpButton {
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

/// Keeps trailing toolbar actions in stable 22pt columns. When an action is
/// unavailable the wrapper remains in the layout, but the hidden control no
/// longer intercepts the toolbar's first-click drag region.
private final class BufferToolbarControlSlot: NSView {
    private let control: NSControl

    init(control: NSControl) {
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setControlVisible(_ visible: Bool) {
        control.isHidden = !visible
        if !visible { control.isEnabled = false }
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
            widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.primaryControlWidth),
            height,
            control.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerY,
            control.widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.primaryControlWidth),
            control.heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.primaryControlHeight),
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
        static let clipboardRailEnabled = "bufferWindow.clipboardRailEnabled.v1"
    }

    private let panel: BufferPanel
    private let outerContainer = NSView()
    private let visual = BufferChromeView()
    private let bufferRail = BufferInlineView()
    private let clipboardHistoryModel: ClipboardHistoryModel
    private let clipboardRail: ClipboardRailView
    private let clipboardDivider = NSView()
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
    private let exchangeEditButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let refreshButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private lazy var exchangeEditSlot = BufferToolbarControlSlot(control: exchangeEditButton)
    private lazy var refreshSlot = BufferToolbarControlSlot(control: refreshButton)
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
    private var openingSide: BufferOpeningSide = .bottomFallback
    private var openingFocusToken: FocusToken?
    private var transientOpeningOrigin = false
    private var persistedFrameOrigin: NSPoint?
    private var lastFocusFollowToken: FocusToken?
    private var scheduledFocusFollowToken: FocusToken?
    private var activeSpaceFocusFollowPending = false

    private var pluginSwitchShortcutTitle: String {
        let previous = RimeShortcutPreferences
            .shortcut(for: .previousPlugin)
            .displayTitle
        let next = RimeShortcutPreferences
            .shortcut(for: .nextPlugin)
            .displayTitle
        return "\(previous) / \(next)"
    }

    private var deliveryShortcutTitle: String {
        RimeShortcutPreferences
            .shortcut(for: .deliverBuffer)
            .displayTitle
    }

    func preferredCandidatePanelSide(for owner: FocusToken?) -> CandidatePanelPreferredSide {
        BufferCandidateSideRules.preferredSide(
            openingSide: openingSide,
            openingToken: openingFocusToken,
            candidateOwner: owner
        )
    }

    func requiresOutwardCandidatePanelPlacement(for owner: FocusToken?) -> Bool {
        BufferCandidateSideRules.requiresOutwardPlacement(
            openingSide: openingSide,
            openingToken: openingFocusToken,
            candidateOwner: owner
        )
    }

    var isVisible: Bool {
        BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace
        )
    }
    var configuredWidth: CGFloat {
        BufferWindowGeometry.clampedStandardWidth(panel.frame.width)
    }

    func setConfiguredWidth(_ width: CGFloat) {
        var frame = panel.frame
        let resolved = BufferWindowGeometry.clampedStandardWidth(width.rounded())
        frame.origin.x -= (resolved - frame.width) / 2
        frame.size.width = resolved
        let fallback = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(
            frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: fallback,
            display: true
        )
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
        IMELog.write("buffer workbench width=\(configuredWidth)")
    }

    func resetConfiguredWidth() {
        setConfiguredWidth(760)
    }

    /// Opt-in permission and presentation state for the process-local Clipboard
    /// rail. This is the only Clipboard value persisted across launches.
    var clipboardRailEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.clipboardRailEnabled) }
        set {
            guard newValue != clipboardRailEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Key.clipboardRailEnabled)
            applyClipboardRailEnabledChange(enabled: newValue)
        }
    }

    func toggleClipboardRail() {
        clipboardRailEnabled.toggle()
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
        dispatchPrecondition(condition: .onQueue(.main))
        let historyModel = MainActor.assumeIsolated {
            ClipboardHistoryModel()
        }
        clipboardHistoryModel = historyModel
        clipboardRail = MainActor.assumeIsolated {
            ClipboardRailView(model: historyModel)
        }
        let initialWorkspace = DerivedBufferWorkspaceRouter.selectedWorkspace
        let initialSnapshot = initialWorkspace?.railSnapshot
        let initialStyle = BufferDerivedPresentationRules.style(
            for: initialWorkspace?.workspacePluginKey
        )
        let initialLayoutMode: BufferWorkbenchLayoutMode = initialWorkspace == nil
            ? .standard
            : BufferDerivedPresentationRules.layoutMode(
                style: initialStyle,
                snapshot: initialSnapshot
            )
        let initialClipboardRailEnabled = UserDefaults.standard.bool(
            forKey: Key.clipboardRailEnabled
        )
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 760,
                                                height: BufferWindowGeometry.height(
                                                    expanded: BufferWorkbenchLayout
                                                        .toolbarAlwaysExpanded,
                                                    mode: initialLayoutMode,
                                                    clipboardRailEnabled:
                                                        initialClipboardRailEnabled
                                                )),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered,
                            defer: false)
        super.init()
        layoutMode = initialLayoutMode
        bufferRail.onDerivedTargetSelection = { [weak self] blockID in
            self?.selectDerivedTarget(blockID: blockID)
        }
        bufferRail.onDerivedTargetStep = { [weak self] delta in
            self?.moveDerivedTargetSelection(delta: delta)
        }
        MainActor.assumeIsolated {
            clipboardRail.onAddToBuffer = { [weak self] item in
                self?.addClipboardItemToBuffer(item) ?? false
            }
        }
        buildWindow()
        restoreFrame()
        installObservers()
        MainActor.assumeIsolated {
            clipboardRail.start()
        }
        syncClipboardHistoryCapture()
    }

    func showOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: Key.visible) == nil
            ? BufferModel.shared.enabled
            : defaults.bool(forKey: Key.visible)
        if visible { show(repositionOnOpen: false) }
    }

    func show() {
        show(repositionOnOpen: true)
    }

    private func show(repositionOnOpen: Bool) {
        let wasVisibleOnActiveSpace = isVisible
        UserDefaults.standard.set(true, forKey: Key.visible)
        guard !sessionProtectionActive else {
            hiddenForSession = true
            syncClipboardHistoryCapture()
            return
        }
        hiddenForSession = false
        ActionPluginHost.shared.refreshStatuses(force: true)
        refresh()
        if repositionOnOpen, !wasVisibleOnActiveSpace {
            positionForExplicitOpening()
        } else {
            clampFrameToScreens()
        }
        // Re-ordering is required for an unpinned panel that is still ordered
        // on another Space. `.moveToActiveSpace` applies when it is ordered
        // again; simply calling orderFront on the old ordered window may leave
        // it attached to the old Space.
        if BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace,
            pinned: pinned
        ) {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
        syncClipboardHistoryCapture()
        RimeBufferController.refreshActiveUI()
    }

    /// Explicit user-facing open actions resume capture after a previous
    /// close-and-pause. Passive restoration uses `show(repositionOnOpen: false)`
    /// so it neither resumes capture nor replaces the persisted window origin.
    func openAndResume() {
        BufferModel.shared.enabled = true
        // Establish the host's marked-text guard before asking for its caret
        // rectangle. Chromium/Electron clients commonly return a zero rect
        // while no marked session exists.
        RimeBufferController.refreshActiveUI()
        show()
    }

    /// Evaluate a newly trusted text focus on the next main-loop turn, after
    /// the controller has installed its marked-text guard. Repeated key events
    /// for the same focus are no-ops unless an intervening Space transition
    /// made the previous evaluation stale.
    func focusedInputDidActivate(expected token: FocusToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lastFocusFollowToken != token || activeSpaceFocusFollowPending else {
            return
        }
        guard scheduledFocusFollowToken != token else { return }
        scheduledFocusFollowToken = token
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.scheduledFocusFollowToken == token else { return }
            self.scheduledFocusFollowToken = nil
            switch self.evaluateFocusedInputFollow(expected: token) {
            case .deferred:
                // A provisional/suspended lease can become trusted on the next
                // exact key event. Leave the token eligible for one retry.
                return
            case .unchanged:
                self.lastFocusFollowToken = token
                self.activeSpaceFocusFollowPending = false
            case .relocated:
                self.lastFocusFollowToken = token
                self.activeSpaceFocusFollowPending = false
                RimeBufferController.refreshActiveUI()
            }
        }
    }

    func hideWithoutPausing() {
        UserDefaults.standard.set(false, forKey: Key.visible)
        panel.orderOut(nil)
        syncClipboardHistoryCapture()
        RimeBufferController.refreshActiveUI()
    }

    /// The optional external-app privacy purge clears staged plaintext and all
    /// plugin state before a different application can become the target.
    func discardForPrivacyTransition() {
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BufferModel.shared.discardForPrivacy()
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            clipboardHistoryModel.clear()
        }
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
        transientOpeningOrigin = false
        openingSide = .bottomFallback
        openingFocusToken = nil
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
                          presentationStyle: BufferDerivedPresentationStyle = .liveExpand,
                          statusIndicators: [WorkbenchStatusIndicator]? = nil,
                          hoveredControl: BufferWorkbenchControl? = nil) -> Bool {
        let selectedWorkspace = DerivedBufferWorkspaceRouter.selectedWorkspace
        let previewStyle = translationSnapshot == nil
            ? BufferDerivedPresentationRules.style(
                for: selectedWorkspace?.workspacePluginKey
            )
            : presentationStyle
        let previewMode: BufferWorkbenchLayoutMode
        if let translationSnapshot {
            previewMode = BufferDerivedPresentationRules.layoutMode(
                style: previewStyle,
                snapshot: translationSnapshot
            )
        } else if let selectedWorkspace {
            previewMode = BufferDerivedPresentationRules.layoutMode(
                style: previewStyle,
                snapshot: selectedWorkspace.railSnapshot
            )
        } else {
            previewMode = .standard
        }
        syncLayoutMode(previewMode)
        adjustingFrame = true
        panel.setFrame(NSRect(x: 0, y: 0, width: 760,
                              height: BufferWindowGeometry.height(
                                  expanded: BufferWorkbenchLayout
                                      .toolbarAlwaysExpanded,
                                  mode: previewMode,
                                  clipboardRailEnabled: clipboardRailEnabled
                              )),
                       display: false)
        adjustingFrame = false
        if let translationSnapshot {
            statusLabel.stringValue = BufferWorkbenchStatusPresentation.text(
                fallback: translationSnapshot.showsSourceRail
                    ? "译文可发送"
                    : translationSnapshot.targetEmptyText,
                snapshot: translationSnapshot
            )
            _ = bufferRail.renderTranslationForPreview(
                translationSnapshot,
                presentationStyle: previewStyle
            )
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
        syncClipboardHistoryCapture(secureInputEnabled: secureInputEnabled)
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
        let derivedPresentationStyle = BufferDerivedPresentationRules.style(
            for: derivedWorkspace?.workspacePluginKey
        )
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
            ? BufferDerivedPresentationRules.layoutMode(
                style: derivedPresentationStyle,
                snapshot: derivedSnapshot
            )
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
            translationSnapshot: derivedSnapshot,
            presentationStyle: derivedPresentationStyle
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
        let rawStatusText: String
        if !contentProtected, let derivedWorkspace {
            rawStatusText = derivedWorkspace.statusText
        } else if !contentProtected, let builtInActionWorkspace {
            rawStatusText = builtInActionWorkspace.actionPresentation.statusText
        } else {
            rawStatusText = BufferWorkbenchStatusText.text(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
            )
        }
        statusLabel.stringValue = BufferWorkbenchStatusPresentation.text(
            fallback: rawStatusText,
            snapshot: contentProtected ? nil : derivedSnapshot
        )
        statusLabel.toolTip = !contentProtected
            && (derivedWorkspaceSelected || builtInActionWorkspaceSelected)
            ? rawStatusText
            : BufferWorkbenchStatusText.help(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
        )
        switch BufferWorkbenchStatusPresentation.tone(
            snapshot: contentProtected ? nil : derivedSnapshot,
            text: rawStatusText
        ) {
        case .neutral: statusLabel.textColor = RimeUI.textSecondary
        case .accent: statusLabel.textColor = RimeUI.accentBlue
        case .warning: statusLabel.textColor = .systemOrange
        case .danger: statusLabel.textColor = .systemRed
        }
        refreshContextualStatusIndicators(
            contentProtected ? nil : derivedWorkspace
        )

        assert(!contentProtected || bufferRail.isHidden,
               "secure input must leave the text-bearing rail hidden")
        refreshPrimaryAction(controls: WorkbenchManualGenerationRouter.selectedControls,
                             availability: availability,
                             contentProtected: contentProtected)
        refreshExchangeActions(
            style: derivedPresentationStyle,
            snapshot: derivedSnapshot,
            contentProtected: contentProtected
        )
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

    private func refreshExchangeActions(
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot?,
        contentProtected: Bool
    ) {
        let showsExchangeActions = !contentProtected
            && BufferDerivedPresentationRules.showsExchangeActions(
                style: style,
                snapshot: snapshot
            )
        exchangeEditSlot.setControlVisible(showsExchangeActions)
        exchangeEditButton.isEnabled = showsExchangeActions
        exchangeEditButton.toolTip = showsExchangeActions
            ? "返回编辑原文（保留原文，放弃当前结果）"
            : nil

        let hasPlugin = BufferPluginSelectionStore.shared.activeKey != nil
        // Current single-exchange workspaces clear an unsent result as soon as
        // refresh starts. Do not expose that destructive path: transactional
        // replacement is required before retry can satisfy retain-until-send.
        let exposesRefresh = style != .singleExchange
        refreshSlot.setControlVisible(exposesRefresh)
        refreshButton.isEnabled = exposesRefresh
            && hasPlugin
            && !contentProtected
        refreshButton.toolTip = refreshButton.isEnabled
            ? "刷新或重置当前插件（保留缓冲正文）"
            : (style == .singleExchange
                ? "返回编辑后可重新生成"
                : "当前没有可刷新的缓冲插件")
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
        transientOpeningOrigin = false
        openingSide = .bottomFallback
        openingFocusToken = nil
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
                                   mode: layoutMode,
                                   clipboardRailEnabled: clipboardRailEnabled
                               ))
        panel.maxSize = NSSize(width: BufferWindowGeometry.standardMaximumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: BufferWorkbenchLayout
                                       .toolbarAlwaysExpanded,
                                   mode: layoutMode,
                                   clipboardRailEnabled: clipboardRailEnabled
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

        configurePrimaryButton(
            sendButton,
            "paperplane.fill",
            "发送",
            "发送下一块（\(deliveryShortcutTitle)）",
            #selector(sendTapped)
        )
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
        configureIconButton(exchangeEditButton,
                            "text.cursor",
                            "返回编辑原文",
                            #selector(returnToExchangeSourceTapped))
        exchangeEditSlot.setControlVisible(false)
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
        pluginSelector.toolTip = "切换缓冲插件（\(pluginSwitchShortcutTitle)）"
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
            exchangeEdit: exchangeEditSlot,
            refresh: refreshSlot,
            close: closeButton
        )

        shelfDivider.wantsLayer = true
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        clipboardDivider.wantsLayer = true
        clipboardDivider.layer?.backgroundColor = RimeUI.borderStrong
            .withAlphaComponent(0.55).cgColor
        clipboardDivider.isHidden = !clipboardRailEnabled
        clipboardRail.isHidden = !clipboardRailEnabled

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

        let root = NSStackView(views: [
            utilityShelf,
            shelfDivider,
            mainBar,
            clipboardDivider,
            clipboardRail,
        ])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.detachesHiddenViews = true
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
            clipboardDivider.heightAnchor.constraint(
                equalToConstant: BufferWindowGeometry.clipboardDividerHeight
            ),
            clipboardRail.heightAnchor.constraint(equalToConstant: ClipboardRailMetrics.railHeight),
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

    private func configurePrimaryButton(_ button: FirstMouseButton,
                                        _ symbol: String,
                                        _ title: String,
                                        _ toolTip: String,
                                        _ action: Selector) {
        button.usesPrimarySurface = true
        button.image = RimeUI.symbol(symbol, pointSize: 10, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = title
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func view(for control: BufferWorkbenchControl) -> NSView {
        switch control {
        case .bufferRail: return bufferRail
        case .send: return sendSlot
        case .status: return statusLabel
        case .pluginActions: return pluginActionsControl
        case .exchangeEdit: return exchangeEditSlot
        case .refresh: return refreshButton
        case .close: return closeButton
        }
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        visual.material = RimeUI.isDark ? .hudWindow : .popover
        visual.fillColor = RimeUI.workbenchChrome
        visual.strokeColor = RimeUI.borderStrong
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        clipboardDivider.layer?.backgroundColor = RimeUI.borderStrong
            .withAlphaComponent(0.55).cgColor
        pluginActionsControl.layer?.backgroundColor = RimeUI.surface2.cgColor
        pluginActionsControl.layer?.borderColor = RimeUI.border.cgColor
        pluginActionsControl.layer?.borderWidth = 1 / max(panel.backingScaleFactor, 1)
        [exchangeEditButton, refreshButton, closeButton, sendButton].forEach {
            $0.contentTintColor = RimeUI.textSecondary
            $0.refreshInteractionAppearance()
        }
        sendButton.contentTintColor = sendButton.isEnabled
            ? RimeUI.accentForegroundColor
            : RimeUI.textSecondary
        sendButton.attributedTitle = NSAttributedString(
            string: sendButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: sendButton.isEnabled
                    ? RimeUI.accentForegroundColor
                    : RimeUI.textMuted,
            ]
        )
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
        [sendButton, exchangeEditButton, refreshButton, closeButton].forEach {
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
        case .exchangeEdit:
            exchangeEditButton.setPreviewPointerState(.hovered)
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
        sendButton.imagePosition = .imageLeading
        guard let controls else {
            setSendButtonGenerating(false)
            setSendButtonSymbol("paperplane.fill")
            sendButton.title = "发送"
            sendButton.isEnabled = availability.canSend && !contentProtected
            sendButton.toolTip = availability.canSend
                ? "发送下一块（\(deliveryShortcutTitle)）"
                : availability.label
            sendButton.setAccessibilityLabel("发送下一块")
            return
        }

        switch controls.primaryAction {
        case .disabled:
            setSendButtonGenerating(false)
            setSendButtonSymbol("sparkles")
            sendButton.title = "生成"
            sendButton.isEnabled = false
            sendButton.toolTip = contentProtected
                ? "安全输入已开启，AI 已暂停"
                : controls.generationStatusText
            sendButton.setAccessibilityLabel("AI 生成不可用")
        case .requestGeneration:
            setSendButtonGenerating(false)
            setSendButtonSymbol("sparkles")
            sendButton.title = "生成"
            sendButton.isEnabled = !contentProtected
                && controls.canGenerate
                && !availability.blocksManualGenerationRequest
            sendButton.toolTip = sendButton.isEnabled
                ? controls.generationRequestDescription
                : (availability.blocksManualGenerationRequest
                    ? availability.label
                    : controls.generationStatusText)
            sendButton.setAccessibilityLabel("请求 AI 生成")
        case .generating:
            sendButton.image = nil
            sendButton.title = ""
            sendButton.isEnabled = false
            sendButton.toolTip = controls.generationStatusText
            sendButton.setAccessibilityLabel("AI 正在生成")
            setSendButtonGenerating(true)
        case .deliver:
            setSendButtonGenerating(false)
            setSendButtonSymbol("paperplane.fill")
            sendButton.title = "发送"
            sendButton.isEnabled = availability.canSend && !contentProtected
            sendButton.toolTip = availability.canSend
                ? "发送下一块（\(deliveryShortcutTitle)）"
                : availability.label
            sendButton.setAccessibilityLabel("发送下一块 AI 内容")
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
            ? "切换缓冲插件（\(pluginSwitchShortcutTitle)）"
            : "当前插件：\(pluginNames.joined(separator: "、"))（\(pluginSwitchShortcutTitle) 切换）"

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
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（\(pluginSwitchShortcutTitle) 切换）"
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
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（\(pluginSwitchShortcutTitle) 切换）"
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
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（\(pluginSwitchShortcutTitle) 切换）"
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
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（\(pluginSwitchShortcutTitle) 切换）"
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

    private func applyClipboardRailEnabledChange(enabled: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        if enabled {
            // Grow before attaching the scroll-backed rail so AppKit never lays
            // its document view out against a transient zero-height section.
            resizeForClipboardRailChange()
            clipboardDivider.isHidden = false
            clipboardRail.isHidden = false
            panel.contentView?.layoutSubtreeIfNeeded()
            syncClipboardHistoryCapture()
        } else {
            // Close the capture gate and scrub card views before detaching the
            // section. History remains process-local, matching React's hidden
            // Clipboard state, and is never restored after process exit.
            syncClipboardHistoryCapture()
            MainActor.assumeIsolated {
                clipboardRail.setActive(false)
            }
            clipboardRail.isHidden = true
            clipboardDivider.isHidden = true
            panel.contentView?.layoutSubtreeIfNeeded()
            resizeForClipboardRailChange()
        }
    }

    private func resizeForClipboardRailChange() {
        let desiredHeight = BufferWindowGeometry.height(
            expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
            mode: layoutMode,
            clipboardRailEnabled: clipboardRailEnabled
        )
        var proposed = panel.frame
        if transientOpeningOrigin, openingSide != .bottomFallback {
            proposed = BufferWindowGeometry.resizedOutward(
                proposed,
                height: desiredHeight,
                openingSide: openingSide
            )
        } else {
            proposed.size.height = desiredHeight
        }
        let fallback = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        applyClampedFrame(
            proposed,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            fallback: fallback,
            display: panel.isVisible
        )
        visual.needsLayout = true
        clipboardRail.needsLayout = true
        saveFrame()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
    }

    private func clipboardCaptureState(
        secureInputEnabled: Bool? = nil
    ) -> ClipboardHistoryCaptureState {
        ClipboardWorkbenchIntegrationRules.captureState(
            workbenchVisibleOnActiveSpace: isVisible,
            hiddenForSession: hiddenForSession,
            railEnabled: clipboardRailEnabled,
            secureInput: secureInputEnabled ?? IsSecureEventInputEnabled(),
            screenLocked: screenLocked,
            sessionInactive: sessionInactive,
            sleeping: sleeping
        )
    }

    private func syncClipboardHistoryCapture(
        secureInputEnabled: Bool? = nil
    ) {
        let state = clipboardCaptureState(
            secureInputEnabled: secureInputEnabled
        )
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            clipboardRail.update(
                workbenchVisible: state.workbenchVisible,
                railEnabled: state.railEnabled,
                protection: state.protection
            )
            if !state.allowsClipboardObservation {
                clipboardRail.setActive(false)
            }
        }
    }

    private func addClipboardItemToBuffer(_ item: ClipboardHistoryItem) -> Bool {
        let secureInputEnabled = IsSecureEventInputEnabled()
        let state = clipboardCaptureState(
            secureInputEnabled: secureInputEnabled
        )
        dispatchPrecondition(condition: .onQueue(.main))
        return MainActor.assumeIsolated {
            clipboardRail.update(
                workbenchVisible: state.workbenchVisible,
                railEnabled: state.railEnabled,
                protection: state.protection
            )
            guard ClipboardWorkbenchIntegrationRules.allowsAddToBuffer(state),
                  !secureInputEnabled,
                  !clipboardHistoryModel.isContentShielded else {
                return false
            }
            return BufferModel.shared.insertPastedText(item.text)
        }
    }

    private func syncLayoutMode(_ nextMode: BufferWorkbenchLayoutMode) {
        updateMainControlAlignment(for: nextMode)
        guard layoutMode != nextMode else { return }
        layoutMode = nextMode
        mainBarHeightConstraint?.constant = BufferWorkbenchMetrics.mainBarHeight(for: nextMode)
        bufferRailHeightConstraint?.constant = BufferWorkbenchMetrics.railHeight(for: nextMode)
        let desiredHeight = BufferWindowGeometry.height(
            expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
            mode: nextMode,
            clipboardRailEnabled: clipboardRailEnabled
        )
        var proposed = panel.frame
        if transientOpeningOrigin, openingSide != .bottomFallback {
            proposed = BufferWindowGeometry.resizedOutward(
                proposed,
                height: desiredHeight,
                openingSide: openingSide
            )
        } else {
            proposed.size.height = desiredHeight
        }
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
        panel.collectionBehavior = BufferWindowCollectionBehaviorRules.behavior(
            pinned: pinned
        )
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
            forName: .rimeShortcutPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
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
            self?.activeSpaceFocusFollowPending = true
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
            self.syncClipboardHistoryCapture(
                secureInputEnabled: secureInputEnabled
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
        syncClipboardHistoryCapture()
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
        syncClipboardHistoryCapture()
    }

    private func restoreAfterSessionProtection() {
        syncClipboardHistoryCapture()
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
        syncClipboardHistoryCapture()
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
        persistedFrameOrigin = panel.frame.origin
        transientOpeningOrigin = false
        openingSide = .bottomFallback
        openingFocusToken = nil
    }

    private enum FocusFollowEvaluation {
        case deferred
        case unchanged
        case relocated
    }

    private func evaluateFocusedInputFollow(
        expected token: FocusToken
    ) -> FocusFollowEvaluation {
        let protected = sessionProtectionActive || hiddenForSession
        let secureInput = IsSecureEventInputEnabled()
        guard BufferModel.shared.enabled else {
            return .unchanged
        }
        guard !protected, !secureInput else { return .deferred }
        guard InputFocusCoordinator.shared.liveTarget(
            expected: token,
            forceOverlayVisibilityRefresh: true
        ) != nil else {
            return .deferred
        }

        let focusedAnchor = freshFocusedInputAnchor(expected: token)
        let targetScreen = focusedAnchor.flatMap { anchor in
            NSScreen.screens.first {
                BufferWindowGeometry.isPlausibleInputAnchor(
                    anchor.rect,
                    visibleFrames: [$0.visibleFrame]
                )
            }
        }
        let targetScreenMatchesPanel = targetScreen.map { target in
            panel.screen?.frame == target.frame
        } ?? true
        let wasVisibleOnActiveSpace = isVisible
        guard BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: BufferModel.shared.enabled,
            presentationProtected: protected,
            secureInput: secureInput,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: wasVisibleOnActiveSpace,
            targetScreenMatchesPanel: targetScreenMatchesPanel
        ) else {
            return .unchanged
        }

        // Closing the workbench pauses capture, so enabled capture is the
        // authoritative visibility intent. Repair a stale false preference
        // left by an older build or interrupted UI transition.
        UserDefaults.standard.set(true, forKey: Key.visible)
        refresh()
        guard !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ) != nil else {
            return .deferred
        }
        if let focusedAnchor {
            positionForOpening(focusedAnchor: focusedAnchor)
        } else {
            // A trusted lease can still come from a host that withholds caret
            // geometry. Bring an old-Space panel forward without guessing a
            // physical display from the mouse or moving a manually placed UI.
            openingSide = .bottomFallback
            openingFocusToken = nil
            clampFrameToScreens()
        }
        guard !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ) != nil else {
            return .deferred
        }
        if BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace,
            pinned: pinned
        ) {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
        syncClipboardHistoryCapture()
        candidateWindow.syncWorkbenchAnchor(candidateAnchorRect)
        let reason = wasVisibleOnActiveSpace ? "display" : "space"
        IMELog.write("workbench followed focused input token=\(token) reason=\(reason)")
        return .relocated
    }

    private func positionForExplicitOpening() {
        positionForOpening(focusedAnchor: freshFocusedInputAnchor())
    }

    private func positionForOpening(
        focusedAnchor: (rect: NSRect, token: FocusToken)?
    ) {
        let screens = NSScreen.screens
        let visibleFrames = screens.map(\.visibleFrame)
        let mouse = NSEvent.mouseLocation
        let fallback = screens.first { $0.frame.contains(mouse) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let placement = BufferWindowGeometry.openingPlacement(
            currentFrame: panel.frame,
            targetRect: focusedAnchor?.rect,
            visibleFrames: visibleFrames,
            fallback: fallback
        )
        applyClampedFrame(placement.frame,
                          visibleFrames: visibleFrames,
                          fallback: fallback,
                          display: panel.isVisible)
        openingSide = placement.side
        openingFocusToken = placement.side == .bottomFallback
            ? nil
            : focusedAnchor?.token
        transientOpeningOrigin = true
    }

    private func freshFocusedInputAnchor(
        expected token: FocusToken? = nil
    ) -> (rect: NSRect, token: FocusToken)? {
        guard !IsSecureEventInputEnabled(),
              let lease = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              let controller = lease.controller else { return nil }
        guard let rect = controller.workbenchCaretRect(expected: lease) else {
            return nil
        }
        return (rect, lease.token)
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
            clipboardRailEnabled: clipboardRailEnabled,
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
            mode: layoutMode,
            clipboardRailEnabled: clipboardRailEnabled
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

    private func moveDerivedTargetSelection(delta: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard delta != 0,
              isVisible,
              !lastSecureInputState,
              !IsSecureEventInputEnabled(),
              !sessionProtectionActive,
              let lease = InputFocusCoordinator.shared.interactionTarget(),
              lease.isExternalTarget else {
            return
        }

        let moved: Bool
        if let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
            as? any DerivedResultSelectionControls,
           controls.ownsResultNavigation {
            moved = controls.moveResultSelection(delta: delta)
        } else if DerivedBufferWorkspaceRouter.selectedWorkspace
                    === StreamInputWorkspace.shared,
                  StreamInputWorkspace.shared.ownsAlternativeNavigation {
            moved = StreamInputWorkspace.shared.moveAlternativeSelection(
                delta: delta,
                focusToken: lease.token
            )
        } else {
            return
        }
        guard moved,
              InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
              ) === lease else {
            return
        }
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    private func saveFrame() {
        let canonical = BufferWindowGeometry.canonicalPersistedFrame(
            panel.frame,
            persistedOrigin: persistedFrameOrigin,
            transientOpeningOrigin: transientOpeningOrigin
        )
        if !transientOpeningOrigin || persistedFrameOrigin == nil {
            persistedFrameOrigin = canonical.origin
        }
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

    @objc private func returnToExchangeSourceTapped() {
        guard !sessionProtectionActive,
              !IsSecureEventInputEnabled() else {
            return
        }
        if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace
                as? AITextPluginWorkspace,
           workspace.pluginKey == AITextBuiltInPluginID.key {
            // `reset()` invalidates the generated delivery lease and clears
            // only result state. BufferModel remains the retained source.
            workspace.reset()
        } else if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace
                    as? MarineChromeWorkspace,
                  workspace.workspacePluginKey == MarineChromeWorkspace.pluginKey {
            // Marine's refresh operation is a source-preserving reset. The
            // user has explicitly chosen to abandon this result and edit.
            _ = workspace.requestRefresh()
        } else {
            return
        }
        IMELog.write("buffer single-exchange returned to source")
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func refreshPluginTapped() {
        guard BufferPluginSelectionStore.shared.activeKey != nil,
              !IsSecureEventInputEnabled() else { return }
        if BufferDerivedPresentationRules.style(
            for: DerivedBufferWorkspaceRouter.selectedWorkspace?.workspacePluginKey
        ) == .singleExchange {
            // See `refreshExchangeActions`: refreshing this workspace is not
            // transactional yet and must not discard an unsent result.
            return
        }
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
