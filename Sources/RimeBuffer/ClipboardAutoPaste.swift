import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Presses ⌘V into the app the user was typing in, so a restored pasteboard
/// lands in their text field instead of waiting for them to paste it by hand.
///
/// This is only the fallback leg of clipboard activation. Complete plain text
/// with an exact focus token is inserted through InputMethodKit and never
/// reaches this path; rich content — HTML, RTF, images, files, colors — has no
/// lossless IMKit primitive, so it is restored to the pasteboard and pasted
/// with a synthetic key press instead.
///
/// macOS drops synthetic key events from processes without the Accessibility
/// grant, so this shares the grant the workbench alignment already asks for
/// and reports in the log when it is missing rather than failing silently.
enum ClipboardAutoPaste {
    private static let defaultsKey = "clipboard.autoPaste.v1"

    /// Delay before the key press. The window has to be off screen and the
    /// previous app key again, or ⌘V lands on a panel that is still up.
    private static let settleDelay: TimeInterval = 0.12

    /// Defaults to on: the whole point is that the user does not repeat the
    /// paste manually. Set `clipboard.autoPaste.v1` to NO to leave the
    /// pasteboard prepared and paste by hand.
    static var enabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: defaultsKey) != nil else { return true }
            return defaults.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// True once the user has granted Accessibility. Never prompts, so no
    /// paste attempt can raise a privacy dialog as a side effect.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    static var isAvailable: Bool { enabled && isPermitted }

    /// Shows the system Accessibility prompt. Only call this from an explicit
    /// user action, never from the paste path.
    @discardableResult
    static func requestPermission() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Schedules the paste for just after the clipboard window closes. Safe to
    /// call unconditionally; it reports why it declined and does nothing else.
    static func pasteAfterWindowClose() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled else {
            IMELog.write(
                "clipboard auto-paste skipped: turned off; pasteboard is "
                    + "prepared for ⌘V"
            )
            return
        }
        guard isPermitted else {
            IMELog.write(
                "clipboard auto-paste skipped: no accessibility grant; "
                    + "pasteboard is prepared for ⌘V"
            )
            return
        }
        guard !IsSecureEventInputEnabled() else {
            IMELog.write("clipboard auto-paste skipped: secure input")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            // Secure input can arm during the settle delay — a password field
            // focused between the close and the key press.
            guard !IsSecureEventInputEnabled() else {
                IMELog.write("clipboard auto-paste aborted: secure input armed")
                return
            }
            post()
        }
    }

    private static func post() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            IMELog.write("clipboard auto-paste failed: no event source")
            return
        }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: v,
                                    keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: v,
                                  keyDown: false) else {
            IMELog.write("clipboard auto-paste failed: could not build ⌘V")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        IMELog.write("clipboard auto-paste posted ⌘V")
    }
}
