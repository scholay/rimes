import Cocoa
import CRimeBridge

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
    func makeInputSourceMenu(target: RimeBufferController) -> NSMenu {
        let menu = NSMenu()

        if !healthy {
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
            action: #selector(RimeBufferController.openSettingsFromInputMenu(_:)),
            keyEquivalent: "")
        settings.target = target
        menu.addItem(settings)

        let inbox = NSMenuItem(
            title: inboundTrayTitle,
            action: #selector(RimeBufferController.openInboundTrayFromInputMenu(_:)),
            keyEquivalent: "")
        inbox.target = target
        menu.addItem(inbox)

        let maintenance = NSMenuItem(title: "维护…", action: nil, keyEquivalent: "")
        let maintenanceMenu = NSMenu(title: "维护")

        let workbench = NSMenuItem(
            title: BufferWindowController.shared.isVisible ? "关闭缓冲工作台（保留内容）" : "显示缓冲工作台",
            action: #selector(RimeBufferController.toggleBufferWindowFromInputMenu(_:)),
            keyEquivalent: "")
        workbench.target = target
        maintenanceMenu.addItem(workbench)

        let clipboardShortcut = RimeShortcutPreferences
            .shortcut(for: .toggleClipboardHistory)
            .displayTitle
        let clipboard = NSMenuItem(
            title: "剪贴板历史（\(clipboardShortcut)；仅工作台显示时读取）",
            action: #selector(RimeBufferController.toggleClipboardHistoryFromInputMenu(_:)),
            keyEquivalent: "")
        clipboard.target = target
        clipboard.state = BufferWindowController.shared.clipboardRailEnabled ? .on : .off
        maintenanceMenu.addItem(clipboard)

        let pin = NSMenuItem(
            title: "常显于所有桌面与全屏空间",
            action: #selector(RimeBufferController.toggleBufferPinnedFromInputMenu(_:)),
            keyEquivalent: "")
        pin.target = target
        pin.state = BufferWindowController.shared.pinned ? .on : .off
        maintenanceMenu.addItem(pin)

        let move = NSMenuItem(
            title: "把缓冲工作台移到当前屏幕",
            action: #selector(RimeBufferController.moveBufferWindowFromInputMenu(_:)),
            keyEquivalent: "")
        move.target = target
        maintenanceMenu.addItem(move)
        maintenanceMenu.addItem(.separator())

        let updateManager = UpdateManager.shared
        let updateTitle: String
        if updateManager.isUpdateReady,
           let pendingVersion = updateManager.pendingVersion {
            updateTitle = "安装 RIMES v\(pendingVersion)…"
        } else {
            updateTitle = "检查更新…"
        }
        let checkUpdate = NSMenuItem(
            title: updateTitle,
            action: #selector(RimeBufferController.checkUpdateFromInputMenu(_:)),
            keyEquivalent: "")
        checkUpdate.target = target
        maintenanceMenu.addItem(checkUpdate)

        let log = NSMenuItem(
            title: "打开日志 (~/rimebuffer.log)",
            action: #selector(RimeBufferController.openLogFromInputMenu(_:)),
            keyEquivalent: "")
        log.target = target
        maintenanceMenu.addItem(log)

        let deploy = NSMenuItem(
            title: "重新部署并重启",
            action: #selector(RimeBufferController.deployAndRestartFromInputMenu(_:)),
            keyEquivalent: "")
        deploy.target = target
        maintenanceMenu.addItem(deploy)

        let reinstall = NSMenuItem(
            title: "重新安装输入法…",
            action: #selector(RimeBufferController.reinstallFromInputMenu(_:)),
            keyEquivalent: "")
        reinstall.target = target
        maintenanceMenu.addItem(reinstall)

        let restart = NSMenuItem(
            title: "重启输入法进程",
            action: #selector(RimeBufferController.restartFromInputMenu(_:)),
            keyEquivalent: "")
        restart.target = target
        maintenanceMenu.addItem(restart)

        maintenance.submenu = maintenanceMenu
        menu.addItem(maintenance)

        return menu
    }

    private var inboundTrayTitle: String {
        let count = InboundBus.shared.pendingCount
        return count > 0
            ? "外部来源收件箱…（\(count) 项待审）"
            : "外部来源收件箱…"
    }

    func openSettings() {
        SettingsWindowController.shared.show()
    }

    func toggleBufferWindow() {
        BufferWindowController.shared.toggleVisibility()
    }

    func toggleClipboardHistory() {
        BufferWindowController.shared.toggleClipboardHistory()
    }

    func toggleBufferPinned() {
        BufferWindowController.shared.pinned.toggle()
    }

    func moveBufferWindowToCurrentScreen() {
        BufferWindowController.shared.openAndResume()
        BufferWindowController.shared.moveToCurrentScreen()
    }

    func openInboundTray() {
        InboundTrayWindow.shared.show()
    }

    func checkUpdate() {
        UpdateManager.shared.checkNowManually()
    }

    func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("rimebuffer.log")
        NSWorkspace.shared.open(url)
    }

    func deployAndRestart() {
        RimeBufferController.active?.forceCommit()
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
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        RimeBufferController.active?.forceCommit()
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
        RimeBufferController.active?.forceCommit()
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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
