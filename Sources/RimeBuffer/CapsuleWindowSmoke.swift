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
        _ = NSApplication.shared
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
                  layouts.allSatisfy({ _, layout in
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
                    && layout.copyButtonIsVisible
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
                kind: .prompt
              ),
              !StandaloneWindowFocusReturnRules.closeHasCompleted(
                windowIsVisible: true
              ),
              StandaloneWindowFocusReturnRules.closeHasCompleted(
                windowIsVisible: false
              ) else {
            return capsuleWindowSmokeFail("visibility toggle contract")
        }

        var prompt = CapsuleWindowDraft.empty(kind: .prompt)
        prompt.title = "Smoke Prompt"
        prompt.content = "Summarize this local document in three points."
        let promptRow = try repository.save(prompt)

        var memory = CapsuleWindowDraft.empty(kind: .memory)
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

        var webURL = CapsuleWindowDraft.empty(kind: .url)
        webURL.title = "Smoke URL"
        webURL.content = "https://example.invalid/private/path?token=never-list#anchor"
        let urlRow = try repository.save(webURL)

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
        password.url = "https://credential.invalid/login"
        password.app = "Fixture Browser"
        password.username = "private-user"
        password.password = "private-current-password"
        password.previousPasswords = ["private-old-password"]
        let passwordRow = try repository.save(password)

        guard promptRow.kind == .prompt,
              memoryRow.kind == .memory,
              skillRow.kind == .skill,
              noteRow.kind == .note,
              urlRow.kind == .url,
              imageRow.kind == .image,
              pdfRow.kind == .pdf,
              passwordRow.kind == .password,
              try repository.list(kind: .prompt).map(\.id) == [promptRow.id],
              try repository.list(kind: .skill).map(\.id) == [skillRow.id],
              try repository.list(kind: .note).map(\.id) == [noteRow.id],
              try repository.list(kind: .url).map(\.id) == [urlRow.id],
              try repository.list(kind: .image).map(\.id) == [imageRow.id],
              try repository.list(kind: .pdf).map(\.id) == [pdfRow.id],
              try repository.list(kind: .password).map(\.id) == [passwordRow.id] else {
            return capsuleWindowSmokeFail("create/list routing")
        }

        guard urlRow.preview == "example.invalid/private/path",
              !urlRow.accessibilitySummary.contains("token="),
              imageRow.preview == "Image · fixture-image.png",
              pdfRow.preview == "PDF · fixture-document.pdf" else {
            return capsuleWindowSmokeFail("safe URL/media list projection")
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
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(.url),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(.app),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(.username),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(.password),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .previousPassword
              ),
              CapsulePasswordEditorSecurityPolicy.mayReveal(.password),
              CapsulePasswordEditorSecurityPolicy.mayReveal(.previousPassword),
              !CapsulePasswordEditorSecurityPolicy.mayReveal(.url),
              !CapsulePasswordEditorSecurityPolicy.mayReveal(.app),
              !CapsulePasswordEditorSecurityPolicy.mayReveal(.username),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .url,
                plaintextVisible: true
              ),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .app,
                plaintextVisible: true
              ),
              CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .username,
                plaintextVisible: true
              ),
              !CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .password,
                plaintextVisible: true
              ),
              !CapsulePasswordEditorSecurityPolicy.usesSecureControl(
                .previousPassword,
                plaintextVisible: true
              ),
              hiddenEditor.revealButtonTitle == "查看明文",
              hiddenEditor.urlUsesSecureControl,
              hiddenEditor.appUsesSecureControl,
              hiddenEditor.usernameUsesSecureControl,
              hiddenEditor.passwordUsesSecureControl,
              hiddenEditor.previousPasswordsUseSecureControls,
              !hiddenEditor.hasUnsavedChanges,
              revealedEditor.revealButtonTitle == "隐藏明文",
              revealedEditor.urlUsesSecureControl,
              revealedEditor.appUsesSecureControl,
              revealedEditor.usernameUsesSecureControl,
              !revealedEditor.passwordUsesSecureControl,
              !revealedEditor.previousPasswordsUseSecureControls,
              !revealedEditor.plaintextAllowsSelection,
              !revealedEditor.plaintextIsAccessibilityElement,
              !revealedEditor.plaintextHasToolTip,
              !revealedEditor.hasUnsavedChanges,
              revealState.isPlaintextVisible,
              !revealState.concealIfExpired(
                now: revealStart.addingTimeInterval(14.999)
              ),
              revealState.concealIfExpired(
                now: revealStart.addingTimeInterval(15)
              ),
              !revealState.isPlaintextVisible else {
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
        guard editedPassword.username == "private-user",
              editedPassword.password == "private-current-password" else {
            return capsuleWindowSmokeFail("explicit password edit load")
        }
        editedPassword.password = "private-rotated-password"
        editedPassword.previousPasswords = ["private-current-password"]
        instant.addTimeInterval(1)
        let updatedPassword = try repository.save(editedPassword)
        let storedPassword = try passwordStore.record(id: passwordRow.id)
        guard updatedPassword.id == passwordRow.id,
              updatedPassword.preview == "••••••••",
              storedPassword.secret.password == "private-rotated-password",
              storedPassword.secret.previousPasswords
                == ["private-current-password"] else {
            return capsuleWindowSmokeFail("password update routing")
        }
        stalePassword.password = "stale-password-must-not-win"
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

        var invalidURL = CapsuleWindowDraft.empty(kind: .url)
        invalidURL.title = "Invalid URL"
        invalidURL.content = "javascript:alert(1)"
        do {
            _ = try repository.save(invalidURL)
            return capsuleWindowSmokeFail("unsafe URL accepted")
        } catch CapsuleWindowDraftError.invalidURL {
            // Expected.
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
        try repository.remove(urlRow, expectedRevision: urlRow.revision)
        try repository.remove(imageRow, expectedRevision: imageRow.revision)
        try repository.remove(pdfRow, expectedRevision: pdfRow.revision)
        try repository.remove(
            updatedPassword,
            expectedRevision: updatedPassword.revision
        )
        guard try repository.list(kind: .prompt).isEmpty,
              try repository.list(kind: .skill).isEmpty,
              try repository.list(kind: .note).isEmpty,
              try repository.list(kind: .url).isEmpty,
              try repository.list(kind: .image).isEmpty,
              try repository.list(kind: .pdf).isEmpty,
              try repository.list(kind: .password).isEmpty,
              try repository.list(kind: .memory, query: "Smoke Memory").isEmpty else {
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
