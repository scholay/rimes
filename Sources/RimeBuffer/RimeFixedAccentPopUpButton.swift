import AppKit

/// Native popup behavior with a theme-owned disclosure treatment. AppKit's
/// `bezelColor` is ignored by the standard popup cell on supported macOS
/// versions, so drawing the chevrons here is the reliable way to avoid the
/// user's system accent leaking into RIMES settings.
class RimeFixedAccentPopUpButton: NSPopUpButton {
    private static let indicatorWidth: CGFloat = 22

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width >= Self.indicatorWidth,
              bounds.height >= 14 else { return }

        let indicatorRect = NSRect(
            x: bounds.maxX - Self.indicatorWidth,
            y: bounds.minY + 2,
            width: Self.indicatorWidth - 2,
            height: bounds.height - 4
        )
        let alpha: CGFloat = isEnabled ? 1 : 0.46
        RimeUI.accentGreen.withAlphaComponent(alpha).setFill()
        NSBezierPath(
            roundedRect: indicatorRect,
            xRadius: min(6, indicatorRect.height / 2),
            yRadius: min(6, indicatorRect.height / 2)
        ).fill()

        let foreground = RimeUI.accentForegroundColor.withAlphaComponent(alpha)
        foreground.setStroke()
        drawChevron(centerY: indicatorRect.midY + 3, pointsUp: true)
        drawChevron(centerY: indicatorRect.midY - 3, pointsUp: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawChevron(centerY: CGFloat, pointsUp: Bool) {
        let halfWidth: CGFloat = 3
        let height: CGFloat = 2.4
        let path = NSBezierPath()
        if pointsUp {
            path.move(to: NSPoint(x: bounds.maxX - 13 - halfWidth,
                                  y: centerY - height / 2))
            path.line(to: NSPoint(x: bounds.maxX - 13,
                                  y: centerY + height / 2))
            path.line(to: NSPoint(x: bounds.maxX - 13 + halfWidth,
                                  y: centerY - height / 2))
        } else {
            path.move(to: NSPoint(x: bounds.maxX - 13 - halfWidth,
                                  y: centerY + height / 2))
            path.line(to: NSPoint(x: bounds.maxX - 13,
                                  y: centerY - height / 2))
            path.line(to: NSPoint(x: bounds.maxX - 13 + halfWidth,
                                  y: centerY + height / 2))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
