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

/// One guide shared by capture and Settings. No automatic Settings launch,
/// permission reset, restart or delayed capture when the user merely returns.
@MainActor
final class CapturePermissionGuide {
    static let shared = CapturePermissionGuide()
    private var panel: CapturePanel?
    private var pending: Task<Void, Never>?
    private let check = CapturePermissionCheck()
    private var activationObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    private var protectedObservers: [NSObjectProtocol] = []
    private var status: NSTextField?
    private var requestButton: CaptureButton?
    private var verifyButton: CaptureButton?
    private var permission = SystemPermission.screenRecording
    private var continuation: (() -> Void)?
    private var requested = false
    private let allowsSystemActions: Bool

    init(allowsSystemActions: Bool = true) { self.allowsSystemActions = allowsSystemActions }

    @discardableResult
    func presentExisting() -> Bool {
        guard let panel else { return false }
        panel.present(center: false)
        return true
    }

    func show(_ permission: SystemPermission, retry: (() -> Void)? = nil) {
        guard !IsSecureEventInputEnabled(), !presentExisting() else { return }
        self.permission = permission; continuation = retry; requested = false
        let panel = CapturePanel(size: NSSize(width: 560, height: 520))
        panel.styleMask.remove(.resizable)
        self.panel = panel
        func label(_ text: String) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: 12); view.textColor = RimeUI.textSecondary
            view.preferredMaxLayoutWidth = 512
            return view
        }
        let status = label(""); self.status = status
        let request = CaptureButton("请求系统授权") { [weak self] in self?.request() }
        requestButton = request
        let verify = CaptureButton(retry == nil ? "检测权限" : "检测并继续") { [weak self] in self?.verify() }
        verifyButton = verify
        let steps = label("1. 打开系统设置，在「\(permission.title)」中允许 RIMES。\n"
            + "2. 返回此处，点击「\(verify.title)」。只返回窗口不会自动开始捕获。\n"
            + "3. 若系统要求重启，或开关已开启但检测仍失败，保存未完成内容后重启 RIMES。")
        let identity = SystemPermissionAudit.identity()
        let location = label("当前应用：\(identity.bundlePath)")
        let signature = label(identity.isAdHocSigned
            ? "当前是临时签名开发版，重建可能使旧授权不再匹配。重启后仍失败时，可在系统设置中移除旧条目，再用此处的当前应用重新添加。不会自动清除授权。"
            : "请授权当前运行的 RIMES.app。这里的定位和拖动不会移动、重装应用，也不会自动更改系统权限。")
        let actions = CaptureUI.row([
            request,
            CaptureButton("打开系统设置") { [weak self] in
                guard let self, self.allowsSystemActions, let url = self.permission.settingsURL else { return }
                NSWorkspace.shared.open(url)
            }, verify
        ])
        let footer = CaptureUI.row([
            CaptureButton("重启 RIMES…") { [weak self] in self?.restart() },
            CaptureButton("取消") { [weak self] in self?.dismiss() }
        ])
        var sections: [NSView] = [
            CaptureUI.label("\(permission.title) · 授权与检测", size: 17), status,
            label("用途：\(permission.enables)"), steps, actions
        ]
        if permission.supportsManualApplicationAddition {
            sections.append(PermissionApplicationCard(width: 500, allowsSystemActions: allowsSystemActions))
            sections.append(signature)
        } else {
            sections.append(label("这项权限不能拖入应用添加。请先点击「请求系统授权」，回答系统弹窗后再检测；已拒绝时在系统设置中打开 RIMES 的开关。"))
            sections.append(location)
        }
        let body = CaptureUI.column(sections, spacing: 12)
        // Keep help readable on small displays instead of compressing labels
        // into each other. Recovery/close stay visible below the scroll area.
        let scroll = CaptureInspectorScroll(body)
        let content = panel.contentView!
        content.addSubview(scroll); content.addSubview(footer)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
        panel.closed = { [weak self, weak panel] in
            self?.pending?.cancel(); self?.pending = nil; self?.check.cancel()
            self?.continuation = nil; self?.panel = nil
            self?.removeObservers(); panel?.contentView = nil
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatus() }
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            protectedObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        refreshStatus()
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 700) - 80
        panel.setContentSize(NSSize(width: 560, height: min(availableHeight, max(340, body.fittingSize.height + footer.fittingSize.height + 56))))
        panel.present()
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

    private func request() {
        guard allowsSystemActions, pending == nil, !requested else { return }
        requested = true
        let permission = permission
        pending = Task { [weak self] in
            await SystemPermissionAudit.requestOnly(permission)
            guard !Task.isCancelled, let self, self.panel != nil else { return }
            self.pending = nil; self.refreshStatus()
        }
        refreshStatus()
    }

    private func verify() {
        guard allowsSystemActions, pending == nil, !IsSecureEventInputEnabled() else { return }
        let permission = permission
        pending = Task { [weak self] in
            guard let self else { return }
            await self.check.check { try await CapturePermissionCheck.verify(permission) }
            guard !Task.isCancelled, self.panel != nil else { return }
            self.pending = nil; self.refreshStatus()
            if self.check.state == .ready, let action = self.continuation,
               !IsSecureEventInputEnabled() {
                self.dismiss()
                DispatchQueue.main.async { action() }
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard panel != nil else { return }
        let preflight = SystemPermissionAudit.status(for: permission) == .granted
        requestButton?.isEnabled = pending == nil && !requested && !preflight
        requestButton?.title = preflight ? "预检查已通过" : (requested ? "已请求授权" : "请求系统授权")
        verifyButton?.isEnabled = pending == nil
        if pending != nil { status?.stringValue = "正在等待系统授权或检测结果…"; return }
        switch check.state {
        case .ready: status?.stringValue = "本次检测通过。之后每次捕获仍由系统重新校验。"
        case .blocked: status?.stringValue = "授权尚未对当前进程生效，不代表系统设置里的开关一定关闭。"
        case .failed(let message): status?.stringValue = "检测失败（不能据此判断未授权）：\(message)"
        default:
            status?.stringValue = preflight
                ? "系统预检查通过，请点击检测确认当前进程可用。"
                : (requested ? "已请求系统授权。请完成系统设置后检测；若仍失败，请按下方步骤重启。"
                    : "当前进程尚未确认可用。首次使用可请求授权；已经开启请直接检测。")
        }
    }

    private func restart() {
        guard allowsSystemActions else { return }
        let alert = NSAlert()
        alert.messageText = "重启 RIMES 以重新载入系统授权？"
        alert.informativeText = "请先保存截图编辑、缓冲区等未保存内容，并停止录屏。词库和配置会保留。当前使用其他输入法时，请在退出后重新选择 RIMES。恢复后请重新触发截图，不会自动捕获。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重启 RIMES")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        dismiss(); StatusMenu.shared.restart()
    }

    func renderForSmoke(to output: URL) throws {
        precondition(!allowsSystemActions)
        show(.screenRecording)
        defer { dismiss() }
        guard let view = panel?.contentView else { throw CaptureError.message("permission preview unavailable") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CaptureError.message("permission preview allocation failed") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CaptureError.message("permission preview encoding failed") }
        try data.write(to: output)
    }
}
