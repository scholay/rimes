import AppKit

@MainActor
enum CaptureSelectionSmoke {
    static func run(previewDirectory: URL? = nil) throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("selection: " + message) }
        }
        let size = CGSize(width: 400, height: 300)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let image = try CaptureSmoke.fixture(width: 800, height: 600)
        for display in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                        CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                        CGRect(x: 100, y: -1200, width: 1600, height: 1200)] {
            let window = CGRect(x: display.minX + 80, y: display.minY + 120, width: 300, height: 180)
            try require(CaptureWindowChoice.localFrame(window: window, display: display) == CGRect(x: 80, y: 120, width: 300, height: 180),
                        "global top-left window bounds stay top-left on offset/negative displays")
        }
        func install(_ view: CaptureSelectionView) { panel.contentView = view; view.frame = CGRect(origin: .zero, size: size) }
        if let screen = NSScreen.main,
           let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            // Read only our fixture window's WindowServer metadata, never
            // screen pixels. Verify the actual CG -> flipped-view boundary.
            panel.setFrame(CGRect(x: screen.frame.minX + 80, y: screen.frame.maxY - 120 - size.height,
                                  width: size.width, height: size.height), display: false)
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber)) as? [[String: Any]]
            if let bounds = infos?.first?[kCGWindowBounds as String] as? [String: Any],
               let actual = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                try require(CaptureWindowChoice.localFrame(window: actual, display: CGDisplayBounds(displayID)) == CGRect(x: 80, y: 120, width: 400, height: 300),
                            "real WindowServer bounds need no second Y flip")
            } else {
                print("capture-selection-smoke: own WindowServer metadata unavailable; native view and synthetic geometry checks still run")
            }
            let flipped = CaptureSelectionView(); install(flipped)
            let screenPoint = CGPoint(x: panel.frame.minX + 20, y: panel.frame.maxY - 30)
            try require(flipped.convert(panel.convertPoint(fromScreen: screenPoint), from: nil) == CGPoint(x: 20, y: 30),
                        "native AppKit screen conversion ends in top-left view points")
            panel.orderOut(nil)

            let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-surfaces-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let coordinator = CaptureCoordinator(isolatedStore: try CaptureStore(root: root))
            let supportedPanel = CapturePanel(size: size), unavailablePanel = CapturePanel(size: size)
            defer { supportedPanel.close(); unavailablePanel.close() }
            let supportedView = CaptureSelectionView(), unavailableView = CaptureSelectionView()
            supportedPanel.contentView = supportedView; unavailablePanel.contentView = unavailableView
            supportedPanel.orderFrontRegardless(); unavailablePanel.orderFrontRegardless()
            let surfaces = [CaptureCoordinator.SelectionSurface(screen: screen, displayID: 10, view: supportedView),
                            CaptureCoordinator.SelectionSurface(screen: screen, displayID: 20, view: unavailableView)]
            let retained = try coordinator.supportedSurfaces(surfaces, displayIDs: [10])
            unavailableView.acceptSnapshot(image)
            try require(retained.count == 1 && retained.first?.view === supportedView && supportedPanel.isVisible
                        && !unavailablePanel.isVisible && unavailableView.snapshot == nil,
                        "missing one SC display closes only its mask and rejects late frames")
            do {
                _ = try coordinator.supportedSurfaces(retained, displayIDs: [])
                throw CaptureError.message("all-unavailable display set accepted")
            } catch CaptureError.message(let message) {
                try require(message == "没有可捕获的显示器" && !supportedPanel.isVisible, "fail only when no supported display remains")
            }
        }
        func mouse(_ view: CaptureSelectionView, _ type: NSEvent.EventType, _ point: CGPoint) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? panel.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1) else { throw CaptureError.message("selection: mouse fixture") }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            case .leftMouseUp: view.mouseUp(with: event)
            default: view.mouseMoved(with: event)
            }
        }
        func drag(_ view: CaptureSelectionView) throws {
            try mouse(view, .leftMouseDown, CGPoint(x: 20, y: 30))
            try mouse(view, .leftMouseDragged, CGPoint(x: 180, y: 130))
            try mouse(view, .leftMouseUp, CGPoint(x: 180, y: 130))
        }
        let expected = CGRect(x: 20, y: 30, width: 160, height: 100)
        let early = CaptureSelectionView(); install(early)
        var selected: [CGRect] = []
        early.selected = { rect, _ in selected.append(rect) }
        try drag(early)
        try require(early.snapshot == nil && early.pendingSelection == expected && selected.isEmpty,
                    "early drag stays interactive but cannot deliver without pixels")
        early.acceptSnapshot(image)
        early.acceptSnapshot(image)
        try require(selected == [expected], "late frame delivers the queued selection exactly once")

        let cancelled = CaptureSelectionView(); install(cancelled)
        var cancelCount = 0
        cancelled.cancelled = { cancelCount += 1 }
        cancelled.selected = { rect, _ in selected.append(rect) }
        try drag(cancelled)
        cancelled.cancelOperation(nil)
        cancelled.cancelOperation(nil)
        cancelled.acceptSnapshot(image)
        try require(cancelCount == 1 && cancelled.snapshot == nil && selected == [expected],
                    "Escape before frame cancels once and rejects late capture")

        let ready = CaptureSelectionView(); install(ready)
        ready.selected = { rect, _ in selected.append(rect) }
        ready.acceptSnapshot(image)
        try drag(ready)
        try require(selected == [expected, expected], "ready frame delivers without a second click")
        let fixed = CaptureSelectionView(); install(fixed); fixed.fixedSize = CGSize(width: 80, height: 60)
        try drag(fixed)
        try require(fixed.pendingSelection == CGRect(x: 20, y: 30, width: 80, height: 60), "fixed-size selection retained")
        let ratio = CaptureSelectionView(); install(ratio); ratio.ratio = 2
        try drag(ratio)
        try require(ratio.pendingSelection == CGRect(x: 20, y: 30, width: 200, height: 100), "aspect ratio retained")

        let framed = CaptureSelectionView(); install(framed)
        framed.requiresConfirmation = true; framed.ratio = 2
        var confirmed: [CGRect] = []
        framed.selected = { rect, _ in confirmed.append(rect) }
        framed.acceptSnapshot(image)
        try drag(framed)
        try require(confirmed.isEmpty && framed.draftRect == CGRect(x: 20, y: 30, width: 200, height: 100), "frame waits for Return and preserves ratio")
        try mouse(framed, .leftMouseDown, CGPoint(x: 40, y: 50))
        try mouse(framed, .leftMouseDragged, CGPoint(x: 70, y: 70))
        try mouse(framed, .leftMouseUp, CGPoint(x: 70, y: 70))
        try require(framed.draftRect == CGRect(x: 50, y: 50, width: 200, height: 100) && confirmed.isEmpty, "dragging a frame translates without resizing or capturing")
        framed.confirmSelection(); framed.confirmSelection()
        try require(confirmed == [CGRect(x: 50, y: 50, width: 200, height: 100)], "Return delivers exactly once")
        let edge = CaptureSelectionView(); install(edge); edge.requiresConfirmation = true; edge.ratio = 2
        try mouse(edge, .leftMouseDown, CGPoint(x: 350, y: 270))
        try mouse(edge, .leftMouseUp, CGPoint(x: 450, y: 370))
        try require(edge.draftRect == CGRect(x: 350, y: 270, width: 50, height: 25), "screen-edge clamping preserves aspect ratio")
        let suite = "capture-frame-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        CaptureFramePreferences.save(size: CGSize(width: 200, height: 100), ratio: 2, defaults: defaults)
        try require(CaptureFramePreferences.size(defaults) == CGSize(width: 200, height: 100) && CaptureFramePreferences.ratio(defaults) == 2, "frame size and aspect persist together")
        edge.restoreSelection(CaptureFramePreferences.size(defaults)!)
        try require(edge.draftRect == CGRect(x: 100, y: 100, width: 200, height: 100), "reopening centers the previous dimensions")
        // Two live view surfaces model distinct displays. Restoring a frame
        // must not clone it, and beginning elsewhere must retire old geometry.
        let secondPanel = CapturePanel(size: size, nonactivating: true)
        defer { secondPanel.close() }
        let firstDisplay = CaptureSelectionView(), secondDisplay = CaptureSelectionView()
        install(firstDisplay); secondPanel.contentView = secondDisplay
        secondDisplay.frame = CGRect(origin: .zero, size: size)
        firstDisplay.requiresConfirmation = true; secondDisplay.requiresConfirmation = true
        let session = CaptureSelectionSession(views: [firstDisplay, secondDisplay])
        session.restore(CGSize(width: 200, height: 100), on: firstDisplay)
        try require(firstDisplay.draftRect != nil && secondDisplay.draftRect == nil, "restore last frame on exactly one display")
        var firstDeliveries = 0, secondDeliveries = 0
        firstDisplay.selected = { _, _ in firstDeliveries += 1 }
        secondDisplay.selected = { _, _ in secondDeliveries += 1 }
        firstDisplay.confirmSelection() // pixels are still pending on display 1
        try drag(secondDisplay)
        try require(session.activeView === secondDisplay && firstDisplay.draftRect == nil
                    && firstDisplay.pendingSelection == nil && secondDisplay.draftRect == expected,
                    "drawing on another display removes the previous frame and queued capture")
        firstDisplay.acceptSnapshot(image); firstDisplay.confirmSelection()
        try require(firstDeliveries == 0, "late pixels or Return on inactive display cannot capture the old frame")
        secondDisplay.acceptSnapshot(image)
        try mouse(firstDisplay, .leftMouseDown, CGPoint(x: 10, y: 10))
        try mouse(firstDisplay, .leftMouseUp, CGPoint(x: 90, y: 70))
        try require(secondDisplay.draftRect == nil && secondDisplay.pendingSelection == nil
                    && firstDisplay.draftRect == CGRect(x: 10, y: 10, width: 80, height: 60),
                    "switching back still leaves exactly one frame")
        secondDisplay.confirmSelection(); firstDisplay.confirmSelection()
        try require(firstDeliveries == 1 && secondDeliveries == 0, "only the final active frame is delivered")
        firstDisplay.invalidate(); secondDisplay.invalidate()
        try require(firstDisplay.draftRect == nil && secondDisplay.draftRect == nil, "closing a session clears all geometry")

        // Repaint the same backing bitmap after a move. Geometry assertions
        // alone miss borders accidentally retained in the displayed pixels.
        let pixels = CaptureSelectionView(); install(pixels); pixels.requiresConfirmation = true
        let cleanContext = try CaptureRenderer.context(size)
        cleanContext.setFillColor(CGColor(gray: 1, alpha: 1)); cleanContext.fill(CGRect(origin: .zero, size: size))
        let cleanImage = cleanContext.makeImage()!
        pixels.acceptSnapshot(cleanImage); pixels.restoreSelection(CGSize(width: 100, height: 80))
        guard let bitmap = pixels.bitmapImageRepForCachingDisplay(in: pixels.bounds) else { throw CaptureError.message("selection: pixel regression bitmap") }
        pixels.cacheDisplay(in: pixels.bounds, to: bitmap)
        try mouse(pixels, .leftMouseDown, CGPoint(x: 170, y: 130))
        try mouse(pixels, .leftMouseUp, CGPoint(x: 70, y: 50))
        pixels.cacheDisplay(in: pixels.bounds, to: bitmap)
        let pixelScale = CGFloat(bitmap.pixelsWide) / size.width
        let retiredEdge = bitmap.colorAt(x: Int(151 * pixelScale), y: Int(150 * pixelScale))!.usingColorSpace(.deviceRGB)!
        try require(abs(retiredEdge.redComponent - retiredEdge.blueComponent) < 0.02 && retiredEdge.redComponent > 0.4,
                    "moving a frame repaints its old blue border from the clean backdrop")
        try require(pixels.snapshot === cleanImage, "drawing and moving never modify the frozen source image")

        let escapePanel = CapturePanel(size: size, nonactivating: true)
        defer { escapePanel.close() }
        var escaped = false
        escapePanel.escapeCloses = false; escapePanel.escapeAction = { escaped = true }
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: escapePanel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        escapePanel.sendEvent(key)
        try require(escaped && escapePanel.styleMask.contains(.nonactivatingPanel), "panel Escape bypasses IME/responder routing and selector is nonactivating from initialization")

        let windows = CaptureSelectionView(mode: .window); install(windows)
        var chosen: [CGWindowID] = []
        windows.windowSelected = { chosen.append($0) }
        try mouse(windows, .leftMouseUp, CGPoint(x: 150, y: 80))
        try require(chosen.isEmpty, "window click cannot capture while targets are loading")
        let front = CaptureWindowChoice(id: 3, frame: CGRect(x: 100, y: 60, width: 200, height: 170), title: "前景窗口")
        let acrossDisplay = CaptureWindowChoice(id: 2, frame: CGRect(x: -80, y: 110, width: 120, height: 100), title: "跨屏窗口")
        let back = CaptureWindowChoice(id: 1, frame: CGRect(x: 20, y: 20, width: 350, height: 230), title: "后景窗口")
        let choices = [front, acrossDisplay, back]
        windows.acceptWindows(choices)
        windows.updateHover(at: CGPoint(x: 150, y: 80))
        try require(windows.hoveredWindow == front, "overlap selects the frontmost eligible window")
        windows.updateHover(at: CGPoint(x: 30, y: 150))
        try require(windows.hoveredWindow == acrossDisplay, "negative-origin window remains selectable on this display")
        windows.updateHover(at: CGPoint(x: 80, y: 200))
        try require(windows.hoveredWindow == back, "uncovered background window is selectable")
        windows.updateHover(at: CGPoint(x: 390, y: 280))
        try require(windows.hoveredWindow == nil, "desktop is not a window target")
        windows.updateHover(at: CGPoint(x: -10, y: 150))
        try require(windows.hoveredWindow == nil, "pointer on another display must not highlight here")
        try mouse(windows, .leftMouseUp, CGPoint(x: 150, y: 80))
        try mouse(windows, .leftMouseUp, CGPoint(x: 150, y: 80))
        try require(chosen == [front.id], "single click selects exactly the highlighted window once")
        let abandoned = CaptureSelectionView(mode: .window); install(abandoned)
        abandoned.cancelOperation(nil); abandoned.acceptWindows(choices)
        abandoned.updateHover(at: CGPoint(x: 150, y: 80))
        try require(abandoned.hoveredWindow == nil, "cancelled window picker ignores late enumeration")

        if let previewDirectory {
            try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
            let root = NSView(frame: CGRect(origin: .zero, size: size))
            panel.contentView = root
            let preview = CaptureSelectionView(mode: .window); preview.frame = root.bounds
            root.addSubview(preview); preview.acceptWindows(choices); preview.updateHover(at: CGPoint(x: 150, y: 80))
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CaptureError.message("selection: preview bitmap") }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            let holeAlpha = bitmap.colorAt(x: Int(150 * scale), y: Int(100 * scale))?.alphaComponent ?? 1
            let maskAlpha = bitmap.colorAt(x: Int(10 * scale), y: Int(100 * scale))?.alphaComponent ?? 0
            try require(holeAlpha >= 0.01 && holeAlpha < 0.04 && maskAlpha > 0.3 && maskAlpha < 0.5,
                        "window mask must reveal the real desktop and dim only outside the target")
            // Composite the transparent window over synthetic pixels only.
            // Drawing a backdrop sibling into the same cache would erase it
            // when the picker clears its transparent target hole.
            guard let overlay = bitmap.cgImage,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CaptureError.message("selection: preview context")
            }
            let outputBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.draw(image, in: outputBounds)
            context.draw(overlay, in: outputBounds)
            guard let composite = context.makeImage() else {
                throw CaptureError.message("selection: preview encoding")
            }
            try CaptureImageIO.write(composite, to: previewDirectory.appendingPathComponent("window-picker.png"))
        }
        print("capture-selection-smoke: OK (early drag, delayed frame, cancellation, fixed size/ratio, window overlap, single active frame across displays)")
    }
}
