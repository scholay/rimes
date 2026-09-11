import AppKit

/// Which process owns the window a global mouse-down landed in. A deferred
/// Buffer click may bind only to the application the user then clicks into,
/// and a click on the Dock or the menu bar belongs to neither.
enum BufferPointerHostRules {
    static func ownerProcessIdentifier(of event: NSEvent) -> pid_t? {
        if event.windowNumber > 0,
           let owner = ownerProcessIdentifier(windowID: CGWindowID(event.windowNumber)) {
            return owner
        }
        return ownerProcessIdentifier(atCocoaPoint: NSEvent.mouseLocation)
    }

    private static func ownerProcessIdentifier(windowID: CGWindowID) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow], windowID
              ) as? [[String: Any]],
              let owner = windows.first?[kCGWindowOwnerPID as String] as? Int else {
            return nil
        }
        return pid_t(owner)
    }

    /// Window-server hit test, front to back, for events that carry no window.
    /// Window bounds are top-left based; Cocoa points are bottom-left based.
    private static func ownerProcessIdentifier(atCocoaPoint point: NSPoint) -> pid_t? {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        let target = CGPoint(x: point.x, y: mainHeight - point.y)
        guard let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let boundsInfo = window[kCGWindowBounds as String],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsInfo as! CFDictionary
                  ),
                  bounds.contains(target),
                  let owner = window[kCGWindowOwnerPID as String] as? Int else {
                continue
            }
            return pid_t(owner)
        }
        return nil
    }
}
