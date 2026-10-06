import XCTest
import UIKit
import RimesCore
@testable import RIMES

@MainActor final class BufferImportTests: XCTestCase {
    func testPromptPreviewsHostTextWithoutImportingAndOnlyFlashesWhenOffered() throws {
        for width: CGFloat in [320, 393, 852] {
            let (window, controller) = host(width: width); defer { window.isHidden = true }
            let text = String(repeating: "输入框已有的长文字，", count: 12)
            setHost(text, controller: controller)
            controller.developmentBuffer(""); window.layoutIfNeeded()
            let prompt = try prompt(controller), paste = try paste(controller)
            XCTAssertFalse(prompt.isHidden); XCTAssertTrue(paste.isEnabled)
            XCTAssertTrue(prompt.accessibilityLabel?.contains(text) == true)
            XCTAssertEqual(controller.developmentBufferSource.text, "")
            XCTAssertEqual(controller.layoutProxy.native.text, text)
            let label = try XCTUnwrap(prompt.subviews.compactMap { $0 as? UILabel }.first)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
            XCTAssertGreaterThan(label.intrinsicContentSize.width, label.bounds.width)
            XCTAssertLessThanOrEqual(prompt.frame.maxX, paste.frame.minX + 1)
            XCTAssertLessThanOrEqual(paste.frame.maxX, controller.layoutViews.source.frame.maxX)
            // An icon and the host text shown as hint text; no caption, no fill.
            XCTAssertEqual(prompt.subviews.compactMap { $0 as? UILabel }.count, 1)
            XCTAssertEqual(label.textColor, .placeholderText)
            XCTAssertEqual(label.font, controller.layoutViews.source.font)
            XCTAssertEqual(prompt.isBreathing, !UIAccessibility.isReduceMotionEnabled)
            // The paste control's opaque background stays inside the input line's outline.
            let line = controller.layoutViews.source.frame.insetBy(dx: BufferPasteButton.lineInset, dy: BufferPasteButton.lineInset)
            XCTAssertTrue(line.insetBy(dx: -0.5, dy: -0.5).contains(paste.convert(paste.controlFrame, to: paste.superview)))
            let height = controller.view.bounds.height
            controller.developmentChoose(.english); controller.developmentType("x"); window.layoutIfNeeded()
            XCTAssertTrue(prompt.isHidden); XCTAssertFalse(paste.isHidden)
            XCTAssertFalse(prompt.isBreathing)
            XCTAssertEqual(controller.layoutProxy.native.text, text)
            XCTAssertEqual(controller.view.bounds.height, height)
        }
    }

    func testImportMovesFullTextFromBeginningMiddleAndEndIncludingEmojiAndNewlines() async throws {
        let text = "前👨‍👩‍👧‍👦e\u{301}\n后。"
        for cursor in [0, 1, text.utf16.count] {
            let (window, controller) = host(); defer { window.isHidden = true }
            setHost(text, cursor: cursor, controller: controller)
            controller.developmentBuffer("")
            try prompt(controller).sendActions(for: .touchUpInside)
            await controller.developmentWaitForBufferImport()
            XCTAssertEqual(controller.developmentBufferSource.text, text)
            XCTAssertEqual(controller.layoutProxy.native.text, "")
            XCTAssertEqual(controller.layoutProxy.native.selectedRange, NSRange(location: 0, length: 0))
            XCTAssertTrue(try prompt(controller).isHidden)
            XCTAssertTrue(controller.developmentTypingSession.isEmpty, "Imports are not typing metrics")
        }
    }

    func testStalePreviewCannotDeleteOrImportAnEditedOrDifferentField() async throws {
        for changesIdentity in [false, true] {
            let (window, controller) = host(); defer { window.isHidden = true }
            setHost("原文", controller: controller); controller.developmentBuffer("")
            setHost("新的输入框文字", controller: controller)
            if changesIdentity { controller.layoutProxy.documentIdentifier = UUID() }
            try prompt(controller).sendActions(for: .touchUpInside)
            await controller.developmentWaitForBufferImport()
            XCTAssertEqual(controller.layoutProxy.native.text, "新的输入框文字")
            XCTAssertEqual(controller.developmentBufferSource.text, "")
        }
    }

    func testTruncatedContextCopiesOnlyWhatWasPreviewedAndRestoresCaretWithoutDeletion() async throws {
        for cursor in [0, 5, 10] {
            let (window, controller) = host(); defer { window.isHidden = true }
            let text = "一二三四五六七八九十"
            setHost(text, cursor: cursor, controller: controller); controller.layoutProxy.contextLimit = 3
            let expected = (controller.layoutProxy.documentContextBeforeInput ?? "") + (controller.layoutProxy.documentContextAfterInput ?? "")
            controller.developmentBuffer("")
            try prompt(controller).sendActions(for: .touchUpInside)
            await controller.developmentWaitForBufferImport()
            XCTAssertEqual(controller.developmentBufferSource.text, expected)
            XCTAssertEqual(controller.layoutProxy.native.text, text)
            XCTAssertEqual(controller.layoutProxy.native.selectedRange.location, cursor)
            XCTAssertTrue(controller.developmentStatus.contains(L("原文保留", "original stays")))
        }
    }

    func testPossiblyTruncatedSelectionIsNeverDeleted() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        setHost("前一二三四五后", controller: controller)
        controller.layoutProxy.native.selectedRange = NSRange(location: 1, length: 5)
        controller.layoutProxy.contextLimit = 2
        controller.developmentBuffer("")
        try prompt(controller).sendActions(for: .touchUpInside)
        await controller.developmentWaitForBufferImport()
        XCTAssertEqual(controller.developmentBufferSource.text, "一二")
        XCTAssertEqual(controller.layoutProxy.native.text, "前一二三四五后")
        XCTAssertEqual(controller.layoutProxy.native.selectedRange, NSRange(location: 1, length: 5))
    }

    func testDelayedAndIgnoredHostDeletionNeverLosesTheSavedSource() async throws {
        for ignored in [false, true] {
            let (window, controller) = host(); defer { window.isHidden = true }
            setHost("甲乙😀", controller: controller)
            controller.layoutProxy.ignoresDeletion = ignored
            controller.layoutProxy.deletionDelay = 0.03
            controller.developmentBuffer("")
            try prompt(controller).sendActions(for: .touchUpInside)
            await controller.developmentWaitForBufferImport()
            XCTAssertEqual(controller.developmentBufferSource.text, "甲乙😀")
            XCTAssertEqual(controller.layoutProxy.native.text, ignored ? "甲乙😀" : "")
        }
    }

    func testFieldChangeDuringDeletionStopsBeforeTouchingTheNewField() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        setHost("甲乙丙", controller: controller); controller.developmentBuffer("")
        controller.layoutProxy.onProxyWrite = {
            controller.textDidChange(nil); controller.selectionDidChange(nil)
            guard controller.layoutProxy.native.text.count < 3 else { return }
            controller.layoutProxy.onProxyWrite = nil
            controller.layoutProxy.documentIdentifier = UUID()
            self.setHost("新目标", controller: controller); controller.textDidChange(nil)
        }
        try prompt(controller).sendActions(for: .touchUpInside)
        await controller.developmentWaitForBufferImport()
        XCTAssertEqual(controller.layoutProxy.native.text, "新目标")
        XCTAssertEqual(controller.developmentBufferSource.text, "甲乙丙")
    }

    func testClipboardIsReadOnlyOnTapAndPreservesWhitespaceLongTextAndExistingBuffer() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        setHost("宿主原文", controller: controller)
        controller.developmentClipboardAccess = true
        var reads = 0
        let text = " \n" + String(repeating: "字", count: 5000) + "\n "
        controller.developmentReadClipboard = { reads += 1; return text }
        controller.developmentBuffer("甲乙"); controller.developmentBufferCursor(1); window.layoutIfNeeded()
        XCTAssertEqual(reads, 0)
        try paste(controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(controller.developmentBufferSource.text, "甲" + text + "乙")
        XCTAssertEqual(controller.layoutProxy.native.text, "宿主原文")
        XCTAssertTrue(controller.developmentTypingSession.isEmpty)
        window.layoutIfNeeded()
        let source = controller.layoutViews.source
        XCTAssertGreaterThan(source.contentSize.width, source.bounds.width)
        XCTAssertEqual(source.trailingAccessoryWidth, 44)
    }

    func testClipboardDenialDoesNotReadOrModifyText() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer("保留"); controller.developmentClipboardAccess = false
        var read = false; controller.developmentReadClipboard = { read = true; return "剪贴板" }
        try paste(controller).sendActions(for: .touchUpInside)
        XCTAssertFalse(read); XCTAssertEqual(controller.developmentBufferSource.text, "保留")
        XCTAssertTrue(controller.developmentStatus.contains(L("完全访问", "Full Access")))
        controller.developmentClipboardAccess = true; controller.developmentReadClipboard = { nil }
        try paste(controller).sendActions(for: .touchUpInside)
        XCTAssertEqual(controller.developmentBufferSource.text, "保留")
    }

    func testSystemPasteProviderInsertsVerbatimAtTheBufferCursor() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentClipboardAccess = true
        controller.developmentBuffer("前后"); controller.developmentBufferCursor(1)
        let button = try paste(controller)
        let items = [NSItemProvider(object: " 中间\n " as NSString)]
        XCTAssertTrue(button.canPaste(items))
        button.paste(itemProviders: items)
        for _ in 0..<100 where controller.developmentBufferSource.text == "前后" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.developmentBufferSource.text, "前 中间\n 后")
        XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
    }

    func testLateSystemPasteProviderCannotFollowToAnotherField() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentClipboardAccess = true; controller.developmentBuffer("保留")
        try paste(controller).paste(itemProviders: [NSItemProvider(object: "迟到" as NSString)])
        controller.layoutProxy.documentIdentifier = UUID(); controller.textDidChange(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.developmentBufferSource.text, "保留")
        XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
    }

    func testPasteAlertRestoresExistingDraftAndCursorOnlyForTheSameField() throws {
        for changesField in [false, true] {
            let (window, controller) = host(); defer { window.isHidden = true }
            controller.developmentClipboardAccess = true
            controller.developmentBuffer("前后"); controller.developmentBufferCursor(1)
            controller.developmentReadClipboard = {
                controller.developmentHostResigned()
                if changesField { controller.layoutProxy.documentIdentifier = UUID() }
                return " 中间 "
            }
            try paste(controller).sendActions(for: .touchUpInside)
            controller.developmentResume()
            XCTAssertEqual(controller.developmentBufferSource.text, changesField ? "" : "前 中间 后")
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
        }
    }

    func testImportPromptRefreshesWhenHostTextOrSelectionChanges() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer(""); XCTAssertTrue(try prompt(controller).isHidden)
        setHost("新文字", controller: controller); controller.textDidChange(nil)
        XCTAssertFalse(try prompt(controller).isHidden)
        setHost("", controller: controller); controller.textDidChange(nil)
        XCTAssertTrue(try prompt(controller).isHidden)
    }

    func testOptimisticStaleProxyCannotAuthorizeDeletingRealHostText() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        setHost("Buffer import 46", controller: controller)
        let cached = UITextView(); cached.text = "Buffe"; cached.selectedRange = NSRange(location: 5, length: 0)
        controller.layoutProxy.optimisticContext = cached
        controller.layoutProxy.cursorDelay = 0.04
        controller.developmentBuffer("")
        try prompt(controller).sendActions(for: .touchUpInside)
        await controller.developmentWaitForBufferImport()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.layoutProxy.native.text, "Buffer import 46")
        XCTAssertEqual(controller.developmentBufferSource.text, "")
    }

    func testUnacknowledgedCursorPredictionCannotAuthorizeDeletion() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        setHost("需要确认", controller: controller)
        controller.layoutProxy.acknowledgesCursor = false
        controller.developmentBuffer("")
        try prompt(controller).sendActions(for: .touchUpInside)
        await controller.developmentWaitForBufferImport()
        XCTAssertEqual(controller.layoutProxy.native.text, "需要确认")
        XCTAssertEqual(controller.developmentBufferSource.text, "")
    }

    func testPromptSnapshotsForNativeReview() throws {
        for (name, width, style) in [("portrait", CGFloat(393), UIUserInterfaceStyle.light), ("narrow-dark", 320, .dark), ("landscape", 852, .light)] {
            let (window, controller) = host(width: width); defer { window.isHidden = true }
            window.overrideUserInterfaceStyle = style
            controller.developmentClipboardAccess = true
            controller.developmentChoose(.chord)
            setHost("这是输入框里已经写好的文字，点这里移入 Buffer 继续编辑。", controller: controller)
            controller.developmentBuffer(""); window.layoutIfNeeded()
            try prompt(controller).layer.removeAllAnimations()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { controller.view.layer.render(in: $0.cgContext) }
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try image.pngData()?.write(to: folder.appendingPathComponent("buffer-import-\(name).png"))
        }
    }

    private func setHost(_ text: String, cursor: Int? = nil, controller: KeyboardViewController) {
        controller.layoutProxy.native.text = text
        controller.layoutProxy.native.selectedRange = NSRange(location: cursor ?? text.utf16.count, length: 0)
    }
    private func prompt(_ controller: KeyboardViewController) throws -> BufferImportPrompt {
        try XCTUnwrap(controller.layoutViews.buffer.subviews.first { $0.accessibilityIdentifier == "keyboard.buffer.importHost" } as? BufferImportPrompt)
    }
    private func paste(_ controller: KeyboardViewController) throws -> BufferPasteButton {
        try XCTUnwrap(controller.layoutViews.buffer.subviews.first { $0.accessibilityIdentifier == "keyboard.buffer.paste" } as? BufferPasteButton)
    }
    private func host(width: CGFloat = 393) -> (UIWindow, KeyboardViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let controller = KeyboardViewController(); controller.layoutNeedsInputModeSwitchKey = false
        controller.loadViewIfNeeded(); controller.developmentResetPreferences()
        parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor), controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)])
        controller.viewWillAppear(false); controller.developmentChoose(.english); controller.developmentBuffer(nil)
        controller.layoutProxy.onProxyWrite = { [weak controller] in controller?.textDidChange(nil); controller?.selectionDidChange(nil) }
        window.layoutIfNeeded()
        return (window, controller)
    }
}
