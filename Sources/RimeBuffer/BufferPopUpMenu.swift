import AppKit

/// Geometry for the workbench's split pull-down control: a title column, one
/// hairline divider, and a trailing disclosure column. Kept pure so
/// `buffer-window-smoke` can pin the split without instantiating a window.
enum BufferPopUpControlMetrics {
    static let cornerRadius: CGFloat = 5
    static let titleLeadingInset: CGFloat = 7
    static let titleTrailingInset: CGFloat = 6
    static let dividerWidth: CGFloat = 1
    static let dividerVerticalInset: CGFloat = 3
    static let disclosureWidth: CGFloat = 18
    static let chevronHalfWidth: CGFloat = 3
    static let chevronHeight: CGFloat = 2.4
    static let chevronLineWidth: CGFloat = 1.4

    /// Width the control needs for a given rendered title width.
    static func intrinsicWidth(titleWidth: CGFloat) -> CGFloat {
        titleLeadingInset + max(0, titleWidth) + titleTrailingInset
            + dividerWidth + disclosureWidth
    }

    static func disclosureRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - disclosureWidth,
               y: bounds.minY,
               width: disclosureWidth,
               height: bounds.height)
    }

    static func dividerRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - disclosureWidth - dividerWidth,
               y: bounds.minY + dividerVerticalInset,
               width: dividerWidth,
               height: max(0, bounds.height - dividerVerticalInset * 2))
    }

    /// Everything left of the divider belongs to the title, so a long title
    /// truncates instead of sliding under the disclosure column.
    static func titleRect(in bounds: NSRect) -> NSRect {
        let trailing = bounds.maxX - disclosureWidth - dividerWidth
            - titleTrailingInset
        let x = bounds.minX + titleLeadingInset
        return NSRect(x: x,
                      y: bounds.minY,
                      width: max(0, trailing - x),
                      height: bounds.height)
    }
}

/// One rendered menu row. Separators carry no title and never highlight.
struct BufferPopUpMenuRow: Equatable {
    let itemIndex: Int
    let title: String
    let isSeparator: Bool
    let isEnabled: Bool
    let isSelected: Bool
    /// A tick that does not mean "this is the current choice". One pull-down
    /// can hold a mutually exclusive choice and an independent switch, and a
    /// switch cannot borrow the selection model without making the choice
    /// above it look unselected whenever the switch is on.
    let isChecked: Bool

    init(itemIndex: Int,
         title: String,
         isSeparator: Bool,
         isEnabled: Bool,
         isSelected: Bool,
         isChecked: Bool = false) {
        self.itemIndex = itemIndex
        self.title = title
        self.isSeparator = isSeparator
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.isChecked = isChecked
    }

    var showsTick: Bool { isSelected || isChecked }

    static func separator(itemIndex: Int) -> BufferPopUpMenuRow {
        BufferPopUpMenuRow(itemIndex: itemIndex,
                           title: "",
                           isSeparator: true,
                           isEnabled: false,
                           isSelected: false)
    }
}

/// Pure layout for the custom menu surface. The workbench panel never becomes
/// key, so the menu is an ordinary nonactivating panel rather than an `NSMenu`
/// tracking loop; that keeps the host's focus lease untouched while it is open.
enum BufferPopUpMenuMetrics {
    static let cornerRadius: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let rowHeight: CGFloat = 24
    static let rowCornerRadius: CGFloat = 5
    static let rowHorizontalInset: CGFloat = 5
    static let titleLeadingInset: CGFloat = 10
    static let checkmarkColumnWidth: CGFloat = 22
    static let separatorRowHeight: CGFloat = 9
    static let minimumWidth: CGFloat = 116
    static let maximumWidth: CGFloat = 320
    static let controlGap: CGFloat = 4
    static let screenEdgeInset: CGFloat = 6

    static var font: NSFont { .systemFont(ofSize: 12) }

    static func height(for row: BufferPopUpMenuRow) -> CGFloat {
        row.isSeparator ? separatorRowHeight : rowHeight
    }

    static func contentHeight(for rows: [BufferPopUpMenuRow]) -> CGFloat {
        rows.reduce(verticalPadding * 2) { $0 + height(for: $1) }
    }

    static func contentWidth(titleWidths: [CGFloat]) -> CGFloat {
        let widest = titleWidths.max() ?? 0
        let needed = rowHorizontalInset * 2 + titleLeadingInset + widest
            + checkmarkColumnWidth
        return min(maximumWidth, max(minimumWidth, ceil(needed)))
    }

    /// Prefers the space under the control and flips above only when the menu
    /// cannot fit, then clamps horizontally so it never lands off screen.
    static func panelOrigin(controlFrameInScreen control: NSRect,
                            panelSize: NSSize,
                            visibleFrame: NSRect) -> NSPoint {
        var x = control.minX
        if x + panelSize.width > visibleFrame.maxX - screenEdgeInset {
            x = visibleFrame.maxX - screenEdgeInset - panelSize.width
        }
        x = max(visibleFrame.minX + screenEdgeInset, x)

        let below = control.minY - controlGap - panelSize.height
        if below >= visibleFrame.minY + screenEdgeInset {
            return NSPoint(x: x, y: below)
        }
        let above = control.maxY + controlGap
        if above + panelSize.height <= visibleFrame.maxY - screenEdgeInset {
            return NSPoint(x: x, y: above)
        }
        return NSPoint(x: x, y: max(visibleFrame.minY + screenEdgeInset, below))
    }

    static func rows(for popup: NSPopUpButton) -> [BufferPopUpMenuRow] {
        popup.itemArray.enumerated().map { index, item in
            if item.isSeparatorItem { return .separator(itemIndex: index) }
            return BufferPopUpMenuRow(
                itemIndex: index,
                title: item.title,
                isSeparator: false,
                isEnabled: item.isEnabled,
                isSelected: index == popup.indexOfSelectedItem,
                // NSMenuItem.state carries a toggle the popup's own selection
                // cannot express.
                isChecked: item.state == .on
            )
        }
    }
}

private final class BufferPopUpMenuContentView: NSView {
    private var rows: [BufferPopUpMenuRow] = []
    private var highlightedRow: Int?
    private var trackingArea: NSTrackingArea?
    var onSelect: ((BufferPopUpMenuRow) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setRows(_ rows: [BufferPopUpMenuRow]) {
        self.rows = rows
        highlightedRow = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // The panel never becomes key, so hover needs `.activeAlways`.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                      .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func rowFrames() -> [(row: BufferPopUpMenuRow, frame: NSRect)] {
        var y = BufferPopUpMenuMetrics.verticalPadding
        return rows.map { row in
            let height = BufferPopUpMenuMetrics.height(for: row)
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            return (row, frame)
        }
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        rowFrames().first {
            !$0.row.isSeparator && $0.row.isEnabled && $0.frame.contains(point)
        }?.row.itemIndex
    }

    override func mouseMoved(with event: NSEvent) {
        updateHighlight(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        updateHighlight(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        highlightedRow = nil
        needsDisplay = true
    }

    private func updateHighlight(at point: NSPoint) {
        let index = rowIndex(at: point)
        guard index != highlightedRow else { return }
        highlightedRow = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        updateHighlight(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point),
              let row = rows.first(where: { $0.itemIndex == index }) else { return }
        onSelect?(row)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = RimeUI.isRasta ? RimeUI.brandGreen : RimeUI.accentBlue
        for (row, frame) in rowFrames() {
            if row.isSeparator {
                let line = NSRect(
                    x: BufferPopUpMenuMetrics.rowHorizontalInset,
                    y: frame.midY - 0.5,
                    width: frame.width
                        - BufferPopUpMenuMetrics.rowHorizontalInset * 2,
                    height: 1
                )
                RimeUI.border.setFill()
                line.fill()
                continue
            }

            let inset = frame.insetBy(
                dx: BufferPopUpMenuMetrics.rowHorizontalInset,
                dy: 1
            )
            if row.itemIndex == highlightedRow {
                let highlight = NSBezierPath(
                    roundedRect: inset,
                    xRadius: BufferPopUpMenuMetrics.rowCornerRadius,
                    yRadius: BufferPopUpMenuMetrics.rowCornerRadius
                )
                BufferWorkbenchPointerRules.backgroundColor(for: .hovered).setFill()
                highlight.fill()
            }

            let color: NSColor = row.isEnabled
                ? RimeUI.textPrimary
                : RimeUI.textMuted
            let attributes: [NSAttributedString.Key: Any] = [
                .font: BufferPopUpMenuMetrics.font,
                .foregroundColor: color,
            ]
            let size = (row.title as NSString).size(withAttributes: attributes)
            let titleOrigin = NSPoint(
                x: BufferPopUpMenuMetrics.rowHorizontalInset
                    + BufferPopUpMenuMetrics.titleLeadingInset,
                y: frame.midY - size.height / 2
            )
            (row.title as NSString).draw(at: titleOrigin, withAttributes: attributes)

            guard row.showsTick,
                  let checkmark = RimeUI.symbol("checkmark", pointSize: 11,
                                                weight: .semibold) else { continue }
            let checkSize = checkmark.size
            let checkRect = NSRect(
                x: frame.maxX - BufferPopUpMenuMetrics.rowHorizontalInset
                    - BufferPopUpMenuMetrics.checkmarkColumnWidth / 2
                    - checkSize.width / 2,
                y: frame.midY - checkSize.height / 2,
                width: checkSize.width,
                height: checkSize.height
            )
            // The fill must come after the glyph: `sourceAtop` recolors the
            // alpha that is already there.
            let tinted = NSImage(size: checkSize, flipped: false) { rect in
                checkmark.draw(in: rect)
                accent.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            // This view is flipped, so the glyph must respect that or the
            // checkmark renders upside down.
            tinted.draw(in: checkRect,
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: nil)
        }
    }
}

private final class BufferPopUpMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Presents the workbench's own menu surface for a pull-down control. Only one
/// menu exists at a time; every dismissal path routes through `dismiss()` so a
/// hidden or protected workbench can never leave a menu behind.
final class BufferPopUpMenuController {
    static let shared = BufferPopUpMenuController()

    private var panel: BufferPopUpMenuPanel?
    private var contentView: BufferPopUpMenuContentView?
    private weak var presentingPopUp: NSPopUpButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    private init() {}

    var isPresenting: Bool { panel != nil }

    func isPresenting(for popup: NSPopUpButton) -> Bool {
        presentingPopUp === popup
    }

    func toggle(for popup: NSPopUpButton) {
        if isPresenting(for: popup) {
            dismiss()
            return
        }
        present(for: popup)
    }

    func present(for popup: NSPopUpButton) {
        dismiss()
        guard popup.isEnabled,
              let window = popup.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let rows = BufferPopUpMenuMetrics.rows(for: popup)
        guard rows.contains(where: { !$0.isSeparator }) else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: BufferPopUpMenuMetrics.font,
        ]
        let titleWidths = rows.map { row in
            (row.title as NSString).size(withAttributes: attributes).width
        }
        let size = NSSize(
            width: BufferPopUpMenuMetrics.contentWidth(titleWidths: titleWidths),
            height: BufferPopUpMenuMetrics.contentHeight(for: rows)
        )
        let controlFrame = window.convertToScreen(
            popup.convert(popup.bounds, to: nil)
        )
        let origin = BufferPopUpMenuMetrics.panelOrigin(
            controlFrameInScreen: controlFrame,
            panelSize: size,
            visibleFrame: screen.visibleFrame
        )

        let panel = BufferPopUpMenuPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = CandidatePanelLevelRules.standard
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = RimeUI.appKitAppearance

        let chrome = BufferPopUpMenuChromeView(
            frame: NSRect(origin: .zero, size: size)
        )
        let content = BufferPopUpMenuContentView(
            frame: NSRect(origin: .zero, size: size)
        )
        content.autoresizingMask = [.width, .height]
        content.setRows(rows)
        content.onSelect = { [weak self] row in
            self?.commit(row: row)
        }
        chrome.addSubview(content)
        panel.contentView = chrome
        panel.orderFront(nil)

        self.panel = panel
        contentView = content
        presentingPopUp = popup
        installMonitors()
        observe(ownerWindow: window)
    }

    func dismiss() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        contentView = nil
        presentingPopUp = nil
    }

    /// Selection mirrors `NSPopUpButton`: the model changes first, then the
    /// control's own target/action runs, so existing handlers stay unchanged.
    private func commit(row: BufferPopUpMenuRow) {
        guard let popup = presentingPopUp else { return }
        dismiss()
        guard row.itemIndex < popup.numberOfItems,
              let item = popup.item(at: row.itemIndex),
              item.isEnabled else { return }
        popup.select(item)
        popup.synchronizeTitleAndSelectedItem()
        popup.needsDisplay = true
        if let action = popup.action {
            NSApp.sendAction(action, to: popup.target, from: popup)
        }
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window === panel { return event }
            // A click on the owning control would otherwise reopen the menu
            // this same gesture is closing.
            let hitOwner = event.window === self.presentingPopUp?.window
                && self.presentingPopUp.map { popup -> Bool in
                    let point = popup.convert(event.locationInWindow, from: nil)
                    return popup.bounds.contains(point)
                } == true
            self.dismiss()
            return hitOwner ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }

    /// The menu is anchored to a control, not reparented into it, so any move
    /// of the workbench — drag, Space change, or screen change — dismisses it
    /// instead of leaving a detached surface behind.
    private func observe(ownerWindow: NSWindow) {
        let names: [NSNotification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.willCloseNotification,
        ]
        windowObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: ownerWindow,
                queue: .main
            ) { [weak self] _ in
                self?.dismiss()
            }
        }
    }
}

/// Draws the menu's rounded surface. Keeping chrome in its own view lets the
/// row content view stay purely about rows and hit testing.
private final class BufferPopUpMenuChromeView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let hairline = 1 / max(scale, 1)
        let rect = bounds.insetBy(dx: hairline / 2, dy: hairline / 2)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: BufferPopUpMenuMetrics.cornerRadius,
            yRadius: BufferPopUpMenuMetrics.cornerRadius
        )
        RimeUI.workbenchChrome.setFill()
        path.fill()
        RimeUI.borderStrong.setStroke()
        path.lineWidth = hairline
        path.stroke()
    }
}

/// Dev-only: render the menu surface offscreen so its style can be reviewed
/// without opening a live workbench menu. Not wired into shipped menus.
func renderBufferPopUpMenuPreview(to path: String,
                                  rows: [BufferPopUpMenuRow],
                                  scale: CGFloat = 2) -> Bool {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: BufferPopUpMenuMetrics.font,
    ]
    let titleWidths = rows.map { row in
        (row.title as NSString).size(withAttributes: attributes).width
    }
    let size = NSSize(
        width: BufferPopUpMenuMetrics.contentWidth(titleWidths: titleWidths),
        height: BufferPopUpMenuMetrics.contentHeight(for: rows)
    )
    let chrome = BufferPopUpMenuChromeView(
        frame: NSRect(origin: .zero, size: size)
    )
    chrome.appearance = RimeUI.appKitAppearance
    let content = BufferPopUpMenuContentView(
        frame: NSRect(origin: .zero, size: size)
    )
    content.setRows(rows)
    chrome.addSubview(content)
    chrome.layoutSubtreeIfNeeded()

    let renderScale = max(1, scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int((size.width * renderScale).rounded()),
        pixelsHigh: Int((size.height * renderScale).rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return false }
    bitmap.size = size
    chrome.cacheDisplay(in: chrome.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }
    return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
}

/// Pure geometry checks for `buffer-window-smoke`: the control's three columns
/// partition its bounds, and the menu prefers below, flips above, and clamps.
func runBufferPopUpMenuGeometryProbe() -> Bool {
    let bounds = NSRect(x: 0, y: 0, width: 98, height: 18)
    let title = BufferPopUpControlMetrics.titleRect(in: bounds)
    let divider = BufferPopUpControlMetrics.dividerRect(in: bounds)
    let disclosure = BufferPopUpControlMetrics.disclosureRect(in: bounds)
    let epsilon: CGFloat = 0.001
    let columnsSplit = title.maxX <= divider.minX + epsilon
        && abs(divider.maxX - disclosure.minX) <= epsilon
        && abs(disclosure.maxX - bounds.maxX) <= epsilon
        && abs(divider.width - BufferPopUpControlMetrics.dividerWidth) <= epsilon
        && divider.height < bounds.height
        && title.minX > bounds.minX
        && title.width > 0

    let rows = [
        BufferPopUpMenuRow(itemIndex: 0, title: "Create PR", isSeparator: false,
                           isEnabled: true, isSelected: true),
        BufferPopUpMenuRow(itemIndex: 1, title: "Create draft PR",
                           isSeparator: false, isEnabled: true,
                           isSelected: false),
        .separator(itemIndex: 2),
        BufferPopUpMenuRow(itemIndex: 3, title: "Manually create PR",
                           isSeparator: false, isEnabled: false,
                           isSelected: false),
    ]
    let expectedHeight = BufferPopUpMenuMetrics.verticalPadding * 2
        + BufferPopUpMenuMetrics.rowHeight * 3
        + BufferPopUpMenuMetrics.separatorRowHeight
    let heightMatches = abs(
        BufferPopUpMenuMetrics.contentHeight(for: rows) - expectedHeight
    ) <= epsilon
    let widthClamps = BufferPopUpMenuMetrics.contentWidth(titleWidths: [10])
            == BufferPopUpMenuMetrics.minimumWidth
        && BufferPopUpMenuMetrics.contentWidth(titleWidths: [4000])
            == BufferPopUpMenuMetrics.maximumWidth

    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let panelSize = NSSize(width: 160, height: 120)
    let roomy = BufferPopUpMenuMetrics.panelOrigin(
        controlFrameInScreen: NSRect(x: 200, y: 500, width: 98, height: 18),
        panelSize: panelSize,
        visibleFrame: screen
    )
    let opensBelow = abs(roomy.y
        - (500 - BufferPopUpMenuMetrics.controlGap - panelSize.height)) <= epsilon
        && abs(roomy.x - 200) <= epsilon
    let tight = BufferPopUpMenuMetrics.panelOrigin(
        controlFrameInScreen: NSRect(x: 200, y: 40, width: 98, height: 18),
        panelSize: panelSize,
        visibleFrame: screen
    )
    let flipsAbove = abs(tight.y - (58 + BufferPopUpMenuMetrics.controlGap)) <= epsilon
    let edge = BufferPopUpMenuMetrics.panelOrigin(
        controlFrameInScreen: NSRect(x: 1400, y: 500, width: 98, height: 18),
        panelSize: panelSize,
        visibleFrame: screen
    )
    let clampsHorizontally = abs(
        edge.x - (screen.maxX - BufferPopUpMenuMetrics.screenEdgeInset
            - panelSize.width)
    ) <= epsilon

    let passed = columnsSplit && heightMatches && widthClamps && opensBelow
        && flipsAbove && clampsHorizontally
    if !passed {
        print("FAILED: buffer pull-down geometry",
              "columns=\(columnsSplit)",
              "height=\(heightMatches)",
              "width=\(widthClamps)",
              "below=\(opensBelow)",
              "above=\(flipsAbove)",
              "clamp=\(clampsHorizontally)")
    }
    return passed
}
