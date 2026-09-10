import AppKit
import Foundation

/// The mode split is only worth having if it stays at the boundary. These
/// assertions include one that reads the source tree, because the failure
/// being prevented is not a wrong value — it is a correct value consulted in
/// the wrong place, which no runtime test can see.
func runBufferPresentationModeSmokeTest() -> Bool {
    print("== RIMES buffer presentation mode smoke ==")

    guard BufferPresentationMode.resolve(currentSourceIsOwn: true)
            == .integratedRime,
          BufferPresentationMode.resolve(currentSourceIsOwn: false)
            == .standaloneField else {
        return presentationModeFail("mode resolution")
    }

    // Borrowed mode must never take focus: doing so would end the host's own
    // editing session, which is exactly what the integrated experience is for.
    guard BufferPresentationMode.integratedRime.panelAcceptsKeyInput == false,
          BufferPresentationMode.standaloneField.panelAcceptsKeyInput else {
        return presentationModeFail("panel focus capability")
    }
    // Only the active input method holds a client to insert into.
    guard BufferPresentationMode.integratedRime.deliversThroughInputMethod,
          BufferPresentationMode.standaloneField.deliversThroughInputMethod
            == false else {
        return presentationModeFail("delivery capability")
    }
    // Exactly one mode shows a composing field, and it is the one with no
    // host preedit to mirror.
    guard BufferPresentationMode.allCases
            .filter(\.showsComposingField).count == 1,
          BufferPresentationMode.standaloneField.showsComposingField else {
        return presentationModeFail("composing field ownership")
    }

    // The boundary itself. A mode leaking into the model, the rail or a
    // plugin is how one product quietly becomes two that must be restyled
    // twice — the cost this design exists to avoid.
    guard let sourceRoot = presentationModeSourceRoot() else {
        print("presentation mode smoke: OK (source tree unavailable)")
        return true
    }
    let fileManager = FileManager.default
    guard let walker = fileManager.enumerator(atPath: sourceRoot.path) else {
        return presentationModeFail("could not read the source tree")
    }
    var offenders: [String] = []
    for case let relative as String in walker where relative.hasSuffix(".swift") {
        let name = (relative as NSString).lastPathComponent
        guard !BufferPresentationModeBoundary.isPermitted(file: name) else {
            continue
        }
        let url = sourceRoot.appendingPathComponent(relative)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            continue
        }
        // Wiring this very test into the CLI is not consulting the mode.
        let text = raw.replacingOccurrences(
            of: "runBufferPresentationModeSmokeTest",
            with: ""
        )
        if text.contains("BufferPresentationMode")
            || text.contains(".standaloneField")
            || text.contains(".integratedRime") {
            offenders.append(name)
        }
    }
    guard offenders.isEmpty else {
        return presentationModeFail(
            "the mode must stay at the boundary; consulted in "
                + offenders.sorted().joined(separator: ", ")
        )
    }

    // The composing field is the one visible difference, and it must not be
    // reachable in the integrated mode where the host owns the preedit.
    let view = BufferInlineView(frame: NSRect(x: 0, y: 0, width: 520, height: 32))
    guard !view.renderedComposingFieldVisible else {
        return presentationModeFail("the field must start hidden")
    }
    view.setComposingFieldEnabled(
        BufferPresentationMode.integratedRime.showsComposingField
    )
    guard !view.renderedComposingFieldVisible else {
        return presentationModeFail("integrated mode must show no field")
    }
    view.setComposingFieldEnabled(
        BufferPresentationMode.standaloneField.showsComposingField
    )
    guard view.renderedComposingFieldVisible else {
        return presentationModeFail("standalone mode must show the field")
    }
    // Focus is refused while the panel is not key: asking for it anyway would
    // silently do nothing and look like a dead field.
    guard view.focusComposingField() == false else {
        return presentationModeFail("focus must require a key window")
    }
    // Leaving the mode clears anything half-typed rather than keeping it for
    // a session the user has already left.
    var committed: [String] = []
    view.onComposingFieldCommit = { committed.append($0) }
    view.setComposingFieldEnabled(false)
    guard view.renderedComposingText.isEmpty, committed.isEmpty else {
        return presentationModeFail("leaving the mode must clear the field")
    }

    // Folding. Without focus a standalone workbench looks ready and takes
    // nothing; folding says so and makes the toolbar the way back in.
    func folds(acceptsInput: Bool,
               music: Bool = false,
               staged: Bool = false) -> Bool {
        BufferRailFoldRules.foldsToToolbar(acceptsInput: acceptsInput,
                                           musicSelected: music,
                                           hasStagedContent: staged)
    }
    // A workbench that cannot receive a keystroke says so, in either mode:
    // the question "will this take my typing" has one answer and one look.
    guard folds(acceptsInput: false) else {
        return presentationModeFail("a rail that cannot take input must fold")
    }
    guard !folds(acceptsInput: true) else {
        return presentationModeFail("a rail that can take input must stay open")
    }
    // Staged blocks are the reason to keep looking at an unfocused
    // workbench, and a folded toolbar cannot show them.
    guard !folds(acceptsInput: false, staged: true) else {
        return presentationModeFail("staged blocks must survive losing focus")
    }
    guard !folds(acceptsInput: false, music: true) else {
        return presentationModeFail("the music surface must not fold")
    }
    guard BufferWindowGeometry.height(expanded: true, railFolded: true)
            == BufferWindowGeometry.toolbarOnlyHeight,
          BufferWindowGeometry.height(expanded: true, railFolded: true)
            < BufferWindowGeometry.height(expanded: true) else {
        return presentationModeFail("a folded panel must be toolbar-height")
    }

    // The question that was not being asked. Opening the workbench when the
    // input method was already third-party involves no mode transition, and
    // focus used to be claimed only on one — so the panel came up
    // ordered-front but never key.
    func claims(_ mode: BufferPresentationMode,
                visible: Bool = true,
                alreadyFocused: Bool = false,
                music: Bool = false,
                protected: Bool = false,
                hidden: Bool = false,
                secure: Bool = false) -> Bool {
        BufferComposingFocusRules.shouldClaimFocus(
            mode: mode, isVisible: visible, musicSelected: music,
            sessionProtected: protected, hiddenForSession: hidden,
            secureInput: secure, alreadyFocused: alreadyFocused
        )
    }
    guard claims(.standaloneField) else {
        return presentationModeFail("a visible standalone workbench must claim focus")
    }
    guard !claims(.integratedRime) else {
        return presentationModeFail("the integrated mode must never take focus")
    }
    // Repeated refreshes must not fight the user's caret once it is theirs.
    guard !claims(.standaloneField, alreadyFocused: true) else {
        return presentationModeFail("focus must not be reclaimed once held")
    }
    for (label, blocked) in [
        ("hidden", claims(.standaloneField, visible: false)),
        ("music", claims(.standaloneField, music: true)),
        ("protected", claims(.standaloneField, protected: true)),
        ("session-hidden", claims(.standaloneField, hidden: true)),
        ("secure input", claims(.standaloneField, secure: true)),
    ] where blocked {
        return presentationModeFail("focus claimed while \(label)")
    }

    // Focus, for real, in a key window. Every assertion above passes on a
    // panel that is never made key — which is exactly the state that shipped:
    // a visible field that could take nothing, because show() orders the
    // panel front regardless and never makes it key.
    let host = FocusProbePanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 40),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    let railInWindow = BufferInlineView(
        frame: NSRect(x: 0, y: 0, width: 520, height: 32)
    )
    host.contentView?.addSubview(railInWindow)
    railInWindow.setComposingFieldEnabled(true)
    railInWindow.renderStandaloneFieldForPreview()
    host.makeKeyAndOrderFront(nil)
    defer { host.orderOut(nil) }
    guard host.isKeyWindow else {
        return presentationModeFail(
            "a borderless nonactivating panel must be able to become key"
        )
    }
    guard railInWindow.focusComposingField(),
          railInWindow.composingFieldHasFocus else {
        return presentationModeFail(
            "the composing field must take first responder in a key window"
        )
    }
    // And must not claim focus once the mode is left.
    railInWindow.setComposingFieldEnabled(false)
    guard !railInWindow.composingFieldHasFocus else {
        return presentationModeFail("a disabled field must not hold focus")
    }

    // Locally typed text is still local typing: it mirrors to a paired Mac
    // like a Rime commit, and stays unbadged because it is ordinary use.
    let local = Origin.localInput(inputSourceID: "com.apple.inputmethod.SCIM")
    guard local.allowsRemoteMirror,
          local.tag == "local:com.apple.inputmethod.SCIM",
          Origin.rime.allowsRemoteMirror else {
        return presentationModeFail("local input provenance")
    }

    print("presentation mode smoke: OK")
    return true
}

/// Only available when running from the checkout; a shipped binary skips the
/// boundary check rather than failing on a tree it cannot see.
private func presentationModeSourceRoot() -> URL? {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    // #filePath points at Sources/RimeBuffer when built from the repository.
    guard FileManager.default.fileExists(atPath: candidate.path) else {
        return nil
    }
    // Guard against a stale absolute path from another machine's build.
    let marker = candidate.appendingPathComponent("BufferPresentationMode.swift")
    guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
    candidate.standardize()
    return candidate
}

private func presentationModeFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}


/// A panel that may become key, standing in for the workbench's own. The
/// default for a borderless window is to refuse, which is the behaviour the
/// real panel overrides.
private final class FocusProbePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
