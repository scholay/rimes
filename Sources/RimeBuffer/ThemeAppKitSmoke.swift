import AppKit
import Darwin

private final class FixedAccentSwitchActionProbe: NSObject {
    private(set) var count = 0
    private(set) weak var lastSender: RimeFixedAccentSwitch?

    @objc func changed(_ sender: RimeFixedAccentSwitch) {
        count += 1
        lastSender = sender
    }
}

private final class FixedAccentChoiceActionProbe: NSObject {
    private(set) var count = 0
    private(set) weak var lastSender: RimeFixedAccentChoiceButton?

    @objc func changed(_ sender: RimeFixedAccentChoiceButton) {
        count += 1
        lastSender = sender
    }
}

private final class FixedAccentPopUpActionProbe: NSObject {
    private(set) var count = 0

    @objc func changed(_ sender: RimeFixedAccentPopUpButton) {
        count += 1
    }
}

private func fixedAccentSwitchKeyEvent(
    modifiers: NSEvent.ModifierFlags = [],
    isRepeat: Bool = false
) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: " ",
        charactersIgnoringModifiers: " ",
        isARepeat: isRepeat,
        keyCode: 49
    )
}

/// AppKit interaction coverage for the product-owned accent controls and the
/// live Settings appearance observer. This intentionally uses no Rime engine,
/// client proxy, network provider, or live input-method state.
func runThemeAppKitSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) theme AppKit smoke test ==")
    var ok = true
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            print("FAILED: \(message)")
            ok = false
        }
    }

    check(Thread.isMainThread, "AppKit smoke must run on the main thread")
    // `NSControl.sendAction` is routed through NSApplication even with an
    // explicit target, so launch the minimal accessory application before
    // exercising the control.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let control = RimeFixedAccentSwitch(frame: .zero)
    let probe = FixedAccentSwitchActionProbe()
    control.target = probe
    control.action = #selector(FixedAccentSwitchActionProbe.changed(_:))
    control.setAccessibilityLabel("启用实时翻译")

    check(control.state == .off, "switch should begin off")
    check(control.accessibilityValue() as? NSNumber == NSNumber(value: false),
          "off state should expose a false NSNumber accessibility value")
    check(control.accessibilityRole() == .button,
          "switch should expose the AppKit button accessibility role")
    check(control.accessibilitySubrole() == .switch,
          "switch should expose the switch accessibility subrole")
    check(control.accessibilityLabel() == "启用实时翻译",
          "switch should retain a readable explicit accessibility label")

    control.performClick(nil)
    check(control.state == .on, "performClick should toggle on")
    check(probe.count == 1 && probe.lastSender === control,
          "performClick should send its configured action exactly once")
    check(control.accessibilityValue() as? NSNumber == NSNumber(value: true),
          "on state should expose a true NSNumber accessibility value")

    control.performClick(nil)
    check(control.state == .off && probe.count == 2,
          "a second performClick should toggle off with one more action")

    control.state = .mixed
    check(control.state == .on,
          "the two-state switch should normalize mixed to on")
    check(control.accessibilityValue() as? NSNumber == NSNumber(value: true),
          "normalized mixed state should expose true to accessibility")
    control.state = .off

    if let space = fixedAccentSwitchKeyEvent() {
        let before = probe.count
        control.keyDown(with: space)
        check(control.state == .on && probe.count == before + 1,
              "bare Space should toggle and dispatch exactly once")
    } else {
        check(false, "could not construct a bare Space key event")
    }

    if let controlSpace = fixedAccentSwitchKeyEvent(modifiers: .control) {
        let stateBefore = control.state
        let actionCountBefore = probe.count
        control.keyDown(with: controlSpace)
        check(control.state == stateBefore && probe.count == actionCountBefore,
              "Control+Space must remain a host shortcut")
    } else {
        check(false, "could not construct a Control+Space key event")
    }

    if let repeatedSpace = fixedAccentSwitchKeyEvent(isRepeat: true) {
        let stateBefore = control.state
        let actionCountBefore = probe.count
        control.keyDown(with: repeatedSpace)
        check(control.state == stateBefore && probe.count == actionCountBefore,
              "repeated Space must not toggle or dispatch")
    } else {
        check(false, "could not construct a repeated Space key event")
    }

    control.isEnabled = false
    let disabledState = control.state
    let disabledActionCount = probe.count
    control.performClick(nil)
    check(control.state == disabledState && probe.count == disabledActionCount,
          "a disabled switch must ignore performClick")
    check(!control.accessibilityPerformPress(),
          "a disabled switch must reject accessibility press")

    let checkbox = RimeFixedAccentChoiceButton.checkbox(title: "启用缓冲模式")
    let checkboxProbe = FixedAccentChoiceActionProbe()
    checkbox.target = checkboxProbe
    checkbox.action = #selector(FixedAccentChoiceActionProbe.changed(_:))

    check(checkbox.state == .off,
          "checkbox should begin off")
    check(checkbox.accessibilityValue() as? NSNumber == NSNumber(value: false),
          "off checkbox should expose a false NSNumber accessibility value")
    check(checkbox.accessibilityRole() == .checkBox,
          "checkbox should expose the checkbox accessibility role")
    check(checkbox.accessibilityLabel() == "启用缓冲模式",
          "checkbox title should be its readable accessibility label")

    checkbox.performClick(nil)
    check(checkbox.state == .on,
          "checkbox performClick should toggle on")
    check(checkboxProbe.count == 1 && checkboxProbe.lastSender === checkbox,
          "checkbox performClick should dispatch exactly once")
    check(checkbox.accessibilityValue() as? NSNumber == NSNumber(value: true),
          "on checkbox should expose a true NSNumber accessibility value")

    checkbox.performClick(nil)
    check(checkbox.state == .off && checkboxProbe.count == 2,
          "a second checkbox click should toggle off with one more action")

    if let space = fixedAccentSwitchKeyEvent() {
        let before = checkboxProbe.count
        checkbox.keyDown(with: space)
        check(checkbox.state == .on && checkboxProbe.count == before + 1,
              "bare Space should toggle a checkbox and dispatch exactly once")
    } else {
        check(false, "could not construct checkbox Space key event")
    }

    if let controlSpace = fixedAccentSwitchKeyEvent(modifiers: .control) {
        let stateBefore = checkbox.state
        let actionCountBefore = checkboxProbe.count
        checkbox.keyDown(with: controlSpace)
        check(checkbox.state == stateBefore
                && checkboxProbe.count == actionCountBefore,
              "Control+Space must not change or dispatch a checkbox")
    } else {
        check(false, "could not construct checkbox Control+Space key event")
    }

    if let repeatedSpace = fixedAccentSwitchKeyEvent(isRepeat: true) {
        let stateBefore = checkbox.state
        let actionCountBefore = checkboxProbe.count
        checkbox.keyDown(with: repeatedSpace)
        check(checkbox.state == stateBefore
                && checkboxProbe.count == actionCountBefore,
              "repeated Space must not change or dispatch a checkbox")
    } else {
        check(false, "could not construct repeated checkbox Space key event")
    }

    checkbox.isEnabled = false
    let disabledCheckboxState = checkbox.state
    let disabledCheckboxActionCount = checkboxProbe.count
    checkbox.performClick(nil)
    check(checkbox.state == disabledCheckboxState
            && checkboxProbe.count == disabledCheckboxActionCount,
          "a disabled checkbox must ignore performClick")
    check(!checkbox.accessibilityPerformPress(),
          "a disabled checkbox must reject accessibility press")

    let radio = RimeFixedAccentChoiceButton.radio(title: "墨竹")
    let radioProbe = FixedAccentChoiceActionProbe()
    radio.target = radioProbe
    radio.action = #selector(FixedAccentChoiceActionProbe.changed(_:))

    check(radio.state == .off,
          "radio button should begin off")
    check(radio.accessibilityValue() as? NSNumber == NSNumber(value: false),
          "off radio should expose a false NSNumber accessibility value")
    check(radio.accessibilityRole() == .radioButton,
          "radio should expose the radio-button accessibility role")
    check(radio.accessibilityLabel() == "墨竹",
          "radio title should be its readable accessibility label")

    radio.performClick(nil)
    check(radio.state == .on,
          "radio performClick should select the radio")
    check(radioProbe.count == 1 && radioProbe.lastSender === radio,
          "radio performClick should dispatch exactly once")
    check(radio.accessibilityValue() as? NSNumber == NSNumber(value: true),
          "on radio should expose a true NSNumber accessibility value")

    radio.performClick(nil)
    check(radio.state == .on && radioProbe.count == 2,
          "a selected radio should stay on and dispatch once per click")

    radio.state = .off
    if let space = fixedAccentSwitchKeyEvent() {
        let before = radioProbe.count
        radio.keyDown(with: space)
        check(radio.state == .on && radioProbe.count == before + 1,
              "bare Space should select a radio and dispatch exactly once")
    } else {
        check(false, "could not construct radio Space key event")
    }

    if let controlSpace = fixedAccentSwitchKeyEvent(modifiers: .control) {
        let stateBefore = radio.state
        let actionCountBefore = radioProbe.count
        radio.keyDown(with: controlSpace)
        check(radio.state == stateBefore && radioProbe.count == actionCountBefore,
              "Control+Space must not change or dispatch a radio")
    } else {
        check(false, "could not construct radio Control+Space key event")
    }

    if let repeatedSpace = fixedAccentSwitchKeyEvent(isRepeat: true) {
        let stateBefore = radio.state
        let actionCountBefore = radioProbe.count
        radio.keyDown(with: repeatedSpace)
        check(radio.state == stateBefore && radioProbe.count == actionCountBefore,
              "repeated Space must not change or dispatch a radio")
    } else {
        check(false, "could not construct repeated radio Space key event")
    }

    radio.isEnabled = false
    let disabledRadioState = radio.state
    let disabledRadioActionCount = radioProbe.count
    radio.performClick(nil)
    check(radio.state == disabledRadioState
            && radioProbe.count == disabledRadioActionCount,
          "a disabled radio must ignore performClick")
    check(!radio.accessibilityPerformPress(),
          "a disabled radio must reject accessibility press")

    let popup = RimeFixedAccentPopUpButton()
    popup.addItems(withTitles: ["墨竹", "翡翠", "静谧"])
    let popupProbe = FixedAccentPopUpActionProbe()
    popup.target = popupProbe
    popup.action = #selector(FixedAccentPopUpActionProbe.changed(_:))
    check(popup.numberOfItems == 3 && popup.selectedItem?.title == "墨竹",
          "fixed-accent popup should retain native menu selection behavior")
    popup.selectItem(at: 2)
    check(popup.selectedItem?.title == "静谧" && popupProbe.count == 0,
          "programmatic popup selection should not dispatch an action")
    let nativePopup = NSPopUpButton()
    check(popup.accessibilityRole() == nativePopup.accessibilityRole()
            && popup.accessibilitySubrole() == nativePopup.accessibilitySubrole(),
          "fixed-accent popup should preserve native popup accessibility")

    // Exercise the actual Settings observer in one window. Both the environment
    // override and persisted preference are restored so this standalone smoke
    // cannot change the user's selected theme.
    let defaults = UserDefaults.standard
    let appearanceKey = "appearanceMode"
    let previousPreference = defaults.object(forKey: appearanceKey)
    let previousEnvironment = ProcessInfo.processInfo.environment[
        "RIMEBUFFER_APPEARANCE_MODE"
    ]
    unsetenv("RIMEBUFFER_APPEARANCE_MODE")
    defaults.set(RimeAppearanceMode.night.rawValue, forKey: appearanceKey)

    SettingsWindowController.shared.show()
    let settingsWindow = app.windows.first {
        $0.title == "\(ProductIdentity.displayName) 设置"
    }

    var appearanceNotificationCount = 0
    let observer = NotificationCenter.default.addObserver(
        forName: .rimeAppearanceDidChange,
        object: nil,
        queue: nil
    ) { _ in
        appearanceNotificationCount += 1
    }

    func drainMainRunLoop(until condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 1)
        while !condition(), Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func matches(_ window: NSWindow?, mode: RimeAppearanceMode) -> Bool {
        let expected = mode.appKitAppearanceName(
            increasedContrast: NSWorkspace.shared
                .accessibilityDisplayShouldIncreaseContrast
        )
        return window?.appearance?.name == expected
            && window?.effectiveAppearance.name == expected
    }

    check(settingsWindow != nil && settingsWindow?.isVisible == true,
          "settings smoke should locate the live settings window")
    check(matches(settingsWindow, mode: .night),
          "settings should initially use 墨竹 AppKit appearance")

    RimeUI.appearance = .day
    drainMainRunLoop { matches(settingsWindow, mode: .day) }
    check(matches(settingsWindow, mode: .day),
          "the same settings window should transition to 翡翠")

    RimeUI.appearance = .quiet
    drainMainRunLoop {
        RimeUI.appearance == .quiet && matches(settingsWindow, mode: .quiet)
    }
    check(RimeUI.appearance == .quiet
            && matches(settingsWindow, mode: .quiet),
          "the same settings window should transition to dark 静谧")

    RimeUI.appearance = .night
    drainMainRunLoop { matches(settingsWindow, mode: .night) }
    check(matches(settingsWindow, mode: .night),
          "the same settings window should transition back to 墨竹")
    check(appearanceNotificationCount == 3,
          "墨竹→翡翠→静谧→墨竹 should emit exactly three appearance notifications")

    NotificationCenter.default.removeObserver(observer)
    settingsWindow?.close()
    if let previousPreference {
        defaults.set(previousPreference, forKey: appearanceKey)
    } else {
        defaults.removeObject(forKey: appearanceKey)
    }
    NotificationCenter.default.post(name: .rimeAppearanceDidChange, object: nil)
    if let previousEnvironment {
        setenv("RIMEBUFFER_APPEARANCE_MODE", previousEnvironment, 1)
    } else {
        unsetenv("RIMEBUFFER_APPEARANCE_MODE")
    }

    if ok { print("theme AppKit smoke: OK") }
    return ok
}
