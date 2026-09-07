import Cocoa
import Carbon.HIToolbox
import QuartzCore

/// The AI Generation output popup has one canonical production definition so
/// runtime rendering and the AppKit smoke exercise the exact same menu items.
enum AITextOutputPopupConfiguration {
    static func populate(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for format in AITextContentFormat.allCases {
            popup.addItem(withTitle: format.displayName)
            popup.lastItem?.representedObject = format.rawValue
        }
    }

    static func matchesCanonicalItems(_ popup: NSPopUpButton) -> Bool {
        let actual = popup.itemArray.map { item in
            (item.title, item.representedObject as? String)
        }
        let expected = AITextContentFormat.allCases.map {
            ($0.displayName, Optional($0.rawValue))
        }
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { lhs, rhs in
            lhs.0 == rhs.0 && lhs.1 == rhs.1
        }
    }
}

/// Direct AppKit evidence used by `ai-text-mailbox-smoke`: the menu actually
/// presented by the Buffer AI plugin contains formats only and no Mailbox item.
func runAITextOutputPopupMenuProbe() -> Bool {
    _ = NSApplication.shared
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    AITextOutputPopupConfiguration.populate(popup)
    return AITextOutputPopupConfiguration.matchesCanonicalItems(popup)
        && popup.itemArray.map(\.title) == ["Plain", "Markdown", "JSON"]
        && popup.itemArray.compactMap { $0.representedObject as? String }
            == ["plain", "markdown", "json"]
}

enum BufferCandidateRoutingRules {
    static func shouldFollowBufferCaret(
        workbenchVisible: Bool,
        presentationProtected: Bool,
        secureInput: Bool,
        capturesExactFocus: Bool
    ) -> Bool {
        workbenchVisible
            && !presentationProtected
            && !secureInput
            && capturesExactFocus
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

/// AppKit-backed transition evidence used by `buffer-window-smoke`. Keeping
/// this as frame data (rather than repeating the pure geometry helper) catches
/// an `NSPanel` or Auto Layout refusal to shrink after a live two-rail state.
struct BufferWindowLayoutTransitionSmokeResult {
    let standardBefore: NSRect
    let derived: NSRect
    let standardAfter: NSRect
    let repairedStandard: NSRect
    let expectedStandardHeight: CGFloat
    let expectedDerivedHeight: CGFloat
    let renderedAllFrames: Bool
}

/// AppKit-backed evidence that attempts to collapse the permanent toolbar are
/// ignored and leave the same stable presentation in place.
struct BufferToolbarToggleSmokeResult {
    let collapsed: NSRect
    let expanded: NSRect
    let collapsedAgain: NSRect
    let toolbarHiddenInitially: Bool
    let toolbarVisibleWhenExpanded: Bool
    let toolbarHiddenAfterCollapse: Bool
    let renderedAllFrames: Bool
}

/// AppKit-backed evidence that the action group overlays the rail instead of
/// taking one of the stack's arranged columns. Width is sampled before and
/// after the optional copy action appears so a future regression cannot bring
/// back the blank trailing slot this layout replaces.
struct BufferRailActionOverlaySmokeResult {
    let panelWidth: CGFloat
    let railFrameWithTwoActions: NSRect
    let railFrameWithThreeActions: NSRect
    let overlayFrame: NSRect
    let actionFrames: [NSRect]
    let overlayIsNonArrangedSibling: Bool
    let overlayContainedByRail: Bool
    let actionsOrderedOnOneRow: Bool
    let actionHitTestingWorks: Bool
    let fadeAreaPassesThrough: Bool
    let interactiveSurfaceVisibleAtIdle: Bool
    let interactiveAccessibilityLabelsAreReadable: Bool
    let functionMenuOwnsOnlyPluginIcon: Bool
    let targetApplicationIconIsReal: Bool
    let targetApplicationIndicatorIsPassive: Bool
    let targetApplicationIconPrecedesClose: Bool
    let protectedStateScrubsApplicationIdentity: Bool
    let hasAmbiguousLayout: Bool

    var passed: Bool {
        let epsilon: CGFloat = 0.5
        return abs(railFrameWithTwoActions.width
            - railFrameWithThreeActions.width) <= epsilon
            && overlayIsNonArrangedSibling
            && overlayContainedByRail
            && actionsOrderedOnOneRow
            && actionHitTestingWorks
            && fadeAreaPassesThrough
            && interactiveSurfaceVisibleAtIdle
            && interactiveAccessibilityLabelsAreReadable
            && functionMenuOwnsOnlyPluginIcon
            && targetApplicationIconIsReal
            && targetApplicationIndicatorIsPassive
            && targetApplicationIconPrecedesClose
            && protectedStateScrubsApplicationIdentity
            && !hasAmbiguousLayout
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

struct BufferDerivedRailVisibility: Equatable {
    let showsSource: Bool
    let showsTarget: Bool
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

    /// One pure presentation decision drives both panel geometry and the
    /// concrete rail tree. Empty live workspaces stay compact: their source
    /// prompt is enough until real source/output appears. A standalone result
    /// message replaces that prompt in one target rail instead of creating an
    /// otherwise empty second row.
    static func visibleRails(
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot
    ) -> BufferDerivedRailVisibility {
        let exchangeTarget = exchangeShowsTarget(
            style: style,
            phase: snapshot.phase,
            outputCount: snapshot.outputBlocks.count
        )
        if style == .singleExchange {
            return BufferDerivedRailVisibility(
                showsSource: snapshot.showsSourceRail && !exchangeTarget,
                showsTarget: exchangeTarget || !snapshot.showsSourceRail
            )
        }

        let hasSource = snapshot.showsSourceRail && !snapshot.sourceText.isEmpty
        let hasOutput = !snapshot.outputBlocks.isEmpty
        let hasExplicitMessage = snapshot.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasStandaloneResultMessage = hasExplicitMessage
            || snapshot.phase == .failed
            || snapshot.phase == .unavailable

        if hasSource {
            return BufferDerivedRailVisibility(showsSource: true, showsTarget: true)
        }
        if hasOutput || hasStandaloneResultMessage {
            return BufferDerivedRailVisibility(showsSource: false, showsTarget: true)
        }
        if snapshot.showsSourceRail {
            return BufferDerivedRailVisibility(showsSource: true, showsTarget: false)
        }
        return BufferDerivedRailVisibility(showsSource: false, showsTarget: true)
    }

    static func layoutMode(
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot?
    ) -> BufferWorkbenchLayoutMode {
        guard let snapshot else {
            return style == .singleExchange ? .singleDerived : .derived(targetRows: 1)
        }
        let visibility = visibleRails(style: style, snapshot: snapshot)
        return visibility.showsSource && visibility.showsTarget
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

/// Pure frame math shared by runtime restoration and the CLI smoke test.
enum BufferWindowGeometry {
    static let standardMinimumWidth: CGFloat = 520
    static let standardMaximumWidth: CGFloat = 1100
    static let collapsedHeight: CGFloat = 42
    static let expandedHeight: CGFloat = 73
    static let translationCollapsedHeight: CGFloat = 74
    static let translationExpandedHeight: CGFloat = 105
    static let standardMinimumHeight = collapsedHeight
    static let screenSafetyMargin: CGFloat = 8
    static let inputAnchorGap: CGFloat = 10
    static let fallbackBottomOffset: CGFloat = 120
    /// Above this height a focused element is a document-sized text area, not
    /// the chat or search box this alignment is meant for. Its left edge and
    /// width still frame the workbench, but the caret line — not the box's
    /// distant bottom edge — stays the vertical anchor, so a full-window
    /// editor does not push the workbench to the bottom of the screen.
    static let boxVerticalAnchorMaximumHeight: CGFloat = 120
    static var maximumRuntimeHeight: CGFloat {
        height(expanded: true, mode: .derived(targetRows: 5))
    }
    static var maximumOpeningHeight: CGFloat { maximumRuntimeHeight }

    static func clampedStandardWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, standardMinimumWidth), standardMaximumWidth)
    }

    static func height(expanded: Bool,
                       mode: BufferWorkbenchLayoutMode = .standard) -> CGFloat {
        let baseHeight: CGFloat
        switch mode {
        case .standard, .singleDerived:
            baseHeight = expanded ? expandedHeight : collapsedHeight
        case .derived:
            // Alternatives page inside one target rail. Candidate count no
            // longer changes the panel height or moves the host-side anchor.
            baseHeight = expanded ? translationExpandedHeight : translationCollapsedHeight
        }
        return baseHeight
    }

    static func clampedFrame(_ proposed: NSRect,
                             expanded: Bool = false,
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
        let height = min(
            height(expanded: expanded, mode: mode),
            safeTarget.height
        )
        var x = proposed.width == width ? proposed.minX : proposed.midX - width / 2
        // The 52pt predecessor and both current states preserve their bottom
        // edge, keeping the candidate panel stationary. Only the legacy 340pt
        // workbench migrates by preserving its old top edge.
        // Treat the previous 78/112pt toolbar frames as compact predecessors:
        // migrating them must preserve the input-facing bottom edge. Only the
        // genuinely old 340pt workbench preserves its top edge.
        var y = proposed.height <= translationExpandedHeight + 1
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
                                 boxRect: NSRect? = nil,
                                 visibleFrames: [NSRect],
                                 fallback: NSRect,
                                 forecastHeight: CGFloat = maximumOpeningHeight)
        -> BufferOpeningPlacement {
        let screens = visibleFrames.isEmpty ? [fallback] : visibleFrames
        let targetScreen = targetRect.flatMap { rect in
            screens.first { isPlausibleInputAnchor(rect, visibleFrame: $0) }
        }
        let target = targetScreen ?? fallback
        let horizontalMargin = min(screenSafetyMargin, max(0, (target.width - 1) / 2))
        let verticalMargin = min(screenSafetyMargin, max(0, (target.height - 1) / 2))
        let safeTarget = target.insetBy(dx: horizontalMargin, dy: verticalMargin)
        // Box alignment applies only to a real, caret-containing text box on
        // the caret's own screen. Anything else keeps the historical
        // caret-centred opening.
        let alignedBox: NSRect? = targetRect.flatMap { caret in
            guard let boxRect,
                  targetScreen != nil,
                  isPlausibleInputBox(boxRect,
                                      caret: caret,
                                      visibleFrames: [target]) else { return nil }
            return boxRect
        }

        let minimumWidth = min(standardMinimumWidth, safeTarget.width)
        let maximumWidth = min(standardMaximumWidth, safeTarget.width)
        // A box-aligned opening adopts the field's width; otherwise the panel
        // keeps the width the user last chose. A field narrower than the
        // readable minimum clamps up to it and keeps its left edge rather than
        // shrinking the workbench past legibility.
        let proposedWidth = alignedBox?.width
            ?? (currentFrame.width > 0 ? currentFrame.width : 680)
        let proposedHeight = currentFrame.height > 0 ? currentFrame.height : collapsedHeight
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

        // The caret marks where the host's next character appears, so the
        // workbench's own first character has to land there — not its window
        // edge, which sits one content inset further left. A box anchor is a
        // frame rather than a text position, so those two edges stay flush.
        var x = alignedBox?.minX
            ?? (targetRect.minX - BufferWorkbenchMetrics.contentLeadingInset)
        x = min(max(x, safeTarget.minX), max(safeTarget.minX, safeTarget.maxX - width))

        // A short field anchors the workbench to the box, so its top edge sits
        // flush under the field. A document-sized text area keeps the caret
        // line, which is where the user actually is.
        let verticalAnchor = alignedBox.map {
            $0.height <= boxVerticalAnchorMaximumHeight ? $0 : targetRect
        } ?? targetRect

        let belowRoom = max(0, verticalAnchor.minY - inputAnchorGap - safeTarget.minY)
        let aboveRoom = max(0, safeTarget.maxY - verticalAnchor.maxY - inputAnchorGap)
        let belowY = verticalAnchor.minY - inputAnchorGap - height
        let aboveY = verticalAnchor.maxY + inputAnchorGap
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

    /// A focused-element frame is usable only when it is a real, on-screen
    /// box that still surrounds the live caret. Accessibility can answer with
    /// a stale frame from the previously focused field, or with a rect that
    /// has been scrolled out of its container; either would align the
    /// workbench to somewhere the user is not typing.
    static func isPlausibleInputBox(_ box: NSRect,
                                    caret: NSRect,
                                    visibleFrames: [NSRect]) -> Bool {
        guard box.origin.x.isFinite,
              box.origin.y.isFinite,
              box.width.isFinite,
              box.height.isFinite,
              box.width >= 1,
              box.height > 2,
              visibleFrames.contains(where: { $0.intersects(box) }) else {
            return false
        }
        // The caret sits on a line inside the box. Tolerate a few points of
        // border and inset rounding on each edge rather than demanding strict
        // containment of a zero-width insertion point.
        let relaxed = box.insetBy(dx: -inputBoxCaretTolerance,
                                  dy: -inputBoxCaretTolerance)
        return relaxed.minX <= caret.minX
            && relaxed.maxX >= caret.minX
            && relaxed.minY <= caret.minY
            && relaxed.maxY >= caret.maxY
    }

    private static let inputBoxCaretTolerance: CGFloat = 4

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
        canonical.size.height = collapsedHeight
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

/// Keep a visible workbench discoverable without turning the passive panel
/// into a caret-following window. A newly trusted text focus may relocate it
/// only when the panel was stranded on another Space or physical display;
/// capture ownership is an independent state.
enum BufferWindowFocusFollowRules {
    static func shouldRelocate(
        workbenchVisible: Bool,
        presentationProtected: Bool,
        secureInput: Bool,
        hasTrustedExternalFocus: Bool,
        panelVisibleOnActiveSpace: Bool,
        targetScreenMatchesPanel: Bool
    ) -> Bool {
        workbenchVisible
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

enum BufferDetachedClipboardRules {
    static let maximumUTF8Bytes = 1_048_576

    static func acceptedText(_ text: String?) -> String? {
        guard let text,
              !text.isEmpty,
              !text.contains("\0"),
              text.utf8.count <= maximumUTF8Bytes else { return nil }
        return text
    }
}

enum BufferTextPasteboardWriter {
    /// Build the complete object before clearing the destination. AppKit does
    /// not offer a transactional pasteboard swap, but a payload-construction
    /// failure must never destroy the user's existing clipboard.
    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

enum BufferTargetAssociationState: Equatable {
    case capturing
    case ready
    case targetChanged
    case unavailable
    case detached
    case protected
}

/// Pure state resolution for the passive target-application icon in the
/// toolbar. The visual never invents an association: capture is shown only
/// when the model's exact token is also the coordinator's current live target.
enum BufferTargetAssociationRules {
    static func state(rimeOwnsInput: Bool,
                      contentProtected: Bool,
                      captureActive: Bool,
                      capturedTargetIsLive: Bool,
                      hasLiveTarget: Bool) -> BufferTargetAssociationState {
        if contentProtected { return .protected }
        if !rimeOwnsInput { return .detached }
        if captureActive {
            return capturedTargetIsLive ? .capturing : .targetChanged
        }
        return hasLiveTarget ? .ready : .unavailable
    }

    static func shouldClearCue(state: BufferTargetAssociationState,
                               hasPresentedCue: Bool,
                               cueMatchesLiveTarget: Bool) -> Bool {
        switch state {
        case .capturing, .ready:
            return hasPresentedCue && !cueMatchesLiveTarget
        case .targetChanged, .unavailable, .detached, .protected:
            return true
        }
    }
}

enum BufferTargetAssociationEdge: Equatable {
    case top
    case bottom
    case left
    case right
}

struct BufferTargetAssociationMarker: Equatable {
    let edge: BufferTargetAssociationEdge
    /// Normalized position along the selected edge. Keeping this normalized
    /// lets an in-flight cue survive backing-scale and layout changes.
    let position: CGFloat
}

/// Chooses the Buffer edge nearest an already validated target caret. This is
/// presentation geometry only; it grants no focus or delivery authority.
enum BufferTargetAssociationGeometry {
    private static let markerInset: CGFloat = 14

    static func marker(panelFrame: NSRect,
                       targetRect: NSRect) -> BufferTargetAssociationMarker? {
        let values = [
            panelFrame.origin.x, panelFrame.origin.y,
            panelFrame.size.width, panelFrame.size.height,
            targetRect.midX, targetRect.midY,
        ]
        guard values.allSatisfy(\.isFinite),
              panelFrame.width > 0,
              panelFrame.height > 0 else { return nil }

        let target = NSPoint(x: targetRect.midX, y: targetRect.midY)
        guard !panelFrame.contains(target) else { return nil }

        func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            min(max(value, lower), upper)
        }
        func distance(to point: NSPoint) -> CGFloat {
            hypot(target.x - point.x, target.y - point.y)
        }

        let horizontalX = clamped(target.x,
                                  lower: panelFrame.minX,
                                  upper: panelFrame.maxX)
        let verticalY = clamped(target.y,
                                lower: panelFrame.minY,
                                upper: panelFrame.maxY)
        let candidates: [(BufferTargetAssociationEdge, CGFloat)] = [
            (.top, distance(to: NSPoint(x: horizontalX, y: panelFrame.maxY))),
            (.bottom, distance(to: NSPoint(x: horizontalX, y: panelFrame.minY))),
            (.left, distance(to: NSPoint(x: panelFrame.minX, y: verticalY))),
            (.right, distance(to: NSPoint(x: panelFrame.maxX, y: verticalY))),
        ]
        guard let edge = candidates.min(by: { $0.1 < $1.1 })?.0 else {
            return nil
        }

        switch edge {
        case .top, .bottom:
            let inset = min(markerInset, panelFrame.width / 2)
            let x = clamped(target.x,
                            lower: panelFrame.minX + inset,
                            upper: panelFrame.maxX - inset)
            return BufferTargetAssociationMarker(
                edge: edge,
                position: (x - panelFrame.minX) / panelFrame.width
            )
        case .left, .right:
            let inset = min(markerInset, panelFrame.height / 2)
            let y = clamped(target.y,
                            lower: panelFrame.minY + inset,
                            upper: panelFrame.maxY - inset)
            return BufferTargetAssociationMarker(
                edge: edge,
                position: (y - panelFrame.minY) / panelFrame.height
            )
        }
    }
}

enum BufferWorkbenchControl: String, Equatable {
    case bufferRail
    case copyResult
    case targetAssociation
    case send
    case status
    case clipboardImport
    case functionMenu
    case pluginActions
    case exchangeEdit
    case autoSend
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
    // The delivery/generation surface is deliberately the same compact,
    // icon-only control as the utility actions. Its tooltip and accessibility
    // label carry the verb without spending rail width on a visible title.
    static let primaryControlWidth: CGFloat = controlSize
    static let primaryControlHeight: CGFloat = controlSize
    static let mainSpacing: CGFloat = 3
    static let actionOverlayFadeWidth: CGFloat = 18
    static let shelfSpacing: CGFloat = 4
    static let mainHorizontalInset: CGFloat = 5
    /// Transparent margin between the panel edge and the drawn chrome, kept
    /// for the shadow and the rounded border.
    static let chromeInset: CGFloat = 2
    /// Panel edge to the first rendered character: chrome margin, main-bar
    /// inset, and the rail's own inset. Derived rather than written as a
    /// number so a later layout change cannot leave the caret alignment
    /// silently stale.
    static var contentLeadingInset: CGFloat {
        chromeInset + mainHorizontalInset + BufferInlineMetrics.railHorizontalInset
    }
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
        mode.targetRows == nil ? 38 : railHeight(for: mode) + 6
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

/// Pins the plugin controls to the leading edge while one dedicated spacer
/// absorbs every width change. The status column participates only while it
/// has actionable text; an empty 88pt reservation made the normal selector
/// look accidentally centered instead of aligned with the toolbar inset.
enum BufferWorkbenchShelfLayout {
    static let flexiblePriority = NSLayoutConstraint.Priority(rawValue: 1)
    static let statusWidthPriority = NSLayoutConstraint.Priority(rawValue: 749)

    static func configure(_ shelf: NSStackView,
                          status: NSView,
                          functionMenu: NSView,
                          pluginActions: NSView,
                          flexibleSpace: NSView,
                          statusIndicators: NSView,
                          exchangeEdit: NSView,
                          autoSend: NSView,
                          targetAssociation: NSView,
                          close: NSView) {
        shelf.orientation = .horizontal
        shelf.alignment = .centerY
        shelf.distribution = .fill
        shelf.spacing = BufferWorkbenchMetrics.shelfSpacing
        shelf.detachesHiddenViews = true
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

        [functionMenu, pluginActions, status, flexibleSpace, statusIndicators,
         exchangeEdit, autoSend, targetAssociation, close].forEach {
            shelf.addArrangedSubview($0)
        }
    }
}

/// Shared by the live stack construction and the pure layout smoke test.
enum BufferWorkbenchLayout {
    static let mainBar: [BufferWorkbenchControl] = [.bufferRail]
    static let railOverlay: [BufferWorkbenchControl] = [
        .clipboardImport, .copyResult, .send,
    ]
    static let toolbar: [BufferWorkbenchControl] = [
        .functionMenu, .pluginActions, .status, .exchangeEdit,
        .autoSend, .targetAssociation, .close,
    ]
    static let hoverControls: Set<BufferWorkbenchControl> = [
        .copyResult, .send, .clipboardImport, .functionMenu,
        .pluginActions, .exchangeEdit, .autoSend, .close,
    ]
    static let passiveControls: Set<BufferWorkbenchControl> = [
        .bufferRail, .status, .targetAssociation,
    ]
    static let toolbarInitiallyExpanded = true
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
            // The inline preedit and detached candidate panel already make
            // composition visible at the Buffer caret. Repeating that state
            // in the toolbar adds noise and reserves an otherwise empty 88pt
            // status column.
            case .composing: return ""
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

    /// Routine ready/idle prose is blank and detaches the status column; the
    /// rail and primary action already communicate those states. Failures,
    /// protection, focus blockers, and active work restore the 88pt column so
    /// compact styling never hides an actionable condition.
    static func railRendersStatusMessage(
        snapshot: TranslationRailSnapshot,
        style: BufferDerivedPresentationStyle
    ) -> Bool {
        let visibility = BufferDerivedPresentationRules.visibleRails(
            style: style,
            snapshot: snapshot
        )
        guard visibility.showsTarget else { return false }
        if snapshot.outputBlocks.isEmpty {
            switch snapshot.phase {
            case .waiting, .translating, .failed, .unavailable:
                return true
            case .idle, .ready:
                return false
            }
        }
        return snapshot.phase == .waiting || snapshot.phase == .translating
    }

    static func text(
        fallback: String,
        snapshot: TranslationRailSnapshot?,
        style: BufferDerivedPresentationStyle = .liveExpand
    ) -> String {
        if let snapshot {
            if railRendersStatusMessage(snapshot: snapshot, style: style) {
                return ""
            }
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

enum BufferWorkbenchPreferences {
    static let closeAfterLastDeliveryKey =
        "bufferWindow.closeAfterLastDelivery.v1"

    static func closeAfterLastDelivery(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: closeAfterLastDeliveryKey) == nil
            ? true
            : defaults.bool(forKey: closeAfterLastDeliveryKey)
    }

    static func setCloseAfterLastDelivery(
        _ enabled: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: closeAfterLastDeliveryKey)
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
            if let textField = current as? NSTextField {
                if textField.isEditable || textField.isSelectable {
                    return textField
                }
                view = current.superview
                continue
            }
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
            && toolbar.hitTest(NSPoint(x: 70, y: 16)) === toolbar
            && toolbar.hitTest(NSPoint(x: 150, y: 16)) === toolbar
            && toolbar.hitTest(NSPoint(x: 220, y: 16)) === toolbar
    }
}

func runBufferWorkbenchToolbarHitTestProbe() -> Bool {
    BufferWorkbenchToolbarView.runHitTestProbe()
}

private final class FirstMousePopUpButton: RimeFixedAccentPopUpButton {
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

    override var pointingHandTrackingOptions: NSTrackingArea.Options {
        [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
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

    /// The title column is the only part that grows with content; the divider
    /// and disclosure columns are fixed.
    override var intrinsicContentSize: NSSize {
        let titleWidth = (currentTitle as NSString)
            .size(withAttributes: [.font: currentFont])
            .width
        return NSSize(
            width: BufferPopUpControlMetrics.intrinsicWidth(
                titleWidth: ceil(titleWidth)
            ),
            height: max(super.intrinsicContentSize.height, 18)
        )
    }

    private var currentFont: NSFont {
        font ?? .systemFont(ofSize: 10)
    }

    private var currentTitle: String {
        titleOfSelectedItem ?? title
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerHovered = true
        refreshInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerHovered = false
        refreshInteractionAppearance()
        super.mouseExited(with: event)
    }

    /// The workbench panel never becomes key, so the system menu's tracking
    /// loop is replaced by the workbench's own nonactivating menu surface.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pointerPressed = true
        refreshInteractionAppearance()
        defer {
            pointerPressed = false
            refreshInteractionAppearance()
        }
        BufferPopUpMenuController.shared.toggle(for: self)
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        BufferPopUpMenuController.shared.toggle(for: self)
    }

    /// The whole control is drawn here — base surface, pointer feedback, title,
    /// divider, and disclosure — so the layer only carries clipping.
    override func draw(_ dirtyRect: NSRect) {
        let state = previewPointerState ?? BufferWorkbenchPointerRules.state(
            enabled: isEnabled,
            hovered: pointerHovered,
            pressed: pointerPressed
        )
        let alpha: CGFloat = isEnabled ? 1 : 0.46
        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / max(scale, 1)
        let surface = bounds.insetBy(dx: hairline / 2, dy: hairline / 2)
        let shape = NSBezierPath(
            roundedRect: surface,
            xRadius: BufferPopUpControlMetrics.cornerRadius,
            yRadius: BufferPopUpControlMetrics.cornerRadius
        )
        RimeUI.surface2.withAlphaComponent(alpha).setFill()
        shape.fill()
        let pointerFill = BufferWorkbenchPointerRules.backgroundColor(for: state)
        if pointerFill != .clear {
            pointerFill.setFill()
            shape.fill()
        }
        let pointerBorder = BufferWorkbenchPointerRules.borderColor(for: state)
        (pointerBorder == .clear
            ? RimeUI.border.withAlphaComponent(alpha)
            : pointerBorder).setStroke()
        shape.lineWidth = hairline
        shape.stroke()

        let divider = BufferPopUpControlMetrics.dividerRect(in: bounds)
        RimeUI.border.withAlphaComponent(alpha).setFill()
        divider.fill()

        let titleRect = BufferPopUpControlMetrics.titleRect(in: bounds)
        if titleRect.width > 0 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: currentFont,
                .foregroundColor: (isEnabled
                    ? RimeUI.textPrimary
                    : RimeUI.textMuted),
                .paragraphStyle: paragraph,
            ]
            let text = currentTitle as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                in: NSRect(x: titleRect.minX,
                           y: titleRect.midY - size.height / 2,
                           width: titleRect.width,
                           height: size.height),
                withAttributes: attributes
            )
        }

        let disclosure = BufferPopUpControlMetrics.disclosureRect(in: bounds)
        (isEnabled ? RimeUI.textSecondary : RimeUI.textMuted).setStroke()
        let chevron = NSBezierPath()
        let half = BufferPopUpControlMetrics.chevronHalfWidth
        let height = BufferPopUpControlMetrics.chevronHeight
        // `NSPopUpButton` draws in a flipped coordinate system, so the apex of
        // a downward chevron is the larger y there and the smaller y elsewhere.
        let apexSign: CGFloat = isFlipped ? 1 : -1
        let shoulderY = disclosure.midY - apexSign * height / 2
        let apexY = disclosure.midY + apexSign * height / 2
        chevron.move(to: NSPoint(x: disclosure.midX - half, y: shoulderY))
        chevron.line(to: NSPoint(x: disclosure.midX, y: apexY))
        chevron.line(to: NSPoint(x: disclosure.midX + half, y: shoulderY))
        chevron.lineWidth = BufferPopUpControlMetrics.chevronLineWidth
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }

    func refreshInteractionAppearance() {
        wantsLayer = true
        layer?.cornerRadius = BufferPopUpControlMetrics.cornerRadius
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setPreviewPointerState(_ state: BufferWorkbenchPointerState?) {
        previewPointerState = state
        refreshInteractionAppearance()
    }

    private func configurePointerFeedback() {
        wantsLayer = true
        layer?.masksToBounds = true
        isBordered = false
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

/// A non-arranged sibling of the full-width rail. Its buttons float over the
/// rail's trailing edge, so showing or hiding an action never changes the
/// outer rail frame. Empty gaps pass through to the logical input surface.
private final class BufferRailActionClusterView: NSView {
    private var controls: [NSControl]
    private let row = NSStackView()
    private let fadeLayer = CAGradientLayer()
    private var widthConstraint: NSLayoutConstraint!

    init(controls: [NSControl]) {
        self.controls = controls
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(fadeLayer)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = BufferWorkbenchMetrics.shelfSpacing
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        controls.forEach { row.addArrangedSubview($0) }
        addSubview(row)

        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: BufferWorkbenchMetrics.actionOverlayFadeWidth
            ),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshGeometry()
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    var reservedWidth: CGFloat { widthConstraint.constant }
    var visibleControls: [NSControl] { controls.filter { !$0.isHidden } }

    /// A derived layout that splits source and target rails owns one trailing
    /// action per row, so the same button instance moves between clusters
    /// instead of existing twice with two delivery authorities.
    func setControls(_ newControls: [NSControl]) {
        let current = controls.map(ObjectIdentifier.init)
        guard current != newControls.map(ObjectIdentifier.init) else { return }
        for control in controls {
            row.removeArrangedSubview(control)
            control.removeFromSuperview()
        }
        controls = newControls
        newControls.forEach { row.addArrangedSubview($0) }
        refreshGeometry()
    }

    func refreshGeometry() {
        let visibleCount = visibleControls.count
        let controlsWidth = CGFloat(visibleCount) * BufferWorkbenchMetrics.controlSize
        let spacingWidth = CGFloat(max(0, visibleCount - 1))
            * BufferWorkbenchMetrics.shelfSpacing
        widthConstraint.constant = visibleCount == 0
            ? 0
            : BufferWorkbenchMetrics.actionOverlayFadeWidth
                + controlsWidth + spacingWidth
        isHidden = visibleCount == 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyAppearance() {
        let background = RimeUI.candidateBackgroundColor
        fadeLayer.colors = [
            background.withAlphaComponent(0).cgColor,
            background.withAlphaComponent(0.96).cgColor,
            background.cgColor,
        ]
        fadeLayer.locations = [0, 0.42, 1]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        fadeLayer.frame = bounds
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var candidate: NSView? = hit
        while let view = candidate, view !== self {
            if view is NSControl { return hit }
            candidate = view.superview
        }
        return nil
    }
}

/// Passive target identity beside Close. A valid exact focus lease uses the
/// application's real color icon; invalid/protected states immediately replace
/// it with a generic template symbol so stale application identity cannot leak.
private final class BufferTargetApplicationIndicatorView: NSView {
    private let imageView = NSImageView()
    private let statusDot = NSView()
    private var fallbackTint: NSColor = RimeUI.textMuted
    private var dotColor: NSColor = .systemGreen
    private(set) var renderedAppName: String?
    private(set) var renderedUsesRealApplicationIcon = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.borderWidth = 1
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(statusDot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            statusDot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(state: BufferTargetAssociationState,
                appName: String?,
                appIcon: NSImage?,
                title: String,
                help: String) {
        renderedAppName = nil
        renderedUsesRealApplicationIcon = false
        statusDot.isHidden = true

        switch state {
        case .capturing, .ready:
            if let appIcon {
                // `NSWorkspace` application icons contain lazily decoded
                // representations. A plain `NSImage.copy()` loses those
                // representations on current macOS and renders as an empty
                // square, so materialize one CG-backed image before display.
                let image = Self.materializedApplicationIcon(appIcon)
                imageView.image = image
                renderedUsesRealApplicationIcon = image != nil
                renderedAppName = image == nil ? nil : appName
            } else {
                imageView.image = RimeUI.symbol("app.dashed", pointSize: 13,
                                                weight: .semibold)
                imageView.image?.isTemplate = true
            }
            fallbackTint = RimeUI.textSecondary
            dotColor = .systemGreen
            statusDot.isHidden = false
        case .targetChanged:
            imageView.image = RimeUI.symbol("exclamationmark.triangle.fill",
                                            pointSize: 12, weight: .semibold)
            imageView.image?.isTemplate = true
            fallbackTint = .systemOrange
        case .unavailable:
            imageView.image = RimeUI.symbol("scope", pointSize: 12,
                                            weight: .semibold)
            imageView.image?.isTemplate = true
            fallbackTint = RimeUI.textMuted
        case .detached:
            imageView.image = RimeUI.symbol("doc.on.clipboard", pointSize: 12,
                                            weight: .semibold)
            imageView.image?.isTemplate = true
            fallbackTint = RimeUI.textMuted
        case .protected:
            imageView.image = RimeUI.symbol("lock.fill", pointSize: 11,
                                            weight: .semibold)
            imageView.image?.isTemplate = true
            fallbackTint = .systemOrange
        }

        toolTip = help
        setAccessibilityLabel(title)
        setAccessibilityHelp(help)
        applyAppearance()
    }

    private static func materializedApplicationIcon(_ source: NSImage) -> NSImage? {
        var proposedRect = NSRect(
            origin: .zero,
            size: source.size.width > 0 && source.size.height > 0
                ? source.size
                : NSSize(width: 32, height: 32)
        )
        guard let cgImage = source.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: 16, height: 16)
        )
        image.isTemplate = false
        return image
    }

    func applyAppearance() {
        imageView.contentTintColor = fallbackTint
        statusDot.layer?.backgroundColor = dotColor.cgColor
        statusDot.layer?.borderColor = RimeUI.candidateBackgroundColor.cgColor
    }

    /// The status remains part of the toolbar drag surface and never looks or
    /// behaves like a button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    private let associationGlowLayer = CAShapeLayer()
    private let associationMarkerLayer = CAShapeLayer()
    private let rastaAccentLayer = CALayer()
    private let rastaRedLayer = CALayer()
    private let rastaYellowLayer = CALayer()
    private let rastaGreenLayer = CALayer()
    private var associationMarker: BufferTargetAssociationMarker?
    private var associationGeneration: UInt64 = 0
    var fillColor: NSColor = .windowBackgroundColor {
        didSet { fillLayer.backgroundColor = fillColor.cgColor }
    }
    var strokeColor: NSColor = .separatorColor {
        didSet { strokeLayer.strokeColor = strokeColor.cgColor }
    }
    var showsRastaAccent = false {
        didSet {
            rastaAccentLayer.isHidden = !showsRastaAccent
            needsLayout = true
        }
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
        rastaAccentLayer.zPosition = 90
        rastaAccentLayer.masksToBounds = true
        rastaAccentLayer.addSublayer(rastaRedLayer)
        rastaAccentLayer.addSublayer(rastaYellowLayer)
        rastaAccentLayer.addSublayer(rastaGreenLayer)
        rastaAccentLayer.isHidden = true
        layer?.addSublayer(rastaAccentLayer)
        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = strokeColor.cgColor
        strokeLayer.zPosition = 100
        layer?.addSublayer(strokeLayer)
        for markerLayer in [associationGlowLayer, associationMarkerLayer] {
            markerLayer.fillColor = NSColor.clear.cgColor
            markerLayer.lineCap = .round
            markerLayer.lineJoin = .round
            markerLayer.opacity = 0
            markerLayer.zPosition = 120
            layer?.addSublayer(markerLayer)
        }
        associationGlowLayer.lineWidth = 5
        associationMarkerLayer.lineWidth = 2
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / max(scale, 1)
        strokeLayer.contentsScale = scale
        fillLayer.contentsScale = scale
        fillLayer.frame = bounds
        rastaAccentLayer.contentsScale = scale
        let accentInset = max(lineWidth, 1)
        let accentFrame = NSRect(
            x: accentInset,
            y: accentInset,
            width: max(0, bounds.width - accentInset * 2),
            height: 2
        )
        rastaAccentLayer.frame = accentFrame
        let third = accentFrame.width / 3
        rastaRedLayer.frame = NSRect(x: 0, y: 0, width: third, height: 2)
        rastaYellowLayer.frame = NSRect(x: third, y: 0, width: third, height: 2)
        rastaGreenLayer.frame = NSRect(
            x: third * 2,
            y: 0,
            width: max(0, accentFrame.width - third * 2),
            height: 2
        )
        rastaRedLayer.backgroundColor = RimeUI.brandRed.cgColor
        rastaYellowLayer.backgroundColor = RimeUI.brandYellow.cgColor
        rastaGreenLayer.backgroundColor = RimeUI.brandGreen.cgColor
        strokeLayer.frame = bounds
        strokeLayer.lineWidth = lineWidth
        strokeLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: max(0, 9 - lineWidth / 2),
            cornerHeight: max(0, 9 - lineWidth / 2),
            transform: nil
        )
        associationGlowLayer.contentsScale = scale
        associationMarkerLayer.contentsScale = scale
        associationGlowLayer.frame = bounds
        associationMarkerLayer.frame = bounds
        let associationPath = associationMarker.map { markerPath(for: $0) }
        associationGlowLayer.path = associationPath
        associationMarkerLayer.path = associationPath
    }

    func flashAssociation(_ marker: BufferTargetAssociationMarker,
                          accentColor: NSColor,
                          reduceMotion: Bool) {
        associationGeneration &+= 1
        let generation = associationGeneration
        associationMarker = marker
        associationGlowLayer.strokeColor = accentColor.withAlphaComponent(0.28).cgColor
        associationMarkerLayer.strokeColor = accentColor.cgColor
        associationGlowLayer.removeAllAnimations()
        associationMarkerLayer.removeAllAnimations()
        associationGlowLayer.opacity = 1
        associationMarkerLayer.opacity = 1
        needsLayout = true
        layoutSubtreeIfNeeded()

        if !reduceMotion {
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.14, 0.72, 1]
            opacity.duration = 0.70
            opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
            associationGlowLayer.opacity = 0
            associationMarkerLayer.opacity = 0
            associationGlowLayer.add(opacity, forKey: "buffer-target-glow")
            associationMarkerLayer.add(opacity, forKey: "buffer-target-marker")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) { [weak self] in
            guard let self, self.associationGeneration == generation else { return }
            self.clearAssociationMarker()
        }
    }

    func clearAssociationMarker() {
        associationGeneration &+= 1
        associationMarker = nil
        associationGlowLayer.removeAllAnimations()
        associationMarkerLayer.removeAllAnimations()
        associationGlowLayer.opacity = 0
        associationMarkerLayer.opacity = 0
        associationGlowLayer.path = nil
        associationMarkerLayer.path = nil
    }

    private func markerPath(for marker: BufferTargetAssociationMarker) -> CGPath {
        let path = CGMutablePath()
        let lineInset: CGFloat = 1.5
        let halfLength: CGFloat = 9
        let notchDepth: CGFloat = 5
        switch marker.edge {
        case .top:
            let x = bounds.minX + bounds.width * marker.position
            let y = bounds.maxY - lineInset
            path.move(to: CGPoint(x: x - halfLength, y: y))
            path.addLine(to: CGPoint(x: x - 3, y: y))
            path.addLine(to: CGPoint(x: x, y: y - notchDepth))
            path.addLine(to: CGPoint(x: x + 3, y: y))
            path.addLine(to: CGPoint(x: x + halfLength, y: y))
        case .bottom:
            let x = bounds.minX + bounds.width * marker.position
            let y = bounds.minY + lineInset
            path.move(to: CGPoint(x: x - halfLength, y: y))
            path.addLine(to: CGPoint(x: x - 3, y: y))
            path.addLine(to: CGPoint(x: x, y: y + notchDepth))
            path.addLine(to: CGPoint(x: x + 3, y: y))
            path.addLine(to: CGPoint(x: x + halfLength, y: y))
        case .left:
            let x = bounds.minX + lineInset
            let y = bounds.minY + bounds.height * marker.position
            path.move(to: CGPoint(x: x, y: y - halfLength))
            path.addLine(to: CGPoint(x: x, y: y - 3))
            path.addLine(to: CGPoint(x: x + notchDepth, y: y))
            path.addLine(to: CGPoint(x: x, y: y + 3))
            path.addLine(to: CGPoint(x: x, y: y + halfLength))
        case .right:
            let x = bounds.maxX - lineInset
            let y = bounds.minY + bounds.height * marker.position
            path.move(to: CGPoint(x: x, y: y - halfLength))
            path.addLine(to: CGPoint(x: x, y: y - 3))
            path.addLine(to: CGPoint(x: x - notchDepth, y: y))
            path.addLine(to: CGPoint(x: x, y: y + 3))
            path.addLine(to: CGPoint(x: x, y: y + halfLength))
        }
        return path
    }
}

/// Stable, nonactivating workbench window. It owns presentation only; all text
/// delivery still flows through BufferDeliveryCoordinator -> Delivery.insert.
final class BufferWindowController: NSObject, NSWindowDelegate {
    static let shared = BufferWindowController()

    private struct InlineCompositionProjection: Equatable {
        let owner: FocusToken
        let text: String
        let cursorPosUTF8: Int
    }

    private struct TargetApplicationIdentity {
        let name: String
        let icon: NSImage?
    }

    private enum Key {
        static let visible = "bufferWindow.visible.v1"
        static let frame = "bufferWindow.frame.v2"
        static let legacyFrame = "bufferWindow.frame.v1"
        static let pinned = "bufferWindow.pinned.v1"
        static let autoSend = "bufferWindow.autoSend.v1"
    }

    /// Seconds a block sits in the rail before it is delivered on its own.
    /// The chip dims across this window so the countdown is visible rather
    /// than a surprise.
    static let autoSendLifetime: TimeInterval = 1

    private let panel: BufferPanel
    private let outerContainer = NSView()
    private let visual = BufferChromeView()
    private let bufferRail = BufferInlineView()
    private let mainBar = NSStackView()
    private lazy var translationBridgeView = AppleTranslationWorkspace.shared.makeBridgeView()
    private let utilityShelf = BufferWorkbenchToolbarView()
    private let shelfDivider = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let functionMenuButton = FirstMouseButton(
        title: "",
        target: nil,
        action: nil
    )
    private let clipboardImportButton = FirstMouseButton(
        title: "",
        target: nil,
        action: nil
    )
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
    private let derivedOptionPickerPopup = FirstMousePopUpButton(
        frame: .zero,
        pullsDown: false
    )
    private let aiConnectorPopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let aiModelPopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let aiModePopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let aiOutputPopup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
    private let copyResultButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let targetApplicationIndicator = BufferTargetApplicationIndicatorView()
    private let sendButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let sendButtonProgressIndicator = NSProgressIndicator()
    private let exchangeEditButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let autoSendButton = FirstMouseButton(title: "", target: nil, action: nil)
    private let closeButton = FirstMouseButton(title: "", target: nil, action: nil)
    private lazy var railActionCluster = BufferRailActionClusterView(
        controls: [clipboardImportButton, copyResultButton, sendButton]
    )
    /// Only a split source/target layout uses this cluster; membership is
    /// reconciled per layout mode by `reconcileRailActionMembership`.
    private lazy var sourceActionCluster = BufferRailActionClusterView(controls: [])
    private lazy var exchangeEditSlot = BufferToolbarControlSlot(control: exchangeEditButton)
    private var railActionCenterYConstraint: NSLayoutConstraint?
    private var autoSendTimer: Timer?
    /// How long each block has been alive, keyed by block id. Accumulated
    /// rather than derived from a start date so an interruption pauses a
    /// countdown instead of restarting it, and each block ages on its own
    /// clock: one block leaving, or arriving, never touches another's.
    private var autoSendAges: [UUID: TimeInterval] = [:]
    /// Timestamp of the last tick that actually advanced ages. Cleared while
    /// paused so resuming does not credit the paused interval.
    private var autoSendLastTick: Date?
    private var sourceActionCenterYConstraint: NSLayoutConstraint?
    private var hiddenForSession = false
    private var sessionInactive = false
    private var screenLocked = false
    private var sleeping = false
    private var adjustingFrame = false
    private var toolbarExpanded = BufferWorkbenchLayout.toolbarInitiallyExpanded
    private var layoutMode: BufferWorkbenchLayoutMode = .standard
    private var mainBarHeightConstraint: NSLayoutConstraint?
    private var bufferRailHeightConstraint: NSLayoutConstraint?
    private var inlineCompositionProjection: InlineCompositionProjection?
    private var observers: [NSObjectProtocol] = []
    private var externalPointerMonitor: Any?
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
    private var renderingOptionPickerControls = false
    private var renderedBuiltInActionHasOptions: Bool?
    private var renderedTranslationLanguages: [TranslationLanguageOption] = []
    private var renderedBuiltInActionOptions: [BuiltInBufferActionOption] = []
    private var renderedDerivedOptionPickerOptions: [
        DerivedOptionPickerOption
    ] = []
    private var sendButtonUsesAccent = false
    private var renderedTargetAssociationState: BufferTargetAssociationState = .unavailable
    private var targetAssociationCueController: TargetAssociationCueController?
    private var targetAssociationCueToken: FocusToken?
    private var targetAssociationCueGeneration: UInt64 = 0
    private var openingSide: BufferOpeningSide = .bottomFallback
    private var openingFocusToken: FocusToken?
    private var transientOpeningOrigin = false
    private var persistedFrameOrigin: NSPoint?
    private var lastFocusFollowToken: FocusToken?
    private var scheduledFocusFollowToken: FocusToken?
    private var activeSpaceFocusFollowPending = false
    private(set) var workbenchSessionEpoch: UInt64 = 1

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
        clearTargetAssociationCue()
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
        candidateWindow.syncWorkbenchLayout()
        IMELog.write("buffer workbench width=\(configuredWidth)")
    }

    func resetConfiguredWidth() {
        setConfiguredWidth(760)
    }

    var closeAfterLastDeliveryEnabled: Bool {
        get { BufferWorkbenchPreferences.closeAfterLastDelivery() }
        set {
            BufferWorkbenchPreferences.setCloseAfterLastDelivery(newValue)
            IMELog.write("setting closeAfterLastDelivery=\(newValue)")
        }
    }

    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Key.pinned) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.pinned)
            applyCollectionBehavior()
            refresh()
        }
    }
    func shouldPresentCandidatesAtBufferCaret(for owner: FocusToken?) -> Bool {
        guard let owner else { return false }
        let capturesExactFocus = BufferModel.shared.capturesInput(for: owner)
            && InputFocusCoordinator.shared.interactionTarget(expected: owner) != nil
        return BufferCandidateRoutingRules.shouldFollowBufferCaret(
            workbenchVisible: isVisible,
            presentationProtected: hiddenForSession || sessionProtectionActive,
            secureInput: IsSecureEventInputEnabled(),
            capturesExactFocus: capturesExactFocus
        )
    }

    /// Projects Rime marked text into the passive Buffer rail and returns the
    /// exact internal caret in screen coordinates. The projection is scoped to
    /// one FocusToken and never enters BufferModel or plugin source state.
    func updateInlineComposition(preedit: String,
                                 cursorPosUTF8: Int,
                                 owner: FocusToken) -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard shouldPresentCandidatesAtBufferCaret(for: owner) else {
            clearInlineComposition(owner: owner)
            return nil
        }
        if !preedit.isEmpty {
            clearTargetAssociationCue(expected: owner)
        }
        let next = InlineCompositionProjection(
            owner: owner,
            text: preedit,
            cursorPosUTF8: cursorPosUTF8
        )
        if inlineCompositionProjection != next {
            inlineCompositionProjection = next
            renderInlineRail(preedit: preedit, cursorPosUTF8: cursorPosUTF8)
        }
        guard shouldPresentCandidatesAtBufferCaret(for: owner),
              inlineCompositionProjection?.owner == owner else {
            clearInlineComposition(owner: owner)
            return nil
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        bufferRail.reconcileTranslationDocumentGeometry()
        guard let rect = bufferRail.inputCaretScreenRect,
              BufferWindowGeometry.isPlausibleInputAnchor(
                rect,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
              ),
              shouldPresentCandidatesAtBufferCaret(for: owner) else {
            clearInlineComposition(owner: owner)
            return nil
        }
        return rect
    }

    func clearInlineComposition(owner: FocusToken? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let current = inlineCompositionProjection,
              owner == nil || owner == current.owner else { return }
        inlineCompositionProjection = nil
        if sessionProtectionActive || hiddenForSession || IsSecureEventInputEnabled() {
            _ = bufferRail.refresh(shielded: true, translationSnapshot: nil)
        } else {
            renderInlineRail(preedit: "", cursorPosUTF8: 0)
        }
    }

    func inlineInputCaretScreenRect(owner: FocusToken) -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard shouldPresentCandidatesAtBufferCaret(for: owner),
              inlineCompositionProjection?.owner == owner else { return nil }
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let rect = bufferRail.inputCaretScreenRect,
              shouldPresentCandidatesAtBufferCaret(for: owner) else { return nil }
        return rect
    }

    private override init() {
        dispatchPrecondition(condition: .onQueue(.main))
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
        panel = BufferPanel(contentRect: NSRect(x: 0, y: 0, width: 760,
                                                height: BufferWindowGeometry.height(
                                                    expanded: BufferWorkbenchLayout
                                                        .toolbarInitiallyExpanded,
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
        bufferRail.onDerivedTargetStep = { [weak self] delta in
            self?.moveDerivedTargetSelection(delta: delta)
        }
        bufferRail.onCaptureRequested = { [weak self] insertionIndex in
            self?.activateLogicalInput(at: insertionIndex)
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
        if visible { show(repositionOnOpen: false) }
    }

    func show() {
        show(repositionOnOpen: true)
    }

    private func show(repositionOnOpen: Bool) {
        let rimeOwnsInput = RimeInputSourceAuthority.currentSourceIsOwn()
        if !rimeOwnsInput {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "external input source workbench"
            )
        }
        let wasVisibleOnActiveSpace = isVisible
        if !wasVisibleOnActiveSpace { workbenchSessionEpoch &+= 1 }
        UserDefaults.standard.set(true, forKey: Key.visible)
        guard !sessionProtectionActive else {
            hiddenForSession = true
            return
        }
        hiddenForSession = false
        if !wasVisibleOnActiveSpace {
            setToolbarExpanded(false, resize: false)
        }
        BufferModel.shared.resumeWorkbenchProcessing()
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
        if rimeOwnsInput {
            RimeBufferController.refreshActiveUI()
        }
    }

    /// Compatibility entry for explicit “enable Buffer” actions. Visibility
    /// itself no longer implies capture; this method requests an exact-focus
    /// capture grant and still shows the workbench when no trusted field exists.
    func openAndResume() {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "external input source clipboard channel"
            )
            show()
            IMELog.write("buffer opened with detached clipboard channel")
            return
        }
        if !activateCaptureForCurrentFocus(showWorkbench: true) {
            show()
        }
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
        BufferPopUpMenuController.shared.dismiss()
        workbenchSessionEpoch &+= 1
        applyTargetAssociationPresentation(state: .unavailable, appName: nil)
        setToolbarExpanded(false, resize: true)
        clearInlineComposition()
        UserDefaults.standard.set(false, forKey: Key.visible)
        panel.orderOut(nil)
        RimeBufferController.refreshActiveUI()
    }

    /// The optional external-app privacy purge clears staged plaintext and all
    /// plugin state before a different application can become the target.
    func discardForPrivacyTransition() {
        applyTargetAssociationPresentation(state: .unavailable, appName: nil)
        clearInlineComposition()
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BufferModel.shared.routeDirectPreservingContent(
            reason: "privacy transition"
        )
        BufferModel.shared.discardForPrivacy()
    }

    /// Product default: close means resolve only a composition currently owned
    /// by Buffer, pause capture, keep staged blocks, settle transient state,
    /// then hide. Clipboard-only presentation must not commit host composition.
    func closeAndPause() {
        pauseAndHide(settleCapturedComposition: true)
    }

    /// Generated-result copy is intentionally a clipboard-only path. It does
    /// not prepare, consume, or deliver blocks, so the Clipboard History
    /// monitor can archive the new pasteboard value exactly like an external
    /// copy while the generated workspace remains intact.
    var canCopyGeneratedResult: Bool {
        guard Thread.isMainThread,
              isVisible,
              !hiddenForSession,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled() else {
            return false
        }
        return BufferGeneratedResultCopyRules.freeze(protected: false) != nil
    }

    @discardableResult
    func copyGeneratedResultAndClose(expectedToken: FocusToken? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard canCopyGeneratedResult else { return false }
        if let expectedToken {
            guard BufferModel.shared.capturesInput(for: expectedToken),
                  InputFocusCoordinator.shared.liveTarget(
                    expected: expectedToken,
                    forceOverlayVisibilityRefresh: true
                  ) != nil else {
                return false
            }
        }
        guard let snapshot = BufferGeneratedResultCopyRules.freeze(
            protected: false
        ), let text = BufferGeneratedResultCopyRules.revalidatedText(
            for: snapshot,
            protected: sessionProtectionActive
                || hiddenForSession
                || IsSecureEventInputEnabled()
        ) else {
            NSSound.beep()
            return false
        }
        if let expectedToken {
            guard BufferModel.shared.capturesInput(for: expectedToken),
                  InputFocusCoordinator.shared.liveTarget(
                    expected: expectedToken,
                    forceOverlayVisibilityRefresh: true
                  ) != nil else {
                return false
            }
        }
        guard !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              BufferTextPasteboardWriter.write(
                text,
                to: NSPasteboard.general
              ) else {
            NSSound.beep()
            return false
        }
        IMELog.write(
            "buffer generated result copied workspace=\(snapshot.workspaceID) "
                + "blocks=\(snapshot.blockIDs.count) bytes=\(text.utf8.count)"
        )
        // Copying a generated result must not settle or deliver a concurrently
        // staged source composition. It only pauses capture after the new
        // clipboard value has been committed.
        pauseAndHide(settleCapturedComposition: false)
        return true
    }

    /// External input methods use Buffer as a clipboard-backed workbench. The
    /// copy path never manufactures a focus token or writes to an IMK client.
    @discardableResult
    func copyDetachedBufferAndClose() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !RimeInputSourceAuthority.currentSourceIsOwn(),
              isVisible,
              !hiddenForSession,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled() else { return false }
        if canCopyGeneratedResult {
            // Once the visible action resolved to the generated result, keep
            // that meaning stable. A stale workspace snapshot or a failed
            // pasteboard write must not silently copy the staged source.
            return copyGeneratedResultAndClose()
        }
        let text = BufferModel.shared.stagedText
        guard !text.isEmpty else { return false }
        guard !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              BufferTextPasteboardWriter.write(
                text,
                to: NSPasteboard.general
              ) else { return false }
        IMELog.write(
            "buffer detached content copied chars=\(text.count) blocks="
                + "\(BufferModel.shared.blocks.count)"
        )
        pauseAndHide(settleCapturedComposition: false)
        return true
    }

    @discardableResult
    private func importClipboardText() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isVisible,
              !hiddenForSession,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled() else { return false }
        let pasteboard = NSPasteboard.general
        let expectedChangeCount = pasteboard.changeCount
        guard let text = BufferDetachedClipboardRules.acceptedText(
            pasteboard.string(forType: .string)
        ), pasteboard.changeCount == expectedChangeCount,
           !sessionProtectionActive,
           !IsSecureEventInputEnabled() else { return false }
        if !RimeInputSourceAuthority.currentSourceIsOwn() {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "clipboard import under external input source"
            )
        }
        guard BufferModel.shared.insertPastedText(
            text,
            origin: .clipboard
        ) else { return false }
        refresh()
        IMELog.write("buffer clipboard import accepted chars=\(text.count)")
        return true
    }

    @discardableResult
    func dismissFromEscape() -> Bool {
        guard isVisible else { return false }
        pauseAndHide(settleCapturedComposition: true)
        IMELog.write("buffer workbench closed by escape")
        return true
    }

    private func pauseAndHide(settleCapturedComposition: Bool) {
        if settleCapturedComposition,
           RimeInputSourceAuthority.currentSourceIsOwn(),
           let target = InputFocusCoordinator.shared.owner,
           InputFocusCoordinator.shared.isCurrent(target.token),
           BufferModel.shared.capturesInput(for: target.token),
           target.compositionActive {
            target.controller?.resolveCompositionForWorkbenchTransition(
                target: target
            )
        }
        clearInlineComposition()
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BuiltInBufferActionWorkspaceRouter.selectedWorkspace?.workbenchWillPause()
        BufferModel.shared.pauseCapturePreservingContent()
        hideWithoutPausing()
    }

    func toggleVisibility() {
        if isVisible {
            closeAndPause()
        } else {
            openAndResume()
        }
    }

    /// Selection changes invalidate any delayed plugin-delivery completion
    /// that was frozen under the previous owner.
    func notePluginSelectionChanged() {
        workbenchSessionEpoch &+= 1
    }

    func closeAfterTerminalDrain(
        _ context: BufferDeliveryCoordinator.TerminalDrainContext
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentSource = BufferDeliveryContentRouter.current()
        guard closeAfterLastDeliveryEnabled,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              context.workbenchSessionEpoch == workbenchSessionEpoch,
              context.matchesCurrentSource(currentSource),
              isVisible,
              !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              InputFocusCoordinator.shared.liveTarget(
                expected: context.targetToken,
                forceOverlayVisibilityRefresh: true
              ) != nil else {
            IMELog.write("buffer terminal auto-close ignored workspace=\(context.workspaceID) attempt=\(context.attemptID)")
            return
        }

        // Do not settle a host composition here: the receipt belongs to the
        // completed plugin result, while the user may already have resumed
        // direct typing during an asynchronous target validation.
        pauseAndHide(settleCapturedComposition: false)
        IMELog.write("buffer terminal drain closed workbench workspace=\(context.workspaceID) attempt=\(context.attemptID)")
    }

    func moveToCurrentScreen() {
        clearTargetAssociationCue()
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
        candidateWindow.syncWorkbenchLayout()
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
                          panelWidth: CGFloat = 760,
                          translationSnapshot: TranslationRailSnapshot? = nil,
                          presentationStyle: BufferDerivedPresentationStyle = .liveExpand,
                          statusIndicators: [WorkbenchStatusIndicator]? = nil,
                          hoveredControl: BufferWorkbenchControl? = nil,
                          candidatePreview: Bool = false,
                          targetAssociationPreviewAppName: String? = nil,
                          toolbarExpanded previewToolbarExpanded: Bool = false) -> Bool {
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
        setToolbarExpanded(previewToolbarExpanded, resize: false)
        syncLayoutMode(previewMode)
        adjustingFrame = true
        panel.setFrame(NSRect(x: 0, y: 0, width: panelWidth,
                              height: BufferWindowGeometry.height(
                                  expanded: toolbarExpanded,
                                  mode: previewMode
                              )),
                       display: false)
        adjustingFrame = false
        if let translationSnapshot {
            setWorkbenchStatusText(BufferWorkbenchStatusPresentation.text(
                fallback: translationSnapshot.showsSourceRail
                    ? "译文可发送"
                    : translationSnapshot.targetEmptyText,
                snapshot: translationSnapshot,
                style: previewStyle
            ))
            let showsCopy = translationSnapshot.phase == .ready
                && !translationSnapshot.outputBlocks.isEmpty
            copyResultButton.isHidden = !showsCopy
            copyResultButton.isEnabled = showsCopy
            _ = bufferRail.renderTranslationForPreview(
                translationSnapshot,
                presentationStyle: previewStyle
            )
            applyAppearance()
        } else {
            refresh()
            if candidatePreview {
                _ = bufferRail.renderStandardForPreview(
                    preedit: "wai'mian",
                    preeditCursorPosUTF8: 3
                )
            }
        }
        if let targetAssociationPreviewAppName {
            setWorkbenchStatusText("")
            let previewApplicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Safari"
            )
            let previewApplicationIcon = previewApplicationURL.map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
            applyTargetAssociationPresentation(
                state: .capturing,
                appName: targetAssociationPreviewAppName,
                appIcon: previewApplicationIcon
            )
            setSendButtonGenerating(false)
            setSendButtonSymbol("paperplane.fill")
            sendButton.isEnabled = true
            sendButton.toolTip = "发送下一块（\(deliveryShortcutTitle)）"
            sendButton.setAccessibilityLabel("发送下一块")
            sendButtonUsesAccent = false
            applyAppearance()
        }
        if let statusIndicators {
            reconcileContextualStatusIndicators(statusIndicators)
        }
        refreshRailActionOverlayGeometry()
        applyAppearance()
        applyPreviewPointerState(hoveredControl)
        return renderCurrentContent(to: path, scale: scale)
    }

    /// Advances a set of independent block ages by one tick. Each block owns
    /// its own age, an interruption pauses rather than resets, and the head is
    /// the only block eligible to leave because delivery is ordered.
    static func autoSendTickForSmoke(
        ages: [UUID: TimeInterval],
        order: [UUID],
        elapsed: TimeInterval,
        deliverable: Bool
    ) -> (ages: [UUID: TimeInterval], sends: UUID?) {
        guard deliverable else { return (ages: ages, sends: nil) }
        let advance = min(max(elapsed, 0), autoSendLifetime)
        var next: [UUID: TimeInterval] = [:]
        for id in order { next[id] = (ages[id] ?? 0) + advance }
        guard let head = order.first,
              (next[head] ?? 0) >= autoSendLifetime else {
            return (ages: next, sends: nil)
        }
        next.removeValue(forKey: head)
        return (ages: next, sends: head)
    }

    /// Pure rules behind the auto-send switch, so its safety conditions are
    /// checkable without a live focus lease or a real host to type into.
    static func autoSendDecisionForSmoke(
        enabled: Bool,
        deliverable: Bool,
        secureInput: Bool,
        age: TimeInterval
    ) -> (fades: Bool, sends: Bool) {
        guard enabled, deliverable, !secureInput else {
            return (fades: false, sends: false)
        }
        return (fades: true, sends: age >= autoSendLifetime)
    }

    /// Exercises the approved in-rail action layout against the real view tree
    /// at both ordinary and narrow widths. The probe changes presentation-only
    /// state and does not read or write the pasteboard or deliver any text.
    func exerciseRailActionOverlayForSmoke(
        panelWidth: CGFloat
    ) -> BufferRailActionOverlaySmokeResult {
        setToolbarExpanded(true, resize: false)
        syncLayoutMode(.standard)
        let currentOrigin = panel.frame.origin
        adjustingFrame = true
        panel.setFrame(
            NSRect(
                origin: currentOrigin,
                size: NSSize(
                    width: panelWidth,
                    height: BufferWindowGeometry.height(
                        expanded: true,
                        mode: .standard
                    )
                )
            ),
            display: false
        )
        adjustingFrame = false
        _ = bufferRail.renderStandardForPreview()

        clipboardImportButton.isHidden = false
        clipboardImportButton.isEnabled = true
        sendButton.isHidden = false
        sendButton.isEnabled = true
        copyResultButton.isHidden = true
        refreshRailActionOverlayGeometry()
        panel.contentView?.layoutSubtreeIfNeeded()
        let railFrameWithTwoActions = bufferRail.convert(
            bufferRail.bounds,
            to: mainBar
        )

        copyResultButton.isHidden = false
        copyResultButton.isEnabled = true
        refreshRailActionOverlayGeometry()
        panel.contentView?.layoutSubtreeIfNeeded()

        let railFrameWithThreeActions = bufferRail.convert(
            bufferRail.bounds,
            to: mainBar
        )
        let overlayFrame = railActionCluster.convert(
            railActionCluster.bounds,
            to: mainBar
        )
        let actionControls = railActionCluster.visibleControls
        let actionFrames = actionControls.map {
            $0.convert($0.bounds, to: mainBar)
        }
        let epsilon: CGFloat = 0.5
        let ordered = zip(actionFrames, actionFrames.dropFirst()).allSatisfy {
            lhs, rhs in
            lhs.maxX <= rhs.minX + epsilon
                && abs(lhs.midY - rhs.midY) <= epsilon
        }
        let finiteFrames = ([railFrameWithTwoActions,
                             railFrameWithThreeActions,
                             overlayFrame] + actionFrames).allSatisfy { rect in
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0
                && rect.height > 0
        }

        func hitBelongsToView(_ hit: NSView?, view expectedView: NSView) -> Bool {
            var candidate = hit
            while let view = candidate {
                if view === expectedView { return true }
                candidate = view.superview
            }
            return false
        }
        let actionHitTestingWorks = zip(actionControls, actionFrames).allSatisfy {
            control, frame in
            hitBelongsToView(
                mainBar.hitTest(NSPoint(x: frame.midX, y: frame.midY)),
                view: control
            )
        }
        let fadePoint = NSPoint(
            x: overlayFrame.minX + 2,
            y: overlayFrame.midY
        )
        let fadeHit = mainBar.hitTest(fadePoint)
        let fadeAreaPassesThrough = hitBelongsToView(fadeHit, view: bufferRail)

        functionMenuButton.isEnabled = true
        functionMenuButton.refreshInteractionAppearance()
        let interactiveSurfaceVisibleAtIdle =
            functionMenuButton.showsPersistentInteractionSurface
            && (functionMenuButton.layer?.backgroundColor?.alpha ?? 0) > 0
            && (functionMenuButton.layer?.borderWidth ?? 0) > 0
        let interactiveAccessibilityLabelsAreReadable = [
            functionMenuButton, clipboardImportButton, copyResultButton,
            sendButton, exchangeEditButton, closeButton,
        ].allSatisfy { button in
            guard let label = button.accessibilityLabel()?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { return false }
            return !label.contains("arrow.")
                && !label.contains("rectangle.")
                && !label.contains("paperplane")
                && label != "text.cursor"
                && label != "xmark"
        }
        let functionMenuOwnsOnlyPluginIcon = functionMenuButton.image != nil
            && pluginSelector.itemArray.allSatisfy { $0.image == nil }

        let previewApplicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        )
        let previewApplicationIcon = previewApplicationURL.map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
        applyTargetAssociationPresentation(
            state: .capturing,
            appName: "Safari",
            appIcon: previewApplicationIcon
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        let targetFrame = targetApplicationIndicator.convert(
            targetApplicationIndicator.bounds,
            to: utilityShelf
        )
        let closeFrame = closeButton.convert(closeButton.bounds, to: utilityShelf)
        let targetApplicationIconIsReal =
            targetApplicationIndicator.renderedUsesRealApplicationIcon
            && targetApplicationIndicator.renderedAppName == "Safari"
        let targetApplicationIndicatorIsPassive =
            targetApplicationIndicator.hitTest(.zero) == nil
            && targetApplicationIndicator.layer?.backgroundColor == nil
        let toolbarFramesFinite = [targetFrame, closeFrame].allSatisfy { rect in
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0
                && rect.height > 0
        }
        let targetApplicationIconPrecedesClose = toolbarFramesFinite
            && targetFrame.maxX <= closeFrame.minX + epsilon
            && abs(closeFrame.minX - targetFrame.maxX
                - BufferWorkbenchMetrics.shelfSpacing) <= epsilon

        applyTargetAssociationPresentation(
            state: .protected,
            appName: nil,
            appIcon: nil
        )
        let protectedStateScrubsApplicationIdentity =
            !targetApplicationIndicator.renderedUsesRealApplicationIcon
            && targetApplicationIndicator.renderedAppName == nil

        let inspectedViews: [NSView] = [
            utilityShelf, mainBar, bufferRail, railActionCluster,
            clipboardImportButton, copyResultButton, sendButton,
            functionMenuButton, targetApplicationIndicator, closeButton,
        ]
        let hasAmbiguousLayout = inspectedViews.contains {
            $0.hasAmbiguousLayout
        }
        let overlayIsNonArrangedSibling = railActionCluster.superview === mainBar
            && !mainBar.arrangedSubviews.contains { $0 === railActionCluster }
            && mainBar.arrangedSubviews.count == 1
            && mainBar.arrangedSubviews.first === bufferRail
        let overlayContainedByRail = railFrameWithThreeActions
            .insetBy(dx: -epsilon, dy: -epsilon)
            .contains(overlayFrame)

        return BufferRailActionOverlaySmokeResult(
            panelWidth: panelWidth,
            railFrameWithTwoActions: railFrameWithTwoActions,
            railFrameWithThreeActions: railFrameWithThreeActions,
            overlayFrame: overlayFrame,
            actionFrames: actionFrames,
            overlayIsNonArrangedSibling: overlayIsNonArrangedSibling,
            overlayContainedByRail: overlayContainedByRail,
            actionsOrderedOnOneRow: finiteFrames
                && actionFrames.count == 3
                && ordered,
            actionHitTestingWorks: actionHitTestingWorks,
            fadeAreaPassesThrough: fadeAreaPassesThrough,
            interactiveSurfaceVisibleAtIdle: interactiveSurfaceVisibleAtIdle,
            interactiveAccessibilityLabelsAreReadable:
                interactiveAccessibilityLabelsAreReadable,
            functionMenuOwnsOnlyPluginIcon: functionMenuOwnsOnlyPluginIcon,
            targetApplicationIconIsReal: targetApplicationIconIsReal,
            targetApplicationIndicatorIsPassive:
                targetApplicationIndicatorIsPassive,
            targetApplicationIconPrecedesClose:
                targetApplicationIconPrecedesClose,
            protectedStateScrubsApplicationIdentity:
                protectedStateScrubsApplicationIdentity,
            hasAmbiguousLayout: hasAmbiguousLayout
        )
    }

    /// Exercises one real `NSPanel` and its existing constraints through the
    /// exact compact -> live-derived -> compact lifecycle. The optional PNGs
    /// make a failed geometry assertion directly inspectable without adding a
    /// second preview implementation.
    func exerciseLayoutTransitionForSmoke(
        standardBeforePath: String? = nil,
        derivedPath: String? = nil,
        standardAfterPath: String? = nil,
        scale: CGFloat = 2
    ) -> BufferWindowLayoutTransitionSmokeResult {
        setToolbarExpanded(false, resize: false)
        let standardMode = BufferWorkbenchLayoutMode.standard
        let derivedMode = BufferWorkbenchLayoutMode.translation
        let expectedStandardHeight = BufferWindowGeometry.height(
            expanded: true,
            mode: standardMode
        )
        let expectedDerivedHeight = BufferWindowGeometry.height(
            expanded: true,
            mode: derivedMode
        )

        func reconcile(
            mode: BufferWorkbenchLayoutMode,
            render: () -> Void
        ) {
            let grows = BufferWorkbenchMetrics.railHeight(for: mode)
                > BufferWorkbenchMetrics.railHeight(for: layoutMode)
            if mode != layoutMode, grows {
                syncLayoutMode(mode)
                panel.contentView?.layoutSubtreeIfNeeded()
            }
            render()
            if mode != layoutMode {
                syncLayoutMode(mode)
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            bufferRail.reconcileTranslationDocumentGeometry()
        }

        reconcile(mode: standardMode) {
            _ = bufferRail.renderStandardForPreview()
        }
        let standardBefore = panel.frame
        let renderedStandardBefore = standardBeforePath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        let derivedSnapshot = TranslationRailSnapshot(
            sourceText: "同一窗口先展开为双轨",
            outputBlocks: [
                TranslationOutputBlock(
                    id: UUID(),
                    text: "再验证它能缩回单轨"
                ),
            ],
            phase: .ready
        )
        reconcile(mode: derivedMode) {
            _ = bufferRail.renderTranslationForPreview(derivedSnapshot)
        }
        let derived = panel.frame
        let renderedDerived = derivedPath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        reconcile(mode: standardMode) {
            _ = bufferRail.renderStandardForPreview()
        }
        let standardAfter = panel.frame
        let renderedStandardAfter = standardAfterPath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        // Reproduce the delayed AppKit case that motivated the repair: the
        // enum and constraints have already returned to standard, but the
        // window receives one stale derived-sized frame on the following
        // layout turn. A same-mode sync must still restore compact geometry.
        var staleFrame = panel.frame
        staleFrame.size.height = expectedDerivedHeight
        adjustingFrame = true
        panel.setFrame(staleFrame, display: false)
        adjustingFrame = false
        syncLayoutMode(standardMode)
        panel.contentView?.layoutSubtreeIfNeeded()
        let repairedStandard = panel.frame

        return BufferWindowLayoutTransitionSmokeResult(
            standardBefore: standardBefore,
            derived: derived,
            standardAfter: standardAfter,
            repairedStandard: repairedStandard,
            expectedStandardHeight: expectedStandardHeight,
            expectedDerivedHeight: expectedDerivedHeight,
            renderedAllFrames: renderedStandardBefore
                && renderedDerived
                && renderedStandardAfter
        )
    }

    /// Exercises the permanent toolbar against the real AppKit stack. Collapse
    /// requests are ignored, so every sampled frame stays at the expanded
    /// height with the shelf visible.
    func exerciseToolbarToggleForSmoke(
        collapsedPath: String? = nil,
        expandedPath: String? = nil,
        collapsedAgainPath: String? = nil,
        scale: CGFloat = 2
    ) -> BufferToolbarToggleSmokeResult {
        syncLayoutMode(.standard)
        _ = bufferRail.renderStandardForPreview()

        setToolbarExpanded(false, resize: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        let collapsed = panel.frame
        let toolbarHiddenInitially = utilityShelf.isHidden && shelfDivider.isHidden
        let renderedCollapsed = collapsedPath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        setToolbarExpanded(true, resize: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        let expanded = panel.frame
        let toolbarVisibleWhenExpanded = !utilityShelf.isHidden && !shelfDivider.isHidden
        let renderedExpanded = expandedPath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        setToolbarExpanded(false, resize: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        let collapsedAgain = panel.frame
        let toolbarHiddenAfterCollapse = utilityShelf.isHidden && shelfDivider.isHidden
        let renderedCollapsedAgain = collapsedAgainPath.map {
            renderCurrentContent(to: $0, scale: scale)
        } ?? true

        return BufferToolbarToggleSmokeResult(
            collapsed: collapsed,
            expanded: expanded,
            collapsedAgain: collapsedAgain,
            toolbarHiddenInitially: toolbarHiddenInitially,
            toolbarVisibleWhenExpanded: toolbarVisibleWhenExpanded,
            toolbarHiddenAfterCollapse: toolbarHiddenAfterCollapse,
            renderedAllFrames: renderedCollapsed
                && renderedExpanded
                && renderedCollapsedAgain
        )
    }

    private func renderCurrentContent(to path: String, scale: CGFloat) -> Bool {
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

    private func resolvedLayoutMode(
        workspaceSelected: Bool,
        style: BufferDerivedPresentationStyle,
        snapshot: TranslationRailSnapshot?,
        preedit: String
    ) -> BufferWorkbenchLayoutMode {
        guard workspaceSelected else { return .standard }
        if !preedit.isEmpty,
           let snapshot,
           BufferDerivedPresentationRules.visibleRails(
                style: style,
                snapshot: snapshot
           ).showsTarget {
            return .derived(targetRows: 1)
        }
        return BufferDerivedPresentationRules.layoutMode(
            style: style,
            snapshot: snapshot
        )
    }

    /// Re-renders only the text rail for a composition keystroke. Toolbar,
    /// provider status and plugin controls do not need to churn at IME speed.
    private func renderInlineRail(preedit: String, cursorPosUTF8: Int) {
        let contentProtected = sessionProtectionActive
            || hiddenForSession
            || IsSecureEventInputEnabled()
        guard !contentProtected else {
            _ = bufferRail.refresh(shielded: true, translationSnapshot: nil)
            return
        }
        let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace
        let snapshot = workspace?.railSnapshot
        let style = BufferDerivedPresentationRules.style(
            for: workspace?.workspacePluginKey
        )
        let nextMode = resolvedLayoutMode(
            workspaceSelected: workspace != nil,
            style: style,
            snapshot: snapshot,
            preedit: preedit
        )
        let grows = BufferWorkbenchMetrics.railHeight(for: nextMode)
            > BufferWorkbenchMetrics.railHeight(for: layoutMode)
        if nextMode != layoutMode, grows {
            syncLayoutMode(nextMode)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        _ = bufferRail.refresh(
            preedit: preedit,
            preeditCursorPosUTF8: cursorPosUTF8,
            shielded: false,
            translationSnapshot: snapshot,
            presentationStyle: style
        )
        if nextMode != layoutMode { syncLayoutMode(nextMode) }
        panel.contentView?.layoutSubtreeIfNeeded()
        bufferRail.reconcileTranslationDocumentGeometry()
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let secureInputEnabled = IsSecureEventInputEnabled()
        let rimeOwnsInput = RimeInputSourceAuthority.currentSourceIsOwn()
        let contentProtected = secureInputEnabled || sessionProtectionActive
        if contentProtected {
            BufferPopUpMenuController.shared.dismiss()
            setToolbarExpanded(false, resize: true)
        }
        syncPanelLevel(
            secureInputEnabled: secureInputEnabled,
            rimeOwnsInput: rimeOwnsInput
        )
        if contentProtected {
            inlineCompositionProjection = nil
            BufferModel.shared.clearAllContentSelection(notify: false)
            candidateWindow.hideAll()
            // Scrub every text-bearing view before protection notifications or
            // frame changes can synchronously re-enter AppKit and repaint the
            // old source/candidates at a smaller layout.
            _ = bufferRail.refresh(
                shielded: true,
                translationSnapshot: nil
            )
        }
        pluginSelector.isEnabled = !contentProtected
        clipboardImportButton.isEnabled = !contentProtected
        clipboardImportButton.toolTip = contentProtected
            ? "受保护状态下不能读取剪贴板"
            : "从系统剪贴板导入文字"
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
        let inlineComposition: InlineCompositionProjection?
        if rimeOwnsInput,
           !contentProtected,
           let projection = inlineCompositionProjection,
           shouldPresentCandidatesAtBufferCaret(for: projection.owner) {
            inlineComposition = projection
        } else {
            inlineCompositionProjection = nil
            inlineComposition = nil
        }
        let availability: BufferDeliveryCoordinator.Availability
        if contentProtected {
            availability = .blocked(.secureInput)
        } else if rimeOwnsInput {
            availability = BufferDeliveryCoordinator.shared.availability()
        } else {
            // Detached mode must not resolve a FocusToken merely to render UI.
            availability = .blocked(.noFocusedField)
        }
        let associationTarget = !contentProtected && rimeOwnsInput
            ? InputFocusCoordinator.shared.liveTarget()
            : nil
        refreshTargetAssociation(
            rimeOwnsInput: rimeOwnsInput,
            contentProtected: contentProtected,
            liveTarget: associationTarget
        )
        // Row reconciliation and panel geometry are one visual transaction.
        // Grow before attaching a new row; shrink only after stale rows have
        // been removed. Otherwise NSScrollView captures a 0pt/old document
        // frame and AppKit permanently breaks the third row's constraints.
        let nextLayoutMode = resolvedLayoutMode(
            workspaceSelected: derivedWorkspaceSelected,
            style: derivedPresentationStyle,
            snapshot: derivedSnapshot,
            preedit: inlineComposition?.text ?? ""
        )
        let layoutChanged = layoutMode != nextLayoutMode
        if layoutChanged {
            clearTargetAssociationCue()
        }
        let grows = BufferWorkbenchMetrics.railHeight(for: nextLayoutMode)
            > BufferWorkbenchMetrics.railHeight(for: layoutMode)
        if layoutChanged {
            panel.disableScreenUpdatesUntilFlush()
        }
        if layoutChanged, grows {
            syncLayoutMode(nextLayoutMode)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
        refreshGeneratedResultCopy(
            contentProtected: contentProtected,
            detachedClipboardMode: !rimeOwnsInput
        )
        _ = bufferRail.refresh(
            preedit: inlineComposition?.text ?? "",
            preeditCursorPosUTF8: inlineComposition?.cursorPosUTF8 ?? 0,
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
        } else if !contentProtected, !rimeOwnsInput {
            rawStatusText = BufferModel.shared.stagedText.isEmpty
                ? "剪贴板通道 · 可导入"
                : "剪贴板通道 · 可复制"
        } else {
            rawStatusText = BufferWorkbenchStatusText.text(
                for: availability,
                secureInput: secureInputEnabled,
                pluginFailure: pluginFailure,
                canGenerateWithoutFocus: canGenerateWithoutFocus
            )
        }
        setWorkbenchStatusText(BufferWorkbenchStatusPresentation.text(
            fallback: rawStatusText,
            snapshot: contentProtected ? nil : derivedSnapshot,
            style: derivedPresentationStyle
        ))
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

        assert(
            !contentProtected
                || bufferRail.renderedTextFragments == ["内容已隐藏"],
            "secure input must leave only the sanitized rail message visible"
        )
        refreshPrimaryAction(controls: WorkbenchManualGenerationRouter.selectedControls,
                             availability: availability,
                             contentProtected: contentProtected,
                             detachedClipboardMode: !rimeOwnsInput)
        refreshExchangeActions(
            style: derivedPresentationStyle,
            snapshot: derivedSnapshot,
            contentProtected: contentProtected
        )
        refreshPluginActions()
        refreshInputOptionsControl(contentProtected: contentProtected)
        refreshRailActionOverlayGeometry()
        applyAppearance()
        if inlineComposition != nil {
            candidateWindow.syncWorkbenchLayout()
        }
    }

    private func refreshTargetAssociation(rimeOwnsInput: Bool,
                                          contentProtected: Bool,
                                          liveTarget: FocusLease?) {
        let model = BufferModel.shared
        let capturedToken = model.captureFocusToken
        let capturedTargetIsLive = capturedToken != nil
            && liveTarget?.token == capturedToken
            && model.capturesInput(for: liveTarget?.token)
        let state = BufferTargetAssociationRules.state(
            rimeOwnsInput: rimeOwnsInput,
            contentProtected: contentProtected,
            captureActive: model.active,
            capturedTargetIsLive: capturedTargetIsLive,
            hasLiveTarget: liveTarget != nil
        )
        let targetForIdentity: FocusLease?
        switch state {
        case .capturing, .ready:
            targetForIdentity = liveTarget
        case .targetChanged, .unavailable, .detached, .protected:
            targetForIdentity = nil
        }
        let identity = targetApplicationIdentity(for: targetForIdentity)
        applyTargetAssociationPresentation(
            state: state,
            appName: identity?.name,
            appIcon: identity?.icon,
            targetToken: targetForIdentity?.token
        )
    }

    private func applyTargetAssociationPresentation(
        state: BufferTargetAssociationState,
        appName: String?,
        appIcon: NSImage? = nil,
        targetToken: FocusToken? = nil
    ) {
        renderedTargetAssociationState = state
        let fullTitle: String
        let help: String
        switch state {
        case .capturing:
            fullTitle = "\(appName ?? "当前应用") · 输入到 Buffer"
            help = "Buffer 正在接收按键；发送会返回到 \(appName ?? "当前应用") 的当前输入框。"
        case .ready:
            fullTitle = "\(appName ?? "当前应用") · 发送目标"
            help = "Buffer 可发送到 \(appName ?? "当前应用") 的当前输入框。"
        case .targetChanged:
            fullTitle = "焦点已变化"
            help = "原目标已失效；请点选输入框后重新关联。"
        case .unavailable:
            fullTitle = "等待输入框"
            help = "请先点选要接收内容的输入框。"
        case .detached:
            fullTitle = "剪贴板模式"
            help = "当前不是 RIMES 输入法；Buffer 只允许剪贴板导入与复制。"
        case .protected:
            fullTitle = "安全输入"
            help = "受保护状态下不显示或保留目标输入框信息。"
        }

        targetApplicationIndicator.update(
            state: state,
            appName: appName,
            appIcon: appIcon,
            title: fullTitle,
            help: help
        )

        if BufferTargetAssociationRules.shouldClearCue(
            state: state,
            hasPresentedCue: targetAssociationCueToken != nil,
            cueMatchesLiveTarget: targetAssociationCueToken == targetToken
        ) {
            clearTargetAssociationCue()
        }
    }

    private func targetApplicationIdentity(
        for target: FocusLease?
    ) -> TargetApplicationIdentity? {
        guard let target else { return nil }
        let application = NSRunningApplication(
            processIdentifier: target.processIdentifier
        )
        let name = application?.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            resolvedName = target.bundleID.split(separator: ".").last
                .map(String.init) ?? "当前应用"
        }
        let icon: NSImage?
        if let applicationIcon = application?.icon {
            icon = applicationIcon
        } else if let applicationURL = application?.bundleURL
                    ?? NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: target.bundleID
                    ) {
            let workspaceIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            icon = workspaceIcon
        } else {
            icon = nil
        }
        return TargetApplicationIdentity(name: resolvedName, icon: icon)
    }

    /// Replays the paired target cue only for a freshly revalidated live
    /// external lease. It never discovers a target through Accessibility or a
    /// remembered app identity, and it never changes focus or the input route.
    @discardableResult
    private func presentTargetAssociationCue(expected token: FocusToken,
                                              requiresCapture: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let model = BufferModel.shared
        let routeGeneration = model.inputRouteGeneration
        let sessionEpoch = workbenchSessionEpoch
        let lifecycleGeneration = targetAssociationCueGeneration
        guard isVisible,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              !hiddenForSession,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              !requiresCapture || model.capturesInput(for: token),
              let target = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              target.isExternalTarget,
              let controller = target.controller,
              let caretRect = controller.workbenchCaretRect(expected: target),
              !panel.frame.contains(
                NSPoint(x: caretRect.midX, y: caretRect.midY)
              ),
              lifecycleGeneration == targetAssociationCueGeneration,
              routeGeneration == model.inputRouteGeneration,
              sessionEpoch == workbenchSessionEpoch,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ) === target,
              !requiresCapture || model.capturesInput(for: token) else {
            clearTargetAssociationCue(expected: token)
            return false
        }

        let accentColor = RimeUI.isRasta ? RimeUI.brandGreen : RimeUI.accentBlue
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let cue = targetAssociationCueController ?? TargetAssociationCueController()
        targetAssociationCueController = cue
        targetAssociationCueGeneration &+= 1
        let cueGeneration = targetAssociationCueGeneration
        targetAssociationCueToken = token
        let shown = cue.show(
            caretScreenRect: caretRect,
            accentColor: accentColor,
            level: CandidatePanelLevelRules.level(
                bundleID: target.bundleID,
                hostKind: target.hostKind
            ),
            reduceMotion: reduceMotion
        )
        guard shown,
              targetAssociationCueGeneration == cueGeneration,
              routeGeneration == model.inputRouteGeneration,
              sessionEpoch == workbenchSessionEpoch,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              !hiddenForSession,
              !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ) === target,
              !requiresCapture || model.capturesInput(for: token) else {
            if targetAssociationCueGeneration == cueGeneration {
                clearTargetAssociationCue()
            }
            return false
        }

        if let marker = BufferTargetAssociationGeometry.marker(
            panelFrame: panel.frame,
            targetRect: caretRect
        ) {
            visual.flashAssociation(
                marker,
                accentColor: accentColor,
                reduceMotion: reduceMotion
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [weak self] in
            guard let self,
                  self.targetAssociationCueGeneration == cueGeneration,
                  self.targetAssociationCueToken == token else { return }
            self.targetAssociationCueToken = nil
        }
        return true
    }

    private func clearTargetAssociationCue(expected token: FocusToken? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let token,
           let activeToken = targetAssociationCueToken,
           activeToken != token { return }
        targetAssociationCueGeneration &+= 1
        targetAssociationCueToken = nil
        targetAssociationCueController?.hide()
        visual.clearAssociationMarker()
    }

    func focusInvalidated(_ token: FocusToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        clearTargetAssociationCue(expected: token)
        applyTargetAssociationPresentation(
            state: .unavailable,
            appName: nil,
            appIcon: nil
        )
    }

    private func refreshContextualStatusIndicators(
        _ workspace: (any DerivedBufferWorkspace)?
    ) {
        let indicators = (workspace as? any WorkbenchStatusIndicatorProviding)?
            .workbenchStatusIndicators ?? []
        reconcileContextualStatusIndicators(indicators)
    }

    private func setWorkbenchStatusText(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
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
    }

    private func refreshGeneratedResultCopy(contentProtected: Bool,
                                            detachedClipboardMode: Bool) {
        // Preserve the secure-refresh rule: never ask a workspace for a
        // plaintext snapshot merely to decide whether an action is visible.
        let hasGeneratedResult = !contentProtected
            && BufferGeneratedResultCopyRules.freeze(protected: false) != nil
        let available = !contentProtected && (hasGeneratedResult
            || (detachedClipboardMode && !BufferModel.shared.stagedText.isEmpty))
        copyResultButton.isHidden = !available
        copyResultButton.isEnabled = available
        copyResultButton.toolTip = available
            ? (detachedClipboardMode
                ? "复制 Buffer 内容并关闭"
                : "复制当前生成结果并关闭 Buffer（⌘C）")
            : nil
        copyResultButton.setAccessibilityLabel(
            detachedClipboardMode
                ? "复制 Buffer 内容并关闭"
                : "复制当前生成结果并关闭 Buffer"
        )
    }

    private func refreshInputOptionsControl(contentProtected: Bool) {
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        let activeKey = BufferPluginSelectionStore.shared.activeKey
        let entry = BufferPluginMenuCatalog.entries(from: plugins).first {
            $0.key == activeKey
        } ?? BufferPluginMenuEntry(
            key: nil,
            title: BufferPluginMenuCatalog.defaultTitle,
            symbolName: PluginVisualIdentity.defaultWorkbenchSymbolName
        )
        functionMenuButton.image = PluginVisualIdentity.image(
            symbolName: entry.symbolName,
            accessibilityDescription: entry.title,
            pointSize: 12,
            weight: .semibold
        )
        functionMenuButton.image?.isTemplate = true
        functionMenuButton.isEnabled = !contentProtected
        functionMenuButton.toolTip = contentProtected
            ? "受保护状态下不能切换 Buffer 功能"
            : "当前功能：\(entry.title)；点按选择 Buffer 功能"
        functionMenuButton.setAccessibilityLabel("Buffer 功能：\(entry.title)")
        functionMenuButton.refreshInteractionAppearance()
        contextualStatusControl.isHidden = contextualStatusControl.arrangedSubviews.isEmpty
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
        contextualStatusControl.isHidden = indicators.isEmpty
    }

    /// Every ETInput-owned text field is an internal UI surface, not a draft
    /// source or a remote-mirroring target.
    func isOwnClient(bundleID: String) -> Bool {
        let own = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
        return bundleID == own
    }

    func windowDidMove(_ notification: Notification) {
        guard !adjustingFrame else { return }
        clearTargetAssociationCue()
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
        candidateWindow.syncWorkbenchLayout()
    }
    func windowDidResize(_ notification: Notification) {
        guard !adjustingFrame else { return }
        clearTargetAssociationCue()
        clampFrameToScreens()
        candidateWindow.syncWorkbenchLayout()
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
        candidateWindow.syncWorkbenchLayout()
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.level = CandidatePanelLevelRules.workbenchStandard
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = BufferWorkbenchLayout.windowBackgroundDraggable
        panel.minSize = NSSize(width: BufferWindowGeometry.standardMinimumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: toolbarExpanded,
                                   mode: layoutMode
                               ))
        panel.maxSize = NSSize(width: BufferWindowGeometry.standardMaximumWidth,
                               height: BufferWindowGeometry.height(
                                   expanded: toolbarExpanded,
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
            visual.leadingAnchor.constraint(
                equalTo: outerContainer.leadingAnchor,
                constant: BufferWorkbenchMetrics.chromeInset
            ),
            visual.trailingAnchor.constraint(
                equalTo: outerContainer.trailingAnchor,
                constant: -BufferWorkbenchMetrics.chromeInset
            ),
            visual.topAnchor.constraint(
                equalTo: outerContainer.topAnchor,
                constant: BufferWorkbenchMetrics.chromeInset
            ),
            visual.bottomAnchor.constraint(
                equalTo: outerContainer.bottomAnchor,
                constant: -BufferWorkbenchMetrics.chromeInset
            ),
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
            copyResultButton,
            "rectangle.portrait.and.arrow.forward",
            "复制当前生成结果并关闭 Buffer（⌘C）",
            #selector(copyResultTapped)
        )
        copyResultButton.isHidden = true
        configurePrimaryButton(
            sendButton,
            "paperplane.fill",
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
        configureIconButton(
            clipboardImportButton,
            "arrow.down.doc",
            "从系统剪贴板导入文字",
            #selector(importClipboardTapped)
        )
        configureIconButton(
            functionMenuButton,
            PluginVisualIdentity.defaultWorkbenchSymbolName,
            "选择 Buffer 功能",
            #selector(functionMenuTapped)
        )
        configureIconButton(
            exchangeEditButton,
            "text.cursor",
            "返回编辑原文",
            #selector(returnToExchangeSourceTapped)
        )
        exchangeEditSlot.setControlVisible(false)
        configureIconButton(
            autoSendButton,
            "timer",
            "自动发送：块在 \(Int(Self.autoSendLifetime)) 秒后自行上屏",
            #selector(toggleAutoSend)
        )
        configureIconButton(
            closeButton,
            "xmark",
            "关闭并暂停缓冲（保留内容）",
            #selector(closeTapped)
        )
        [functionMenuButton, clipboardImportButton, copyResultButton,
         sendButton, exchangeEditButton, autoSendButton, closeButton].forEach {
            $0.showsPersistentInteractionSurface = true
        }

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.alignment = .left
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.userInterfaceLayoutDirection = .leftToRight
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true

        pluginSelector.controlSize = .mini
        pluginSelector.font = .systemFont(ofSize: 10, weight: .semibold)
        pluginSelector.imagePosition = .noImage
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
        pluginButtonRow.spacing = 6
        pluginButtonRow.detachesHiddenViews = false
        pluginButtonRow.userInterfaceLayoutDirection = .leftToRight
        pluginButtonRow.isHidden = true
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

        derivedOptionPickerPopup.controlSize = .mini
        derivedOptionPickerPopup.font = .systemFont(ofSize: 10)
        derivedOptionPickerPopup.target = self
        derivedOptionPickerPopup.action = #selector(derivedOptionPickerChanged)
        derivedOptionPickerPopup.translatesAutoresizingMaskIntoConstraints = false
        derivedOptionPickerPopup.widthAnchor.constraint(
            equalToConstant: 92
        ).isActive = true
        derivedOptionPickerPopup.setContentHuggingPriority(
            .required,
            for: .horizontal
        )
        derivedOptionPickerPopup.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )

        let aiPopupWidths: [(FirstMousePopUpButton, CGFloat)] = [
            (aiConnectorPopup, 98),
            (aiModelPopup, 88),
            (aiModePopup, 62),
            (aiOutputPopup, 82),
        ]
        for (popup, width) in aiPopupWidths {
            popup.controlSize = .mini
            popup.font = .systemFont(ofSize: 10)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: width).isActive = true
            popup.setContentHuggingPriority(.required, for: .horizontal)
            popup.setContentCompressionResistancePriority(.required,
                                                          for: .horizontal)
        }
        aiConnectorPopup.target = self
        aiConnectorPopup.action = #selector(aiConnectorChanged)
        aiConnectorPopup.toolTip = "选择实际处理请求的 AI 连接器"
        aiModelPopup.isEnabled = false
        aiModelPopup.toolTip = "CLI 使用已验证的默认模型；OpenAI 使用连接器设置中的模型"
        aiModePopup.target = self
        aiModePopup.action = #selector(aiModeChanged)
        aiModePopup.toolTip = "选择本次处理方式"
        aiOutputPopup.target = self
        aiOutputPopup.action = #selector(aiOutputChanged)
        aiOutputPopup.toolTip = "选择原地生成的内容格式"

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
        pluginActionsControl.spacing = 6
        pluginActionsControl.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 3)
        // Hidden loading state and an empty action row must leave the layout;
        // otherwise the shared surface draws a blank tail after every plugin
        // selector item.
        pluginActionsControl.detachesHiddenViews = true
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

        syncAutoSendTimer()
        BufferWorkbenchShelfLayout.configure(
            utilityShelf,
            status: statusLabel,
            functionMenu: functionMenuButton,
            pluginActions: pluginActionsControl,
            flexibleSpace: shelfFlexibleSpace,
            statusIndicators: contextualStatusControl,
            exchangeEdit: exchangeEditSlot,
            autoSend: autoSendButton,
            targetAssociation: targetApplicationIndicator,
            close: closeButton
        )
        utilityShelf.isHidden = !toolbarExpanded

        shelfDivider.wantsLayer = true
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong
            .withAlphaComponent(0.55).cgColor
        shelfDivider.isHidden = !toolbarExpanded

        BufferWorkbenchLayout.mainBar
            .map { view(for: $0) }
            .forEach { mainBar.addArrangedSubview($0) }
        mainBar.orientation = .horizontal
        mainBar.alignment = .centerY
        mainBar.distribution = .fill
        mainBar.spacing = BufferWorkbenchMetrics.mainSpacing
        mainBar.detachesHiddenViews = true
        mainBar.userInterfaceLayoutDirection = .leftToRight
        mainBar.edgeInsets = NSEdgeInsets(
            top: 3,
            left: BufferWorkbenchMetrics.mainHorizontalInset,
            bottom: 3,
            right: BufferWorkbenchMetrics.mainHorizontalInset
        )
        mainBar.addSubview(railActionCluster, positioned: .above, relativeTo: bufferRail)
        let actionCenterY = railActionCluster.centerYAnchor.constraint(
            equalTo: bufferRail.centerYAnchor,
            constant: BufferWorkbenchMetrics.mainControlYOffset(
                row: .target,
                mode: layoutMode
            )
        )
        railActionCenterYConstraint = actionCenterY
        NSLayoutConstraint.activate([
            railActionCluster.trailingAnchor.constraint(
                equalTo: bufferRail.trailingAnchor,
                constant: -BufferInlineMetrics.railHorizontalInset
            ),
            railActionCluster.leadingAnchor.constraint(
                greaterThanOrEqualTo: bufferRail.leadingAnchor,
                constant: BufferInlineMetrics.railHorizontalInset
            ),
            actionCenterY,
        ])

        mainBar.addSubview(sourceActionCluster, positioned: .above, relativeTo: bufferRail)
        let sourceActionCenterY = sourceActionCluster.centerYAnchor.constraint(
            equalTo: bufferRail.centerYAnchor,
            constant: BufferWorkbenchMetrics.mainControlYOffset(
                row: .source,
                mode: layoutMode
            )
        )
        sourceActionCenterYConstraint = sourceActionCenterY
        NSLayoutConstraint.activate([
            sourceActionCluster.trailingAnchor.constraint(
                equalTo: bufferRail.trailingAnchor,
                constant: -BufferInlineMetrics.railHorizontalInset
            ),
            sourceActionCluster.leadingAnchor.constraint(
                greaterThanOrEqualTo: bufferRail.leadingAnchor,
                constant: BufferInlineMetrics.railHorizontalInset
            ),
            sourceActionCenterY,
        ])

        let root = NSStackView(views: [utilityShelf, shelfDivider, mainBar])
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
            utilityShelf.heightAnchor.constraint(equalToConstant: 30),
            shelfDivider.heightAnchor.constraint(equalToConstant: 1),
            mainBarHeight,
            bufferRail.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            railHeight,
        ])
        updateMainControlAlignment(for: layoutMode)
        refreshRailActionOverlayGeometry()
        applyAppearance()
        rebuildPluginSelector()
        candidateWindow.syncWorkbenchLayout()
    }

    /// iShot's verified nonactivating annotation host sits above ordinary
    /// floating windows. Elevate the passive workbench only while
    /// that exact capture lease is still current; every other route resets to
    /// the ordinary floating level.
    private func syncPanelLevel(
        secureInputEnabled: Bool,
        rimeOwnsInput: Bool
    ) {
        let resolved: NSWindow.Level
        if rimeOwnsInput,
           !secureInputEnabled,
           !sessionProtectionActive,
           let token = BufferModel.shared.captureFocusToken,
           BufferModel.shared.capturesInput(for: token),
           let target = InputFocusCoordinator.shared.interactionTarget(
                expected: token
           ) {
            resolved = CandidatePanelLevelRules.workbenchLevel(
                bundleID: target.bundleID,
                hostKind: target.hostKind
            )
        } else {
            resolved = CandidatePanelLevelRules.workbenchStandard
        }
        if panel.level != resolved {
            panel.level = resolved
        }
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
        button.setAccessibilityLabel(toolTip)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: BufferWorkbenchMetrics.controlSize).isActive = true
    }

    private func configurePrimaryButton(_ button: FirstMouseButton,
                                        _ symbol: String,
                                        _ toolTip: String,
                                        _ action: Selector) {
        button.image = RimeUI.symbol(symbol, pointSize: 11, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.title = ""
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = toolTip
        button.setAccessibilityLabel(toolTip)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.primaryControlWidth
        ).isActive = true
        button.heightAnchor.constraint(
            equalToConstant: BufferWorkbenchMetrics.primaryControlHeight
        ).isActive = true
    }

    private func view(for control: BufferWorkbenchControl) -> NSView {
        switch control {
        case .bufferRail: return bufferRail
        case .copyResult: return copyResultButton
        case .targetAssociation: return targetApplicationIndicator
        case .send: return sendButton
        case .status: return statusLabel
        case .clipboardImport: return clipboardImportButton
        case .functionMenu: return functionMenuButton
        case .pluginActions: return pluginActionsControl
        case .exchangeEdit: return exchangeEditSlot
        case .autoSend: return autoSendButton
        case .close: return closeButton
        }
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        visual.material = RimeUI.isDark ? .hudWindow : .popover
        visual.fillColor = RimeUI.workbenchChrome
        visual.strokeColor = RimeUI.borderStrong
        visual.showsRastaAccent = RimeUI.isRasta
        shelfDivider.layer?.backgroundColor = RimeUI.borderStrong.withAlphaComponent(0.55).cgColor
        pluginActionsControl.layer?.backgroundColor = RimeUI.surface2.cgColor
        pluginActionsControl.layer?.borderColor = RimeUI.border.cgColor
        pluginActionsControl.layer?.borderWidth = 1 / max(panel.backingScaleFactor, 1)
        [functionMenuButton, clipboardImportButton, exchangeEditButton,
         autoSendButton, closeButton, copyResultButton, sendButton].forEach {
            $0.contentTintColor = $0.isEnabled
                ? RimeUI.textSecondary
                : RimeUI.textMuted
            $0.refreshInteractionAppearance()
        }
        copyResultButton.contentTintColor = RimeUI.isRasta
            ? RimeUI.brandYellow
            : RimeUI.textSecondary
        sendButton.contentTintColor = sendButtonUsesAccent && sendButton.isEnabled
            ? (RimeUI.isRasta ? RimeUI.brandGreen : RimeUI.accentBlue)
            : RimeUI.textSecondary
        targetApplicationIndicator.applyAppearance()
        refreshAutoSendButton()
        railActionCluster.applyAppearance()
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
        derivedOptionPickerPopup.refreshInteractionAppearance()
        translationSourcePopup.refreshInteractionAppearance()
        translationTargetPopup.refreshInteractionAppearance()
        aiConnectorPopup.refreshInteractionAppearance()
        aiModelPopup.refreshInteractionAppearance()
        aiModePopup.refreshInteractionAppearance()
        aiOutputPopup.refreshInteractionAppearance()
        contextualStatusViews.values.forEach { $0.applyAppearance() }
    }

    private func applyPreviewPointerState(_ hoveredControl: BufferWorkbenchControl?) {
        [functionMenuButton, copyResultButton, sendButton, clipboardImportButton,
         exchangeEditButton, autoSendButton, closeButton].forEach {
            $0.setPreviewPointerState(nil)
        }
        pluginSelector.setPreviewPointerState(nil)
        builtInActionOptionPopup.setPreviewPointerState(nil)
        translationSourcePopup.setPreviewPointerState(nil)
        translationTargetPopup.setPreviewPointerState(nil)
        aiConnectorPopup.setPreviewPointerState(nil)
        aiModelPopup.setPreviewPointerState(nil)
        aiModePopup.setPreviewPointerState(nil)
        aiOutputPopup.setPreviewPointerState(nil)
        translationSwapButton.setPreviewPointerState(nil)
        builtInActionButton.setPreviewPointerState(nil)
        pluginActionButtons.values.forEach { $0.setPreviewPointerState(nil) }

        switch hoveredControl {
        case .copyResult:
            copyResultButton.setPreviewPointerState(.hovered)
        case .send:
            sendButton.setPreviewPointerState(.hovered)
        case .clipboardImport:
            clipboardImportButton.setPreviewPointerState(.hovered)
        case .functionMenu:
            functionMenuButton.setPreviewPointerState(.hovered)
        case .pluginActions:
            pluginSelector.setPreviewPointerState(.hovered)
        case .exchangeEdit:
            exchangeEditButton.setPreviewPointerState(.hovered)
        case .autoSend:
            autoSendButton.setPreviewPointerState(.hovered)
        case .close:
            closeButton.setPreviewPointerState(.hovered)
        case .bufferRail, .status, .targetAssociation, .none:
            break
        }
    }

    private func refreshPrimaryAction(
        controls: (any WorkbenchManualGenerationControls)?,
        availability: BufferDeliveryCoordinator.Availability,
        contentProtected: Bool,
        detachedClipboardMode: Bool
    ) {
        sendButton.imagePosition = .imageOnly
        sendButton.title = ""
        sendButtonUsesAccent = false
        guard let controls else {
            setSendButtonGenerating(false)
            if detachedClipboardMode {
                setSendButtonSymbol("paperplane.fill")
                sendButton.isEnabled = false
                sendButton.toolTip = "当前输入法下请使用旁边的“复制并退出”"
                sendButton.setAccessibilityLabel("发送不可用")
            } else {
                setSendButtonSymbol("paperplane.fill")
                sendButton.isEnabled = availability.canSend && !contentProtected
                sendButton.toolTip = availability.canSend
                    ? "发送下一块（\(deliveryShortcutTitle)）"
                    : availability.label
                sendButton.setAccessibilityLabel("发送下一块")
            }
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
            sendButton.isEnabled = !detachedClipboardMode
                && !contentProtected
                && availability.canSend
            sendButton.toolTip = detachedClipboardMode
                ? "当前输入法下请使用旁边的“复制并退出”"
                : (availability.canSend
                    ? "发送下一块（\(deliveryShortcutTitle)）"
                    : availability.label)
            sendButton.setAccessibilityLabel(
                detachedClipboardMode ? "发送不可用" : "发送下一块 AI 内容"
            )
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
        defer { syncPluginActionRowVisibility() }
        guard !lastSecureInputState, !sessionProtectionActive else {
            resetDerivedControlRendering()
            pluginLoadingIndicator.isHidden = true
            pluginLoadingIndicator.stopAnimation(nil)
            pluginSelector.toolTip = "安全输入已开启，插件控制已隐藏"
            return
        }
        if let workspace = DerivedBufferWorkspaceRouter.selectedWorkspace {
            if let controls = workspace as? any DerivedOptionPickerControls {
                refreshDerivedOptionPickerControls(
                    workspace: workspace,
                    controls: controls
                )
            } else if let controls = workspace as? any DerivedLanguagePairControls {
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
            || renderingBuiltInActionControls
            || renderingOptionPickerControls {
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
            renderingOptionPickerControls = false
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

    private func refreshDerivedOptionPickerControls(
        workspace: any DerivedBufferWorkspace,
        controls: any DerivedOptionPickerControls
    ) {
        pluginSelector.toolTip = "当前插件：\(workspace.workbenchDisplayName)（\(pluginSwitchShortcutTitle) 切换）"
        pluginLoadingIndicator.isHidden = true
        pluginLoadingIndicator.stopAnimation(nil)

        if !renderingOptionPickerControls {
            resetDerivedControlRendering()
            renderingOptionPickerControls = true
            pluginButtonRow.addArrangedSubview(derivedOptionPickerPopup)
        }

        if renderedDerivedOptionPickerOptions != controls.optionPickerOptions {
            renderedDerivedOptionPickerOptions = controls.optionPickerOptions
            derivedOptionPickerPopup.removeAllItems()
            for option in controls.optionPickerOptions {
                derivedOptionPickerPopup.addItem(withTitle: option.title)
                derivedOptionPickerPopup.lastItem?.representedObject =
                    option.identifier
            }
        }
        selectPopupExactly(
            derivedOptionPickerPopup,
            representedValue: controls.selectedOptionPickerID
        )
        derivedOptionPickerPopup.isEnabled = !lastSecureInputState
            && !sessionProtectionActive
        derivedOptionPickerPopup.toolTip = controls.optionPickerToolTip
        derivedOptionPickerPopup.setAccessibilityLabel(
            "\(workspace.workbenchDisplayName) 类型"
        )
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
            renderingOptionPickerControls = false
            renderedTranslationLanguages.removeAll()
            renderedPluginKeys.removeAll()
            pluginActionButtons.removeAll()
            pluginButtonRow.arrangedSubviews.forEach {
                pluginButtonRow.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            pluginButtonRow.addArrangedSubview(aiConnectorPopup)
            pluginButtonRow.addArrangedSubview(aiModelPopup)
            pluginButtonRow.addArrangedSubview(aiModePopup)
            pluginButtonRow.addArrangedSubview(aiOutputPopup)
        }
        refreshAIControlSelections()
    }

    private func refreshAIControlSelections() {
        if aiConnectorPopup.numberOfItems != AITextProviderKind.allCases.count {
            aiConnectorPopup.removeAllItems()
            for kind in AITextProviderKind.allCases {
                aiConnectorPopup.addItem(withTitle: compactAIConnectorTitle(kind))
                aiConnectorPopup.lastItem?.representedObject = kind.rawValue
            }
        }
        let connectorKind = AITextConnectorSelectionStore.shared.selectedKind
        selectPopupExactly(aiConnectorPopup,
                           representedValue: connectorKind.rawValue)

        let modelID = try? AITextGenerationPreferenceStore.shared
            .requestSelection(connectorKind: connectorKind)
            .modelID
        aiModelPopup.removeAllItems()
        aiModelPopup.addItem(withTitle: modelID ?? "默认模型")
        aiModelPopup.lastItem?.representedObject = modelID
        aiModelPopup.isEnabled = false

        if aiModePopup.numberOfItems != AITextGenerationMode.allCases.count {
            aiModePopup.removeAllItems()
            for mode in AITextGenerationMode.allCases {
                aiModePopup.addItem(withTitle: mode.displayName)
                aiModePopup.lastItem?.representedObject = mode.rawValue
            }
        }
        selectPopupExactly(
            aiModePopup,
            representedValue: AITextGenerationPreferenceStore.shared.mode.rawValue
        )

        if !AITextOutputPopupConfiguration.matchesCanonicalItems(aiOutputPopup) {
            AITextOutputPopupConfiguration.populate(aiOutputPopup)
        }
        selectPopupExactly(
            aiOutputPopup,
            representedValue: AITextGenerationPreferenceStore.shared.format.rawValue
        )
    }

    private func compactAIConnectorTitle(_ kind: AITextProviderKind) -> String {
        switch kind {
        case .codexCLI: return "Codex CLI"
        case .claudeCodeCLI: return "Claude Code"
        case .openAICompatible: return "OpenAI API"
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
        renderingOptionPickerControls = false
        renderedBuiltInActionHasOptions = nil
        renderedTranslationLanguages.removeAll()
        renderedBuiltInActionOptions.removeAll()
        renderedDerivedOptionPickerOptions.removeAll()
        renderedPluginKeys.removeAll()
        pluginActionButtons.removeAll()
        pluginButtonRow.arrangedSubviews.forEach {
            pluginButtonRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func syncPluginActionRowVisibility() {
        pluginButtonRow.isHidden = pluginButtonRow.arrangedSubviews.isEmpty
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

    private func setToolbarExpanded(_ expanded: Bool, resize: Bool) {
        _ = expanded
        let presentationChanged = !toolbarExpanded
            || utilityShelf.isHidden
            || shelfDivider.isHidden
        guard presentationChanged else { return }

        toolbarExpanded = true
        utilityShelf.isHidden = false
        shelfDivider.isHidden = false
        panel.contentView?.layoutSubtreeIfNeeded()

        if resize {
            resizeForCurrentPresentation()
            candidateWindow.syncWorkbenchLayout()
        }
    }

    private func resizeForCurrentPresentation() {
        let desiredHeight = BufferWindowGeometry.height(
            expanded: toolbarExpanded,
            mode: layoutMode
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
        saveFrame()
    }

    private func syncLayoutMode(_ nextMode: BufferWorkbenchLayoutMode) {
        updateMainControlAlignment(for: nextMode)
        let modeChanged = layoutMode != nextMode
        if modeChanged {
            layoutMode = nextMode
            mainBarHeightConstraint?.constant = BufferWorkbenchMetrics.mainBarHeight(
                for: nextMode
            )
            bufferRailHeightConstraint?.constant = BufferWorkbenchMetrics.railHeight(
                for: nextMode
            )
        }
        let desiredHeight = BufferWindowGeometry.height(
            expanded: toolbarExpanded,
            mode: nextMode
        )
        let fallback = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let verticalMargin = min(
            BufferWindowGeometry.screenSafetyMargin,
            max(0, (fallback.height - 1) / 2)
        )
        let expectedHeight = min(
            desiredHeight,
            max(1, fallback.height - verticalMargin * 2)
        )
        let needsHeightRepair = abs(panel.frame.height - expectedHeight) >= 0.5
        guard modeChanged || needsHeightRepair else { return }

        // `layoutMode` can already be correct while AppKit still holds the
        // previous derived frame (for example after constraints settle on the
        // next run-loop turn). Reassert the canonical height in that case;
        // returning solely on enum equality leaves a permanently tall empty
        // workbench after switching back to Default.
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
        applyClampedFrame(proposed,
                          visibleFrames: NSScreen.screens.map(\.visibleFrame),
                          fallback: fallback,
                          display: panel.isVisible)
        visual.needsLayout = true
        bufferRail.needsLayout = true
        saveFrame()
    }

    private func updateMainControlAlignment(for mode: BufferWorkbenchLayoutMode) {
        railActionCenterYConstraint?.constant = BufferWorkbenchMetrics
            .mainControlYOffset(row: .target, mode: mode)
        sourceActionCenterYConstraint?.constant = BufferWorkbenchMetrics
            .mainControlYOffset(row: .source, mode: mode)
    }

    /// Clipboard import edits the source text, so a split layout keeps it on
    /// the source row while delivery and copy stay with the result. A single
    /// rail has no second row to move to, so it keeps one combined cluster.
    private func reconcileRailActionMembership(for mode: BufferWorkbenchLayoutMode) {
        if mode.targetRows == nil {
            sourceActionCluster.setControls([])
            railActionCluster.setControls(
                [clipboardImportButton, copyResultButton, sendButton]
            )
        } else {
            railActionCluster.setControls([copyResultButton, sendButton])
            sourceActionCluster.setControls([clipboardImportButton])
        }
    }

    private func refreshRailActionOverlayGeometry() {
        reconcileRailActionMembership(for: layoutMode)
        railActionCluster.refreshGeometry()
        sourceActionCluster.refreshGeometry()
        updateMainControlAlignment(for: layoutMode)
        panel.contentView?.layoutSubtreeIfNeeded()
        bufferRail.setTrailingActionExclusion(width: railActionCluster.reservedWidth)
        bufferRail.setSourceTrailingActionExclusion(
            width: sourceActionCluster.reservedWidth
        )
    }

    /// Shared by all three plugin modes: turning it on in one turns it on
    /// everywhere, because it describes how the user wants delivery to work
    /// rather than anything about a particular plugin.
    var autoSendEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.autoSend) }
        set {
            guard newValue != autoSendEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Key.autoSend)
            autoSendAges.removeAll()
            autoSendLastTick = nil
            bufferRail.setAutoSendFade([:])
            syncAutoSendTimer()
            refresh()
            IMELog.write("buffer auto-send enabled=\(newValue)")
        }
    }

    @objc private func toggleAutoSend() {
        autoSendEnabled.toggle()
        refreshAutoSendButton()
    }

    /// Off and on have to be legible at a glance, so they differ in glyph,
    /// tint, and a filled pill — a tint change alone reads as noise next to
    /// the app icon.
    private func refreshAutoSendButton() {
        let on = autoSendEnabled
        let accent = RimeUI.isRasta ? RimeUI.brandGreen : RimeUI.accentBlue
        autoSendButton.image = RimeUI.symbol(
            on ? "timer.circle.fill" : "timer",
            pointSize: on ? 13 : 11,
            weight: .semibold
        )
        autoSendButton.image?.isTemplate = true
        autoSendButton.wantsLayer = true
        autoSendButton.layer?.cornerRadius = 5
        autoSendButton.layer?.backgroundColor = on
            ? accent.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        autoSendButton.layer?.borderWidth = on
            ? 1 / max(panel.backingScaleFactor, 1)
            : 0
        autoSendButton.layer?.borderColor = on
            ? accent.withAlphaComponent(0.6).cgColor
            : NSColor.clear.cgColor
        autoSendButton.contentTintColor = on ? accent : RimeUI.textMuted
        autoSendButton.toolTip = on
            ? "自动发送已开启：块会在 \(Int(Self.autoSendLifetime)) 秒后自行上屏，点击可关闭"
            : "自动发送已关闭：点击后块会在 \(Int(Self.autoSendLifetime)) 秒后自行上屏"
        autoSendButton.setAccessibilityLabel(
            on ? "关闭自动发送" : "开启自动发送"
        )
        autoSendButton.refreshInteractionAppearance()
    }

    private func syncAutoSendTimer() {
        autoSendTimer?.invalidate()
        autoSendTimer = nil
        guard autoSendEnabled else {
            autoSendAges.removeAll()
            autoSendLastTick = nil
            bufferRail.setAutoSendFade([:])
            return
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickAutoSend()
        }
        autoSendTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One tick: age the visible blocks, dim them, and hand the oldest to the
    /// ordinary delivery path once its lifetime is up. Everything the manual
    /// gesture checks — exact focus, secure input, composition — is checked
    /// there too, so this cannot deliver anywhere a Return could not.
    private func tickAutoSend() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard autoSendEnabled, panel.isVisible else { return }
        let blocks = BufferModel.shared.blocks
        guard !blocks.isEmpty else {
            if !autoSendAges.isEmpty {
                autoSendAges.removeAll()
                autoSendLastTick = nil
                bufferRail.setAutoSendFade([:])
            }
            return
        }
        let deliverable: Bool
        if case .ready = BufferDeliveryCoordinator.shared.availability() {
            deliverable = true
        } else {
            deliverable = false
        }
        // Losing the target or hitting a password field pauses every countdown
        // where it stands. Ages survive, so a block that had one second left
        // still has one second left when the target comes back.
        guard Self.autoSendDecisionForSmoke(
            enabled: true,
            deliverable: deliverable,
            secureInput: IsSecureEventInputEnabled(),
            age: 0
        ).fades else {
            autoSendLastTick = nil
            return
        }

        let now = Date()
        let elapsed = autoSendLastTick.map { now.timeIntervalSince($0) } ?? 0
        autoSendLastTick = now
        // A tick can be late — a busy main thread, a wake from sleep — but a
        // block must never jump the queue because of it.
        let advance = min(max(elapsed, 0), Self.autoSendLifetime)

        let liveIDs = Set(blocks.map(\.id))
        autoSendAges = autoSendAges.filter { liveIDs.contains($0.key) }
        var fade: [UUID: Double] = [:]
        for block in blocks {
            let age = (autoSendAges[block.id] ?? 0) + advance
            autoSendAges[block.id] = age
            fade[block.id] = min(max(age / Self.autoSendLifetime, 0), 1)
        }
        bufferRail.setAutoSendFade(fade)

        // Delivery is ordered, so the head block is the only one that can
        // leave; it is also the oldest, so its own age is what decides.
        guard let head = blocks.first,
              Self.autoSendDecisionForSmoke(
                enabled: true,
                deliverable: true,
                secureInput: false,
                age: autoSendAges[head.id] ?? 0
              ).sends else {
            return
        }
        autoSendAges.removeValue(forKey: head.id)
        BufferDeliveryCoordinator.shared.sendNext()
    }

    private func applyCollectionBehavior() {
        panel.collectionBehavior = BufferWindowCollectionBehaviorRules.behavior(
            pinned: pinned
        )
    }

    private func installObservers() {
        // The panel deliberately never becomes key, so clicking the same host
        // field again does not create a new IMK focus token. Observe external
        // pointer intent separately: any click delivered to another process
        // returns physical keys to that host, while a click on our logical
        // Buffer rail is handled locally and explicitly grants capture.
        externalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.externalPointerDidRequestHostInput()
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil,
                                            queue: .main) { [weak self] _ in
            self?.clearTargetAssociationCue()
            self?.clampFrameToScreens()
            candidateWindow.syncWorkbenchLayout()
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
            forName: .aiTextGenerationPreferencesDidChange,
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
            self?.clearTargetAssociationCue()
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
                self.applyTargetAssociationPresentation(
                    state: .protected,
                    appName: nil
                )
                ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
                BufferModel.shared.routeDirectPreservingContent(
                    reason: "secure input enabled"
                )
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
        applyTargetAssociationPresentation(state: .protected, appName: nil)
        setToolbarExpanded(false, resize: true)
        inlineCompositionProjection = nil
        _ = bufferRail.refresh(shielded: true, translationSnapshot: nil)
        ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
        DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
        BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
        if let lease = InputFocusCoordinator.shared.invalidateAll(reason: reason) {
            // This abandons only process-local Rime composition and never calls
            // the retired IMK client, so it remains safe under another IME.
            lease.controller?.finalizeProtectedSession(lease, reason: reason)
            candidateWindow.hide(owner: lease.token)
        } else {
            candidateWindow.hideAll()
        }
        BufferModel.shared.routeDirectPreservingContent(reason: reason)
        if panel.isVisible || UserDefaults.standard.bool(forKey: Key.visible) {
            hiddenForSession = true
            BufferPopUpMenuController.shared.dismiss()
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
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            return .deferred
        }
        let protected = sessionProtectionActive || hiddenForSession
        let secureInput = IsSecureEventInputEnabled()
        let visibilityIntent = UserDefaults.standard.bool(forKey: Key.visible)
        guard visibilityIntent else {
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
            workbenchVisible: visibilityIntent,
            presentationProtected: protected,
            secureInput: secureInput,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: wasVisibleOnActiveSpace,
            targetScreenMatchesPanel: targetScreenMatchesPanel
        ) else {
            return .unchanged
        }

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
        candidateWindow.syncWorkbenchLayout()
        let reason = wasVisibleOnActiveSpace ? "display" : "space"
        IMELog.write("workbench followed focused input token=\(token) reason=\(reason)")
        return .relocated
    }

    private func positionForExplicitOpening() {
        positionForOpening(focusedAnchor: freshFocusedInputAnchor())
    }

    private func positionForOpening(
        focusedAnchor: (rect: NSRect, box: NSRect?, token: FocusToken)?
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
            boxRect: focusedAnchor?.box,
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
        // Alignment depends on a grant the user can revoke at any time, so say
        // which inputs produced this placement rather than leaving a silent
        // fallback looking like a broken feature.
        IMELog.write(
            "workbench opening side=\(placement.side) "
            + "caret=\(focusedAnchor != nil) "
            + "box=\(focusedAnchor?.box != nil) "
            + "alignPref=\(FocusedInputBoxProbe.alignmentEnabled) "
            + "axGranted=\(FocusedInputBoxProbe.isPermitted)"
        )
    }

    private func freshFocusedInputAnchor(
        expected token: FocusToken? = nil
    ) -> (rect: NSRect, box: NSRect?, token: FocusToken)? {
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              let lease = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              let controller = lease.controller else { return nil }
        guard let rect = controller.workbenchCaretRect(expected: lease) else {
            return nil
        }
        // Optional by design: the caret alone already places the workbench, so
        // a host with no usable Accessibility geometry simply keeps the
        // caret-centred opening instead of losing its anchor.
        let box = controller.workbenchInputBoxRect(expected: lease)
        return (rect, box, lease.token)
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
            expanded: toolbarExpanded,
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
            expanded: toolbarExpanded,
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
              let controls = DerivedBufferWorkspaceRouter
                .selectedWorkspace as? any DerivedResultSelectionControls,
              controls.ownsResultNavigation else {
            return
        }
        if RimeInputSourceAuthority.currentSourceIsOwn() {
            guard let lease = InputFocusCoordinator.shared.interactionTarget(),
                  lease.isExternalTarget,
                  controls.selectResult(blockID: blockID),
                  RimeInputSourceAuthority.currentSourceIsOwn(),
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: lease.token
                  ) === lease else { return }
        } else {
            // Result paging is local presentation state. Detached Buffer can
            // choose which completed alternative will be copied without an
            // IMK destination lease.
            guard controls.selectResult(blockID: blockID) else { return }
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
              !sessionProtectionActive else {
            return
        }

        if let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
            as? any DerivedResultSelectionControls,
           controls.ownsResultNavigation {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                guard let lease = InputFocusCoordinator.shared.interactionTarget(),
                      lease.isExternalTarget,
                      controls.moveResultSelection(delta: delta),
                      RimeInputSourceAuthority.currentSourceIsOwn(),
                      InputFocusCoordinator.shared.interactionTarget(
                        expected: lease.token
                      ) === lease else { return }
            } else {
                guard controls.moveResultSelection(delta: delta) else { return }
            }
        } else if DerivedBufferWorkspaceRouter.selectedWorkspace
                    === StreamInputWorkspace.shared,
                  StreamInputWorkspace.shared.ownsAlternativeNavigation {
            // Stream alternatives remain bound to their RIMES focus token.
            guard RimeInputSourceAuthority.currentSourceIsOwn(),
                  let lease = InputFocusCoordinator.shared.interactionTarget(),
                  lease.isExternalTarget,
                  StreamInputWorkspace.shared.moveAlternativeSelection(
                delta: delta,
                focusToken: lease.token
                  ),
                  RimeInputSourceAuthority.currentSourceIsOwn(),
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: lease.token
                  ) === lease else { return }
        } else {
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

    /// Switch the logical input surface without making this nonactivating
    /// panel key. The exact host lease remains the sole later delivery target.
    @discardableResult
    func activateCaptureForCurrentFocus(showWorkbench: Bool = true) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !sessionProtectionActive,
              !hiddenForSession,
              !IsSecureEventInputEnabled(),
              let lease = InputFocusCoordinator.shared.liveTarget(
                forceOverlayVisibilityRefresh: true
              ) else {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "capture requested without a trusted input target"
            )
            refresh()
            return false
        }

        // A composition started in direct mode belongs to the host. Settle it
        // before granting the same physical field's subsequent keys to Buffer.
        lease.controller?.forceCommit()
        guard InputFocusCoordinator.shared.liveTarget(
            expected: lease.token,
            forceOverlayVisibilityRefresh: true
        ) === lease else {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "capture target changed while switching route"
            )
            refresh()
            return false
        }
        BufferModel.shared.activateCapture(for: lease.token)
        if showWorkbench { show() }
        refresh()
        _ = presentTargetAssociationCue(
            expected: lease.token,
            requiresCapture: true
        )
        RimeBufferController.refreshActiveUI()
        return true
    }

    private func activateLogicalInput(at insertionIndex: Int) {
        guard activateCaptureForCurrentFocus(showWorkbench: false) else {
            NSSound.beep()
            return
        }
        _ = BufferModel.shared.setInsertionPoint(insertionIndex)
        refresh()
    }

    private func externalPointerDidRequestHostInput() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard BufferModel.shared.active else { return }
        clearTargetAssociationCue()
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            clearInlineComposition()
            BufferModel.shared.routeDirectPreservingContent(
                reason: "external input source pointer event"
            )
            return
        }
        if let captureToken = BufferModel.shared.captureFocusToken,
           let target = InputFocusCoordinator.shared.owner,
           target.token == captureToken {
            // The global pointer event can arrive while the same host field is
            // still the active IMK lease. Resolve under the old capture grant
            // first so a live preedit becomes a Buffer block; clearing the
            // route first would let a later commit leak into the host or be
            // discarded by the untrusted-focus recovery path.
            target.controller?.resolveCompositionForWorkbenchTransition(
                target: target
            )
        }
        BufferModel.shared.routeDirectPreservingContent(
            reason: "pointer activated external host"
        )
        refresh()
        RimeBufferController.refreshActiveUI()
    }

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

    @objc private func functionMenuTapped() {
        guard functionMenuButton.isEnabled, pluginSelector.isEnabled else { return }
        pluginSelector.performClick(nil)
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

    @objc private func aiConnectorChanged() {
        guard let raw = aiConnectorPopup.selectedItem?.representedObject as? String,
              let kind = AITextProviderKind(rawValue: raw) else {
            refresh()
            return
        }
        _ = AITextConnectorRegistry.shared.select(kind)
        refresh()
        RimeBufferController.refreshActiveUI()
    }

    @objc private func aiModeChanged() {
        guard let raw = aiModePopup.selectedItem?.representedObject as? String,
              let mode = AITextGenerationMode(rawValue: raw) else {
            refresh()
            return
        }
        AITextGenerationPreferenceStore.shared.mode = mode
    }

    @objc private func aiOutputChanged() {
        guard let raw = aiOutputPopup.selectedItem?.representedObject as? String,
              let format = AITextContentFormat(rawValue: raw) else {
            refresh()
            return
        }
        AITextGenerationPreferenceStore.shared.set(
            destination: .inline,
            format: format
        )
    }

    @objc private func sendTapped() {
        guard !sessionProtectionActive else { return }
        if IsSecureEventInputEnabled() {
            // Synchronize privacy immediately instead of waiting for the next
            // periodic secure-input refresh.
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
            BufferModel.shared.routeDirectPreservingContent(
                reason: "secure input while sending"
            )
            refresh()
            return
        }
        let rimeOwnsInput = RimeInputSourceAuthority.currentSourceIsOwn()
        if let controls = WorkbenchManualGenerationRouter.selectedControls {
            switch controls.primaryAction {
            case .requestGeneration:
                let availability: BufferDeliveryCoordinator.Availability =
                    rimeOwnsInput
                    ? BufferDeliveryCoordinator.shared.availability()
                    : .blocked(.noFocusedField)
                guard !availability.blocksManualGenerationRequest else {
                    NSSound.beep()
                    refresh()
                    return
                }
                let result = AITextGenerationCommandRouter.request(
                    controls: controls
                )
                switch result {
                case .inlineStarted:
                    refresh()
                    RimeBufferController.refreshActiveUI()
                case .rejected:
                    NSSound.beep()
                    IMELog.write("AI generation request rejected")
                    refresh()
                    RimeBufferController.refreshActiveUI()
                }
                return
            case .generating, .disabled:
                return
            case .deliver:
                break
            }
        }
        if !rimeOwnsInput || !RimeInputSourceAuthority.currentSourceIsOwn() {
            // A paper-plane click always means delivery. If the target/source
            // lease changed after mouse-down, fail closed and let refresh show
            // the detached copy action instead of changing clipboard contents.
            NSSound.beep()
            IMELog.write("buffer send rejected after input source changed")
            refresh()
            RimeBufferController.refreshActiveUI()
            return
        }
        _ = BufferDeliveryCoordinator.shared.sendNext(resolveCompositionIfNeeded: true)
        // Delivery.insert atomically replaces the idle marked guard. Restore it
        // for the still-current external lease before the next Return.
        RimeBufferController.refreshActiveUI()
    }

    @objc private func copyResultTapped() {
        if RimeInputSourceAuthority.currentSourceIsOwn() {
            _ = copyGeneratedResultAndClose()
        } else {
            _ = copyDetachedBufferAndClose()
        }
    }

    @objc private func importClipboardTapped() {
        _ = importClipboardText()
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

    @objc private func derivedOptionPickerChanged() {
        guard !sessionProtectionActive,
              !IsSecureEventInputEnabled(),
              let controls = DerivedBufferWorkspaceRouter.selectedWorkspace
                as? any DerivedOptionPickerControls,
              let identifier = derivedOptionPickerPopup.selectedItem?
                .representedObject as? String else {
            return
        }
        if !controls.setOptionPickerSelection(identifier) {
            NSSound.beep()
        }
        refresh()
        RimeBufferController.refreshActiveUI()
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
