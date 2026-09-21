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
        checkSaveRules(expect: expect)
        checkSaver(expect: expect)
        checkSavedIndexAndMarkers(expect: expect)
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
            entry(.note, "dev-reload", "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./dev-reload.sh", now.addingTimeInterval(-600_000)),
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
        if tab == .recent {
            library.reload()
            waitUntil { library.state(for: .note) == .loaded }
        } else {
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

    /// Renders the Capsule manager with sample notes from temporary stores,
    /// at its default size, to a PNG at `path`.
    static func renderManagerPreview(to path: String) -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimes-capsule-manager-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = CapsuleContentStore(rootURL: root)
        let passwordStore = CapsulePasswordStore(rootURL: root)
        let samples = [
            ("Capsule 合并方案", "合并体验，不合并存储。\n\n- 最近：本机剪贴板历史，不上 iCloud\n- 收入：⌘S 把选中项写成 Capsule 条目\n- 密码：只在管理视图查看，仍需四组并击"),
            ("RIMES 本机构建", "DEVELOPER_DIR 指向 Xcode 再跑 dev-reload.sh；装完看 ~/rimebuffer.log。"),
            ("Electron 输入框", "打开 AXManualAccessibility 后约 3 秒树才建好。"),
        ]
        for (title, content) in samples.reversed() {
            _ = try? contentStore.put(CapsuleContentWriteRequest(
                type: .note,
                title: title,
                content: content
            ))
        }
        let pane = CapsulePaneViewController(
            repository: CapsuleWindowRepository(
                contentStore: contentStore,
                passwordStore: passwordStore
            ),
            cloudSyncController: nil
        )
        let size = CapsuleWindowGeometry.defaultContentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = pane
        window.setContentSize(size)
        pane.reloadFromStore()
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        pane.view.layoutSubtreeIfNeeded()
        pane.view.displayIfNeeded()
        guard let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) else {
            return false
        }
        pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    private static func checkRules(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        expect(
            CapsuleRailTab.ordered.map(\.label) == ["最近", "捕获", "笔记", "图片", "视频", "PDF", "技能", "密码"],
            "tab order"
        )
        expect(CapsuleRailTab.recent.cycled(by: -1) == .saved(.password), "tabs wrap backward")
        expect(CapsuleRailTab.saved(.password).cycled(by: 1) == .recent, "tabs wrap forward")
        expect(CapsuleRailTab.saved(.note).cycled(by: 3) == .saved(.pdf), "tabs step")
        expect(CapsuleRailActivationRules.action(for: .note) == .insertText, "note inserts text")
        for kind in [CapsuleEntryKind.image, .video, .pdf, .skill] {
            expect(
                CapsuleRailActivationRules.action(for: kind) == .pasteFile,
                "\(kind.rawValue) pastes a file"
            )
        }
        expect(CapsuleRailActivationRules.action(for: .password) == .refuse, "password is refused")
        expect(!CapsuleRailActivationRules.allowsCopy(.password), "password never copies")
        expect(CapsuleRailActivationRules.allowsCopy(.note), "note copies")
        expect(CapsuleRailCountText.items(1) == "1 ITEM", "singular count")
        expect(CapsuleRailCountText.items(3) == "3 ITEMS", "plural count")
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
        expect(recent.editableCardCount == 1, "a text history card offers the brush")
        var savedFromHistory: [[UUID]] = []
        pane.onSaveHistory = { items in savedFromHistory.append(items.map(\.id)); return true }
        expect(pane.handleKeyDown(key(kVK_ANSI_S, modifiers: .command)), "Command-S owned on Recent")
        expect(savedFromHistory.count == 1, "Command-S saves the selected history card")

        expect(pane.handleKeyDown(key(kVK_Tab)), "Tab is owned by the rail")
        expect(pane.selectedTab == .captures, "Tab moves to captures")
        expect(pane.handleKeyDown(key(kVK_Tab)), "next Tab moves onward")
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
        expect(
            pane.handleKeyDown(key(kVK_ANSI_S, modifiers: .command)),
            "Command-S stays owned on a saved tab, so it never reaches the host"
        )
        expect(savedFromHistory.count == 1, "Command-S saves nothing from a saved tab")
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

    private static func checkSaveRules(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        expect(
            CapsuleRailSaveRules.title(fromText: "  \n  第一行   标题 \n第二行") == "第一行 标题",
            "title is the first non-empty line, whitespace collapsed"
        )
        let long = String(repeating: "长", count: 80)
        expect(
            CapsuleRailSaveRules.title(fromText: long) == String(repeating: "长", count: 60) + "…",
            "a long first line is bounded"
        )
        expect(CapsuleRailSaveRules.isSaveable(.text), "text is saveable")
        expect(!CapsuleRailSaveRules.isSaveable(.color), "color is not saveable")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard let textArchive = archive(["public.utf8-plain-text": Data("第一行\n正文".utf8)]),
              let fileArchive = try? ClipboardPasteboardArchive(items: [
                .init(types: ["public.file-url"], dataByType: ["public.file-url": Data("file:///tmp/报告.pdf".utf8)]),
                .init(types: ["public.file-url"], dataByType: ["public.file-url": Data("file:///tmp/notes.txt".utf8)]),
              ]),
              let png = fixturePNG(),
              let imageArchive = archive(["public.png": png]) else {
            expect(false, "could not build rule archives")
            return
        }
        expect(
            CapsuleRailSaveRules.plans(kind: .text, completeText: nil, capturedAt: now, archive: textArchive)
                == [.note(title: "第一行", text: "第一行\n正文")],
            "text becomes a note, falling back to the archive text"
        )
        expect(
            CapsuleRailSaveRules.plans(kind: .link, completeText: "https://example.com", capturedAt: now, archive: textArchive)
                == [.note(title: "https://example.com", text: "https://example.com")],
            "a link becomes a note of its complete text"
        )
        expect(
            CapsuleRailSaveRules.plans(kind: .files, completeText: nil, capturedAt: now, archive: fileArchive)
                == [.file(kind: .pdf, title: "报告.pdf", path: "/tmp/报告.pdf"), .unsupported(.fileType)],
            "a PDF file becomes a PDF entry; other files are refused"
        )
        if case let .imageData(_, data, fileExtension)? = CapsuleRailSaveRules.plans(
            kind: .image, completeText: nil, capturedAt: now, archive: imageArchive
        ).first {
            expect(data == png && fileExtension == "png", "a pasted PNG is stored as PNG")
        } else {
            expect(false, "a pasted image becomes image data")
        }
        expect(
            CapsuleRailSaveRules.plans(kind: .color, completeText: nil, capturedAt: now, archive: textArchive)
                == [.unsupported(.kind)],
            "a color is refused"
        )

        let id = UUID()
        expect(CapsuleRailSaveRules.toast(for: [.saved(.note, id)]) == "已收入 Capsule · 笔记", "single save toast")
        expect(CapsuleRailSaveRules.toast(for: [.saved(.note, id), .saved(.image, id)]) == "已收入 Capsule · 2 条", "multiple save toast")
        expect(CapsuleRailSaveRules.toast(for: [.alreadySaved(.note, id)]) == "已在 Capsule 中", "duplicate toast")
        expect(CapsuleRailSaveRules.toast(for: [.unsupported(.kind)]) == "此类型暂不能收入 Capsule", "unsupported toast")
        expect(CapsuleRailSaveRules.toast(for: [.failed]) == "收入 Capsule 失败", "failure toast")
    }

    private static func checkSaver(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rimes-capsule-rail-save-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = CapsuleContentStore(rootURL: root)
        let passwordStore = CapsulePasswordStore(rootURL: root)
        let saver = CapsuleRailSaver(
            contentStore: contentStore,
            repository: CapsuleWindowRepository(
                contentStore: contentStore,
                passwordStore: passwordStore
            ),
            assetsURL: root.appendingPathComponent("assets", isDirectory: true)
        )
        let note = CapsuleRailSavePlan.note(title: "焦点租约", text: "FocusToken 只认 client")
        let first = saver.save([note])
        let second = saver.save([note])
        guard case let .saved(.note, noteID)? = first.first else {
            expect(false, "a note plan saves: \(first)")
            return
        }
        expect(second == [.alreadySaved(.note, noteID)], "saving the same text again finds the entry")

        guard let png = fixturePNG() else {
            expect(false, "could not build a PNG")
            return
        }
        let image = saver.save([.imageData(title: "图片", data: png, fileExtension: "png")])
        let imageAgain = saver.save([.imageData(title: "图片", data: png, fileExtension: "png")])
        guard case let .saved(.image, imageID)? = image.first,
              let record = try? contentStore.record(id: imageID) else {
            expect(false, "pasted image data saves as an Image entry: \(image)")
            return
        }
        let assetURL = URL(fileURLWithPath: record.content)
        expect(
            assetURL.deletingLastPathComponent().lastPathComponent == "assets"
                && assetURL.deletingPathExtension().lastPathComponent.count == 64,
            "pasted image lands in assets under its SHA-256"
        )
        let mode = (try? FileManager.default.attributesOfItem(atPath: assetURL.path))?[.posixPermissions] as? NSNumber
        expect(mode?.intValue == 0o600, "asset file is private")
        expect(imageAgain == [.alreadySaved(.image, imageID)], "the same image is saved once")

        let pdfURL = root.appendingPathComponent("报告.pdf")
        try? Data("%PDF-1.4\n%rimes smoke\n".utf8).write(to: pdfURL)
        let pdf = saver.save([.file(kind: .pdf, title: "报告.pdf", path: pdfURL.path)])
        if case .saved(.pdf, _)? = pdf.first {} else {
            expect(false, "a PDF file saves as a PDF entry: \(pdf)")
        }
        expect(
            saver.save([.unsupported(.fileType)]) == [.unsupported(.fileType)],
            "unsupported plans write nothing"
        )
    }

    private static func checkSavedIndexAndMarkers(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        let suite = "RimeBuffer.CapsuleRailSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = UUID()
        let entry = UUID()
        let index = CapsuleRailSavedIndex(defaults: defaults)
        index.record(historyItem: history, entry: entry)
        expect(
            CapsuleRailSavedIndex(defaults: defaults).entryID(forHistoryItem: history) == entry,
            "saved index persists"
        )
        index.prune(keeping: [])
        expect(
            CapsuleRailSavedIndex(defaults: defaults).entryID(forHistoryItem: history) == nil,
            "saved index forgets deleted entries"
        )

        let model = ClipboardHistoryModel(
            configuration: .init(),
            pasteboard: CapsuleRailPasteboardDouble(),
            schedulesAutomaticPolling: false
        )
        model.start()
        model.update(windowVisible: true, captureEnabled: true, protection: [])
        _ = model.ingest("already a note")
        _ = model.ingest("not saved")
        let note = self.entry(.note, "already", "already a note", Date())
        let library = CapsuleRailLibrary(
            loader: { (.success([note]), .success([])) },
            savedIndex: CapsuleRailSavedIndex(defaults: nil)
        )
        let pane = ClipboardHistoryPaneView(model: model, library: library)
        pane.frame = NSRect(
            x: 0,
            y: 0,
            width: ClipboardHistoryWindowMetrics.preferredWidth,
            height: ClipboardHistoryWindowMetrics.preferredHeight
        )
        library.reload()
        waitUntil { library.state(for: .note) == .loaded }
        pane.layoutSubtreeIfNeeded()
        let snapshot = pane.capsuleRailSnapshotForSmoke()
        expect(snapshot.cardCount == 2, "marker pane shows both history cards")
        expect(snapshot.inCapsuleCardCount == 1, "only the card matching a note is marked")
    }

    private static func archive(_ dataByType: [String: Data]) -> ClipboardPasteboardArchive? {
        try? ClipboardPasteboardArchive(items: [
            .init(types: Array(dataByType.keys), dataByType: dataByType),
        ])
    }

    private static func fixturePNG() -> Data? {
        guard let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
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
