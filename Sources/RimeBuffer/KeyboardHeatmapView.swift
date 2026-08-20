import Cocoa

/// Pure conversion used by the view and the theme smoke test. Keeping the
/// foreground decision in integer sRGB makes it independent of the current
/// macOS appearance and user accent preference.
enum KeyboardHeatmapColorRules {
    static func sRGBHex(red: Double, green: Double, blue: Double) -> UInt32 {
        func byte(_ value: Double) -> UInt32 {
            UInt32((min(1, max(0, value)) * 255).rounded())
        }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    static func preferredForeground(background: UInt32) -> UInt32 {
        RimeColorContrast.preferredForeground(background: background)
    }
}

final class KeyboardHeatmapView: NSView {
    var snapshot: KeyFrequencySnapshot = .empty {
        didSet {
            needsDisplay = true
            updateHover(at: lastMousePoint)
        }
    }

    private let layout = KeyboardLayout.macANSI
    private var tracking: NSTrackingArea?
    private var hoveredKeyId: String?
    private var lastMousePoint: NSPoint?

    override var intrinsicContentSize: NSSize {
        // The keyboard scales to whatever width its settings page provides.
        // Advertising the old 820pt width made Auto Layout enlarge the whole
        // settings window instead of fitting the heatmap into the content area.
        NSSize(width: NSView.noIntrinsicMetric, height: 260)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredKeyId = nil
        lastMousePoint = nil
        toolTip = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()
        let panel = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        )
        RimeUI.surface2.withAlphaComponent(0.66).setFill()
        panel.fill()
        RimeUI.borderStrong.withAlphaComponent(0.72).setStroke()
        panel.lineWidth = 1
        panel.setLineDash([4, 3], count: 2, phase: 0)
        panel.stroke()

        let metrics = layoutMetrics()
        for key in layout.keys {
            drawKey(key, rect: keyRect(for: key, metrics: metrics))
        }
    }

    private func drawKey(_ key: KeyboardKeySpec, rect: NSRect) {
        let count = snapshot.counts[key.keyId] ?? 0
        let fraction = snapshot.maxCount > 0 ? CGFloat(count) / CGFloat(snapshot.maxCount) : 0
        let path = NSBezierPath(roundedRect: rect, xRadius: min(7, rect.height * 0.22), yRadius: min(7, rect.height * 0.22))

        let fill = keyFill(fraction: fraction, highlighted: hoveredKeyId == key.keyId)
        fill.setFill()
        path.fill()
        let foreground = labelColor(background: fill)

        RimeUI.border.withAlphaComponent(RimeUI.isDark ? 0.75 : 0.55).setStroke()
        path.lineWidth = hoveredKeyId == key.keyId ? 1.6 : 1
        path.stroke()

        let labelFontSize: CGFloat = rect.height < 24 ? 9 : 11
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: labelFontSize, weight: .semibold),
            .foregroundColor: foreground
        ]
        drawCentered(key.label, in: rect.insetBy(dx: 2, dy: rect.height * 0.28), attributes: labelAttrs)

        if count > 0, rect.width >= 28, rect.height >= 26 {
            let countAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: foreground
            ]
            let value = "\(count)" as NSString
            let size = value.size(withAttributes: countAttrs)
            let countRect = NSRect(
                x: rect.midX - size.width / 2,
                y: rect.minY + 4,
                width: size.width,
                height: size.height
            )
            value.draw(in: countRect, withAttributes: countAttrs)
        }
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let value = text as NSString
        let size = value.size(withAttributes: attributes)
        let drawRect = NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        value.draw(in: drawRect, withAttributes: attributes)
    }

    private func updateHover(at point: NSPoint?) {
        lastMousePoint = point
        guard let point else { return }
        let metrics = layoutMetrics()
        let key = layout.keys.first { keyRect(for: $0, metrics: metrics).contains(point) }
        hoveredKeyId = key?.keyId
        if let key {
            let count = snapshot.counts[key.keyId] ?? 0
            let ratio = snapshot.total > 0 ? Double(count) / Double(snapshot.total) * 100 : 0
            toolTip = "\(key.label) · \(count) 次 · \(String(format: "%.1f", ratio))%"
        } else {
            toolTip = nil
        }
        needsDisplay = true
    }

    private struct LayoutMetrics {
        let scale: CGFloat
        let origin: CGPoint
    }

    private func layoutMetrics() -> LayoutMetrics {
        let padding: CGFloat = 16
        let available = bounds.insetBy(dx: padding, dy: padding)
        let scale = min(
            available.width / layout.size.width,
            available.height / layout.size.height
        )
        let width = layout.size.width * scale
        let height = layout.size.height * scale
        return LayoutMetrics(
            scale: scale,
            origin: CGPoint(x: available.midX - width / 2, y: available.midY - height / 2)
        )
    }

    private func keyRect(for key: KeyboardKeySpec, metrics: LayoutMetrics) -> NSRect {
        NSRect(
            x: metrics.origin.x + key.frame.minX * metrics.scale,
            y: metrics.origin.y + (layout.size.height - key.frame.maxY) * metrics.scale,
            width: key.frame.width * metrics.scale,
            height: key.frame.height * metrics.scale
        ).insetBy(dx: 2, dy: 2)
    }

    private func keyFill(fraction: CGFloat, highlighted: Bool) -> NSColor {
        let base = RimeUI.surface2
        guard fraction > 0 else {
            return highlighted
                ? base.blended(withFraction: 0.20, of: RimeUI.accentGreen) ?? base
                : base
        }
        let eased = min(1, max(0.16, sqrt(fraction)))
        let mixed = base.blended(withFraction: eased * 0.86,
                                 of: RimeUI.accentGreen) ?? RimeUI.accentGreen
        return highlighted ? mixed.highlight(withLevel: 0.12) ?? mixed : mixed
    }

    private func labelColor(background: NSColor) -> NSColor {
        guard let sRGB = background.usingColorSpace(.sRGB) else {
            let fallback = KeyboardHeatmapColorRules.preferredForeground(
                background: RimeUI.palette.surfaceSecondary
            )
            return RimeUI.color(fallback)
        }
        let backgroundHex = KeyboardHeatmapColorRules.sRGBHex(
            red: Double(sRGB.redComponent),
            green: Double(sRGB.greenComponent),
            blue: Double(sRGB.blueComponent)
        )
        return RimeUI.color(
            KeyboardHeatmapColorRules.preferredForeground(background: backgroundHex)
        )
    }
}
