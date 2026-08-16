import AppKit

/// Product-owned checkbox/radio control whose selected state always uses the
/// current theme accent instead of the user's macOS accent preference.
final class RimeFixedAccentChoiceButton: NSControl {
    enum Style {
        case checkbox
        case radio
    }

    let style: Style

    var title: String {
        didSet {
            guard oldValue != title else { return }
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var state: NSControl.StateValue = .off {
        didSet {
            let normalized: NSControl.StateValue = state == .off ? .off : .on
            if state != normalized {
                state = normalized
                return
            }
            guard oldValue != state else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override var intrinsicContentSize: NSSize {
        let font = resolvedFont
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(
            width: indicatorSize + indicatorTextSpacing + textWidth,
            height: max(indicatorSize, ceil(font.ascender - font.descender + font.leading))
        )
    }

    init(style: Style,
         title: String,
         target: AnyObject?,
         action: Selector?) {
        self.style = style
        self.title = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        style = .checkbox
        title = ""
        super.init(coder: coder)
        configureAccessibility()
    }

    static func checkbox(title: String,
                         target: AnyObject? = nil,
                         action: Selector? = nil) -> RimeFixedAccentChoiceButton {
        RimeFixedAccentChoiceButton(
            style: .checkbox,
            title: title,
            target: target,
            action: action
        )
    }

    static func radio(title: String,
                      target: AnyObject? = nil,
                      action: Selector? = nil) -> RimeFixedAccentChoiceButton {
        RimeFixedAccentChoiceButton(
            style: .radio,
            title: title,
            target: target,
            action: action
        )
    }

    override func sizeThatFits(_ size: NSSize) -> NSSize { intrinsicContentSize }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)

        var releasedInside = bounds.contains(convert(event.locationInWindow, from: nil))
        var sawMouseUp = false
        isHighlighted = releasedInside
        needsDisplay = true

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            releasedInside = bounds.contains(convert(next.locationInWindow, from: nil))
            isHighlighted = releasedInside
            needsDisplay = true
            if next.type == .leftMouseUp {
                sawMouseUp = true
                break
            }
        }

        isHighlighted = false
        needsDisplay = true
        if sawMouseUp, releasedInside { activate() }
    }

    override func keyDown(with event: NSEvent) {
        let shortcutModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift,
        ])
        guard event.charactersIgnoringModifiers == " ", shortcutModifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        guard isEnabled, !event.isARepeat else { return }
        activate()
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        activate()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: state == .on)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let indicatorRect = NSRect(
            x: 0,
            y: floor((bounds.height - indicatorSize) / 2),
            width: indicatorSize,
            height: indicatorSize
        )
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.76 : 1) : 0.45

        switch style {
        case .checkbox:
            drawCheckbox(in: indicatorRect, alpha: alpha)
        case .radio:
            drawRadio(in: indicatorRect, alpha: alpha)
        }

        let textRect = NSRect(
            x: indicatorRect.maxX + indicatorTextSpacing,
            y: 0,
            width: max(0, bounds.maxX - indicatorRect.maxX - indicatorTextSpacing),
            height: bounds.height
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        let textColor = isEnabled ? RimeUI.textPrimary : RimeUI.textMuted
        (title as NSString).draw(
            in: verticallyCenteredTextRect(textRect),
            withAttributes: [
                .font: resolvedFont,
                .foregroundColor: textColor.withAlphaComponent(alpha),
                .paragraphStyle: paragraph,
            ]
        )

        if window?.firstResponder === self {
            let focusRect = bounds.insetBy(dx: -2, dy: -2)
            RimeUI.accentGreen.withAlphaComponent(0.72).setStroke()
            let focus = NSBezierPath(roundedRect: focusRect, xRadius: 4, yRadius: 4)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private var resolvedFont: NSFont {
        font ?? .systemFont(ofSize: NSFont.systemFontSize)
    }

    private var indicatorSize: CGFloat {
        switch controlSize {
        case .mini: return 12
        case .small: return 14
        default: return 16
        }
    }

    private var indicatorTextSpacing: CGFloat { 6 }

    private func verticallyCenteredTextRect(_ rect: NSRect) -> NSRect {
        let font = resolvedFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return NSRect(
            x: rect.minX,
            y: floor(rect.midY - lineHeight / 2),
            width: rect.width,
            height: lineHeight
        )
    }

    private func drawCheckbox(in rect: NSRect, alpha: CGFloat) {
        let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        let isOn = state == .on
        (isOn ? RimeUI.accentGreen : RimeUI.surface3)
            .withAlphaComponent(alpha)
            .setFill()
        box.fill()
        (isOn ? RimeUI.accentGreen : RimeUI.borderStrong)
            .withAlphaComponent(alpha)
            .setStroke()
        box.lineWidth = 1
        box.stroke()

        guard isOn else { return }
        let check = NSBezierPath()
        check.move(to: NSPoint(x: rect.minX + rect.width * 0.23, y: rect.midY))
        check.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.29))
        check.line(to: NSPoint(x: rect.minX + rect.width * 0.79, y: rect.minY + rect.height * 0.73))
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.lineWidth = max(1.5, rect.width * 0.12)
        RimeUI.accentForegroundColor.withAlphaComponent(alpha).setStroke()
        check.stroke()
    }

    private func drawRadio(in rect: NSRect, alpha: CGFloat) {
        let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        RimeUI.surface3.withAlphaComponent(alpha).setFill()
        outer.fill()
        (state == .on ? RimeUI.accentGreen : RimeUI.borderStrong)
            .withAlphaComponent(alpha)
            .setStroke()
        outer.lineWidth = state == .on ? 1.5 : 1
        outer.stroke()

        guard state == .on else { return }
        RimeUI.accentGreen.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)).fill()
    }

    private func activate() {
        switch style {
        case .checkbox:
            state = state == .off ? .on : .off
        case .radio:
            state = .on
        }
        _ = sendAction(action, to: target)
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(style == .checkbox ? .checkBox : .radioButton)
        setAccessibilityLabel(title)
    }
}
