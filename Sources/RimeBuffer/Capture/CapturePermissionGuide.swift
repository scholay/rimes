import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// Permission evidence is scoped to one explicit attempt, never persisted as
/// authorization. A preflight failure alone is not a ScreenCaptureKit error.
@MainActor
final class CapturePermissionCheck {
    enum State: Equatable {
        case idle, checking, ready, blocked
        case failed(String)
    }
    private(set) var state = State.idle
    private var generation = UUID()
    private struct NotEffective: Error {}

    static func isPermissionFailure(_ error: Error) -> Bool {
        if error is NotEffective { return true }
        var current = error as NSError
        for _ in 0..<4 {
            if current.domain == SCStreamErrorDomain && current.code == SCStreamError.Code.userDeclined.rawValue { return true }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return false
    }

    static func verify(_ permission: SystemPermission) async throws {
        if permission == .screenRecording {
            // Explicit, OS-authorized capability check only. No frame is
            // captured, stored or logged, and no prior success bypasses TCC.
            _ = try await CaptureEngine.content()
        } else if SystemPermissionAudit.status(for: permission) != .granted {
            throw NotEffective()
        }
    }

    func check(_ operation: () async throws -> Void) async {
        guard state != .checking else { return }
        generation = UUID(); let token = generation
        state = .checking
        do {
            try await operation()
            guard generation == token, !Task.isCancelled else { return }
            state = .ready
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            if Self.isPermissionFailure(error) { state = .blocked }
            else { state = .failed((error as NSError).localizedDescription) }
        }
    }

    func cancel() { generation = UUID(); state = .idle }
}

struct CapturePermissionPresentation {
    let permission: SystemPermission
    let intent: PermissionChangeIntent
    let state: CapturePermissionCheck.State
    let continuing: Bool

    var showsAddition: Bool { intent == .enable && permission.supportsManualApplicationAddition }
    var showsContinue: Bool { continuing && intent == .enable && state == .ready }
    var message: String {
        if state == .ready { return "已开启，可以继续。" }
        if case .failed = state { return "暂时无法确认，请重新尝试。" }
        if permission == .localNetwork { return "在系统设置中确认开关。" }
        if intent == .disable { return "在系统设置中关闭 \(ProductBrand.name) 的开关。" }
        return showsAddition ? "拖动虚线框内的图标，再打开系统开关。" : "在系统设置中打开 \(ProductBrand.name) 的开关。"
    }
}

@MainActor
struct PermissionGuideEnvironment {
    var status: (SystemPermission) -> SystemPermissionStatus
    var openSettings: (SystemPermission) -> Void
    var request: (SystemPermission) async -> Void
    var verify: (SystemPermission) async throws -> Void

    static var live: Self {
        Self(status: SystemPermissionAudit.status,
             openSettings: { permission in
                if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
             }, request: SystemPermissionAudit.requestOnly,
             verify: CapturePermissionCheck.verify)
    }
}

/// The initiating switch opens the system pane and requests authorization in
/// one action. Passive refresh never grants permission, resets TCC, restarts
/// the IME, or starts a capture. A pending capture still needs its own Continue.
@MainActor
final class CapturePermissionGuide {
    static let shared = CapturePermissionGuide()
    private var panel: CapturePanel?
    private var pending: Task<Void, Never>?
    private let check = CapturePermissionCheck()
    private var activationObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var protectedObservers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var statusLabel: NSTextField?
    private var continueButton: CaptureButton?
    private var header: NSView?
    private var body: NSView?
    private var scroll: CaptureInspectorScroll?
    private var help: PermissionHelpDisclosure?
    private var permission = SystemPermission.screenRecording
    private var intent = PermissionChangeIntent.enable
    private var continuation: (() -> Void)?
    private var requested = false
    private var generation = UUID()
    private var observedStatus: SystemPermissionStatus?
    private var hiddenForSecureInput = false
    private let allowsSystemActions: Bool
    private let environment: PermissionGuideEnvironment
    private let contentWidth: CGFloat = 456
    var isPresented: Bool { panel != nil }

    init(allowsSystemActions: Bool = true, environment: PermissionGuideEnvironment? = nil) {
        self.allowsSystemActions = allowsSystemActions
        self.environment = environment ?? .live
    }

    @discardableResult
    func presentExisting() -> Bool {
        guard let panel else { return false }
        panel.present(center: false)
        return true
    }

    func show(_ permission: SystemPermission, intent: PermissionChangeIntent = .enable,
              retry: (() -> Void)? = nil) {
        guard !IsSecureEventInputEnabled() else { return }
        if panel != nil {
            if self.permission == permission, self.intent == intent {
                if let retry { continuation = retry; refreshStatus() }
                _ = presentExisting()
                if allowsSystemActions { environment.openSettings(permission) }
                return
            }
            dismiss()
        }
        self.permission = permission; self.intent = intent
        continuation = retry; requested = false; generation = UUID(); observedStatus = nil
        hiddenForSecureInput = false
        check.cancel()
        let panel = CapturePanel(size: NSSize(width: 500, height: 430))
        panel.styleMask.remove(.resizable)
        panel.title = "\(permission.title)权限"
        self.panel = panel

        let applicationURL = PermissionApplication.appURL()
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13); status.textColor = RimeUI.textSecondary
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status
        let text = CaptureUI.column([title, status], spacing: 6)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let close = CaptureGlyphButton(symbol: "xmark", tooltip: "关闭权限引导") { [weak self] in self?.dismiss() }
        let header = CaptureUI.row([text, close], spacing: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: contentWidth - 34 - 12).isActive = true
        self.header = header

        var views: [NSView] = []
        if presentation.showsAddition {
            let target = PermissionApplicationIcon(applicationURL: applicationURL,
                allowsSystemActions: allowsSystemActions, showsDragTarget: true)
            target.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([target.widthAnchor.constraint(equalToConstant: 56), target.heightAnchor.constraint(equalToConstant: 56)])
            target.setAccessibilityIdentifier("permission-application-drag-target")
            let arrow = NSImageView(image: RimeUI.symbol("arrow.left", pointSize: 22, weight: .semibold) ?? NSImage())
            arrow.contentTintColor = RimeUI.accentTextColor
            let hint = NSTextField(labelWithString: "1  拖动这个")
            hint.font = .systemFont(ofSize: 14, weight: .semibold)
            hint.textColor = RimeUI.textPrimary
            views.append(CaptureUI.column([CaptureUI.row([target, arrow, hint], spacing: 12),
                PermissionGuideAnimation(.drag, width: contentWidth)], spacing: 10))
        }
        views.append(animationStep(intent == .disable ? "关闭系统开关" : presentation.showsAddition ? "2  打开系统开关" : "打开系统开关",
                                   kind: intent == .enable ? .enable : .disable))
        if presentation.showsAddition {
            let repair = animationStep("修复示意：移除旧条目，再添加当前应用", kind: .repair)
            let help = PermissionHelpDisclosure(details: repair, width: contentWidth)
            help.didToggle = { [weak self, weak help] in
                self?.resizePanel()
                if let help, help.expanded { help.scrollToVisible(help.bounds) }
            }
            self.help = help
            views.append(help)
        }
        let next = CaptureButton("继续") { [weak self] in self?.verify(continueFeature: true) }
        next.isProminent = true
        next.isHidden = true
        continueButton = next
        views.append(next)
        let body = CaptureUI.column(views, spacing: 16)
        body.detachesHiddenViews = true
        self.body = body
        let scroll = CaptureInspectorScroll(body)
        self.scroll = scroll
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        let content = panel.contentView!
        content.addSubview(header); content.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
        panel.closed = { [weak self, weak panel] in
            guard let self else { return }
            self.generation = UUID()
            self.pending?.cancel(); self.pending = nil; self.check.cancel()
            self.poll?.invalidate(); self.poll = nil
            self.continuation = nil; self.panel = nil
            self.header = nil; self.body = nil; self.scroll = nil; self.help = nil
            self.statusLabel = nil; self.continueButton = nil
            self.removeObservers(); panel?.contentView = nil
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.requested else { return }
                self.refreshStatus()
                self.verify()
            }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            protectedObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        refreshStatus(); resizePanel()
        if allowsSystemActions, let screen = NSScreen.main {
            // Keep the real app icon alongside the system pane for dragging.
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.minX + 18, y: max(frame.minY + 18, frame.midY - panel.frame.height / 2)))
            panel.present(center: false)
        } else { panel.present() }
        beginSystemFlow()
    }

    private func animationStep(_ title: String, kind: PermissionGuideAnimation.Kind) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = RimeUI.textSecondary
        return CaptureUI.column([label, PermissionGuideAnimation(kind, width: contentWidth)], spacing: 7)
    }

    private var currentStatus: SystemPermissionStatus {
        allowsSystemActions ? environment.status(permission) : .denied
    }

    private var presentation: CapturePermissionPresentation {
        CapturePermissionPresentation(permission: permission, intent: intent,
            state: check.state, continuing: continuation != nil)
    }

    private func beginSystemFlow() {
        guard allowsSystemActions, panel != nil, !IsSecureEventInputEnabled() else { return }
        // Always reveal the exact pane, even when a recorded denial makes the
        // OS request silent. Never make the user press a second Settings button.
        environment.openSettings(permission)
        requested = true
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissionStatus() }
        }
        poll = timer; RunLoop.main.add(timer, forMode: .common)
        guard intent == .enable else { return }
        let permission = permission, token = generation
        pending = Task { [weak self] in
            guard let self else { return }
            await self.environment.request(permission)
            guard !Task.isCancelled, self.generation == token, self.panel != nil else { return }
            self.pending = nil
            self.verify()
        }
    }

    func refreshPermissionStatus() {
        guard panel != nil else { return }
        // An administrator-authentication sheet can temporarily enable secure
        // input. Keep the explicit attempt alive, but hide its interactive UI.
        guard !IsSecureEventInputEnabled() else {
            hiddenForSecureInput = true; panel?.orderOut(nil); return
        }
        let resumed = hiddenForSecureInput
        if resumed {
            hiddenForSecureInput = false; panel?.orderFrontRegardless()
        }
        if check.state == .ready, continuation == nil { dismiss(); return }
        let latest = currentStatus
        if latest != observedStatus || resumed {
            observedStatus = latest
            NotificationCenter.default.post(name: .systemPermissionStatusDidChange, object: nil)
            refreshStatus()
            if intent == .disable, intent.isSatisfied(by: latest) { dismiss(); return }
            if latest == .granted { verify() }
        }
    }

    private func verify(continueFeature: Bool = false) {
        guard allowsSystemActions, panel != nil, pending == nil, intent == .enable,
              permission != .localNetwork, !IsSecureEventInputEnabled() else { return }
        let permission = permission, token = generation
        pending = Task { [weak self] in
            guard let self else { return }
            await self.check.check { try await self.environment.verify(permission) }
            guard !Task.isCancelled, self.generation == token, self.panel != nil else { return }
            self.pending = nil
            self.refreshStatus()
            NotificationCenter.default.post(name: .systemPermissionStatusDidChange, object: nil)
            if self.check.state == .ready, !IsSecureEventInputEnabled() {
                if continueFeature {
                    let action = self.continuation
                    self.dismiss()
                    if let action { DispatchQueue.main.async { action() } }
                } else if self.continuation == nil {
                    self.dismiss()
                }
            }
        }
    }

    private func refreshStatus() {
        guard panel != nil else { return }
        statusLabel?.stringValue = presentation.message
        continueButton?.isHidden = !presentation.showsContinue
        continueButton?.isEnabled = pending == nil
        resizePanel()
    }

    private func resizePanel() {
        guard let panel, let header, let body else { return }
        body.layoutSubtreeIfNeeded()
        let availableHeight = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 700
        let size = NSSize(width: 500, height: min(availableHeight - 60,
            max(220, header.fittingSize.height + 16 + body.fittingSize.height + 44)))
        // Keep the top edge still when the single optional recovery card opens.
        let top = panel.frame.maxY
        panel.setContentSize(size)
        let bottom = (panel.screen ?? NSScreen.main)?.visibleFrame.minY ?? 0
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: max(bottom + 12, top - panel.frame.height)))
        panel.contentView?.layoutSubtreeIfNeeded()
        scroll?.needsLayout = true; scroll?.layoutSubtreeIfNeeded()
    }

    func dismiss() { panel?.close() }

    private func removeObservers() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        lockObserver = nil
        protectedObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        protectedObservers.removeAll()
    }

    func renderForSmoke(to output: URL) throws {
        precondition(!allowsSystemActions)
        show(.screenRecording)
        defer { dismiss() }
        if ProcessInfo.processInfo.environment["RIMES_PERMISSION_HELP_PREVIEW"] == "1" { help?.setExpanded(true) }
        guard let view = panel?.contentView else { throw CaptureError.message("permission preview unavailable") }
        view.layoutSubtreeIfNeeded()
        func validate(_ node: NSView) throws {
            guard !node.isHiddenOrHasHiddenAncestor else { return }
            if node is NSControl, !(node is NSTextField),
               !node.visibleRect.contains(node.bounds.insetBy(dx: 0.5, dy: 0.5)) {
                // Expanded help may scroll; the header close control must not.
                if node is CaptureGlyphButton { throw CaptureError.message("permission close control is clipped") }
            }
            try node.subviews.forEach(validate)
        }
        try validate(view)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("permission preview allocation failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message("permission preview encoding failed") }
        try data.write(to: output)
    }
}
