import Cocoa
import QuartzCore

/// Briefly marks the trusted screen-space caret that Buffer is associated with.
///
/// This controller is deliberately presentation-only. Its caller owns focus
/// authority and supplies an already validated caret rectangle; the cue never
/// discovers targets, observes other applications, or synthesizes input.
final class TargetAssociationCueController {
    private enum Metrics {
        static let width: CGFloat = 32
        static let minimumHeight: CGFloat = 28
        static let maximumHeight: CGFloat = 42
        static let verticalCaretPadding: CGFloat = 12
        static let screenInset: CGFloat = 1

        /// The complete appearance and retirement take about 700 ms, keeping
        /// the association visible long enough to notice without persisting
        /// over the host's text.
        static let presentationDuration: TimeInterval = 0.70
    }

    private let cueView: TargetAssociationCueView
    private let panel: TargetAssociationCuePanel
    private var visibilityGeneration: UInt64 = 0
    private var pendingHide: DispatchWorkItem?

    init() {
        dispatchPrecondition(condition: .onQueue(.main))

        cueView = TargetAssociationCueView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Metrics.width,
                height: Metrics.minimumHeight
            )
        )
        panel = TargetAssociationCuePanel(
            contentRect: cueView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets the level, so establish the final policy
        // afterwards just like the candidate panel does.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.contentView = cueView
    }

    deinit {
        pendingHide?.cancel()
    }

    /// Presents a click-through bracket around an already trusted caret.
    ///
    /// - Parameters:
    ///   - caretScreenRect: Caret bounds in AppKit screen coordinates.
    ///   - accentColor: The active RimeUI accent selected by the caller.
    ///   - level: The exact host-aware candidate level selected by the caller.
    ///   - reduceMotion: The current accessibility Reduce Motion preference.
    /// - Returns: `false` when the rectangle is invalid or outside every screen.
    @discardableResult
    func show(caretScreenRect: NSRect,
              accentColor: NSColor,
              level: NSWindow.Level,
              reduceMotion: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let frame = cueFrame(for: caretScreenRect) else {
            hide()
            return false
        }

        let generation = beginNewGeneration()
        cueView.layer?.removeAllAnimations()
        panel.alphaValue = 1
        panel.appearance = RimeUI.appKitAppearance
        cueView.accentColor = accentColor
        cueView.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)
        guard visibilityGeneration == generation else { return false }
        panel.level = level
        guard visibilityGeneration == generation else { return false }

        // Retire stale ordering from another Space before reusing the panel.
        if panel.isVisible, !panel.isOnActiveSpace {
            panel.orderOut(nil)
            guard visibilityGeneration == generation else { return false }
        }
        panel.orderFrontRegardless()
        guard visibilityGeneration == generation else { return false }
        animateCue(reduceMotion: reduceMotion)
        guard visibilityGeneration == generation else { return false }

        let hide = DispatchWorkItem { [weak self] in
            guard let self,
                  self.visibilityGeneration == generation else { return }
            self.pendingHide = nil
            self.cueView.layer?.removeAllAnimations()
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Metrics.presentationDuration,
            execute: hide
        )
        return true
    }

    /// Removes the cue synchronously and invalidates every scheduled retirement.
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))

        _ = beginNewGeneration()
        cueView.layer?.removeAllAnimations()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// Debug CLI contract probe. Keeping this assertion beside the concrete
    /// panel makes focus-stealing regressions observable without presenting it.
    func hasSafeWindowContractForSmokeTest() -> Bool {
        panel.styleMask.contains(.nonactivatingPanel)
            && !panel.canBecomeKey
            && !panel.canBecomeMain
            && panel.ignoresMouseEvents
            && !panel.hidesOnDeactivate
            && panel.collectionBehavior.contains(.ignoresCycle)
            && panel.collectionBehavior.contains(.fullScreenAuxiliary)
    }

    private func beginNewGeneration() -> UInt64 {
        pendingHide?.cancel()
        pendingHide = nil
        visibilityGeneration &+= 1
        return visibilityGeneration
    }

    private func cueFrame(for caretRect: NSRect) -> NSRect? {
        let values = [
            caretRect.origin.x,
            caretRect.origin.y,
            caretRect.size.width,
            caretRect.size.height,
        ]
        guard values.allSatisfy(\.isFinite),
              caretRect.width >= 0,
              caretRect.height > 0 else { return nil }

        let target = NSPoint(x: caretRect.midX, y: caretRect.midY)
        let targetProbe = NSRect(
            x: target.x - 0.5,
            y: target.y - 0.5,
            width: 1,
            height: 1
        )
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.intersects(targetProbe)
        }) else { return nil }

        let height = min(
            Metrics.maximumHeight,
            max(Metrics.minimumHeight, caretRect.height + Metrics.verticalCaretPadding)
        )
        let size = NSSize(width: Metrics.width, height: height)
        // Keep the complete cue out of the menu bar and Dock on ordinary
        // Spaces. In full-screen Spaces AppKit's visibleFrame already expands
        // to the usable full-screen surface.
        let safeFrame = screen.visibleFrame.insetBy(
            dx: Metrics.screenInset,
            dy: Metrics.screenInset
        )
        let proposedOrigin = NSPoint(
            x: target.x - size.width / 2,
            y: target.y - size.height / 2
        )
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, safeFrame.minX), safeFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, safeFrame.minY), safeFrame.maxY - size.height)
        )
        return NSRect(origin: origin, size: size).integral
    }

    private func animateCue(reduceMotion: Bool) {
        guard let layer = cueView.layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.setAffineTransform(.identity)
        guard !reduceMotion else { return }
        // Match the animation's terminal state in the model layer. If the
        // main queue is briefly busy when the 700ms retirement fires, Core
        // Animation must not reveal a fully opaque cue again.
        layer.opacity = 0

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.12, 0.74, 1]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.86, 1.06, 1, 1]
        scale.keyTimes = [0, 0.16, 0.32, 1]

        let group = CAAnimationGroup()
        group.animations = [opacity, scale]
        group.duration = Metrics.presentationDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "target-association-cue")
    }
}

private final class TargetAssociationCuePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TargetAssociationCueView: NSView {
    var accentColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bracketRect = bounds.insetBy(dx: 4, dy: 4)
        guard bracketRect.width > 12, bracketRect.height > 10 else { return }

        let path = NSBezierPath()
        let capLength: CGFloat = 5
        let cornerRadius: CGFloat = 3
        appendLeftBracket(
            to: path,
            rect: bracketRect,
            capLength: capLength,
            cornerRadius: cornerRadius
        )
        appendRightBracket(
            to: path,
            rect: bracketRect,
            capLength: capLength,
            cornerRadius: cornerRadius
        )
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // The broad translucent stroke keeps the thin RimeUI accent readable
        // across both light and dark host content without adding an opaque card.
        accentColor.withAlphaComponent(0.24).setStroke()
        path.lineWidth = 6
        path.stroke()

        accentColor.withAlphaComponent(0.96).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func appendLeftBracket(to path: NSBezierPath,
                                   rect: NSRect,
                                   capLength: CGFloat,
                                   cornerRadius: CGFloat) {
        let x = rect.minX
        path.move(to: NSPoint(x: x + capLength, y: rect.maxY))
        path.line(to: NSPoint(x: x + cornerRadius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: x, y: rect.maxY - cornerRadius),
            controlPoint1: NSPoint(x: x + 1, y: rect.maxY),
            controlPoint2: NSPoint(x: x, y: rect.maxY - 1)
        )
        path.line(to: NSPoint(x: x, y: rect.minY + cornerRadius))
        path.curve(
            to: NSPoint(x: x + cornerRadius, y: rect.minY),
            controlPoint1: NSPoint(x: x, y: rect.minY + 1),
            controlPoint2: NSPoint(x: x + 1, y: rect.minY)
        )
        path.line(to: NSPoint(x: x + capLength, y: rect.minY))
    }

    private func appendRightBracket(to path: NSBezierPath,
                                    rect: NSRect,
                                    capLength: CGFloat,
                                    cornerRadius: CGFloat) {
        let x = rect.maxX
        path.move(to: NSPoint(x: x - capLength, y: rect.maxY))
        path.line(to: NSPoint(x: x - cornerRadius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: x, y: rect.maxY - cornerRadius),
            controlPoint1: NSPoint(x: x - 1, y: rect.maxY),
            controlPoint2: NSPoint(x: x, y: rect.maxY - 1)
        )
        path.line(to: NSPoint(x: x, y: rect.minY + cornerRadius))
        path.curve(
            to: NSPoint(x: x - cornerRadius, y: rect.minY),
            controlPoint1: NSPoint(x: x, y: rect.minY + 1),
            controlPoint2: NSPoint(x: x - 1, y: rect.minY)
        )
        path.line(to: NSPoint(x: x - capLength, y: rect.minY))
    }
}
