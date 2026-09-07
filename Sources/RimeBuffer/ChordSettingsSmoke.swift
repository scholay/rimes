import AppKit
import Foundation

/// Exercises the production settings controls with in-memory state and actions.
/// It does not read/write chord preferences, deploy Rime, select an input source,
/// or access an IMK client. Rendering is optional and also works offscreen.
func runChordSettingsSmokeTest(outputURL: URL? = nil) -> Bool {
    func fail(_ message: String) -> Bool {
        print("chord-settings-smoke: FAIL \(message)")
        return false
    }
    guard Thread.isMainThread else { return fail("AppKit requires the main thread") }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    var isCurrent = false
    var duration = ChordSettings.defaultDuration
    var durationWrites = 0
    var resetRequests = 0
    var selectionRequests = 0
    let pane = FlyChordConfigurationPageView(
        stateProvider: {
            FlyChordConfigurationState(isEnabled: true,
                                       implementationName: "飞耀输入 · 并击",
                                       isCurrent: isCurrent,
                                       duration: duration)
        },
        onDuration: { duration = $0; durationWrites += 1 },
        onReset: { duration = ChordSettings.defaultDuration; resetRequests += 1 },
        onMakeCurrent: { isCurrent = true; selectionRequests += 1; return true },
        observesChanges: false
    )
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let views = descendants(pane)
    let labels = views.compactMap { $0 as? NSTextField }
    let buttons = views.compactMap { $0 as? NSButton }
    let copy = labels.map(\.stringValue).joined(separator: "\n")
    guard copy.contains("先左后右"), copy.contains("停顿本身不会取消"),
          copy.contains("两次单键不会跨批合并"), copy.contains("合并项须为完整音节"),
          !copy.contains("互击"), !copy.contains("并击结算模式"),
          !buttons.contains(where: { ["互击", "并击"].contains($0.title) }),
          !views.contains(where: {
              $0 is NSPopUpButton || $0 is NSSegmentedControl || $0 is RimeFixedAccentChoiceButton
          }) else { return fail("unified behavior or removal of the old mode picker") }
    guard let field = labels.first(where: {
        $0.accessibilityIdentifier() == "chord-settings.duration"
    }),
    let makeCurrent = buttons.first(where: {
        $0.accessibilityIdentifier() == "chord-settings.make-current"
    }),
    let reset = buttons.first(where: {
        $0.accessibilityIdentifier() == "chord-settings.reset-duration"
    }),
    let stepper = views.compactMap({ $0 as? NSStepper }).first,
    field.isEnabled, makeCurrent.isEnabled, stepper.isEnabled,
    selectionRequests == 0, durationWrites == 0, resetRequests == 0 else {
        return fail("initial render must expose controls without changing state")
    }

    field.doubleValue = 0.14
    guard field.sendAction(field.action, to: field.target),
          abs(duration - 0.14) < 0.0001, durationWrites == 1,
          abs(stepper.doubleValue - duration) < 0.0001 else {
        return fail("duration field action and refreshed stepper")
    }
    stepper.doubleValue = 0.15
    guard stepper.sendAction(stepper.action, to: stepper.target),
          abs(duration - 0.15) < 0.0001, durationWrites == 2,
          abs(field.doubleValue - duration) < 0.0001 else {
        return fail("duration stepper action and refreshed field")
    }
    reset.performClick(nil)
    guard resetRequests == 1, duration == ChordSettings.defaultDuration,
          field.doubleValue == duration else { return fail("restore default action") }
    makeCurrent.performClick(nil)
    guard selectionRequests == 1, isCurrent, !makeCurrent.isEnabled,
          makeCurrent.title == "当前输入方案" else {
        return fail("explicit input-scheme selection action")
    }

    var disabledActionRequests = 0
    let disabledPane = FlyChordConfigurationPageView(
        stateProvider: {
            FlyChordConfigurationState(isEnabled: false,
                                       implementationName: "飞耀输入 · 并击",
                                       isCurrent: false,
                                       duration: ChordSettings.defaultDuration)
        },
        onDuration: { _ in disabledActionRequests += 1 },
        onReset: { disabledActionRequests += 1 },
        onMakeCurrent: { disabledActionRequests += 1; return true },
        observesChanges: false
    )
    let disabledViews = descendants(disabledPane)
    guard let disabledField = disabledViews.compactMap({ $0 as? NSTextField }).first(where: {
        $0.accessibilityIdentifier() == "chord-settings.duration"
    }),
    let disabledSelection = disabledViews.compactMap({ $0 as? NSButton }).first(where: {
        $0.accessibilityIdentifier() == "chord-settings.make-current"
    }),
    !disabledField.isEnabled, !disabledSelection.isEnabled,
    disabledViews.compactMap({ $0 as? NSTextField }).contains(where: {
        $0.stringValue == "已停用"
    }), disabledActionRequests == 0 else {
        return fail("disabled extension state and side-effect isolation")
    }

    pane.wantsLayer = true
    pane.layer?.backgroundColor = RimeUI.surface.cgColor
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 698, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = RimeUI.appKitAppearance
    window.backgroundColor = RimeUI.surface
    window.contentView = pane
    defer { window.close() }
    pane.layoutSubtreeIfNeeded()
    let fittingHeight = ceil(pane.fittingSize.height)
    guard fittingHeight.isFinite, (200...900).contains(fittingHeight) else {
        return fail("unexpected settings fitting height: \(fittingHeight)")
    }
    window.setContentSize(NSSize(width: 698, height: fittingHeight))
    pane.layoutSubtreeIfNeeded()
    guard field.frame.width >= 60, makeCurrent.frame.width >= 75,
          labels.filter({ $0.accessibilityIdentifier() == "chord-settings.behavior" })
            .allSatisfy({ $0.frame.width >= 600 && $0.frame.height >= 12 }) else {
        return fail("settings controls or behavior text are collapsed")
    }
    pane.displayIfNeeded()
    guard pane.bounds.width == 698,
          let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else {
        return fail("settings render surface is invalid")
    }
    pane.cacheDisplay(in: pane.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
        return fail("settings PNG rendering failed")
    }
    if let outputURL {
        do {
            try png.write(to: outputURL, options: .atomic)
            print("chord-settings-smoke: rendered \(outputURL.path)")
        } catch { return fail(error.localizedDescription) }
    }
    print("chord-settings-smoke: PASS unified UI, isolated duration/reset/selection actions, disabled state, \(Int(pane.bounds.width))×\(Int(pane.bounds.height)) render")
    return true
}
