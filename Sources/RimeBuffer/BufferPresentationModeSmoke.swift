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
