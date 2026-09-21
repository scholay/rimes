import AppKit

@MainActor
enum CaptureOverlaySmoke {
    static func run(root: URL) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("overlay: " + message) }
        }
        func wait(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !ready(), Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            try require(ready(), "asynchronous preview/refresh timed out")
        }
        let visible = CGRect(x: -1200, y: 40, width: 1000, height: 400)
        let sizes = Array(repeating: CGSize(width: 220, height: 128), count: 10)
        for onLeft in [true, false] {
            let frames = CaptureOverlayLayout.frames(sizes: sizes, visible: visible, onLeft: onLeft)
            try require(frames.count == 2, "overflow must have no stale slot")
            try require(frames.allSatisfy { visible.contains($0) }, "slots stay on screen")
            try require(frames[0].minY == visible.minY + 18 && !frames[0].intersects(frames[1]), "bottom anchored, nonoverlapping")
            try require(frames[0].minX == (onLeft ? visible.minX + 18 : visible.maxX - 238), "left/right edge")
        }
        try require(CaptureOverlayLayout.frames(sizes: sizes, visible: .zero, onLeft: true).isEmpty, "zero screen")
        let store = try CaptureStore(root: root)
        let coordinator = CaptureCoordinator(isolatedStore: store)
        defer { Array(coordinator.overlays.values).forEach { $0.close() } }
        let image = try CaptureSmoke.fixture(width: 480, height: 900)
        let records = try (0..<3).map { _ in try store.importImage(image) }
        records.forEach { coordinator.showOverlay($0) }
        try require(coordinator.overlays.count == 3, "three result windows")
        let panels = records.compactMap { coordinator.overlays[$0.id] }
        try wait { panels.allSatisfy { $0.preview.image != nil } }
        let frames = panels.map(\.frame)
        try require(Set(frames.map { $0.minY }).count == 3, "three distinct stack positions")
        let order = coordinator.overlayOrder
        let generations = panels.map(\.previewGeneration)
        func refresh() throws {
            var done = false
            coordinator.refreshVisibleAssets { done = true }
            try wait { done }
        }
        for _ in 0..<5 { try refresh() }
        try require(coordinator.overlayOrder == order && panels.map(\.frame) == frames, "refresh preserves order and coordinates")
        try require(records.enumerated().allSatisfy { coordinator.overlays[$0.element.id] === panels[$0.offset] }, "refresh preserves window identity")
        try require(panels.map(\.previewGeneration) == generations, "metadata refresh must not restart previews")
        var revised = records[0]; revised.title = "Synthetic title"
        try store.update(revised)
        coordinator.setResultOverlaysSuspended(true)
        try refresh()
        try require(panels.allSatisfy { !$0.isVisible }, "refresh must not reveal hidden capture results")
        try require(panels[0].record.title == revised.title && panels[0].preview.image != nil, "metadata updates without blanking image")
        coordinator.setResultOverlaysSuspended(false)
        try require(panels.map(\.frame) == frames && panels.allSatisfy(\.isVisible), "restore uses the same stack")
        // Lock/wake, secure input and capture suspension must not strand cards
        // or allow one unprotect signal to bypass another active protection.
        coordinator.setResultOverlaysSuspended(true)
        coordinator.setProtection(.locked, active: true)
        coordinator.setProtection(.sleeping, active: true)
        coordinator.setProtection(.sleeping, active: false)
        try require(panels.allSatisfy { !$0.isVisible }, "wake while locked stays hidden")
        coordinator.setProtection(.secureInput, active: true)
        coordinator.setProtection(.locked, active: false)
        try require(panels.allSatisfy { !$0.isVisible }, "unlock while secure stays hidden")
        coordinator.setProtection(.secureInput, active: false)
        try require(panels.allSatisfy(\.isVisible), "final unprotect restores cards and clears abandoned capture suspension")

        coordinator.showText("disposable recovery fixture")
        guard let textPanel = NSApp.windows.compactMap({ $0 as? CapturePanel }).first(where: {
            $0.isVisible && $0.contentView?.subviews.contains(where: { $0 is NSStackView }) == true
        }) else { throw CaptureError.message("overlay: recovery fixture panel missing") }
        coordinator.setProtection(.inactive, active: true)
        try require(!textPanel.isVisible, "managed panels hide during session transition")
        coordinator.setProtection(.inactive, active: false)
        try require(textPanel.isVisible, "previously visible managed panel restores")
        coordinator.setProtection(.locked, active: true)
        textPanel.close()
        coordinator.setProtection(.locked, active: false)
        try require(!textPanel.isVisible, "closed panel is not resurrected on unlock")

        // No ScreenCaptureKit call is reached: cancel the waiting task before
        // its first suspension ends, then let late task cleanup run.
        coordinator.begin("area", delay: 30)
        try require(coordinator.preparingCapture && coordinator.countdown?.isVisible == true, "delay has visible cancellation UI")
        coordinator.countdown?.cancelOperation(nil)
        try require(!coordinator.preparingCapture && coordinator.countdown == nil && panels.allSatisfy(\.isVisible), "Escape cancels countdown and restores cards")
        coordinator.begin("area", delay: 30)
        coordinator.begin("area")
        try require(!coordinator.preparingCapture && coordinator.countdown == nil, "repeated shortcut cancels countdown")
        coordinator.begin("area", delay: 30)
        coordinator.setProtection(.locked, active: true)
        try require(!coordinator.preparingCapture && coordinator.countdown == nil && panels.allSatisfy { !$0.isVisible }, "lock cancels pending delay")
        coordinator.setProtection(.locked, active: false)
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        try require(!coordinator.preparingCapture && panels.allSatisfy(\.isVisible), "cancelled tasks cannot strand or restart capture")
        let bottom = panels[2].frame.minY
        panels[2].close()
        try require(coordinator.overlays.count == 2 && panels[1].frame.minY == bottom, "closing bottom immediately fills the gap")
        let panel = panels[0]
        try require(!panel.preview.fillsFrame && panel.preview.imageScaling == .scaleProportionallyUpOrDown, "preview fits the entire image")
        // A new rendered revision must update both the image and drag payload,
        // including when its thumbnail is missing. Never fall back to source.
        revised.output = "revised.png"
        revised.thumbnail = "missing-thumbnail.png"
        try CaptureImageIO.write(try CaptureSmoke.fixture(width: 180, height: 120),
                                 to: store.directory(revised.id).appendingPathComponent(revised.output))
        try store.update(revised)
        let priorGeneration = panel.previewGeneration
        try refresh()
        try wait { panel.preview.image != nil }
        try require(panel.previewGeneration != priorGeneration && panel.preview.image?.size == CGSize(width: 180, height: 120), "missing thumbnail falls back to current rendered output")
        try require(panel.preview.file == store.url(revised), "drag payload follows current render")
        let stale = panel.previewGeneration
        let current = panel.beginPreview()
        panel.acceptPreview(NSImage(cgImage: image, size: .zero), generation: stale)
        try require(panel.preview.image == nil, "stale decode cannot restore old content")
        panel.acceptPreview(nil, generation: current)
        try require(!panel.previewStatus.isHidden, "failure has an explicit placeholder")
        coordinator.setResultOverlaysSuspended(true)
        panel.close()
        try refresh()
        coordinator.setResultOverlaysSuspended(false)
        panel.acceptPreview(NSImage(cgImage: image, size: .zero), generation: current)
        try require(panel.preview.image == nil && !panel.isVisible, "late decode cannot resurrect a dismissed result")
        // Exercise the real asynchronous copy path with disposable assets and
        // a private pasteboard, never the user's clipboard.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copyRecord = records[1]
        let copyPanel = panels[1]
        var copyResult: Result<Void, Error>?
        coordinator.copy(copyRecord, dismissing: copyPanel, to: pasteboard) { copyResult = $0 }
        try require(!copyPanel.dismissed, "card stays until pasteboard write completes")
        try wait { copyResult != nil }
        try copyResult!.get()
        try require(pasteboard.data(forType: .png) != nil, "copy publishes image data")
        try require(copyPanel.dismissed && coordinator.overlays[copyRecord.id] == nil
                    && !coordinator.overlayOrder.contains(copyRecord.id), "successful copy removes only its card")
        let retained = try store.record(copyRecord.id)
        try require(FileManager.default.fileExists(atPath: store.url(retained).path), "copy dismissal preserves capture history and file")
        coordinator.restoreOverlay()
        guard let restored = coordinator.overlays[copyRecord.id] else {
            throw CaptureError.message("overlay: copied card must be restorable")
        }

        copyResult = nil
        coordinator.copy(copyRecord, to: pasteboard) { copyResult = $0 }
        try wait { copyResult != nil }
        try copyResult!.get()
        try require(!restored.dismissed, "history/editor copy does not dismiss a stack card")

        copyResult = nil
        coordinator.copy(copyRecord, dismissing: restored, to: pasteboard) { copyResult = $0 }
        pasteboard.clearContents()
        try require(pasteboard.setString("newer clipboard content", forType: .string), "clipboard conflict fixture")
        try wait { copyResult != nil }
        guard case .failure(let conflict) = copyResult!,
              case .pasteboardChanged = conflict as? CapsuleFilePasteboardError else {
            throw CaptureError.message("overlay: newer clipboard must reject stale copy")
        }
        try require(!restored.dismissed && pasteboard.string(forType: .string) == "newer clipboard content",
                    "failed copy preserves card and newer clipboard")

        var unavailable = retained
        unavailable.output = "missing-copy-output.png"
        try store.update(unavailable)
        copyResult = nil
        coordinator.copy(copyRecord, dismissing: restored, to: pasteboard) { copyResult = $0 }
        try wait { copyResult != nil }
        guard case .failure = copyResult! else { throw CaptureError.message("overlay: missing image must fail copy") }
        try require(!restored.dismissed && pasteboard.string(forType: .string) == "newer clipboard content",
                    "prepare failure preserves card and clipboard")
        try store.update(retained)

        copyResult = nil
        coordinator.copy(copyRecord, dismissing: restored, to: pasteboard) { copyResult = $0 }
        restored.close()
        coordinator.restoreOverlay()
        let replacement = coordinator.overlays[copyRecord.id]
        try wait { copyResult != nil }
        try copyResult!.get()
        try require(replacement != nil && replacement !== restored && replacement?.dismissed == false
                    && coordinator.overlays[copyRecord.id] === replacement,
                    "late copy completion must not dismiss a replacement card")
        print("capture-overlay-smoke: OK (stable identity, refresh, hidden restore, compaction, overflow, preview generations, copy dismissal/failure/history/replacement)")
    }
}
