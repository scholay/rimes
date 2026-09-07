import AppKit

/// Only records AppKit delivery. None of these selectors touches the live IME,
/// preferences, log files, updater, deployment, installation, or process exit.
private final class StatusMenuActionSpy: NSObject {
    struct Invocation {
        let selectorName: String
        let item: NSMenuItem?
    }

    private(set) var invocations: [Invocation] = []

    private func record(_ selectorName: String, sender: Any?) {
        invocations.append(Invocation(selectorName: selectorName, item: sender as? NSMenuItem))
    }

    @objc func openSettingsFromInputMenu(_ sender: Any?) {
        record("openSettingsFromInputMenu:", sender: sender)
    }
    @objc func toggleBufferWindowFromInputMenu(_ sender: Any?) {
        record("toggleBufferWindowFromInputMenu:", sender: sender)
    }
    @objc func toggleClipboardHistoryFromInputMenu(_ sender: Any?) {
        record("toggleClipboardHistoryFromInputMenu:", sender: sender)
    }
    @objc func openMailboxFromInputMenu(_ sender: Any?) {
        record("openMailboxFromInputMenu:", sender: sender)
    }
    @objc func openCapsuleFromInputMenu(_ sender: Any?) {
        record("openCapsuleFromInputMenu:", sender: sender)
    }
    @objc func openMaintenanceFromInputMenu(_ sender: Any?) {
        record("openMaintenanceFromInputMenu:", sender: sender)
    }
    @objc func checkUpdateFromInputMenu(_ sender: Any?) {
        record("checkUpdateFromInputMenu:", sender: sender)
    }
    @objc func openLogFromInputMenu(_ sender: Any?) {
        record("openLogFromInputMenu:", sender: sender)
    }
    @objc func deployAndRestartFromInputMenu(_ sender: Any?) {
        record("deployAndRestartFromInputMenu:", sender: sender)
    }
    @objc func reinstallFromInputMenu(_ sender: Any?) {
        record("reinstallFromInputMenu:", sender: sender)
    }
    @objc func restartFromInputMenu(_ sender: Any?) {
        record("restartFromInputMenu:", sender: sender)
    }
}

/// Tests production menu construction and in-process AppKit target/action
/// dispatch. This intentionally does not claim to test TextInputMenuAgent's
/// cross-process IMK callback, nor does it open a menu or execute maintenance.
func runStatusMenuSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("status-menu-smoke: FAIL \(message)")
        return false
    }
    guard Thread.isMainThread else { return fail("AppKit requires the main thread") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let spy = StatusMenuActionSpy()
    let state = InputSourceMenuState(
        healthy: true,
        bufferTitle: "Buffer…（⌃⌥B）",
        clipboardTitle: "Clipboard History…（⌃⌥P）",
        mailboxTitle: "Mailbox…（3 条未读 · ⌃⌥M）",
        capsuleTitle: "Capsule…（⌃⌥C）"
    )
    let sourceMenu = StatusMenu.makeInputSourceMenu(target: spy, state: state)
    let sourceTitles = [
        "设置…", state.bufferTitle, state.clipboardTitle,
        state.mailboxTitle, state.capsuleTitle, "", "维护…"
    ]
    guard sourceMenu.items.map(\.title) == sourceTitles,
          sourceMenu.items.filter(\.isSeparatorItem).count == 1,
          sourceMenu.items[5].isSeparatorItem,
          sourceMenu.items.allSatisfy({ $0.submenu == nil }) else {
        return fail("main menu must contain five modules and one maintenance entry, without remote submenus")
    }
    let removedTitles = ["常显于所有桌面与全屏空间", "把缓冲工作台移到当前屏幕"]
    guard sourceMenu.items.allSatisfy({ !removedTitles.contains($0.title) }) else {
        return fail("removed workbench commands remain visible")
    }

    let unhealthyMenu = StatusMenu.makeInputSourceMenu(target: spy, state: InputSourceMenuState(
        healthy: false,
        bufferTitle: state.bufferTitle,
        clipboardTitle: state.clipboardTitle,
        mailboxTitle: state.mailboxTitle,
        capsuleTitle: state.capsuleTitle
    ))
    guard unhealthyMenu.items.count == sourceTitles.count + 2,
          unhealthyMenu.items[0].title == "⚠️ 输入引擎异常 — 已退化为英文直通",
          !unhealthyMenu.items[0].isEnabled,
          unhealthyMenu.items[0].action == nil,
          unhealthyMenu.items[1].isSeparatorItem,
          unhealthyMenu.items.dropFirst(2).map(\.title) == sourceTitles else {
        return fail("engine health warning must precede the unchanged main commands")
    }

    let refreshedState = InputSourceMenuState(
        healthy: true,
        bufferTitle: "Buffer…（⇧⌘B）",
        clipboardTitle: "Clipboard History…（⇧⌘P）",
        mailboxTitle: "Mailbox…（⇧⌘M）",
        capsuleTitle: "Capsule…（⇧⌘C）"
    )
    let refreshedMenu = StatusMenu.makeInputSourceMenu(target: spy, state: refreshedState)
    guard refreshedMenu.items.count == sourceTitles.count,
          refreshedMenu.items[1...4].map(\.title) == [
        refreshedState.bufferTitle, refreshedState.clipboardTitle,
        refreshedState.mailboxTitle, refreshedState.capsuleTitle
    ], sourceMenu.items.map(\.title) == sourceTitles else {
        return fail("fresh menu snapshots must preserve current shortcut and unread-count titles")
    }

    let maintenanceMenu = StatusMenu.makeMaintenanceMenu(target: spy, pendingVersion: nil)
    let maintenanceTitles = [
        "检查更新…", "打开日志 (~/rimebuffer.log)", "重新部署并重启",
        "重新安装输入法…", "重启输入法进程"
    ]
    guard maintenanceMenu.title == "维护",
          maintenanceMenu.items.map(\.title) == maintenanceTitles,
          maintenanceMenu.items.allSatisfy({ !$0.isSeparatorItem && $0.submenu == nil }) else {
        return fail("maintenance must contain exactly the five existing commands")
    }
    let pendingMenu = StatusMenu.makeMaintenanceMenu(target: spy, pendingVersion: "9.8.7-preview.1")
    guard pendingMenu.items.first?.title == "安装 RIMES v9.8.7-preview.1…",
          pendingMenu.items.dropFirst().map(\.title) == Array(maintenanceTitles.dropFirst()) else {
        return fail("ready update title must retain the pending version and all other commands")
    }

    // Cancelling an unpresented menu must be inert too. Actual tracking and
    // cancellation are deliberately reserved for the separate safe preview.
    for menu in [sourceMenu, unhealthyMenu, refreshedMenu, maintenanceMenu, pendingMenu] {
        menu.cancelTracking()
    }
    guard spy.invocations.isEmpty else { return fail("constructing or cancelling menus dispatched an action") }

    func verifyDispatch(_ menu: NSMenu, selectors: [String]) -> Bool {
        let items = menu.items.filter { !$0.isSeparatorItem }
        guard items.count == selectors.count else { return fail("dispatch fixture item count") }
        for (item, selectorName) in zip(items, selectors) {
            guard item.isEnabled,
                  item.target as? NSObject === spy,
                  item.action == NSSelectorFromString(selectorName),
                  spy.responds(to: NSSelectorFromString(selectorName)) else {
                return fail("incorrect target/action wiring for \(selectorName)")
            }
            let previousCount = spy.invocations.count
            menu.performActionForItem(at: menu.index(of: item))
            guard spy.invocations.count == previousCount + 1,
                  spy.invocations.last?.selectorName == selectorName,
                  spy.invocations.last?.item === item else {
                return fail("AppKit did not dispatch \(selectorName) exactly once to the injected spy")
            }
        }
        return true
    }

    guard verifyDispatch(sourceMenu, selectors: [
        "openSettingsFromInputMenu:", "toggleBufferWindowFromInputMenu:",
        "toggleClipboardHistoryFromInputMenu:", "openMailboxFromInputMenu:",
        "openCapsuleFromInputMenu:", "openMaintenanceFromInputMenu:"
    ]), verifyDispatch(maintenanceMenu, selectors: [
        "checkUpdateFromInputMenu:", "openLogFromInputMenu:",
        "deployAndRestartFromInputMenu:", "reinstallFromInputMenu:",
        "restartFromInputMenu:"
    ]), spy.invocations.count == 11 else { return false }
    let completedCount = spy.invocations.count
    maintenanceMenu.cancelTracking()
    sourceMenu.cancelTracking()
    guard spy.invocations.count == completedCount else { return fail("cancellation replayed a prior command") }

    print("status-menu-smoke: PASS compact main menu, health and dynamic titles, five maintenance commands, 11 isolated AppKit actions, inert construction/cancellation")
    return true
}

/// Optional manual visual/interaction preview. Even clicking deployment,
/// reinstall, or restart only records a spy invocation and exits the preview.
/// This function is never called by the noninteractive smoke test.
func runStatusMaintenanceMenuPreview() -> Bool {
    guard Thread.isMainThread else { return false }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let spy = StatusMenuActionSpy()
    let menu = StatusMenu.makeMaintenanceMenu(target: spy, pendingVersion: nil)
    let selected = withExtendedLifetime(spy) {
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    let valid = selected ? spy.invocations.count == 1 : spy.invocations.isEmpty
    print("status-maintenance-menu-preview: \(valid ? "PASS" : "FAIL") selected=\(selected) spyActions=\(spy.invocations.count); no real maintenance executed")
    return valid
}
