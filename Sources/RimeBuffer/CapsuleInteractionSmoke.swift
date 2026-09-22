import AppKit
import Carbon.HIToolbox

/// Native UI and migration regression fixtures. Never opens a live Capsule,
/// system pasteboard, or iCloud library, and never prints a credential.
@MainActor
enum CapsuleInteractionSmoke {
    static func run(output: URL? = nil) -> Bool {
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-capsule-interaction-\(UUID())")
        let suite = "RIMES.CapsuleInteractionSmoke.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            let passwords = CapsulePasswordStore(rootURL: root)
            let content = CapsuleContentStore(rootURL: root)
            let repository = CapsuleWindowRepository(contentStore: content, passwordStore: passwords)
            let store = CapsuleRevealPasscodeStore(defaults: defaults)
            let code = CapsuleRevealPasscode(chords: ["ab", "df", "jk", "mn"].map { CapsuleRevealChord($0)! })!
            store.set(code)
            let chords: [[UInt16]] = [[0, 11], [2, 3], [38, 40], [46, 45]]
            let note = try repository.save(CapsuleWindowDraft(kind: .note, title: "登录资料", content: "fixture-secret-body"))
            let password = try repository.moveNoteToPassword(note)
            try require(try repository.list(kind: .note).allSatisfy { $0.id != note.id }, "migration removes only the committed source")
            try require(try passwords.record(id: password.id).secret.body == "fixture-secret-body", "migration preserves content")
            let bytes = try Data(contentsOf: password.fileURL)
            try require(!String(decoding: bytes, as: UTF8.self).contains("fixture-secret-body"), "destination is encrypted")
            let stale = try repository.save(CapsuleWindowDraft(kind: .note, title: "并发修改", content: "initial"))
            var updated = try repository.draft(for: stale)
            updated.content = "updated"
            _ = try repository.save(updated)
            do { _ = try repository.moveNoteToPassword(stale); throw Failure("stale migration accepted") }
            catch CapsuleWindowRepositoryError.staleRecord { }
            try require(try repository.list(kind: .password).count == 1, "stale migration creates no duplicate")
            try require(!CapsuleRailSaveRules.mayRemoveSource(after: []), "empty migration preserves source")
            try require(!CapsuleRailSaveRules.mayRemoveSource(after: [.saved(.pdf, UUID()), .unsupported(.fileType)]), "mixed card preserves source")
            try require(!CapsuleRailSaveRules.mayRemoveSource(after: [.failed]), "failed migration preserves source")
            try require(CapsuleRailSaveRules.mayRemoveSource(after: [.saved(.image, UUID()), .alreadySaved(.pdf, UUID())]), "complete migration may remove source")

            let model = ClipboardHistoryModel(configuration: .init(), pasteboard: EmptyPasteboard(), schedulesAutomaticPolling: false)
            model.start()
            model.update(windowVisible: true, captureEnabled: true, protection: [])
            let entries = try CapsuleRailLibrary.load(contentStore: content, passwordStore: passwords).passwords.get()
            var reads = 0
            let library = CapsuleRailLibrary(loader: { (.success([]), .success(entries)) }, passwordReader: { entry in
                reads += 1
                return try passwords.record(id: entry.id).secret.body
            })
            let pane = ClipboardHistoryPaneView(model: model, library: library, passcodeStore: store)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: ClipboardHistoryWindowMetrics.preferredWidth, height: ClipboardHistoryWindowMetrics.preferredHeight), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil) }
            window.contentView = pane
            window.makeKeyAndOrderFront(nil)
            // Command-line smoke runs have no normal NSApplication event
            // loop. Drive AppKit's native key lifecycle explicitly.
            window.becomeKey()
            try require(wait { window.isKeyWindow }, "native fixture window becomes key")
            pane.onRequestPasswordInput = { window.makeKeyAndOrderFront(nil); return window.canBecomeKey }
            pane.selectTab(.saved(.password))
            try require(wait { pane.capsuleRailSnapshotForSmoke().cardCount == 1 }, "password card loads")
            pane.layoutSubtreeIfNeeded()
            try require(pane.activateSelectedItems(), "card starts native authentication")
            pane.layoutSubtreeIfNeeded()
            try require(reads == 0, "no decryption before authentication")
            let hint = descendants(pane).first { $0.identifier?.rawValue == "capsule-rail-hint" }!
            let hintRect = pane.convert(hint.bounds, from: hint)
            let bottomGap = pane.isFlipped ? pane.bounds.maxY - hintRect.maxY : hintRect.minY - pane.bounds.minY
            try require((6...16).contains(bottomGap), "rail has no empty bottom row")
            let plainKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            let copyKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            try require(!pane.handleStandaloneKeyEquivalent(plainKey), "native password keys are not swallowed by rail shortcuts")
            try require(pane.handleStandaloneKeyEquivalent(copyKey), "password blocks clipboard shortcuts")
            try render(pane, to: output?.appendingPathComponent("password-card-locked.png"))
            send([[0], [0], [0], [0]], to: window)
            try require(reads == 0, "wrong code cannot decrypt")
            send(chords, to: window)
            try require(reads == 1, "verified card decrypts once")
            try require(descendants(pane).compactMap { $0 as? CapsuleCardPasswordView }.contains { $0.isRevealed }, "password revealed in card")
            try require(!pane.copySelectedItems(), "revealed password cannot copy")
            try require(entries.allSatisfy { $0.payload == nil && !$0.searchText.contains("fixture-secret-body") }, "projection remains redacted")
            try render(pane, to: output?.appendingPathComponent("password-card-revealed.png"))
            pane.selectTab(.saved(.note))
            try require(!pane.hasPasswordInteraction, "tab switch conceals")
            pane.selectTab(.saved(.password))
            try require(pane.activateSelectedItems(), "card can authenticate again")
            send(chords, to: window)
            NotificationCenter.default.post(name: .capsuleRevealPasscodeDidChange, object: nil)
            try require(!pane.hasPasswordInteraction, "credential change revokes plaintext")
            try require(pane.activateSelectedItems(), "card reopens after revocation")
            send(chords, to: window)
            model.update(windowVisible: true, captureEnabled: true, protection: [.secureInput])
            try require(!pane.hasPasswordInteraction, "protection removes plaintext")
            let editor = CapsulePaneViewController(repository: repository, cloudSyncController: nil, revealPasscodeStore: store)
            // Reuse the active window; no app activation or cross-window focus
            // race can accidentally authenticate a background editor.
            let detail = window
            CapsuleWindowGeometry.install(contentController: editor, in: detail)
            editor.setCompactDetail(true)
            editor.reveal(kind: .password, id: password.id)
            try require(wait { descendants(editor.view).contains { ($0 as? NSTextField)?.stringValue == "登录资料" } }, "existing password loads in compact detail")
            try require(detail.isKeyWindow, "detail keeps native key ownership")
            editor.windowBecameKey()
            send([[0], [0], [0], [0]], to: detail)
            try require(!descendants(editor.view).contains { ($0 as? NSTextView)?.isFieldEditor == false }, "wrong detail passcode stays concealed")
            send(chords, to: detail)
            let revealedEditors = descendants(editor.view).compactMap { $0 as? NSTextView }.filter { !$0.isFieldEditor }
            try require(revealedEditors.count == 1 && revealedEditors.first?.string == "fixture-secret-body", "detail authenticates and shows the selected body")
            editor.concealPasswordPlaintext()
            try require(revealedEditors.allSatisfy { $0.string.isEmpty && !$0.isDescendant(of: editor.view) }, "conceal scrubs the detached editor and its undo history")
            editor.beginDraft(kind: .password, title: "演示账号（仅测试）", content: "用户名：demo@example.invalid\n密码：fixture-only-secret")
            try require(descendants(editor.view).contains { ($0 as? NSTextView)?.isEditable == true && ($0 as? NSTextView)?.isFieldEditor == false }, "new password directly editable without challenge")
            try require(!descendants(editor.view).contains { $0 is CapsuleInlinePasscodeView }, "creation needs no old-secret verification")
            try render(editor.view, to: output?.appendingPathComponent("password-create.png"))
            editor.concealPasswordPlaintext()
            try require(!descendants(editor.view).contains { ($0 as? NSTextView)?.isFieldEditor == false }, "new password draft conceals on privacy boundary")
            for size in [CapsuleWindowGeometry.detailContentSize, CapsuleWindowGeometry.detailMinimumSize] {
                detail.setContentSize(size)
                editor.view.layoutSubtreeIfNeeded()
                try require(editor.view.bounds.width <= size.width + 1, "compact detail does not expand window")
                try require(!editor.view.hasAmbiguousLayout, "compact detail has definite layout")
            }
            try render(editor.view, to: output?.appendingPathComponent("password-detail-locked.png"))

            var menuCalls = [String]()
            let menu = CapsuleCardMenu.make([
                ("编辑", true, { menuCalls.append("edit") }),
                ("迁移", false, { menuCalls.append("move") }),
                ("删除", true, { menuCalls.append("delete") }),
            ])
            menu.performActionForItem(at: 0)
            menu.performActionForItem(at: 2)
            try require(menuCalls == ["edit", "delete"] && !menu.items[1].isEnabled, "menu callbacks retained and unsupported moves disabled")
            print("capsule-interaction-smoke: PASS")
            return true
        } catch {
            // Only our static assertion text is printable; store errors may
            // contain paths and are deliberately not serialized here.
            print("capsule-interaction-smoke: FAIL \((error as? Failure)?.message ?? "fixture operation")")
            return false
        }
    }

    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func wait(_ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return ready()
    }
    private static func send(_ chords: [[UInt16]], to window: NSWindow) {
        for chord in chords {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                for key in chord {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key)!
                    window.sendEvent(event)
                }
            }
        }
    }
    private static func render(_ view: NSView, to output: URL?) throws {
        guard let output else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("render allocation") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure("render encoding") }
        try png.write(to: output)
    }
    private final class EmptyPasteboard: ClipboardHistoryPasteboardReading {
        var changeCount: Int { 0 }
        func readPlainText() -> String? { nil }
    }
}
