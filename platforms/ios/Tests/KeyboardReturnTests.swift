import XCTest
import UIKit
import RimesCore
@testable import RIMES

@MainActor final class KeyboardReturnTests: XCTestCase {
    private enum Layout: CaseIterable { case qwerty, nineKey, custom, orthogonal, split }

    func testEveryLayoutInsertsBufferBlocksBeforePerformingHostReturn() throws {
        for layout in Layout.allCases {
            for theme: StatusSkin in [.apple, .rhino] {
                let (window, keyboard) = host(layout); defer { window.isHidden = true }
                keyboard.developmentSkin(theme)
                keyboard.layoutProxy.returnKeyType = .send
                keyboard.developmentBuffer("")
                let key = try returnKey(keyboard)
                XCTAssertEqual(key.currentTitle, L("发送", "Send"))
                keyboard.developmentBuffer("甲。乙。")
                XCTAssertEqual(key.currentTitle, L("上屏", "Insert"))
                tap(key)
                XCTAssertEqual(keyboard.layoutProxy.insertions, ["甲。"], "\(layout), \(theme)")
                XCTAssertEqual(keyboard.developmentBufferSource.text, "乙。")
                XCTAssertEqual(key.currentTitle, L("上屏", "Insert"))
                tap(key)
                XCTAssertEqual(keyboard.layoutProxy.insertions, ["甲。", "乙。"])
                XCTAssertTrue(keyboard.developmentBufferSource.text.isEmpty)
                XCTAssertEqual(key.currentTitle, L("发送", "Send"))
                tap(key)
                XCTAssertEqual(keyboard.layoutProxy.insertions, ["甲。", "乙。", "\n"])
                keyboard.layoutProxy.returnKeyType = .search; keyboard.developmentBuffer(nil)
                XCTAssertEqual(key.currentTitle, L("搜索", "Search"))
                keyboard.layoutProxy.returnKeyType = .default; keyboard.developmentBuffer(nil)
                XCTAssertEqual(key.currentTitle, L("换行", "return"))
            }
        }
    }

    func testCompositionConfirmationRequiresAnotherTapToInsertTheBuffer() throws {
        for layout in Layout.allCases {
            let (window, keyboard) = host(layout); defer { window.isHidden = true }
            keyboard.layoutProxy.returnKeyType = .send
            keyboard.developmentBuffer("")
            keyboard.developmentType(layout == .nineKey ? "64" : "ni")
            let key = try returnKey(keyboard)
            XCTAssertEqual(key.currentTitle, L("确认", "Confirm"))
            tap(key)
            XCTAssertTrue(keyboard.developmentRaw.isEmpty)
            XCTAssertFalse(keyboard.developmentBufferSource.text.isEmpty)
            XCTAssertTrue(keyboard.layoutProxy.insertions.isEmpty)
            XCTAssertEqual(key.currentTitle, L("上屏", "Insert"))
            let committed = keyboard.developmentBufferSource.text
            tap(key)
            XCTAssertEqual(keyboard.layoutProxy.insertions, [committed])
            XCTAssertEqual(key.currentTitle, L("发送", "Send"))
        }
    }

    func testPluginReturnKeepsRemainingBlocksAndWaitsForCompletedOutput() throws {
        let (window, keyboard) = host(.qwerty); defer { window.isHidden = true }
        keyboard.layoutProxy.returnKeyType = .send
        keyboard.developmentPlugin(.polish, source: "原文", output: "One.Two.", blocks: ["One.", "Two."])
        let key = try returnKey(keyboard)
        tap(key)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["One."])
        XCTAssertTrue(keyboard.developmentBufferSource.text.isEmpty)
        XCTAssertEqual(key.currentTitle, L("上屏", "Insert"))
        tap(key)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["One.", "Two."])
        XCTAssertEqual(key.currentTitle, L("发送", "Send"))
        for generating in [false, true] {
            keyboard.developmentPlugin(.polish, source: "不能直接泄漏原文", generating: generating)
            XCTAssertFalse(key.isEnabled)
            if generating { keyboard.developmentPreview("partial") }
            keyboard.developmentEnter()
            XCTAssertEqual(keyboard.layoutProxy.insertions, ["One.", "Two."])
            XCTAssertEqual(keyboard.developmentBufferSource.text, "不能直接泄漏原文")
        }
    }

    func testCompletedPluginResultCannotSurviveDisableAndReenable() throws {
        let (window, keyboard) = host(.qwerty); defer { window.isHidden = true }
        keyboard.developmentPlugin(.polish, source: "保留原文", output: "Old result")
        let key = try returnKey(keyboard)
        key.sendActions(for: .touchDown)
        try keyboard.developmentRevokePlugin(.polish)
        key.sendActions(for: .touchUpInside)
        keyboard.developmentEnter()
        XCTAssertTrue(keyboard.layoutProxy.insertions.isEmpty)
        XCTAssertEqual(keyboard.developmentBufferSource.text, "保留原文")
        keyboard.developmentPlugin(.polish, source: "新请求", output: "Fresh result")
        tap(key)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["Fresh result"])
    }

    func testHeldReturnCannotTurnIntoSendAfterAnotherActionDrainsBuffer() throws {
        let (window, keyboard) = host(.orthogonal); defer { window.isHidden = true }
        keyboard.layoutProxy.returnKeyType = .send
        keyboard.developmentBuffer("保留发送边界")
        let key = try returnKey(keyboard)
        key.sendActions(for: .touchDown)
        XCTAssertTrue(keyboard.layoutViews.insert.accessibilityActivate())
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["保留发送边界"])
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["保留发送边界"])
        tap(key)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["保留发送边界", "\n"])
        keyboard.developmentBuffer("旧输入框内容")
        key.sendActions(for: .touchDown)
        keyboard.layoutProxy.documentIdentifier = UUID()
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(keyboard.layoutProxy.insertions, ["保留发送边界", "\n"])
        XCTAssertEqual(keyboard.developmentBufferSource.text, "旧输入框内容")
    }

    func testNativeThemeUsesDotIncludingLegacySelection() throws {
        let indicator = StatusLight(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        for skin: StatusSkin in [.apple, .light] {
            indicator.skin = skin; indicator.layoutIfNeeded()
            let dot = try XCTUnwrap(indicator.layer.sublayers?.first { $0.name == "status.dot" })
            XCTAssertFalse(dot.isHidden)
            XCTAssertEqual(dot.bounds.size, CGSize(width: 10, height: 10))
            for state: StatusLight.State in [.idle, .waiting, .streaming, .ready, .failed] {
                indicator.set(state)
                XCTAssertFalse(dot.isHidden)
                XCTAssertEqual(dot.backgroundColor, state.color.resolvedColor(with: indicator.traitCollection).cgColor)
            }
            XCTAssertTrue(indicator.subviews.allSatisfy(\.isHidden))
        }
        indicator.skin = .rhino
        XCTAssertEqual(indicator.layer.sublayers?.first { $0.name == "status.dot" }?.isHidden, true)
    }

    func testMenusNameBufferAndKeepIconsWithoutExposingChordLayout() throws {
        let (window, keyboard) = host(.split); defer { window.isHidden = true }
        let originalLayout = keyboard.layoutViews.keys.chordLayout
        let gear = try XCTUnwrap(keyboard.layoutViews.settings.menu)
        let entries = menuEntries(gear)
        XCTAssertFalse(entries.contains { ["Chord layout", "并击布局"].contains($0.title) })
        for title in [L("繁体输出", "Traditional Chinese output"), L("按键震动", "Key haptics")] {
            XCTAssertNotNil(try XCTUnwrap(entries.first { $0.title == title }).image)
        }
        let pluginButton = keyboard.developmentPluginControls.plugin
        let buffer = try XCTUnwrap(pluginButton.menu?.children.first as? UIAction)
        XCTAssertEqual(buffer.title, "Buffer"); XCTAssertNotNil(buffer.image)
        XCTAssertEqual(pluginButton.accessibilityLabel, "Buffer"); XCTAssertNotNil(pluginButton.image(for: .normal))
        keyboard.developmentOpenSettings()
        let chip = try XCTUnwrap(keyboard.developmentPanel?.chips.first { $0.item.id == "default" })
        XCTAssertEqual(chip.accessibilityLabel, "Buffer"); XCTAssertNotNil(chip.icon.image)
        XCTAssertEqual(keyboard.layoutViews.keys.chordLayout, originalLayout)
    }

    private func returnKey(_ keyboard: KeyboardViewController) throws -> KeycapButton {
        try XCTUnwrap(keyboard.developmentStandardFunctions[.enter] as? KeycapButton)
    }
    private func tap(_ key: KeycapButton) { key.sendActions(for: .touchDown); key.sendActions(for: .touchUpInside) }
    private func menuEntries(_ menu: UIMenu) -> [UIMenuElement] {
        menu.children.flatMap { element in [element] + ((element as? UIMenu).map(menuEntries) ?? []) }
    }
    private func host(_ layout: Layout) -> (UIWindow, KeyboardViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let keyboard = KeyboardViewController(); keyboard.layoutNeedsInputModeSwitchKey = false
        keyboard.loadViewIfNeeded(); keyboard.developmentResetPreferences()
        parent.addChild(keyboard); parent.view.addSubview(keyboard.view); keyboard.didMove(toParent: parent)
        switch layout {
        case .qwerty: keyboard.developmentOrdinaryAppearance(layout: .qwerty)
        case .nineKey: keyboard.developmentOrdinaryAppearance(layout: .nineKey)
        case .custom: keyboard.developmentSetCustomLayout(CustomKeyboardLayout.templates[0])
        case .orthogonal: keyboard.developmentChoose(.chord); keyboard.developmentSetLayout(.orthogonal)
        case .split: keyboard.developmentChoose(.chord); keyboard.developmentSetLayout(.splitOrthogonal)
        }
        parent.view.layoutIfNeeded(); keyboard.view.layoutIfNeeded()
        return (window, keyboard)
    }
}
