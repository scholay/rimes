import XCTest
import UIKit
import RimesCore
@testable import RIMES

@MainActor final class TextClipboardInteractionTests: XCTestCase {
    private var root: URL!
    override func setUp() { super.setUp(); root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testOpeningDoesNotReadAndLocalEntryAddsAtCursorWithoutHostInsertion() throws {
        for width: CGFloat in [320, 393, 852] {
            let store = TextClipboardStore(root: root); try store.clear()
            let entry = try XCTUnwrap(store.collect(" 中😀。\n ").first)
            let (window, controller) = host(width: width); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
            controller.developmentClipboardAccess = false
            controller.developmentReadClipboard = { XCTFail("Opening history must not read clipboard"); return "" }
            controller.developmentBuffer("前后"); controller.developmentBufferCursor(1)
            var time: TimeInterval = 0; controller.defaultClockNow = { time }
            controller.developmentAutoDelay(1)
            window.layoutIfNeeded()
            let height = controller.view.bounds.height
            controller.developmentOpenClipboard(); window.layoutIfNeeded()
            XCTAssertNotNil(controller.developmentClipboardPanel)
            XCTAssertEqual(controller.view.bounds.height, height)
            XCTAssertEqual(controller.developmentBufferSource.text, "前后")
            controller.developmentSelectClipboard(entry.id)
            XCTAssertEqual(controller.developmentBufferSource.text, "前 中😀。\n 后")
            controller.developmentAutoTick(); time = 5; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
            XCTAssertNil(controller.developmentClipboardPanel)
            controller.developmentOpenClipboard(); controller.developmentClosePanel()
            controller.developmentAutoTick(); time = 10; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "Browsing again must preserve the import's explicit pause")
            controller.developmentType("later edit"); controller.developmentAutoTick()
            time = 20; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "An explicit history import must stay paused")
        }
    }

    func testBrowsingAndCollectingThenClosingAllowsOnlyLaterEditsToRestartAutomaticInsertion() throws {
        for scenario in 0..<4 {
            let (window, controller) = host(); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
            var time: TimeInterval = 0; controller.defaultClockNow = { time }
            controller.developmentClipboardAccess = true
            controller.developmentBuffer(scenario == 2 ? nil : "A。B。")
            controller.developmentAutoDelay(1); controller.developmentAutoTick()
            time = 0.75; controller.developmentAutoTick()
            controller.developmentOpenClipboard()
            if scenario == 1 {
                controller.developmentReadClipboard = { "explicitly saved" }
                controller.developmentCollectClipboard()
            }
            time = 10; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
            XCTAssertEqual(controller.developmentBufferSource.text, scenario == 2 ? "" : "A。B。")
            controller.developmentClosePanel(); controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "Do not restore the old elapsed deadline")
            time = 20; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "Closing must not automatically insert existing text")
            if scenario == 3 { controller.developmentBackspace() }
            else { controller.developmentType(scenario == 2 ? "A。" : "C") }
            controller.developmentAutoTick()
            time = 20.99; controller.developmentAutoTick(); XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
            time = 21; controller.developmentAutoTick()
            XCTAssertEqual(controller.layoutProxy.native.text, "A。", "Browsing must preserve automatic insertion for later edits")
            time = 21.1; controller.developmentAutoTick()
            XCTAssertEqual(controller.layoutProxy.native.text, scenario >= 2 ? "A。" : "A。B。")
        }
    }

    func testClosingChangedClipboardContextsCannotResumeAnOldAutomaticDelivery() throws {
        for change in 0..<5 {
            let (window, controller) = host(); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
            var time: TimeInterval = 0; controller.defaultClockNow = { time }
            controller.developmentClipboardAccess = true; controller.developmentBuffer("A。B。")
            controller.developmentAutoDelay(1); controller.developmentAutoTick(); controller.developmentOpenClipboard()
            switch change {
            case 0: controller.layoutProxy.documentIdentifier = UUID(); controller.textDidChange(nil)
            case 1: controller.developmentType("edit")
            case 2: controller.developmentPlugin(.ask, source: "A。B。"); controller.developmentPlugin(nil, source: "A。B。")
            case 3:
                controller.developmentClipboardAccess = false; controller.developmentBufferCursor(0)
                controller.developmentClipboardAccess = true
            default:
                controller.viewWillDisappear(false); controller.developmentResume(); controller.developmentBuffer("new session")
            }
            controller.developmentClosePanel(); controller.developmentAutoTick()
            time = 10; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "Changed context must not resume: \(change)")
            controller.developmentType("later edit"); controller.developmentAutoTick()
            time = 20; controller.developmentAutoTick()
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty, "A changed context must preserve its explicit pause: \(change)")
        }
    }

    func testManualInsertionAfterBrowsingDoesNotAutomaticallySendTheUneditedRemainder() async throws {
        let (window, controller) = host(); defer { window.isHidden = true; controller.developmentAutoDelay(0) }
        var time: TimeInterval = 0; controller.defaultClockNow = { time }
        controller.developmentBuffer("A。B。"); controller.developmentAutoDelay(1)
        controller.developmentOpenClipboard(); controller.developmentClosePanel()
        XCTAssertTrue(controller.layoutViews.insert.accessibilityActivate())
        await controller.developmentWaitForDelivery()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。")
        XCTAssertEqual(controller.developmentBufferSource.text, "B。")
        let revision = controller.developmentBufferSource.revision
        controller.developmentBufferCursor(0); controller.developmentBackspace(); controller.developmentBufferCursor(2)
        XCTAssertEqual(controller.developmentBufferSource.revision, revision, "Cursor movement and empty deletion are not edits")
        controller.developmentAutoTick(); time = 10; controller.developmentAutoTick()
        await controller.developmentWaitForDelivery()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。", "Manual consumption is not an ordinary source edit")
        XCTAssertEqual(controller.developmentBufferSource.text, "B。")
        controller.developmentType("C"); controller.developmentAutoTick()
        time = 10.99; controller.developmentAutoTick(); XCTAssertEqual(controller.layoutProxy.native.text, "A。")
        time = 11; controller.developmentAutoTick(); await controller.developmentWaitForDelivery()
        XCTAssertEqual(controller.layoutProxy.native.text, "A。B。")
    }

    func testExplicitSystemCollectionSavesVerbatimWithoutChangingBuffer() async throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentClipboardAccess = true; controller.developmentBuffer("保留")
        controller.developmentOpenClipboard()
        let control = try XCTUnwrap(controller.developmentClipboardPanel?.collect)
        control.paste(itemProviders: [NSItemProvider(object: " \n中😀\n " as NSString)])
        try await waitForCollection()
        XCTAssertEqual(TextClipboardStore(root: root).load().map(\.text), [" \n中😀\n "])
        XCTAssertEqual(controller.developmentBufferSource.text, "保留")
        XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
    }

    func testDeniedAccessNeverReadsAndOversizedTextDoesNotSave() throws {
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer("保留"); controller.developmentOpenClipboard()
        controller.developmentClipboardAccess = false
        controller.developmentReadClipboard = { XCTFail("Denied access must not read"); return "" }
        controller.developmentCollectClipboard(); XCTAssertTrue(TextClipboardStore(root: root).load().isEmpty)
        controller.developmentClipboardAccess = true
        controller.developmentReadClipboard = { String(repeating: "字", count: 6000) }
        controller.developmentCollectClipboard(); XCTAssertTrue(TextClipboardStore(root: root).load().isEmpty)
        XCTAssertEqual(controller.developmentBufferSource.text, "保留")
    }

    func testLateCollectionCannotFollowChangedFieldHideEditPluginOrPermission() async throws {
        for change in 0..<5 {
            try TextClipboardStore(root: root).clear()
            let (window, controller) = host(); defer { window.isHidden = true }
            controller.developmentClipboardAccess = true; controller.developmentBuffer("保留"); controller.developmentOpenClipboard()
            try XCTUnwrap(controller.developmentClipboardPanel?.collect).paste(itemProviders: [NSItemProvider(object: "迟到" as NSString)])
            switch change {
            case 0: controller.layoutProxy.documentIdentifier = UUID(); controller.textDidChange(nil)
            case 1: controller.viewWillDisappear(false)
            case 2: controller.developmentType("编辑")
            case 3: controller.developmentPlugin(.ask, source: "保留")
            default: controller.developmentClipboardAccess = false
            }
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertTrue(TextClipboardStore(root: root).load().isEmpty, "Changed context: \(change)")
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
        }
    }

    func testPastePermissionAlertCollectsOnlyForTheOriginalFieldAndKeepsTheDraft() throws {
        for changedField in [false, true] {
            try TextClipboardStore(root: root).clear()
            let (window, controller) = host(); defer { window.isHidden = true }
            controller.developmentClipboardAccess = true; controller.developmentBuffer("前后"); controller.developmentBufferCursor(1)
            controller.developmentOpenClipboard()
            controller.developmentReadClipboard = {
                controller.developmentHostResigned()
                if changedField { controller.layoutProxy.documentIdentifier = UUID() }
                return " 明确收录 "
            }
            controller.developmentCollectClipboard(); controller.developmentResume()
            XCTAssertEqual(TextClipboardStore(root: root).load().map(\.text), changedField ? [] : [" 明确收录 "])
            XCTAssertEqual(controller.developmentBufferSource.text, changedField ? "" : "前后")
            XCTAssertTrue(controller.layoutProxy.native.text.isEmpty)
        }
    }

    func testHistoryClearDoesNotChangeBufferAndStorePersistsAcrossKeyboardInstances() throws {
        let store = TextClipboardStore(root: root); _ = try store.collect("history")
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentBuffer("保留"); controller.developmentOpenClipboard(); window.layoutIfNeeded()
        let clear = try XCTUnwrap(controller.developmentClipboardPanel?.subviews.first { $0.accessibilityIdentifier == "keyboard.clipboard.clear" } as? UIButton)
        clear.sendActions(for: .touchUpInside)
        XCTAssertTrue(store.load().isEmpty); XCTAssertEqual(controller.developmentBufferSource.text, "保留")
    }

    private func waitForCollection() async throws {
        for _ in 0..<100 where TextClipboardStore(root: root).load().isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    private func host(width: CGFloat = 393) -> (UIWindow, KeyboardViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let controller = KeyboardViewController(); controller.layoutNeedsInputModeSwitchKey = false
        controller.loadViewIfNeeded(); controller.developmentResetPreferences(); controller.developmentClipboardHistory(root: root)
        parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
        NSLayoutConstraint.activate([controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor), controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor), controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)])
        controller.viewWillAppear(false); controller.developmentChoose(.english); controller.developmentBuffer(nil)
        controller.layoutProxy.onProxyWrite = { [weak controller] in controller?.textDidChange(nil); controller?.selectionDidChange(nil) }
        window.layoutIfNeeded(); return (window, controller)
    }
}
