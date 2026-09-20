import AppKit
import AVKit
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private var launcher: CapturePanel?
    private var selectors: [CapturePanel] = []
    private var overlays: [UUID: CapturePanel] = [:]
    /// Stacking order; the dictionary alone cannot say which card is newest.
    private var overlayOrder: [UUID] = []
    private var pins: [UUID: CapturePanel] = [:]
    private var editors: [UUID: CaptureEditor] = [:]
    private var otherPanels: [CapturePanel] = []
    private var lastClosed: UUID?
    private var generation = UUID()
    private var previousTarget: CaptureTarget?
    private var sourceName = ""
    private var sourceApplication: NSRunningApplication?
    private var temporarilyHidden: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var protectionTimer: Timer?
    private var cleanupTimer: Timer?
    private var sessionProtected = false
    private var scrollSession: CaptureScrollSession?
    private var recorder: CaptureRecorderController?
    private let queue = DispatchQueue(label: "RIMES.Capture.work", qos: .userInitiated)
    private var store: CaptureStore { get throws { try CaptureStore.shared.get() } }

    private init() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { sourceApplication = front }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.sourceApplication = application }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .capsuleCapturesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleAssets() }
        })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.protect() }
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sessionProtected = false }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.protect() } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sessionProtected = false } })
        protectionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard IsSecureEventInputEnabled() else { return }
                self?.recorder?.pauseForProtection()
                self?.selectors.forEach { $0.close() }
                self?.selectors.removeAll()
            }
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { _ = try? CaptureStore.shared.get().prune() }
        }
        queue.async { _ = try? CaptureStore.shared.get().recoverInterruptedRecordings(); _ = try? CaptureStore.shared.get().prune() }
    }

    private func refreshVisibleAssets() {
        guard !sessionProtected else { return }
        let ids = Set(overlays.keys).union(pins.keys)
        guard !ids.isEmpty else { return }
        queue.async {
            guard let records = try? CaptureStore.shared.get().records() else { return }
            DispatchQueue.main.async {
                guard !self.sessionProtected else { return }
                for record in records where ids.contains(record.id) {
                    if let overlay = self.overlays[record.id] {
                        let origin = overlay.frame.origin
                        overlay.close(); self.showOverlay(record); self.overlays[record.id]?.setFrameOrigin(origin)
                    }
                    if let pin = self.pins[record.id] {
                        let frame = pin.frame, alpha = pin.alphaValue, locked = pin.ignoresMouseEvents
                        pin.close(); self.pin(record)
                        self.pins[record.id]?.setFrame(frame, display: true); self.pins[record.id]?.alphaValue = alpha; self.pins[record.id]?.ignoresMouseEvents = locked
                    }
                }
            }
        }
    }

    private func protect() {
        sessionProtected = true; generation = UUID()
        selectors.forEach { $0.close() }; selectors.removeAll()
        launcher?.close()
        overlays.values.forEach { $0.orderOut(nil) }; pins.values.forEach { $0.orderOut(nil) }
        editors.values.forEach { $0.panel.orderOut(nil) }
        otherPanels.forEach { $0.orderOut(nil) }
        scrollSession?.cancel(); recorder?.stop()
    }

    private func restoreHiddenPanels() {
        guard !sessionProtected else { return }
        pins.values.forEach { $0.orderFrontRegardless() }
        temporarilyHidden.forEach { $0.orderFrontRegardless() }; temporarilyHidden.removeAll()
        layoutOverlays()
    }

    private func keepPanel(_ panel: CapturePanel) {
        let previous = panel.closed
        panel.closed = { [weak self, weak panel] in
            previous?()
            guard let panel else { return }
            self?.otherPanels.removeAll { $0 === panel }
            panel.contentView = nil
        }
        otherPanels.append(panel)
    }

    func showLauncher() {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { NSSound.beep(); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { sourceApplication = NSWorkspace.shared.frontmostApplication }
        sourceName = sourceApplication?.localizedName ?? ""
        ClipboardHistoryWindowController.shared.hide()
        if let launcher, launcher.isVisible { launcher.makeKeyAndOrderFront(nil); return }
        let panel = CapturePanel(size: NSSize(width: 812, height: 62))
        let delay = NSPopUpButton(); delay.addItems(withTitles: ["立即", "3 秒", "5 秒", "10 秒"])
        let ratio = NSPopUpButton(); ratio.addItems(withTitles: ["自由比例", "1:1", "4:3", "16:9", "9:16"])
        let width = NSTextField(string: ""); width.placeholderString = "宽 pt"; width.widthAnchor.constraint(equalToConstant: 65).isActive = true
        let height = NSTextField(string: ""); height.placeholderString = "高 pt"; height.widthAnchor.constraint(equalToConstant: 65).isActive = true
        // The glyph is the control: clicking it flips the state it draws.
        let freezeToggle = CaptureGlyphButton(symbol: "snowflake",
                                              tooltip: "冻结选区画面")
        freezeToggle.isOn = true
        freezeToggle.onClick = { [weak freezeToggle] in freezeToggle?.isOn.toggle() }
        let run: (String) -> Void = { [weak self, weak panel] mode in
            let seconds = [0, 3, 5, 10][delay.indexOfSelectedItem]
            let ratios: [CGFloat?] = [nil, 1, 4 / 3, 16 / 9, 9 / 16]
            let size = width.doubleValue > 0 && height.doubleValue > 0 ? CGSize(width: min(16384, width.doubleValue), height: min(16384, height.doubleValue)) : nil
            panel?.close()
            self?.begin(mode, delay: seconds, ratio: ratios[ratio.indexOfSelectedItem], size: size, freeze: freezeToggle.isOn)
        }
        // One horizontal strip: capture modes, then capture options, then the
        // things you reach for afterwards. Icons carry the meaning and the
        // names survive as tooltips, so the panel stops being a wall of
        // Chinese labels at four different widths.
        delay.toolTip = "延时"
        ratio.toolTip = "选区比例"
        width.toolTip = "固定宽度 (pt)"
        height.toolTip = "固定高度 (pt)"
        let strip = CaptureUI.row([
            CaptureGlyphButton(symbol: "viewfinder", tooltip: "区域 ⌘⇧4",
                               prominent: true) { run("area") },
            CaptureGlyphButton(symbol: "macwindow", tooltip: "窗口") { run("window") },
            CaptureGlyphButton(symbol: "display", tooltip: "全屏") { run("screen") },
            CaptureUI.verticalSeparator(),
            CaptureGlyphButton(symbol: "arrow.up.arrow.down", tooltip: "滚动截图") { run("scroll") },
            CaptureGlyphButton(symbol: "text.viewfinder", tooltip: "取字 OCR") { run("ocr") },
            CaptureGlyphButton(symbol: "record.circle", tooltip: "录屏") { [weak self, weak panel] in
                panel?.close(); self?.showRecorder()
            },
            CaptureUI.verticalSeparator(),
            delay, ratio, width, height, freezeToggle,
            CaptureUI.verticalSeparator(),
            CaptureGlyphButton(symbol: "arrow.counterclockwise", tooltip: "重截上次区域") { run("previous") },
            CaptureGlyphButton(symbol: "rectangle.on.rectangle", tooltip: "恢复浮层") { [weak self] in
                self?.restoreOverlay()
            },
            CaptureGlyphButton(symbol: "folder", tooltip: "打开工程") { self.openProject() },
            CaptureGlyphButton(symbol: "gearshape", tooltip: "捕获设置") { [weak self] in
                self?.showOptions()
            },
            CaptureUI.verticalSeparator(),
            CaptureGlyphButton(symbol: "xmark", tooltip: "关闭") { [weak panel] in panel?.close() },
        ], spacing: 6)
        strip.alignment = .centerY
        CaptureUI.fill(strip, in: panel.contentView!, inset: 12)
        launcher = panel
        panel.closed = { [weak self, weak panel] in self?.launcher = nil; panel?.contentView = nil }
        panel.present()
    }

    func begin(_ mode: String, delay: Int = 0, ratio: CGFloat? = nil, size: CGSize? = nil, freeze: Bool = true) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        // Through the shared audit, so the permissions page and the feature
        // agree on what was asked for and what the answer was.
        guard SystemPermissionAudit.ensure(.screenRecording) else {
            CaptureUI.error(CaptureError.message("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 RIMES，然后重试。可在 RIMES 设置 → 系统权限中逐项检查。")); return
        }
        generation = UUID(); let token = generation
        selectors.forEach { $0.close() }; selectors.removeAll()
        ClipboardHistoryWindowController.shared.hide()
        // Result overlays used to be closed here, which is why only ever one
        // was on screen: each capture destroyed the stack it was about to
        // add to. They are hidden for the duration like every other panel
        // and restored with them, so the results accumulate.
        pins.values.forEach { $0.orderOut(nil) }
        temporarilyHidden = overlays.values.filter(\.isVisible)
            + editors.values.map(\.panel).filter(\.isVisible)
            + otherPanels.filter(\.isVisible)
        temporarilyHidden.forEach { $0.orderOut(nil) }
        Task {
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }
                // Let AppKit remove the launcher before collecting shareable windows.
                try await Task.sleep(nanoseconds: 180_000_000)
                guard generation == token, !sessionProtected, !IsSecureEventInputEnabled() else { return }
                let content = try await CaptureEngine.content()
                if mode == "previous", let previousTarget {
                    guard content.displays.contains(where: { $0.displayID == previousTarget.display.displayID }) else { throw CaptureError.message("上次使用的显示器已断开") }
                    try await finish(target: previousTarget, content: content, mode: "area", snapshot: nil)
                    return
                }
                if mode == "window" || mode == "recordWindow" { chooseWindow(content, mode: mode == "recordWindow" ? "record" : "window"); return }
                if mode == "screen" || mode == "recordScreen" {
                    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                    let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw CaptureError.message("没有可捕获的显示器") }
                    try await finish(target: CaptureTarget(display: display, window: nil, rect: nil), content: content, mode: mode == "recordScreen" ? "record" : mode, snapshot: nil)
                    return
                }
                try await select(content, mode: mode, ratio: ratio, size: size, freeze: freeze)
            } catch { self.restoreHiddenPanels(); CaptureUI.error(error) }
        }
    }

    private func chooseWindow(_ content: SCShareableContent, mode: String) {
        let windows = content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 50 && $0.frame.height > 40 && $0.windowLayer == 0 }
        let chooser = NSPopUpButton()
        chooser.addItems(withTitles: windows.map { "\($0.owningApplication?.applicationName ?? "窗口") · \($0.title ?? "")" })
        let panel = CapturePanel(size: NSSize(width: 480, height: 130))
        let confirm = CaptureButton("捕获窗口") { [weak self, weak panel] in
            guard let self, windows.indices.contains(chooser.indexOfSelectedItem), let display = content.displays.first else { return }
            let window = windows[chooser.indexOfSelectedItem]
            let matchingDisplay = content.displays.max { a, b in
                let ar = a.frame.intersection(window.frame), br = b.frame.intersection(window.frame)
                return ar.width*ar.height < br.width*br.height
            } ?? display
            let target = CaptureTarget(display: matchingDisplay, window: window, rect: nil)
            panel?.close()
            Task { do { try await self.finish(target: target, content: content, mode: mode, snapshot: nil) } catch { CaptureUI.error(error) } }
        }
        CaptureUI.fill(CaptureUI.column([CaptureUI.label("选择窗口"), chooser, CaptureUI.row([confirm, CaptureButton("取消") { [weak panel] in panel?.close() }])]), in: panel.contentView!)
        keepPanel(panel); panel.present()
    }

    private func select(_ content: SCShareableContent, mode: String, ratio: CGFloat?, size: CGSize?, freeze: Bool) async throws {
        let request = generation
        var frames: [(NSScreen, SCDisplay, CGImage)] = []
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let image = try await CaptureEngine.image(CaptureTarget(display: display, window: nil, rect: nil), content: content, scale: screen.backingScaleFactor)
            frames.append((screen, display, image))
        }
        guard request == generation, !sessionProtected, !IsSecureEventInputEnabled() else { return }
        for (screen, display, image) in frames {
            let panel = CapturePanel(size: screen.frame.size)
            panel.styleMask = [.borderless]; panel.level = .screenSaver; panel.isMovableByWindowBackground = false
            panel.setFrame(screen.frame, display: false)
            let view = CaptureSelectionView(image: image); view.fixedSize = size; view.ratio = ratio
            view.cancelled = { [weak self] in self?.selectors.forEach { $0.close() }; self?.selectors.removeAll(); self?.restoreHiddenPanels(); self?.sourceApplication?.activate(options: [.activateIgnoringOtherApps]) }
            view.selected = { [weak self] rect in
                guard let self, self.generation == request else { return }
                self.selectors.forEach { $0.close() }; self.selectors.removeAll()
                let target = CaptureTarget(display: display, window: nil, rect: rect)
                let factor = CGFloat(image.width) / screen.frame.width
                let crop = freeze ? image.cropping(to: CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)) : nil
                Task { do { try await self.finish(target: target, content: content, mode: mode, snapshot: mode == "scroll" || mode == "record" ? nil : crop) } catch { CaptureUI.error(error) } }
            }
            panel.contentView = view; selectors.append(panel); panel.present(center: false); panel.makeFirstResponder(view)
        }
    }

    private func finish(target: CaptureTarget, content: SCShareableContent, mode: String, snapshot: CGImage?) async throws {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        restoreHiddenPanels()
        previousTarget = target
        if mode == "scroll" {
            scrollSession = CaptureScrollSession(target: target, content: content, sourceApplication: sourceApplication) { [weak self] image, incomplete in self?.save(image, kind: .scrolling, incomplete: incomplete) }
            scrollSession?.show(); return
        }
        if mode == "record" { recorder?.start(target: target, content: content); return }
        let image: CGImage
        if let snapshot { image = snapshot } else { image = try await CaptureEngine.image(target, content: content) }
        save(image, recognize: mode == "ocr")
    }

    func save(_ image: CGImage, kind: CaptureKind = .image, incomplete: Bool = false, recognize: Bool = false) {
        let source = sourceName
        queue.async {
            let result = Result { try CaptureStore.shared.get().importImage(image, kind: kind, source: source, incomplete: incomplete) }
            DispatchQueue.main.async {
                switch result {
                case .success(let record): self.showOverlay(record); if recognize { self.ocr(record) }
                case .failure(let error): CaptureUI.error(error)
                }
            }
        }
    }

    func showOverlay(_ record: CaptureRecord) {
        guard !sessionProtected else { return }
        IMELog.write("capture overlay show kind=\(record.kind.label) "
            + "thumbnail=\(record.thumbnail != nil) stack=\(overlays.count)")
        do {
            let store = try store
            if let old = overlays[record.id] { old.orderFrontRegardless(); return }
            let scale = max(0.8, min(1.5, UserDefaults.standard.object(forKey: "capture.overlay.scale") as? Double ?? 1))
            // Smaller than before so a stack of them fits down one edge:
            // the thumbnail is the whole card, and the controls arrive on
            // hover instead of taking a permanent row each.
            let width = 224 * scale
            let height = 128 * scale
            let panel = CapturePanel(size: NSSize(width: width, height: height), key: false)
            let body = CaptureHoverView()
            let preview = CaptureDragImageView()
            preview.fillsFrame = true
            preview.file = store.url(record)
            CaptureUI.fill(preview, in: body, inset: 0)
            // Every card is the same rectangle. An NSImageView reports its
            // image's size as its intrinsic size, so without these the card
            // grew to whatever it happened to be showing: cards of different
            // sizes, positions computed from a height the panel no longer
            // had, and neighbours overlapping each other.
            body.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                body.widthAnchor.constraint(equalToConstant: width),
                body.heightAnchor.constraint(equalToConstant: height),
            ])
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                preview.setContentHuggingPriority(.defaultLow, for: axis)
                preview.setContentCompressionResistancePriority(.defaultLow, for: axis)
            }
            let previewLoad = loadOverlayPreview(record, store: store, into: preview)

            let close = CaptureGlyphButton(symbol: "xmark", tooltip: "关闭") { [weak panel] in
                panel?.close()
            }
            let actions = CaptureUI.row([
                CaptureGlyphButton(symbol: "doc.on.doc", tooltip: "复制") { self.copy(record) },
                CaptureGlyphButton(
                    symbol: record.kind.capsuleKind == .video ? "play.fill" : "pencil.tip.crop.circle",
                    tooltip: record.kind.capsuleKind == .video ? "播放" : "标注"
                ) { self.edit(record) },
                CaptureGlyphButton(symbol: "tray.and.arrow.down", tooltip: "收入 Capsule") { self.collect(record) },
                CaptureGlyphButton(symbol: "ellipsis", tooltip: "更多") { self.showActions(record) },
            ], spacing: 4)
            for control in [close, actions] {
                control.translatesAutoresizingMaskIntoConstraints = false
                control.alphaValue = 0
                body.addSubview(control)
            }
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: body.topAnchor, constant: 6),
                close.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
                actions.centerXAnchor.constraint(equalTo: body.centerXAnchor),
                actions.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -6),
            ])
            body.onHover = { [weak close, weak actions] inside in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    close?.animator().alphaValue = inside ? 1 : 0
                    actions?.animator().alphaValue = inside ? 1 : 0
                }
            }
            CaptureUI.fill(body, in: panel.contentView!, inset: 0)

            guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理，请刷新捕获历史") }
            panel.closed = { [weak self] in
                previewLoad.cancel()
                store.release(record.id)
                self?.lastClosed = record.id
                self?.overlays.removeValue(forKey: record.id)
                self?.overlayOrder.removeAll { $0 == record.id }
                self?.layoutOverlays()
            }
            overlays[record.id] = panel
            overlayOrder.append(record.id)
            panel.present(center: false)
            layoutOverlays()
            // If a card is still blank a moment later, say what state it is
            // in rather than leaving it to guesswork.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak panel, weak preview] in
                guard let panel, let preview else { return }
                IMELog.write("capture overlay settled visible=\(panel.isVisible) "
                    + "alpha=\(panel.alphaValue) "
                    + "occluded=\(!panel.occlusionState.contains(.visible)) "
                    + "hasImage=\(preview.image != nil) "
                    + "origin=\(Int(panel.frame.minX)),\(Int(panel.frame.minY))")
            }
            queue.async { _ = try? store.prune() }
            let seconds = UserDefaults.standard.double(forKey: "capture.overlay.seconds")
            if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak panel] in panel?.close() } }
        } catch { CaptureUI.error(error) }
    }

    /// The overlay used to show the rendered preview only. When that file is
    /// not written yet — or the loader declines the type — nothing was set
    /// and the card came up black. Fall back to the captured file itself and
    /// say so in the log rather than presenting an empty rectangle.
    @discardableResult
    private func loadOverlayPreview(_ record: CaptureRecord,
                                    store: CaptureStore,
                                    into view: NSImageView) -> Operation {
        let original = store.url(record)
        return CapsuleMediaPreviewLoader.shared.load(
            kind: record.thumbnail == nil ? record.kind.capsuleKind : .image,
            path: store.previewURL(record).path,
            maximumPixelSize: 512
        ) { result in
            if case let .image(image) = result {
                IMELog.write("capture overlay preview loaded "
                    + "\(image.width)x\(image.height)")
                view.image = NSImage(cgImage: image, size: .zero)
                // The image lands about 30ms after the panel is presented.
                // CaptureDragImageView draws it itself when fillsFrame is
                // set, bypassing the cell that would normally invalidate, so
                // the newest card stayed blank until something else forced a
                // redraw — which is exactly why entering capture mode and
                // pressing Esc "fixed" it: that re-orders every card.
                view.needsDisplay = true
                view.window?.viewsNeedDisplay = true
                view.window?.displayIfNeeded()
                return
            }
            if let fallback = NSImage(contentsOf: original) {
                IMELog.write("capture overlay preview unavailable; using the original")
                view.image = fallback
                view.needsDisplay = true
                view.window?.viewsNeedDisplay = true
                view.window?.displayIfNeeded()
            } else {
                IMELog.write("capture overlay has no displayable preview for "
                    + "\(record.kind.label)")
            }
        }
    }

    /// Results stack up one edge, newest nearest the corner, and reflow when
    /// one is dismissed. A fixed three-step cascade overlapped them and lost
    /// everything past the third.
    private func layoutOverlays() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let onLeft = UserDefaults.standard.object(forKey: "capture.overlay.left") as? Bool ?? true
        var y = visible.minY + 18
        for id in overlayOrder.reversed() {
            // Only cards that are actually on screen take a slot. A panel
            // that is hidden — during a capture, or before it is presented —
            // used to reserve the bottom position and show nothing there,
            // which read as a missing card with an empty space under the
            // column.
            guard let panel = overlays[id], panel.isVisible else { continue }
            let x = onLeft
                ? visible.minX + 18
                : visible.maxX - panel.frame.width - 18
            panel.setFrameOrigin(CGPoint(x: x, y: y))
            // What the Esc path does, and what made a blank card appear.
            panel.orderFrontRegardless()
            IMELog.write("capture overlay slot y=\(Int(y)) "
                + "size=\(Int(panel.frame.width))x\(Int(panel.frame.height)) "
                + "visible=\(panel.isVisible)")
            y += panel.frame.height + 8
            if y > visible.maxY - panel.frame.height { break }
        }
    }

    func showActions(_ record: CaptureRecord) {
        let panel = CapturePanel(size: NSSize(width: 310, height: 170))
        var actions: [NSView] = [CaptureUI.label(record.title), CaptureUI.row([CaptureButton("保存文件") { self.export(record) }, CaptureButton("收入 Capsule") { self.collect(record) }])]
        if record.kind.capsuleKind == .image {
            actions.append(CaptureUI.row([CaptureButton("取字 / 二维码") { self.ocr(record) }, CaptureButton("贴图") { self.pin(record) }]))
        } else { actions.append(CaptureButton("播放预览") { self.edit(record) }) }
        actions.append(CaptureButton("关闭") { [weak panel] in panel?.close() })
        CaptureUI.fill(CaptureUI.column(actions), in: panel.contentView!)
        keepPanel(panel); panel.present()
    }
    func restoreOverlay() { if let id = lastClosed, let record = try? store.record(id) { showOverlay(record) } }
    private func openProject() {
        let dialog = NSOpenPanel(); dialog.allowedContentTypes = [UTType(filenameExtension: "rimesproject") ?? .data]
        dialog.begin { response in
            guard response == .OK, let url = dialog.url else { return }
            self.queue.async {
                do {
                    let record = try CaptureStore.shared.get().importProject(url)
                    DispatchQueue.main.async { self.edit(record) }
                } catch { DispatchQueue.main.async { CaptureUI.error(error) } }
            }
        }
    }
    func copy(_ record: CaptureRecord) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        let expectedChangeCount = NSPasteboard.general.changeCount
        queue.async {
            let result = Result {
                let store = try CaptureStore.shared.get(); guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理") }; defer { store.release(record.id) }
                let current = try store.record(record.id)
                return try CapsuleFilePasteboardWriter.prepare(kind: current.kind.capsuleKind, path: store.url(current).path)
            }
            DispatchQueue.main.async {
                guard !self.sessionProtected, !IsSecureEventInputEnabled() else { return }
                do { try CapsuleFilePasteboardWriter.write(result.get(), expectedChangeCount: expectedChangeCount) }
                catch { CaptureUI.error(error) }
            }
        }
    }
    func collect(_ record: CaptureRecord) {
        queue.async {
            do { _ = try CaptureStore.shared.get().collect(record.id) }
            catch { DispatchQueue.main.async { CaptureUI.error(error) } }
        }
    }
    func export(_ record: CaptureRecord) {
        let dialog = NSSavePanel(); dialog.nameFieldStringValue = record.title + "." + URL(fileURLWithPath: record.output).pathExtension
        dialog.begin { response in
            guard response == .OK, let destination = dialog.url else { return }
            self.queue.async {
                do {
                    let store = try CaptureStore.shared.get(); guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理") }; defer { store.release(record.id) }
                    let source = store.url(try store.record(record.id))
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
                    else { try FileManager.default.moveItem(at: temporary, to: destination) }
                } catch { DispatchQueue.main.async { CaptureUI.error(error) } }
            }
        }
    }
    func edit(_ record: CaptureRecord) {
        if record.kind == .gif {
            guard let store = try? store, store.acquire(record.id) else { return }
            let url = store.url(record)
            let panel = CapturePanel(size: NSSize(width: 640, height: 440))
            let view = NSImageView(); view.animates = true; view.imageScaling = .scaleProportionallyUpOrDown
            queue.async { let image = NSImage(contentsOf: url); DispatchQueue.main.async { view.image = image } }
            CaptureUI.fill(view, in: panel.contentView!, inset: 8)
            panel.closed = { store.release(record.id) }
            keepPanel(panel); panel.present(); return
        }
        if record.kind == .video {
            guard let store = try? store, store.acquire(record.id) else { return }
            let url = store.url(record)
            let panel = CapturePanel(size: NSSize(width: 800, height: 500))
            let player = AVPlayerView(); player.player = AVPlayer(url: url); player.controlsStyle = .floating
            CaptureUI.fill(player, in: panel.contentView!, inset: 0)
            panel.closed = { player.player?.pause(); store.release(record.id) }; keepPanel(panel); panel.present(); return
        }
        if let editor = editors[record.id] { editor.panel.present(); return }
        do {
            let editor = try CaptureEditor(record: record, store: store)
            editors[record.id] = editor
            editor.onClose = { [weak self] in self?.editors.removeValue(forKey: record.id) }
            editor.show()
        } catch { CaptureUI.error(error) }
    }
    func editSaved(_ entry: CapsuleRailEntry) {
        guard let path = entry.payload, entry.kind == .image || entry.kind == .video else { return }
        queue.async {
            do {
                let store = try CaptureStore.shared.get()
                var record = try store.records().first { $0.collectionID == entry.id || store.url($0).path == path }
                if record == nil {
                    let package = URL(fileURLWithPath: path).appendingPathExtension("rimesproject")
                    var imported: CaptureRecord
                    if entry.kind == .image, FileManager.default.fileExists(atPath: package.path) {
                        imported = try store.importProject(package, title: entry.title, collectionID: entry.id)
                    } else {
                        imported = try store.importFile(URL(fileURLWithPath: path), kind: entry.kind == .video ? (URL(fileURLWithPath: path).pathExtension.lowercased() == "gif" ? .gif : .video) : .image, title: entry.title)
                        imported.collectionID = entry.id
                    }
                    try store.update(imported); record = imported
                }
                if let record { DispatchQueue.main.async { self.edit(record) } }
            } catch { DispatchQueue.main.async { CaptureUI.error(error) } }
        }
    }
    func ocr(_ record: CaptureRecord) {
        guard record.kind != .video, !sessionProtected else { return }
        queue.async {
            do {
                let store = try CaptureStore.shared.get()
                guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理") }; defer { store.release(record.id) }
                var updated = try store.record(record.id)
                let text = try CaptureEngine.recognize(CaptureImageIO.read(store.url(updated)))
                updated.text = text; try store.update(updated)
                DispatchQueue.main.async { if !self.sessionProtected { self.showText(text) } }
            } catch { DispatchQueue.main.async { CaptureUI.error(error) } }
        }
    }
    func showText(_ text: String) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        let panel = CapturePanel(size: NSSize(width: 560, height: 360))
        let view = NSTextView(); view.string = text; view.font = .systemFont(ofSize: 15); view.isRichText = false
        view.textColor = RimeUI.textPrimary; view.backgroundColor = RimeUI.surface2
        let scroll = NSScrollView(); scroll.documentView = view; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 530).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        let actions = CaptureUI.row([
            CaptureButton("复制文字") { guard !IsSecureEventInputEnabled() else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(view.string, forType: .string) },
            CaptureButton("存为笔记") { do { _ = try CapsuleWindowRepository().save(CapsuleWindowDraft(kind: .note, title: String(view.string.prefix(40)), content: view.string)) } catch { CaptureUI.error(error) } },
            CaptureButton("送入 Buffer") { [weak panel] in let value = view.string; panel?.close(); BufferWindowController.shared.importCaptureText(value) },
            CaptureButton("关闭") { [weak panel] in panel?.close() }
        ])
        CaptureUI.fill(CaptureUI.column([CaptureUI.label(text.isEmpty ? "未识别到文字或二维码" : "识别文字", size: 16), scroll, actions]), in: panel.contentView!)
        keepPanel(panel); panel.present()
    }
    func pin(_ record: CaptureRecord) {
        guard record.kind != .video, let store = try? store else { return }
        if let pin = pins[record.id] { pin.orderFrontRegardless(); return }
        let panel = CapturePinPanel(size: NSSize(width: 430, height: 310), key: false)
        panel.styleMask.insert(.resizable)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let image = CaptureDragImageView(); image.file = store.url(record); image.imageScaling = .scaleProportionallyUpOrDown
        image.clicked = { [weak panel] _ in panel?.makeKey(); panel?.makeFirstResponder(panel) }
        image.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        image.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        CapsuleMediaPreviewLoader.shared.load(kind: .image, path: store.url(record).path) { if case let .image(cg) = $0 { image.image = NSImage(cgImage: cg, size: .zero) } }
        let opacity = NSSlider(value: 1, minValue: 0.15, maxValue: 1, target: nil, action: nil)
        let binding = CaptureSliderAction { [weak panel, weak opacity] in panel?.alphaValue = opacity?.doubleValue ?? 1 }; opacity.target = binding; opacity.action = #selector(CaptureSliderAction.changed)
        let actions = CaptureUI.row([CaptureButton("锁定穿透") { [weak panel] in panel?.ignoresMouseEvents = true }, opacity, CaptureButton("关闭") { [weak panel] in panel?.close() }])
        CaptureUI.fill(CaptureUI.column([actions, image]), in: panel.contentView!)
        guard store.acquire(record.id) else { return }
        panel.closed = { [weak self, binding] in _ = binding; store.release(record.id); self?.pins.removeValue(forKey: record.id) }
        pins[record.id] = panel; panel.present()
    }
    func showRecorder() {
        if recorder?.isRecording == true { recorder?.showControls(); return }
        recorder = CaptureRecorderController { [weak self] in self?.begin("record", freeze: false) } completed: { [weak self] record in self?.showOverlay(record) }
        recorder?.showSettings()
    }
    func showOptions() {
        let panel = CapturePanel(size: NSSize(width: 480, height: 270))
        let left = NSButton(checkboxWithTitle: "浮层放在屏幕左下角", target: nil, action: nil); left.state = UserDefaults.standard.bool(forKey: "capture.overlay.left") ? .on : .off
        let seconds = NSTextField(string: String(Int(UserDefaults.standard.double(forKey: "capture.overlay.seconds"))))
        let scale = NSSlider(value: UserDefaults.standard.object(forKey: "capture.overlay.scale") as? Double ?? 1, minValue: 0.8, maxValue: 1.5, target: nil, action: nil)
        let restore = CaptureButton("应用") { [weak panel] in
            UserDefaults.standard.set(left.state == .on, forKey: "capture.overlay.left")
            UserDefaults.standard.set(max(0, seconds.doubleValue), forKey: "capture.overlay.seconds"); panel?.close()
            UserDefaults.standard.set(scale.doubleValue, forKey: "capture.overlay.scale")
        }
        CaptureUI.fill(CaptureUI.column([CaptureUI.label("捕获设置", size: 16), left, CaptureUI.row([CaptureUI.label("浮层自动关闭（秒，0 为保持）"), seconds]), CaptureUI.row([CaptureUI.label("预览大小"), scale]), CaptureUI.label("临时历史：30 天 / 10 GB · 收藏不清理"), CaptureUI.row([restore, CaptureButton("解锁贴图") { self.pins.values.forEach { $0.ignoresMouseEvents = false } }, CaptureButton("关闭所有贴图") { Array(self.pins.values).forEach { $0.close() } }])]), in: panel.contentView!)
        keepPanel(panel); panel.present()
    }
}

final class CaptureSliderAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func changed() { action() }
}
