import Cocoa
import Carbon.HIToolbox

/// Capsule rail: tab order, what may leave each tab, the store projection, and
/// the pane's read-only saved tabs. Uses temporary stores only; never reads
/// the user's Capsule or the general pasteboard.
@MainActor
enum CapsuleRailSmoke {
    static func run() -> Bool {
        var ok = true
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard !condition() else { return }
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            ok = false
        }

        checkRules(expect: expect)
        checkLibraryProjection(expect: expect)
        checkPane(expect: expect)
        return ok
    }

    /// Renders the rail on `tabName` (`recent` or a Capsule kind such as
    /// `note`) with sample entries and the second card hovered, to a PNG at
    /// `path`. `RIMES_PREVIEW_SCALE=1` renders at 1x instead of the screen's
    /// backing scale.
    static func renderPreview(to path: String, tabName: String) -> Bool {
        let model = ClipboardHistoryModel(
            configuration: .init(),
            pasteboard: CapsuleRailPasteboardDouble(),
            clock: Date.init,
            sourceApplicationName: { "Terminal" },
            sourceApplicationBundleIdentifier: { "com.apple.Terminal" },
            schedulesAutomaticPolling: false
        )
        model.start()
        model.update(windowVisible: true, captureEnabled: true, protection: [])
        _ = model.ingest("https://developer.apple.com/documentation/inputmethodkit")
        _ = model.ingest("DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./dev-reload.sh")

        let now = Date()
        let icon = FileManager.default.currentDirectoryPath
            + "/Logo/AppIcon.iconset/icon_256x256.png"
        let notes = [
            entry(.note, "Capsule 合并方案", "合并体验，不合并存储。最近只存本机；收入后才写 Markdown 与 iCloud。", now.addingTimeInterval(-7_200)),
            entry(.note, "RIMES 本机构建", "DEVELOPER_DIR 指向 Xcode 再跑 dev-reload.sh；装完看 ~/rimebuffer.log。", now.addingTimeInterval(-172_800)),
            entry(.note, "Electron 输入框", "打开 AXManualAccessibility 后约 3 秒树才建好。", now.addingTimeInterval(-432_000)),
        ]
        let images = [
            CapsuleRailEntry(id: UUID(), kind: .image, title: "RIMES 图标", preview: "Image · icon_256x256.png", updatedAt: now.addingTimeInterval(-86_400), payload: icon, searchText: "RIMES 图标"),
        ]
        let passwords = ["GitHub", "Cloudflare", "服务器 SSH"].enumerated().map { index, title in
            CapsuleRailEntry(id: UUID(), kind: .password, title: title, preview: "••••••••", updatedAt: now.addingTimeInterval(Double(-index) * 864_000), payload: nil, searchText: title)
        }
        let library = CapsuleRailLibrary(loader: {
            (.success(notes + images), .success(passwords))
        })
        let pane = ClipboardHistoryPaneView(model: model, library: library)
        pane.frame = NSRect(
            x: 0,
            y: 0,
            width: ClipboardHistoryWindowMetrics.preferredWidth,
            height: ClipboardHistoryWindowMetrics.preferredHeight
        )
        let tab = CapsuleEntryKind(rawValue: tabName).map(CapsuleRailTab.saved) ?? .recent
        if tab != .recent {
            pane.selectTab(tab)
            waitUntil { library.state(for: .note) == .loaded }
            if tab == .saved(.image) {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
        }
        pane.layoutSubtreeIfNeeded()
        pane.hoverCardForPreview(at: 1)
        pane.displayIfNeeded()
        let bitmap: NSBitmapImageRep?
        if let scale = ProcessInfo.processInfo.environment["RIMES_PREVIEW_SCALE"]
            .flatMap(Double.init), scale > 0 {
            bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pane.bounds.width * scale),
                pixelsHigh: Int(pane.bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            bitmap?.size = pane.bounds.size
        } else {
            bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds)
        }
        guard let bitmap else { return false }
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    private static func checkRules(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        expect(
            CapsuleRailTab.ordered.map(\.label) == ["最近", "笔记", "图片", "PDF", "技能", "密码"],
            "tab order"
        )
        expect(CapsuleRailTab.recent.cycled(by: -1) == .saved(.password), "tabs wrap backward")
        expect(CapsuleRailTab.saved(.password).cycled(by: 1) == .recent, "tabs wrap forward")
        expect(CapsuleRailTab.saved(.note).cycled(by: 2) == .saved(.pdf), "tabs step")
        expect(CapsuleRailActivationRules.action(for: .note) == .insertText, "note inserts text")
        for kind in [CapsuleEntryKind.image, .pdf, .skill] {
            expect(
                CapsuleRailActivationRules.action(for: kind) == .pasteFile,
                "\(kind.rawValue) pastes a file"
            )
        }
        expect(CapsuleRailActivationRules.action(for: .password) == .refuse, "password is refused")
        expect(!CapsuleRailActivationRules.allowsCopy(.password), "password never copies")
        expect(CapsuleRailActivationRules.allowsCopy(.note), "note copies")
    }

    private static func checkLibraryProjection(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimes-capsule-rail-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let contentStore = CapsuleContentStore(rootURL: root, now: { clock })
        let passwordStore = CapsulePasswordStore(rootURL: root, now: { clock })
        do {
            _ = try contentStore.put(CapsuleContentWriteRequest(
                type: .note,
                title: "发布清单",
                content: "DEVELOPER_DIR 指向 Xcode"
            ))
            clock = clock.addingTimeInterval(60)
            _ = try contentStore.put(CapsuleContentWriteRequest(
                type: .note,
                title: "焦点租约",
                content: "FocusToken 只认 client"
            ))
            clock = clock.addingTimeInterval(60)
            _ = try passwordStore.put(CapsulePasswordWriteRequest(
                title: "GitHub",
                body: "password: rail-smoke-secret"
            ))
        } catch {
            expect(false, "seeding temporary stores threw: \(error.localizedDescription)")
            return
        }

        let loaded = CapsuleRailLibrary.load(
            contentStore: contentStore,
            passwordStore: passwordStore
        )
        guard let content = try? loaded.content.get(),
              let passwords = try? loaded.passwords.get() else {
            expect(false, "library projection failed")
            return
        }
        let notes = content.filter { $0.kind == .note }
        expect(notes.first?.title == "焦点租约", "newest note first")
        expect(
            notes.first?.payload == "FocusToken 只认 client",
            "note payload is its text"
        )
        expect(passwords.count == 1, "one password")
        expect(passwords.first?.payload == nil, "password carries no secret")
        expect(passwords.first?.preview == "••••••••", "password preview is the fixed mask")
        expect(
            passwords.first.map { !$0.searchText.contains("rail-smoke-secret") } == true,
            "password search text never holds the secret"
        )
        expect(
            CapsuleRailSearchRules.filter(notes, query: "focustoken").map(\.title) == ["焦点租约"],
            "search matches an entry body"
        )
        expect(
            CapsuleRailSearchRules.filter(passwords, query: "secret").isEmpty,
            "a password body is not searchable"
        )
    }

    private static func checkPane(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        let model = ClipboardHistoryModel(
            configuration: .init(),
            pasteboard: CapsuleRailPasteboardDouble(),
            schedulesAutomaticPolling: false
        )
        model.start()
        model.update(windowVisible: true, captureEnabled: true, protection: [])
        _ = model.ingest("history alpha")

        let now = Date()
        let noteA = entry(.note, "焦点租约", "FocusToken 只认 client", now)
        let noteB = entry(.note, "发布清单", "DEVELOPER_DIR 指向 Xcode", now.addingTimeInterval(-60))
        let password = CapsuleRailEntry(
            id: UUID(),
            kind: .password,
            title: "GitHub",
            preview: "••••••••",
            updatedAt: now,
            payload: nil,
            searchText: "GitHub"
        )
        let library = CapsuleRailLibrary(loader: {
            (.success([noteA, noteB]), .success([password]))
        })
        let pane = ClipboardHistoryPaneView(model: model, library: library)
        pane.frame = NSRect(
            x: 0,
            y: 0,
            width: ClipboardHistoryWindowMetrics.preferredWidth,
            height: ClipboardHistoryWindowMetrics.preferredHeight
        )
        var activated: [CapsuleRailEntry] = []
        var copied: [CapsuleRailEntry] = []
        var historyActivations = 0
        pane.onActivateSaved = { activated.append($0); return true }
        pane.onCopySaved = { copied.append($0); return true }
        pane.onActivate = { _ in historyActivations += 1; return true }
        pane.layoutSubtreeIfNeeded()

        let recent = pane.capsuleRailSnapshotForSmoke()
        expect(recent.tab == .recent, "rail opens on Recent")
        expect(recent.clearButtonVisible, "Recent shows clear")
        expect(recent.editableCardCount == 0, "Recent cards have no edit brush in step 1")

        expect(pane.handleKeyDown(key(kVK_Tab)), "Tab is owned by the rail")
        expect(pane.selectedTab == .saved(.note), "Tab moves to Notes")
        waitUntil { library.state(for: .note) == .loaded }
        pane.layoutSubtreeIfNeeded()
        let notes = pane.capsuleRailSnapshotForSmoke()
        expect(notes.cardCount == 2, "Notes shows both notes")
        expect(notes.editableCardCount == 2, "saved cards can be edited")
        expect(notes.selectedEntryID == noteA.id, "first note is selected")
        expect(!notes.clearButtonVisible, "Notes hides clear")
        expect(notes.countText == "2 ITEMS", "Notes count")
        expect(notes.hint.contains("↩ INSERT"), "Notes hint offers insertion")

        expect(pane.handleKeyDown(key(kVK_RightArrow)), "arrow owned")
        expect(pane.capsuleRailSnapshotForSmoke().selectedEntryID == noteB.id, "arrow selects next note")
        expect(pane.handleKeyDown(key(kVK_Return)), "Return owned")
        expect(activated.map(\.id) == [noteB.id], "Return activates the selected note")
        expect(pane.handleKeyDown(key(kVK_ANSI_C, modifiers: .command)), "Command-C owned")
        expect(copied.map(\.id) == [noteB.id], "Command-C copies the selected note")
        expect(pane.handleKeyDown(key(kVK_Delete)), "Delete owned")
        expect(pane.capsuleRailSnapshotForSmoke().cardCount == 2, "Delete never removes a saved entry")
        expect(model.itemCount == 1, "Delete on a saved tab leaves history alone")
        expect(historyActivations == 0, "saved activation never reaches history")

        _ = pane.appendSearchText("焦点")
        let searched = pane.capsuleRailSnapshotForSmoke()
        expect(searched.cardCount == 1, "search filters saved cards")
        expect(searched.countText == "1 / 2", "search count")
        pane.resetSearch()

        expect(
            pane.handleSavedCardInteraction(id: noteA.id, clickCount: 2),
            "double click activates"
        )
        expect(activated.last?.id == noteA.id, "double click activates that note")

        pane.selectTab(.saved(.password))
        pane.layoutSubtreeIfNeeded()
        let passwords = pane.capsuleRailSnapshotForSmoke()
        expect(passwords.cardCount == 1, "Password shows its entry")
        expect(passwords.hint.contains("PASSWORDS"), "Password hint says it stays in the manager")
        let activationsBefore = activated.count
        let copiesBefore = copied.count
        _ = pane.handleKeyDown(key(kVK_Return))
        _ = pane.handleKeyDown(key(kVK_ANSI_1, modifiers: .command))
        _ = pane.handleKeyDown(key(kVK_ANSI_C, modifiers: .command))
        expect(activated.count == activationsBefore, "a password never activates")
        expect(copied.count == copiesBefore, "a password never copies")

        expect(pane.handleKeyDown(key(kVK_Tab)), "Tab from the last tab")
        expect(pane.selectedTab == .recent, "Tab wraps to Recent")
        expect(pane.capsuleRailSnapshotForSmoke().cardCount == 1, "Recent shows history again")

        model.update(windowVisible: true, captureEnabled: true, protection: [.secureInput])
        pane.selectTab(.saved(.note))
        let shielded = pane.capsuleRailSnapshotForSmoke()
        expect(shielded.cardCount == 0, "protection hides saved cards")
        expect(shielded.stateMessage == "安全输入期间已隐藏内容", "protection message on a saved tab")
    }

    private static func entry(_ kind: CapsuleEntryKind,
                              _ title: String,
                              _ body: String,
                              _ date: Date) -> CapsuleRailEntry {
        CapsuleRailEntry(
            id: UUID(),
            kind: kind,
            title: title,
            preview: body,
            updatedAt: date,
            payload: body,
            searchText: title + "\n" + body
        )
    }

    private static func key(_ code: Int,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(code)
        )!
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class CapsuleRailPasteboardDouble: ClipboardHistoryPasteboardReading {
    var changeCount: Int { 0 }
    func readPlainText() -> String? { nil }
}
