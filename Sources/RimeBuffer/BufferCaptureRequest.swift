import Foundation

/// What a click on the Buffer rail should do.
///
/// Capture is bound to one exact host lease, and the Buffer is a proxy for
/// that field rather than a window of its own — the panel never becomes key,
/// so "focus the Buffer" means "route this field's keys here". That makes a
/// click meaningless while no trusted field owns a lease, which happens
/// routinely: switching applications retires the old lease, and the new one
/// does not exist until IMK activates a field there.
///
/// The old behaviour treated every failed request the same way — revoke the
/// route and beep — which produced the two symptoms worth naming. A click
/// arriving a moment before the new lease dropped the user's intent entirely,
/// and a click while capture was already held could revoke a route that was
/// still perfectly valid.
enum BufferCaptureRequestDecision: Equatable {
    /// A trusted lease exists; bind the route to it.
    case grant
    /// Validation failed, but the route currently held is still bound to a
    /// live token. Revoking here is what made a second click lose the Buffer.
    case keepExistingCapture
    /// Nothing to capture for yet. Remember the intent and bind it as soon as
    /// a trusted field appears, rather than making the user click twice.
    case awaitTarget
    /// The route points at something that no longer exists.
    case revoke
}

enum BufferCaptureRequestRules {
    static func decision(hasTrustedLease: Bool,
                         holdsCaptureRoute: Bool,
                         captureTokenIsLive: Bool) -> BufferCaptureRequestDecision {
        if hasTrustedLease { return .grant }
        if holdsCaptureRoute {
            return captureTokenIsLive ? .keepExistingCapture : .revoke
        }
        return .awaitTarget
    }
}

/// A remembered click, waiting for a field to attach to.
///
/// Bounded in time on purpose: an intent that outlived the gesture would
/// hijack whichever field the user focused minutes later, which is worse than
/// dropping it. The window is long enough to cover an application switch and
/// short enough that the user still associates it with the click they made.
struct BufferPendingCaptureRequest: Equatable {
    static let lifetime: TimeInterval = 6

    let insertionIndex: Int
    let requestedAt: Date
    /// Which application this request is allowed to bind to, when it was
    /// armed to survive one specific host losing its input session. A plain
    /// deferred click leaves it nil and binds to the application the user
    /// then clicks into. A re-arm is different: it exists to restore a route
    /// that already existed, so binding it to a *different* application would
    /// silently capture typing the user never pointed at the Buffer.
    var expectedBundleID: String?
    /// The process whose window the user clicked after the request was armed.
    /// Switching applications activates *a* field there — usually the one
    /// focused last — and that is not a box the user chose.
    var hostPointerProcessIdentifier: pid_t?

    func isLive(at moment: Date,
                lifetime: TimeInterval = lifetime) -> Bool {
        let elapsed = moment.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed < lifetime
    }

    func accepts(bundleID: String?) -> Bool {
        guard let expectedBundleID else { return true }
        return expectedBundleID == bundleID
    }

    /// A plain deferred click binds only after the user has clicked into that
    /// application; an application switch alone never completes it. A re-arm
    /// is held to its application by `accepts(bundleID:)` instead.
    func mayBind(toProcess processIdentifier: pid_t) -> Bool {
        guard expectedBundleID == nil else { return true }
        return hostPointerProcessIdentifier == processIdentifier
    }
}
