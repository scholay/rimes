import Cocoa
import InputMethodKit

enum HostMarkedTextPresentation: Equatable {
    case none
    case normalPreedit
    case bufferGuard(rimeComposing: Bool)
}

/// Host marked-text policy is deliberately separate from buffer delivery and
/// from Rime's semantic composition state. Chromium-based editors can observe
/// Return or an owned clipboard shortcut before/around IMK's handled result;
/// an idle marked session is what tells those editors that the input method
/// still owns the key.
enum HostMarkedTextPresentationRules {
    static func presentation(bufferControlsActive: Bool,
                             capturesRimeCommits: Bool,
                             rimeComposing: Bool,
                             secureInput: Bool,
                             stagedChordGuardActive: Bool = false) -> HostMarkedTextPresentation {
        guard !secureInput else { return .none }
        // FlyYao stages every current timer batch outside Rime until its
        // settlement boundary. Establish an invisible marked-text session
        // during that interval even when the workbench is off, otherwise
        // hostile fields can observe the physical key before IMK's handled
        // result arrives.
        if stagedChordGuardActive {
            return .bufferGuard(rimeComposing: rimeComposing)
        }
        guard bufferControlsActive else { return .normalPreedit }

        // Persistent capture mirrors preedit at the Buffer's logical caret. A transient
        // buffer keeps ordinary inline preedit while Rime is actually active,
        // but still needs the invisible guard while idle so Return cannot leak.
        if capturesRimeCommits || !rimeComposing {
            return .bufferGuard(rimeComposing: rimeComposing)
        }
        return .normalPreedit
    }

    static func shouldRefreshForActiveChange(previous: Bool, current: Bool) -> Bool {
        previous != current
    }
}

/// The v2 composition protocol: a marked-text session ALWAYS exists while Rime
/// is composing, and an invisible session stays alive while exact external
/// buffer controls are idle. Squirrel-proven — without a session, clients echo
/// raw keystrokes ("zuoye作业" leak, seen in WeChat) and the caret-rect API
/// returns zero. The session's CONTENT is a policy:
///   .inline       marked text = underlined preedit (matches the user's
///                 squirrel.yaml `inline_preedit: true`); default.
///   .placeholder  marked text = one full-width space "　" (Squirrel's trick to
///                 keep hostile fields — iTerm2 etc. — from echoing, while the
///                 preedit renders in our auxiliary composition surface instead).
final class CompositionSession {
    enum Mode: String { case inline, placeholder }

    private let bufferGuardText = "\u{200B}"

    private(set) var markedTextActive = false
    private(set) var composing = false
    private var bufferGuardActive = false

    /// Per-app override table (bundleId -> "placeholder"). Empty by default;
    /// populate as hostile apps are found in the field.
    static func mode(for bundleId: String) -> Mode {
        let overrides = UserDefaults.standard
            .dictionary(forKey: "compositionModeOverrides") as? [String: String]
        return overrides?[bundleId] == Mode.placeholder.rawValue ? .placeholder : .inline
    }

    /// Reflect the current Rime preedit into the client's marked text.
    /// `cursorPosUTF8` is librime's byte offset into the UTF-8 preedit.
    func update(preedit: String, cursorPosUTF8: Int, client: IMKTextInput, mode: Mode) {
        guard !preedit.isEmpty else {
            clear(client: client)
            return
        }
        let replacement = NSRange(location: NSNotFound, length: 0)
        // Host proxy calls may synchronously re-enter the same controller with
        // a newer focus token. Publish this operation's latch before crossing
        // that boundary so a newer reentrant operation remains the final
        // writer when the older call returns.
        markedTextActive = true
        composing = true
        bufferGuardActive = false
        switch mode {
        case .inline:
            let attr = NSMutableAttributedString(string: preedit)
            attr.addAttribute(.underlineStyle,
                              value: NSUnderlineStyle.single.rawValue,
                              range: NSRange(location: 0, length: attr.length))
            let caret = Self.utf16Offset(ofUTF8 : cursorPosUTF8, in: preedit)
            client.setMarkedText(attr,
                                 selectionRange: NSRange(location: caret, length: 0),
                                 replacementRange: replacement)
        case .placeholder:
            client.setMarkedText("　" as NSString,
                                 selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: replacement)
        }
    }

    /// Keep the host field connected to IMK for the full lifetime of exact
    /// external buffer control, including Rime-idle periods. The guard's host
    /// lifetime and Rime's semantic composing state must remain independent:
    /// otherwise an idle Return would only "settle composition" forever.
    func updateBufferGuard(rimeComposing: Bool, client: IMKTextInput) {
        composing = rimeComposing
        // setMarkedText can synchronously enter the host and trigger expensive
        // focus probes. Keep one guard for the whole buffer-control lease
        // instead of replacing it after every physical key.
        if !bufferGuardActive {
            installBufferGuard(client: client)
        }
    }

    /// Reassert the invisible session for the current owned control keyDown.
    /// Some web editors can end marked text without an observable focus
    /// transition, leaving our local guard latch stale. A targeted refresh
    /// makes the same keyDown an explicit IME transaction before its action.
    func reassertBufferGuard(rimeComposing: Bool, client: IMKTextInput) {
        composing = rimeComposing
        installBufferGuard(client: client)
    }

    private func installBufferGuard(client: IMKTextInput) {
        markedTextActive = true
        bufferGuardActive = true
        client.setMarkedText(bufferGuardText as NSString,
                             selectionRange: NSRange(
                                location: (bufferGuardText as NSString).length,
                                length: 0
                             ),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// End the session explicitly (escape / focus loss / commit without insert).
    func clear(client: IMKTextInput) {
        guard markedTextActive else { return }
        // See `update`: clear the old latch before entering the host so a
        // reentrant new composition cannot be overwritten on return.
        markedTextActive = false
        composing = false
        bufferGuardActive = false
        client.setMarkedText("" as NSString,
                             selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// insertText replaces the marked text atomically and closes the session —
    /// record that without sending another setMarkedText.
    func commitDidInsert() {
        markedTextActive = false
        composing = false
        bufferGuardActive = false
    }

    /// Session died with its client (focus already gone); just drop the flag.
    func markCleared() {
        markedTextActive = false
        composing = false
        bufferGuardActive = false
    }

    private static func utf16Offset(ofUTF8 byteOffset: Int, in s: String) -> Int {
        if byteOffset <= 0 { return 0 }
        let bytes = Array(s.utf8.prefix(byteOffset))
        if bytes.count >= s.utf8.count { return (s as NSString).length }
        return String(decoding: bytes, as: UTF8.self).utf16.count
    }
}
