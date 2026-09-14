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
/// What activating a clipboard card should do.
enum ClipboardActivationPolicy: String, CaseIterable {
    /// Restore the pasteboard and press ⌘V into the app the user came from.
    case pasteIntoApp
    /// Restore the pasteboard and stop. Nothing is typed anywhere and the
    /// front application never changes.
    case clipboardOnly

    var displayName: String {
        switch self {
        case .pasteIntoApp: return "自动粘贴到目标应用"
        case .clipboardOnly: return "仅写入剪贴板"
        }
    }
}

/// Why a paste did not happen, so the caller can say so instead of leaving
/// the user to discover it.
enum ClipboardAutoPasteOutcome: Equatable {
    case pasted
    case clipboardOnlyByChoice
    case blockedWithoutAccessibility
    case blockedBySecureInput
    case targetUnavailable
}

enum ClipboardAutoPaste {
    private static let defaultsKey = "clipboard.autoPaste.v1"
    private static let policyKey = "clipboard.activationPolicy.v1"

    /// The front application has to have come back before ⌘V is posted, or
    /// the key lands on a panel that is still up. A fixed delay guessed at
    /// that; these bound a wait for the real thing instead.
    private static let settleDelay: TimeInterval = 0.05
    private static let frontmostPollInterval: TimeInterval = 0.03
    private static let frontmostTimeout: TimeInterval = 0.9

    static var policy: ClipboardActivationPolicy {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: policyKey),
               let stored = ClipboardActivationPolicy(rawValue: raw) {
                return stored
            }
            // Honour the older boolean so an existing preference is not
            // silently reversed by the upgrade.
            if defaults.object(forKey: defaultsKey) != nil {
                return defaults.bool(forKey: defaultsKey)
                    ? .pasteIntoApp
                    : .clipboardOnly
            }
            return .pasteIntoApp
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: policyKey)
            UserDefaults.standard.set(newValue == .pasteIntoApp,
                                      forKey: defaultsKey)
        }
    }

    /// Defaults to on: the whole point is that the user does not repeat the
    /// paste manually.
    static var enabled: Bool {
        get { policy == .pasteIntoApp }
        set { policy = newValue ? .pasteIntoApp : .clipboardOnly }
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
    /// call unconditionally; it reports what it did and does nothing else.
    ///
    /// `target` is the application that was front when the clipboard opened.
    /// Waiting for it to be front again is what makes this reliable: closing
    /// a panel is asynchronous, and a fixed delay either fires too early —
    /// pasting into nothing — or wastes time on every activation.
    static func pasteAfterWindowClose(
        target: NSRunningApplication? = nil,
        completion: ((ClipboardAutoPasteOutcome) -> Void)? = nil
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard policy == .pasteIntoApp else {
            IMELog.write("clipboard activation: clipboard-only by choice")
            completion?(.clipboardOnlyByChoice)
            return
        }
        guard isPermitted else {
            IMELog.write(
                "clipboard auto-paste skipped: no accessibility grant; "
                    + "pasteboard is prepared for ⌘V"
            )
            completion?(.blockedWithoutAccessibility)
            return
        }
        guard !IsSecureEventInputEnabled() else {
            IMELog.write("clipboard auto-paste skipped: secure input")
            completion?(.blockedBySecureInput)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
            waitForFrontmost(target: target,
                             deadline: Date().addingTimeInterval(frontmostTimeout),
                             completion: completion)
        }
    }

    /// Polls until the intended application is front again. Without a target
    /// it waits only for our own panel to stop being front, which is the most
    /// that can be checked when the caller did not record where it came from.
    private static func waitForFrontmost(
        target: NSRunningApplication?,
        deadline: Date,
        completion: ((ClipboardAutoPasteOutcome) -> Void)?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !IsSecureEventInputEnabled() else {
            IMELog.write("clipboard auto-paste aborted: secure input armed")
            completion?(.blockedBySecureInput)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ready: Bool
        if let target {
            ready = frontmost?.processIdentifier == target.processIdentifier
        } else {
            ready = frontmost?.processIdentifier
                != ProcessInfo.processInfo.processIdentifier
        }
        if ready {
            post()
            completion?(.pasted)
            return
        }
        guard Date() < deadline else {
            // Post anyway: the pasteboard is correct, the user asked for a
            // paste, and refusing at this point helps nobody. Recorded so a
            // paste that lands in the wrong place is explicable.
            IMELog.write(
                "clipboard auto-paste posting without confirmed frontmost "
                    + "target=\(target?.bundleIdentifier ?? "unknown") "
                    + "front=\(frontmost?.bundleIdentifier ?? "unknown")"
            )
            post()
            completion?(.pasted)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + frontmostPollInterval) {
            waitForFrontmost(target: target,
                             deadline: deadline,
                             completion: completion)
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

/// What to tell the user after activating a card. A silent fallback to the
/// pasteboard is what made this feel unreliable: the gesture looked like it
/// had failed when in fact the content was ready and only the key press was
/// blocked. Naming the reason turns a mystery into a one-time setting.
enum ClipboardActivationFeedback {
    static func message(for outcome: ClipboardAutoPasteOutcome) -> String {
        switch outcome {
        case .pasted:
            return "已粘贴到目标应用"
        case .clipboardOnlyByChoice:
            return "已复制到剪贴板"
        case .blockedWithoutAccessibility:
            return "已复制到剪贴板 · 未获辅助功能权限，无法自动粘贴"
        case .blockedBySecureInput:
            return "已复制到剪贴板 · 密码输入中，未自动粘贴"
        case .targetUnavailable:
            return "已复制到剪贴板 · 未找到目标应用"
        }
    }
}
