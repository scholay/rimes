import ApplicationServices
import Carbon.HIToolbox
import Cocoa

/// Reads the focused text box's screen frame through the Accessibility API so
/// a summoned workbench can line up with the field the user is already in.
///
/// InputMethodKit reports the caret line and nothing else, so the box's left
/// edge and width are only reachable here. The probe is deliberately narrow:
/// it reads role and geometry, never `AXValue`, never walks the element tree,
/// and never observes other applications. It stays completely inert until the
/// user has granted Accessibility, and it refuses to run under secure input.
/// Callers query it once, at opening time, on an already token-validated
/// focus lease.
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
              isPermitted,
              !IsSecureEventInputEnabled() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedRef
              ) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        // The workbench, candidate panel and capsule are AX elements too.
        // Aligning to one of our own windows would feed the opening geometry
        // straight back into itself.
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID != ProcessInfo.processInfo.processIdentifier else { return nil }

        guard let role = copyString(element, kAXRoleAttribute),
              textBoxRoles.contains(role) else { return nil }
        return copyFrame(element)
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

    private static func copyString(_ element: AXUIElement,
                                   _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &ref
              ) == .success else { return nil }
        return ref as? String
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
