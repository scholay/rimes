import AppKit
import Foundation

func runCapsuleWindowSmokeTest() -> Bool {
    print("== RIMES Capsule window smoke ==")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "rimes-capsule-window-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var instant = Date(timeIntervalSince1970: 1_788_055_000)
    let contentStore = CapsuleContentStore(rootURL: root, now: { instant })
    let passwordStore = CapsulePasswordStore(rootURL: root, now: { instant })
    let repository = CapsuleWindowRepository(
        contentStore: contentStore,
        passwordStore: passwordStore
    )

    do {
        let passcodeSuite =
            "RimeBuffer.CapsuleRevealPasscodeSmoke.\(UUID().uuidString)"
        guard let passcodeDefaults = UserDefaults(suiteName: passcodeSuite)
        else {
            return capsuleWindowSmokeFail("passcode defaults fixture")
        }
        defer {
            passcodeDefaults.removePersistentDomain(forName: passcodeSuite)
        }
        let passcodeStore = CapsuleRevealPasscodeStore(
            defaults: passcodeDefaults
        )
        let customChords = ["ab", "df", "jk", "mn"].compactMap(
            CapsuleRevealChord.init
        )
        let defaultChordKeyCodes: [[UInt16]] = [
            [15, 4], [13, 31], [8, 9, 45], [12, 32],
        ]
        let customChordKeyCodes: [[UInt16]] = [
            [0, 11], [2, 3], [38, 40], [46, 45],
        ]
        guard CapsuleRevealChord("hr") == CapsuleRevealChord("rh"),
              CapsuleRevealChord("r1") == nil,
              CapsuleRevealChord.character(forPhysicalKeyCode: 15) == "r",
              CapsuleRevealChord.character(forPhysicalKeyCode: 4) == "h",
              CapsuleRevealChord.character(forPhysicalKeyCode: 18) == nil,
              let customPasscode = CapsuleRevealPasscode(
                chords: customChords
              ),
              passcodeStore.matches(.defaultValue),
              !passcodeStore.matches(customPasscode) else {
            return capsuleWindowSmokeFail("default chord passcode rules")
        }
        var attempt = CapsuleRevealPasscodeAttempt()
        for chord in customChords.dropLast() {
            guard attempt.append(chord) == nil else {
                return capsuleWindowSmokeFail("passcode completed early")
            }
        }
        guard attempt.append(customChords.last!) == customPasscode,
              attempt.isComplete else {
            return capsuleWindowSmokeFail("four-slot passcode completion")
        }
        passcodeStore.set(customPasscode)
        let storedPasscodeDomain = passcodeDefaults.persistentDomain(
            forName: passcodeSuite
        ) ?? [:]
        guard passcodeStore.isCustomized,
              passcodeStore.matches(customPasscode),
              !passcodeStore.matches(.defaultValue),
              storedPasscodeDomain.count == 1,
              storedPasscodeDomain.values.allSatisfy({ $0 is String }) else {
            return capsuleWindowSmokeFail("custom passcode digest storage")
        }
        let storedCredentialKey = storedPasscodeDomain.keys.first!
        passcodeDefaults.set("damaged", forKey: storedCredentialKey)
        guard passcodeStore.isCustomized,
              !passcodeStore.matches(customPasscode),
              !passcodeStore.matches(.defaultValue) else {
            return capsuleWindowSmokeFail(
                "damaged custom passcode must fail closed"
            )
        }
        passcodeStore.resetToDefault()
        guard !passcodeStore.isCustomized,
              passcodeStore.matches(.defaultValue) else {
            return capsuleWindowSmokeFail("passcode default reset")
        }
        passcodeDefaults.set(
            Data([0x01, 0x02]).base64EncodedString(),
            forKey: "capsule.passwordRevealPasscode.salt.v1"
        )
        guard passcodeStore.isCustomized,
              !passcodeStore.matches(.defaultValue),
              !passcodeStore.matches(customPasscode) else {
            return capsuleWindowSmokeFail(
                "legacy passcode residue must fail closed"
            )
        }
        passcodeStore.resetToDefault()
        guard !passcodeStore.isCustomized,
              passcodeStore.matches(.defaultValue) else {
            return capsuleWindowSmokeFail("legacy passcode recovery reset")
        }

        _ = NSApplication.shared

        // Beginning a sheet necessarily makes its parent resign key. That
        // transition must not cancel authentication, while a real loss of the
        // challenge sheet itself must fail closed and discard partial input.
        let passcodeParent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        passcodeParent.contentView = NSView()
        passcodeParent.orderFront(nil)
        let lifecycleChallenge = CapsuleRevealPasscodeChallengeController(
            purpose: .verify,
            store: passcodeStore
        )
        var lifecycleResult: Bool?
        lifecycleChallenge.beginSheet(for: passcodeParent) { success in
            lifecycleResult = success
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard let challengeSheet = passcodeParent.attachedSheet,
              lifecycleResult == nil,
              challengeSheet.contentView?.hasAmbiguousLayout == false,
              challengeSheet.contentView.map({ root in
                capsuleDescendants(in: root).allSatisfy {
                    !$0.hasAmbiguousLayout
                }
              }) == true else {
            return capsuleWindowSmokeFail(
                "passcode sheet attach/lifecycle/layout"
            )
        }
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: passcodeParent
        )
        guard passcodeParent.attachedSheet === challengeSheet,
              lifecycleResult == nil else {
            return capsuleWindowSmokeFail(
                "parent resign must preserve passcode sheet"
            )
        }
        lifecycleChallenge.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification,
            object: challengeSheet
        ))
        guard lifecycleResult == false,
              passcodeParent.attachedSheet == nil else {
            return capsuleWindowSmokeFail(
                "challenge resign must cancel passcode sheet"
            )
        }

        let eventChallenge = CapsuleRevealPasscodeChallengeController(
            purpose: .verify,
            store: passcodeStore
        )
        var eventResult: Bool?
        eventChallenge.beginSheet(for: passcodeParent) { success in
            eventResult = success
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard let eventSheet = passcodeParent.attachedSheet,
              capsuleSendPasscodeChord(
                [15, 4, 18],
                to: eventSheet
              ),
              eventResult == nil else {
            return capsuleWindowSmokeFail(
                "unsupported physical key must reject whole chord"
            )
        }
        guard capsuleSendPasscode(
                defaultChordKeyCodes,
                to: eventSheet
              ),
              eventResult == true,
              passcodeParent.attachedSheet == nil else {
            return capsuleWindowSmokeFail(
                "physical four-chord event verification"
            )
        }

        let passcodeSettings = CapsuleRevealPasscodeSettingsView(
            store: passcodeStore
        )
        passcodeSettings.frame = NSRect(x: 0, y: 0, width: 650, height: 150)
        passcodeParent.contentView = passcodeSettings
        passcodeParent.layoutIfNeeded()
        let passcodeButtons = capsuleDescendants(in: passcodeSettings)
            .compactMap { $0 as? NSButton }
        guard !passcodeSettings.hasAmbiguousLayout,
              capsuleDescendants(in: passcodeSettings).allSatisfy({
                !$0.hasAmbiguousLayout
              }),
              let setPasscodeButton = passcodeButtons.first(where: {
            $0.title == "设置口令…"
        }), let resetPasscodeButton = passcodeButtons.first(where: {
            $0.title == "恢复默认"
        }) else {
            return capsuleWindowSmokeFail("passcode settings controls")
        }

        setPasscodeButton.performClick(nil)
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard let currentCodeSheet = passcodeParent.attachedSheet,
              passcodeStore.matches(.defaultValue) else {
            return capsuleWindowSmokeFail(
                "changing passcode must verify current code first"
            )
        }
        guard capsuleSendPasscode(
            defaultChordKeyCodes,
            to: currentCodeSheet
        ) else {
            return capsuleWindowSmokeFail("current passcode event fixture")
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard let configurationSheet = passcodeParent.attachedSheet else {
            return capsuleWindowSmokeFail("passcode configuration sheet")
        }
        guard capsuleSendPasscode(
                customChordKeyCodes,
                to: configurationSheet
              ),
              capsuleSendPasscode(
                customChordKeyCodes,
                to: configurationSheet
              ) else {
            return capsuleWindowSmokeFail("new passcode event fixture")
        }
        guard passcodeParent.attachedSheet == nil,
              passcodeStore.matches(customPasscode),
              !passcodeStore.matches(.defaultValue) else {
            return capsuleWindowSmokeFail("authenticated passcode change")
        }

        resetPasscodeButton.performClick(nil)
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard let resetVerificationSheet = passcodeParent.attachedSheet,
              passcodeStore.matches(customPasscode) else {
            return capsuleWindowSmokeFail(
                "reset must verify current passcode first"
            )
        }
        guard capsuleSendPasscode(
            customChordKeyCodes,
            to: resetVerificationSheet
        ) else {
            return capsuleWindowSmokeFail("reset passcode event fixture")
        }
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.05)
        )
        guard passcodeParent.attachedSheet == nil,
              passcodeStore.matches(.defaultValue),
              !passcodeStore.isCustomized else {
            return capsuleWindowSmokeFail("authenticated default reset")
        }
        passcodeParent.orderOut(nil)

        let pane = CapsulePaneViewController(
            repository: repository,
            cloudSyncController: nil
        )
        guard pane.validatesEntryRowPointerForSmoke() else {
            return capsuleWindowSmokeFail("entry-row pointing-hand policy")
        }
        let layoutSizes = [
            NSSize(width: 940, height: 660),
            NSSize(width: 940, height: 1_040),
            NSSize(width: 680, height: 460),
            NSSize(width: 620, height: 430),
        ]
        let fixedFormKinds: Set<CapsuleEntryKind> = [
            .skill, .image, .pdf, .password,
        ]
        for size in layoutSizes {
            // AppKit does not drive resize passes for an unattached root view.
            // A fresh pane makes each requested geometry its initial layout,
            // matching how Settings/standalone windows attach the controller.
            let layoutPane = CapsulePaneViewController(
                repository: repository,
                cloudSyncController: nil
            )
            let layoutWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            layoutWindow.contentViewController = layoutPane
            layoutWindow.setContentSize(size)
            let layouts = CapsuleEntryKind.allCases.map { kind in
                (
                    kind,
                    layoutPane.layoutSnapshotForSmoke(kind: kind, size: size)
                )
            }
            guard let reference = layouts.first?.1,
                  layouts.allSatisfy({ kind, layout in
                    (10...18).contains(layout.subtitleToTabsGap)
                    && (15...17).contains(layout.formTopGap)
                    && abs(layout.tabsTop - layout.editorTop) <= 1.5
                    && layout.kindControlFrame.width > 0
                    && layout.kindControlFrame.height > 0
                    && layout.listFrame.width >= 199
                    && layout.editorFrame.width > 0
                    && layout.editorFrame.height > 0
                    && layout.horizontalContentFits
                    && layout.actionsAreVisible
                    && layout.previewFitsEditorWidth
                    && layout.imagePreviewFitsContainer
                    && layout.imagePreviewUsesAspectFit
                    && layout.formMatchesClipWidth
                    && layout.copyButtonIsVisible
                    && layout.titleRowHeight.map { (35...50).contains($0) }
                        == true
                    && layout.titleToFirstDetailGap.map {
                        (8...12).contains($0)
                    } == true
                    && (!fixedFormKinds.contains(kind)
                        || layout.firstDetailRowHeight.map { $0 <= 50 } == true)
                    && (fixedFormKinds.contains(kind)
                        == (layout.bottomSpacerHeight != nil))
                    && !layout.hasAmbiguousLayout
                  }),
                  layouts.allSatisfy({ _, layout in
                    abs(layout.tabsTop - reference.tabsTop) <= 0.5
                        && abs(layout.editorTop - reference.editorTop) <= 0.5
                  }) else {
                return capsuleWindowSmokeFail(
                    "Password/Skill top alignment size=\(size) "
                        + "layouts=\(layouts)"
                )
            }
            if size.height >= 1_000 {
                guard layouts.allSatisfy({ kind, layout in
                    if fixedFormKinds.contains(kind) {
                        return layout.bottomSpacerHeight.map { $0 > 100 } == true
                    }
                    return layout.bottomSpacerHeight == nil
                        && layout.firstDetailRowHeight.map { $0 > 500 } == true
                }) else {
                    return capsuleWindowSmokeFail(
                        "editor vertical expansion size=\(size) layouts=\(layouts)"
                    )
                }
            }
        }

        let visibleFrame = NSRect(x: 0, y: 0, width: 1_280, height: 720)
        let safeFrame = visibleFrame.insetBy(dx: 12, dy: 12)
        let oversized = CapsuleWindowGeometry.constrainedFrame(
            NSRect(x: -400, y: -300, width: 1_800, height: 1_000),
            visibleFrames: [visibleFrame]
        )
        let offscreen = CapsuleWindowGeometry.constrainedFrame(
            NSRect(x: 3_000, y: 2_000, width: 900, height: 600),
            visibleFrames: [],
            fallbackVisibleFrame: visibleFrame
        )
        let alreadySafe = NSRect(x: 80, y: 30, width: 940, height: 660)
        guard safeFrame.contains(oversized),
              safeFrame.contains(offscreen),
              CapsuleWindowGeometry.constrainedFrame(
                alreadySafe,
                visibleFrames: [visibleFrame]
              ) == alreadySafe else {
            return capsuleWindowSmokeFail("restored window frame containment")
        }
        for kind in CapsuleEntryKind.allCases {
            _ = pane.layoutSnapshotForSmoke(kind: kind, size: layoutSizes[0])
            guard capsulePointingHandControlsAreValid(in: pane.view) else {
                return capsuleWindowSmokeFail(
                    "pointing-hand control coverage for \(kind.displayName)"
                )
            }
        }

        var lifecycleEvents: [String] = []
        CapsuleWindowVisibilityRules.perform(
            .show,
            show: { lifecycleEvents.append("show") },
            performClose: { lifecycleEvents.append("perform-close") }
        )
        CapsuleWindowVisibilityRules.perform(
            .close,
            show: { lifecycleEvents.append("show") },
            performClose: { lifecycleEvents.append("perform-close") }
        )
        guard CapsuleWindowVisibilityRules.action(isVisible: false) == .show,
              CapsuleWindowVisibilityRules.action(isVisible: true) == .close,
              lifecycleEvents == ["show", "perform-close"],
              !CapsuleWindowSelectionRules.allowsAutomaticFirstSelection(
                kind: .password
              ),
              CapsuleWindowSelectionRules.allowsAutomaticFirstSelection(
                kind: .note
              ),
              !StandaloneWindowFocusReturnRules.closeHasCompleted(
                windowIsVisible: true
              ),
              StandaloneWindowFocusReturnRules.closeHasCompleted(
                windowIsVisible: false
              ) else {
            return capsuleWindowSmokeFail("visibility toggle contract")
        }

        var prompt = CapsuleWindowDraft.empty(kind: .note)
        prompt.title = "Smoke Prompt"
        prompt.content = "Summarize this local document in three points."
        let promptRow = try repository.save(prompt)

        var memory = CapsuleWindowDraft.empty(kind: .note)
        memory.title = "Smoke Memory"
        memory.content = "Capsule remains local and Obsidian-readable."
        let memoryRow = try repository.save(memory)

        let skillDirectory = root.appendingPathComponent(
            "fixture-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        var skill = CapsuleWindowDraft.empty(kind: .skill)
        skill.title = "Smoke Skill"
        skill.content = skillDirectory.path
        let skillRow = try repository.save(skill)

        var note = CapsuleWindowDraft.empty(kind: .note)
        note.title = "Smoke Note"
        note.content = "# Local note\n\nOne Markdown file is one Capsule item."
        let noteRow = try repository.save(note)


        let imageURL = root.appendingPathComponent("fixture-image.png")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let imageData = bitmap.representation(using: .png, properties: [:]) else {
            return capsuleWindowSmokeFail("image fixture creation")
        }
        try imageData.write(to: imageURL, options: .atomic)

        let pdfURL = root.appendingPathComponent("fixture-document.pdf")
        let pdfFixture = NSView(frame: NSRect(x: 0, y: 0, width: 72, height: 72))
        let pdfData = pdfFixture.dataWithPDF(inside: pdfFixture.bounds)
        try pdfData.write(to: pdfURL, options: .atomic)

        let imagePasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "RIMES.CapsuleWindowSmoke.image.\(UUID().uuidString)"
            )
        )
        try CapsuleFilePasteboardWriter.copy(
            kind: .image,
            path: imageURL.path,
            to: imagePasteboard
        )
        guard let imageItem = imagePasteboard.pasteboardItems?.first,
              imagePasteboard.pasteboardItems?.count == 1,
              let copiedPNG = imageItem.data(forType: .png),
              NSImage(data: copiedPNG) != nil,
              imageItem.data(forType: .tiff) != nil,
              imageItem.string(forType: .fileURL)
                == imageURL.standardizedFileURL.absoluteString else {
            return capsuleWindowSmokeFail(
                "image copy representations/file URL"
            )
        }

        let wideImageURL = root.appendingPathComponent("fixture-wide.jpg")
        guard let wideBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 5_000,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let wideJPEG = wideBitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else {
            return capsuleWindowSmokeFail("wide image fixture creation")
        }
        try wideJPEG.write(to: wideImageURL, options: .atomic)

        let tallImageURL = root.appendingPathComponent("fixture-tall.jpg")
        guard let tallBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 5_000,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let tallJPEG = tallBitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else {
            return capsuleWindowSmokeFail("tall image fixture creation")
        }
        try tallJPEG.write(to: tallImageURL, options: .atomic)

        let mediaFixtures: [(CapsuleEntryKind, URL, String)] = [
            (.image, wideImageURL, "wide image"),
            (.image, tallImageURL, "tall image"),
            (.pdf, pdfURL, "PDF"),
        ]
        let mediaContentSizes = [
            CapsuleWindowGeometry.defaultContentSize,
            NSSize(width: 680, height: 460),
            CapsuleWindowGeometry.minimumContentSize,
        ]
        for contentSize in mediaContentSizes {
            for (kind, url, label) in mediaFixtures {
                let mediaPane = CapsulePaneViewController(
                    repository: repository,
                    cloudSyncController: nil
                )
                let mediaWindow = NSWindow(
                    contentRect: NSRect(origin: .zero, size: contentSize),
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                mediaWindow.contentMinSize = CapsuleWindowGeometry.minimumContentSize
                CapsuleWindowGeometry.install(
                    contentController: mediaPane,
                    in: mediaWindow
                )
                mediaWindow.setContentSize(contentSize)
                mediaPane.beginMediaPreviewForSmoke(kind: kind, path: url.path)
                let frameBeforeLoad = mediaWindow.frame
                let contentLayoutSizeBeforeLoad = mediaWindow.contentLayoutRect.size
                let contentViewSizeBeforeLoad = mediaWindow.contentView?.bounds.size
                let previewDeadline = Date().addingTimeInterval(5)
                while !mediaPane.mediaPreviewIsReadyForSmoke,
                      Date() < previewDeadline {
                    RunLoop.current.run(
                        mode: .default,
                        before: Date().addingTimeInterval(0.01)
                    )
                }
                mediaWindow.layoutIfNeeded()
                let mediaLayout = mediaPane.currentLayoutSnapshotForSmoke(
                    kind: kind
                )
                guard mediaPane.mediaPreviewIsReadyForSmoke,
                      capsuleSizesMatch(
                        frameBeforeLoad.size,
                        mediaWindow.frame.size
                      ),
                      capsuleSizesMatch(
                        contentLayoutSizeBeforeLoad,
                        mediaWindow.contentLayoutRect.size
                      ),
                      (contentViewSizeBeforeLoad.map {
                        capsuleSizesMatch(
                            $0,
                            mediaWindow.contentView?.bounds.size ?? .zero
                        )
                      } == true),
                      (mediaLayout.previewFrame.map {
                        $0.width <= 640.5 && (159...361).contains($0.height)
                      } == true),
                      mediaLayout.imagePreviewFrame != nil,
                      mediaLayout.imagePreviewFitsContainer,
                      mediaLayout.imagePreviewUsesAspectFit,
                      mediaLayout.formMatchesClipWidth,
                      mediaLayout.horizontalContentFits,
                      !mediaLayout.hasAmbiguousLayout else {
                    return capsuleWindowSmokeFail(
                        "async \(label) preview changed window geometry at "
                            + "contentSize=\(contentSize): "
                            + "before=\(frameBeforeLoad) "
                            + "after=\(mediaWindow.frame) layout=\(mediaLayout)"
                    )
                }
            }
        }

        let widePasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "RIMES.CapsuleWindowSmoke.wide.\(UUID().uuidString)"
            )
        )
        try CapsuleFilePasteboardWriter.copy(
            kind: .image,
            path: wideImageURL.path,
            to: widePasteboard
        )
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        guard let wideItem = widePasteboard.pasteboardItems?.first,
              wideItem.data(forType: jpegType) == wideJPEG,
              let fallbackPNG = wideItem.data(forType: .png),
              let fallbackRep = NSBitmapImageRep(data: fallbackPNG),
              fallbackRep.pixelsWide
                <= CapsuleFilePasteboardWriter
                    .maximumFallbackRepresentationDimension,
              fallbackRep.pixelsHigh
                <= CapsuleFilePasteboardWriter
                    .maximumFallbackRepresentationDimension else {
            return capsuleWindowSmokeFail(
                "bounded image fallback/original representation"
            )
        }

        let pdfPasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "RIMES.CapsuleWindowSmoke.pdf.\(UUID().uuidString)"
            )
        )
        try CapsuleFilePasteboardWriter.copy(
            kind: .pdf,
            path: pdfURL.path,
            to: pdfPasteboard
        )
        guard let pdfItem = pdfPasteboard.pasteboardItems?.first,
              pdfPasteboard.pasteboardItems?.count == 1,
              pdfItem.string(forType: .fileURL)
                == pdfURL.standardizedFileURL.absoluteString,
              pdfItem.data(forType: .png) == nil,
              pdfItem.data(forType: .tiff) == nil else {
            return capsuleWindowSmokeFail("PDF copy as file URL")
        }

        let skillPasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "RIMES.CapsuleWindowSmoke.skill.\(UUID().uuidString)"
            )
        )
        try CapsuleFilePasteboardWriter.copy(
            kind: .skill,
            path: skillDirectory.path,
            to: skillPasteboard
        )
        guard skillPasteboard.pasteboardItems?.first?.string(forType: .fileURL)
                == skillDirectory.standardizedFileURL.absoluteString else {
            return capsuleWindowSmokeFail("Skill folder copy as file URL")
        }
        let skillFileURL = skillDirectory.appendingPathComponent("SKILL.md")
        try Data("# Fixture Skill".utf8).write(to: skillFileURL, options: .atomic)
        try CapsuleFilePasteboardWriter.copy(
            kind: .skill,
            path: skillFileURL.path,
            to: skillPasteboard
        )
        guard skillPasteboard.pasteboardItems?.first?.string(forType: .fileURL)
                == skillFileURL.standardizedFileURL.absoluteString else {
            return capsuleWindowSmokeFail("Skill file copy as file URL")
        }

        let stalePayload = try CapsuleFilePasteboardWriter.prepare(
            kind: .pdf,
            path: pdfURL.path
        )
        skillPasteboard.clearContents()
        skillPasteboard.setString("older", forType: .string)
        let expectedChangeCount = skillPasteboard.changeCount
        skillPasteboard.clearContents()
        skillPasteboard.setString("newer-user-clipboard", forType: .string)
        do {
            _ = try CapsuleFilePasteboardWriter.write(
                stalePayload,
                to: skillPasteboard,
                expectedChangeCount: expectedChangeCount
            )
            return capsuleWindowSmokeFail(
                "stale async copy overwrote newer pasteboard"
            )
        } catch CapsuleFilePasteboardError.pasteboardChanged {
            // Expected: preparation completion is compare-before-write.
        }
        guard skillPasteboard.string(forType: .string)
                == "newer-user-clipboard" else {
            return capsuleWindowSmokeFail(
                "stale async copy cleared newer pasteboard"
            )
        }

        let failurePasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "RIMES.CapsuleWindowSmoke.failure.\(UUID().uuidString)"
            )
        )
        failurePasteboard.clearContents()
        failurePasteboard.setString("keep-existing", forType: .string)
        do {
            try CapsuleFilePasteboardWriter.copy(
                kind: .image,
                path: root.appendingPathComponent("missing-copy.png").path,
                to: failurePasteboard
            )
            return capsuleWindowSmokeFail("missing image copied")
        } catch CapsuleFilePasteboardError.unavailableFile {
            // Expected: validation happens before the pasteboard is cleared.
        }
        guard failurePasteboard.string(forType: .string) == "keep-existing" else {
            return capsuleWindowSmokeFail(
                "failed copy cleared existing pasteboard"
            )
        }

        var image = CapsuleWindowDraft.empty(kind: .image)
        image.title = "Smoke Image"
        image.content = imageURL.path
        let imageRow = try repository.save(image)

        var pdf = CapsuleWindowDraft.empty(kind: .pdf)
        pdf.title = "Smoke PDF"
        pdf.content = pdfURL.path
        let pdfRow = try repository.save(pdf)

        var password = CapsuleWindowDraft.empty(kind: .password)
        password.title = "Smoke Password"
        password.content = """
        - 网址：https://credential.invalid/login
        - 用户名：private-user
        - 密码：private-current-password
        """
        let passwordRow = try repository.save(password)

        guard promptRow.kind == .note,
              memoryRow.kind == .note,
              skillRow.kind == .skill,
              noteRow.kind == .note,
              imageRow.kind == .image,
              pdfRow.kind == .pdf,
              passwordRow.kind == .password,
              try repository.list(kind: .note).map(\.id).contains(promptRow.id),
              try repository.list(kind: .skill).map(\.id) == [skillRow.id],
              try repository.list(kind: .note).map(\.id).contains(noteRow.id),
              try repository.list(kind: .image).map(\.id) == [imageRow.id],
              try repository.list(kind: .pdf).map(\.id) == [pdfRow.id],
              try repository.list(kind: .password).map(\.id) == [passwordRow.id] else {
            return capsuleWindowSmokeFail("create/list routing")
        }

        guard imageRow.preview == "Image · fixture-image.png",
              pdfRow.preview == "PDF · fixture-document.pdf" else {
            return capsuleWindowSmokeFail("safe media list projection")
        }
        guard case .image = CapsuleMediaPreviewLoader.loadSynchronously(
            kind: .image,
            path: imageURL.path
        ), case .pdf = CapsuleMediaPreviewLoader.loadSynchronously(
            kind: .pdf,
            path: pdfURL.path
        ) else {
            return capsuleWindowSmokeFail("real image/PDF preview decode")
        }
        let previewQueue = OperationQueue()
        previewQueue.isSuspended = true
        let previewLoader = CapsuleMediaPreviewLoader(queue: previewQueue)
        var asyncPreviewKinds: [CapsuleEntryKind] = []
        let imageOperation = previewLoader.load(
            kind: .image,
            path: imageURL.path
        ) { result in
            if case .image = result { asyncPreviewKinds.append(.image) }
        }
        let pdfOperation = previewLoader.load(
            kind: .pdf,
            path: pdfURL.path
        ) { result in
            if case .pdf = result { asyncPreviewKinds.append(.pdf) }
        }
        previewQueue.isSuspended = false
        let previewDeadline = Date().addingTimeInterval(5)
        while asyncPreviewKinds.count < 2, Date() < previewDeadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.01)
            )
        }
        guard !imageOperation.isCancelled,
              !pdfOperation.isCancelled,
              Set(asyncPreviewKinds) == Set([.image, .pdf]) else {
            return capsuleWindowSmokeFail(
                "independent panes must not cancel each other's media preview"
            )
        }
        let linkedImageURL = root.appendingPathComponent("linked-image.png")
        try FileManager.default.createSymbolicLink(
            at: linkedImageURL,
            withDestinationURL: imageURL
        )
        guard case .unavailable = CapsuleMediaPreviewLoader.loadSynchronously(
            kind: .image,
            path: linkedImageURL.path
        ), case .unavailable = CapsuleMediaPreviewLoader.loadSynchronously(
            kind: .pdf,
            path: root.appendingPathComponent("missing.pdf").path
        ) else {
            return capsuleWindowSmokeFail("unsafe/missing media preview rejection")
        }
        do {
            try CapsuleFilePasteboardWriter.copy(
                kind: .image,
                path: linkedImageURL.path,
                to: failurePasteboard
            )
            return capsuleWindowSmokeFail("symlink image copied")
        } catch CapsuleFilePasteboardError.unavailableFile {
            // Expected: copy follows the same O_NOFOLLOW boundary as preview.
        }

        guard passwordRow.preview == "••••••••",
              !passwordRow.accessibilitySummary.contains("private-user"),
              !passwordRow.accessibilitySummary.contains("private-current-password"),
              try repository.list(kind: .password, query: "private-user").isEmpty,
              try repository.list(kind: .password, query: "Smoke Password")
                .map(\.id) == [passwordRow.id] else {
            return capsuleWindowSmokeFail("password list/search disclosure boundary")
        }

        let hiddenEditor = pane.passwordEditorSnapshotForSmoke(
            plaintextVisible: false
        )
        let revealedEditor = pane.passwordEditorSnapshotForSmoke(
            plaintextVisible: true
        )
        guard capsulePointingHandControlsAreValid(in: pane.view) else {
            return capsuleWindowSmokeFail(
                "pointing-hand control coverage for Password history"
            )
        }
        var revealState = CapsulePasswordRevealState()
        let revealStart = Date(timeIntervalSince1970: 1_000)
        revealState.reveal(now: revealStart)
        guard !CapsulePasswordEditorSecurityPolicy.usesSecureControl(.title),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(.secret),
              CapsulePasswordEditorSecurityPolicy.mayReveal(.secret),
              !CapsulePasswordEditorSecurityPolicy.mayReveal(.title),
              !CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .secret,
                plaintextVisible: true
              ) else {
            return capsuleWindowSmokeFail("password editor security policy")
        }

        var obsidianStaleMemory = try repository.draft(for: memoryRow)
        let memoryMarkdown = try String(
            contentsOf: contentStore.record(id: memoryRow.id).summary.fileURL,
            encoding: .utf8
        )
        let directlyEditedMarkdown = memoryMarkdown.replacingOccurrences(
            of: "Capsule remains local and Obsidian-readable.",
            with: "Capsule was edited directly in Obsidian."
        )
        guard directlyEditedMarkdown != memoryMarkdown else {
            return capsuleWindowSmokeFail("Obsidian edit fixture did not change")
        }
        let memoryFileURL = try contentStore.record(id: memoryRow.id).summary.fileURL
        try Data(directlyEditedMarkdown.utf8).write(
            to: memoryFileURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: memoryFileURL.path
        )
        obsidianStaleMemory.content = "A stale pane must not overwrite Obsidian."
        do {
            _ = try repository.save(obsidianStaleMemory)
            return capsuleWindowSmokeFail("direct Obsidian edit was overwritten")
        } catch CapsuleWindowRepositoryError.staleRecord {
            // Expected: the full Markdown file fingerprint changed.
        }
        do {
            try repository.remove(
                memoryRow,
                expectedRevision: memoryRow.revision
            )
            return capsuleWindowSmokeFail("stale row deleted an Obsidian edit")
        } catch CapsuleWindowRepositoryError.staleRecord {
            // Expected: deletion uses the same file revision guard.
        }

        var editedPrompt = try repository.draft(for: promptRow)
        var stalePrompt = editedPrompt
        editedPrompt.title = "Smoke Prompt Edited"
        editedPrompt.content = "Return exactly three concise points."
        instant.addTimeInterval(1)
        let updatedPrompt = try repository.save(editedPrompt)
        guard updatedPrompt.id == promptRow.id,
              try contentStore.record(id: promptRow.id).content
                == editedPrompt.content else {
            return capsuleWindowSmokeFail("ordinary update routing")
        }
        stalePrompt.content = "This stale pane must not overwrite the update."
        do {
            _ = try repository.save(stalePrompt)
            return capsuleWindowSmokeFail("stale ordinary draft overwrote a newer edit")
        } catch CapsuleWindowRepositoryError.staleRecord {
            // Expected: two panes cannot silently overwrite each other.
        }

        var editedMemory = try repository.draft(for: memoryRow)
        editedMemory.content = "Capsule updates remain local and inspectable."
        instant.addTimeInterval(1)
        let updatedMemory = try repository.save(editedMemory)
        var editedSkill = try repository.draft(for: skillRow)
        editedSkill.content = root.path
        instant.addTimeInterval(1)
        let updatedSkill = try repository.save(editedSkill)
        guard updatedMemory.id == memoryRow.id,
              updatedSkill.id == skillRow.id,
              try contentStore.record(id: memoryRow.id).content
                == editedMemory.content,
              try contentStore.record(id: skillRow.id).content == root.path else {
            return capsuleWindowSmokeFail("Memory/Skill update routing")
        }

        var editedPassword = try repository.draft(for: passwordRow)
        var stalePassword = editedPassword
        guard editedPassword.content.contains("private-user"),
              editedPassword.content.contains("private-current-password") else {
            return capsuleWindowSmokeFail("explicit password edit load")
        }
        editedPassword.content = "- 密码：private-rotated-password"
        instant.addTimeInterval(1)
        let updatedPassword = try repository.save(editedPassword)
        let storedPassword = try passwordStore.record(id: passwordRow.id)
        guard updatedPassword.id == passwordRow.id,
              updatedPassword.preview == "••••••••",
              storedPassword.secret.body == "- 密码：private-rotated-password" else {
            return capsuleWindowSmokeFail("password update routing")
        }
        stalePassword.content = "- 密码：stale-password-must-not-win"
        do {
            _ = try repository.save(stalePassword)
            return capsuleWindowSmokeFail("stale password draft overwrote rotation")
        } catch CapsuleWindowRepositoryError.staleRecord {
            // Expected: password rotation is protected by the loaded revision.
        }

        var relativeSkill = CapsuleWindowDraft.empty(kind: .skill)
        relativeSkill.title = "Invalid Skill"
        relativeSkill.content = "relative/path"
        do {
            _ = try repository.save(relativeSkill)
            return capsuleWindowSmokeFail("relative Skill path accepted")
        } catch CapsuleWindowDraftError.relativeSkillPath {
            // Expected: the manager validates before calling the store.
        }


        var missingImage = CapsuleWindowDraft.empty(kind: .image)
        missingImage.title = "Missing Image"
        missingImage.content = root.appendingPathComponent("missing.png").path
        do {
            _ = try repository.save(missingImage)
            return capsuleWindowSmokeFail("missing image accepted")
        } catch CapsuleWindowDraftError.unavailableAsset {
            // Expected.
        }

        var wrongPDF = CapsuleWindowDraft.empty(kind: .pdf)
        wrongPDF.title = "Wrong PDF"
        wrongPDF.content = imageURL.path
        do {
            _ = try repository.save(wrongPDF)
            return capsuleWindowSmokeFail("wrong PDF extension accepted")
        } catch CapsuleWindowDraftError.unsupportedAssetType {
            // Expected.
        }

        var emptyPassword = CapsuleWindowDraft.empty(kind: .password)
        emptyPassword.title = "Invalid Password"
        do {
            _ = try repository.save(emptyPassword)
            return capsuleWindowSmokeFail("empty password accepted")
        } catch CapsuleWindowDraftError.missingPassword {
            // Expected.
        }

        try repository.remove(
            updatedPrompt,
            expectedRevision: updatedPrompt.revision
        )
        try repository.remove(
            updatedMemory,
            expectedRevision: updatedMemory.revision
        )
        try repository.remove(
            updatedSkill,
            expectedRevision: updatedSkill.revision
        )
        try repository.remove(noteRow, expectedRevision: noteRow.revision)
        try repository.remove(imageRow, expectedRevision: imageRow.revision)
        try repository.remove(pdfRow, expectedRevision: pdfRow.revision)
        try repository.remove(
            updatedPassword,
            expectedRevision: updatedPassword.revision
        )
        // The seeded welcome entry is itself a Note now, so "empty" means
        // nothing survives except that preset.
        guard try repository.list(kind: .note).allSatisfy({
                $0.id == CapsuleContentStore.defaultEntryID
              }),
              try repository.list(kind: .skill).isEmpty,
              try repository.list(kind: .image).isEmpty,
              try repository.list(kind: .pdf).isEmpty,
              try repository.list(kind: .password).isEmpty,
              try repository.list(kind: .note, query: "Smoke Memory").isEmpty else {
            return capsuleWindowSmokeFail("delete routing")
        }
    } catch {
        return capsuleWindowSmokeFail("unexpected error: \(error.localizedDescription)")
    }

    print("capsule-window-smoke: OK")
    return true
}

private func capsuleWindowSmokeFail(_ message: String) -> Bool {
    fputs("capsule-window-smoke: FAIL: \(message)\n", stderr)
    return false
}

private func capsuleSendPasscodeChord(
    _ keyCodes: [UInt16],
    to window: NSWindow
) -> Bool {
    func event(
        type: NSEvent.EventType,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    for keyCode in keyCodes {
        guard let keyDown = event(type: .keyDown, keyCode: keyCode) else {
            return false
        }
        window.sendEvent(keyDown)
    }
    for keyCode in keyCodes.reversed() {
        guard let keyUp = event(type: .keyUp, keyCode: keyCode) else {
            return false
        }
        window.sendEvent(keyUp)
    }
    return true
}

private func capsuleSendPasscode(
    _ chords: [[UInt16]],
    to window: NSWindow
) -> Bool {
    chords.allSatisfy { capsuleSendPasscodeChord($0, to: window) }
}

private func capsuleSizesMatch(
    _ lhs: NSSize,
    _ rhs: NSSize,
    tolerance: CGFloat = 0.5
) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func capsulePointingHandControlsAreValid(in root: NSView) -> Bool {
    let controls = capsuleDescendants(in: root)
    // AppKit owns the private search/clear buttons nested inside
    // NSSearchField. Their concrete classes vary by macOS release and should
    // keep the system cursor policy; this assertion covers only our controls.
    let buttons = controls.compactMap { $0 as? NSButton }.filter {
        !capsuleIsInsideSearchField($0)
    }
    let segmentedControls = controls.compactMap { $0 as? NSSegmentedControl }
    let popUpButtons = controls.compactMap { $0 as? NSPopUpButton }
    return !buttons.isEmpty
        && !segmentedControls.isEmpty
        && buttons.allSatisfy {
            $0 is RimePointingHandButton
                || $0 is RimeFixedAccentPopUpButton
        }
        && segmentedControls.allSatisfy {
            $0 is RimePointingHandSegmentedControl
        }
        && popUpButtons.allSatisfy {
            $0 is RimeFixedAccentPopUpButton
        }
}

private func capsuleIsInsideSearchField(_ view: NSView) -> Bool {
    var ancestor = view.superview
    while let current = ancestor {
        if current is NSSearchField { return true }
        ancestor = current.superview
    }
    return false
}

private func capsuleDescendants(in root: NSView) -> [NSView] {
    root.subviews.flatMap { child in
        [child] + capsuleDescendants(in: child)
    }
}
