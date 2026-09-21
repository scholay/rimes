import AppKit

/// A capture owns one panel for its entire visible lifetime. Store refreshes
/// replace its value/preview, not the window, stacking identity or close timer.
final class CaptureResultPanel: CapturePanel {
    var record: CaptureRecord
    let preview = CaptureDragImageView()
    var previewLoad: Operation?
    private(set) var previewGeneration = UUID()
    private(set) var dismissed = false
    let previewStatus = CaptureUI.label("正在载入预览…", size: 12)

    init(record: CaptureRecord, size: NSSize) {
        self.record = record
        super.init(size: size, key: false)
    }

    func beginPreview() -> UUID {
        previewLoad?.cancel()
        previewGeneration = UUID()
        // A changed render may contain new redactions. Do not retain an old
        // preview while loading it, or fall back to the unredacted original.
        preview.image = nil
        preview.needsDisplay = true
        previewStatus.stringValue = "正在载入预览…"
        previewStatus.isHidden = false
        return previewGeneration
    }

    func acceptPreview(_ image: NSImage?, generation: UUID) {
        guard !dismissed, generation == previewGeneration else { return }
        preview.image = image
        previewStatus.stringValue = "预览不可用，可打开查看"
        previewStatus.isHidden = image != nil
        preview.needsDisplay = true
        viewsNeedDisplay = true
        displayIfNeeded()
    }

    override func close() {
        guard !dismissed else { return }
        dismissed = true
        previewGeneration = UUID()
        previewLoad?.cancel()
        super.close()
    }
}

enum CaptureOverlayLayout {
    /// Newest-first slots; overflow remains owned and is revealed as slots
    /// become free. Never leave excess windows at stale overlapping frames.
    static func frames(sizes: [CGSize], visible: CGRect, onLeft: Bool) -> [CGRect] {
        guard visible.minX.isFinite, visible.minY.isFinite,
              visible.width.isFinite, visible.height.isFinite,
              visible.width > 0, visible.height > 0 else { return [] }
        let margin: CGFloat = 18
        var y = visible.minY + margin
        var result: [CGRect] = []
        for size in sizes {
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  size.width <= visible.width - 2 * margin,
                  y + size.height <= visible.maxY - margin else { break }
            let x = onLeft ? visible.minX + margin : visible.maxX - size.width - margin
            result.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            y += size.height + 8
        }
        return result
    }
}
