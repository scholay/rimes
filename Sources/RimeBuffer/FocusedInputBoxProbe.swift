import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Reads the focused text box through the Accessibility API: its screen frame,
/// so a summoned workbench can line up with the field the user is already in,
/// and its identity, so a Buffer capture is bound to that exact box.
///
/// InputMethodKit reports the caret line and a client, and one client can
/// front many boxes, so the box's geometry and which box it is are only
/// reachable here. The probe is deliberately narrow: it reads role, owning
/// process and geometry, never `AXValue`, never walks the element tree, and
/// never observes other applications. Its one write is Electron's
/// accessibility switch (`ElectronAccessibilityTree`), without which an
/// Electron app exposes no boxes at all. It stays completely inert until the
/// user has granted Accessibility, and it refuses to run under secure input.
/// Callers query it on an already token-validated focus lease.
enum FocusedInputBoxProbe {
    /// Only these roles have a frame that *is* a text box. A window or group
    /// element would contain the caret just as well, so the role allowlist —
    /// not caret containment — is what keeps the workbench from aligning
    /// itself to a whole window.
    private static let textBoxRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
    ]

    /// AX calls block the caller. A short timeout keeps an unresponsive host
    /// from stalling the opening path, which runs on the main queue.
    private static let messagingTimeout: Float = 0.25

    private static let alignmentDefaultsKey = "workbench.alignToInputBox.v1"

    /// Whether the user wants box-aligned openings. Defaults to on so the
    /// feature follows the Accessibility grant rather than needing a second
    /// opt-in, but stays independently switchable from the input-source menu.
    static var alignmentEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: alignmentDefaultsKey) != nil else {
                return true
            }
            return defaults.bool(forKey: alignmentDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: alignmentDefaultsKey) }
    }

    /// True once the user has granted Accessibility. Never prompts: an input
    /// method must not raise a privacy prompt as a side effect of opening its
    /// own panel.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt. Only call this from an explicit
    /// user action, never from the opening path.
    @discardableResult
    static func requestPermission() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// Frame of the focused text box in Cocoa screen coordinates, or nil when
    /// alignment is off, permission is absent, the host exposes no usable text
    /// element, or the element belongs to this input method itself.
    static func focusedBoxFrame() -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard alignmentEnabled,
              let element = focusedTextBox(ownedBy: nil,
                                           timeout: messagingTimeout) else { return nil }
        return copyFrame(element)
    }

    /// Same budget as the opening probe: Electron hosts can be slow to answer.
    /// The box lock asks from a background queue, so a slow answer never
    /// stalls key handling.
    private static let identityMessagingTimeout: Float = 0.25

    /// Why the last `focusedTextBox` call named no box, for the log only: an
    /// Accessibility error code, a role or a process mismatch — never text.
    private(set) static var lastFailureReason: String?

    /// Main-queue form of `probeFocusedTextBox`, for callers already on the
    /// main thread such as the one-off opening alignment.
    static func focusedTextBox(ownedBy processIdentifier: pid_t?,
                               timeout: Float = identityMessagingTimeout) -> AXUIElement? {
        dispatchPrecondition(condition: .onQueue(.main))
        let result = probeFocusedTextBox(ownedBy: processIdentifier, timeout: timeout)
        lastFailureReason = result.failure
        return result.element
    }

    /// One read of the focused text box.
    struct TextBoxReading {
        /// The focused text box, or nil when none can be named.
        var element: AXUIElement?
        /// Why none was named, for the log only.
        var failure: String?
        /// False when the host did not reply within the timeout — typically
        /// while it is busy with text just sent to it — which says nothing
        /// about which box has focus.
        var answered = true
        /// The application answered that nothing in it has focus: it draws
        /// its own controls and exposes no boxes to name.
        var exposesNoBoxes = false
    }

    /// The focused text box as an Accessibility element, for identity only:
    /// role and owning process are read, never the value. It ignores the
    /// alignment preference — the send lock must not hang on a layout option —
    /// and has no queue requirement (its one piece of shared state is behind a
    /// lock), so the box lock can ask from a background queue. A reading
    /// without an element means the box cannot be named; callers treat that
    /// as "not locked" unless the app exposes no boxes at all.
    static func probeFocusedTextBox(ownedBy processIdentifier: pid_t?,
                                    timeout: Float = identityMessagingTimeout)
        -> TextBoxReading {
        guard isPermitted else { return TextBoxReading(failure: "accessibility not granted") }
        guard !IsSecureEventInputEnabled() else { return TextBoxReading(failure: "secure input") }

        // Ask the lease's own application. Chromium hosts (Chrome, Electron
        // apps) refuse the system-wide focus query but answer this one, and it
        // pins the answer to the application the lease names. System surfaces
        // have no named owner and keep the system-wide query.
        let root = processIdentifier.map(AXUIElementCreateApplication)
            ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, timeout)

        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            root,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            // An Electron app reports no focused element until its tree is
            // built. Ask for the tree; until it is ready, this says nothing
            // about which box has focus.
            if result == .noValue, let processIdentifier,
               ElectronAccessibilityTree.isBuilding(processIdentifier,
                                                    application: root) {
                return TextBoxReading(failure: "accessibility tree building",
                                      answered: false)
            }
            // The application itself answered that nothing in it has focus:
            // it draws its own controls and exposes no boxes.
            return TextBoxReading(
                failure: "no focused element (AX \(result.rawValue))",
                answered: result != .cannotComplete,
                exposesNoBoxes: result == .noValue && processIdentifier != nil
            )
        }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)

        // The workbench, candidate panel and capsule are AX elements too.
        // Treating one of our own windows as the target would point the
        // Buffer back at itself.
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID != ProcessInfo.processInfo.processIdentifier,
              processIdentifier.map({ $0 == elementPID }) ?? true else {
            return TextBoxReading(failure: "focused element belongs to another process")
        }

        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        )
        guard roleResult != .cannotComplete else {
            return TextBoxReading(failure: "role unanswered (AX \(roleResult.rawValue))",
                                  answered: false)
        }
        let role = roleRef as? String
        guard let role, textBoxRoles.contains(role) else {
            return TextBoxReading(failure: "focused element is not a text box (\(role ?? "no role"))")
        }
        return TextBoxReading(element: element)
    }

    /// `AXFrame` is one atomic read and already screen-relative, but plenty of
    /// hosts only answer position and size. Try the cheap path, then the
    /// portable one.
    private static func copyFrame(_ element: AXUIElement) -> NSRect? {
        if let frame = copyRectValue(element, "AXFrame") {
            return flippedToCocoa(frame)
        }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionRef
              ) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeRef
              ) == .success,
              let positionRef,
              let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return flippedToCocoa(CGRect(origin: origin, size: size))
    }

    private static func copyRectValue(_ element: AXUIElement,
                                      _ attribute: String) -> CGRect? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &ref
              ) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Accessibility measures from the top-left of the main display with y
    /// growing downward; AppKit measures from its bottom-left with y growing
    /// upward. Both share the same global origin, so one flip about the main
    /// display's height converts the whole multi-monitor arrangement.
    private static func flippedToCocoa(_ rect: CGRect) -> NSRect? {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard mainHeight > 0,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite else { return nil }
        return NSRect(x: rect.origin.x,
                      y: mainHeight - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
    }
}

/// Electron apps keep their Chromium accessibility tree off until an assistive
/// app asks for it through the `AXManualAccessibility` switch on the
/// application element, and until then report no focused element at all — so
/// none of their boxes could ever be locked. The tree takes a few seconds to
/// build after the request (about three for a long Claude conversation).
///
/// Only an app that answers the switch is asked, once per process; the tree
/// then stays on for that process's life, as it does for any assistive app.
enum ElectronAccessibilityTree {
    /// How long "no focused element" still means "not built yet" after the
    /// request.
    static let buildAllowance: TimeInterval = 8

    private static let switchName = "AXManualAccessibility" as CFString
    private static let lock = NSLock()
    private static var requestedAt: [pid_t: TimeInterval] = [:]

    /// True while the tree of `processIdentifier` may still be building:
    /// requested by this call, or less than `buildAllowance` ago. False for an
    /// app without the switch, or one whose tree should long be ready.
    static func isBuilding(_ processIdentifier: pid_t,
                           application: AXUIElement) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if let requested = requestedAt[processIdentifier] {
            return now - requested < buildAllowance
        }
        // Reading the switch tells an Electron app from everything else;
        // nothing else is ever written to.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, switchName, &value) == .success,
              AXUIElementSetAttributeValue(application, switchName, kCFBooleanTrue) == .success
        else { return false }
        requestedAt[processIdentifier] = now
        return true
    }
}
