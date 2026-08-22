import Cocoa
import Carbon.HIToolbox
import CoreText

extension Notification.Name {
    static let candidateWindowMetricsDidChange = Notification.Name("CandidateWindowMetricsDidChange")
}

enum CandidatePanelInteractionRules {
    static func mayInteract(hasLogicalCandidates: Bool,
                            hasInteractionTarget: Bool,
                            panelIsVisible: Bool,
                            panelIsOnActiveSpace: Bool) -> Bool {
        hasLogicalCandidates
            && hasInteractionTarget
            && panelIsVisible
            && panelIsOnActiveSpace
    }
}

enum CandidatePanelSpaceRules {
    /// A direct-host candidate panel belongs to the Space containing the
    /// current input target. It must not remain resident on every Space,
    /// because there is only one live FocusToken and one interaction owner.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .fullScreenAuxiliary,
    ]

    /// AppKit can keep an already ordered nonactivating panel attached to its
    /// previous Space. Retire that stale ordering before bringing it forward.
    static func shouldOrderOutBeforeShow(isVisible: Bool,
                                         isOnActiveSpace: Bool) -> Bool {
        isVisible && !isOnActiveSpace
    }
}

enum CandidatePanelLevelRules {
    static let standard = NSWindow.Level.popUpMenu
    static let workbenchStandard = NSWindow.Level.floating
    private static let displayShielding = NSWindow.Level(
        rawValue: Int(CGShieldingWindowLevel())
    )

    /// iShot's verified nonactivating annotation surface sits above ordinary
    /// menu windows. Elevate only that exact focus host while it owns the lease;
    /// every other client stays at the normal candidate level.
    static func level(bundleID: String, hostKind: FocusHostKind) -> NSWindow.Level {
        guard bundleID == FocusHostRules.iShotBundleID,
              hostKind == .nonactivatingSystemOverlay else {
            return standard
        }
        return displayShielding
    }

    /// The workbench stays at its ordinary floating level except for the same
    /// exact iShot overlay lease that requires display shielding candidates.
    static func workbenchLevel(bundleID: String,
                               hostKind: FocusHostKind) -> NSWindow.Level {
        let candidateLevel = level(bundleID: bundleID, hostKind: hostKind)
        return candidateLevel == displayShielding
            ? displayShielding
            : workbenchStandard
    }
}

enum CandidatePanelSecurityRules {
    static func mayOrderFront(secureInputEnabled: Bool) -> Bool {
        !secureInputEnabled
    }
}

enum CandidateWindowMetric: String, CaseIterable {
    case baseWidth
    case compactStripHeight
    case compactCandidateHeight
    case preeditHeight
    case candidateFontSize
    case labelFontSize

    var title: String {
        switch self {
        case .baseWidth: return "基础宽度"
        case .compactStripHeight: return "候选条高度"
        case .compactCandidateHeight: return "候选按钮高度"
        case .preeditHeight: return "预编辑高度"
        case .candidateFontSize: return "候选字大小"
        case .labelFontSize: return "序号大小"
        }
    }

    var unit: String {
        switch self {
        case .candidateFontSize, .labelFontSize: return "pt"
        default: return "px"
        }
    }

    var defaultValue: Double {
        switch self {
        case .baseWidth: return 460
        case .compactStripHeight: return 34
        case .compactCandidateHeight: return 24
        case .preeditHeight: return 20
        case .candidateFontSize: return 16
        case .labelFontSize: return 10
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .baseWidth: return 360...900
        case .compactStripHeight: return 32...64
        case .compactCandidateHeight: return 22...44
        case .preeditHeight: return 18...36
        case .candidateFontSize: return 12...24
        case .labelFontSize: return 9...18
        }
    }

    var userDefaultsKey: String { "candidateWindow.\(rawValue)" }

    var tag: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static func fromTag(_ tag: Int) -> CandidateWindowMetric? {
        guard allCases.indices.contains(tag) else { return nil }
        return allCases[tag]
    }
}

struct CandidateWindowMetrics {
    private static let compactDefaultsMigrationKey = "candidateWindow.compactDefaultsMigrated.v1"

    let baseWidth: CGFloat
    let compactStripHeight: CGFloat
    let compactCandidateHeight: CGFloat
    let preeditHeight: CGFloat
    let candidateFontSize: CGFloat
    let labelFontSize: CGFloat

    static var current: CandidateWindowMetrics {
        let values = resolvedValues(Dictionary(uniqueKeysWithValues:
            CandidateWindowMetric.allCases.map { ($0, Double(value(for: $0))) }
        ))
        func get(_ metric: CandidateWindowMetric) -> CGFloat {
            CGFloat(values[metric] ?? metric.defaultValue)
        }
        return CandidateWindowMetrics(
            baseWidth: get(.baseWidth),
            compactStripHeight: get(.compactStripHeight),
            compactCandidateHeight: get(.compactCandidateHeight),
            preeditHeight: get(.preeditHeight),
            candidateFontSize: get(.candidateFontSize),
            labelFontSize: get(.labelFontSize)
        )
    }

    static func value(for metric: CandidateWindowMetric) -> CGFloat {
        migrateCompactDefaultsIfNeeded()
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: metric.userDefaultsKey) != nil else {
            return CGFloat(metric.defaultValue)
        }
        return CGFloat(clamp(defaults.double(forKey: metric.userDefaultsKey), to: metric.range))
    }

    static func set(_ value: Double, for metric: CandidateWindowMetric) {
        let clamped = clamp(value, to: metric.range)
        UserDefaults.standard.set(clamped, forKey: metric.userDefaultsKey)
        IMELog.write("candidate window metric \(metric.rawValue)=\(clamped)")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    static func apply(_ values: [CandidateWindowMetric: Double]) {
        let resolved = resolvedValues(values)
        for metric in CandidateWindowMetric.allCases {
            guard let value = resolved[metric] else { continue }
            UserDefaults.standard.set(value, forKey: metric.userDefaultsKey)
        }
        IMELog.write("candidate window metrics applied")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    /// Resolve the container chain in dependency order. Repeating the pass keeps
    /// this correct even if enum declaration order changes: strip -> button ->
    /// candidate font -> index label.
    static func resolvedValues(
        _ raw: [CandidateWindowMetric: Double]
    ) -> [CandidateWindowMetric: Double] {
        var resolved: [CandidateWindowMetric: Double] = [:]

        while resolved.count < CandidateWindowMetric.allCases.count {
            let countBeforePass = resolved.count
            for metric in CandidateWindowMetric.allCases where resolved[metric] == nil {
                if let dependency = metric.containerMetric,
                   resolved[dependency.metric] == nil {
                    continue
                }
                let supported = metric.supportedRange(given: resolved)
                resolved[metric] = clamp(
                    (raw[metric] ?? metric.defaultValue).rounded(),
                    to: supported
                )
            }

            guard resolved.count > countBeforePass else {
                // Defensive fallback for a future accidental dependency cycle.
                for metric in CandidateWindowMetric.allCases where resolved[metric] == nil {
                    resolved[metric] = clamp(
                        (raw[metric] ?? metric.defaultValue).rounded(),
                        to: metric.range
                    )
                }
                break
            }
        }
        return resolved
    }

    static func resetToDefaults() {
        for metric in CandidateWindowMetric.allCases {
            UserDefaults.standard.removeObject(forKey: metric.userDefaultsKey)
        }
        IMELog.write("candidate window metrics reset")
        NotificationCenter.default.post(name: .candidateWindowMetricsDidChange, object: nil)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func migrateCompactDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: compactDefaultsMigrationKey) else { return }
        let oldDefaults: [CandidateWindowMetric: Double] = [
            .compactStripHeight: 40,
            .compactCandidateHeight: 30,
            .preeditHeight: 22,
            .labelFontSize: 11,
        ]
        for (metric, oldValue) in oldDefaults {
            guard defaults.object(forKey: metric.userDefaultsKey) != nil else { continue }
            if abs(defaults.double(forKey: metric.userDefaultsKey) - oldValue) < 0.001 {
                defaults.set(metric.defaultValue, forKey: metric.userDefaultsKey)
            }
        }
        defaults.set(true, forKey: compactDefaultsMigrationKey)
    }
}

// MARK: - Pure compact-strip geometry

/// The layout math shared by the live candidate window and the settings preview.
/// Both must compute identical geometry, so it lives here as pure functions of a
/// `CandidateWindowMetrics` value — no window state, no side effects.
enum CandidateLayout {
    static let actionButtonSize: CGFloat = 28
    static let candidateSpacing: CGFloat = 3
    static let candidateSeparatorWidth: CGFloat = 8
    static let candidateSeparatorRunWidth = candidateSeparatorWidth + candidateSpacing * 2
    static let barSpacing: CGFloat = 4
    /// CandidateSurface uses a 4pt strip inset (`space1`). Keep this separate
    /// from the 6pt pill padding so the AppKit window follows the same rhythm.
    static let barHorizontalPadding: CGFloat = 4
    /// CSS specifies `padding-inline: 6px`; the native width helper stores the
    /// combined inset because CoreText reports glyph width without padding.
    static let compactCandidateHorizontalPadding: CGFloat = 12
    static let selectedCandidateCornerRadius: CGFloat = 6
    static let stripCornerRadius: CGFloat = 6
    static let preeditCornerRadius: CGFloat = 5
    static let preeditHorizontalPadding: CGFloat = 6
    static let annotationFontSize: CGFloat = 9
    static let bufferActionMinWidth: CGFloat = 38
    static let rootSpacing: CGFloat = 5

    /// Vertical inset between the strip edge and its tallest child.
    static func barVerticalPadding(_ m: CandidateWindowMetrics) -> CGFloat {
        let tallestChild = max(actionButtonSize, min(m.compactCandidateHeight, m.compactStripHeight - 2))
        return max(1, floor((m.compactStripHeight - tallestChild) / 2))
    }

    /// The height a candidate button actually renders at — never taller than the
    /// space the strip leaves for it. This clamp is exactly why the button-height
    /// control must forbid values above `stripHeight - 2` (see `supportedRange`):
    /// anything larger is silently absorbed here and never shows.
    static func candidateButtonHeight(_ m: CandidateWindowMetrics) -> CGFloat {
        let available = m.compactStripHeight - 2 * barVerticalPadding(m)
        return min(m.compactCandidateHeight, max(22, available))
    }

    /// The compact strip's rendered height (grows to fit the button if needed).
    static func compactStripHeight(_ m: CandidateWindowMetrics) -> CGFloat {
        max(m.compactStripHeight, candidateButtonHeight(m) + 2 * barVerticalPadding(m))
    }

    static func dividerHeight(_ m: CandidateWindowMetrics) -> CGFloat {
        min(compactStripHeight(m) - 8, max(20, m.compactStripHeight - 10))
    }

    /// Raises the smaller index font so its visual centre matches the candidate
    /// glyph. Point-size subtraction is not sufficient because AppKit fonts use
    /// different ascender and descender proportions.
    static func centeredLabelBaselineOffset(
        labelFont: NSFont,
        candidateFont: NSFont
    ) -> CGFloat {
        let labelCenter = (labelFont.ascender + labelFont.descender) / 2
        let candidateCenter = (candidateFont.ascender + candidateFont.descender) / 2
        return candidateCenter - labelCenter
    }
}

extension CandidateWindowMetric {
    /// A metric whose current value caps this metric's usable upper bound. A
    /// "child" (candidate button, candidate glyph, index label) can never render
    /// larger than the container that holds it; past that point the window clips
    /// or silently clamps, so the size control must not allow it.
    var containerMetric: (metric: CandidateWindowMetric, slack: Double)? {
        switch self {
        case .compactCandidateHeight: return (.compactStripHeight, 2)   // button ≤ strip − 2px
        case .candidateFontSize:       return (.compactCandidateHeight, 6) // glyph ≤ button − 6px
        case .labelFontSize:          return (.candidateFontSize, 0)     // index label ≤ candidate glyph
        default:                      return nil
        }
    }

    /// The sub-interval of `range` that actually renders as set, given the
    /// current values of the other metrics. Outside it the layout absorbs the
    /// change, so the UI hard-limits controls to this range.
    func supportedRange(given values: [CandidateWindowMetric: Double]) -> ClosedRange<Double> {
        guard let dep = containerMetric, let cap = values[dep.metric] else { return range }
        let upper = max(range.lowerBound, min(range.upperBound, cap - dep.slack))
        return range.lowerBound...upper
    }
}

struct CandidateSelection {
    let pageOffset: Int
    let index: Int
}

enum CandidatePresentationMode {
    case caret
    case bufferCaret
}

enum CandidatePanelPreferredSide: Equatable {
    case below
    case above
}

enum CandidatePanelGeometry {
    static func origin(anchor: NSRect,
                       panelSize: NSSize,
                       visibleFrame: NSRect,
                       preferredSide: CandidatePanelPreferredSide = .below) -> NSPoint {
        var x = anchor.minX
        let belowY = anchor.minY - panelSize.height - 6
        let aboveY = anchor.maxY + 6
        var y: CGFloat
        switch preferredSide {
        case .below:
            y = belowY
            if y < visibleFrame.minY {
                y = aboveY
            }
        case .above:
            y = aboveY
            if y + panelSize.height > visibleFrame.maxY {
                y = belowY
            }
        }
        x = min(max(x, visibleFrame.minX + 6),
                visibleFrame.maxX - panelSize.width - 6)
        y = min(max(y, visibleFrame.minY + 6),
                visibleFrame.maxY - panelSize.height - 6)
        return NSPoint(x: x, y: y)
    }

    static func originIfAvailable(anchor: NSRect,
                                  panelSize: NSSize,
                                  visibleFrame: NSRect,
                                  preferredSide: CandidatePanelPreferredSide,
                                  strictPreferredSide: Bool) -> NSPoint? {
        if strictPreferredSide {
            switch preferredSide {
            case .below:
                guard anchor.minY - panelSize.height - 6
                        >= visibleFrame.minY + 6 else { return nil }
            case .above:
                guard anchor.maxY + 6 + panelSize.height
                        <= visibleFrame.maxY - 6 else { return nil }
            }
        }
        return origin(anchor: anchor,
                      panelSize: panelSize,
                      visibleFrame: visibleFrame,
                      preferredSide: preferredSide)
    }
}

struct CandidateMatrixLayoutSnapshot {
    let initialPanelLevel: Int
    let iShotPanelLevel: Int
    let hiddenPanelLevel: Int
    let panelCollectionBehavior: NSWindow.CollectionBehavior
    let rowCount: Int
    let rowHeights: [CGFloat]
    let expectedRowHeight: CGFloat
    let documentHeight: CGFloat
    let expectedDocumentHeight: CGFloat
    let scrollHeight: CGFloat
    let panelHeight: CGFloat
    let expectedPanelHeight: CGFloat
    let documentTranslatesAutoresizingMaskIntoConstraints: Bool
    let documentAutoresizingMaskConstraintCount: Int
}

struct CandidateTextRendererSnapshot {
    let nativeButtonTitleIsEmpty: Bool
    let nativeAttributedTitleIsEmpty: Bool
    let buttonBounds: NSRect
    let titleViewFrame: NSRect
    let requiredLineHeight: CGFloat
    let baselineCenterDelta: CGFloat
    let titleViewHitTestIsNil: Bool
    let candidateGlyphPixelCount: Int
    let horizontalInkCenterDelta: CGFloat
    let verticalInkCenterDelta: CGFloat
}

struct CandidateBufferCaretSnapshot {
    let contentStayedInPanel: Bool
    let renderedCandidateViews: Int
    let preeditHidden: Bool
    let stripOnlyHeight: CGFloat
    let expectedStripOnlyHeight: CGFloat
    let bufferActionHidden: Bool
    let rejectedCachedHostAnchor: Bool
    let scrubbedCandidateViews: Bool
    let scrubbedPreedit: Bool
}

/// In-process candidate window. Candidates default to a compact one-line strip
/// and can expand into a matrix of consecutive Rime pages, one page per row.
/// The matrix renders at most three rows at a time, but that is a viewport, not
/// a limit: it slides over every page fetched so far and the owner keeps pulling
/// pages until Rime reports the last one, so the whole candidate list is
/// reachable by holding ↓.
final class CandidateWindow {
    private static let candidateSpacing = CandidateLayout.candidateSpacing
    private static let candidateSeparatorWidth = CandidateLayout.candidateSeparatorWidth
    private static let barSpacing = CandidateLayout.barSpacing
    private static let barHorizontalPadding = CandidateLayout.barHorizontalPadding
    private static let actionButtonSize = CandidateLayout.actionButtonSize
    private static let compactCandidateHorizontalPadding = CandidateLayout.compactCandidateHorizontalPadding
    private static let expandedRowSpacing: CGFloat = 3
    /// Vertical limit of the matrix. Three rows is the visual cap, NOT the
    /// reach: the viewport slides over every fetched page (see `windowBase`).
    static let expandedMaxRows = 3
    private static let characterSelectionTagBase = 200_000

    private let panel: NSPanel
    private let panelHost = NSView()
    private let content = NSView()
    private let root = NSStackView()
    private let preeditPill = NSView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let candidateScroll = NSScrollView()
    private let candidateStack = NSStackView()
    private let divider = NSView()
    private let settingsButton = CandidateActionButton(symbolName: "gearshape", title: "")
    private var stripHeightConstraint: NSLayoutConstraint!
    private var candidateHeightConstraint: NSLayoutConstraint!
    private var preeditHeightConstraint: NSLayoutConstraint!
    private var preeditWidthConstraint: NSLayoutConstraint!
    private var dividerHeightConstraint: NSLayoutConstraint!
    private var barTopConstraint: NSLayoutConstraint!
    private var barBottomConstraint: NSLayoutConstraint!
    private var lastGoodCaretRect: NSRect?

    private var currentContext = RimeContextModel()
    private var currentSignature = ""
    private var selectedIndex = 0
    private var visualPageIndex = 0
    /// Every Rime page fetched so far, one row each. The index IS the page
    /// offset from the anchor page, which is what `CandidateSelection.pageOffset`
    /// means — so this array may grow past the three visible rows, but an entry
    /// must never be dropped or reordered.
    private var expandedPages: [RimeContextModel] = []
    /// Page offset of the top rendered row: the three-row viewport slides over
    /// `expandedPages` so the whole candidate list stays reachable.
    private var expandedWindowBase = 0
    /// Candidate index of the leftmost rendered item in each Rime page. Every
    /// matrix row owns its own horizontal viewport: a long candidate in one row
    /// must neither stretch nor scroll any other row.
    private var expandedColumnBases: [Int: Int] = [:]
    private var expandedSelectionPageOffset = 0
    private var characterSelectionText = ""
    private var characterSelectionIndex = 0
    private var lastCaretRect = NSRect.zero
    private var lastBundleId = ""
    private var ownerToken: FocusToken?
    private var presentationMode: CandidatePresentationMode = .caret
    private var projectionPreedit = ""
    private weak var contentHost: NSView?
    private var contentHostConstraints: [NSLayoutConstraint] = []

    var onSelect: ((FocusToken, CandidateSelection) -> Void)?
    var onSettings: (() -> Void)?

    var hasCandidates: Bool {
        guard let ownerToken,
              InputFocusCoordinator.shared.interactionTarget(expected: ownerToken) != nil else { return false }
        return !currentContext.candidates.isEmpty
    }
    /// Candidate-only keyboard and mouse actions require WindowServer-visible
    /// candidates. Logical context remains available to composition cleanup,
    /// but a panel hidden by privacy/layout/Space transitions must not capture
    /// arrows, Return, Space, Option-selection, or paging.
    var hasInteractableCandidates: Bool {
        CandidatePanelInteractionRules.mayInteract(
            hasLogicalCandidates: !currentContext.candidates.isEmpty,
            hasInteractionTarget: ownerToken.map {
                InputFocusCoordinator.shared.interactionTarget(expected: $0) != nil
            } ?? false,
            panelIsVisible: presentationIsVisible,
            panelIsOnActiveSpace: presentationIsOnActiveSpace
        )
    }
    var isVisible: Bool {
        guard let ownerToken,
              InputFocusCoordinator.shared.interactionTarget(expected: ownerToken) != nil,
              !currentContext.candidates.isEmpty || !projectionPreedit.isEmpty else {
            return false
        }
        // Logical candidate state is not enough: AppKit can order a panel out
        // during an application/Space transition without changing our owner or
        // Rime context. Callers asking whether candidates are visible must see
        // the WindowServer truth, otherwise a hidden panel can keep steering
        // candidate-only key paths indefinitely.
        guard presentationIsVisible, presentationIsOnActiveSpace else { return false }
        return !currentContext.candidates.isEmpty || !projectionPreedit.isEmpty
    }
    var isExpanded: Bool { !expandedPages.isEmpty }
    /// How many Rime pages the matrix has fetched, and where the selection sits
    /// in them — the owner uses these to pull more pages before the selection
    /// runs off the fetched tail.
    var expandedPageCount: Int { expandedPages.count }
    var expandedSelectionPage: Int { expandedSelectionPageOffset }
    /// True when Rime says the last fetched page ends the list (nothing to pull).
    var expandedTailIsLastPage: Bool { expandedPages.last?.isLastPage ?? true }
    var isSingleCharacterSelectionActive: Bool { !characterSelectionText.isEmpty }
    var rawInputForCommit: String { currentContext.input }
    var selectedCandidateText: String? {
        guard hasCandidates else { return nil }
        if isExpanded {
            let pageOffset = clamp(expandedSelectionPageOffset, count: expandedPages.count)
            let row = expandedPages[pageOffset].candidates
            guard !row.isEmpty else { return nil }
            return row[clamp(selectedIndex, count: row.count)].text
        }
        guard !currentContext.candidates.isEmpty else { return nil }
        return currentContext.candidates[clamp(selectedIndex, count: currentContext.candidates.count)].text
    }
    var selectedSingleCharacterText: String? {
        guard isSingleCharacterSelectionActive else { return nil }
        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return nil }
        return String(chars[clamp(characterSelectionIndex, count: chars.count)])
    }
    var selectedCandidateSelection: CandidateSelection? {
        guard hasCandidates else { return nil }
        if isExpanded {
            let pageOffset = clamp(expandedSelectionPageOffset, count: expandedPages.count)
            let count = expandedCandidateCount(pageOffset: pageOffset)
            guard count > 0 else { return nil }
            return CandidateSelection(pageOffset: pageOffset,
                                      index: clamp(selectedIndex, count: count))
        }
        return CandidateSelection(pageOffset: 0,
                                  index: clamp(selectedIndex, count: currentContext.candidates.count))
    }
    private let bufferActionTag = -1000

    init() {
        let metrics = CandidateWindowMetrics.current
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0,
                                            width: metrics.baseWidth,
                                            height: metrics.compactStripHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets the AppKit level to `.floating`; establish
        // the candidate policy after toggling it so ordinary hosts really use
        // `.popUpMenu` rather than inheriting that lower level.
        panel.level = CandidatePanelLevelRules.standard
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = CandidatePanelSpaceRules.collectionBehavior

        // React CandidateSurface treats preedit as an independent 20pt pill,
        // not as a full-width row painted by the candidate strip. Preserve the
        // native label (and therefore IMK-safe, non-WebView rendering), while
        // mirroring its 12pt monospace typography and 6pt horizontal padding.
        preeditPill.wantsLayer = true
        preeditPill.layer?.cornerRadius = CandidateLayout.preeditCornerRadius
        preeditPill.layer?.borderWidth = 1
        preeditPill.layer?.masksToBounds = true
        preeditPill.translatesAutoresizingMaskIntoConstraints = false
        preeditPill.isHidden = true

        preeditLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preeditLabel.lineBreakMode = .byTruncatingTail
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        preeditPill.addSubview(preeditLabel)
        preeditHeightConstraint = preeditPill.heightAnchor.constraint(equalToConstant: metrics.preeditHeight)
        preeditWidthConstraint = preeditPill.widthAnchor.constraint(
            equalToConstant: CandidateLayout.preeditHorizontalPadding * 2
        )
        NSLayoutConstraint.activate([
            preeditHeightConstraint,
            preeditWidthConstraint,
            preeditLabel.leadingAnchor.constraint(
                equalTo: preeditPill.leadingAnchor,
                constant: CandidateLayout.preeditHorizontalPadding
            ),
            preeditLabel.trailingAnchor.constraint(
                equalTo: preeditPill.trailingAnchor,
                constant: -CandidateLayout.preeditHorizontalPadding
            ),
            preeditLabel.centerYAnchor.constraint(equalTo: preeditPill.centerYAnchor),
        ])

        strip.wantsLayer = true
        strip.layer?.cornerRadius = CandidateLayout.stripCornerRadius
        strip.layer?.borderWidth = 1
        strip.layer?.masksToBounds = true
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: metrics.compactStripHeight)
        stripHeightConstraint.isActive = true

        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing
        candidateStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        // `NSScrollView.documentView` is frame-driven here. Leaving the stack's
        // autoresizing mask enabled creates a required 24pt document-height
        // constraint from the compact state; a three-row matrix needs 78pt and
        // AppKit then breaks every row/button height constraint.
        candidateStack.translatesAutoresizingMaskIntoConstraints = false

        candidateScroll.drawsBackground = false
        candidateScroll.hasHorizontalScroller = false
        candidateScroll.hasVerticalScroller = false
        candidateScroll.horizontalScrollElasticity = .none
        candidateScroll.verticalScrollElasticity = .none
        candidateScroll.documentView = candidateStack
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        candidateHeightConstraint = candidateScroll.heightAnchor.constraint(equalToConstant: metrics.compactCandidateHeight)
        candidateHeightConstraint.isActive = true

        divider.wantsLayer = true
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        dividerHeightConstraint = divider.heightAnchor.constraint(equalToConstant: dividerHeight(for: metrics))
        dividerHeightConstraint.isActive = true

        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.toolTip = "打开设置"
        settingsButton.setAccessibilityElement(true)
        settingsButton.setAccessibilityRole(.button)
        settingsButton.setAccessibilityLabel("打开设置")
        settingsButton.widthAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true

        let barRow = NSStackView(views: [candidateScroll, divider, settingsButton])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        barRow.spacing = Self.barSpacing
        barRow.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(barRow)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint = barRow.topAnchor.constraint(equalTo: strip.topAnchor, constant: padding)
        barBottomConstraint = barRow.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -padding)
        NSLayoutConstraint.activate([
            barRow.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Self.barHorizontalPadding),
            barRow.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -Self.barHorizontalPadding),
            barTopConstraint,
            barBottomConstraint,
        ])

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = CandidateLayout.rootSpacing
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(preeditPill)
        root.addArrangedSubview(strip)

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preeditPill.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preeditPill.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
        ])
        panelHost.wantsLayer = true
        panelHost.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = panelHost
        attachContent(
            to: panelHost,
            insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        )

        applyAppearance()
        NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
            self?.renderCandidates()
            self?.layoutAndShowAccordingToPresentation()
        }
        NotificationCenter.default.addObserver(
            forName: .candidateWindowMetricsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyMetrics()
            self?.renderCandidates()
            self?.layoutAndShowAccordingToPresentation()
        }
    }

    private var presentationIsVisible: Bool {
        panel.isVisible
    }

    private var presentationIsOnActiveSpace: Bool {
        panel.isOnActiveSpace
    }

    private func attachContent(to host: NSView, insets: NSEdgeInsets) {
        guard contentHost !== host else { return }
        NSLayoutConstraint.deactivate(contentHostConstraints)
        contentHostConstraints.removeAll()
        content.removeFromSuperview()
        host.addSubview(content)
        contentHost = host
        contentHostConstraints = [
            content.leadingAnchor.constraint(
                equalTo: host.leadingAnchor,
                constant: insets.left
            ),
            content.trailingAnchor.constraint(
                equalTo: host.trailingAnchor,
                constant: -insets.right
            ),
            content.topAnchor.constraint(
                equalTo: host.topAnchor,
                constant: insets.top
            ),
            content.bottomAnchor.constraint(
                equalTo: host.bottomAnchor,
                constant: -insets.bottom
            ),
        ]
        NSLayoutConstraint.activate(contentHostConstraints)
        host.needsLayout = true
    }

    private func attachContentToPanel() {
        attachContent(
            to: panelHost,
            insets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        )
    }

    func update(_ ctx: RimeContextModel,
                caretRect: NSRect,
                bundleId: String,
                showPreedit: Bool,
                owner: FocusToken,
                presentation: CandidatePresentationMode) {
        guard InputFocusCoordinator.shared.isCurrent(owner) else {
            IMELog.write("candidate stale update ignored owner=\(owner)")
            return
        }
        guard !ctx.candidates.isEmpty
                || (showPreedit && (!ctx.preedit.isEmpty || !ctx.input.isEmpty)) else {
            hide(owner: owner)
            return
        }

        if ownerToken != owner {
            panel.level = CandidatePanelLevelRules.standard
            resetPresentationState()
        }
        if presentationMode != presentation {
            lastGoodCaretRect = nil
        }
        ownerToken = owner
        presentationMode = presentation
        let signature = contextSignature(ctx)
        let signatureChanged = signature != currentSignature
        if signature != currentSignature {
            resetExpandedState()
            resetCharacterSelectionState()
            selectedIndex = clamp(ctx.highlightedIndex, count: ctx.candidates.count)
            currentSignature = signature
        }

        currentContext = ctx
        // A preedit-only composition belongs in the Buffer, but it must not
        // reserve an empty candidate strip or expose an inert settings button.
        strip.isHidden = ctx.candidates.isEmpty
        lastCaretRect = caretRect
        lastBundleId = bundleId
        if signatureChanged {
            visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        } else {
            visualPageIndex = clampVisualPage(visualPageIndex, panelWidth: activePanelWidth())
            if isExpanded {
                expandedPages[0] = ctx
            }
        }

        projectionPreedit = showPreedit ? (ctx.preedit.isEmpty ? ctx.input : ctx.preedit) : ""
        preeditLabel.stringValue = projectionPreedit
        preeditPill.isHidden = preeditLabel.stringValue.isEmpty
        updatePreeditWidth()
        applyAppearance()
        renderCandidates()
        layoutAndShowAccordingToPresentation()
    }

    func hide(owner: FocusToken) {
        guard let ownerToken else {
            hidePanel(reason: "owner-hide-without-presentation",
                      clearsPresentation: true)
            return
        }
        guard ownerToken == owner else {
            IMELog.write("candidate stale hide ignored owner=\(owner)")
            return
        }
        hidePanel(reason: "owner-hide", clearsPresentation: true)
    }

    func hideAll() {
        hidePanel(reason: "global-hide", clearsPresentation: true)
    }

    private func resetPresentationState() {
        scrubRenderedCandidateViews()
        visualPageIndex = 0
        selectedIndex = 0
        resetExpandedState()
        resetCharacterSelectionState()
        currentContext = RimeContextModel()
        currentSignature = ""
        projectionPreedit = ""
        ownerToken = nil
        presentationMode = .caret
        lastCaretRect = .zero
        lastBundleId = ""
        lastGoodCaretRect = nil
        preeditLabel.stringValue = ""
        preeditPill.isHidden = true
        strip.isHidden = false
    }

    private func scrubRenderedCandidateViews() {
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        preeditLabel.stringValue = ""
        preeditLabel.setAccessibilityValue(nil)
        candidateScroll.toolTip = nil
        candidateStack.toolTip = nil
    }

    /// Moving/resizing the passive workbench does not re-read Rime, but the
    /// floating panel must re-read the live logical Buffer caret every time.
    func syncWorkbenchLayout() {
        guard presentationMode == .bufferCaret,
              let ownerToken,
              let caret = BufferWindowController.shared
                .inlineInputCaretScreenRect(owner: ownerToken) else {
            if presentationMode == .bufferCaret {
                hidePanel(reason: "buffer-caret-unavailable",
                          clearsPresentation: false)
            }
            return
        }
        lastCaretRect = caret
        renderCandidates()
        layoutAndShowAccordingToPresentation()
    }

    @discardableResult
    func beginSingleCharacterSelection(candidateText: String) -> Bool {
        let chars = Array(candidateText)
        guard chars.count > 1 else { return false }
        resetExpandedState()
        characterSelectionText = candidateText
        characterSelectionIndex = 0
        renderCandidates()
        layoutAndShowAccordingToPresentation()
        return true
    }

    @discardableResult
    func moveSingleCharacterSelection(delta: Int) -> Bool {
        guard isSingleCharacterSelectionActive else { return false }
        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return false }
        let logicalDelta = delta
        characterSelectionIndex = clamp(characterSelectionIndex + logicalDelta, count: chars.count)
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    func cancelSingleCharacterSelection() {
        guard isSingleCharacterSelectionActive else { return }
        resetCharacterSelectionState()
        selectedIndex = clamp(selectedIndex, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        layoutAndShowAccordingToPresentation()
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        if isExpanded {
            return moveExpandedSelection(columnDelta: delta)
        }
        guard !currentContext.candidates.isEmpty else { return false }
        let logicalDelta = delta
        selectedIndex = clamp(selectedIndex + logicalDelta, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    @discardableResult
    func moveExpandedSelection(rowDelta: Int) -> Bool {
        guard isExpanded else { return false }
        if rowDelta < 0, expandedSelectionPageOffset == 0 {
            return collapseExpanded()
        }
        let nextOffset = expandedSelectionPageOffset + rowDelta
        // At the fetched tail the owner had its chance to pull more pages; if
        // none arrived we are genuinely at the end of the list, so hold still.
        guard expandedPages.indices.contains(nextOffset) else { return true }
        expandedSelectionPageOffset = nextOffset
        scrollExpandedWindowToSelection()
        clampExpandedSelectionToVisiblePrefix()
        renderCandidates()
        logExpandedVisiblePrefix(reason: "row move")
        resetCandidateScroll()
        return true
    }

    @discardableResult
    func expand(with pages: [RimeContextModel]) -> Bool {
        let usablePages = pages.filter { !$0.candidates.isEmpty }
        guard !usablePages.isEmpty else { return false }
        expandedPages = usablePages
        expandedSelectionPageOffset = min(expandedSelectionPageOffset, expandedPages.count - 1)
        expandedColumnBases.removeAll()
        scrollExpandedWindowToSelection()
        guard expandedCandidateCount(pageOffset: expandedSelectionPageOffset) > 0 else {
            IMELog.write("candidate matrix skipped; selected row has no candidates")
            resetExpandedState()
            return true
        }
        clampExpandedSelectionToVisiblePrefix()
        renderCandidates()
        logExpandedVisiblePrefix(reason: "expand")
        layoutAndShowAccordingToPresentation()
        return true
    }

    /// Take a longer page list re-read from the same anchor. Index still means
    /// page offset, so the current row/selection stay valid and only the
    /// reachable tail grows.
    func extendExpandedPages(with pages: [RimeContextModel]) {
        guard isExpanded else { return }
        let usablePages = pages.filter { !$0.candidates.isEmpty }
        guard usablePages.count > expandedPages.count else { return }
        expandedPages = usablePages
        IMELog.write("candidate matrix pages fetched=\(expandedPages.count) last=\(expandedTailIsLastPage)")
    }

    /// Slide the viewport so `selection` stays visible, one row at a time.
    /// Pure and static so `matrix-smoke` can pin the scroll invariants without
    /// a window server: the result is always a valid base whose `maxRows`-tall
    /// window contains `selection`.
    static func windowBase(selection: Int, currentBase: Int, pageCount: Int,
                           maxRows: Int = CandidateWindow.expandedMaxRows) -> Int {
        guard pageCount > 0, maxRows > 0 else { return 0 }
        var base = currentBase
        if selection < base {
            base = selection
        } else if selection >= base + maxRows {
            base = selection - maxRows + 1
        }
        return min(max(0, base), max(0, pageCount - maxRows))
    }

    /// Height of the visible matrix document. Pure so `matrix-smoke` can pin
    /// the one/two/three-row transition without depending on a window server.
    static func matrixViewportHeight(rowHeight: CGFloat, rowCount: Int) -> CGFloat {
        let visibleRows = max(1, min(expandedMaxRows, rowCount))
        return CGFloat(visibleRows) * rowHeight
            + CGFloat(max(0, visibleRows - 1)) * expandedRowSpacing
    }

    /// Keep the selected row inside the three-row viewport.
    private func scrollExpandedWindowToSelection() {
        expandedWindowBase = Self.windowBase(selection: expandedSelectionPageOffset,
                                             currentBase: expandedWindowBase,
                                             pageCount: expandedPages.count)
    }

    /// Page offsets of the rows currently rendered.
    private func expandedWindowRange() -> Range<Int> {
        guard !expandedPages.isEmpty else { return 0..<0 }
        let base = min(max(0, expandedWindowBase),
                       max(0, expandedPages.count - Self.expandedMaxRows))
        return base..<min(base + Self.expandedMaxRows, expandedPages.count)
    }

    @discardableResult
    func collapseExpanded() -> Bool {
        guard isExpanded else { return false }
        resetExpandedState()
        selectedIndex = clamp(selectedIndex, count: currentContext.candidates.count)
        visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        renderCandidates()
        layoutAndShowAccordingToPresentation()
        return true
    }

    private func moveExpandedSelection(columnDelta: Int) -> Bool {
        guard isExpanded,
              expandedPages.indices.contains(expandedSelectionPageOffset) else {
            return false
        }
        let row = expandedPages[expandedSelectionPageOffset].candidates
        guard !row.isEmpty else { return false }
        let logicalDelta = columnDelta
        // Bounded by the whole page, not by what fits: the column viewport
        // scrolls so ←/→ can reach candidates past the right edge.
        selectedIndex = clamp(selectedIndex + logicalDelta, count: row.count)
        scrollExpandedColumnsToSelection()
        renderCandidates()
        logExpandedVisiblePrefix(reason: "column move")
        resetCandidateScroll()
        return true
    }

    private func resetExpandedState() {
        expandedPages.removeAll()
        expandedWindowBase = 0
        expandedColumnBases.removeAll()
        expandedSelectionPageOffset = 0
    }

    private func resetCharacterSelectionState() {
        characterSelectionText = ""
        characterSelectionIndex = 0
    }

    @discardableResult
    func movePage(delta: Int) -> Bool {
        guard !currentContext.candidates.isEmpty else { return false }
        let pages = candidatePages(panelWidth: activePanelWidth())
        guard !pages.isEmpty else { return false }
        let currentPage = clampVisualPage(visualPageIndex, pageCount: pages.count)
        let nextPage = currentPage + delta
        guard pages.indices.contains(nextPage) else { return false }

        visualPageIndex = nextPage
        if let first = pages[nextPage].first {
            selectedIndex = first
        }
        renderCandidates()
        resetCandidateScroll()
        return true
    }

    func performBufferAction() {
        guard !BufferModel.shared.active else {
            IMELog.write("candidate buffer action ignored; already enabled")
            renderCandidates()
            BufferWindowController.shared.show()
            return
        }
        let activated = BufferWindowController.shared
            .activateCaptureForCurrentFocus(showWorkbench: true)
        IMELog.write("candidate buffer action -> \(activated ? "capture" : "direct")")
        renderCandidates()
        BufferWindowController.shared.refresh()
    }

    /// Resolve a number-key selection against the row that currently owns the
    /// matrix labels. Keys count the columns actually on screen, so they map
    /// through the column viewport onto the candidate's real page index.
    func expandedSelection(atVisibleIndex index: Int) -> CandidateSelection? {
        guard isExpanded,
              expandedPages.indices.contains(expandedSelectionPageOffset),
              index >= 0 else {
            return nil
        }
        let columns = expandedColumnRange()
        let candidateIndex = columns.lowerBound + index
        guard index < columns.count,
              candidateIndex < expandedCandidateCount(pageOffset: expandedSelectionPageOffset) else {
            return nil
        }
        return CandidateSelection(pageOffset: expandedSelectionPageOffset, index: candidateIndex)
    }

    // MARK: Positioning

    @discardableResult
    private func layoutPanel(caretRect: NSRect, bundleId: String) -> Bool {
        let metrics = CandidateWindowMetrics.current
        panel.setContentSize(desiredPanelContentSize(caretRect: caretRect, metrics: metrics))
        panel.layoutIfNeeded()
        updateCandidateDocumentSize()
        resetCandidateScroll()
        guard let origin = origin(for: caretRect, bundleId: bundleId) else {
            return false
        }
        panel.setFrameOrigin(origin)
        return true
    }

    private func desiredPanelContentSize(
        caretRect: NSRect,
        metrics: CandidateWindowMetrics
    ) -> NSSize {
        let stripHeight = strip.isHidden ? 0 : stripHeightConstraint.constant
        let preeditHeight = preeditPill.isHidden ? 0 : metrics.preeditHeight
        let interItemSpacing = preeditPill.isHidden || strip.isHidden
            ? 0
            : root.spacing
        let height = stripHeight + preeditHeight + interItemSpacing
        return NSSize(width: activePanelWidth(), height: height)
    }

    /// Resolve the final panel, scroll viewport, and document frame before rows
    /// are attached. This keeps AppKit from laying a three-row stack inside the
    /// stale compact (one-row) document geometry during reconciliation.
    private func prepareCandidateGeometryForRendering() {
        let metrics = CandidateWindowMetrics.current
        panel.setContentSize(desiredPanelContentSize(caretRect: lastCaretRect, metrics: metrics))
        panel.layoutIfNeeded()
        candidateStack.setFrameSize(NSSize(
            width: candidateScroll.contentSize.width,
            height: candidateAreaHeight(for: metrics)
        ))
    }

    private func origin(for caretRect: NSRect, bundleId: String) -> NSPoint? {
        var anchor = caretRect
        if isPlausible(anchor) {
            lastGoodCaretRect = anchor
        } else if presentationMode == .caret,
                  let cached = lastGoodCaretRect {
            anchor = cached
        } else if presentationMode == .bufferCaret {
            // A Buffer caret belongs to a short-lived logical surface. Never
            // jump to a cached host caret when that surface is hidden/stale.
            return nil
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: vf.midX - panel.frame.width / 2, y: vf.minY + 120)
        }

        let screen = screen(containing: anchor)
        let vf = screen?.visibleFrame ?? .zero
        return CandidatePanelGeometry.originIfAvailable(
            anchor: anchor,
            panelSize: panel.frame.size,
            visibleFrame: vf,
            preferredSide: .below,
            strictPreferredSide: false
        )
    }

    private func isPlausible(_ r: NSRect) -> Bool {
        guard r != .zero, r.height > 2, r.height < 300 else { return false }
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -8, dy: -8).contains(r.origin) }
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -8, dy: -8).contains(rect.origin) }
            ?? NSScreen.main
    }

    private func panelWidth(caretRect: NSRect) -> CGFloat {
        let metrics = CandidateWindowMetrics.current
        let visibleWidth = (screen(containing: caretRect)?.visibleFrame.width ?? metrics.baseWidth) - 12
        return min(max(metrics.baseWidth, 360), max(360, visibleWidth))
    }

    private func layoutAndShowAccordingToPresentation() {
        guard let ownerToken else {
            hidePanel(reason: "missing-owner", clearsPresentation: true)
            return
        }
        guard let interactionTarget = InputFocusCoordinator.shared.interactionTarget(
                expected: ownerToken
              ) else {
            // Authority is fail-closed. Clear the logical presentation as well
            // as the physical panel so a suspended lease cannot leave behind a
            // candidate state that looks visible. A later trusted `update`
            // supplies a fresh context and safely reconstructs the panel.
            hidePanel(reason: "interaction-target-unavailable",
                      clearsPresentation: true)
            return
        }
        guard !currentContext.candidates.isEmpty || !projectionPreedit.isEmpty else {
            hidePanel(reason: "empty-content", clearsPresentation: true)
            return
        }
        guard CandidatePanelSecurityRules.mayOrderFront(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) else {
            hidePanel(reason: "secure-input-before-level", clearsPresentation: true)
            return
        }

        if presentationMode == .bufferCaret {
            guard let caret = BufferWindowController.shared
                .inlineInputCaretScreenRect(owner: ownerToken) else {
                hidePanel(reason: "buffer-caret-unavailable",
                          clearsPresentation: false)
                return
            }
            lastCaretRect = caret
        }

        attachContentToPanel()
        guard layoutPanel(caretRect: lastCaretRect, bundleId: lastBundleId) else {
            hidePanel(reason: "layout-unavailable", clearsPresentation: false)
            return
        }
        panel.level = CandidatePanelLevelRules.level(
            bundleID: interactionTarget.bundleID,
            hostKind: interactionTarget.hostKind
        )
        showPanel(reason: "layout-ready")
    }

    /// Candidate presentation changes are centralized here so logical state and
    /// AppKit visibility cannot silently diverge. Reasons are fixed internal
    /// strings; logs contain only counts, geometry, and focus tokens — never
    /// candidate, preedit, input, or bundle text.
    private func hidePanel(reason: String, clearsPresentation: Bool) {
        let snapshot = panelLogSnapshot()
        panel.orderOut(nil)
        panel.level = CandidatePanelLevelRules.standard
        if clearsPresentation {
            resetPresentationState()
        }
        attachContentToPanel()
        logPanelTransition(
            action: "hide",
            reason: reason,
            before: snapshot,
            retiredPresentation: clearsPresentation
        )
    }

    private func showPanel(reason: String) {
        guard CandidatePanelSecurityRules.mayOrderFront(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) else {
            hidePanel(reason: "secure-input-before-show", clearsPresentation: true)
            return
        }
        let snapshot = panelLogSnapshot()
        if CandidatePanelSpaceRules.shouldOrderOutBeforeShow(
            isVisible: panel.isVisible,
            isOnActiveSpace: panel.isOnActiveSpace
        ) {
            panel.orderOut(nil)
        }
        panel.orderFrontRegardless()
        logPanelTransition(
            action: "show",
            reason: reason,
            before: snapshot,
            retiredPresentation: false
        )
    }

    private struct PanelLogSnapshot {
        let owner: String
        let presentation: String
        let candidateCount: Int
        let preeditLength: Int
        let visible: Bool
        let onActiveSpace: Bool
    }

    private func panelLogSnapshot() -> PanelLogSnapshot {
        let presentation: String
        switch presentationMode {
        case .caret: presentation = "caret"
        case .bufferCaret: presentation = "buffer-caret"
        }
        return PanelLogSnapshot(
            owner: ownerToken?.description ?? "none",
            presentation: presentation,
            candidateCount: currentContext.candidates.count,
            preeditLength: projectionPreedit.count,
            visible: presentationIsVisible,
            onActiveSpace: presentationIsOnActiveSpace
        )
    }

    private func logPanelTransition(action: String,
                                    reason: String,
                                    before: PanelLogSnapshot,
                                    retiredPresentation: Bool) {
        let afterVisible = presentationIsVisible
        let afterOnActiveSpace = presentationIsOnActiveSpace
        let hadLogicalPresentation = before.owner != "none"
            || before.candidateCount > 0
            || before.preeditLength > 0
        // Candidate updates are frequent. Log every real WindowServer
        // transition and every hide that retires logical presentation, while
        // suppressing repeated visible->visible layout refreshes.
        guard before.visible != afterVisible
                || before.onActiveSpace != afterOnActiveSpace
                || (action == "hide"
                    && retiredPresentation
                    && hadLogicalPresentation) else {
            return
        }
        IMELog.write(
            "candidate panel transition action=\(action) reason=\(reason) "
            + "owner=\(before.owner) presentation=\(before.presentation) "
            + "candidates=\(before.candidateCount) preeditLength=\(before.preeditLength) "
            + "visible=\(before.visible)->\(afterVisible) "
            + "onSpace=\(before.onActiveSpace)->\(afterOnActiveSpace) "
            + "frame=\(NSStringFromRect(panel.frame))"
        )
    }

    // MARK: Rendering

    private func renderCandidates() {
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if isExpanded {
            // A too-narrow panel no longer collapses the matrix: at least one
            // column always renders and the viewport scrolls to the rest.
            if expandedCandidateCount(pageOffset: expandedSelectionPageOffset) == 0 {
                IMELog.write("candidate matrix collapsed; selected row has no candidates")
                resetExpandedState()
            } else {
                clampExpandedSelectionToVisiblePrefix()
            }
        }
        visualPageIndex = clampVisualPage(visualPageIndex, panelWidth: activePanelWidth())
        candidateScroll.isHidden = false
        applyMetrics()
        prepareCandidateGeometryForRendering()

        if isSingleCharacterSelectionActive {
            renderSingleCharacterSelectionRow()
        } else if isExpanded {
            renderExpandedMatrix()
        } else {
            renderCompactRow()
        }
        applyAppearance()
        updateCandidateDocumentSize()
    }

    private func renderCompactRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing

        let panelWidth = activePanelWidth()
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let indices = currentVisualCandidateIndices(panelWidth: panelWidth)
        let renderedIndices = indices
        for (offset, i) in renderedIndices.enumerated() {
            if offset > 0 {
                candidateStack.addArrangedSubview(candidateSeparatorView())
            }
            let c = currentContext.candidates[i]
            candidateStack.addArrangedSubview(candidateButton(
                pageOffset: 0,
                index: i,
                candidate: c,
                highlighted: i == selectedIndex,
                compact: true,
                width: nil,
                maxWidth: candidateMaxWidth(panelWidth: panelWidth)
            ))
        }

        if showsBufferAction {
            candidateStack.addArrangedSubview(bufferActionButton(width: min(bufferActionWidth(), available)))
        }
    }

    private func renderExpandedMatrix() {
        candidateStack.orientation = .vertical
        candidateStack.alignment = .leading
        candidateStack.spacing = Self.expandedRowSpacing

        let panelWidth = activePanelWidth()
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let windowRange = expandedWindowRange()
        let pages = expandedPages.isEmpty ? [currentContext] : Array(expandedPages[windowRange])
        // Rows carry their absolute page offset: button tags encode it, and
        // selection replays it as page-downs from the anchor.
        let baseOffset = expandedPages.isEmpty ? 0 : windowRange.lowerBound

        for (rowIndex, page) in pages.enumerated() {
            let pageOffset = baseOffset + rowIndex
            let isActiveRow = pageOffset == expandedSelectionPageOffset
            let naturalWidths = expandedRowNaturalWidths(page: page)
            let columnRange = Self.fittedColumnRange(
                widths: naturalWidths,
                separator: separatorRunWidth(),
                available: available,
                base: expandedColumnBases[pageOffset] ?? 0
            )
            // Candidates carry their absolute index within the page, so tags and
            // number labels stay correct after this row's viewport scrolls.
            let renderedCandidates = Array(
                page.candidates.enumerated()
                    .dropFirst(columnRange.lowerBound)
                    .prefix(columnRange.count)
            )
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = Self.candidateSpacing
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: compactCandidateButtonHeight(
                for: CandidateWindowMetrics.current
            )).isActive = true

            let displayedCandidates = renderedCandidates
            for (offset, element) in displayedCandidates.enumerated() {
                let (index, candidate) = element
                if offset > 0 {
                    row.addArrangedSubview(candidateSeparatorView())
                }
                row.addArrangedSubview(candidateButton(
                    pageOffset: pageOffset,
                    index: index,
                    candidate: candidate,
                    highlighted: isActiveRow && index == selectedIndex,
                    compact: true,
                    width: naturalWidths[index],
                    showsLabel: isActiveRow
                ))
            }
            candidateStack.addArrangedSubview(row)
        }
    }

    /// Each row measures only its own candidates. We still reserve the number
    /// label and selected font weight even while the row is inactive, so moving
    /// the active-row highlight does not reflow that row. No width is shared
    /// across rows.
    private func expandedRowNaturalWidths(page: RimeContextModel) -> [CGFloat] {
        page.candidates.map { candidate in
            ceil(measuredCandidateWidth(candidate,
                                        highlighted: true,
                                        compact: true,
                                        showsLabel: true))
        }
    }

    /// How many whole columns fit starting at `base`. Pure for `matrix-smoke`.
    /// A column wider than the viewport still counts as one: dropping it would
    /// make that candidate permanently unreachable, which is the bug this
    /// viewport exists to avoid.
    static func fittedColumnCount(widths: [CGFloat], separator: CGFloat,
                                  available: CGFloat, base: Int) -> Int {
        guard base >= 0, base < widths.count else { return 0 }
        var count = 0
        var used: CGFloat = 0
        for width in widths[base...] {
            let added = (count == 0 ? 0 : separator) + width
            guard used + added <= available else { break }
            used += added
            count += 1
        }
        return max(count, 1)
    }

    /// The independently fitted candidate range for one matrix row. Keeping
    /// this pure lets `matrix-smoke` pin row isolation without a window server.
    static func fittedColumnRange(widths: [CGFloat], separator: CGFloat,
                                  available: CGFloat, base: Int) -> Range<Int> {
        guard !widths.isEmpty else { return 0..<0 }
        let resolvedBase = min(max(0, base), widths.count - 1)
        let count = fittedColumnCount(widths: widths,
                                      separator: separator,
                                      available: available,
                                      base: resolvedBase)
        return resolvedBase..<min(resolvedBase + count, widths.count)
    }

    /// Slide the column viewport so `selection` stays visible. Pure for the
    /// smoke: the result always yields a window containing `selection`.
    static func columnBase(selection: Int, currentBase: Int, widths: [CGFloat],
                           separator: CGFloat, available: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        var base = min(max(0, currentBase), widths.count - 1)
        let target = min(max(0, selection), widths.count - 1)
        if target < base { return target }
        while target >= base + fittedColumnCount(widths: widths, separator: separator,
                                                 available: available, base: base),
              base < widths.count - 1 {
            base += 1
        }
        return base
    }

    /// Candidate indices rendered in the active row. Number keys and horizontal
    /// navigation belong to that row; inactive rows keep independent widths and
    /// viewport bases.
    private func expandedColumnRange() -> Range<Int> {
        guard expandedPages.indices.contains(expandedSelectionPageOffset) else {
            return 0..<0
        }
        let widths = expandedRowNaturalWidths(
            page: expandedPages[expandedSelectionPageOffset]
        )
        return Self.fittedColumnRange(
            widths: widths,
            separator: separatorRunWidth(),
            available: candidateAvailableWidth(panelWidth: activePanelWidth()),
            base: expandedColumnBases[expandedSelectionPageOffset] ?? 0
        )
    }

    /// Selection is bounded by the page's real candidate count, not by what
    /// currently fits — the column viewport scrolls to reveal the rest.
    private func expandedCandidateCount(pageOffset: Int) -> Int {
        guard expandedPages.indices.contains(pageOffset) else { return 0 }
        return expandedPages[pageOffset].candidates.count
    }

    private func scrollExpandedColumnsToSelection() {
        guard expandedPages.indices.contains(expandedSelectionPageOffset) else {
            return
        }
        let widths = expandedRowNaturalWidths(
            page: expandedPages[expandedSelectionPageOffset]
        )
        guard !widths.isEmpty else { return }
        expandedColumnBases[expandedSelectionPageOffset] = Self.columnBase(
            selection: selectedIndex,
            currentBase: expandedColumnBases[expandedSelectionPageOffset] ?? 0,
            widths: widths,
            separator: separatorRunWidth(),
            available: candidateAvailableWidth(panelWidth: activePanelWidth())
        )
    }

    private func clampExpandedSelectionToVisiblePrefix() {
        guard expandedPages.indices.contains(expandedSelectionPageOffset) else { return }
        selectedIndex = clamp(
            selectedIndex,
            count: expandedCandidateCount(pageOffset: expandedSelectionPageOffset)
        )
        scrollExpandedColumnsToSelection()
    }

    private func logExpandedVisiblePrefix(reason: String) {
        guard expandedPages.indices.contains(expandedSelectionPageOffset) else { return }
        let total = expandedCandidateCount(pageOffset: expandedSelectionPageOffset)
        let range = expandedColumnRange()
        guard range.count < total else { return }
        IMELog.write("candidate matrix \(reason) row=\(expandedSelectionPageOffset) cols=\(range.lowerBound)..<\(range.upperBound)/\(total)")
    }

    private func renderSingleCharacterSelectionRow() {
        candidateStack.orientation = .horizontal
        candidateStack.alignment = .centerY
        candidateStack.spacing = Self.candidateSpacing

        let chars = Array(characterSelectionText)
        guard !chars.isEmpty else { return }

        let indexedCharacters = Array(chars.enumerated())
        let displayedCharacters = indexedCharacters
        for (offset, element) in displayedCharacters.enumerated() {
            let (index, char) = element
            if offset > 0 {
                candidateStack.addArrangedSubview(candidateSeparatorView())
            }
            candidateStack.addArrangedSubview(candidateButton(
                pageOffset: 0,
                index: index,
                candidate: RimeCandidateModel(text: String(char), comment: "", label: ""),
                highlighted: index == characterSelectionIndex,
                compact: true,
                width: nil,
                tag: Self.characterSelectionTagBase + index
            ))
        }
    }

    private func candidateButton(
        pageOffset: Int,
        index: Int,
        candidate: RimeCandidateModel,
        highlighted: Bool,
        compact: Bool,
        width: CGFloat?,
        maxWidth: CGFloat? = nil,
        showsLabel: Bool = true,
        tag: Int? = nil
    ) -> NSButton {
        let button = CandidatePillButton()
        button.tag = tag ?? candidateTag(pageOffset: pageOffset, index: index)
        button.target = self
        button.action = #selector(candidateTapped(_:))
        button.setCandidateTitle(
            candidateTitle(candidate,
                           highlighted: highlighted,
                           showsLabel: showsLabel),
            accessibilityLabel: showsLabel && !candidate.label.isEmpty
                ? "\(candidate.label) \(candidate.text)"
                : candidate.text
        )
        if !candidate.comment.isEmpty {
            button.setAccessibilityHelp(candidate.comment)
        }
        button.applyAppearance(highlighted: highlighted)
        button.toolTip = candidate.comment.isEmpty
            ? candidate.text
            : "\(candidate.text)  \(candidate.comment)"

        let naturalWidth = ceil(measuredCandidateWidth(candidate,
                                                       highlighted: highlighted,
                                                       compact: compact,
                                                       showsLabel: showsLabel))
        let cappedWidth = maxWidth.map { min(naturalWidth, $0) } ?? naturalWidth
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width ?? cappedWidth),
            button.heightAnchor.constraint(equalToConstant: compact
                ? compactCandidateButtonHeight(for: CandidateWindowMetrics.current)
                : 32),
        ])
        return button
    }

    private func candidateTitle(
        _ c: RimeCandidateModel,
        highlighted: Bool,
        showsLabel: Bool = true
    ) -> NSAttributedString {
        let metrics = CandidateWindowMetrics.current
        let line = NSMutableAttributedString()
        let labelColor = highlighted
            ? RimeUI.selectedCandidateTextColor
            : RimeUI.textSecondary
        let textColor = highlighted
            ? RimeUI.selectedCandidateTextColor
            : RimeUI.textPrimary
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: metrics.labelFontSize,
                                                         weight: .semibold)
        let candidateFont = NSFont.systemFont(ofSize: metrics.candidateFontSize,
                                              weight: highlighted ? .semibold : .regular)
        let annotationFont = NSFont.systemFont(ofSize: CandidateLayout.annotationFontSize,
                                               weight: .regular)
        let baseline = CandidateLayout.centeredLabelBaselineOffset(
            labelFont: labelFont,
            candidateFont: candidateFont
        )
        let annotationBaseline = CandidateLayout.centeredLabelBaselineOffset(
            labelFont: annotationFont,
            candidateFont: candidateFont
        )

        if showsLabel, !c.label.isEmpty {
            line.append(NSAttributedString(
                string: "\(c.label) ",
                attributes: [.font: labelFont,
                             .foregroundColor: labelColor,
                             .baselineOffset: baseline]))
        }
        line.append(NSAttributedString(
            string: c.text,
            attributes: [.font: candidateFont,
                         .foregroundColor: textColor]))
        if !c.comment.isEmpty {
            line.append(NSAttributedString(
                string: " \(c.comment)",
                attributes: [
                    .font: annotationFont,
                    .foregroundColor: highlighted
                        ? RimeUI.selectedCandidateTextColor
                        : RimeUI.textMuted,
                    .baselineOffset: annotationBaseline,
                ]
            ))
        }
        return line
    }

    private func bufferActionButton(width: CGFloat) -> NSButton {
        let button = BufferActionPillButton()
        button.tag = bufferActionTag
        button.target = self
        button.action = #selector(candidateTapped(_:))
        button.toolTip = "开启缓冲区"
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: Self.actionButtonSize),
        ])
        return button
    }

    private func candidateSeparatorView() -> NSView {
        let label = NSTextField(labelWithString: "|")
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = RimeUI.borderStrong
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.candidateSeparatorWidth).isActive = true
        return label
    }

    private func measuredCandidateWidth(
        _ c: RimeCandidateModel,
        highlighted: Bool,
        compact: Bool,
        showsLabel: Bool = true
    ) -> CGFloat {
        candidateTitle(c, highlighted: highlighted, showsLabel: showsLabel).size().width
            + (compact ? Self.compactCandidateHorizontalPadding : 14)
    }

    private func activePanelWidth() -> CGFloat {
        panelWidth(caretRect: lastCaretRect)
    }

    private func candidateAvailableWidth(panelWidth: CGFloat) -> CGFloat {
        let sideControlsWidth: CGFloat = 1 + Self.actionButtonSize + Self.barSpacing * 2
        return max(80, panelWidth - Self.barHorizontalPadding * 2 - sideControlsWidth)
    }

    private func bufferActionWidth() -> CGFloat {
        CandidateLayout.bufferActionMinWidth
    }

    private func candidateMaxWidth(panelWidth: CGFloat) -> CGFloat {
        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = showsBufferAction
            ? min(bufferActionWidth(), available) + Self.candidateSpacing
            : 0
        let remaining = available - bufferSpace
        return max(64, remaining)
    }

    private func candidatePages(panelWidth: CGFloat) -> [[Int]] {
        guard !currentContext.candidates.isEmpty else { return [] }

        let available = candidateAvailableWidth(panelWidth: panelWidth)
        let bufferSpace = showsBufferAction
            ? min(bufferActionWidth(), available) + Self.candidateSpacing
            : 0
        let remaining = available - bufferSpace
        let pageWidth = max(64, remaining)
        let maxItemWidth = max(64, pageWidth)

        var pages: [[Int]] = []
        var page: [Int] = []
        var usedWidth: CGFloat = 0

        for i in currentContext.candidates.indices {
            let natural = ceil(measuredCandidateWidth(currentContext.candidates[i],
                                                      highlighted: false,
                                                      compact: true))
            let width = min(natural, maxItemWidth)
            let nextWidth = page.isEmpty ? width : usedWidth + separatorRunWidth() + width
            if !page.isEmpty, nextWidth > pageWidth {
                pages.append(page)
                page = [i]
                usedWidth = width
            } else {
                page.append(i)
                usedWidth = nextWidth
            }
        }

        if !page.isEmpty { pages.append(page) }
        return pages
    }

    private func separatorRunWidth() -> CGFloat {
        CandidateLayout.candidateSeparatorRunWidth
    }

    private func currentVisualCandidateIndices(panelWidth: CGFloat) -> [Int] {
        let pages = candidatePages(panelWidth: panelWidth)
        guard !pages.isEmpty else { return [] }
        return pages[clampVisualPage(visualPageIndex, pageCount: pages.count)]
    }

    private func pageIndex(containing candidateIndex: Int, panelWidth: CGFloat) -> Int {
        let pages = candidatePages(panelWidth: panelWidth)
        guard !pages.isEmpty else { return 0 }
        return pages.firstIndex { $0.contains(candidateIndex) } ?? 0
    }

    private func clampVisualPage(_ index: Int, panelWidth: CGFloat) -> Int {
        clampVisualPage(index, pageCount: candidatePages(panelWidth: panelWidth).count)
    }

    private func clampVisualPage(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(index, 0), pageCount - 1)
    }

    private func updateCandidateDocumentSize() {
        let metrics = CandidateWindowMetrics.current
        let fit = candidateStack.fittingSize
        let height = candidateAreaHeight(for: metrics)
        candidateStack.setFrameSize(NSSize(width: max(fit.width, candidateScroll.contentSize.width),
                                           height: height))
    }

    private func resetCandidateScroll() {
        candidateScroll.layoutSubtreeIfNeeded()
        candidateStack.layoutSubtreeIfNeeded()
        let origin = NSPoint(x: 0, y: 0)
        candidateScroll.contentView.scroll(to: origin)
        candidateScroll.reflectScrolledClipView(candidateScroll.contentView)
    }

    private func candidateLeadingSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func applyAppearance() {
        panel.appearance = RimeUI.appKitAppearance
        content.layer?.backgroundColor = NSColor.clear.cgColor
        preeditLabel.textColor = RimeUI.textPrimary
        preeditPill.layer?.backgroundColor = RimeUI.candidateBackgroundColor
            .withAlphaComponent(0.95).cgColor
        preeditPill.layer?.borderColor = RimeUI.borderStrong
            .withAlphaComponent(0.72).cgColor
        strip.layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        strip.layer?.borderColor = RimeUI.borderStrong.cgColor
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        settingsButton.applyAppearance()
    }

    private func applyMetrics() {
        let metrics = CandidateWindowMetrics.current
        preeditLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preeditHeightConstraint.constant = metrics.preeditHeight
        updatePreeditWidth()
        stripHeightConstraint.constant = effectiveStripHeight(for: metrics)
        candidateHeightConstraint.constant = candidateAreaHeight(for: metrics)
        dividerHeightConstraint.constant = dividerHeight(for: metrics)
        let padding = barVerticalPadding(for: metrics)
        barTopConstraint.constant = padding
        barBottomConstraint.constant = -padding
    }

    private func updatePreeditWidth() {
        let panelWidth = max(1, activePanelWidth())
        let naturalWidth = ceil(preeditLabel.intrinsicContentSize.width)
            + CandidateLayout.preeditHorizontalPadding * 2
        preeditWidthConstraint.constant = min(
            panelWidth,
            max(CandidateLayout.preeditHorizontalPadding * 2, naturalWidth)
        )
    }

    private func dividerHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        // Expanded matrices grow the strip beyond the compact height; keep the
        // divider bounded to whichever is taller.
        min(effectiveStripHeight(for: metrics) - 8, max(20, metrics.compactStripHeight - 10))
    }

    private func barVerticalPadding(for metrics: CandidateWindowMetrics) -> CGFloat {
        CandidateLayout.barVerticalPadding(metrics)
    }

    private func compactCandidateButtonHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        CandidateLayout.candidateButtonHeight(metrics)
    }

    private func candidateAreaHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        let rowHeight = compactCandidateButtonHeight(for: metrics)
        guard isExpanded, !isSingleCharacterSelectionActive else {
            return showsBufferAction ? max(rowHeight, Self.actionButtonSize) : rowHeight
        }
        return Self.matrixViewportHeight(rowHeight: rowHeight,
                                         rowCount: expandedPages.count)
    }

    private func effectiveStripHeight(for metrics: CandidateWindowMetrics) -> CGFloat {
        max(metrics.compactStripHeight, candidateAreaHeight(for: metrics) + 2 * barVerticalPadding(for: metrics))
    }

    private var showsBufferAction: Bool {
        presentationMode == .caret && !BufferModel.shared.active
    }

    /// AppKit-backed seam for `buffer-window-smoke`. Unlike the pure viewport
    /// math above, this exercises the real NSPanel/NSScrollView/NSStackView
    /// hierarchy and catches a reintroduced autoresizing-mask conflict.
    static func matrixLayoutSnapshotForSmoke(rowCount: Int) -> CandidateMatrixLayoutSnapshot {
        let candidateWindow = CandidateWindow()
        let initialPanelLevel = candidateWindow.panel.level.rawValue
        candidateWindow.panel.level = CandidatePanelLevelRules.level(
            bundleID: FocusHostRules.iShotBundleID,
            hostKind: .nonactivatingSystemOverlay
        )
        let iShotPanelLevel = candidateWindow.panel.level.rawValue
        candidateWindow.hidePanel(
            reason: "smoke-panel-level-reset",
            clearsPresentation: false
        )
        let hiddenPanelLevel = candidateWindow.panel.level.rawValue
        let pages = (0..<rowCount).map { pageIndex -> RimeContextModel in
            var page = RimeContextModel()
            page.pageNo = pageIndex
            page.pageSize = 1
            page.isLastPage = pageIndex == rowCount - 1
            page.candidates = [
                RimeCandidateModel(text: "候选\(pageIndex + 1)",
                                   comment: "",
                                   label: "1"),
            ]
            return page
        }
        candidateWindow.expandedPages = pages
        candidateWindow.expandedSelectionPageOffset = 0
        candidateWindow.expandedWindowBase = 0
        candidateWindow.renderCandidates()
        candidateWindow.panel.layoutIfNeeded()
        candidateWindow.candidateScroll.layoutSubtreeIfNeeded()
        candidateWindow.candidateStack.layoutSubtreeIfNeeded()

        let metrics = CandidateWindowMetrics.current
        let expectedRowHeight = candidateWindow.compactCandidateButtonHeight(for: metrics)
        let expectedDocumentHeight = matrixViewportHeight(rowHeight: expectedRowHeight,
                                                          rowCount: rowCount)
        let expectedPanelHeight = candidateWindow.desiredPanelContentSize(
            caretRect: candidateWindow.lastCaretRect,
            metrics: metrics
        ).height
        let document = candidateWindow.candidateStack
        let constraints = document.constraints
            + candidateWindow.candidateScroll.contentView.constraints
            + candidateWindow.candidateScroll.constraints
        let autoresizingMaskConstraintCount = constraints.filter { constraint in
            guard constraint.isActive,
                  String(describing: type(of: constraint)).contains("AutoresizingMask") else {
                return false
            }
            return (constraint.firstItem as? NSView) === document
                || (constraint.secondItem as? NSView) === document
        }.count

        return CandidateMatrixLayoutSnapshot(
            initialPanelLevel: initialPanelLevel,
            iShotPanelLevel: iShotPanelLevel,
            hiddenPanelLevel: hiddenPanelLevel,
            panelCollectionBehavior: candidateWindow.panel.collectionBehavior,
            rowCount: document.arrangedSubviews.count,
            rowHeights: document.arrangedSubviews.map(\.frame.height),
            expectedRowHeight: expectedRowHeight,
            documentHeight: document.frame.height,
            expectedDocumentHeight: expectedDocumentHeight,
            scrollHeight: candidateWindow.candidateScroll.frame.height,
            panelHeight: candidateWindow.panel.contentView?.bounds.height ?? 0,
            expectedPanelHeight: expectedPanelHeight,
            documentTranslatesAutoresizingMaskIntoConstraints:
                document.translatesAutoresizingMaskIntoConstraints,
            documentAutoresizingMaskConstraintCount: autoresizingMaskConstraintCount
        )
    }

    static func bufferCaretSnapshotForSmoke() -> CandidateBufferCaretSnapshot {
        let candidateWindow = CandidateWindow()
        candidateWindow.presentationMode = .bufferCaret
        var context = RimeContextModel()
        context.input = "smoke"
        context.preedit = "smoke"
        context.candidates = [
            RimeCandidateModel(text: "候选", comment: "", label: "1"),
            RimeCandidateModel(text: "测试", comment: "", label: "2"),
        ]
        candidateWindow.currentContext = context
        candidateWindow.projectionPreedit = ""
        candidateWindow.preeditLabel.stringValue = ""
        candidateWindow.preeditPill.isHidden = true
        candidateWindow.strip.isHidden = false
        candidateWindow.renderCandidates()
        candidateWindow.panel.layoutIfNeeded()
        let contentStayedInPanel = candidateWindow.content.superview
            === candidateWindow.panelHost
        let renderedCandidateViews = candidateWindow.candidateStack.arrangedSubviews.count
        let metrics = CandidateWindowMetrics.current
        let stripOnlyHeight = candidateWindow.desiredPanelContentSize(
            caretRect: .zero,
            metrics: metrics
        ).height
        let bufferActionHidden = !candidateWindow.showsBufferAction
        candidateWindow.lastGoodCaretRect = NSRect(
            x: 200,
            y: 200,
            width: 0,
            height: 20
        )
        let rejectedCachedHostAnchor = candidateWindow.origin(
            for: .zero,
            bundleId: "smoke"
        ) == nil
        candidateWindow.resetPresentationState()
        let scrubbedCandidateViews = candidateWindow.candidateStack.arrangedSubviews.isEmpty
        let scrubbedPreedit = candidateWindow.preeditLabel.stringValue.isEmpty
        return CandidateBufferCaretSnapshot(
            contentStayedInPanel: contentStayedInPanel,
            renderedCandidateViews: renderedCandidateViews,
            preeditHidden: candidateWindow.preeditPill.isHidden,
            stripOnlyHeight: stripOnlyHeight,
            expectedStripOnlyHeight: metrics.compactStripHeight,
            bufferActionHidden: bufferActionHidden,
            rejectedCachedHostAnchor: rejectedCachedHostAnchor,
            scrubbedCandidateViews: scrubbedCandidateViews,
            scrubbedPreedit: scrubbedPreedit
        )
    }

    /// AppKit-backed typography seam for `candidate-metrics-smoke`. It renders
    /// the real button hierarchy and verifies that the dedicated CoreText view
    /// is centred while the native NSButtonCell title path stays empty.
    static func textRendererSnapshotForSmoke(
        buttonHeight: CGFloat,
        candidateFontSize: CGFloat,
        labelFontSize: CGFloat,
        candidateText: String = "现在的",
        label: String = "1",
        usesTightWidth: Bool = false,
        highlighted: Bool = false
    ) -> CandidateTextRendererSnapshot {
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize,
                                                         weight: .semibold)
        let candidateFont = NSFont.systemFont(ofSize: candidateFontSize,
                                              weight: highlighted ? .semibold : .regular)
        let baseline = CandidateLayout.centeredLabelBaselineOffset(
            labelFont: labelFont,
            candidateFont: candidateFont
        )
        let title = NSMutableAttributedString()
        if !label.isEmpty {
            title.append(NSAttributedString(string: "\(label) ", attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.systemRed,
                .baselineOffset: baseline,
            ]))
        }
        title.append(NSAttributedString(string: candidateText, attributes: [
            .font: candidateFont,
            .foregroundColor: NSColor.systemGreen,
        ]))
        let naturalWidth = ceil(title.size().width)
            + CandidateLayout.compactCandidateHorizontalPadding
        let buttonWidth = usesTightWidth ? naturalWidth : 180
        let button = CandidatePillButton()
        let host = NSView(frame: NSRect(x: 0, y: 0,
                                        width: buttonWidth,
                                        height: buttonHeight))
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            button.topAnchor.constraint(equalTo: host.topAnchor),
            button.widthAnchor.constraint(equalToConstant: buttonWidth),
            button.heightAnchor.constraint(equalToConstant: buttonHeight),
        ])
        button.setCandidateTitle(
            title,
            accessibilityLabel: label.isEmpty
                ? candidateText
                : "\(label) \(candidateText)"
        )
        host.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()

        let titleView = button.subviews.compactMap { $0 as? CandidateTitleLabel }.first
        let titleViewFrame = titleView?.frame ?? .zero
        let requiredLineHeight = candidateFont.ascender
            - candidateFont.descender
            + candidateFont.leading
        let labelCenter = (labelFont.ascender + labelFont.descender) / 2 + baseline
        let candidateCenter = (candidateFont.ascender + candidateFont.descender) / 2
        let ink = Self.candidateInkMetrics(in: button)

        return CandidateTextRendererSnapshot(
            nativeButtonTitleIsEmpty: button.title.isEmpty,
            nativeAttributedTitleIsEmpty: button.attributedTitle.length == 0,
            buttonBounds: button.bounds,
            titleViewFrame: titleViewFrame,
            requiredLineHeight: requiredLineHeight,
            baselineCenterDelta: abs(labelCenter - candidateCenter),
            titleViewHitTestIsNil: titleView?.hitTest(NSPoint(x: 1, y: 1)) == nil,
            candidateGlyphPixelCount: ink.candidateGlyphPixelCount,
            horizontalInkCenterDelta: ink.horizontalCenterDelta,
            verticalInkCenterDelta: ink.verticalCenterDelta
        )
    }

    /// Rasterize the real hierarchy. The smoke title colors its index red and
    /// candidate green, allowing the test to prove both candidate visibility
    /// and the optical centre of the complete title.
    private static func candidateInkMetrics(
        in button: NSButton
    ) -> (
        candidateGlyphPixelCount: Int,
        horizontalCenterDelta: CGFloat,
        verticalCenterDelta: CGFloat
    ) {
        let scale: CGFloat = 2
        let pixelWidth = max(1, Int(ceil(button.bounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(button.bounds.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return (0, .greatestFiniteMagnitude, .greatestFiniteMagnitude) }
        bitmap.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: bitmap)

        var candidateCount = 0
        var minimumX = bitmap.pixelsWide
        var minimumY = bitmap.pixelsHigh
        var maximumX = -1
        var maximumY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                guard color.alphaComponent > 0.05 else { continue }
                let isCandidate = color.greenComponent
                    > color.redComponent + 0.05
                    && color.greenComponent > color.blueComponent + 0.05
                let isLabel = color.redComponent > color.greenComponent + 0.05
                    && color.redComponent > color.blueComponent + 0.05
                guard isCandidate || isLabel else { continue }
                if isCandidate {
                    candidateCount += 1
                }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else {
            return (candidateCount,
                    .greatestFiniteMagnitude,
                    .greatestFiniteMagnitude)
        }
        let inkMidX = CGFloat(minimumX + maximumX + 1) / (2 * scale)
        let inkMidY = CGFloat(minimumY + maximumY + 1) / (2 * scale)
        return (
            candidateCount,
            abs(inkMidX - button.bounds.midX),
            abs(inkMidY - button.bounds.midY)
        )
    }

    private func contextSignature(_ ctx: RimeContextModel) -> String {
        let candidates = ctx.candidates.map { "\($0.label):\($0.text):\($0.comment)" }.joined(separator: "|")
        return "\(ctx.input)#\(ctx.preedit)#\(ctx.pageNo)#\(candidates)"
    }

    private func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private func candidateTag(pageOffset: Int, index: Int) -> Int {
        pageOffset * 1000 + index
    }

    private func candidateSelection(from tag: Int) -> CandidateSelection? {
        guard tag >= 0 else { return nil }
        return CandidateSelection(pageOffset: tag / 1000, index: tag % 1000)
    }

    @objc private func candidateTapped(_ sender: NSButton) {
        guard let ownerToken,
              InputFocusCoordinator.shared.interactionTarget(expected: ownerToken) != nil,
              presentationIsVisible,
              presentationIsOnActiveSpace else {
            hideAll()
            return
        }
        if sender.tag == bufferActionTag {
            performBufferAction()
            return
        }
        guard hasInteractableCandidates else {
            hideAll()
            return
        }
        if isSingleCharacterSelectionActive, sender.tag >= Self.characterSelectionTagBase {
            let chars = Array(characterSelectionText)
            characterSelectionIndex = clamp(sender.tag - Self.characterSelectionTagBase,
                                            count: chars.count)
            renderCandidates()
            return
        }
        guard let selection = candidateSelection(from: sender.tag) else { return }
        if isExpanded {
            guard expandedPages.indices.contains(selection.pageOffset) else { return }
            expandedSelectionPageOffset = selection.pageOffset
            selectedIndex = clamp(selection.index,
                                  count: expandedPages[selection.pageOffset].candidates.count)
        } else {
            selectedIndex = clamp(selection.index, count: currentContext.candidates.count)
            visualPageIndex = pageIndex(containing: selectedIndex, panelWidth: activePanelWidth())
        }
        onSelect?(ownerToken,
                  CandidateSelection(pageOffset: selection.pageOffset, index: selectedIndex))
    }

    @objc private func settingsTapped() {
        onSettings?()
    }
}

/// The button remains the click and accessibility target, while a dedicated
/// CoreText view renders its title. This avoids both NSButtonCell's clipped CJK
/// title rect and NSTextFieldCell's asymmetric single-line drawing offsets.
private class CandidateTextButton: NSButton {
    private let candidateTitleLabel = CandidateTitleLabel()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        alignment = .center
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        // CandidateSurface gives the selected pill a small exterior shadow.
        // Do not mask the host layer; the CoreText title is already clipped to
        // its own bounds and the layer's rounded background remains intact.
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(candidateTitleLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCandidateTitle(_ title: NSAttributedString, accessibilityLabel: String) {
        candidateTitleLabel.setCandidateTitle(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    override func layout() {
        super.layout()
        let inset = CandidateLayout.compactCandidateHorizontalPadding / 2
        candidateTitleLabel.frame = bounds.insetBy(dx: inset, dy: 0)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CandidatePillButton: CandidateTextButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isSelectedCandidate = false

    init() {
        super.init(cornerRadius: CandidateLayout.selectedCandidateCornerRadius)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyAppearance(highlighted: Bool) {
        isSelectedCandidate = highlighted
        updateVisualState()
    }

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
        updateVisualState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisualState()
    }

    private func updateVisualState() {
        guard let layer else { return }
        if isSelectedCandidate {
            layer.backgroundColor = RimeUI.selectedCandidateBackgroundColor.cgColor
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 1
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: -1)
        } else if isHovered {
            layer.backgroundColor = RimeUI.surface3.cgColor
            layer.borderColor = RimeUI.border.cgColor
            layer.borderWidth = 1
            layer.shadowOpacity = 0
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = NSColor.clear.cgColor
            layer.borderWidth = 1
            layer.shadowOpacity = 0
        }
    }
}

private final class BufferActionPillButton: NSButton {
    private let countLabel = NSTextField(labelWithString: "0")
    private let trayIcon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = CandidateLayout.selectedCandidateCornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: CandidateLayout.annotationFontSize,
            weight: .regular
        )
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        trayIcon.image = RimeUI.symbol("tray", pointSize: 13, weight: .bold)
        trayIcon.image?.isTemplate = true
        trayIcon.imageScaling = .scaleProportionallyDown
        trayIcon.translatesAutoresizingMaskIntoConstraints = false

        let contents = NSStackView(views: [countLabel, trayIcon])
        contents.orientation = .horizontal
        contents.alignment = .centerY
        contents.spacing = 4
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        NSLayoutConstraint.activate([
            contents.centerXAnchor.constraint(equalTo: centerXAnchor),
            contents.centerYAnchor.constraint(equalTo: centerYAnchor),
            trayIcon.widthAnchor.constraint(equalToConstant: 13),
            trayIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("开启缓冲区")
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The count label and template icon are visual-only; keep the whole
        // 38×28 control as the button's first-click target.
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func applyAppearance() {
        countLabel.textColor = isHovered ? RimeUI.accentTextColor : RimeUI.textSecondary
        trayIcon.contentTintColor = isHovered ? RimeUI.accentTextColor : RimeUI.textSecondary
        layer?.backgroundColor = RimeUI.surface2.cgColor
        layer?.borderWidth = 1
        let hoverBorder = RimeUI.border.blended(
            withFraction: 0.48,
            of: RimeUI.accentTextColor
        ) ?? RimeUI.accentTextColor
        layer?.borderColor = (isHovered ? hoverBorder : RimeUI.border).cgColor
    }
}

private final class CandidateTitleLabel: NSView {
    private var candidateTitle = NSAttributedString()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCandidateTitle(_ title: NSAttributedString) {
        candidateTitle = NSAttributedString(attributedString: title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard candidateTitle.length > 0,
              bounds.width > 0,
              bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let sourceLine = CTLineCreateWithAttributedString(candidateTitle)
        let sourceWidth = CGFloat(CTLineGetTypographicBounds(
            sourceLine, nil, nil, nil
        ))
        let renderedLine: CTLine
        if sourceWidth > bounds.width {
            let attributes = candidateTitle.attributes(
                at: candidateTitle.length - 1,
                effectiveRange: nil
            )
            let token = CTLineCreateWithAttributedString(
                NSAttributedString(string: "…", attributes: attributes)
            )
            renderedLine = CTLineCreateTruncatedLine(
                sourceLine,
                Double(bounds.width),
                .end,
                token
            ) ?? sourceLine
        } else {
            renderedLine = sourceLine
        }

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(
            renderedLine,
            &ascent,
            &descent,
            &leading
        ))
        let origin = CGPoint(
            x: (bounds.width - width) / 2,
            y: (bounds.height - (ascent + descent)) / 2 + descent
        )
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(renderedLine, context)
        context.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CandidateActionButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    init(symbolName: String, title: String) {
        super.init(frame: .zero)
        self.title = title
        image = RimeUI.symbol(symbolName, pointSize: title.isEmpty ? 15 : 14, weight: .semibold)
        image?.isTemplate = true
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageScaling = .scaleProportionallyDown
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        font = .systemFont(ofSize: 14, weight: .semibold)
        contentTintColor = RimeUI.textSecondary
        wantsLayer = true
        layer?.cornerRadius = CandidateLayout.selectedCandidateCornerRadius
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyAppearance() {
        contentTintColor = isHovered ? RimeUI.textPrimary : RimeUI.textSecondary
        layer?.backgroundColor = (isHovered ? RimeUI.surface3 : NSColor.clear).cgColor
    }

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Settings live preview

/// A non-interactive mock of the candidate window for the settings page. It
/// renders a sample composition using the SAME geometry (`CandidateLayout`) and
/// theme (`RimeUI`) as the real window, so dragging a size control shows the
/// exact effect before "应用修改" ever touches the live window. Rebuilds whenever
/// `metrics` changes; call `reload()` after a theme switch.
final class CandidatePreviewView: NSView {
    /// Metrics to render — set live from the (unsaved) settings controls.
    var metrics: CandidateWindowMetrics = .current {
        didSet { rebuild() }
    }

    private let canvasPadding: CGFloat = 18
    private let statusHeight: CGFloat = 16
    private let statusSpacing: CGFloat = 4
    private let maxWidth: CGFloat
    private let backdrop = NSView()
    private let previewScroll = NSScrollView()
    private let previewDocument = NSView()
    private let widthStatusLabel = NSTextField(labelWithString: "")
    private let windowMock = NSView()
    private let preeditPill = NSView()
    private let preeditLabel = NSTextField(labelWithString: "")
    private let strip = NSView()
    private let candidateRow = NSStackView()
    private let divider = NSView()
    private let gear = NSButton()
    private var heightConstraint: NSLayoutConstraint!

    private var preeditHeightConstraint: NSLayoutConstraint!
    private var stripTopConstraint: NSLayoutConstraint!
    private var stripHeightConstraint: NSLayoutConstraint!
    private var windowWidthConstraint: NSLayoutConstraint!
    private var candidateRowHeightConstraint: NSLayoutConstraint!
    private var dividerHeightConstraint: NSLayoutConstraint!

    private let sampleCandidates: [(label: String, text: String)] = [
        ("1", "你好"), ("2", "拟好"), ("3", "你"), ("4", "尼"),
        ("5", "泥"), ("6", "逆"), ("7", "拟"), ("8", "腻"), ("9", "妮"),
    ]
    private let samplePreedit = "ni hao"

    init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        previewScroll.drawsBackground = false
        previewScroll.borderType = .noBorder
        previewScroll.hasVerticalScroller = false
        previewScroll.horizontalScrollElasticity = .none
        previewScroll.verticalScrollElasticity = .none
        previewScroll.scrollerStyle = .overlay
        previewScroll.autohidesScrollers = false
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.documentView = previewDocument
        backdrop.addSubview(previewScroll)

        widthStatusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        widthStatusLabel.textColor = .tertiaryLabelColor
        widthStatusLabel.alignment = .right
        widthStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(widthStatusLabel)

        windowMock.wantsLayer = true
        windowMock.translatesAutoresizingMaskIntoConstraints = false
        previewDocument.addSubview(windowMock)

        preeditPill.wantsLayer = true
        preeditPill.layer?.cornerRadius = CandidateLayout.preeditCornerRadius
        preeditPill.layer?.borderWidth = 1
        preeditPill.layer?.masksToBounds = true
        preeditPill.translatesAutoresizingMaskIntoConstraints = false

        preeditLabel.lineBreakMode = .byTruncatingTail
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        preeditPill.addSubview(preeditLabel)

        strip.wantsLayer = true
        strip.layer?.cornerRadius = CandidateLayout.stripCornerRadius
        strip.layer?.borderWidth = 1
        strip.layer?.masksToBounds = true
        strip.translatesAutoresizingMaskIntoConstraints = false

        candidateRow.orientation = .horizontal
        candidateRow.alignment = .centerY
        candidateRow.spacing = CandidateLayout.candidateSpacing
        candidateRow.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.setContentHuggingPriority(.required, for: .horizontal)

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        gear.isBordered = false
        gear.image = RimeUI.symbol("gearshape", pointSize: 15, weight: .semibold)
        gear.image?.isTemplate = true
        gear.imagePosition = .imageOnly
        gear.isEnabled = false
        gear.wantsLayer = true
        gear.layer?.cornerRadius = CandidateLayout.selectedCandidateCornerRadius
        gear.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSStackView(views: [candidateRow, divider, gear])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = CandidateLayout.barSpacing
        bar.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(bar)

        windowMock.addSubview(preeditPill)
        windowMock.addSubview(strip)

        heightConstraint = heightAnchor.constraint(equalToConstant: 120)
        preeditHeightConstraint = preeditPill.heightAnchor.constraint(equalToConstant: metrics.preeditHeight)
        stripTopConstraint = strip.topAnchor.constraint(equalTo: preeditPill.bottomAnchor, constant: CandidateLayout.rootSpacing)
        stripHeightConstraint = strip.heightAnchor.constraint(equalToConstant: CandidateLayout.compactStripHeight(metrics))
        windowWidthConstraint = windowMock.widthAnchor.constraint(equalToConstant: metrics.baseWidth)
        candidateRowHeightConstraint = candidateRow.heightAnchor.constraint(
            equalToConstant: max(
                CandidateLayout.candidateButtonHeight(metrics),
                CandidateLayout.actionButtonSize
            )
        )
        dividerHeightConstraint = divider.heightAnchor.constraint(equalToConstant: CandidateLayout.dividerHeight(metrics))

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: maxWidth),
            heightConstraint,

            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            previewScroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            previewScroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            previewScroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            previewScroll.bottomAnchor.constraint(equalTo: widthStatusLabel.topAnchor,
                                                  constant: -statusSpacing),

            widthStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor,
                                                       constant: 8),
            widthStatusLabel.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -8),
            widthStatusLabel.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -4),
            widthStatusLabel.heightAnchor.constraint(equalToConstant: statusHeight),

            windowMock.leadingAnchor.constraint(equalTo: previewDocument.leadingAnchor,
                                                constant: canvasPadding),
            windowMock.topAnchor.constraint(equalTo: previewDocument.topAnchor,
                                            constant: canvasPadding),

            preeditPill.leadingAnchor.constraint(equalTo: windowMock.leadingAnchor),
            preeditPill.topAnchor.constraint(equalTo: windowMock.topAnchor),
            preeditPill.trailingAnchor.constraint(lessThanOrEqualTo: windowMock.trailingAnchor),
            preeditLabel.leadingAnchor.constraint(
                equalTo: preeditPill.leadingAnchor,
                constant: CandidateLayout.preeditHorizontalPadding
            ),
            preeditLabel.trailingAnchor.constraint(
                equalTo: preeditPill.trailingAnchor,
                constant: -CandidateLayout.preeditHorizontalPadding
            ),
            preeditLabel.centerYAnchor.constraint(equalTo: preeditPill.centerYAnchor),

            strip.leadingAnchor.constraint(equalTo: windowMock.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: windowMock.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: windowMock.bottomAnchor),

            bar.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: CandidateLayout.barHorizontalPadding),
            bar.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -CandidateLayout.barHorizontalPadding),
            bar.centerYAnchor.constraint(equalTo: strip.centerYAnchor),

            divider.widthAnchor.constraint(equalToConstant: 1),
            gear.widthAnchor.constraint(equalToConstant: CandidateLayout.actionButtonSize),
            gear.heightAnchor.constraint(equalToConstant: CandidateLayout.actionButtonSize),

            preeditHeightConstraint, stripTopConstraint, stripHeightConstraint,
            windowWidthConstraint, candidateRowHeightConstraint, dividerHeightConstraint,
        ])

        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Re-apply theme + geometry (call after a night/day switch).
    func reload() { rebuild() }

    private func rebuild() {
        let m = metrics

        // Theme.
        appearance = RimeUI.appKitAppearance
        backdrop.layer?.backgroundColor = RimeUI.surface3.cgColor
        windowMock.layer?.backgroundColor = NSColor.clear.cgColor
        preeditPill.layer?.backgroundColor = RimeUI.candidateBackgroundColor
            .withAlphaComponent(0.95).cgColor
        preeditPill.layer?.borderColor = RimeUI.borderStrong
            .withAlphaComponent(0.72).cgColor
        strip.layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        strip.layer?.borderColor = RimeUI.borderStrong.cgColor
        divider.layer?.backgroundColor = RimeUI.borderStrong.cgColor
        gear.contentTintColor = RimeUI.textSecondary

        // Preedit.
        preeditLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preeditLabel.textColor = RimeUI.textPrimary
        preeditLabel.stringValue = samplePreedit

        // Geometry (identical to the live window).
        let stripHeight = CandidateLayout.compactStripHeight(m)
        let buttonHeight = CandidateLayout.candidateButtonHeight(m)
        let windowWidth = m.baseWidth
        let previewWindowHeight = m.preeditHeight + CandidateLayout.rootSpacing + stripHeight
        let scrollHeight = canvasPadding * 2 + previewWindowHeight
        let documentWidth = max(maxWidth, windowWidth + 2 * canvasPadding)
        let overflows = documentWidth > maxWidth + 0.5
        let previousScrollX = previewScroll.contentView.bounds.minX

        preeditHeightConstraint.constant = m.preeditHeight
        stripHeightConstraint.constant = stripHeight
        candidateRowHeightConstraint.constant = max(buttonHeight, CandidateLayout.actionButtonSize)
        dividerHeightConstraint.constant = CandidateLayout.dividerHeight(m)
        windowWidthConstraint.constant = windowWidth
        previewDocument.frame = NSRect(x: 0, y: 0, width: documentWidth, height: scrollHeight)
        previewScroll.hasHorizontalScroller = overflows
        widthStatusLabel.stringValue = overflows
            ? "实际宽度 \(Int(windowWidth.rounded())) px · 左右滚动查看"
            : "实际宽度 \(Int(windowWidth.rounded())) px"

        // Fill candidates until the strip is full (mirrors real paging).
        candidateRow.arrangedSubviews.forEach {
            candidateRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let gearArea = CandidateLayout.actionButtonSize + CandidateLayout.barSpacing * 2 + 1
        let available = windowWidth - 2 * CandidateLayout.barHorizontalPadding - gearArea
        let bufferWidth = CandidateLayout.bufferActionMinWidth
        let candidateAvailable = max(64,
                                     available - bufferWidth
                                         - CandidateLayout.candidateSpacing)
        var used: CGFloat = 0
        for (i, item) in sampleCandidates.enumerated() {
            let attr = candidateAttr(label: item.label, text: item.text, highlighted: i == 0, m: m)
            let w = ceil(attr.size().width) + CandidateLayout.compactCandidateHorizontalPadding
            let hasCandidate = used > 0
            let separatorRun = CandidateLayout.candidateSeparatorRunWidth
            let next = hasCandidate ? used + separatorRun + w : w
            if hasCandidate, next > candidateAvailable { break }
            if hasCandidate {
                candidateRow.addArrangedSubview(candidateSeparator())
            }
            used = next
            candidateRow.addArrangedSubview(candidatePill(attr,
                                                          highlighted: i == 0,
                                                          width: w,
                                                          height: buttonHeight))
        }
        candidateRow.addArrangedSubview(bufferActionPill(
            width: min(bufferWidth, available),
            height: CandidateLayout.actionButtonSize
        ))

        heightConstraint.constant = scrollHeight + statusSpacing + statusHeight + 4
        let maxScrollX = max(0, documentWidth - maxWidth)
        previewScroll.contentView.scroll(to: NSPoint(x: min(max(0, previousScrollX), maxScrollX),
                                                     y: previewScroll.contentView.bounds.minY))
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
        needsLayout = true
    }

    private func candidatePill(
        _ title: NSAttributedString,
        highlighted: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = CandidateLayout.selectedCandidateCornerRadius
        pill.layer?.backgroundColor = highlighted
            ? RimeUI.selectedCandidateBackgroundColor.cgColor
            : NSColor.clear.cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.clear.cgColor
        if highlighted {
            pill.layer?.shadowColor = NSColor.black.cgColor
            pill.layer?.shadowOpacity = 0.18
            pill.layer?.shadowRadius = 2
            pill.layer?.shadowOffset = CGSize(width: 0, height: -1)
        }
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithAttributedString: title)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: width),
            pill.heightAnchor.constraint(equalToConstant: height),
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        return pill
    }

    private func bufferActionPill(width: CGFloat, height: CGFloat) -> NSView {
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = CandidateLayout.selectedCandidateCornerRadius
        pill.layer?.backgroundColor = RimeUI.surface2.cgColor
        pill.layer?.borderColor = RimeUI.border.cgColor
        pill.layer?.borderWidth = 1
        pill.translatesAutoresizingMaskIntoConstraints = false

        let count = NSTextField(labelWithString: "0")
        count.font = .monospacedDigitSystemFont(
            ofSize: CandidateLayout.annotationFontSize,
            weight: .regular
        )
        count.textColor = RimeUI.textSecondary
        let icon = NSImageView()
        icon.image = RimeUI.symbol("tray", pointSize: 13, weight: .bold)
        icon.image?.isTemplate = true
        icon.contentTintColor = RimeUI.textSecondary
        let contents = NSStackView(views: [count, icon])
        contents.orientation = .horizontal
        contents.alignment = .centerY
        contents.spacing = 4
        contents.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(contents)
        NSLayoutConstraint.activate([
            pill.widthAnchor.constraint(equalToConstant: width),
            pill.heightAnchor.constraint(equalToConstant: height),
            contents.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            contents.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
        ])
        return pill
    }

    private func candidateSeparator() -> NSView {
        let label = NSTextField(labelWithString: "|")
        label.font = .systemFont(ofSize: 10, weight: .regular)
        label.textColor = RimeUI.borderStrong
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: CandidateLayout.candidateSeparatorWidth).isActive = true
        return label
    }

    private func candidateAttr(label: String, text: String, highlighted: Bool, m: CandidateWindowMetrics) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let labelColor = highlighted
            ? RimeUI.selectedCandidateTextColor
            : RimeUI.textSecondary
        let textColor = highlighted
            ? RimeUI.selectedCandidateTextColor
            : RimeUI.textPrimary
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: m.labelFontSize,
                                                         weight: .semibold)
        let candidateFont = NSFont.systemFont(ofSize: m.candidateFontSize,
                                              weight: highlighted ? .semibold : .regular)
        let baseline = CandidateLayout.centeredLabelBaselineOffset(
            labelFont: labelFont,
            candidateFont: candidateFont
        )
        if !label.isEmpty {
            line.append(NSAttributedString(string: "\(label) ", attributes: [
                .font: labelFont,
                .foregroundColor: labelColor,
                .baselineOffset: baseline,
            ]))
        }
        line.append(NSAttributedString(string: text, attributes: [
            .font: candidateFont,
            .foregroundColor: textColor,
        ]))
        return line
    }
}
