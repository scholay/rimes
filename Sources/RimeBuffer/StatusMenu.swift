import Cocoa
import CRimeBridge

/// A value-only snapshot keeps menu construction independent of live stores.
struct InputSourceMenuState {
    let healthy: Bool
    let bufferTitle: String
    let clipboardTitle: String
    let mailboxTitle: String
    let capsuleTitle: String
}

/// Builds ETInput's commands for the system input-source menu. The menu items
/// target the live IMKInputController because InputMethodKit dispatches text
/// input menu commands through that controller.
final class StatusMenu {
    static let shared = StatusMenu()

    private(set) var schemaId = ""
    private(set) var schemaName = ""
    private(set) var healthy = true

    private var installLogURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer-install.log")
    }

    func update(schemaId: String, schemaName: String) {
        self.schemaId = schemaId
        self.schemaName = schemaName
    }

    func setHealthy(_ ok: Bool) {
        healthy = ok
    }

    /// InputMethodKit asks the active controller for a fresh menu whenever the
    /// system input menu opens, so every item reflects current engine state.
    func makeInputSourceMenu(target: RIMESController) -> NSMenu {
        let clipboardShortcut = RimeShortcutPreferences
            .shortcut(for: .toggleClipboardHistory)
            .displayTitle
        return Self.makeInputSourceMenu(target: target, state: InputSourceMenuState(
            healthy: healthy,
            bufferTitle: bufferTitle,
            clipboardTitle: "Clipboard History…（\(clipboardShortcut)）",
            mailboxTitle: mailboxTitle,
            capsuleTitle: capsuleTitle
        ))
    }

    static func makeInputSourceMenu(target: NSObject, state: InputSourceMenuState) -> NSMenu {
        let menu = NSMenu()

        if !state.healthy {
            let health = NSMenuItem(
                title: "⚠️ 输入引擎异常 — 已退化为英文直通",
                action: nil,
                keyEquivalent: "")
            health.isEnabled = false
            menu.addItem(health)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(RIMESController.openSettingsFromInputMenu(_:)),
            keyEquivalent: "")
        settings.target = target
        menu.addItem(settings)

        let buffer = NSMenuItem(
            title: state.bufferTitle,
            action: #selector(RIMESController.toggleBufferWindowFromInputMenu(_:)),
            keyEquivalent: "")
        buffer.target = target
        menu.addItem(buffer)

        let clipboard = NSMenuItem(
            title: state.clipboardTitle,
            action: #selector(RIMESController.toggleClipboardHistoryFromInputMenu(_:)),
            keyEquivalent: "")
        clipboard.target = target
        menu.addItem(clipboard)

        let mailbox = NSMenuItem(
            title: state.mailboxTitle,
            action: #selector(RIMESController.openMailboxFromInputMenu(_:)),
            keyEquivalent: "")
        mailbox.target = target
        menu.addItem(mailbox)

        let capsule = NSMenuItem(
            title: state.capsuleTitle,
            action: #selector(RIMESController.openCapsuleFromInputMenu(_:)),
            keyEquivalent: "")
        capsule.target = target
        menu.addItem(capsule)

        let codexSession = NSMenuItem(
            title: "Codex 会话…",
            action: #selector(RIMESController.openCodexSessionFromInputMenu(_:)),
            keyEquivalent: "")
        codexSession.target = target
        menu.addItem(codexSession)

        // Keep one top-level IMK action. Nested items previously appeared in
        // TextInputMenuAgent but did not dispatch; the controller opens the
        // five-command AppKit menu inside this process instead.
        menu.addItem(.separator())
        let maintenance = NSMenuItem(
            title: "维护…",
            action: #selector(RIMESController.openMaintenanceFromInputMenu(_:)),
            keyEquivalent: "")
        maintenance.target = target
        menu.addItem(maintenance)

        return menu
    }

    static func makeMaintenanceMenu(target: NSObject, pendingVersion: String?) -> NSMenu {
        let menu = NSMenu(title: "维护")
        let updateTitle = pendingVersion.map { "安装 RIMES v\($0)…" } ?? "检查更新…"
        let checkUpdate = NSMenuItem(
            title: updateTitle,
            action: #selector(RIMESController.checkUpdateFromInputMenu(_:)),
            keyEquivalent: "")
        checkUpdate.target = target
        menu.addItem(checkUpdate)

        let log = NSMenuItem(
            title: "打开日志 (~/rimebuffer.log)",
            action: #selector(RIMESController.openLogFromInputMenu(_:)),
            keyEquivalent: "")
        log.target = target
        menu.addItem(log)

        let deploy = NSMenuItem(
            title: "重新部署并重启",
            action: #selector(RIMESController.deployAndRestartFromInputMenu(_:)),
            keyEquivalent: "")
        deploy.target = target
        menu.addItem(deploy)

        let reinstall = NSMenuItem(
            title: "重新安装输入法…",
            action: #selector(RIMESController.reinstallFromInputMenu(_:)),
            keyEquivalent: "")
        reinstall.target = target
        menu.addItem(reinstall)

        let restart = NSMenuItem(
            title: "重启输入法进程",
            action: #selector(RIMESController.restartFromInputMenu(_:)),
            keyEquivalent: "")
        restart.target = target
        menu.addItem(restart)

        return menu
    }

    func showMaintenanceMenu(target: RIMESController) {
        let location = NSEvent.mouseLocation
        // Leave the system menu's command callback before tracking a menu in
        // our process. The ellipsis intentionally means click-to-open, not a
        // nonfunctional hover submenu forwarded through InputMethodKit.
        DispatchQueue.main.async {
            guard RimeInputSourceAuthority.currentSourceIsOwn() else { return }
            let updateManager = UpdateManager.shared
            let menu = Self.makeMaintenanceMenu(
                target: target,
                pendingVersion: updateManager.isUpdateReady ? updateManager.pendingVersion : nil
            )
            IMELog.write("input menu: maintenance opened")
            withExtendedLifetime(target) {
                _ = menu.popUp(positioning: nil, at: location, in: nil)
            }
        }
    }

    private var bufferTitle: String {
        let shortcut = RimeShortcutPreferences
            .shortcut(for: .toggleWorkbench)
            .displayTitle
        return "Buffer…（\(shortcut)）"
    }

    private var mailboxTitle: String {
        let unreadCount = MailboxStore.shared.snapshot.unreadCount
        let shortcut = RimeShortcutPreferences
            .shortcut(for: .openMailbox)
            .displayTitle
        return unreadCount > 0
            ? "Mailbox…（\(unreadCount) 条未读 · \(shortcut)）"
            : "Mailbox…（\(shortcut)）"
    }

    private var capsuleTitle: String {
        let shortcut = RimeShortcutPreferences
            .shortcut(for: .openCapsule)
            .displayTitle
        return "Capsule…（\(shortcut)）"
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    func toggleBufferWindow() {
        BufferWindowController.shared.toggleVisibility()
    }

    func toggleClipboardHistory() {
        ClipboardHistoryWindowController.shared.toggleVisibility()
    }

    func openMailbox() {
        let threadID = MailboxStore.shared.selectLatestUnreadOrMostRecent()
        MailboxWindowController.shared.show(selecting: threadID)
    }

    func openCapsule() {
        CapsuleWindowController.shared.show()
    }

    /// Opens the split session pane on the frontmost Finder-visible working
    /// directory, falling back to the home directory. Codex is launched in
    /// that workspace and writes its rollout there for the right pane to read.
    func openCodexSession() {
        // Codex is workspace-bound: its sandbox, its edits and the `cwd` the
        // right pane matches on all come from the launch directory, so the
        // directory is asked for rather than assumed.
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = CodexSessionWorkspaceRules.preferredWorkspace()
        picker.prompt = "在此启动 Codex"
        picker.message = "选择 Codex 会话的工作目录"
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let workspace = picker.url else { return }
        CodexSessionWorkspaceRules.remember(workspace)
        CodexSessionWindowController.shared.present(workspace: workspace)
    }

    func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    func openLog() {
        IMELog.write("input menu: log requested")
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    func deployAndRestart() {
        RIMESController.active?.forceCommit()
        IMELog.write("input menu: deploy requested")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = rimeEngine.start()
            let ok = BBRimeDeploy()
            if ok {
                rimeEngine.invalidateSchemaListCacheAfterDeployment()
            }
            IMELog.write("input menu: deploy=\(ok), restarting")
            DispatchQueue.main.async {
                InputMetricsPersistence.saveNow()
                exit(0)
            }
        }
    }

    func reinstallInputMethod() {
        guard let script = installScriptURL() else {
            showInfo("找不到 build_install.sh。")
            return
        }

        let alert = NSAlert()
        alert.messageText = "重新安装 \(ProductIdentity.displayName)？"
        alert.informativeText = "将从 \(script.deletingLastPathComponent().path) 运行 build_install.sh。构建完成后当前输入法进程会被重启。"
        alert.addButton(withTitle: "重新安装")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = RimeUI.appKitAppearance
        guard StandaloneWindowFocusCoordinator.shared
            .runModalAlertIfRIMESActive(alert) == .alertFirstButtonReturn else {
            return
        }

        RIMESController.active?.forceCommit()
        InputMetricsPersistence.saveNow()

        let command = [
            "cd \(shellQuote(script.deletingLastPathComponent().path))",
            "nohup env RB_KEEP_USERDB=1 /bin/bash ./build_install.sh > \(shellQuote(installLogURL.path)) 2>&1 &",
        ].joined(separator: " && ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()
            IMELog.write("input menu: launched install script \(script.path)")
        } catch {
            showInfo("安装启动失败：\(error.localizedDescription)")
        }
    }

    func restart() {
        IMELog.write("input menu: restart requested")
        RIMESController.active?.forceCommit()
        InputMetricsPersistence.saveNow()
        exit(0)
    }

    private func installScriptURL() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Documents/DEV/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer-1/build_install.sh"),
            home.appendingPathComponent("Documents/DEV/rime-buffer/build_install.sh"),
            home.appendingPathComponent("Documents/05-dev/apps/rime-buffer/build_install.sh"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.window.appearance = RimeUI.appKitAppearance
        _ = StandaloneWindowFocusCoordinator.shared
            .runModalAlertIfRIMESActive(alert)
    }
}
