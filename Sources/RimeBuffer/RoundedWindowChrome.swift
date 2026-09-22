import AppKit

/// Custom window chrome needs both a transparent backing window and clipped
/// content. Rounding just a layer leaves NSWindow's rectangular fill visible.
enum RoundedWindowChrome {
    static let radius: CGFloat = 14

    static func apply(to window: NSWindow, radius: CGFloat = radius) {
        window.isOpaque = false
        window.backgroundColor = .clear
        if let content = window.contentView { clip(content, radius: radius) }
        window.invalidateShadow()
    }

    static func clip(_ view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = radius > 0
    }

    /// Visual-effect materials are composited separately from child layers.
    /// AppKit needs its own mask as well as layer clipping for the subviews.
    static func maskMaterial(_ view: NSVisualEffectView, radius: CGFloat) {
        clip(view, radius: radius)
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
    }
}
