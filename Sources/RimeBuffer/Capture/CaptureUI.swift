import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

final class CaptureButton: NSButton {
    var perform: () -> Void
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        perform = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded; isBordered = false
        font = .systemFont(ofSize: 12)
        target = self
        self.action = #selector(invoke)
        if let symbol { image = RimeUI.symbol(symbol, pointSize: 13, weight: .regular); imagePosition = .imageLeading }
        setAccessibilityLabel(title)
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(42, (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width + (image == nil ? 20 : 40)), height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        let primary = title == "收入 Capsule" || title == "开始录制"
        let fill = primary ? RimeUI.accentGreen : (isHighlighted ? RimeUI.surface2 : RimeUI.surface3)
        fill.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        RimeUI.border.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        let foreground = primary ? RimeUI.accentForegroundColor : RimeUI.textPrimary
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: isEnabled ? foreground : RimeUI.textMuted]
        let size = (title as NSString).size(withAttributes: attributes)
        let x = image == nil ? (bounds.width-size.width)/2 : 29
        (title as NSString).draw(at: CGPoint(x: x, y: (bounds.height-size.height)/2), withAttributes: attributes)
        if let image { (image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [foreground])) ?? image).draw(in: CGRect(x: 9, y: (bounds.height-14)/2, width: 14, height: 14)) }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A square icon button that shows which tool is active. The previous rail
/// was a column of text buttons whose widths tracked the length of each
/// Chinese name, so nothing lined up and nothing showed the current tool.
final class CaptureToolButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    private let tool: CaptureTool
    private let perform: (CaptureTool) -> Void
    var isActiveTool = false { didSet { needsDisplay = true } }

    init(tool: CaptureTool, action: @escaping (CaptureTool) -> Void) {
        self.tool = tool
        perform = action
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = RimeUI.symbol(tool.symbolName, pointSize: 14, weight: .regular)
        target = self
        self.action = #selector(invoke)
        toolTip = tool.title
        setAccessibilityLabel(tool.title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func invoke() { perform(tool) }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 15, yRadius: 15)
        if isActiveTool {
            CaptureChrome.blue.setFill()
        } else if isHighlighted {
            CaptureChrome.control.setFill()
        } else {
            NSColor.clear.setFill()
        }
        path.fill()
        let tint = CaptureChrome.text
        guard let image else { return }
        let art = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tint])
        ) ?? image
        art.draw(in: CGRect(
            x: (bounds.width - 16) / 2,
            y: (bounds.height - 16) / 2,
            width: 16,
            height: 16
        ))
    }
}

/// Carries a closure to a target/action control, so popups and fields can
/// apply as they change instead of waiting for an "apply" button.
final class CaptureControlAction: NSObject {
    private let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
    @objc func fire() { perform() }
}

/// An icon button for the capture strip: same square geometry as the editor
/// tool rail, with the name kept as the tooltip. `isOn` draws the accent fill
/// so a toggle such as freeze reads as engaged.
final class CaptureGlyphButton: NSButton {
    /// Assignable so a toggle can refer to itself when it flips.
    var onClick: () -> Void
    private let prominent: Bool
    var isOn = false { didSet { needsDisplay = true } }

    init(symbol: String,
         tooltip: String,
         prominent: Bool = false,
         action: @escaping () -> Void = {}) {
        onClick = action
        self.prominent = prominent
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = RimeUI.symbol(symbol, pointSize: 14, weight: .regular)
        target = self
        self.action = #selector(invoke)
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 30) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc private func invoke() { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7)
        if isOn || prominent {
            RimeUI.accentGreen.setFill()
        } else if isHighlighted {
            RimeUI.surface2.setFill()
        } else {
            RimeUI.surface3.setFill()
        }
        path.fill()
        if !(isOn || prominent) {
            RimeUI.border.setStroke()
            path.stroke()
        }
        let tint = (isOn || prominent)
            ? RimeUI.accentForegroundColor
            : RimeUI.textPrimary
        guard let image else { return }
        let art = image.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tint])
        ) ?? image
        art.draw(in: CGRect(x: (bounds.width - 16) / 2,
                            y: (bounds.height - 16) / 2,
                            width: 16,
                            height: 16))
    }
}

/// Reveals its controls only while the pointer is inside, so a result
/// overlay is a thumbnail at rest and a toolbar when reached for.
final class CaptureHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

enum CaptureUI {
    /// A vertical hairline between groups in a horizontal strip.
    static func verticalSeparator(height: CGFloat = 20) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = RimeUI.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: height),
        ])
        return line
    }

    /// A label/control pair whose labels all line up, which a plain row of
    /// mismatched intrinsic widths does not.
    static func field(_ title: String, _ control: NSView,
                      labelWidth: CGFloat = 40) -> NSStackView {
        let caption = label(title)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        let row = self.row([caption, control], spacing: 6)
        row.distribution = .fill
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    /// A hairline between tool groups.
    static func separator(width: CGFloat) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = RimeUI.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.widthAnchor.constraint(equalToConstant: width),
        ])
        return line
    }

    /// A section header for the inspector, so the controls below it read as
    /// a group instead of a pile.
    static func sectionHeader(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = RimeUI.textMuted
        return label
    }

    static func label(_ value: String, size: CGFloat = 12) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size)
        label.textColor = RimeUI.textPrimary
        return label
    }
    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = spacing
        return row
    }
    static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    static func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 14) {
        parent.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
    static func error(_ error: Error, window: NSWindow? = nil) {
        let alert = NSAlert(); alert.messageText = "Capsule"; alert.informativeText = error.localizedDescription
        if let window, window.isVisible { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}

/// Shared chrome for new Capsule windows. Only key-capable surfaces acquire
/// standalone focus; passive overlays never claim an input-method target.
class CapturePanel: NSPanel, NSWindowDelegate {
    var captureChrome = false { didSet { updateTheme() } }
    var closed: (() -> Void)?
    var escapeCloses = true
    var shouldClose: (() -> Bool)?
    private let acceptsKeyboard: Bool
    private var registered = false
    private var themeObserver: NSObjectProtocol?
    init(size: NSSize, key: Bool = true) {
        acceptsKeyboard = key
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: key ? [.titled, .fullSizeContentView, .resizable] : [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden; titlebarAppearsTransparent = true
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(type)?.isHidden = true }
        isReleasedWhenClosed = false; isMovableByWindowBackground = true; hasShadow = true; hidesOnDeactivate = false
        backgroundColor = RimeUI.surface; appearance = RimeUI.appKitAppearance
        contentView?.wantsLayer = true; contentView?.layer?.cornerRadius = 14
        contentView?.layer?.masksToBounds = true
        level = .floating; collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        delegate = self
        themeObserver = NotificationCenter.default.addObserver(forName: .rimeAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in self?.updateTheme() }
    }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    private func updateTheme() {
        if captureChrome {
            appearance = NSAppearance(named: .darkAqua); backgroundColor = isOpaque ? CaptureChrome.bar : .clear
            contentView?.needsDisplay = true
            return
        }
        appearance = RimeUI.appKitAppearance; backgroundColor = RimeUI.surface
        func visit(_ view: NSView) {
            if let label = view as? NSTextField { label.textColor = RimeUI.textPrimary }
            if let text = view as? NSTextView { text.textColor = RimeUI.textPrimary; text.backgroundColor = RimeUI.surface2 }
            view.needsDisplay = true; view.subviews.forEach(visit)
        }
        if let contentView { visit(contentView) }
    }
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { acceptsKeyboard }
    func present(center: Bool = true) {
        if center { self.center() }
        appearance = captureChrome ? NSAppearance(named: .darkAqua) : RimeUI.appKitAppearance
        if acceptsKeyboard {
            StandaloneWindowFocusCoordinator.shared.windowWillPresent(self)
            registered = true
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        } else { orderFrontRegardless() }
    }
    override func cancelOperation(_ sender: Any?) { if escapeCloses { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose?() ?? true }
    func windowDidBecomeKey(_ notification: Notification) {
        if !registered { StandaloneWindowFocusCoordinator.shared.windowWillPresent(self); registered = true }
    }
    func windowWillClose(_ notification: Notification) {
        if registered { StandaloneWindowFocusCoordinator.shared.windowWillClose(self); registered = false }
        closed?()
    }
}

final class CaptureInspectorScroll: NSScrollView {
    private let stack: NSView
    private final class Document: NSView { override var isFlipped: Bool { true } }
    init(_ stack: NSView) {
        self.stack = stack
        super.init(frame: .zero)
        drawsBackground = false; hasVerticalScroller = true
        let document = Document(); document.addSubview(stack); documentView = document
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let height = max(contentSize.height, stack.fittingSize.height)
        documentView?.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: height)
        stack.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: stack.fittingSize.height)
    }
}

final class CaptureDragImageView: NSImageView, NSDraggingSource {
    var file: URL?
    var clicked: ((NSEvent) -> Void)?
    /// Crop to fill the frame instead of fitting inside it. Captures arrive
    /// in every shape — a wide strip, a tall window, a small region — and
    /// fitting them into one box letterboxes each one differently, so a
    /// column of cards has art floating at a different size in every card.
    /// Filling and cropping keeps the cards identical; the top-left is kept
    /// because that is where a screenshot's subject usually is.
    var fillsFrame = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard fillsFrame, let image, image.size.width > 0, image.size.height > 0 else {
            super.draw(dirtyRect)
            return
        }
        let scale = max(bounds.width / image.size.width,
                        bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale,
                          height: image.size.height * scale)
        // Anchor top-left, clipped to the card.
        let target = NSRect(x: bounds.minX,
                            y: bounds.maxY - size.height,
                            width: size.width,
                            height: size.height)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        image.draw(in: target,
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        if let clicked { clicked(event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let file else { return }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// File promises keep export rendering off the main thread and freeze the
/// document at drag start, including every redaction and unsaved edit.
final class CaptureCurrentDragView: NSView, NSDraggingSource {
    var snapshot: (() -> (CaptureDocument, URL, CaptureStore, UUID)?)?
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 32) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) {
        CaptureChrome.control.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        ("≡   拖出图片   ≡" as NSString).draw(at: CGPoint(x: 18, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: CaptureChrome.muted])
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (document, directory, store, id) = snapshot?() else { return }
        let provider = CaptureImagePromise(document: document, directory: directory, store: store, id: id)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: NSImage(named: NSImage.multipleDocumentsName))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

private final class CaptureImagePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let document: CaptureDocument
    private let directory: URL
    private let store: CaptureStore
    private let id: UUID
    private let acquired: Bool
    private let worker = OperationQueue()
    init(document: CaptureDocument, directory: URL, store: CaptureStore, id: UUID) {
        self.document = document; self.directory = directory; self.store = store; self.id = id
        acquired = store.acquire(id)
        super.init()
        fileType = UTType.png.identifier
        delegate = self; worker.maxConcurrentOperationCount = 1; worker.qualityOfService = .userInitiated
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if acquired { store.release(id) } }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Capsule-\(UUID().uuidString.prefix(8)).png" }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { worker }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard acquired else { completionHandler(CaptureError.message("资产已进入清理，请刷新后重试")); return }
        do { try CaptureImageIO.write(CaptureRenderer.render(document, directory: directory), to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}

final class CapturePinPanel: CapturePanel {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override func keyDown(with event: NSEvent) {
        var point = frame.origin
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: point.x -= step
        case 124: point.x += step
        case 125: point.y -= step
        case 126: point.y += step
        case 53: close(); return
        default: return
        }
        setFrameOrigin(point)
    }
}
