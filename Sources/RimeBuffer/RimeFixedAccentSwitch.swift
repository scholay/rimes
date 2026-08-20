import AppKit

/// A product-owned switch that keeps the selected theme accent instead of
/// inheriting the user's macOS accent preference. It deliberately subclasses `NSControl`:
/// `NSSwitch` renders through private AppKit internals and does not call an
/// overridden `draw(_:)`, so it cannot be reliably recolored.
class RimeFixedAccentSwitch: NSControl {
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

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }
    override var acceptsFirstResponder: Bool { isEnabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func sizeThatFits(_ size: NSSize) -> NSSize { intrinsicContentSize }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        guard let window else {
            activate()
            return
        }

        var pointerInside = bounds.contains(
            convert(event.locationInWindow, from: nil)
        )
        isHighlighted = pointerInside
        needsDisplay = true
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) {
            pointerInside = bounds.contains(
                convert(next.locationInWindow, from: nil)
            )
            isHighlighted = pointerInside
            needsDisplay = true
            guard next.type == .leftMouseUp else { continue }
            if pointerInside { activate() }
            break
        }
        isHighlighted = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let conflictingModifiers: NSEvent.ModifierFlags = [
            .command, .control, .option,
        ]
        if isEnabled,
           !event.isARepeat,
           event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(conflictingModifiers).isEmpty {
            activate()
        } else {
            super.keyDown(with: event)
        }
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
        NSNumber(value: state != .off)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let trackHeight: CGFloat = 20
        let trackWidth: CGFloat = 36
        let trackRect = NSRect(
            x: bounds.midX - trackWidth / 2,
            y: bounds.midY - trackHeight / 2,
            width: trackWidth,
            height: trackHeight
        )
        let track = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackHeight / 2,
            yRadius: trackHeight / 2
        )
        let isOn = state != .off
        let trackColor = isOn ? RimeUI.accentGreen : RimeUI.surface3
        let enabledAlpha: CGFloat = isEnabled ? (isHighlighted ? 0.78 : 1) : 0.48
        trackColor.withAlphaComponent(enabledAlpha).setFill()
        track.fill()

        (isOn ? RimeUI.accentTextColor : RimeUI.border)
            .withAlphaComponent(isEnabled ? 0.78 : 0.30)
            .setStroke()
        track.lineWidth = 1
        track.stroke()

        let inset: CGFloat = 2
        let knobSize = trackHeight - inset * 2
        let knobX = isOn
            ? trackRect.maxX - inset - knobSize
            : trackRect.minX + inset
        let knobRect = NSRect(
            x: knobX,
            y: trackRect.minY + inset,
            width: knobSize,
            height: knobSize
        )
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.70).setFill()
        NSBezierPath(ovalIn: knobRect).fill()

        if window?.firstResponder === self {
            RimeUI.accentGreen.withAlphaComponent(0.72).setStroke()
            let focus = NSBezierPath(
                roundedRect: trackRect.insetBy(dx: -2, dy: -2),
                xRadius: trackHeight / 2 + 2,
                yRadius: trackHeight / 2 + 2
            )
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    private func activate() {
        state = state == .off ? .on : .off
        _ = sendAction(action, to: target)
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilitySubrole(.switch)
    }
}
