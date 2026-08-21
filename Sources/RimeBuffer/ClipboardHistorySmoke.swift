import Cocoa

/// Standalone, deterministic Clipboard model/view contract check. It uses an
/// in-memory pasteboard double and never touches the user's NSPasteboard.
@MainActor
enum ClipboardHistorySmoke {
    static func run() -> Bool {
        var ok = true

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard !condition() else { return }
            // Failure labels describe contracts and deliberately never include
            // clipboard payloads.
            FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
            ok = false
        }

        // The global visibility shortcut never resumes Buffer capture. Its
        // pure plan only enables/disables the rail and, when necessary, asks
        // the existing nonactivating shell to become visible on this Space.
        expect(
            ClipboardRailVisibilityToggleRules.plan(
                railEnabled: false,
                workbenchVisibleOnActiveSpace: false
            ) == ClipboardRailVisibilityTogglePlan(
                railEnabled: true,
                showWorkbench: true
            ),
            "hidden disabled rail did not plan enable-and-show"
        )
        expect(
            ClipboardRailVisibilityToggleRules.plan(
                railEnabled: true,
                workbenchVisibleOnActiveSpace: false
            ) == ClipboardRailVisibilityTogglePlan(
                railEnabled: true,
                showWorkbench: true
            ),
            "enabled rail on another Space was disabled instead of shown"
        )
        expect(
            ClipboardRailVisibilityToggleRules.plan(
                railEnabled: false,
                workbenchVisibleOnActiveSpace: true
            ) == ClipboardRailVisibilityTogglePlan(
                railEnabled: true,
                showWorkbench: false
            ),
            "visible disabled rail did not plan enable in place"
        )
        expect(
            ClipboardRailVisibilityToggleRules.plan(
                railEnabled: true,
                workbenchVisibleOnActiveSpace: true
            ) == ClipboardRailVisibilityTogglePlan(
                railEnabled: false,
                showWorkbench: false
            ),
            "visible enabled rail did not plan hide in place"
        )

        let pasteboard = ClipboardHistoryPasteboardDouble()
        let configuration = ClipboardHistoryConfiguration(
            maximumItems: 3,
            maximumItemBytes: 32,
            maximumTotalBytes: 64,
            pollingInterval: 1
        )
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var dynamicProtection: ClipboardHistoryProtection = []
        let model = ClipboardHistoryModel(
            configuration: configuration,
            pasteboard: pasteboard,
            protectionProbe: { dynamicProtection },
            clock: {
                defer { now.addTimeInterval(1) }
                return now
            },
            schedulesAutomaticPolling: false
        )

        // Starting while hidden and every disabled poll are pasteboard-silent.
        pasteboard.stubChangeCount = 7
        model.start()
        expect(pasteboard.changeCountReadCount == 0, "hidden start read change count")
        expect(!model.pollNow(), "hidden poll reported capture")
        expect(pasteboard.changeCountReadCount == 0, "hidden poll read change count")
        expect(pasteboard.plainTextReadCount == 0, "hidden poll read text")

        model.update(workbenchVisible: true, railEnabled: false, protection: [])
        _ = model.pollNow()
        expect(pasteboard.changeCountReadCount == 0, "disabled rail read change count")

        // Enabling establishes a change-count-only baseline. Text is read only
        // after a later observed change.
        model.update(workbenchVisible: true, railEnabled: true, protection: [])
        expect(pasteboard.changeCountReadCount == 1, "eligible start missed baseline")
        expect(pasteboard.plainTextReadCount == 0, "baseline read text")
        pasteboard.stubChangeCount = 8
        pasteboard.stubPlainText = "first"
        expect(model.pollNow(), "changed pasteboard was not captured")
        expect(pasteboard.plainTextReadCount == 1, "changed pasteboard text read count")
        expect(model.items.count == 1, "first item count")
        expect(model.storedByteCount == 5, "first item byte accounting")

        // Exact duplicates are promoted in place rather than copied.
        let firstID = model.items.first?.id
        pasteboard.stubChangeCount = 9
        pasteboard.stubPlainText = "first"
        expect(model.pollNow(), "duplicate was not accepted for promotion")
        expect(model.items.count == 1, "duplicate created a second item")
        expect(model.items.first?.id == firstID, "duplicate changed item identity")

        expect(!model.ingest(""), "empty item accepted")
        expect(!model.ingest(" \n\t "), "whitespace-only item accepted")
        expect(!model.ingest("bad\0value"), "NUL item accepted")
        expect(!model.ingest(String(repeating: "x", count: 33)), "oversized item accepted")

        // Selection is clamped, deletion selects the nearest survivor, and the
        // newest entries remain inside both configured bounds.
        expect(model.ingest("second"), "second item rejected")
        expect(model.ingest("third"), "third item rejected")
        expect(model.moveSelection(delta: 1), "right selection failed")
        let selectedBeforeDelete = model.selectedID
        expect(model.deleteSelected(), "selected delete failed")
        expect(!model.items.contains(where: { $0.id == selectedBeforeDelete }),
               "selected delete retained item")
        expect(model.selectedID != nil, "delete did not choose neighbor")

        let boundedPasteboard = ClipboardHistoryPasteboardDouble()
        let boundedModel = ClipboardHistoryModel(
            configuration: .init(
                maximumItems: 10,
                maximumItemBytes: 8,
                maximumTotalBytes: 10,
                pollingInterval: 1
            ),
            pasteboard: boundedPasteboard,
            schedulesAutomaticPolling: false
        )
        expect(boundedModel.ingest("aaaa"), "bounded item one rejected")
        expect(boundedModel.ingest("bbbb"), "bounded item two rejected")
        expect(boundedModel.ingest("cccc"), "bounded item three rejected")
        expect(boundedModel.items.count == 2, "total-byte eviction count")
        expect(boundedModel.storedByteCount == 8, "total-byte eviction accounting")
        expect(!boundedModel.ingest("123456789"), "per-item byte cap failed")
        expect(!boundedModel.ingest("中文中"), "UTF-8 byte cap failed")

        let countBoundedModel = ClipboardHistoryModel(
            configuration: .init(
                maximumItems: 2,
                maximumItemBytes: 32,
                maximumTotalBytes: 96,
                pollingInterval: 1
            ),
            pasteboard: ClipboardHistoryPasteboardDouble(),
            schedulesAutomaticPolling: false
        )
        _ = countBoundedModel.ingest("one")
        _ = countBoundedModel.ingest("two")
        _ = countBoundedModel.ingest("three")
        expect(countBoundedModel.items.count == 2, "item-count eviction failed")

        // Explicit protection shields the UI and avoids even changeCount. A
        // resume observes only a fresh baseline, so protected content cannot be
        // backfilled.
        model.update(
            workbenchVisible: true,
            railEnabled: true,
            protection: [.secureInput]
        )
        let protectedCountReads = pasteboard.changeCountReadCount
        let protectedTextReads = pasteboard.plainTextReadCount
        pasteboard.stubChangeCount = 10
        pasteboard.stubPlainText = "protected"
        expect(!model.pollNow(), "protected poll reported capture")
        expect(pasteboard.changeCountReadCount == protectedCountReads,
               "protected poll read change count")
        expect(pasteboard.plainTextReadCount == protectedTextReads,
               "protected poll read text")
        expect(model.items.isEmpty, "protected primary item projection leaked")
        expect(model.visibleItems.isEmpty, "protected items remained visible")
        expect(model.itemCount > 0, "protected history was not retained in memory")
        expect(model.selectedItem == nil, "protected selection remained visible")

        model.update(workbenchVisible: true, railEnabled: true, protection: [])
        expect(pasteboard.changeCountReadCount == protectedCountReads + 1,
               "resume did not establish baseline")
        expect(pasteboard.plainTextReadCount == protectedTextReads,
               "resume backfilled protected text")
        expect(!model.pollNow(), "unchanged resume baseline captured text")
        pasteboard.stubChangeCount = 11
        pasteboard.stubPlainText = "after"
        expect(model.pollNow(), "post-resume change was not captured")

        // A live Secure Input probe follows the same no-read/resume-baseline
        // rule even when the workbench's explicit session state is unchanged.
        dynamicProtection = [.secureInput]
        let dynamicCountReads = pasteboard.changeCountReadCount
        let dynamicTextReads = pasteboard.plainTextReadCount
        pasteboard.stubChangeCount = 12
        pasteboard.stubPlainText = "dynamic-protected"
        expect(!model.pollNow(), "dynamic protection reported capture")
        expect(pasteboard.changeCountReadCount == dynamicCountReads,
               "dynamic protection read change count")
        expect(pasteboard.plainTextReadCount == dynamicTextReads,
               "dynamic protection read text")
        dynamicProtection = []
        expect(!model.pollNow(), "dynamic protection resume backfilled content")
        expect(pasteboard.changeCountReadCount == dynamicCountReads + 1,
               "dynamic protection resume missed baseline")
        expect(pasteboard.plainTextReadCount == dynamicTextReads,
               "dynamic protection resume read text")

        model.stop()
        let stoppedCountReads = pasteboard.changeCountReadCount
        let stoppedTextReads = pasteboard.plainTextReadCount
        pasteboard.stubChangeCount = 13
        _ = model.pollNow()
        expect(pasteboard.changeCountReadCount == stoppedCountReads,
               "stopped model read change count")
        expect(pasteboard.plainTextReadCount == stoppedTextReads,
               "stopped model read text")

        // A second model has no access to the first model's history: there is
        // intentionally no disk or UserDefaults restoration path.
        let freshModel = ClipboardHistoryModel(
            configuration: configuration,
            pasteboard: ClipboardHistoryPasteboardDouble(),
            schedulesAutomaticPolling: false
        )
        expect(freshModel.items.isEmpty, "fresh model restored persisted history")

        let timerPasteboard = ClipboardHistoryPasteboardDouble()
        let timerModel = ClipboardHistoryModel(
            configuration: .init(
                maximumItems: 3,
                maximumItemBytes: 32,
                maximumTotalBytes: 64,
                pollingInterval: 60
            ),
            pasteboard: timerPasteboard,
            schedulesAutomaticPolling: true
        )
        timerModel.start()
        expect(!timerModel.hasScheduledPolling, "hidden model scheduled polling")
        timerModel.update(workbenchVisible: true, railEnabled: true, protection: [])
        expect(timerModel.hasScheduledPolling, "eligible model did not schedule polling")
        timerModel.update(
            workbenchVisible: true,
            railEnabled: true,
            protection: [.sessionInactive]
        )
        expect(!timerModel.hasScheduledPolling, "protected model kept polling timer")
        timerModel.update(workbenchVisible: true, railEnabled: true, protection: [])
        expect(timerModel.hasScheduledPolling, "resumed model did not restart polling")
        timerModel.stop()
        expect(!timerModel.hasScheduledPolling, "stopped model kept polling timer")

        runViewChecks(expect: expect)
        return ok
    }

    private static func runViewChecks(
        expect: (_ condition: @autoclosure () -> Bool, _ message: String) -> Void
    ) {
        let pasteboard = ClipboardHistoryPasteboardDouble()
        let model = ClipboardHistoryModel(
            configuration: .init(
                maximumItems: 8,
                maximumItemBytes: 2_048,
                maximumTotalBytes: 8_192,
                pollingInterval: 1
            ),
            pasteboard: pasteboard,
            schedulesAutomaticPolling: false
        )
        model.update(workbenchVisible: true, railEnabled: true, protection: [])
        model.start()
        _ = model.ingest("short")
        _ = model.ingest(String(repeating: "long", count: 120))

        let rail = ClipboardRailView(model: model)
        rail.frame = NSRect(x: 0, y: 0, width: 260, height: ClipboardRailMetrics.railHeight)
        rail.layoutSubtreeIfNeeded()

        let passive = rail.snapshotForSmoke()
        expect(passive.railHeight == 40, "rail height drifted")
        expect(passive.cardCount == 2, "rail card count")
        expect(passive.cardHeight == 20, "card height drifted")
        expect(passive.widestCardWidth <= 220, "card width exceeded design cap")
        expect(passive.selectedCardBorderWidth == 1, "passive selected border")
        expect(!passive.stateIsVisible, "nonempty rail showed state")

        rail.setActive(true)
        let active = rail.snapshotForSmoke()
        expect(active.isActive, "rail did not enter active state")
        expect(active.selectedCardBorderWidth == 2, "active selected border")

        let selectionBeforeModifiedKey = model.selectedID
        if let commandRight = keyEvent(keyCode: 124, modifiers: [.command]) {
            expect(!rail.handleKeyEvent(commandRight), "modified arrow was consumed")
            expect(model.selectedID == selectionBeforeModifiedKey,
                   "modified arrow changed selection")
        } else {
            expect(false, "modified-arrow event creation")
        }

        var acceptedItemID: UUID?
        rail.onAddToBuffer = { item in
            acceptedItemID = item.id
            return true
        }
        guard let rightArrow = keyEvent(keyCode: 124) else {
            expect(false, "right-arrow event creation")
            return
        }
        expect(rail.handleKeyEvent(rightArrow), "view right-arrow routing failed")
        let activatedID = model.selectedID
        guard let returnKey = keyEvent(keyCode: 36) else {
            expect(false, "Return event creation")
            return
        }
        expect(rail.handleKeyEvent(returnKey), "Buffer callback activation failed")
        expect(acceptedItemID == activatedID, "Buffer callback received wrong item")
        expect(model.items.first?.id == activatedID, "activation did not promote item")

        let orderBeforeRejectedActivation = model.items.map(\.id)
        rail.onAddToBuffer = { _ in false }
        expect(!rail.activateSelectedItem(), "rejected Buffer callback reported success")
        expect(model.items.map(\.id) == orderBeforeRejectedActivation,
               "rejected Buffer callback changed history order")

        model.update(
            workbenchVisible: true,
            railEnabled: true,
            protection: [.screenLocked, .sessionInactive]
        )
        let protectedSnapshot = rail.snapshotForSmoke()
        expect(protectedSnapshot.isProtected, "protected rail state missing")
        expect(protectedSnapshot.cardCount == 0, "protected rail retained text cards")
        expect(protectedSnapshot.stateIsVisible, "protected rail missing state message")
        expect(!rail.activateSelectedItem(), "protected rail activated item")

        model.update(workbenchVisible: true, railEnabled: false, protection: [])
        let disabledSnapshot = rail.snapshotForSmoke()
        expect(disabledSnapshot.cardCount == 0, "disabled rail retained text cards")
        expect(disabledSnapshot.stateIsVisible, "disabled rail missing state")

        let emptyModel = ClipboardHistoryModel(
            configuration: .init(),
            pasteboard: ClipboardHistoryPasteboardDouble(),
            schedulesAutomaticPolling: false
        )
        emptyModel.update(workbenchVisible: true, railEnabled: true, protection: [])
        emptyModel.start()
        let emptyRail = ClipboardRailView(model: emptyModel)
        emptyRail.setActive(true)
        if let emptyReturn = keyEvent(keyCode: 36) {
            expect(emptyRail.handleKeyEvent(emptyReturn),
                   "owned empty-rail Return leaked to input target")
        } else {
            expect(false, "empty Return event creation")
        }
    }

    private static func keyEvent(keyCode: UInt16,
                                 modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

private final class ClipboardHistoryPasteboardDouble: ClipboardHistoryPasteboardReading {
    var stubChangeCount = 0
    var stubPlainText: String?
    private(set) var changeCountReadCount = 0
    private(set) var plainTextReadCount = 0

    var changeCount: Int {
        changeCountReadCount += 1
        return stubChangeCount
    }

    func readPlainText() -> String? {
        plainTextReadCount += 1
        return stubPlainText
    }
}

#if CLIPBOARD_HISTORY_STANDALONE_SMOKE
@main
private enum ClipboardHistorySmokeMain {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        if ClipboardHistorySmoke.run() {
            print("clipboard history smoke: OK")
        } else {
            exit(1)
        }
    }
}
#endif
