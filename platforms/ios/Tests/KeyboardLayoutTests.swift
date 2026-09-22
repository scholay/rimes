import XCTest
import UIKit
import RimesCore
@testable import RIMES

typealias DocumentIdentity = RIMES.DocumentIdentity
typealias MobileEngine = RIMES.MobileEngine
typealias ProxyTextDelivery = RIMES.ProxyTextDelivery
typealias AppConfiguration = RIMES.AppConfiguration
typealias ConfigurationStore = RIMES.ConfigurationStore
typealias KeychainStore = RIMES.KeychainStore
typealias KeyboardPreferenceStore = RIMES.KeyboardPreferenceStore
typealias AppleTranslationPlugin = RIMES.AppleTranslationPlugin
typealias AITextPlugin = RIMES.AITextPlugin
func L(_ zh: String, _ en: String) -> String { RIMES.L(zh, en) }

@MainActor final class KeyboardLayoutTests: XCTestCase {
    func testNativeKeyboardLayoutsAndSnapshots() async throws {
        let variants: [(String, CGFloat, Bool, Bool, Bool, UIUserInterfaceStyle)] = [
            ("portrait", 393, false, false, false, .light),
            ("buffer", 393, true, false, true, .light),
            ("buffer-expanded", 393, true, true, true, .light),
            ("narrow-dark", 320, true, false, true, .dark),
            ("landscape", 852, true, true, true, .dark),
            ("idle", 393, false, false, false, .light),
            ("buffer-empty", 393, true, false, false, .light),
            ("long-text", 320, true, true, false, .light),
            ("landscape-idle", 852, false, false, false, .dark),
            ("chord-idle", 393, false, false, true, .light),
            ("emoji", 320, false, false, true, .light),
            ("default-blocks", 393, true, false, true, .light),
            ("default-blocks-narrow", 320, true, false, true, .dark),
            ("default-blocks-landscape", 852, true, false, true, .dark)
        ]
        for (name, width, buffer, expanded, chord, style) in variants {
            let controller = KeyboardViewController(); controller.layoutNeedsInputModeSwitchKey = false
            controller.layoutProxy.keyboardAppearance = style == .dark ? .dark : .light
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
            window.overrideUserInterfaceStyle = style
            let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
            parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            controller.view.tintColor = .systemTeal
            NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor), controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor), controller.view.widthAnchor.constraint(equalToConstant: width)])
            parent.view.layoutIfNeeded()
            defer { window.isHidden = true }
            try await Task.sleep(nanoseconds: 80_000_000)
            controller.overrideUserInterfaceStyle = style
            controller.view.overrideUserInterfaceStyle = style
            let (bufferView, candidates, keys) = controller.developmentLayout(bufferText: buffer ? "你好，这是一段用于检查空间布局的原文。" : nil, expanded: expanded, chord: chord)
            if name.hasSuffix("idle") || name == "emoji" { controller.developmentContent() }
            if name == "buffer-empty" { controller.developmentContent(); controller.developmentBuffer("") }
            if name.hasPrefix("default-blocks") {
                controller.developmentBuffer("第一句。第二句！这是正在编辑的第三块", plugin: false)
                controller.developmentContent()
            }
            if name == "long-text" {
                controller.developmentBuffer(String(repeating: "长原文内容。", count: 100), plugin: true, output: String(repeating: "A longer translation preview. ", count: 100))
                controller.developmentContent(preedit: "changhouxuan", candidates: ["长候选词", "你好", "世界", "用来验证长候选文字不会缩小的句子", "测试", "一", "二", "三", "四", "五"])
            }
            let height = try XCTUnwrap(controller.view.constraints.first { $0.firstItem === controller.view && $0.firstAttribute == .height && $0.secondItem == nil }).constant
            XCTAssertGreaterThan(height, 140)
            parent.view.setNeedsLayout(); parent.view.layoutIfNeeded(); controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.view.traitCollection.userInterfaceStyle, style, name)
            XCTAssertEqual(keys.traitCollection.userInterfaceStyle, style, name)
            let keyFrame = keys.convert(keys.bounds, to: controller.view)
            let candidateFrame = candidates.convert(candidates.bounds, to: controller.view)
            XCTAssertGreaterThanOrEqual(keyFrame.height, chord ? 80 : 100, name)
            if !candidates.isHidden { XCTAssertLessThanOrEqual(candidateFrame.maxY, keyFrame.minY, name) }
            if buffer {
                let bufferFrame = bufferView.convert(bufferView.bounds, to: controller.view)
                XCTAssertLessThanOrEqual(bufferFrame.maxY, candidates.isHidden ? keyFrame.minY : candidateFrame.minY, name)
                XCTAssertLessThanOrEqual(bufferFrame.height, 140, name)
            }
            XCTAssertLessThanOrEqual(keyFrame.maxX, width, name)
            if name == "emoji" {
                XCTAssertTrue(try XCTUnwrap(keys.subviews.first { $0.accessibilityIdentifier == "keyboard.emoji" }).accessibilityActivate())
            } else if chord && name != "chord-idle" { keys.developmentPress("a", end: "s") }
            controller.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 80_000_000)
            let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
            let image = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("build22-keyboard-\(name).png")
            try image.pngData()?.write(to: path)
        }
    }
}

@MainActor final class LayoutTestDocumentProxy: NSObject, UITextDocumentProxy {
    let native = UITextView()
    var keyboardAppearance: UIKeyboardAppearance = .default
    var documentIdentifier = UUID()
    var identityAvailable = true
    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(getter: UITextDocumentProxy.documentIdentifier), !identityAvailable { return false }
        return super.responds(to: selector)
    }
    var onProxyWrite: (() -> Void)?
    var insertions: [String] = []
    var markedUpdates: [String] = []
    var documentContextBeforeInput: String? { String((native.text as NSString).substring(to: native.selectedRange.location)) }
    var documentContextAfterInput: String? { String((native.text as NSString).substring(from: NSMaxRange(native.selectedRange))) }
    var selectedText: String? { native.selectedRange.length == 0 ? nil : (native.text as NSString).substring(with: native.selectedRange) }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { native.hasText }
    func insertText(_ text: String) { insertions.append(text); native.insertText(text); onProxyWrite?() }
    func deleteBackward() { native.deleteBackward(); onProxyWrite?() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        native.selectedRange = NSRange(location: max(0, min(native.text.utf16.count, native.selectedRange.location + offset)), length: 0)
    }
    func setMarkedText(_ markedText: String, selectedRange: NSRange) { markedUpdates.append(markedText); native.setMarkedText(markedText, selectedRange: selectedRange); onProxyWrite?() }
    func unmarkText() { native.unmarkText(); onProxyWrite?() }
}

@MainActor final class KeyboardInteractionTests: XCTestCase {
    func testRawEnterShiftAndLanguageRoutingInHostAndBuffer() throws {
        for buffered in [false, true] {
            let (window, controller) = host(); defer { window.isHidden = true }
            controller.developmentChoose(.chord); controller.developmentSetLayout(.splitOrthogonal)
            if buffered { controller.developmentBuffer("") }
            func text() -> String { buffered ? controller.developmentBufferSource.text : controller.layoutProxy.native.text }
            controller.developmentChord("ni'hao'")
            XCTAssertFalse(controller.developmentRaw.isEmpty)
            controller.developmentEnter()
            XCTAssertEqual(text(), "nihao"); XCTAssertTrue(controller.developmentRaw.isEmpty)
            XCTAssertNil(controller.layoutProxy.native.markedTextRange)
            controller.developmentEnter(); XCTAssertEqual(text(), "nihao\n")
            controller.developmentType("ni")
            controller.developmentShift()
            XCTAssertEqual(text(), "nihao\nni")
            XCTAssertFalse(controller.layoutViews.keys.resolvesChords)
            controller.developmentType("ab"); XCTAssertEqual(text(), "nihao\nniAB")
            controller.developmentShift(); XCTAssertTrue(controller.layoutViews.keys.resolvesChords)
            controller.developmentType("hao"); controller.developmentLanguage()
            XCTAssertEqual(text(), "nihao\nniABhao")
            XCTAssertEqual(controller.layoutViews.keys.chordLayout, .splitOrthogonal)
            XCTAssertFalse(controller.layoutViews.keys.resolvesChords)
            controller.developmentType("test"); XCTAssertTrue(text().hasSuffix("haotest"))
            controller.developmentLanguage(); XCTAssertTrue(controller.layoutViews.keys.resolvesChords)
            controller.developmentType("nihk"); controller.developmentSpace()
            XCTAssertTrue(text().hasSuffix("你好"))
            controller.developmentShift(); controller.developmentChoose(.wubi86)
            XCTAssertFalse(controller.layoutViews.keys.shifted)
            controller.developmentType("wq"); controller.developmentEnter()
            XCTAssertTrue(text().hasSuffix("你好wq"))
        }
    }
    func testDefaultChordSerialGHReachesGangInHostAndBuffer() {
        for buffered in [false, true] {
            let (window, controller) = host(); defer { window.isHidden = true }
            controller.developmentChoose(.chord)
            if buffered { controller.developmentBuffer("") }
            controller.developmentType("g"); controller.developmentType("h")
            XCTAssertEqual(controller.developmentRaw, "gh")
            let preedit = buffered ? controller.layoutViews.source.text : controller.layoutProxy.native.text
            XCTAssertEqual(preedit, buffered ? "gang▏" : "gang")
            controller.developmentEnter()
            XCTAssertEqual(buffered ? controller.developmentBufferSource.text : controller.layoutProxy.native.text, "gh")
            XCTAssertTrue(controller.developmentRaw.isEmpty)
        }
    }
    func testProxyWriteCallbacksPreserveCompositionAndAutomaticDelivery() {
        let (window, controller) = host(); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
        controller.layoutProxy.onProxyWrite = { [weak controller] in
            controller?.selectionWillChange(nil); controller?.textWillChange(nil); controller?.textDidChange(nil)
        }
        controller.developmentChoose(.pinyin)
        controller.developmentType("ni")
        XCTAssertEqual(controller.developmentRaw, "ni")
        XCTAssertEqual(controller.layoutProxy.native.text, "ni")
        controller.developmentEnter()
        XCTAssertEqual(controller.layoutProxy.native.text, "ni")
        XCTAssertTrue(controller.developmentRaw.isEmpty)
        var time: TimeInterval = 0; controller.defaultClockNow = { time }
        controller.developmentBuffer("A。B。"); controller.developmentAutoDelay(1)
        controller.developmentAutoTick(); time = 1; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "niA。")
        // A host may also deliver selection notifications asynchronously.
        controller.selectionWillChange(nil)
        time = 1.1; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "niA。B。")
    }
    func testDefaultBufferAutoDeliveryIsBoundToVisibleTargetAndOriginalMode() {
        let (window, controller) = host(); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
        var time: TimeInterval = 0; controller.defaultClockNow = { time }
        controller.developmentChoose(.english); controller.developmentBuffer("")
        controller.developmentAutoDelay(1)
        controller.layoutViews.keys.onTypingPress?()
        controller.developmentType("A。B。")
        XCTAssertEqual(controller.developmentTypingMetrics.committedCharacterCount, 4)
        XCTAssertEqual(controller.developmentTypingMetrics.keyCount, 1)
        controller.developmentAutoTick()
        time = 1; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。")
        XCTAssertEqual(controller.developmentBufferSource.text, "B。")
        time = 1.1; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。B。")
        controller.developmentType("held")
        controller.developmentAutoTick()
        controller.layoutProxy.documentIdentifier = UUID(); controller.textDidChange(nil)
        time = 5; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。B。")
        controller.developmentAutoDelay(1)
        controller.developmentBuffer("source", plugin: true, output: "translation")
        controller.developmentAutoTick(); time = 10; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。B。")
        controller.developmentBuffer("hide"); controller.developmentAutoDelay(1)
        controller.developmentAutoTick(); controller.viewWillDisappear(false)
        time = 20; controller.developmentAutoTick()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。B。")
    }
    func testDeleteRepeatsAcrossCompositionThenBufferAndStopsOnTargetChange() {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin); controller.developmentBuffer("AB😀")
        controller.developmentType("ni")
        let button = controller.developmentDelete
        var time: TimeInterval = 10; button.clock = { time }
        let feedback = controller.layoutViews.keys.feedback
        feedback.enabled = true; feedback.reset(); feedback.clock = { time }
        var pulses = 0; feedback.onFeedback = { _ in pulses += 1 }
        button.sendActions(for: .touchDown)
        XCTAssertEqual(controller.developmentRaw, "n"); XCTAssertEqual(pulses, 1)
        time = 10.399; button.advance(); XCTAssertEqual(controller.developmentRaw, "n")
        time = 10.4; button.advance(); XCTAssertTrue(controller.developmentRaw.isEmpty)
        time = 10.475; button.advance(); XCTAssertEqual(controller.developmentBufferSource.text, "AB"); XCTAssertEqual(pulses, 3)
        button.sendActions(for: .touchUpInside); time = 20; button.advance(); XCTAssertEqual(pulses, 3)
        XCTAssertEqual(controller.developmentBufferSource.text, "AB")
        button.sendActions(for: .touchDown); XCTAssertEqual(controller.developmentBufferSource.text, "A")
        controller.layoutProxy.documentIdentifier = UUID(); controller.textDidChange(nil)
        time = 21; button.advance(); XCTAssertEqual(controller.developmentBufferSource.text, "A")
        controller.developmentBuffer(nil); controller.developmentChoose(.english)
        controller.layoutProxy.native.text = "abcd"; controller.layoutProxy.native.selectedRange = NSRange(location: 4, length: 0)
        button.sendActions(for: .touchDown); XCTAssertEqual(controller.layoutProxy.native.text, "abc")
        time += 0.4; button.advance(); XCTAssertEqual(controller.layoutProxy.native.text, "ab")
        button.sendActions(for: .touchDragExit); time += 1; button.advance()
        XCTAssertEqual(controller.layoutProxy.native.text, "ab")
        button.sendActions(for: .touchDown); controller.viewWillDisappear(false); time += 1; button.advance()
        XCTAssertEqual(controller.layoutProxy.native.text, "a")
        controller.viewWillAppear(false); controller.developmentBuffer("protected")
        controller.layoutProxy.identityAvailable = false; controller.textDidChange(nil)
        button.sendActions(for: .touchDown); time += 1; button.advance()
        XCTAssertEqual(controller.developmentBufferSource.text, "protected")
    }
    func testRepeatClockCancelsAndDoesNotCatchUpOrFireOnRelease() {
        var press = RepeatingPress(); press.begin(at: 0)
        XCTAssertFalse(press.advance(to: 0.399)); XCTAssertTrue(press.advance(to: 0.4))
        XCTAssertFalse(press.advance(to: 0.474)); XCTAssertTrue(press.advance(to: 5))
        XCTAssertFalse(press.advance(to: 5)); press.cancel(); XCTAssertFalse(press.advance(to: 10))
    }
    func testRepeatButtonCancellationAndVisiblePressedState() {
        let button = RepeatKeycapButton()
        var time: TimeInterval = 0, count = 0
        button.clock = { time }; button.onPressBegan = { true }
        button.onDelete = { count += 1; return true }
        for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
            button.sendActions(for: .touchDown)
            XCTAssertTrue(button.isHighlighted)
            let first = count
            time += 0.4; button.advance(); XCTAssertEqual(count, first + 1)
            time += 0.074; button.advance(); XCTAssertEqual(count, first + 1)
            time += 0.002; button.advance(); XCTAssertEqual(count, first + 2)
            button.sendActions(for: event); XCTAssertFalse(button.isHighlighted)
            time += 1; button.advance(); XCTAssertEqual(count, first + 2)
        }
        button.sendActions(for: .touchDown); let first = count
        button.isEnabled = false; time += 1; button.advance(); XCTAssertEqual(count, first)
        button.isEnabled = true; button.sendActions(for: .touchDown)
        button.didMoveToWindow(); time += 1; button.advance(); XCTAssertEqual(count, first + 1)
    }
    func testCustomProfileLayoutUsesItsHandOrderAndActualHitAndAccessibilityFrames() throws {
        var profile = ChordProfile.builtIn.copy()
        // A custom profile can put keys across the familiar screen midpoint.
        swap(&profile.leftKeys, &profile.rightKeys)
        let surface = KeySurface(); surface.profile = profile; surface.chordMode = true
        for layout in ChordLayout.allCases {
            surface.chordLayout = layout
            surface.frame = CGRect(x: 0, y: 0, width: 310, height: KeyboardGeometry.height(layout: layout, chord: true, numeric: false, emoji: false, landscape: false))
            surface.layoutIfNeeded()
            let elements = try XCTUnwrap(surface.accessibilityElements)
            for key in profile.leftKeys + profile.rightKeys {
                let frame = try XCTUnwrap(surface.developmentKeyFrames[String(key)])
                XCTAssertEqual(surface.developmentKey(at: CGPoint(x: frame.midX, y: frame.midY)), String(key))
                let element = try XCTUnwrap(elements.compactMap { $0 as? UIAccessibilityElement }.first { $0.accessibilityLabel == String(key).uppercased() })
                XCTAssertEqual(element.accessibilityFrameInContainerSpace, frame)
            }
            XCTAssertEqual(profile.hand(for: "q"), .right); XCTAssertEqual(profile.hand(for: "y"), .left)

        }
    }
    func testAllChordGeometryKeepsSquareKeysAndHandIdentity() throws {
        let profile = ChordProfile.builtIn
        for layout in ChordLayout.allCases {
            for width: CGFloat in [310, 383, 842] {
                let height = KeyboardGeometry.height(layout: layout, chord: true, numeric: false, emoji: false, landscape: width > 600, width: width)
                let geometry = KeyboardGeometry.make(size: CGSize(width: width, height: height), profile: profile, chord: true, numeric: false, layout: layout)
                let keys = Dictionary(uniqueKeysWithValues: geometry.keys)
                XCTAssertEqual(Set(keys.keys), Set((profile.leftKeys + profile.rightKeys).map(String.init)))
                let reference = try XCTUnwrap(keys["q"])
                XCTAssertEqual(reference.width, reference.height, accuracy: 0.001)
                let frames = geometry.keys.map(\.1) + [geometry.emoji, geometry.language].compactMap { $0 }
                for (i, rect) in frames.enumerated() {
                    XCTAssertEqual(rect.size, reference.size)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: width, height: height).contains(rect))
                    for other in frames.dropFirst(i + 1) { XCTAssertFalse(rect.intersects(other)) }
                }
                XCTAssertEqual(keys["w"]!.minX - keys["q"]!.maxX, 2, accuracy: 0.001)
                XCTAssertEqual(keys["y"]!.minX - keys["t"]!.maxX, layout == .splitOrthogonal ? 14 : 2, accuracy: 0.001)
            }
        }
    }
    func testLayoutSwitchRetiresChordAndPreservesCompositionAndScreenshots() async throws {
        for (width, style) in [(CGFloat(320), UIUserInterfaceStyle.light), (393, .dark), (852, .light)] {
            let (window, controller) = host(width: width); defer { window.isHidden = true }
            controller.overrideUserInterfaceStyle = style; window.overrideUserInterfaceStyle = style
            controller.layoutProxy.keyboardAppearance = style == .dark ? .dark : .light
            // Finish initial UIKit appearance before establishing the test session.
            try await Task.sleep(nanoseconds: 80_000_000)
            controller.developmentChoose(.chord); controller.developmentType("ni")
            for layout in ChordLayout.allCases {
                do {
                    let keys = controller.layoutViews.keys
                    keys.developmentPress("a", end: "s")
                    controller.developmentSetLayout(layout)
                    XCTAssertFalse(keys.isChordActive); XCTAssertEqual(controller.developmentRaw, "ni")
                    controller.developmentBuffer("这是 Buffer 原文，用于检查正交键盘和候选的位置。")
                    XCTAssertEqual(controller.developmentRaw, "ni", "after enabling Buffer")
                    window.layoutIfNeeded(); controller.view.layoutIfNeeded(); keys.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 40_000_000)
                    XCTAssertEqual(controller.developmentRaw, "ni", "after awaiting layout")
                    let before = keys.convert(keys.bounds, to: window)
                    controller.developmentContent(preedit: "ni", candidates: ["你", "拟", "这个长候选不应缩小字体"])
                    window.layoutIfNeeded(); controller.view.layoutIfNeeded()
                    XCTAssertEqual(keys.convert(keys.bounds, to: window), before)
                    XCTAssertEqual(controller.layoutViews.settings.bounds.width, 32)
                    XCTAssertGreaterThanOrEqual(controller.layoutViews.insert.bounds.width, 24)
                    // drawHierarchy temporarily detaches UIInputViewController's view,
                    // legitimately ending its session. Render layers to keep this session alive.
                    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { controller.view.layer.render(in: $0.cgContext) }
                    XCTAssertEqual(controller.developmentRaw, "ni", "after snapshot")
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
                    let name = "build\(build)-\(layout.rawValue)-\(Int(width))-\(style == .dark ? "dark" : "light")"
                    let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name + ".png")
                    try image.pngData()?.write(to: url)
                }
            }
        }
    }

    func testInlineHostCompositionCommitsAndBackspacesWithoutDuplicates() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin)
        let proxy = controller.layoutProxy
        proxy.native.text = "前😀后"; proxy.native.selectedRange = NSRange(location: 3, length: 0)
        controller.developmentType("nihao")
        let range = try XCTUnwrap(proxy.native.markedTextRange)
        XCTAssertEqual(proxy.native.text(in: range)?.replacingOccurrences(of: " ", with: ""), "nihao")
        XCTAssertTrue(proxy.native.text.hasPrefix("前😀")); XCTAssertTrue(proxy.native.text.hasSuffix("后"))
        let index = try XCTUnwrap(controller.layoutViews.candidates.buttons.firstIndex { $0.currentTitle == "你好" })
        controller.layoutViews.candidates.onSelect?(index)
        XCTAssertEqual(proxy.native.text, "前😀你好后"); XCTAssertNil(proxy.native.markedTextRange)
        controller.developmentType("ni")
        let delete = try XCTUnwrap(controller.layoutViews.bottom.arrangedSubviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == L("删除", "Delete") })
        delete.sendActions(for: .touchDown); delete.sendActions(for: .touchUpInside); delete.sendActions(for: .touchDown); delete.sendActions(for: .touchUpInside)
        XCTAssertEqual(proxy.native.text, "前😀你好后"); XCTAssertNil(proxy.native.markedTextRange)
        controller.developmentType("hao"); controller.viewWillDisappear(false)
        XCTAssertEqual(proxy.native.text, "前😀你好后"); XCTAssertNil(proxy.native.markedTextRange)
    }
    func testInlineCompositionNeverEditsDifferentTargetOrMovedSelection() {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin)
        let proxy = controller.layoutProxy
        controller.developmentType("ni")
        let count = proxy.markedUpdates.count
        proxy.native.text = "新输入框"; proxy.documentIdentifier = UUID()
        controller.textDidChange(nil)
        XCTAssertEqual(proxy.native.text, "新输入框"); XCTAssertEqual(proxy.markedUpdates.count, count)
        controller.developmentType("ni")
        let beforeAppearance = proxy.markedUpdates.count
        proxy.native.text = "再次切换"; proxy.documentIdentifier = UUID()
        controller.viewWillAppear(false)
        XCTAssertEqual(proxy.native.text, "再次切换"); XCTAssertEqual(proxy.markedUpdates.count, beforeAppearance)
        controller.developmentType("hao")
        proxy.native.unmarkText(); proxy.native.selectedRange = NSRange(location: 0, length: 0)
        let text = proxy.native.text, updates = proxy.markedUpdates.count
        controller.selectionWillChange(nil)
        XCTAssertEqual(proxy.native.text, text); XCTAssertEqual(proxy.markedUpdates.count, updates)
        XCTAssertTrue(controller.layoutViews.candidates.buttons.isEmpty)
        controller.viewWillDisappear(false)
        XCTAssertEqual(proxy.native.text, text); XCTAssertEqual(proxy.markedUpdates.count, updates)
    }
    func testBufferCompositionStaysOutOfSourceUntilCandidateConfirmation() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin); controller.developmentBuffer("前😀后")
        controller.developmentBufferCursor(2)
        let before = controller.developmentBufferSource
        controller.developmentType("nihao")
        XCTAssertEqual(controller.developmentBufferSource.text, before.text)
        XCTAssertEqual(controller.developmentBufferSource.revision, before.revision)
        XCTAssertTrue(controller.layoutProxy.markedUpdates.isEmpty)
        XCTAssertTrue(controller.layoutProxy.insertions.isEmpty)
        XCTAssertEqual(controller.layoutViews.source.text.replacingOccurrences(of: " ", with: ""), "前😀nihao▏后")
        XCTAssertFalse(controller.layoutViews.insert.isEnabled)
        let index = try XCTUnwrap(controller.layoutViews.candidates.buttons.firstIndex { $0.currentTitle == "你好" })
        controller.layoutViews.candidates.onSelect?(index)
        XCTAssertEqual(controller.developmentBufferSource.text, "前😀你好后")
        XCTAssertEqual(controller.layoutViews.source.text, "前😀你好▏后")
        XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
        XCTAssertTrue(controller.layoutViews.insert.isEnabled)
    }
    func testOldFieldProxyIsUnmarkedWithoutChangingEitherFieldsContent() {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin); controller.developmentType("ni")
        let old = controller.layoutProxy
        XCTAssertNotNil(old.native.markedTextRange)
        let next = LayoutTestDocumentProxy(); next.native.text = "新输入框"
        controller.layoutProxy = next; controller.textWillChange(nil); controller.textDidChange(nil)
        XCTAssertNil(old.native.markedTextRange); XCTAssertEqual(old.native.text, "ni")
        XCTAssertEqual(next.native.text, "新输入框"); XCTAssertTrue(next.markedUpdates.isEmpty)
    }
    func testRefocusedMarkedFieldRecoversDuringNilDocumentReset() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.pinyin)
        let proxy = controller.layoutProxy
        proxy.native.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        proxy.identityAvailable = false
        controller.textDidChange(nil)
        XCTAssertNil(proxy.native.markedTextRange); XCTAssertEqual(proxy.native.text, "ni")
        proxy.identityAvailable = true; proxy.documentIdentifier = UUID()
        controller.textDidChange(nil); controller.developmentType("hao")
        XCTAssertEqual(proxy.native.text, "nihao")
        let range = try XCTUnwrap(proxy.native.markedTextRange)
        XCTAssertEqual(proxy.native.text(in: range), "hao")
        controller.layoutViews.candidates.onSelect?(0)
        XCTAssertEqual(proxy.native.text, "ni好"); XCTAssertNil(proxy.native.markedTextRange)
        proxy.native.selectedRange = NSRange(location: 1, length: 1); proxy.identityAvailable = false
        controller.textDidChange(nil)
        XCTAssertEqual(proxy.native.text, "ni好"); XCTAssertEqual(proxy.native.selectedRange, NSRange(location: 1, length: 1))
    }
    func testBufferCompositionUsesUTF16RangesForEmojiAndInlineUnderline() {
        let prefix = "前👩🏽‍💻"
        let display = BufferComposition(source: prefix + "后", cursor: 2, preedit: "ni hao", font: .systemFont(ofSize: 15))
        XCTAssertEqual(display.text.string, prefix + "ni hao▏后")
        XCTAssertEqual(display.markedRange, NSRange(location: prefix.utf16.count, length: 6))
        XCTAssertEqual(display.caretRange.location, prefix.utf16.count + 6)
        XCTAssertEqual(display.text.attribute(.underlineStyle, at: display.markedRange.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(display.text.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let empty = BufferComposition(source: "", cursor: 50, preedit: "", font: .systemFont(ofSize: 15))
        XCTAssertEqual(empty.text.string, "▏"); XCTAssertEqual(empty.markedRange.length, 0)
    }
    func testChordCapsShareDimensionsIncludingRightHandUtilities() throws {
        var custom = ChordProfile.builtIn.copy()
        custom.leftKeys = "qwertyuiopasdfg"; custom.rightKeys = "hjklzxcvbnm,."
        custom.mappings = [.init(keys: "ah", output: "ni", kind: .syllable)]
        custom = try custom.validated()
        for profile in [ChordProfile.builtIn, custom] {
            for (width, height): (CGFloat, CGFloat) in [(310, 150), (365, 150), (383, 150), (842, 108)] {
                let keys = KeySurface(frame: .init(x: 0, y: 0, width: width, height: height))
                keys.profile = profile; keys.chordMode = true; keys.layoutIfNeeded()
                let frames = keys.developmentKeyFrames, reference = try XCTUnwrap(frames["q"])
                XCTAssertEqual(frames.count, 30)
                for (name, frame) in frames {
                    XCTAssertEqual(frame.width, reference.width, accuracy: 0.001, name)
                    XCTAssertEqual(frame.height, reference.height, accuracy: 0.001, name)
                    XCTAssertTrue(keys.bounds.contains(frame), name)
                }
                for utility in ["emoji", "mode"] {
                    let frame = try XCTUnwrap(frames[utility])
                    XCTAssertNil(keys.developmentKey(at: CGPoint(x: frame.midX, y: frame.midY)))
                }
                if profile.id == ChordProfile.builtIn.id {
                    XCTAssertEqual(frames["emoji"]!.minX, frames["p"]!.minX, accuracy: 0.001)
                    XCTAssertEqual(frames["mode"]!.minX, frames["p"]!.minX, accuracy: 0.001)
                    let ordinaryGap = frames["w"]!.minX - frames["q"]!.maxX
                    XCTAssertEqual(frames["y"]!.minX - frames["t"]!.maxX, ordinaryGap, accuracy: 0.001)
                    XCTAssertEqual(frames["h"]!.minX - frames["g"]!.maxX, ordinaryGap, accuracy: 0.001)
                }
            }
        }
    }
    func testChordUtilitiesIgnoreHeldChordsAndCancelledPresses() throws {
        let keys = KeySurface(frame: .init(x: 0, y: 0, width: 310, height: 150))
        keys.chordMode = true; keys.layoutIfNeeded()
        func control(_ id: String) throws -> UIControl {
            try XCTUnwrap(keys.subviews.first { $0.accessibilityIdentifier == id } as? UIControl)
        }
        func tap(_ button: UIControl) { button.sendActions(for: .touchDown); button.sendActions(for: .touchUpInside) }
        let emoji = try control("keyboard.emoji"), script = try control("keyboard.mode")
        var toggles = 0, inserted = [String]()
        keys.onLanguageToggle = { toggles += 1 }; keys.onEmoji = { inserted.append($0) }
        keys.developmentPress("a", end: "s")
        tap(script); tap(emoji)
        XCTAssertEqual(toggles, 0); XCTAssertFalse(keys.emojiMode)
        XCTAssertFalse(script.accessibilityActivate()); XCTAssertEqual(emoji.alpha, 0.3, accuracy: 0.001)
        keys.retire(); keys.layoutIfNeeded()
        script.sendActions(for: .touchDown); keys.retire(); script.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggles, 0)
        script.sendActions(for: .touchDown); script.sendActions(for: .touchCancel); script.sendActions(for: .touchUpInside)
        XCTAssertEqual(toggles, 0)
        XCTAssertTrue(script.accessibilityActivate()); XCTAssertEqual(toggles, 1)
        let before = keys.developmentKeyFrames
        tap(emoji); keys.layoutIfNeeded(); XCTAssertTrue(keys.emojiMode)
        let preset = try control("keyboard.emoji.preset.0")
        tap(preset); XCTAssertEqual(inserted, ["😀"])
        for case let button as UIButton in keys.subviews where !button.isHidden {
            button.layoutIfNeeded()
            if let text = button.titleLabel?.text, let font = button.titleLabel?.font {
                XCTAssertGreaterThanOrEqual(button.titleLabel!.bounds.width, ceil((text as NSString).size(withAttributes: [.font: font]).width))
            }
        }
        XCTAssertTrue(try control("keyboard.emoji.back").accessibilityActivate())
        keys.layoutIfNeeded(); XCTAssertFalse(keys.emojiMode); XCTAssertEqual(keys.developmentKeyFrames, before)
        XCTAssertEqual(emoji.alpha, 1)
    }
    func testEmojiUsesBufferAndExplicitDelivery() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer("")
        let keys = controller.layoutViews.keys
        keys.chordMode = true; window.layoutIfNeeded(); keys.layoutIfNeeded()
        let emoji = try XCTUnwrap(keys.subviews.first { $0.accessibilityIdentifier == "keyboard.emoji" })
        XCTAssertTrue(emoji.accessibilityActivate()); keys.layoutIfNeeded()
        let preset = try XCTUnwrap(keys.subviews.first { $0.accessibilityIdentifier == "keyboard.emoji.preset.0" })
        XCTAssertTrue(preset.accessibilityActivate())
        XCTAssertTrue(controller.layoutProxy.insertions.isEmpty)
        XCTAssertTrue(controller.layoutViews.insert.accessibilityActivate())
        XCTAssertEqual(controller.layoutProxy.insertions, ["😀"])
        controller.developmentBuffer(nil); window.layoutIfNeeded()
        XCTAssertTrue(preset.accessibilityActivate())
        XCTAssertEqual(controller.layoutProxy.insertions, ["😀", "😀"])
    }
    private func host(width: CGFloat = 393) -> (UIWindow, KeyboardViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 874))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let controller = KeyboardViewController(); controller.layoutNeedsInputModeSwitchKey = false
        parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor), controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)])
        controller.developmentResetPreferences()
        controller.developmentContent(); controller.developmentBuffer(nil); window.layoutIfNeeded()
        return (window, controller)
    }
    func testReservedCandidateRowAndBufferRowOrder() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.chord); window.layoutIfNeeded()
        let v = controller.layoutViews
        func frame(_ view: UIView) -> CGRect { view.convert(view.bounds, to: window) }
        let keyFrame = frame(v.keys), candidateFrame = frame(v.candidates), idleHeight = controller.view.bounds.height
        XCTAssertFalse(v.candidates.isHidden); XCTAssertGreaterThanOrEqual(candidateFrame.height, 32)
        XCTAssertTrue(v.buffer.isHidden)
        XCTAssertEqual(frame(v.settings).minY, candidateFrame.minY)
        XCTAssertEqual(frame(v.settings).maxX, frame(controller.view).maxX - 5)
        XCTAssertLessThan(candidateFrame.maxX, frame(v.settings).minX)
        XCTAssertEqual(candidateFrame.minY, frame(controller.view).minY + 5, accuracy: 0.5)
        let schemes = try XCTUnwrap(v.settings.menu?.children.first as? UIMenu)
        XCTAssertEqual(schemes.children.count, InputScheme.allCases.count)
        XCTAssertEqual((schemes.children.compactMap { $0 as? UIAction }.first { $0.state == .on })?.title, InputScheme.chord.title)
        let toggle = try XCTUnwrap(v.candidates.superview?.subviews.first { $0.accessibilityIdentifier == "keyboard.buffer" })
        XCTAssertLessThan(frame(toggle).maxX, candidateFrame.minX)
        controller.developmentContent(preedit: "ni", candidates: ["你", "拟"]); window.layoutIfNeeded()
        XCTAssertEqual(controller.view.bounds.height, idleHeight)
        XCTAssertEqual(frame(v.keys), keyFrame); XCTAssertEqual(frame(v.candidates), candidateFrame)
        controller.developmentContent(); controller.developmentBuffer(""); window.layoutIfNeeded()
        XCTAssertFalse(v.buffer.isHidden); XCTAssertTrue(v.result.isHidden)
        XCTAssertLessThan(frame(v.result).maxY, frame(v.source).minY)
        XCTAssertLessThan(frame(v.source).maxY, frame(v.candidates).minY)
        XCTAssertLessThan(frame(v.candidates).maxY, frame(v.keys).minY)
        XCTAssertEqual(frame(v.keys), keyFrame)
        let plugin = try XCTUnwrap(v.buffer.subviews.first { $0.accessibilityIdentifier == "keyboard.plugin" })
        XCTAssertLessThan(frame(plugin).maxX, frame(v.source).minX)
        XCTAssertEqual(frame(plugin).minY, frame(v.source).minY)
        XCTAssertGreaterThan(frame(v.insert).minX, frame(v.result).maxX)
        XCTAssertEqual(frame(v.insert).minY, frame(v.result).minY)
        XCTAssertEqual(v.bottom.spacing, 2)
        controller.developmentBuffer("原文。", plugin: false); window.layoutIfNeeded()
        XCTAssertEqual(v.result.text, "")
        XCTAssertTrue(v.source.isHidden)
        let blocks = try XCTUnwrap(v.buffer.subviews.compactMap { $0 as? BufferBlockStrip }.first)
        let stats = try XCTUnwrap(v.buffer.subviews.first { $0.accessibilityIdentifier == "keyboard.buffer.metrics" } as? UILabel)
        XCTAssertFalse(blocks.isHidden); XCTAssertFalse(stats.isHidden)
        XCTAssertEqual(stats.textAlignment, .center); XCTAssertGreaterThanOrEqual(stats.font.pointSize, 16)
        XCTAssertEqual(blocks.frame, v.source.frame)
        XCTAssertEqual(stats.frame.height, v.result.frame.height)
        XCTAssertEqual(stats.frame.midX, v.buffer.bounds.midX)
        controller.developmentBuffer("第一句。第二句！未完成", plugin: false); window.layoutIfNeeded()
        XCTAssertEqual(blocks.blockTexts, ["第一句。", "第二句！", "未完成"])
        XCTAssertEqual(v.buffer.bounds.height, 76)
        controller.developmentBuffer("原文。", plugin: true, output: "Text."); window.layoutIfNeeded()
        XCTAssertEqual(v.result.text, "Text."); XCTAssertFalse(v.result.isHidden); XCTAssertFalse(v.source.isHidden); XCTAssertTrue(blocks.isHidden); XCTAssertTrue(stats.isHidden)
        controller.developmentBuffer(nil); window.layoutIfNeeded()
        XCTAssertTrue(v.buffer.isHidden); XCTAssertEqual(frame(v.keys), keyFrame)
        XCTAssertEqual(controller.view.bounds.height, idleHeight)
    }
    func testSystemGlobeOnlyWhenRequiredAndSpaceReceivesFreedWidth() {
        let (window, controller) = host(); defer { window.isHidden = true }
        let views = controller.layoutViews
        let space = views.bottom.arrangedSubviews.first { $0.accessibilityIdentifier == "keyboard.space" }!
        let without = space.bounds.width
        XCTAssertTrue(views.globe.isHidden)
        controller.layoutNeedsInputModeSwitchKey = true; controller.developmentContent(); window.layoutIfNeeded()
        XCTAssertFalse(views.globe.isHidden); XCTAssertLessThan(space.bounds.width, without)
        let otherWidths = views.bottom.arrangedSubviews.filter { $0 !== space }.map { $0.bounds.width }
        XCTAssertTrue(otherWidths.allSatisfy { abs($0 - otherWidths[0]) <= 0.5 }, "Pixel-aligned widths: \(otherWidths)")
        controller.layoutNeedsInputModeSwitchKey = false; controller.developmentContent(); window.layoutIfNeeded()
        XCTAssertTrue(views.globe.isHidden); XCTAssertEqual(space.bounds.width, without, accuracy: 0.01)
    }
    func testCandidateWidthsUseTextAndExpandedRowsWrap() {
        let texts = ["你", "你好", "你好世界", String(repeating: "长候选", count: 12), "好"]
        for width: CGFloat in [274, 347, 806] {
            for landscape in [false, true] {
                let collapsed = CandidateLayout.measure(texts, width: width, expanded: false, landscape: landscape)
                let expanded = CandidateLayout.measure(texts, width: width, expanded: true, landscape: landscape)
                XCTAssertGreaterThan(collapsed.frames[2].width, collapsed.frames[1].width)
                XCTAssertGreaterThan(collapsed.frames[1].width, collapsed.frames[0].width)
                XCTAssertEqual(Set(collapsed.frames.map(\.minY)).count, 1)
                XCTAssertTrue(expanded.frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width })
                XCTAssertGreaterThan(expanded.contentSize.height, expanded.frames[0].height)
                XCTAssertLessThanOrEqual(expanded.height, 110)
                let font = UIFont.systemFont(ofSize: landscape ? 18 : 20)
                let glyphWidth = (texts[1] as NSString).size(withAttributes: [.font: font]).width
                XCTAssertEqual(collapsed.frames[1].width, ceil(glyphWidth) + 12)
            }
        }
        XCTAssertEqual(CandidateLayout.measure([], width: 300, expanded: true, landscape: false).height, 0)
    }
    func testCandidateGlyphsFitActualLabelsAndPressDoesNotDrift() {
        let strip = CandidateStrip(); strip.update(["你", "你好", "你好世界"])
        strip.frame = CGRect(x: 0, y: 0, width: 393, height: 32); strip.layoutIfNeeded()
        for button in strip.buttons {
            button.layoutIfNeeded()
            let label = button.titleLabel!
            let width = (label.text! as NSString).size(withAttributes: [.font: label.font!]).width
            XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(width))
            XCTAssertGreaterThanOrEqual(label.bounds.height, ceil(label.font.lineHeight))
            let normal = label.frame
            button.isHighlighted = true; button.layoutIfNeeded()
            XCTAssertEqual(label.frame, normal)
            button.setNeedsLayout(); button.layoutIfNeeded()
            XCTAssertEqual(label.frame, normal)
            button.isHighlighted = false; button.layoutIfNeeded(); XCTAssertEqual(label.frame, normal)
            XCTAssertEqual(button.backgroundColor, .clear)
            XCTAssertEqual(button.layer.borderWidth, 0); XCTAssertEqual(button.layer.shadowOpacity, 0)
        }
    }
    func testInsertionTapHoldThresholdCancellationAndNoDuplicateRelease() {
        var press = InsertionPress()
        press.begin(at: 0); XCTAssertNil(press.advance(to: 0.999))
        XCTAssertEqual(press.end(at: 0.999, inside: true), .next)
        press.begin(at: 2); XCTAssertEqual(press.advance(to: 3), .all)
        XCTAssertNil(press.advance(to: 4)); XCTAssertNil(press.end(at: 4, inside: true))
        // A delayed run-loop timer cannot convert a held press back into a tap.
        press.begin(at: 5); XCTAssertEqual(press.end(at: 6, inside: true), .all)
        press.begin(at: 7); press.cancel(); XCTAssertNil(press.advance(to: 8)); XCTAssertNil(press.end(at: 8, inside: true))
        press.begin(at: 9); XCTAssertNil(press.end(at: 9.5, inside: false)); XCTAssertNil(press.advance(to: 10))
        press.begin(at: 11); XCTAssertEqual(press.end(at: 11.1, inside: true), .next)
    }
    func testMissingObjectiveCDocumentIdentityIsSafeAndHasNoFallbackTarget() {
        let stub = NullableDocumentIdentity()
        XCTAssertNil(DocumentIdentity.readObject(stub))
        let id = UUID(); stub.documentIdentifier = id as NSUUID
        XCTAssertEqual(DocumentIdentity.readObject(stub), id)
        stub.documentIdentifier = nil
        XCTAssertNil(DocumentIdentity.readObject(stub))
        XCTAssertNil(DocumentIdentity.readObject(NSObject()))
    }
    func testBufferInsertionRoutesBlocksAndRejectsStalePress() {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer("第一块。第二块。第三块。"); window.layoutIfNeeded()
        let button = controller.layoutViews.insert
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(controller.layoutProxy.insertions, ["第一块。"])
        button.onPressBegan?(); button.onInsert?(.all)
        XCTAssertEqual(controller.layoutProxy.insertions, ["第一块。", "第二块。第三块。"])
        XCTAssertFalse(button.isEnabled)
        controller.developmentBuffer("源文。", plugin: true, output: "First!Second!")
        XCTAssertTrue(button.accessibilityActivate())
        XCTAssertEqual(controller.layoutProxy.insertions.last, "First!")
        button.onPressBegan?()
        controller.developmentBuffer("已修改原文。", plugin: true) // Old result must never be sent.
        button.onInsert?(.all)
        XCTAssertEqual(controller.layoutProxy.insertions.count, 3)
        XCTAssertFalse(button.isEnabled)
        controller.developmentBuffer("正在处理。", plugin: true, generating: true)
        XCTAssertFalse(button.isEnabled); XCTAssertFalse(controller.layoutViews.stop.isHidden)
        controller.developmentBuffer("新的原文。")
        button.onPressBegan?(); controller.layoutProxy.documentIdentifier = UUID()
        button.onInsert?(.all)
        XCTAssertEqual(controller.layoutProxy.insertions.count, 3)
    }
}

@MainActor private final class NullableDocumentIdentity: NSObject {
    @objc var documentIdentifier: NSUUID?
}
