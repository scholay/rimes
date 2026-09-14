import InputMethodKit
import Carbon.HIToolbox
import Foundation

/// The SOLE place text reaches the client. Every commit — ordinary, chord
/// release, or raw fallback — goes through here so ordering is guaranteed.
enum Delivery {
    /// Inserts `text` into `client`, unless macOS secure input is active.
    ///
    /// Secure input (password fields, and any app that opted in) blocks third-
    /// party input methods from *seeing* keystrokes, but it does NOT stop us
    /// pushing already-buffered text into whatever field is focused. This gate
    /// is the security backstop: when secure input is on, refuse to deliver so
    /// buffered content can never land in a password field. It is queried at the
    /// delivery moment (cheap, authoritative) rather than polled.
    ///
    /// Returns whether the text was actually inserted, so the buffer can keep
    /// unsent blocks instead of dropping them (see BufferDeliveryCoordinator).
    /// Does NOT cover apps that draw their own password fields without enabling
    /// secure input — that is out of this backstop's reach.
    @discardableResult
    static func insert(_ text: String, into client: IMKTextInput) -> Bool {
        guard !text.isEmpty else { return true }
        // TIS notifications can trail a real source switch. Recheck at the
        // single client-write sink so a retired RIMES proxy can never receive
        // text after another input method takes ownership.
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            IMELog.write("delivery blocked: RIMES is not the current input source")
            return false
        }
        guard !IsSecureEventInputEnabled() else {
            IMELog.write("delivery blocked: secure input active len=\(text.count)")
            return false
        }
        client.insertText(text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}
