import AppKit

enum CaptureColorValue {
    static func parse(_ text: String) -> NSColor? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard [6, 8].contains(hex.count), let value = UInt32(hex, radix: 16) else { return nil }
        let rgb = hex.count == 8 ? value >> 8 : value
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: hex.count == 8 ? CGFloat(value & 255) / 255 : 1)
    }
    static func hex(_ color: NSColor, alpha: Bool = true) -> String {
        let color = color.usingColorSpace(.sRGB) ?? .black
        let rgb = String(format: "%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
        return alpha && color.alphaComponent < 0.999 ? rgb + String(format: "%02X", Int((color.alphaComponent * 255).rounded())) : rgb
    }
}

private final class CaptureColorPlane: NSView {
    enum Kind { case saturation, hue, alpha }
    let kind: Kind
    var hue: CGFloat = 0.61
    var saturation: CGFloat = 0.8
    var brightness: CGFloat = 1
    var opacity: CGFloat = 1
    var changed: ((CGFloat, CGFloat) -> Void)?
    init(_ kind: Kind) { self.kind = kind; super.init(frame: .zero); setAccessibilityLabel(kind == .saturation ? "饱和度与亮度" : kind == .hue ? "色相" : "透明度") }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        changed?(min(1, max(0, p.x / bounds.width)), min(1, max(0, p.y / bounds.height)))
    }
    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        let x = kind == .saturation ? saturation : kind == .hue ? hue : opacity
        switch event.keyCode {
        case 123: changed?(max(0, x - step), brightness)
        case 124: changed?(min(1, x + step), brightness)
        case 125: changed?(x, max(0, brightness - step))
        case 126: changed?(x, min(1, brightness + step))
        default: super.keyDown(with: event)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: kind == .saturation ? 5 : 6, yRadius: kind == .saturation ? 5 : 6).setClip()
        switch kind {
        case .saturation:
            NSGradient(starting: .white, ending: NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))?.draw(in: bounds, angle: 0)
            NSGradient(starting: .black, ending: .clear)?.draw(in: bounds, angle: 90)
        case .hue:
            NSGradient(colors: (0...6).map { NSColor(hue: CGFloat($0) / 6, saturation: 1, brightness: 1, alpha: 1) })?.draw(in: bounds, angle: 0)
        case .alpha:
            for x in stride(from: CGFloat(0), to: bounds.width, by: 5) {
                for y in stride(from: CGFloat(0), to: bounds.height, by: 5) {
                    NSColor(white: (Int(x / 5) + Int(y / 5)) % 2 == 0 ? 0.3 : 0.5, alpha: 1).setFill()
                    CGRect(x: x, y: y, width: 5, height: 5).fill()
                }
            }
            let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: bounds, angle: 0)
        }
        NSGraphicsContext.restoreGraphicsState()
        let x = (kind == .saturation ? saturation : kind == .hue ? hue : opacity) * bounds.width
        let y = kind == .saturation ? brightness * bounds.height : bounds.midY
        let ring = NSBezierPath(ovalIn: CGRect(x: min(bounds.maxX - 5, max(5, x)) - 5, y: min(bounds.maxY - 5, max(5, y)) - 5, width: 10, height: 10))
        NSColor.black.withAlphaComponent(0.3).setStroke(); ring.lineWidth = 4; ring.stroke()
        NSColor.white.setStroke(); ring.lineWidth = 2; ring.stroke()
    }
}

final class CaptureColorPicker: NSView {
    var onChange: ((String) -> Void)?
    private(set) var color: NSColor
    private let defaults: UserDefaults
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 0
    private var opacity: CGFloat = 1
    private let plane = CaptureColorPlane(.saturation)
    private let hueBar = CaptureColorPlane(.hue)
    private let alphaBar = CaptureColorPlane(.alpha)
    private let hex = NSTextField(string: "")
    private let channels = (0..<4).map { _ in NSTextField(string: "") }
    private var favorites: [CaptureChromeButton] = []
    private var actions: [CaptureControlAction] = []
    private let sample = CaptureChromeButton(size: NSSize(width: 30, height: 30))
    private var sampler: NSColorSampler?
    init(hex: String, defaults: UserDefaults = .standard) {
        color = CaptureColorValue.parse(hex) ?? .systemYellow; self.defaults = defaults
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 424))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true; layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor; layer?.cornerRadius = 14
        let builtins = ["000000", "FF3547", "FF9D16", "FFE338", "38D44C", "27CCC1", "1687FF", "914BFF", "FF287C", "FFFFFF"]
        for (i, value) in builtins.enumerated() {
            let swatch = CaptureChromeButton(help: "颜色 #" + value, size: NSSize(width: 28, height: 28))
            swatch.bare = true; swatch.swatch = CaptureColorValue.parse(value); swatch.swatchDiameter = 23
            swatch.frame = CGRect(x: 12, y: 384 - i * 36, width: 28, height: 28)
            swatch.onClick = { [weak self] in self?.setColor(CaptureColorValue.parse(value)!) }
            addSubview(swatch)
            let favorite = CaptureChromeButton(help: "保存的颜色 \(i + 1)", size: NSSize(width: 28, height: 28))
            favorite.bare = true; favorite.emptySwatch = true; favorite.swatchDiameter = 23; favorite.frame = swatch.frame.offsetBy(dx: 34, dy: 0)
            favorite.onClick = { [weak self, weak favorite] in if let color = favorite?.swatch { self?.setColor(color) } }
            addSubview(favorite); favorites.append(favorite)
        }
        plane.frame = CGRect(x: 88, y: 222, width: 238, height: 190)
        hueBar.frame = CGRect(x: 100, y: 193, width: 180, height: 12)
        alphaBar.frame = CGRect(x: 100, y: 173, width: 180, height: 12)
        sample.frame = CGRect(x: 291, y: 176, width: 30, height: 30); sample.bare = true; sample.isEnabled = false
        for view in [plane, hueBar, alphaBar, sample] { addSubview(view) }
        plane.changed = { [weak self] s, b in self?.saturation = s; self?.brightness = b; self?.applyHSB() }
        hueBar.changed = { [weak self] h, _ in self?.hue = h; self?.applyHSB() }
        alphaBar.changed = { [weak self] a, _ in self?.opacity = a; self?.applyHSB() }
        self.hex.frame = CGRect(x: 100, y: 134, width: 180, height: 25)
        configure(self.hex, label: "Hex") { [weak self] in
            guard let self else { return }
            guard let color = CaptureColorValue.parse(self.hex.stringValue) else { NSSound.beep(); self.refresh(); return }
            // Six digits edit RGB without unexpectedly resetting transparency.
            self.setColor(self.hex.stringValue.replacingOccurrences(of: "#", with: "").count == 6 ? color.withAlphaComponent(self.opacity) : color)
        }
        let eyedropper = CaptureChromeButton(symbol: "eyedropper", help: "从屏幕取色", size: NSSize(width: 28, height: 25))
        eyedropper.bare = true; eyedropper.frame = CGRect(x: 290, y: 134, width: 28, height: 25)
        eyedropper.onClick = { [weak self] in
            guard let self else { return }; let sampler = NSColorSampler(); self.sampler = sampler
            sampler.show { [weak self] color in if let color { self?.setColor(color) }; self?.sampler = nil }
        }
        addSubview(eyedropper)
        for (i, field) in channels.enumerated() {
            field.frame = CGRect(x: 100 + i * 57, y: 80, width: 49, height: 25)
            configure(field, label: ["R", "G", "B", "Alpha"][i]) { [weak self] in self?.applyChannels() }
        }
        let add = CaptureChromeButton("＋ 添加到我的颜色", size: NSSize(width: 222, height: 34)) { [weak self] in self?.saveFavorite() }
        add.active = true; add.frame = CGRect(x: 100, y: 16, width: 222, height: 34); addSubview(add)
        setColor(color, notify: false); refreshFavorites()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func configure(_ field: NSTextField, label: String, action: @escaping () -> Void) {
        field.alignment = .center; field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = CaptureChrome.text; field.backgroundColor = NSColor(white: 0.21, alpha: 1)
        field.isBezeled = false; field.focusRingType = .none; field.wantsLayer = true; field.layer?.cornerRadius = 5
        let target = CaptureControlAction(action); actions.append(target); field.target = target; field.action = #selector(CaptureControlAction.fire)
        field.setAccessibilityLabel(label); addSubview(field)
        let caption = CaptureChrome.label(label, size: 10); caption.textColor = CaptureChrome.muted; caption.alignment = .center
        caption.frame = CGRect(x: field.frame.minX, y: field.frame.minY - 17, width: field.frame.width, height: 14); addSubview(caption)
    }
    func setColor(_ value: NSColor, notify: Bool = true) {
        guard let value = value.usingColorSpace(.sRGB) else { return }
        color = value; value.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &opacity)
        refresh(); if notify { onChange?(CaptureColorValue.hex(color)) }
    }
    private func applyHSB() {
        color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: opacity).usingColorSpace(.sRGB)!
        refresh(); onChange?(CaptureColorValue.hex(color))
    }
    private func applyChannels() {
        let limits = [255, 255, 255, 100]
        guard zip(channels, limits).allSatisfy({ field, limit in Int(field.stringValue).map { (0...limit).contains($0) } ?? false }) else { NSSound.beep(); refresh(); return }
        setColor(NSColor(srgbRed: CGFloat(channels[0].integerValue) / 255, green: CGFloat(channels[1].integerValue) / 255, blue: CGFloat(channels[2].integerValue) / 255, alpha: CGFloat(channels[3].integerValue) / 100))
    }
    private func refresh() {
        for view in [plane, hueBar, alphaBar] { view.hue = hue; view.saturation = saturation; view.brightness = brightness; view.opacity = opacity; view.needsDisplay = true }
        hex.stringValue = CaptureColorValue.hex(color, alpha: false)
        let rgb = color.usingColorSpace(.sRGB)!
        for (field, value) in zip(channels, [rgb.redComponent * 255, rgb.greenComponent * 255, rgb.blueComponent * 255, opacity * 100]) { field.integerValue = Int(value.rounded()) }
        sample.swatch = color
    }
    func saveFavorite() {
        var saved = defaults.stringArray(forKey: "capture.annotation.colors") ?? []
        let value = CaptureColorValue.hex(color); saved.removeAll { $0 == value }; saved.insert(value, at: 0)
        defaults.set(Array(saved.prefix(10)), forKey: "capture.annotation.colors"); refreshFavorites()
    }
    private func refreshFavorites() {
        let saved = defaults.stringArray(forKey: "capture.annotation.colors") ?? []
        for (i, button) in favorites.enumerated() { button.swatch = i < saved.count ? CaptureColorValue.parse(saved[i]) : nil; button.isEnabled = button.swatch != nil; button.needsDisplay = true }
    }
}
