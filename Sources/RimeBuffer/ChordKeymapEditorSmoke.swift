import AppKit
import Foundation

/// Runs the real no-code editor against private temporary files and defaults.
/// No engine, IMK client, deployment, or input-source change is performed.
func runChordKeymapEditorSmokeTest(outputURL: URL? = nil) -> Bool {
    func fail(_ message: String) -> Bool {
        print("chord-keymap-ui-smoke: FAIL \(message)")
        return false
    }
    guard Thread.isMainThread else { return fail("AppKit requires the main thread") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(
        "rimes-chord-keymap-editor-smoke-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    let suite = "rimes.chord-keymap.editor-smoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return fail("isolated defaults") }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? manager.removeItem(at: root)
    }

    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent("rime-data/my_combo.schema.yaml")
        let schema: FlyChordSchema
        if manager.fileExists(atPath: sourceURL.path) {
            schema = try FlyChordSchemaParser.load(from: sourceURL)
        } else {
            schema = try FlyChordSchemaParser.parse(
                """
                schema:
                  schema_id: my_combo
                chord_composer:
                  alphabet: 'qwertyuiopasdfghjklzxcvbnm,.'
                  algebra:
                    - 'xform/^qy$/qing/'
                    - 'xform/^dv$/n/'
                    - 'xform/^km$/ong/'
                    - 'xform/^dvkm$/nong/'
                    - 'xform/^dvi$/ni/'
                """,
                sourceURL: root.appendingPathComponent("fixture.schema.yaml")
            )
        }
        let builtin = try ChordKeymapProfile.builtIn(from: schema).validated()
        let store = ChordKeymapStore(rootURL: root, defaults: defaults,
                                    builtInLoader: { builtin })
        try ChordKeymapEditorViewController.smokeCheck(store: store)

        // A copied built-in template exercises the populated, editable screen
        // that users reach through the ordinary "复制方案" workflow.
        let copy = builtin.duplicated(name: "我的飞耀方案")
        try store.save(copy)
        var applyWasRequested = false
        let controller = ChordKeymapEditorViewController(store: store, apply: { _, completion in
            applyWasRequested = true
            completion(.success(()))
        })
        let pane = controller.view
        pane.wantsLayer = true
        pane.layer?.backgroundColor = RimeUI.surface.cgColor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 698, height: 1_300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = RimeUI.appKitAppearance
        window.backgroundColor = RimeUI.surface
        window.contentView = pane
        defer { window.close() }

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(pane)
        guard let picker = views.compactMap({ $0 as? NSPopUpButton }).first(where: {
            $0.accessibilityIdentifier() == "chord-keymap.profile"
        }),
        let customIndex = picker.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == copy.id
        }) else { return fail("profile picker does not expose saved custom profile") }
        picker.selectItem(at: customIndex)
        guard picker.sendAction(picker.action, to: picker.target) else {
            return fail("profile selection action was not delivered")
        }
        guard let name = views.compactMap({ $0 as? NSTextField }).first(where: {
            $0.accessibilityIdentifier() == "chord-keymap.name"
        }), name.isEnabled, name.stringValue == copy.name,
        let table = views.compactMap({ $0 as? NSTableView }).first,
        table.numberOfRows == copy.mappings.count,
        !applyWasRequested, store.activeProfile == builtin else {
            return fail("custom profile selection changed active state or failed to load")
        }

        // Select an actual row via AppKit so the edit fields and keyboard
        // highlight are included in the screenshot, then use the real tryout.
        if let index = copy.mappings.firstIndex(where: { $0.keys == "dvkm" }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else if table.numberOfRows > 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        if let tryButton = views.compactMap({ $0 as? NSButton }).first(where: {
            $0.title == "试译和弦"
        }) {
            tryButton.performClick(nil)
        } else { return fail("local tryout action is missing") }
        guard !applyWasRequested, controller.confirmCanLeave() else {
            return fail("viewing and trying a mapping must not dirty or apply a draft")
        }

        pane.layoutSubtreeIfNeeded()
        let fittingHeight = ceil(pane.fittingSize.height)
        guard fittingHeight.isFinite, (600...1_800).contains(fittingHeight) else {
            return fail("unexpected editor fitting height: \(fittingHeight)")
        }
        window.setContentSize(NSSize(width: 698, height: fittingHeight))
        pane.layoutSubtreeIfNeeded()
        let keyFields = views.compactMap({ $0 as? NSTextField }).filter {
            ["chord-keymap.left-keys", "chord-keymap.right-keys"].contains($0.accessibilityIdentifier())
        }
        // The fields share an equal-width constraint; on a 1x display AppKit
        // aligns frames to whole points, so an odd total splits 281/280.
        let pixel = 1 / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 1)
        guard keyFields.count == 2,
              keyFields.allSatisfy({ $0.frame.width >= 200 }),
              abs(keyFields[0].frame.width - keyFields[1].frame.width) <= pixel else {
            return fail("both key-zone fields must have equal, readable widths of at least 200pt: \(keyFields.map { $0.frame.width })")
        }
        pane.displayIfNeeded()
        guard pane.bounds.width == 698, pane.bounds.height >= 600,
              let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else {
            return fail("editor layout/render surface is invalid")
        }
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            return fail("editor PNG rendering failed")
        }
        if let outputURL {
            try png.write(to: outputURL, options: .atomic)
            print("chord-keymap-ui-smoke: rendered \(outputURL.path)")
        }
        print("chord-keymap-ui-smoke: PASS editor actions, isolated storage, local tryout, \(Int(pane.bounds.width))×\(Int(pane.bounds.height)) render")
        return true
    } catch { return fail(error.localizedDescription) }
}
