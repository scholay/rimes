import AppKit

/// WindowServer front-to-back order, in display-local top-left coordinates.
struct CaptureWindowChoice: Equatable {
    let id: CGWindowID
    let frame: CGRect
    let title: String

    static func hitTest(_ point: CGPoint, in choices: [Self]) -> Self? {
        choices.first { $0.frame.contains(point) }
    }
}

/// Appears before ScreenCaptureKit enumeration or image capture. A user may
/// draw immediately; releasing early queues the crop until its frame arrives.
final class CaptureSelectionView: NSView {
    enum Mode { case area, window }
    let mode: Mode
    var selected: ((CGRect, CGImage) -> Void)?
    var windowSelected: ((CGWindowID) -> Void)?
    var cancelled: (() -> Void)?
    private(set) var snapshot: CGImage?
    private(set) var hoveredWindow: CaptureWindowChoice?
    private(set) var pendingSelection: CGRect?
    var fixedSize: CGSize?
    var ratio: CGFloat?
    private var windowChoices: [CaptureWindowChoice]?
    private var tracking: NSTrackingArea?
    private var finished = false
    private var start: CGPoint?
    private var end = CGPoint.zero
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(mode: Mode = .area) { self.mode = mode; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: mode == .window ? .pointingHand : .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
    }
    override func cancelOperation(_ sender: Any?) {
        guard !finished else { return }
        invalidate(); cancelled?()
    }
    func invalidate() {
        finished = true; snapshot = nil; pendingSelection = nil
        windowChoices = nil; hoveredWindow = nil
    }
    func acceptSnapshot(_ image: CGImage) {
        guard !finished else { return }
        snapshot = image; needsDisplay = true
        deliverSelectionIfReady()
    }
    func acceptWindows(_ choices: [CaptureWindowChoice]) {
        guard !finished else { return }
        windowChoices = choices
        if let window { updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        needsDisplay = true
    }
    func updateHover(at point: CGPoint) {
        guard !finished, mode == .window else { return }
        hoveredWindow = bounds.contains(point) ? CaptureWindowChoice.hitTest(point, in: windowChoices ?? []) : nil
        setAccessibilityValue(hoveredWindow?.title ?? "移动鼠标选择窗口")
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hoveredWindow = nil; needsDisplay = true }
    private var selection: CGRect {
        guard let start else { return .zero }
        var w = abs(end.x - start.x), h = abs(end.y - start.y)
        if let fixedSize { w = fixedSize.width; h = fixedSize.height }
        else if let ratio { h = w / ratio }
        return CGRect(x: end.x < start.x ? start.x - w : start.x,
                      y: end.y < start.y ? start.y - h : start.y, width: w, height: h).intersection(bounds)
    }
    override func mouseDown(with event: NSEvent) {
        guard !finished, pendingSelection == nil else { return }
        if mode == .window { mouseMoved(with: event); return }
        start = convert(event.locationInWindow, from: nil); end = start!; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !finished, pendingSelection == nil else { return }
        if mode == .window { mouseMoved(with: event); return }
        end = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !finished, pendingSelection == nil else { return }
        if mode == .window {
            mouseMoved(with: event)
            if let choice = hoveredWindow { finished = true; windowSelected?(choice.id) }
            return
        }
        end = convert(event.locationInWindow, from: nil)
        if selection.width >= 4, selection.height >= 4 {
            pendingSelection = selection; needsDisplay = true; deliverSelectionIfReady()
        }
    }
    private func deliverSelectionIfReady() {
        guard !finished, let rect = pendingSelection, let snapshot else { return }
        finished = true; selected?(rect, snapshot)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let image = snapshot.map { NSImage(cgImage: $0, size: bounds.size) }
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.40).setFill(); bounds.fill()
        let rect = mode == .window ? (hoveredWindow?.frame.intersection(bounds) ?? .zero) : selection
        if rect.width > 0, rect.height > 0 {
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
            if let image { image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil) }
            else { NSColor.clear.setFill(); rect.fill(using: .copy) }
            NSGraphicsContext.restoreGraphicsState()
            CaptureChrome.blue.setStroke(); let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); border.lineWidth = 2; border.stroke()
        }
        let hint: String
        if mode == .window {
            hint = windowChoices == nil ? "正在准备窗口 · Esc 取消" : "移动鼠标选择窗口 · 单击截取 · Esc 取消"
        } else if snapshot == nil {
            hint = pendingSelection == nil ? "正在准备画面，可先框选 · Esc 取消" : "选区已确定，正在准备截图 · Esc 取消"
        } else { hint = "拖动选择区域 · Esc 取消" }
        drawLabel(hint, at: CGPoint(x: 24, y: 24))
        if mode == .window {
            if let choice = hoveredWindow { drawLabel(choice.title, at: CGPoint(x: rect.minX + 8, y: rect.maxY + 6)) }
            return
        }
        guard start != nil else { return }
        let scale = snapshot.map { CGFloat($0.width) / max(1, bounds.width) } ?? window?.backingScaleFactor ?? 1
        let size = "\(Int(rect.width * scale)) × \(Int(rect.height * scale)) px · \(Int(rect.width)) × \(Int(rect.height)) pt"
        drawLabel(size, at: CGPoint(x: rect.minX, y: rect.maxY + 6))
        guard let snapshot else { return }
        let sample = CGRect(x: end.x * scale - 10, y: end.y * scale - 10, width: 20, height: 20).intersection(CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height))
        if let crop = snapshot.cropping(to: sample) {
            let magnifier = CGRect(x: min(bounds.width - 90, end.x + 24), y: min(bounds.height - 90, end.y + 24), width: 80, height: 80)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: crop, size: magnifier.size).draw(in: magnifier, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            let cross = NSBezierPath(); cross.move(to: CGPoint(x: magnifier.midX, y: magnifier.minY)); cross.line(to: CGPoint(x: magnifier.midX, y: magnifier.maxY)); cross.move(to: CGPoint(x: magnifier.minX, y: magnifier.midY)); cross.line(to: CGPoint(x: magnifier.maxX, y: magnifier.midY)); cross.stroke()
        }
    }
    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = min(textSize.width + 20, max(20, bounds.width - 16))
        let rect = CGRect(x: max(8, min(bounds.width - width - 8, point.x)),
                          y: max(8, min(bounds.height - 36, point.y)), width: width, height: 28)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        var labelAttributes = attributes; labelAttributes[.paragraphStyle] = style
        (text as NSString).draw(in: rect.insetBy(dx: 10, dy: 5), withAttributes: labelAttributes)
    }
}
