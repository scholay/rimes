import AppKit

/// Screenshot chrome has its own neutral palette; the IME theme stays unchanged.
enum CaptureChrome {
    static let blue = NSColor(srgbRed: 0.04, green: 0.46, blue: 1, alpha: 1)
    static let text = NSColor(white: 0.94, alpha: 1)
    static let muted = NSColor(white: 0.68, alpha: 1)
    static let canvas = NSColor(white: 0.115, alpha: 1)
    static let bar = NSColor(srgbRed: 0.17, green: 0.19, blue: 0.22, alpha: 1)
    static let control = NSColor(white: 1, alpha: 0.13)
    static func group(_ children: [NSView], spacing: CGFloat = 2, inset: CGFloat = 4) -> NSView {
        let body = CaptureChromeSurface(radius: 18, color: control)
        CaptureUI.fill(CaptureUI.row(children, spacing: spacing), in: body, inset: inset)
        return body
    }
    static func label(_ text: String, size: CGFloat = 12) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size); field.textColor = self.text
        return field
    }
    static func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

class CaptureChromeSurface: NSView {
    var radius: CGFloat
    var color: NSColor
    init(radius: CGFloat = 0, color: NSColor = CaptureChrome.bar) {
        self.radius = radius; self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Pill, glyph and thumbnail actions use the same hit-tested AppKit button.
final class CaptureChromeButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var onClick: () -> Void
    var active = false { didSet { needsDisplay = true } }
    var swatch: NSColor? { didSet { needsDisplay = true } }
    var emptySwatch = false
    var swatchDiameter: CGFloat = 18
    var light = false
    var bare = false
    var dropdown = false
    var controlSizeHint: NSSize
    init(_ title: String = "", symbol: String? = nil, help: String? = nil,
         size: NSSize = NSSize(width: 42, height: 32), action: @escaping () -> Void = {}) {
        onClick = action; controlSizeHint = size
        super.init(frame: .zero)
        self.title = title; toolTip = help ?? title; isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: help ?? title) }
        target = self; self.action = #selector(invoke)
        setAccessibilityLabel(help ?? title)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { controlSizeHint }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func invoke() { onClick() }
    override func draw(_ dirtyRect: NSRect) {
        let fill = active ? CaptureChrome.blue : light ? NSColor(white: 0.96, alpha: 0.92) : CaptureChrome.control
        if !bare || active || isHighlighted {
            fill.withAlphaComponent(isHighlighted ? 0.65 : fill.alphaComponent).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let tint = (light ? NSColor(white: 0.16, alpha: 1) : CaptureChrome.text).withAlphaComponent(isEnabled ? 1 : 0.35)
        let center = bounds.midX - (dropdown ? 6 : 0)
        if swatch != nil || emptySwatch {
            let circle = NSBezierPath(ovalIn: CGRect(x: center - swatchDiameter / 2, y: bounds.midY - swatchDiameter / 2, width: swatchDiameter, height: swatchDiameter))
            if let swatch {
                swatch.setFill(); circle.fill(); NSColor(white: 1, alpha: 0.55).setStroke(); circle.lineWidth = 1; circle.stroke()
            } else {
                NSColor(white: 1, alpha: 0.2).setStroke(); circle.setLineDash([2, 2], count: 2, phase: 0); circle.stroke()
            }
        } else if let image {
            let side: CGFloat = bounds.height <= 24 ? 11 : 17
            (image.withSymbolConfiguration(.init(paletteColors: [tint])) ?? image).draw(in: CGRect(x: center - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: tint]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: center - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
        if dropdown, let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            (chevron.withSymbolConfiguration(.init(paletteColors: [CaptureChrome.muted])) ?? chevron).draw(in: CGRect(x: bounds.maxX - 14, y: bounds.midY - 3, width: 8, height: 6))
        }
    }
}

final class CaptureModeButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var isFlipped: Bool { false }
    var onClick: () -> Void
    var selected = false { didSet { needsDisplay = true } }
    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        onClick = action
        super.init(frame: .zero)
        self.title = title; image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        isBordered = false; target = self; self.action = #selector(invoke)
        setAccessibilityLabel(title); toolTip = title
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 70, height: 56) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func invoke() { onClick() }
    override func draw(_ dirtyRect: NSRect) {
        if selected || isHighlighted {
            CaptureChrome.control.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        }
        if let image {
            (image.withSymbolConfiguration(.init(paletteColors: [CaptureChrome.text])) ?? image).draw(in: CGRect(x: bounds.midX - 10, y: 28, width: 20, height: 20))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: CaptureChrome.muted]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: 7), withAttributes: attributes)
    }
}

/// Two compact groups, not a settings form. Modes execute immediately; timer
/// changes the next capture, and blank dimensions mean free selection.
final class CaptureLauncherView: NSView {
    var capture: ((String, Int, CGFloat?, CGSize?) -> Void)?
    var recording: (() -> Void)?
    var utilities: [(String, () -> Void)] = []
    private var delay = 0
    private var ratio: CGFloat?
    private let width = NSTextField(string: "")
    private let height = NSTextField(string: "")
    private var menuActions: [CaptureControlAction] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        let timer = CaptureModeButton("延时", symbol: "timer") {}
        timer.onClick = { [weak self, weak timer] in
            guard let self, let timer else { return }
            self.menu([("无延时", 0), ("3 秒", 3), ("5 秒", 5), ("10 秒", 10)], from: timer) { value in
                self.delay = value; timer.title = value == 0 ? "延时" : "\(value) 秒"; timer.selected = value > 0
            }
        }
        let modes = CaptureChrome.group([
            mode("区域", "viewfinder", "area"), mode("全屏", "display", "screen"),
            mode("窗口", "macwindow", "window"), mode("滚动", "arrow.down", "scroll"), timer,
            CaptureUI.verticalSeparator(), mode("取字", "textformat", "ocr"),
            CaptureModeButton("录屏", symbol: "video") { [weak self] in self?.recording?() }
        ], spacing: 0, inset: 6)
        (modes as? CaptureChromeSurface)?.color = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.20, alpha: 0.96)
        for field in [width, height] {
            field.placeholderString = "自动"; field.alignment = .center; field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            field.textColor = CaptureChrome.text; field.backgroundColor = NSColor(white: 0.08, alpha: 0.5)
            field.isBezeled = false; field.focusRingType = .none
            field.widthAnchor.constraint(equalToConstant: 50).isActive = true
            field.heightAnchor.constraint(equalToConstant: 23).isActive = true
        }
        width.setAccessibilityLabel("选区宽度，点"); height.setAccessibilityLabel("选区高度，点")
        let reset = CaptureChromeButton(symbol: "arrow.up.left.and.arrow.down.right", help: "清除固定尺寸", size: NSSize(width: 28, height: 30)) { [weak self] in self?.width.stringValue = ""; self?.height.stringValue = "" }
        reset.bare = true
        let aspect = CaptureChromeButton(symbol: "crop", help: "选区比例", size: NSSize(width: 44, height: 30)); aspect.bare = true; aspect.dropdown = true
        aspect.onClick = { [weak self, weak aspect] in
            guard let self, let aspect else { return }
            self.menu([("自由比例", 0), ("1:1", 1), ("4:3", 2), ("16:9", 3), ("9:16", 4)], from: aspect) { index in
                self.ratio = [nil, 1, 4 / 3, 16 / 9, 9 / 16][index]; aspect.active = index != 0
                aspect.toolTip = "选区比例：" + ["自由", "1:1", "4:3", "16:9", "9:16"][index]
            }
        }
        let options = CaptureChrome.group([width, CaptureChrome.label("×"), height, reset, CaptureUI.verticalSeparator(), aspect], spacing: 7, inset: 12)
        (options as? CaptureChromeSurface)?.color = NSColor(srgbRed: 0.15, green: 0.14, blue: 0.20, alpha: 0.96)
        let row = CaptureUI.row([modes, options], spacing: 10)
        CaptureUI.fill(row, in: self, inset: 0)
        options.heightAnchor.constraint(equalTo: modes.heightAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func rightMouseDown(with event: NSEvent) {
        menuActions.removeAll(); defer { menuActions.removeAll() }
        let menu = NSMenu()
        for (title, perform) in utilities {
            let target = CaptureControlAction(perform); menuActions.append(target)
            let item = NSMenuItem(title: title, action: #selector(CaptureControlAction.fire), keyEquivalent: "")
            item.target = target; menu.addItem(item)
        }
        if !utilities.isEmpty { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    private func mode(_ label: String, _ symbol: String, _ id: String) -> CaptureModeButton {
        CaptureModeButton(label, symbol: symbol) { [weak self] in
            guard let self else { return }
            let w = self.width.doubleValue, h = self.height.doubleValue
            guard self.width.stringValue.isEmpty && self.height.stringValue.isEmpty || (w.isFinite && h.isFinite && w >= 1 && h >= 1 && w <= 16384 && h <= 16384) else {
                NSSound.beep(); self.window?.makeFirstResponder(w <= 0 ? self.width : self.height); return
            }
            self.capture?(id, self.delay, self.ratio, w > 0 && h > 0 ? CGSize(width: w, height: h) : nil)
        }
    }
    private func menu(_ choices: [(String, Int)], from view: NSView, picked: @escaping (Int) -> Void) {
        menuActions.removeAll(); let menu = NSMenu()
        defer { menuActions.removeAll() }
        for (title, value) in choices {
            let action = CaptureControlAction { picked(value) }; menuActions.append(action)
            let item = NSMenuItem(title: title, action: #selector(CaptureControlAction.fire), keyEquivalent: ""); item.target = action; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: view)
    }
}

/// Hover chrome remains a sibling of the image: the thumbnail still handles
/// file dragging, and the passive overlay never activates the input method.
final class CaptureCardControls: NSView {
    let copyButton = CaptureChromeButton("复制", help: "复制并移除卡片", size: NSSize(width: 52, height: 26))
    let saveButton = CaptureChromeButton("保存", size: NSSize(width: 52, height: 26))
    let closeButton = CaptureChromeButton(symbol: "xmark", help: "关闭卡片", size: NSSize(width: 22, height: 22))
    let pinButton = CaptureChromeButton(symbol: "pin.fill", help: "贴图", size: NSSize(width: 22, height: 22))
    let editButton = CaptureChromeButton(symbol: "pencil", help: "标注", size: NSSize(width: 22, height: 22))
    override init(frame: NSRect) {
        super.init(frame: frame)
        let glass = NSVisualEffectView()
        glass.material = .hudWindow; glass.blendingMode = .withinWindow; glass.state = .active
        RoundedWindowChrome.maskMaterial(glass, radius: RoundedWindowChrome.radius)
        CaptureUI.fill(glass, in: self, inset: 0)
        for button in [copyButton, saveButton, closeButton, pinButton, editButton] {
            button.light = true; button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7), pinButton.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            editButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), editButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            copyButton.centerXAnchor.constraint(equalTo: centerXAnchor), copyButton.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -4),
            saveButton.centerXAnchor.constraint(equalTo: centerXAnchor), saveButton.topAnchor.constraint(equalTo: centerYAnchor, constant: 4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point); return hit is NSButton ? hit : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.36).setFill(); bounds.fill()
    }
}
