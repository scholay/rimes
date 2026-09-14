import AppKit

enum RimePointingHandCursorKind: Equatable {
    case arrow
    case pointingHand
}

/// Shared enabled-aware cursor policy for product-owned AppKit controls.
/// Settings uses a key window, while the Buffer and Clipboard surfaces may
/// additionally set the same cursor from their active-always tracking areas.
enum RimePointingHandCursorRules {
    static func kind(enabled: Bool) -> RimePointingHandCursorKind {
        enabled ? .pointingHand : .arrow
    }

    static func cursor(enabled: Bool) -> NSCursor {
        switch kind(enabled: enabled) {
        case .arrow: return .arrow
        case .pointingHand: return .pointingHand
        }
    }

    static func updateTrackingArea(
        _ current: inout NSTrackingArea?,
        for view: NSView,
        options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect,
        ]
    ) {
        if let current { view.removeTrackingArea(current) }
        let replacement = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: view,
            userInfo: nil
        )
        view.addTrackingArea(replacement)
        current = replacement
    }

    static func mouseEntered(enabled: Bool) {
        cursor(enabled: enabled).set()
    }

    static func mouseExited() {
        NSCursor.arrow.set()
    }

    static func enabledDidChange(
        for view: NSView,
        pointerInside: Bool,
        enabled: Bool
    ) {
        view.window?.invalidateCursorRects(for: view)
        if pointerInside { mouseEntered(enabled: enabled) }
    }

    static func resetCursorRect(for view: NSView, enabled: Bool) {
        view.addCursorRect(view.bounds, cursor: cursor(enabled: enabled))
    }
}

/// Native button behavior with one product-owned, enabled-aware cursor area.
/// Keep this shared rather than defining page-local button subclasses so views
/// embedded in Settings retain the same affordance as controls built by the
/// Settings shell itself.
class RimePointingHandButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false

    var pointingHandTrackingOptions: NSTrackingArea.Options {
        [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    }

    override var isEnabled: Bool {
        didSet {
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isEnabled
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self,
            options: pointingHandTrackingOptions
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isEnabled
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(enabled: isEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }
}

/// Segmented controls are buttons from the user's point of view but do not
/// inherit from `NSButton`, so give them the same single tracking-area policy.
class RimePointingHandSegmentedControl: NSSegmentedControl {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false

    override var isEnabled: Bool {
        didSet {
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isEnabled
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isEnabled
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(enabled: isEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }
}

/// A product-owned switch that keeps the selected theme accent instead of
/// inheriting the user's macOS accent preference. It deliberately subclasses `NSControl`:
/// `NSSwitch` renders through private AppKit internals and does not call an
/// overridden `draw(_:)`, so it cannot be reliably recolored.
class RimeFixedAccentSwitch: NSControl {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerInside = false

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
        didSet {
            needsDisplay = true
            RimePointingHandCursorRules.enabledDidChange(
                for: self,
                pointerInside: pointerInside,
                enabled: isEnabled
            )
        }
    }

    /// The toolbar variant: a mini track that sits beside 22pt icon buttons
    /// and, like them, takes the click without taking keyboard focus.
    var isCompact = false {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var trackSize: NSSize {
        isCompact ? NSSize(width: 26, height: 15) : NSSize(width: 36, height: 20)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: trackSize.width + 2, height: trackSize.height + 2)
    }
    override var acceptsFirstResponder: Bool { isEnabled && !isCompact }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isCompact }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    override func sizeThatFits(_ size: NSSize) -> NSSize { intrinsicContentSize }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        RimePointingHandCursorRules.updateTrackingArea(
            &pointerTrackingArea,
            for: self
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        RimePointingHandCursorRules.resetCursorRect(
            for: self,
            enabled: isEnabled
        )
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerInside = true
        RimePointingHandCursorRules.mouseEntered(enabled: isEnabled)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        RimePointingHandCursorRules.mouseExited()
        super.mouseExited(with: event)
    }

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
        let trackHeight = trackSize.height
        let trackWidth = trackSize.width
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
