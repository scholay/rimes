import AppKit

@MainActor
enum CaptureChromeSmoke {
    static func run(output: URL) throws {
        func require(_ condition: Bool, _ text: String) throws { if !condition { throw CaptureError.message("chrome: " + text) } }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(8)
            while !ready(), Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            try require(ready(), "UI did not become ready")
        }
        func snapshot(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("bitmap unavailable") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message("PNG unavailable") }
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-chrome-smoke-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureStore(root: root)
        let fixture = try CaptureSmoke.fixture(width: 1000, height: 630)
        let record = try store.importImage(fixture)
        var geometry = CaptureDocument(image: fixture, file: record.original)
        geometry.crop = CGRect(x: 20, y: 30, width: 500, height: 350); geometry.turns = 1
        geometry.background.enabled = true; geometry.background.padding = 31; geometry.background.aspect = 16 / 9
        for outputWidth in [nil, 800] as [Int?] {
            geometry.outputWidth = outputWidth
            let rendered = try CaptureRenderer.render(geometry, directory: store.directory(record.id))
            try require(CaptureRenderer.outputPixelSize(geometry) == CGSize(width: rendered.width, height: rendered.height), "zoom geometry follows crop, rotation, background and export width")
        }
        let editor = try CaptureEditor(record: record, store: store)
        defer { editor.panel.close() }
        editor.show()
        let view = editor.panel.contentView!
        let canvas = descendants(view).compactMap { $0 as? CaptureCanvas }.first!
        try wait { canvas.image != nil }
        try require(descendants(view).filter { $0 is CaptureToolButton }.count == 12, "compact horizontal annotation tools")
        try require(!descendants(view).contains { $0 is CaptureLibraryStrip || $0 is CaptureInspectorScroll }, "no persistent sidebars or history rail")
        try snapshot(view, "editor")
        editor.panel.setContentSize(NSSize(width: 1040, height: 700)); view.layoutSubtreeIfNeeded()
        let buttons = descendants(view).compactMap { $0 as? CaptureChromeButton }
        for button in buttons {
            let rect = button.convert(button.bounds, to: view)
            try require(view.bounds.contains(rect), "button stays inside minimum-size editor: \(button.toolTip ?? "")")
        }
        try snapshot(view, "editor-compact")
        let colorButton = buttons.first { $0.accessibilityLabel() == "标注颜色" }!
        colorButton.performClick(nil)
        try wait { NSApp.windows.contains { window in window.contentView.map { descendants($0).contains { $0 is CaptureColorPicker } } ?? false } }
        if let pickerWindow = NSApp.windows.first(where: { window in window.contentView.map { descendants($0).contains { $0 is CaptureColorPicker } } ?? false }) {
            let embedded = descendants(pickerWindow.contentView!).first { $0 is CaptureColorPicker }!
            try require(embedded.bounds.size == CGSize(width: 340, height: 424), "popover preserves picker dimensions")
            pickerWindow.close()
        }
        canvas.zoom = 1
        try require(abs(canvas.imageRect.width - canvas.documentSize.width) < 1, "100% uses document pixels")
        canvas.zoom = nil

        let suite = "capture-chrome-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let picker = CaptureColorPicker(hex: "2C7FFB", defaults: defaults)
        var changed = ""
        picker.onChange = { changed = $0 }
        picker.setColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        try require(changed == "FF000080", "RGBA serializes alpha")
        let cg = CaptureRenderer.color(changed, alpha: 0.4)
        try require(abs(cg.alpha - 0.2) < 0.003, "renderer combines saved alpha and highlight opacity")
        try require(CaptureColorValue.parse("#2C7FFB") != nil && CaptureColorValue.parse("xyz") == nil, "hex validation")
        picker.saveFavorite(); picker.saveFavorite()
        try require(defaults.stringArray(forKey: "capture.annotation.colors") == ["FF000080"], "favorites deduplicate and persist")
        let hex = descendants(picker).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Hex" }!
        hex.stringValue = "bad"; _ = hex.sendAction(hex.action!, to: hex.target)
        try require(hex.stringValue == "FF0000", "invalid field restores current color")
        picker.setColor(CaptureColorValue.parse("2C7FFB")!)
        let pickerPanel = CapturePanel(size: picker.frame.size); pickerPanel.captureChrome = true; pickerPanel.contentView = picker
        defer { pickerPanel.close() }; pickerPanel.orderFrontRegardless()
        try snapshot(picker, "color-picker")

        let launcher = CaptureLauncherView(frame: .zero)
        let launchPanel = CapturePanel(size: NSSize(width: 780, height: 68)); launchPanel.captureChrome = true
        launchPanel.styleMask = [.borderless]; launchPanel.backgroundColor = .clear; launchPanel.isOpaque = false
        CaptureUI.fill(launcher, in: launchPanel.contentView!, inset: 0)
        launchPanel.setContentSize(launcher.fittingSize); launchPanel.orderFrontRegardless()
        defer { launchPanel.close() }
        var modes: [String] = []; launcher.capture = { mode, _, _, _ in modes.append(mode) }; launcher.recording = { modes.append("record") }
        for button in descendants(launcher).compactMap({ $0 as? CaptureModeButton }) where button.title != "延时" { button.performClick(nil) }
        try require(modes == ["area", "screen", "window", "scroll", "ocr", "record"], "all six mode actions route correctly")
        try snapshot(launcher, "launcher")

        let coordinator = CaptureCoordinator(isolatedStore: store); coordinator.showOverlay(record)
        guard let card = coordinator.overlays[record.id] else { throw CaptureError.message("missing card") }
        defer { card.close() }
        try wait { card.preview.image != nil }
        let controls = descendants(card.contentView!).compactMap { $0 as? CaptureCardControls }.first!
        controls.alphaValue = 1
        try snapshot(card.contentView!, "card-hover")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(card.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try CaptureImageIO.write(image, to: output.appendingPathComponent("card-hover-native.png"))
        }
        controls.alphaValue = 0
        try snapshot(card.contentView!, "card-rest")
        try require(controls.copyButton.accessibilityLabel() == "复制并移除卡片", "copy action remains accessible")
        print("capture-chrome-smoke: OK (compact editor, zoom, RGBA, validation, favorites, mode routing, native visual captures)")
    }
}
