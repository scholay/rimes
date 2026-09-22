import AppKit
import AVKit
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers

enum CaptureProtectionReason: Hashable { case locked, sleeping, inactive, secureInput, shuttingDown }

enum CapturePreferences {
    static func overlaysOnLeft(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "capture.overlay.left") as? Bool ?? true
    }
}

@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()
    private var launcher: CapturePanel?
    private var selectors: [CapturePanel] = []
    private(set) var overlays: [UUID: CaptureResultPanel] = [:]
    /// Stacking order; the dictionary alone cannot say which card is newest.
    private(set) var overlayOrder: [UUID] = []
    private var overlaysSuspended = false
    private var overlayScreen: NSScreen?
    private var pins: [UUID: CapturePanel] = [:]
    private var editors: [UUID: CaptureEditor] = [:]
    private var otherPanels: [CapturePanel] = []
    private var lastClosed: UUID?
    private var generation = UUID()
    private(set) var preparingCapture = false
    private(set) var countdown: CapturePanel?
    private var preparationTask: Task<Void, Never>?
    private var previousTarget: CaptureTarget?
    private var sourceName = ""
    private var sourceApplication: NSRunningApplication?
    private var temporarilyHidden: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []
    private var protectionTimer: Timer?
    private var cleanupTimer: Timer?
    private var protectionReasons: Set<CaptureProtectionReason> = []
    private var sessionProtected: Bool { !protectionReasons.isEmpty }
    private var scrollSession: CaptureScrollSession?
    private var recorder: CaptureRecorderController?
    private let queue = DispatchQueue(label: "RIMES.Capture.work", qos: .userInitiated)
    private let isolatedStore: CaptureStore?
    private var store: CaptureStore { get throws { try isolatedStore ?? CaptureStore.shared.get() } }

    init(isolatedStore: CaptureStore? = nil) {
        self.isolatedStore = isolatedStore
        // Smoke coordinators use disposable assets, no live capture observers,
        // global shortcut registration, cleanup timers or user storage.
        if isolatedStore != nil { return }
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
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.preparingCapture || !self.selectors.isEmpty { self.cancelSelection(self.generation) }
                self?.layoutOverlays()
            }
        })
        let transitions: [(Notification.Name, CaptureProtectionReason, Bool)] = [
            (NSWorkspace.sessionDidResignActiveNotification, .inactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .inactive, false),
            (NSWorkspace.willSleepNotification, .sleeping, true),
            (NSWorkspace.didWakeNotification, .sleeping, false),
            (NSWorkspace.willPowerOffNotification, .shuttingDown, true)
        ]
        for (name, reason, active) in transitions {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setProtection(reason, active: active) }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setProtection(.locked, active: true) } })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setProtection(.locked, active: false) } })
        protectionTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setProtection(.secureInput, active: IsSecureEventInputEnabled())
            }
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { _ = try? CaptureStore.shared.get().prune() }
        }
        queue.async { _ = try? CaptureStore.shared.get().recoverInterruptedRecordings(); _ = try? CaptureStore.shared.get().prune() }
    }

    func refreshVisibleAssets(completion: (() -> Void)? = nil) {
        guard !sessionProtected else { completion?(); return }
        let snapshot = overlays.mapValues { $0.record }
        let ids = Set(overlays.keys).union(pins.keys)
        guard !ids.isEmpty, let store = try? store else { completion?(); return }
        queue.async {
            let records = (try? store.records()) ?? []
            DispatchQueue.main.async {
                defer { completion?() }
                guard !self.sessionProtected else { return }
                for record in records where ids.contains(record.id) {
                    if let overlay = self.overlays[record.id], overlay.record == snapshot[record.id] {
                        self.updateOverlay(overlay, record: record)
                    }
                    if let pin = self.pins[record.id], pin.isVisible {
                        let frame = pin.frame, alpha = pin.alphaValue, locked = pin.ignoresMouseEvents
                        pin.close(); self.pin(record)
                        self.pins[record.id]?.setFrame(frame, display: true); self.pins[record.id]?.alphaValue = alpha; self.pins[record.id]?.ignoresMouseEvents = locked
                    }
                }
            }
        }
    }

    /// Protection sources are independent: wake must not expose windows while
    /// the screen is still locked, nor unlock while secure input remains active.
    func setProtection(_ reason: CaptureProtectionReason, active: Bool) {
        if !active {
            guard protectionReasons.remove(reason) != nil else { return }
            if !sessionProtected { restoreHiddenPanels() }
            return
        }
        guard protectionReasons.insert(reason).inserted else { return }
        rememberVisiblePanels()
        invalidateSelection()
        // The capture was cancelled, not paused. Remove its suspension even
        // though protection still prevents layout from showing anything.
        setResultOverlaysSuspended(false)
        CapturePermissionGuide.shared.dismiss()
        launcher?.close()
        overlays.values.forEach { $0.orderOut(nil) }; pins.values.forEach { $0.orderOut(nil) }
        editors.values.forEach { $0.panel.orderOut(nil) }
        otherPanels.forEach { $0.orderOut(nil) }
        scrollSession?.cancel()
        if reason == .secureInput { recorder?.pauseForProtection() } else { recorder?.stop() }
        IMELog.write("capture protection entered")
    }

    private var managedPanels: [NSWindow] {
        Array(pins.values) + editors.values.map(\.panel) + otherPanels
    }
    private func rememberVisiblePanels() {
        for panel in managedPanels where panel.isVisible && !temporarilyHidden.contains(where: { $0 === panel }) {
            temporarilyHidden.append(panel)
        }
    }

    private func restoreHiddenPanels() {
        if IsSecureEventInputEnabled() { setProtection(.secureInput, active: true); return }
        guard !sessionProtected else { return }
        let managed = managedPanels
        for panel in temporarilyHidden where managed.contains(where: { $0 === panel }) {
            panel.orderFrontRegardless()
        }
        temporarilyHidden.removeAll()
        setResultOverlaysSuspended(false)
    }

    func setResultOverlaysSuspended(_ suspended: Bool) {
        overlaysSuspended = suspended
        if suspended { overlays.values.forEach { $0.orderOut(nil) } }
        else { layoutOverlays() }
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
        if countdown != nil { cancelSelection(generation); return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { sourceApplication = NSWorkspace.shared.frontmostApplication }
        sourceName = sourceApplication?.localizedName ?? ""
        ClipboardHistoryWindowController.shared.hide()
        if let launcher, launcher.isVisible { launcher.makeKeyAndOrderFront(nil); return }
        let panel = CapturePanel(size: NSSize(width: 766, height: 68), surface: .transparent)
        panel.captureChrome = true
        panel.styleMask = [.borderless]
        panel.isOpaque = false; panel.backgroundColor = .clear
        let strip = CaptureLauncherView(frame: .zero)
        strip.capture = { [weak self, weak panel] mode, delay, ratio, size in
            panel?.close(); self?.begin(mode, delay: delay, ratio: ratio, size: size)
        }
        strip.recording = { [weak self, weak panel] in panel?.close(); self?.showRecorder() }
        strip.utilities = [
            ("恢复最近关闭的卡片", { [weak self] in self?.restoreOverlay() }),
            ("打开已有工程…", { [weak self] in self?.openProject() }),
            ("捕获与贴图设置…", { [weak self] in self?.showOptions() })
        ]
        CaptureUI.fill(strip, in: panel.contentView!, inset: 0)
        panel.setContentSize(strip.fittingSize)
        launcher = panel
        panel.closed = { [weak self, weak panel] in self?.launcher = nil; panel?.contentView = nil }
        panel.present()
    }

    func begin(_ mode: String, delay: Int = 0, ratio: CGFloat? = nil, size: CGSize? = nil, freeze: Bool = true,
               requestedAt: TimeInterval? = nil) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        if countdown != nil { cancelSelection(generation); return }
        guard !CapturePermissionGuide.shared.presentExisting(), !preparingCapture else { return }
        // The explicit capture uses ScreenCaptureKit's real permission gate.
        // Do not reject it solely on CoreGraphics preflight, or stack a system
        // prompt, Settings launch and generic error in the same gesture.
        preparingCapture = true
        generation = UUID(); let token = generation
        preparationTask?.cancel()
        closeSelectors()
        let started = requestedAt ?? ProcessInfo.processInfo.systemUptime
        IMELog.write("capture prepare start mode=\(mode)")
        launcher?.close()
        if isolatedStore == nil { ClipboardHistoryWindowController.shared.hide() }
        // Result overlays used to be closed here, which is why only ever one
        // was on screen: each capture destroyed the stack it was about to
        // add to. They are hidden for the duration like every other panel
        // and restored with them, so the results accumulate.
        rememberVisiblePanels()
        setResultOverlaysSuspended(true)
        temporarilyHidden.forEach { $0.orderOut(nil) }
        let countdownLabel = delay > 0 ? presentCountdown(seconds: delay, request: token) : nil
        preparationTask = Task {
            defer { if generation == token { preparingCapture = false; preparationTask = nil } }
            do {
                if delay > 0 {
                    for remaining in stride(from: delay, through: 1, by: -1) {
                        guard selectionIsCurrent(token) else { return }
                        countdownLabel?.stringValue = "\(remaining) 秒后截图 · Esc 取消"
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    closeCountdown()
                }
                guard selectionIsCurrent(token) else { return }
                // Preflight only decides whether to cover the desktop before
                // the real gate. Never obscure a first-use system prompt, and
                // never reject capture just because preflight reports false.
                let usesSelection = !["previous", "screen", "recordScreen"].contains(mode)
                var surfaces = usesSelection && CGPreflightScreenCaptureAccess()
                    ? try presentSelectors(mode: mode, ratio: ratio, size: size, request: token) : []
                if !surfaces.isEmpty { logPreparation("mask-visible", started: started) }
                let content = try await CaptureEngine.content()
                guard selectionIsCurrent(token) else { return }
                logPreparation("content-ready", started: started)
                if usesSelection && surfaces.isEmpty {
                    surfaces = try presentSelectors(mode: mode, ratio: ratio, size: size, request: token)
                    logPreparation("mask-visible", started: started)
                }
                if usesSelection {
                    surfaces = try supportedSurfaces(surfaces, displayIDs: Set(content.displays.map(\.displayID)))
                }
                if mode == "previous", let previousTarget {
                    guard content.displays.contains(where: { $0.displayID == previousTarget.display.displayID }) else { throw CaptureError.message("上次使用的显示器已断开") }
                    try await finish(target: previousTarget, content: content, mode: "area", snapshot: nil)
                    return
                }
                if mode == "window" || mode == "recordWindow" {
                    try chooseWindow(content, surfaces: surfaces, mode: mode == "recordWindow" ? "record" : "window", request: token)
                    logPreparation("windows-ready", started: started)
                    return
                }
                if mode == "screen" || mode == "recordScreen" {
                    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                    let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                    guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw CaptureError.message("没有可捕获的显示器") }
                    try await finish(target: CaptureTarget(display: display, window: nil, rect: nil), content: content, mode: mode == "recordScreen" ? "record" : mode, snapshot: nil)
                    return
                }
                let selectionSurfaces = usesSelection ? surfaces : try presentSelectors(mode: mode, ratio: ratio, size: size, request: token)
                try await select(content, surfaces: selectionSurfaces, mode: mode, freeze: freeze, request: token, started: started)
            } catch {
                guard generation == token, !sessionProtected else { return }
                if IsSecureEventInputEnabled() { setProtection(.secureInput, active: true); return }
                invalidateSelection()
                self.restoreHiddenPanels()
                if CapturePermissionCheck.isPermissionFailure(error) {
                    IMELog.write("capture authorization: ScreenCaptureKit declined current process")
                    CapturePermissionGuide.shared.show(.screenRecording) { [weak self] in
                        self?.begin(mode, delay: delay, ratio: ratio, size: size, freeze: freeze)
                    }
                } else { CaptureUI.error(error) }
            }
        }
    }

    struct SelectionSurface {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let view: CaptureSelectionView
    }
    private func presentCountdown(seconds: Int, request: UUID) -> NSTextField {
        let panel = CapturePanel(size: NSSize(width: 280, height: 100))
        panel.captureChrome = true
        let label = CaptureUI.label("\(seconds) 秒后截图 · Esc 取消", size: 16)
        CaptureUI.fill(CaptureUI.column([label, CaptureButton("取消") { [weak self] in self?.cancelSelection(request) }]), in: panel.contentView!)
        panel.closed = { [weak self, weak panel] in
            guard let self, self.countdown === panel else { return }
            self.countdown = nil; self.cancelSelection(request)
        }
        countdown = panel; panel.present()
        return label
    }
    private func closeCountdown() {
        let panel = countdown; countdown = nil
        panel?.closed = nil; panel?.close()
    }
    func supportedSurfaces(_ surfaces: [SelectionSurface], displayIDs: Set<CGDirectDisplayID>) throws -> [SelectionSurface] {
        let supported = surfaces.filter { surface in
            guard displayIDs.contains(surface.displayID) else {
                surface.view.invalidate()
                if let panel = surface.view.window as? CapturePanel {
                    selectors.removeAll { $0 === panel }; panel.close()
                }
                return false
            }
            return true
        }
        guard !supported.isEmpty else { throw CaptureError.message("没有可捕获的显示器") }
        if !selectors.contains(where: \.isKeyWindow), let panel = selectors.first {
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView)
        }
        return supported
    }
    private func logPreparation(_ phase: String, started: TimeInterval) {
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        IMELog.write("capture prepare \(phase) elapsed_ms=\(milliseconds)")
    }
    private func selectionIsCurrent(_ request: UUID) -> Bool {
        guard generation == request, !Task.isCancelled else { return false }
        if IsSecureEventInputEnabled() { setProtection(.secureInput, active: true); return false }
        return !sessionProtected
    }
    private func closeSelectors() {
        selectors.forEach {
            ($0.contentView as? CaptureSelectionView)?.invalidate()
            $0.close()
        }
        selectors.removeAll()
    }
    private func invalidateSelection() {
        generation = UUID(); preparingCapture = false
        preparationTask?.cancel(); preparationTask = nil
        closeSelectors()
        closeCountdown()
    }
    private func cancelSelection(_ request: UUID) {
        guard generation == request else { return }
        invalidateSelection()
        restoreHiddenPanels()
        if !sessionProtected, !IsSecureEventInputEnabled() {
            sourceApplication?.activate(options: [.activateIgnoringOtherApps])
        }
    }
    private func presentSelectors(mode: String, ratio: CGFloat?, size: CGSize?, request: UUID) throws -> [SelectionSurface] {
        var surfaces: [SelectionSurface] = []
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            let panel = CapturePanel(size: screen.frame.size, surface: .transparent)
            panel.styleMask = [.borderless]; panel.level = .screenSaver; panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true; panel.escapeCloses = false
            panel.setFrame(screen.frame, display: false)
            let view = CaptureSelectionView(mode: mode == "window" || mode == "recordWindow" ? .window : .area)
            view.fixedSize = size; view.ratio = ratio
            view.cancelled = { [weak self] in self?.cancelSelection(request) }
            panel.contentView = view; selectors.append(panel)
            panel.present(center: false); panel.makeFirstResponder(view); panel.displayIfNeeded()
            surfaces.append(SelectionSurface(screen: screen, displayID: id, view: view))
        }
        guard !surfaces.isEmpty else { throw CaptureError.message("没有可捕获的显示器") }
        // Leave keyboard cancellation on the display under the pointer.
        if let panel = selectors.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(panel.contentView)
        }
        return surfaces
    }

    private func chooseWindow(_ content: SCShareableContent, surfaces: [SelectionSurface], mode: String, request: UUID) throws {
        let eligible = content.windows.filter {
            $0.isOnScreen && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                && $0.frame.width > 50 && $0.frame.height > 40 && $0.windowLayer == 0
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.windowID, $0) })
        // Fetch z-order once, not on every mouse move. Only windows admitted
        // by ScreenCaptureKit may become actual capture targets.
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = infos.compactMap { info -> (window: SCWindow, frame: CGRect)? in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let window = byID[id], let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (window, frame)
        }
        guard !windows.isEmpty else { throw CaptureError.message("当前没有可截取的窗口，请使用区域截图") }
        for surface in surfaces {
            guard let display = content.displays.first(where: { $0.displayID == surface.displayID }) else { continue }
            surface.view.windowSelected = { [weak self] id in
                guard let self, self.selectionIsCurrent(request), let window = byID[id] else { return }
                self.invalidateSelection()
                let target = CaptureTarget(display: display, window: window, rect: nil)
                Task { do { try await self.finish(target: target, content: content, mode: mode, snapshot: nil) } catch { CaptureUI.error(error) } }
            }
            surface.view.acceptWindows(windows.map {
                CaptureWindowChoice(id: $0.window.windowID,
                    frame: CaptureWindowChoice.localFrame(window: $0.frame, display: CGDisplayBounds(display.displayID)),
                    title: [$0.window.owningApplication?.applicationName, $0.window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            })
        }
    }

    private func select(_ content: SCShareableContent, surfaces: [SelectionSurface], mode: String, freeze: Bool,
                        request: UUID, started: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, surface) in surfaces.enumerated() {
                guard let display = content.displays.first(where: { $0.displayID == surface.displayID }) else { continue }
                let scale = surface.screen.backingScaleFactor
                let screenWidth = surface.screen.frame.width
                let target = CaptureTarget(display: display, window: nil, rect: nil)
                group.addTask { (index, try await CaptureEngine.image(target, content: content, scale: scale)) }
                surface.view.selected = { [weak self] rect, image in
                    guard let self, self.selectionIsCurrent(request) else { return }
                    self.invalidateSelection()
                    let target = CaptureTarget(display: display, window: nil, rect: rect)
                    let factor = CGFloat(image.width) / screenWidth
                    let crop = freeze ? image.cropping(to: CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)) : nil
                    Task { do { try await self.finish(target: target, content: content, mode: mode, snapshot: mode == "scroll" || mode == "record" ? nil : crop) } catch { CaptureUI.error(error) } }
                }
            }
            for try await (index, image) in group {
                guard selectionIsCurrent(request) else { group.cancelAll(); return }
                logPreparation("display-ready", started: started)
                surfaces[index].view.acceptSnapshot(image)
                if !selectionIsCurrent(request) { group.cancelAll(); return }
            }
        }
    }

    private func finish(target: CaptureTarget, content: SCShareableContent, mode: String, snapshot: CGImage?) async throws {
        if IsSecureEventInputEnabled() { setProtection(.secureInput, active: true); return }
        guard !sessionProtected else { return }
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
            if let old = overlays[record.id] {
                updateOverlay(old, record: record)
                layoutOverlays()
                return
            }
            let scale = max(0.8, min(1.5, UserDefaults.standard.object(forKey: "capture.overlay.scale") as? Double ?? 1))
            // Smaller than before so a stack of them fits down one edge:
            // the thumbnail is the whole card, and the controls arrive on
            // hover instead of taking a permanent row each.
            let width = 208 * scale
            let height = 148 * scale
            let panel = CaptureResultPanel(record: record, size: NSSize(width: width, height: height))
            panel.captureChrome = true
            let body = CaptureHoverView()
            let preview = panel.preview
            // Keep the whole capture visible. Top-left aspect-fill could turn
            // a mostly white screenshot into an apparently blank card.
            preview.imageScaling = .scaleProportionallyUpOrDown
            preview.imageAlignment = .alignCenter
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
            let status = panel.previewStatus
            status.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(status)
            NSLayoutConstraint.activate([
                status.centerXAnchor.constraint(equalTo: body.centerXAnchor),
                status.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            ])

            let controls = CaptureCardControls(frame: .zero)
            controls.copyButton.onClick = { [weak self, weak panel] in
                if let panel { self?.copy(panel.record, dismissing: panel) }
            }
            controls.saveButton.onClick = { [weak self, weak panel] in if let panel { self?.export(panel.record) } }
            controls.closeButton.onClick = { [weak panel] in panel?.close() }
            controls.pinButton.isHidden = record.kind.capsuleKind == .video
            controls.pinButton.onClick = { [weak self, weak panel] in if let panel { self?.pin(panel.record) } }
            controls.editButton.onClick = { [weak self, weak panel] in if let panel { self?.edit(panel.record) } }
            if record.kind.capsuleKind == .video {
                controls.editButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "播放")
                controls.editButton.toolTip = "播放"; controls.editButton.setAccessibilityLabel("播放")
            }
            controls.alphaValue = 0
            CaptureUI.fill(controls, in: body, inset: 0)
            body.onHover = { [weak controls] inside in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    controls?.animator().alphaValue = inside ? 1 : 0
                }
            }
            CaptureUI.fill(body, in: panel.contentView!, inset: 0)

            guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理，请刷新捕获历史") }
            panel.closed = { [weak self] in
                store.release(record.id)
                self?.lastClosed = record.id
                self?.overlays.removeValue(forKey: record.id)
                self?.overlayOrder.removeAll { $0 == record.id }
                self?.layoutOverlays()
            }
            overlays[record.id] = panel
            overlayOrder.append(record.id)
            if overlayScreen == nil {
                overlayScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            }
            loadOverlayPreview(panel, store: store)
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

    private func updateOverlay(_ panel: CaptureResultPanel, record: CaptureRecord) {
        let old = panel.record
        guard old != record else { return }
        panel.record = record
        guard let store = try? store else { return }
        panel.preview.file = store.url(record)
        // Metadata-only changes (collection, OCR, title) do not blank a ready
        // preview or cancel its pending decode.
        if old.output != record.output || old.thumbnail != record.thumbnail || old.kind != record.kind {
            loadOverlayPreview(panel, store: store)
        }
    }

    private func loadOverlayPreview(_ panel: CaptureResultPanel, store: CaptureStore) {
        let record = panel.record
        let generation = panel.beginPreview()
        panel.previewLoad = CapsuleMediaPreviewLoader.shared.load(
            kind: record.thumbnail == nil ? record.kind.capsuleKind : .image,
            path: store.previewURL(record).path,
            maximumPixelSize: 512
        ) { [weak panel] result in
            guard let panel, !panel.dismissed, panel.previewGeneration == generation else { return }
            if case let .image(image) = result {
                IMELog.write("capture overlay preview loaded "
                    + "\(image.width)x\(image.height)")
                panel.acceptPreview(NSImage(cgImage: image, size: .zero), generation: generation)
                return
            }
            // Retry the current rendered output with the same bounded decoder,
            // not an unbounded main-thread NSImage load or the original asset.
            panel.previewLoad = CapsuleMediaPreviewLoader.shared.load(
                kind: record.kind.capsuleKind, path: store.url(record).path, maximumPixelSize: 512
            ) { [weak panel] fallback in
                let image: NSImage?
                if case let .image(value) = fallback { image = NSImage(cgImage: value, size: .zero) }
                else { image = nil }
                panel?.acceptPreview(image, generation: generation)
            }
        }
    }

    /// Results stack up one edge, newest nearest the corner, and reflow when
    /// one is dismissed. A fixed three-step cascade overlapped them and lost
    /// everything past the third.
    private func layoutOverlays() {
        guard !sessionProtected, !overlaysSuspended, !IsSecureEventInputEnabled() else { return }
        if overlays.isEmpty { overlayScreen = nil; return }
        if overlayScreen == nil || !NSScreen.screens.contains(where: { $0 == overlayScreen }) {
            overlayScreen = NSScreen.main
        }
        guard let visible = overlayScreen?.visibleFrame else { return }
        let onLeft = CapturePreferences.overlaysOnLeft()
        let panels = overlayOrder.reversed().compactMap { overlays[$0] }
        let frames = CaptureOverlayLayout.frames(sizes: panels.map { $0.frame.size }, visible: visible, onLeft: onLeft)
        for (index, panel) in panels.enumerated() {
            guard index < frames.count else { panel.orderOut(nil); continue }
            panel.setFrameOrigin(frames[index].origin)
            panel.present(center: false)
        }
        IMELog.write("capture overlay layout total=\(panels.count) visible=\(frames.count)")
    }

    func showActions(_ record: CaptureRecord) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
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
    /// Only a stack-card copy supplies its panel. Other copy entry points keep
    /// their existing UI. A supplied completion owns error presentation.
    func copy(_ record: CaptureRecord, dismissing overlay: CaptureResultPanel? = nil,
              to pasteboard: NSPasteboard = .general,
              completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !sessionProtected, !IsSecureEventInputEnabled() else {
            completion?(.failure(CaptureError.message("当前处于保护状态，未复制")))
            return
        }
        let expectedChangeCount = pasteboard.changeCount
        let pasteboardName = pasteboard.name
        let storeResult = Result { try store }
        queue.async { [weak overlay] in
            let result = Result {
                let store = try storeResult.get(); guard store.acquire(record.id) else { throw CaptureError.message("资产正在清理") }; defer { store.release(record.id) }
                let current = try store.record(record.id)
                return try CapsuleFilePasteboardWriter.prepare(kind: current.kind.capsuleKind, path: store.url(current).path)
            }
            DispatchQueue.main.async { [weak overlay] in
                guard !self.sessionProtected, !IsSecureEventInputEnabled() else {
                    completion?(.failure(CaptureError.message("当前处于保护状态，未复制")))
                    return
                }
                let outcome = Result<Void, Error> {
                    try CapsuleFilePasteboardWriter.write(result.get(), to: NSPasteboard(name: pasteboardName), expectedChangeCount: expectedChangeCount)
                    // Close this exact card only after the write succeeds;
                    // never dismiss a replacement restored during the copy.
                    if overlay?.record.id == record.id { overlay?.close() }
                }
                if let completion { completion(outcome) }
                else if case .failure(let error) = outcome { CaptureUI.error(error) }
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
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
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
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
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
        guard !sessionProtected, !IsSecureEventInputEnabled() else { return }
        if recorder?.isRecording == true { recorder?.showControls(); return }
        recorder = CaptureRecorderController { [weak self] in self?.begin("record", freeze: false) } completed: { [weak self] record in self?.showOverlay(record) }
        recorder?.showSettings()
    }
    func showOptions() {
        let panel = CapturePanel(size: NSSize(width: 480, height: 270))
        let left = NSButton(checkboxWithTitle: "浮层放在屏幕左下角", target: nil, action: nil); left.state = CapturePreferences.overlaysOnLeft() ? .on : .off
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
