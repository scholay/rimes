import AppKit
import Darwin

/// Local AppKit fixtures only: no screen recording, live Capsule data, input
/// source changes, or persisted appearance preferences are needed for this test.
@MainActor
enum WindowChromeSmoke {
    static func run(output: URL? = nil) throws {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("window chrome: " + message) }
        }
        let environmentKey = "RIMEBUFFER_APPEARANCE_MODE"
        let previous = ProcessInfo.processInfo.environment[environmentKey]
        let previousAppearance = NSApp.appearance
        defer {
            if let previous { setenv(environmentKey, previous, 1) } else { unsetenv(environmentKey) }
            NSApp.appearance = previousAppearance
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-window-chrome-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = CapsulePaneViewController(repository: CapsuleWindowRepository(
            contentStore: CapsuleContentStore(rootURL: root),
            passwordStore: CapsulePasswordStore(rootURL: root)
        ), cloudSyncController: nil)
        let manager = NSWindow(contentRect: NSRect(origin: .zero, size: CapsuleWindowGeometry.defaultContentSize),
                               styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        manager.isReleasedWhenClosed = false
        manager.titlebarAppearsTransparent = true
        manager.titleVisibility = .hidden
        CapsuleWindowGeometry.install(contentController: pane, in: manager)
        defer { manager.close() }

        let card = CapturePanel(size: NSSize(width: 208, height: 148), key: false)
        card.captureChrome = true
        let fullBleed = NSView(frame: card.contentView!.bounds)
        fullBleed.autoresizingMask = [.width, .height]
        fullBleed.wantsLayer = true
        fullBleed.layer?.backgroundColor = NSColor.white.cgColor
        card.contentView!.addSubview(fullBleed)
        let hover = CaptureCardControls(frame: fullBleed.bounds)
        hover.autoresizingMask = [.width, .height]
        card.contentView!.addSubview(hover)
        let utility = CapturePanel(size: NSSize(width: 310, height: 170))
        let transparent = CapturePanel(size: NSSize(width: 780, height: 68), surface: .transparent)
        transparent.styleMask = [.borderless]
        transparent.captureChrome = true
        // The fullscreen selector replaces the initial content view; it must
        // retain square, transparent edges even after a theme notification.
        transparent.contentView = NSView(frame: transparent.contentView!.bounds)
        defer { card.close(); utility.close(); transparent.close() }

        func checkRounded(_ window: NSWindow, name: String) throws {
            try require(!window.isOpaque && window.backgroundColor.alphaComponent == 0, name + " transparent window backing")
            try require(window.contentView?.layer?.cornerRadius == RoundedWindowChrome.radius
                        && window.contentView?.layer?.masksToBounds == true, name + " clips the entire content tree")
        }
        func snapshot(_ view: NSView, name: String, scale: CGFloat) throws {
            view.window?.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            view.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            guard let layer = view.layer else { throw CaptureError.message("missing root layer") }
            let context = try CaptureRenderer.context(CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale))
            // CaptureRenderer uses image/document coordinates. CALayer.render
            // already handles the AppKit layer orientation, so undo that flip.
            context.translateBy(x: 0, y: CGFloat(context.height))
            context.scaleBy(x: 1, y: -1)
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            guard let image = context.makeImage() else { throw CaptureError.message("missing raster") }
            let bitmap = NSBitmapImageRep(cgImage: image)
            for x in [0, bitmap.pixelsWide - 1] {
                for y in [0, bitmap.pixelsHigh - 1] {
                    try require((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.01, name + " corner alpha at \(x),\(y)")
                }
            }
            try require((bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.9,
                        name + " preserves the center")
            if view === card.contentView, hover.isHidden {
                let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
                try require((center?.redComponent ?? 0) > 0.95, "full-bleed child actually rendered, not just the root background")
            }
            if let output { try CaptureImageIO.write(image, to: output.appendingPathComponent(name + "-\(Int(scale))x.png")) }
        }
        for mode in [RimeAppearanceMode.day, .night] {
            setenv(environmentKey, mode.rawValue, 1)
            NSApp.appearance = NSAppearance(named: mode == .day ? .aqua : .darkAqua)
            NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
            manager.appearance = RimeUI.appKitAppearance
            pane.applyAppearance()
            for (window, name) in [(card, "card"), (utility, "utility"), (manager, "capsule")] {
                try checkRounded(window, name: name)
            }
            try require(!card.canBecomeKey && utility.canBecomeKey, "nonactivating/key-window behavior unchanged")
            try require(!transparent.isOpaque && transparent.backgroundColor.alphaComponent == 0
                        && transparent.contentView?.layer?.cornerRadius == 0
                        && transparent.contentView?.layer?.backgroundColor?.alpha == 0,
                        "launcher gaps and fullscreen selector edges stay transparent and square")
            for scale: CGFloat in [1, 2] {
                for hovering in [false, true] {
                    hover.isHidden = !hovering
                    try snapshot(card.contentView!, name: "\(mode.rawValue)-card-\(hovering ? "hover" : "rest")", scale: scale)
                }
                try snapshot(utility.contentView!, name: "\(mode.rawValue)-utility", scale: scale)
                for size in [CapsuleWindowGeometry.defaultContentSize, CapsuleWindowGeometry.minimumContentSize] {
                    manager.setContentSize(size)
                    try snapshot(pane.view, name: "\(mode.rawValue)-capsule-\(Int(size.width))", scale: scale)
                }
            }
        }
        // All visual-effect surfaces use resizable material masks, not merely
        // CALayer cornerRadius (which cannot clip the backdrop compositor).
        for radius: CGFloat in [9, RoundedWindowChrome.radius] {
            let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 760, height: 112))
            RoundedWindowChrome.maskMaterial(material, radius: radius)
            try require(material.maskImage?.capInsets.left == radius
                        && material.maskImage?.resizingMode == .stretch
                        && material.layer?.masksToBounds == true, "resizable material mask")
        }
        let replacement = NSView(frame: utility.contentView!.bounds)
        utility.contentView = replacement
        try checkRounded(utility, name: "replacement content")
        print("window-chrome-smoke: OK (light/dark, 1x/2x corner alpha, hover, resize, replacement, material masks, fullscreen exemption)")
    }
}
