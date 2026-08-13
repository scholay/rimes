import Cocoa
import InputMethodKit

/// Monotonic identity for one focused IMK client. A token becomes permanently
/// stale as soon as another client is observed, even when both clients belong
/// to the same application.
struct FocusToken: Hashable, CustomStringConvertible {
    fileprivate let generation: UInt64

    var description: String { "focus-\(generation)" }
}

/// Most IMK clients are ordinary activating applications, so their client
/// bundle/PID must exactly match `NSWorkspace.frontmostApplication`. A small
/// number of explicitly trusted nonactivating surfaces are hosted out of process
/// and leave the application underneath them frontmost. Keep those exceptions
/// bundle/path verified instead of weakening the foreground gate for every
/// accessory application or XPC service.
enum FocusHostKind: Equatable {
    case frontmostApplication
    case nonactivatingSystemOverlay
    /// AppKit's open/save ViewService owns the IMK client while its window is
    /// composited under the initiating frontmost application's PID.
    case appKitOpenSavePanel

    var requiresTransientSurfaceAuthority: Bool {
        self != .frontmostApplication
    }

    var permitsPendingModifierBaselineSync: Bool {
        self == .nonactivatingSystemOverlay
    }
}

struct FocusHostResolution: Equatable {
    let kind: FocusHostKind
    let clientProcessIdentifier: pid_t
    let foregroundAnchorBundleID: String?
    let foregroundAnchorProcessIdentifier: pid_t?
}

enum FocusHostRules {
    private static let trustedNonactivatingSystemOverlayPaths = [
        "com.apple.Spotlight": "/System/Library/CoreServices/Spotlight.app",
        // Paste is an LSUIElement app whose search field owns the IMK client
        // without becoming NSWorkspace's frontmost application. It has no stable
        // TeamIdentifier on the observed release, so its narrow trust identity is
        // exact bundle + canonical install path + unique live PID + visible
        // WindowServer surface; the latter gates remain enforced at runtime.
        "com.wiheads.paste": "/Applications/Paste.app",
    ]
    private static let trustedAppKitOpenSavePanelPaths = [
        "com.apple.appkit.xpc.openAndSavePanelService":
            "/System/Library/Frameworks/AppKit.framework/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc",
    ]

    static func isNonactivatingSystemOverlayBundle(_ bundleID: String) -> Bool {
        trustedNonactivatingSystemOverlayPaths[bundleID] != nil
    }

    static func isAppKitOpenSavePanelBundle(_ bundleID: String) -> Bool {
        trustedAppKitOpenSavePanelPaths[bundleID] != nil
    }

    static func isTransientSystemSurfaceBundle(_ bundleID: String) -> Bool {
        isNonactivatingSystemOverlayBundle(bundleID)
            || isAppKitOpenSavePanelBundle(bundleID)
    }

    static func mayUseOrdinaryProcessBoundFallback(_ bundleID: String) -> Bool {
        !isTransientSystemSurfaceBundle(bundleID)
    }

    private static func trustedPathMatches(bundleID: String,
                                           bundlePath: String?,
                                           allowlist: [String: String]) -> Bool {
        guard let expectedPath = allowlist[bundleID],
              let bundlePath else { return false }
        let actual = URL(fileURLWithPath: bundlePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let expected = URL(fileURLWithPath: expectedPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return actual == expected
    }

    static func isTrustedNonactivatingSystemOverlay(bundleID: String,
                                                     bundlePath: String?) -> Bool {
        trustedPathMatches(
            bundleID: bundleID,
            bundlePath: bundlePath,
            allowlist: trustedNonactivatingSystemOverlayPaths
        )
    }

    static func isTrustedAppKitOpenSavePanel(bundleID: String,
                                             bundlePath: String?) -> Bool {
        trustedPathMatches(
            bundleID: bundleID,
            bundlePath: bundlePath,
            allowlist: trustedAppKitOpenSavePanelPaths
        )
    }

    static func uniqueTrustedOverlayProcessIdentifier(
        bundleID: String,
        runningCandidates: [(processIdentifier: pid_t, bundlePath: String?)]
    ) -> pid_t? {
        // Count every live process with this bundle identifier before checking
        // its path. A second genuine or spoofed instance makes the identity
        // ambiguous rather than being filtered out and silently ignored.
        guard runningCandidates.count == 1,
              let candidate = runningCandidates.first,
              isTrustedNonactivatingSystemOverlay(
                bundleID: bundleID,
                bundlePath: candidate.bundlePath
              ) else { return nil }
        return candidate.processIdentifier
    }

    /// Open/save ViewServices can leave multiple genuine idle processes alive.
    /// Do not guess which one backs the opaque IMK proxy. Instead require at
    /// least one instance and reject the whole class if any same-ID process is
    /// outside Apple's sealed system path.
    static func allSystemPanelProcessesAreTrusted(
        bundleID: String,
        runningCandidates: [(processIdentifier: pid_t, bundlePath: String?)]
    ) -> Bool {
        guard !runningCandidates.isEmpty,
              isAppKitOpenSavePanelBundle(bundleID) else {
            return false
        }
        return runningCandidates.allSatisfy {
            isTrustedAppKitOpenSavePanel(
                bundleID: bundleID,
                bundlePath: $0.bundlePath
            )
        }
    }

    /// Resolve the two identities that a focus lease needs. Classify every
    /// special bundle before the ordinary frontmost-app path so an accidental
    /// or spoofed foreground report cannot bypass the exact system-path gate.
    static func resolveKnownFrontmost(incomingBundleID: String,
                                      frontmostBundleID: String,
                                      frontmostProcessIdentifier: pid_t,
        trustedOverlayProcessIdentifier: pid_t?,
        trustedSystemPanelAvailable: Bool = false) -> FocusHostResolution? {
        if isNonactivatingSystemOverlayBundle(incomingBundleID) {
            guard incomingBundleID != frontmostBundleID,
                  let trustedOverlayProcessIdentifier else { return nil }
            return FocusHostResolution(
                kind: .nonactivatingSystemOverlay,
                clientProcessIdentifier: trustedOverlayProcessIdentifier,
                foregroundAnchorBundleID: frontmostBundleID,
                foregroundAnchorProcessIdentifier: frontmostProcessIdentifier
            )
        }
        if isAppKitOpenSavePanelBundle(incomingBundleID) {
            guard incomingBundleID != frontmostBundleID,
                  trustedSystemPanelAvailable else { return nil }
            // WindowServer attributes the remote panel to the initiating app,
            // not to any one of the potentially many ViewService processes.
            // This PID is therefore the frozen authority PID, not the service
            // process that owns the opaque IMK proxy.
            return FocusHostResolution(
                kind: .appKitOpenSavePanel,
                clientProcessIdentifier: frontmostProcessIdentifier,
                foregroundAnchorBundleID: frontmostBundleID,
                foregroundAnchorProcessIdentifier: frontmostProcessIdentifier
            )
        }
        if incomingBundleID == frontmostBundleID {
            return FocusHostResolution(
                kind: .frontmostApplication,
                clientProcessIdentifier: frontmostProcessIdentifier,
                foregroundAnchorBundleID: frontmostBundleID,
                foregroundAnchorProcessIdentifier: frontmostProcessIdentifier
            )
        }
        return nil
    }

    static func callbackMayUseResolution(kind: FocusHostKind,
                                         explicitActivation: Bool,
                                         eventCanEstablishTransientSurface: Bool,
                                         continuesExactLease: Bool,
                                         trustedSurfaceAuthority: Bool) -> Bool {
        switch kind {
        case .frontmostApplication:
            return true
        case .nonactivatingSystemOverlay,
             .appKitOpenSavePanel:
            // An explicit lifecycle callback may create only a suspended lease
            // before the surface is ordered. Events require its verified
            // frozen window to be on screen.
            return explicitActivation
                || (trustedSurfaceAuthority
                    && (eventCanEstablishTransientSurface
                        || continuesExactLease))
        }
    }

    static func resolutionMatchesLease(_ resolution: FocusHostResolution,
                                       hostKind: FocusHostKind,
                                       clientProcessIdentifier: pid_t,
                                       foregroundAnchorBundleID: String?,
                                       foregroundAnchorProcessIdentifier: pid_t?) -> Bool {
        let anchorBundleMatches = resolution.foregroundAnchorBundleID
            == foregroundAnchorBundleID
            || (hostKind == .frontmostApplication
                && foregroundAnchorBundleID == nil
                && resolution.foregroundAnchorProcessIdentifier
                    == foregroundAnchorProcessIdentifier)
        return resolution.kind == hostKind
            && resolution.clientProcessIdentifier == clientProcessIdentifier
            && anchorBundleMatches
            && resolution.foregroundAnchorProcessIdentifier
                == foregroundAnchorProcessIdentifier
    }

    static func applicationAuthorityMatches(
        kind: FocusHostKind,
        leaseBundleID: String,
        leaseProcessIdentifier: pid_t,
        foregroundAnchorBundleID: String?,
        foregroundAnchorProcessIdentifier: pid_t?,
        currentFrontmostBundleID: String?,
        currentFrontmostProcessIdentifier: pid_t?,
        currentTrustedOverlayProcessIdentifier: pid_t?,
        trustedSurfaceAuthority: Bool
    ) -> (bundle: Bool, process: Bool) {
        switch kind {
        case .frontmostApplication:
            return (
                currentFrontmostBundleID.map { $0 == leaseBundleID } ?? true,
                currentFrontmostProcessIdentifier == leaseProcessIdentifier
            )
        case .nonactivatingSystemOverlay:
            let overlayProcessMatches = trustedSurfaceAuthority
                && currentTrustedOverlayProcessIdentifier == leaseProcessIdentifier
            let anchorBundleMatches = currentFrontmostBundleID.map {
                $0 == foregroundAnchorBundleID
            } ?? (currentFrontmostProcessIdentifier
                    == foregroundAnchorProcessIdentifier)
            return (
                overlayProcessMatches
                    && foregroundAnchorBundleID != nil
                    && anchorBundleMatches,
                overlayProcessMatches
                    && foregroundAnchorProcessIdentifier != nil
                    && currentFrontmostProcessIdentifier == foregroundAnchorProcessIdentifier
            )
        case .appKitOpenSavePanel:
            let anchorBundleMatches = currentFrontmostBundleID.map {
                $0 == foregroundAnchorBundleID
            } ?? (currentFrontmostProcessIdentifier
                    == foregroundAnchorProcessIdentifier)
            return (
                trustedSurfaceAuthority
                    && foregroundAnchorBundleID != nil
                    && anchorBundleMatches,
                trustedSurfaceAuthority
                    && foregroundAnchorProcessIdentifier != nil
                    && currentFrontmostProcessIdentifier
                        == foregroundAnchorProcessIdentifier
                    && leaseProcessIdentifier
                        == foregroundAnchorProcessIdentifier
            )
        }
    }

    static func frontmostChangeInvalidatesLease(
        hostKind: FocusHostKind,
        leaseBundleID: String,
        leaseProcessIdentifier: pid_t,
        foregroundAnchorBundleID: String?,
        foregroundAnchorProcessIdentifier: pid_t?,
        activatedBundleID: String?,
        activatedProcessIdentifier: pid_t?
    ) -> Bool {
        // These out-of-process system surfaces never become frontmost. Any
        // later workspace activation — including the anchor app becoming
        // active again — is a fail-closed signal that the lease must retire.
        if hostKind != .frontmostApplication { return true }
        let expectedBundleID = foregroundAnchorBundleID ?? leaseBundleID
        let expectedProcessIdentifier = foregroundAnchorProcessIdentifier
            ?? leaseProcessIdentifier
        let bundleChanged = activatedBundleID.map { $0 != expectedBundleID } ?? false
        return bundleChanged || activatedProcessIdentifier != expectedProcessIdentifier
    }

    static func displacedLeaseRequiresNoClientCleanup(
        hostKind: FocusHostKind
    ) -> Bool {
        // Replacing a nonactivating overlay means the destination is no longer
        // authoritative. Its proxy may still be alive but must not be called.
        hostKind != .frontmostApplication
    }

    static func shouldSuspendNewLease(
        kind: FocusHostKind,
        explicitActivation: Bool
    ) -> Bool {
        kind.requiresTransientSurfaceAuthority && explicitActivation
    }

    static func shouldPreservePendingPreheatAfterRejectedCallback(
        kind: FocusHostKind,
        reusesExactOwner: Bool,
        resolutionMatchesOwner: Bool,
        deliverySuspended: Bool,
        awaitingKeyDown: Bool
    ) -> Bool {
        kind.requiresTransientSurfaceAuthority
            && reusesExactOwner
            && resolutionMatchesOwner
            && deliverySuspended
            && awaitingKeyDown
    }

}

struct FocusWindowSnapshot: Equatable {
    let windowNumber: CGWindowID
    let ownerProcessIdentifier: pid_t
    let layer: Int
    let alpha: Double
}

struct FocusSystemPanelWindowAuthority: Equatable {
    let trusted: Bool
    let pendingWindowNumber: CGWindowID?
}

/// WindowServer attributes AppKit's remote open/save panel to the initiating
/// frontmost application, not to the ViewService process that owns the IMK
/// proxy. Freeze the frontmost eligible anchor window on the first fresh
/// keyDown, then require that exact window number for every later interaction.
enum FocusSystemPanelWindowRules {
    static func frontmostWindowNumber(
        anchorProcessIdentifier: pid_t,
        orderedWindows: [FocusWindowSnapshot]
    ) -> CGWindowID? {
        orderedWindows.first {
            $0.ownerProcessIdentifier == anchorProcessIdentifier
                && $0.layer == 0
                && $0.alpha > 0
        }?.windowNumber
    }

    static func windowRemainsTrusted(
        _ windowNumber: CGWindowID,
        anchorProcessIdentifier: pid_t,
        onScreenWindows: [FocusWindowSnapshot]
    ) -> Bool {
        onScreenWindows.contains {
            $0.windowNumber == windowNumber
                && $0.ownerProcessIdentifier == anchorProcessIdentifier
                && $0.layer == 0
                && $0.alpha > 0
        }
    }

    /// Resolve window authority for an exact existing open/save lease. A
    /// previously frozen window is monotonic: if it disappears, a new topmost
    /// anchor window must not replace it. Only a lease that has never frozen a
    /// window may capture the current candidate on a fresh keyDown.
    static func authorityForExistingLease(
        frozenWindowNumber: CGWindowID?,
        frozenWindowRemainsTrusted: Bool,
        deliverySuspended: Bool,
        eventCanEstablishTransientSurface: Bool,
        candidateWindowNumber: CGWindowID?
    ) -> FocusSystemPanelWindowAuthority {
        if let frozenWindowNumber {
            guard frozenWindowRemainsTrusted else {
                return FocusSystemPanelWindowAuthority(
                    trusted: false,
                    pendingWindowNumber: nil
                )
            }
            return FocusSystemPanelWindowAuthority(
                trusted: true,
                pendingWindowNumber: eventCanEstablishTransientSurface
                        ? frozenWindowNumber
                        : nil
            )
        }
        guard deliverySuspended,
              eventCanEstablishTransientSurface,
              let candidateWindowNumber else {
            return FocusSystemPanelWindowAuthority(
                trusted: false,
                pendingWindowNumber: nil
            )
        }
        return FocusSystemPanelWindowAuthority(
            trusted: true,
            pendingWindowNumber: candidateWindowNumber
        )
    }
}

/// Pure epoch state used by the runtime coordinator and the CLI smoke test.
struct FocusEpochState {
    private(set) var generation: UInt64 = 0
    private(set) var current: FocusToken?

    mutating func activate() -> FocusToken {
        generation &+= 1
        let token = FocusToken(generation: generation)
        current = token
        return token
    }

    @discardableResult
    mutating func deactivate(_ token: FocusToken) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    func isCurrent(_ token: FocusToken) -> Bool {
        current == token
    }
}

/// Pure eligibility gate shared by the runtime and the CLI smoke test. Keeping
/// every condition visible in one predicate makes it hard to accidentally
/// reintroduce a "recent client" fallback while evolving IMK callbacks.
enum FocusTargetRules {
    static func shouldPruneExpiredLease(controllerAlive: Bool,
                                        clientAlive: Bool) -> Bool {
        !controllerAlive || !clientAlive
    }

    static func requiresNoClientCleanup(controllerAlive: Bool,
                                        clientAlive: Bool) -> Bool {
        controllerAlive && !clientAlive
    }

    static func identifiesExternalTarget(bundleID: String,
                                          processIdentifier: pid_t,
                                          ownBundleID: String,
                                          ownProcessIdentifier: pid_t) -> Bool {
        bundleID != ownBundleID && processIdentifier != ownProcessIdentifier
    }

    static func allows(tokenIsCurrent: Bool,
                       expectedTokenMatches: Bool,
                       externalTarget: Bool,
                       deliveryTrusted: Bool,
                       controllerAlive: Bool,
                       clientAlive: Bool,
                       clientIdentityMatches: Bool,
                       controllerClientIdentityMatches: Bool,
                       clientBundleMatches: Bool,
                       frontmostApplicationMatches: Bool,
                       frontmostProcessMatches: Bool) -> Bool {
        tokenIsCurrent
            && expectedTokenMatches
            && externalTarget
            && deliveryTrusted
            && controllerAlive
            && clientAlive
            && clientIdentityMatches
            && controllerClientIdentityMatches
            && clientBundleMatches
            && frontmostApplicationMatches
            && frontmostProcessMatches
    }
}

enum FocusEventRules {
    static let nonactivatingOverlayEventFreshnessWindow: TimeInterval = 1.0

    static func isOrdered(_ eventTimestamp: TimeInterval,
                          activationFloor: TimeInterval?,
                          lastAccepted: TimeInterval?) -> Bool {
        let epsilon = 0.000_001
        if let activationFloor, eventTimestamp + epsilon < activationFloor { return false }
        if let lastAccepted, eventTimestamp + epsilon < lastAccepted { return false }
        return true
    }

    static func isFreshNonactivatingOverlayEvent(_ eventTimestamp: TimeInterval,
                                                  now: TimeInterval) -> Bool {
        let age = now - eventTimestamp
        return age >= -0.000_001 && age <= nonactivatingOverlayEventFreshnessWindow
    }

    static func mayTakeOwnership(incomingBundleID: String,
                                 currentOwnerBundleID: String,
                                 frontmostBundleID: String?,
                                 incomingHostKind: FocusHostKind) -> Bool {
        if incomingHostKind != .frontmostApplication { return true }
        guard let frontmostBundleID else {
            return incomingBundleID == currentOwnerBundleID
        }
        return incomingBundleID == frontmostBundleID
    }

    /// A missing frontmost bundle may continue an exact lease or use a client
    /// proxy whose PID was frozen by an earlier bundle-verified callback. The
    /// frontmost PID alone is not provenance: binding an unknown proxy to it can
    /// poison every later callback from that proxy.
    static func mayUseOrdinaryProcessBoundResolution(
        ownerExists: Bool,
        reusesExactOwner: Bool,
        frontmostProcessIdentifier: pid_t?,
        knownClientProcessIdentifier: pid_t?
    ) -> Bool {
        if reusesExactOwner { return true }
        guard let frontmostProcessIdentifier else { return false }
        // Preserve first-key compatibility while NSWorkspace is between app
        // records, but treat this as provisional authority: the caller must not
        // cache this inferred binding until a later exact bundle/PID match.
        if !ownerExists && knownClientProcessIdentifier == nil { return true }
        guard let knownClientProcessIdentifier else { return false }
        return knownClientProcessIdentifier == frontmostProcessIdentifier
    }

    /// Persist only identities established by a positive bundle/path check.
    /// AppKit open/save proxies are deliberately never process-cached because
    /// their frozen authority PID belongs to the initiating app, not the proxy.
    static func mayCacheClientProcess(
        hostKind: FocusHostKind,
        resolvedIdentityWasVerified: Bool
    ) -> Bool {
        resolvedIdentityWasVerified && hostKind != .appKitOpenSavePanel
    }

    static func verifiedIdentityRequiresFreshEpoch(
        reusesExactOwner: Bool,
        ownerProcessIdentityWasVerified: Bool,
        resolvedIdentityWasVerified: Bool
    ) -> Bool {
        reusesExactOwner
            && !ownerProcessIdentityWasVerified
            && resolvedIdentityWasVerified
    }

    static func mayRebindKnownClientProcess(
        hostKind: FocusHostKind,
        resolvedIdentityWasVerified: Bool
    ) -> Bool {
        hostKind == .frontmostApplication && resolvedIdentityWasVerified
    }
}

enum FocusActivationRules {
    static let provisionalConfirmationWindow: TimeInterval = 0.25
    static let nonactivatingOverlayProvisionalConfirmationWindow: TimeInterval = 2.0
    static let reusedClientLifecycleSuppressionWindow: TimeInterval = 0.25
    static let reusedClientPostKeyDownSuppressionWindow: TimeInterval = 0.5
    static let ambiguousLifecycleMinimumAge: TimeInterval = 0.08

    static func shouldConfirmProvisional(isProvisional: Bool,
                                         sameControllerAndClient: Bool,
                                         age: TimeInterval,
                                         hostKind: FocusHostKind = .frontmostApplication) -> Bool {
        let confirmationWindow = hostKind != .frontmostApplication
            ? nonactivatingOverlayProvisionalConfirmationWindow
            : provisionalConfirmationWindow
        return isProvisional
            && sameControllerAndClient
            && age >= 0
            && age <= confirmationWindow
    }

    static func lifecycleCallbackMayApply(now: TimeInterval,
                                          suppressionUntil: TimeInterval,
                                          leaseAge: TimeInterval,
                                          senderIsExplicit: Bool,
                                          clientIdentityWasReused: Bool) -> Bool {
        // A reused identity remains ambiguous until a fully validated keyDown
        // clears the lease's latch. Time alone must never make an old field's
        // delayed deactivate authoritative.
        guard !clientIdentityWasReused else { return false }
        guard now >= suppressionUntil else { return false }
        return senderIsExplicit || leaseAge >= ambiguousLifecycleMinimumAge
    }

    /// Called only after the coordinator has accepted the event through its
    /// controller/client, app/PID, host authority and monotonic timestamp gates.
    /// keyUp/flagsChanged cannot prove which field owns a reused IMK proxy.
    static func acceptedEventConfirmsReusedClientLifecycle(
        eventType: NSEvent.EventType?
    ) -> Bool {
        eventType == .keyDown
    }

    static func suppressionDeadlineAfterConfirmedKeyDown(
        current: TimeInterval,
        confirmationUptime: TimeInterval
    ) -> TimeInterval {
        max(
            current,
            confirmationUptime + reusedClientPostKeyDownSuppressionWindow
        )
    }

    static func currentControllerClientMayApply(clientExists: Bool,
                                                 identityMatches: Bool) -> Bool {
        clientExists && identityMatches
    }

    static func mayContinueExactLeaseWithoutBundle(forceNewEpoch: Bool,
                                                    eventRequiresFreshEpoch: Bool) -> Bool {
        !forceNewEpoch && !eventRequiresFreshEpoch
    }

    static func eventRevealsFieldChange(hasEvent: Bool,
                                        reusesExactOwner: Bool,
                                        compositionActive: Bool,
                                        markedRangeReliable: Bool,
                                        markedRangeWasObservable: Bool,
                                        markedRangeIsMissing: Bool) -> Bool {
        hasEvent
            && reusesExactOwner
            && compositionActive
            && markedRangeReliable
            && markedRangeWasObservable
            && markedRangeIsMissing
    }
}

/// Runtime lease for the currently focused IMK client. References stay on the
/// main thread and are weak so a hostile host that omits deactivateServer cannot
/// keep an old controller/client alive forever.
final class FocusLease {
    let token: FocusToken
    weak var controller: RimeBufferController?
    weak var client: IMKTextInput?
    let clientIdentity: ObjectIdentifier
    let bundleID: String
    let processIdentifier: pid_t
    let hostKind: FocusHostKind
    let foregroundAnchorBundleID: String?
    let foregroundAnchorProcessIdentifier: pid_t?
    let isExternalTarget: Bool
    var activationEventFloor: TimeInterval?
    var lastAcceptedEventTimestamp: TimeInterval?
    var provisionalFromEvent: Bool
    let createdAtUptime: TimeInterval
    var lifecycleSuppressionUntilUptime: TimeInterval
    /// Safety latch, not merely history. It starts true when IMK reuses a proxy
    /// across epochs and is cleared only by a fully accepted keyDown. Until then
    /// lifecycle callbacks with that identity remain unattributable.
    var clientIdentityWasReused: Bool
    /// False only for a compatibility lease created while NSWorkspace exposed a
    /// frontmost PID but no bundle. It can handle the current key without being
    /// persisted as proxy/PID truth; exact bundle evidence replaces its epoch.
    let processIdentityWasVerified: Bool
    var deliverySuspended = false
    var awaitingSystemSurfaceKeyDown = false
    var systemPanelWindowNumber: CGWindowID? = nil
    var compositionActive = false
    var markedRangeReliable = true
    var markedRangeWasObservable = false

    init(token: FocusToken,
         controller: RimeBufferController,
         client: IMKTextInput,
         bundleID: String,
         processIdentifier: pid_t,
         hostKind: FocusHostKind,
         foregroundAnchorBundleID: String?,
         foregroundAnchorProcessIdentifier: pid_t?,
         isExternalTarget: Bool,
         activationEventFloor: TimeInterval?,
         lastAcceptedEventTimestamp: TimeInterval?,
         provisionalFromEvent: Bool,
         createdAtUptime: TimeInterval,
         lifecycleSuppressionUntilUptime: TimeInterval,
         clientIdentityWasReused: Bool,
         processIdentityWasVerified: Bool) {
        self.token = token
        self.controller = controller
        self.client = client
        self.clientIdentity = ObjectIdentifier(client as AnyObject)
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
        self.hostKind = hostKind
        self.foregroundAnchorBundleID = foregroundAnchorBundleID
        self.foregroundAnchorProcessIdentifier = foregroundAnchorProcessIdentifier
        self.isExternalTarget = isExternalTarget
        self.activationEventFloor = activationEventFloor
        self.lastAcceptedEventTimestamp = lastAcceptedEventTimestamp
        self.provisionalFromEvent = provisionalFromEvent
        self.createdAtUptime = createdAtUptime
        self.lifecycleSuppressionUntilUptime = lifecycleSuppressionUntilUptime
        self.clientIdentityWasReused = clientIdentityWasReused
        self.processIdentityWasVerified = processIdentityWasVerified
    }
}

/// Owns focus epochs and the one delivery lease that is allowed to receive
/// buffered text. Candidate ownership and delivery eligibility share the same
/// token, but clients inside ETInput itself are never exposed as delivery
/// targets (notably the explicit block editor).
final class InputFocusCoordinator {
    static let shared = InputFocusCoordinator()

    struct Activation {
        let token: FocusToken
        let displaced: FocusLease?
    }

    private struct OverlayVisibilitySample {
        let processIdentifier: pid_t
        let checkedAtUptime: TimeInterval
        let visible: Bool
    }

    private var epochs = FocusEpochState()
    private(set) var owner: FocusLease?
    private let knownClientProcesses = NSMapTable<AnyObject, NSNumber>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    private var overlayVisibilitySample: OverlayVisibilitySample?
    var onChange: (() -> Void)?
    var onInvalidated: ((FocusToken) -> Void)?

    private init() {}

    /// Resolve only explicitly allowlisted bundle/path surfaces. Established
    /// leases re-run the same unique-process + canonical-path check: a second
    /// instance, PID reuse, or path replacement must revoke rather than inherit
    /// authority (especially for the third-party Paste overlay).
    private func trustedNonactivatingSystemOverlayProcessIdentifier(
        for bundleID: String,
        boundProcessIdentifier: pid_t? = nil
    ) -> pid_t? {
        guard FocusHostRules.isNonactivatingSystemOverlayBundle(bundleID) else {
            return nil
        }
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).filter { !$0.isTerminated }.map {
            (processIdentifier: $0.processIdentifier,
             bundlePath: $0.bundleURL?.path)
        }
        guard let resolved = FocusHostRules.uniqueTrustedOverlayProcessIdentifier(
            bundleID: bundleID,
            runningCandidates: candidates
        ) else { return nil }
        if let boundProcessIdentifier,
           resolved != boundProcessIdentifier {
            return nil
        }
        return resolved
    }

    /// AppKit may retain more than one genuine open/save ViewService. We do not
    /// select one: all live same-ID processes must come from the sealed AppKit
    /// XPC path, and the panel itself is tied to the initiating app/window.
    private func trustedAppKitOpenSavePanelServiceIsAvailable(
        for bundleID: String
    ) -> Bool {
        guard FocusHostRules.isAppKitOpenSavePanelBundle(bundleID) else {
            return false
        }
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).filter { !$0.isTerminated }.map {
            (processIdentifier: $0.processIdentifier,
             bundlePath: $0.bundleURL?.path)
        }
        return FocusHostRules.allSystemPanelProcessesAreTrusted(
            bundleID: bundleID,
            runningCandidates: candidates
        )
    }

    /// Preserve WindowServer's front-to-back order. Open/save panels are
    /// composited as windows of the initiating app rather than of the XPC PID.
    private func onScreenWindowSnapshots() -> [FocusWindowSnapshot] {
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber else {
                return nil
            }
            return FocusWindowSnapshot(
                windowNumber: CGWindowID(number.uint32Value),
                ownerProcessIdentifier: ownerPID.int32Value,
                layer: layer.intValue,
                alpha: alpha.doubleValue
            )
        }
    }

    /// PID/path existence is not enough (Spotlight in particular is long-lived):
    /// delivery is trusted only while that process owns an on-screen window.
    /// A tiny cache coalesces the several target checks made by one key event.
    private func trustedOverlayHasVisibleWindow(
        processIdentifier: pid_t,
        forceRefresh: Bool = false
    ) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if !forceRefresh,
           let sample = overlayVisibilitySample,
           sample.processIdentifier == processIdentifier,
           now - sample.checkedAtUptime >= 0,
           now - sample.checkedAtUptime <= 0.010 {
            return sample.visible
        }
        let options: CGWindowListOption = [
            .optionOnScreenOnly,
            .excludeDesktopElements,
        ]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] ?? []
        let visible = windows.contains { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == processIdentifier else { return false }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
                ?? 1
            return alpha > 0
        }
        overlayVisibilitySample = OverlayVisibilitySample(
            processIdentifier: processIdentifier,
            checkedAtUptime: now,
            visible: visible
        )
        return visible
    }

    private func suspendReusedTransientSurfaceOwnerIfNeeded(
        reusesExactOwner: Bool,
        reason: String
    ) {
        guard reusesExactOwner,
              let owner,
              owner.hostKind.requiresTransientSurfaceAuthority else { return }
        suspendDelivery(token: owner.token, reason: reason)
    }

    private func confirmReusedClientLifecycleIfNeeded(
        _ lease: FocusLease,
        eventType: NSEvent.EventType?
    ) {
        guard lease.clientIdentityWasReused,
              FocusActivationRules.acceptedEventConfirmsReusedClientLifecycle(
                eventType: eventType
              ) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lease.lifecycleSuppressionUntilUptime = FocusActivationRules
            .suppressionDeadlineAfterConfirmedKeyDown(
                current: lease.lifecycleSuppressionUntilUptime,
                confirmationUptime: now
            )
        lease.clientIdentityWasReused = false
        IMELog.write("focus reused-client lifecycle confirmed token=\(lease.token)")
    }

    @discardableResult
    private func pruneExpiredOwner() -> Bool {
        guard let expired = owner else { return false }
        let controller = expired.controller
        let controllerAlive = controller != nil
        let clientAlive = expired.client != nil
        guard FocusTargetRules.shouldPruneExpiredLease(
            controllerAlive: controllerAlive,
            clientAlive: clientAlive
        ) else { return false }
        _ = epochs.deactivate(expired.token)
        owner = nil
        IMELog.write("focus expired weak lease removed token=\(expired.token)")
        // If only the IMK client disappeared, the controller and its librime
        // session can still survive. Clear/recover that session without ever
        // calling the expired client, otherwise the next field can inherit its
        // chord or composition.
        if FocusTargetRules.requiresNoClientCleanup(
            controllerAlive: controllerAlive,
            clientAlive: clientAlive
        ) {
            controller?.finalizeProtectedSession(expired, reason: "focus client expired")
        }
        onInvalidated?(expired.token)
        onChange?()
        return true
    }

    /// A server activation denotes a new field focus even when IMK reuses the
    /// same application-level client proxy for multiple text controls.
    func beginActivation(controller: RimeBufferController,
                         client: IMKTextInput,
                         eventFloor: TimeInterval?) -> Activation? {
        activate(controller: controller,
                 client: client,
                 forceNewEpoch: true,
                 eventTimestamp: nil,
                 eventType: nil,
                 eventFloor: eventFloor)
    }

    /// `handle(_:client:)` can precede activateServer in some clients. A key
    /// event reuses the exact current lease, or establishes a new one when the
    /// client really changed. Its monotonic event timestamp rejects callbacks
    /// queued before the current activation.
    func noteEvent(controller: RimeBufferController,
                   client: IMKTextInput,
                   eventTimestamp: TimeInterval,
                   eventType: NSEvent.EventType) -> Activation? {
        activate(controller: controller,
                 client: client,
                 forceNewEpoch: false,
                 eventTimestamp: eventTimestamp,
                 eventType: eventType,
                 eventFloor: nil)
    }

    private func activate(controller: RimeBufferController,
                          client: IMKTextInput,
                          forceNewEpoch: Bool,
                          eventTimestamp: TimeInterval?,
                          eventType: NSEvent.EventType?,
                          eventFloor: TimeInterval?) -> Activation? {
        dispatchPrecondition(condition: .onQueue(.main))
        let identity = ObjectIdentifier(client as AnyObject)
        let bundleID = client.bundleIdentifier() ?? "unknown"
        let controllerClient = controller.client()
        let controllerClientMatches = controllerClient.map {
            ObjectIdentifier($0 as AnyObject) == identity
        } ?? false
        guard FocusActivationRules.currentControllerClientMayApply(
            clientExists: controllerClient != nil,
            identityMatches: controllerClientMatches
        ) else {
            IMELog.write("focus callback rejected; controller current client unavailable or mismatched bundle=\(bundleID)")
            return nil
        }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostBundleID = frontmostApplication?.bundleIdentifier
        let frontmostProcessIdentifier = frontmostApplication?.processIdentifier

        _ = pruneExpiredOwner()

        let reusesExactOwner = owner.map {
            epochs.isCurrent($0.token)
                && $0.controller === controller
                && $0.clientIdentity == identity
                && $0.client != nil
                && $0.bundleID == bundleID
        } ?? false

        let activationNow = ProcessInfo.processInfo.systemUptime
        let explicitActivation = forceNewEpoch && eventTimestamp == nil
        let eventCanEstablishTransientSurface = eventType == .keyDown
            && eventTimestamp.map {
                FocusEventRules.isFreshNonactivatingOverlayEvent(
                    $0,
                    now: activationNow
                )
            } == true

        let clientObject = client as AnyObject
        let knownProcess = knownClientProcesses.object(forKey: clientObject)
        let overlayBundle = FocusHostRules
            .isNonactivatingSystemOverlayBundle(bundleID)
        let openSavePanelBundle = FocusHostRules
            .isAppKitOpenSavePanelBundle(bundleID)
        let boundOverlayProcessIdentifier: pid_t? = {
            guard overlayBundle,
                  reusesExactOwner,
                  owner?.hostKind == .nonactivatingSystemOverlay else { return nil }
            return owner?.processIdentifier
        }()
        var trustedSurfaceAuthority = false
        var pendingSystemPanelWindowNumber: CGWindowID?
        var resolvedClientProcessIdentityWasVerified = false
        let hostResolution: FocusHostResolution

        if let frontmostBundleID, let frontmostProcessIdentifier {
            let overlayProcessIdentifier: pid_t?
            if overlayBundle {
                overlayProcessIdentifier =
                    trustedNonactivatingSystemOverlayProcessIdentifier(
                        for: bundleID,
                        boundProcessIdentifier: boundOverlayProcessIdentifier
                    )
                if let overlayProcessIdentifier {
                    trustedSurfaceAuthority = trustedOverlayHasVisibleWindow(
                        processIdentifier: overlayProcessIdentifier,
                        forceRefresh: explicitActivation || eventType != nil
                    )
                }
            } else {
                overlayProcessIdentifier = nil
            }
            let systemPanelAvailable = openSavePanelBundle
                && trustedAppKitOpenSavePanelServiceIsAvailable(for: bundleID)
            guard let resolved = FocusHostRules.resolveKnownFrontmost(
                incomingBundleID: bundleID,
                frontmostBundleID: frontmostBundleID,
                frontmostProcessIdentifier: frontmostProcessIdentifier,
                trustedOverlayProcessIdentifier: overlayProcessIdentifier,
                trustedSystemPanelAvailable: systemPanelAvailable
            ) else {
                suspendReusedTransientSurfaceOwnerIfNeeded(
                    reusesExactOwner: reusesExactOwner,
                    reason: "transient surface provenance/anchor unavailable"
                )
                IMELog.write("focus background callback rejected bundle=\(bundleID) frontmost=\(frontmostBundleID)")
                return nil
            }
            hostResolution = resolved
            // `resolveKnownFrontmost` accepts ordinary apps only on an exact
            // bundle match, and overlays only with their trusted system-path
            // process. The open/save anchor PID is intentionally not cacheable.
            resolvedClientProcessIdentityWasVerified =
                resolved.kind != .appKitOpenSavePanel
            if resolved.kind == .appKitOpenSavePanel {
                let windows = onScreenWindowSnapshots()
                if let owner,
                   reusesExactOwner,
                   owner.hostKind == .appKitOpenSavePanel {
                    let frozenWindow = owner.systemPanelWindowNumber
                    let frozenWindowTrusted = frozenWindow.map {
                        FocusSystemPanelWindowRules.windowRemainsTrusted(
                            $0,
                            anchorProcessIdentifier:
                                frontmostProcessIdentifier,
                            onScreenWindows: windows
                        )
                    } ?? false
                    let candidateWindow = frozenWindow == nil
                        && eventCanEstablishTransientSurface
                            ? FocusSystemPanelWindowRules
                                .frontmostWindowNumber(
                                    anchorProcessIdentifier:
                                        frontmostProcessIdentifier,
                                    orderedWindows: windows
                                )
                            : nil
                    let windowAuthority =
                        FocusSystemPanelWindowRules.authorityForExistingLease(
                        frozenWindowNumber: frozenWindow,
                        frozenWindowRemainsTrusted: frozenWindowTrusted,
                        deliverySuspended: owner.deliverySuspended,
                        eventCanEstablishTransientSurface:
                            eventCanEstablishTransientSurface,
                        candidateWindowNumber: candidateWindow
                    )
                    trustedSurfaceAuthority = windowAuthority.trusted
                    pendingSystemPanelWindowNumber =
                        windowAuthority.pendingWindowNumber
                } else if eventCanEstablishTransientSurface {
                    pendingSystemPanelWindowNumber =
                        FocusSystemPanelWindowRules.frontmostWindowNumber(
                            anchorProcessIdentifier: frontmostProcessIdentifier,
                            orderedWindows: windows
                        )
                    trustedSurfaceAuthority =
                        pendingSystemPanelWindowNumber != nil
                }
            }
        } else if overlayBundle {
            // The frontmost bundle can briefly be unavailable. Only an exact,
            // already-bound overlay lease may continue under the frozen anchor
            // PID; first establishment still requires both anchor identities.
            guard let owner,
                  reusesExactOwner,
                  owner.hostKind == .nonactivatingSystemOverlay,
                  let foregroundAnchorBundleID = owner.foregroundAnchorBundleID,
                  let foregroundAnchorProcessIdentifier =
                    owner.foregroundAnchorProcessIdentifier,
                  frontmostProcessIdentifier == foregroundAnchorProcessIdentifier,
                  trustedNonactivatingSystemOverlayProcessIdentifier(
                    for: bundleID,
                    boundProcessIdentifier: owner.processIdentifier
                  ) == owner.processIdentifier else {
                suspendReusedTransientSurfaceOwnerIfNeeded(
                    reusesExactOwner: reusesExactOwner,
                    reason: "overlay foreground anchor unavailable"
                )
                IMELog.write("focus overlay callback rejected; foreground anchor unavailable bundle=\(bundleID)")
                return nil
            }
            trustedSurfaceAuthority = trustedOverlayHasVisibleWindow(
                processIdentifier: owner.processIdentifier,
                forceRefresh: explicitActivation || eventType != nil
            )
            hostResolution = FocusHostResolution(
                kind: .nonactivatingSystemOverlay,
                clientProcessIdentifier: owner.processIdentifier,
                foregroundAnchorBundleID: foregroundAnchorBundleID,
                foregroundAnchorProcessIdentifier: foregroundAnchorProcessIdentifier
            )
            resolvedClientProcessIdentityWasVerified = true
        } else if openSavePanelBundle {
            // A temporarily missing foreground bundle must never downgrade an
            // AppKit service callback into the ordinary PID fallback. Continue
            // only the exact lease under its already-frozen anchor identity.
            guard let owner,
                  reusesExactOwner,
                  owner.hostKind == .appKitOpenSavePanel,
                  let foregroundAnchorBundleID = owner.foregroundAnchorBundleID,
                  let foregroundAnchorProcessIdentifier =
                    owner.foregroundAnchorProcessIdentifier,
                  frontmostProcessIdentifier == foregroundAnchorProcessIdentifier,
                  trustedAppKitOpenSavePanelServiceIsAvailable(for: bundleID) else {
                suspendReusedTransientSurfaceOwnerIfNeeded(
                    reusesExactOwner: reusesExactOwner,
                    reason: "open/save panel foreground anchor unavailable"
                )
                IMELog.write("focus open/save callback rejected; frozen anchor unavailable bundle=\(bundleID)")
                return nil
            }
            let windows = onScreenWindowSnapshots()
            let frozenWindow = owner.systemPanelWindowNumber
            let frozenWindowTrusted = frozenWindow.map {
                FocusSystemPanelWindowRules.windowRemainsTrusted(
                    $0,
                    anchorProcessIdentifier: foregroundAnchorProcessIdentifier,
                    onScreenWindows: windows
                )
            } ?? false
            let candidateWindow = frozenWindow == nil
                && eventCanEstablishTransientSurface
                    ? FocusSystemPanelWindowRules.frontmostWindowNumber(
                        anchorProcessIdentifier:
                            foregroundAnchorProcessIdentifier,
                        orderedWindows: windows
                    )
                    : nil
            let windowAuthority =
                FocusSystemPanelWindowRules.authorityForExistingLease(
                frozenWindowNumber: frozenWindow,
                frozenWindowRemainsTrusted: frozenWindowTrusted,
                deliverySuspended: owner.deliverySuspended,
                eventCanEstablishTransientSurface:
                    eventCanEstablishTransientSurface,
                candidateWindowNumber: candidateWindow
            )
            trustedSurfaceAuthority = windowAuthority.trusted
            pendingSystemPanelWindowNumber =
                windowAuthority.pendingWindowNumber
            hostResolution = FocusHostResolution(
                kind: .appKitOpenSavePanel,
                clientProcessIdentifier: foregroundAnchorProcessIdentifier,
                foregroundAnchorBundleID: foregroundAnchorBundleID,
                foregroundAnchorProcessIdentifier: foregroundAnchorProcessIdentifier
            )
        } else {
            guard FocusHostRules.mayUseOrdinaryProcessBoundFallback(bundleID) else {
                suspendReusedTransientSurfaceOwnerIfNeeded(
                    reusesExactOwner: reusesExactOwner,
                    reason: "system surface cannot use ordinary PID fallback"
                )
                return nil
            }
            // NSWorkspace can briefly omit a bundle. Continue an exact/frozen
            // binding, or create a provisional first lease for the current key.
            // That provisional PID is deliberately not written to the durable
            // proxy cache; later exact bundle evidence replaces its epoch.
            guard FocusEventRules.mayUseOrdinaryProcessBoundResolution(
                ownerExists: owner != nil,
                reusesExactOwner: reusesExactOwner,
                frontmostProcessIdentifier: frontmostProcessIdentifier,
                knownClientProcessIdentifier: knownProcess?.int32Value
            ) else {
                IMELog.write("focus callback rejected; unverifiable frontmost bundle=\(bundleID)")
                return nil
            }
            if let owner,
               let frontmostProcessIdentifier,
               (owner.foregroundAnchorProcessIdentifier ?? owner.processIdentifier)
                    != frontmostProcessIdentifier {
                IMELog.write("focus callback rejected; frontmost PID changed without bundle")
                return nil
            }
            let processIdentifier = frontmostProcessIdentifier
                ?? knownProcess?.int32Value
                ?? owner?.processIdentifier
                ?? 0
            guard processIdentifier > 0 else {
                IMELog.write("focus callback rejected; client process unavailable bundle=\(bundleID)")
                return nil
            }
            hostResolution = FocusHostResolution(
                kind: .frontmostApplication,
                clientProcessIdentifier: processIdentifier,
                foregroundAnchorBundleID: frontmostBundleID
                    ?? owner?.foregroundAnchorBundleID,
                foregroundAnchorProcessIdentifier: frontmostProcessIdentifier
                    ?? owner?.foregroundAnchorProcessIdentifier
                    ?? processIdentifier
            )
        }

        let hostResolutionMatchesOwner = owner.map {
            FocusHostRules.resolutionMatchesLease(
                hostResolution,
                hostKind: $0.hostKind,
                clientProcessIdentifier: $0.processIdentifier,
                foregroundAnchorBundleID: $0.foregroundAnchorBundleID,
                foregroundAnchorProcessIdentifier:
                    $0.foregroundAnchorProcessIdentifier
            )
        } ?? false
        let continuesExactLease = reusesExactOwner
            && hostResolutionMatchesOwner
            && owner?.deliverySuspended == false
        guard FocusHostRules.callbackMayUseResolution(
            kind: hostResolution.kind,
            explicitActivation: explicitActivation,
            eventCanEstablishTransientSurface:
                eventCanEstablishTransientSurface,
            continuesExactLease: continuesExactLease,
            trustedSurfaceAuthority: trustedSurfaceAuthority
        ) else {
            let preservesPendingPreheat =
                FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
                    kind: hostResolution.kind,
                    reusesExactOwner: reusesExactOwner,
                    resolutionMatchesOwner: hostResolutionMatchesOwner,
                    deliverySuspended: owner?.deliverySuspended == true,
                    awaitingKeyDown:
                        owner?.awaitingSystemSurfaceKeyDown == true
                )
            if (!trustedSurfaceAuthority || !hostResolutionMatchesOwner),
               !preservesPendingPreheat {
                suspendReusedTransientSurfaceOwnerIfNeeded(
                    reusesExactOwner: reusesExactOwner,
                    reason: "transient surface/window authority unavailable"
                )
            }
            IMELog.write("focus transient-surface event rejected; no trusted visible window type=\(eventType?.rawValue ?? 0)")
            return nil
        }

        // An open/save proxy is intentionally bound to the initiating app PID,
        // not to one ambiguous XPC PID. Do not poison the ordinary frozen-PID
        // map when AppKit later reuses that proxy for another application.
        if hostResolution.kind != .appKitOpenSavePanel,
           let knownProcess,
           knownProcess.int32Value != hostResolution.clientProcessIdentifier,
           !FocusEventRules.mayRebindKnownClientProcess(
            hostKind: hostResolution.kind,
            resolvedIdentityWasVerified:
                resolvedClientProcessIdentityWasVerified
           ) {
            suspendReusedTransientSurfaceOwnerIfNeeded(
                reusesExactOwner: reusesExactOwner,
                reason: "client process authority changed"
            )
            IMELog.write("focus client process mismatch rejected bundle=\(bundleID) known=\(knownProcess.int32Value) resolved=\(hostResolution.clientProcessIdentifier)")
            return nil
        }
        if let owner, epochs.isCurrent(owner.token) {
            if let eventTimestamp,
               !FocusEventRules.isOrdered(eventTimestamp,
                                          activationFloor: owner.activationEventFloor,
                                          lastAccepted: owner.lastAcceptedEventTimestamp) {
                IMELog.write("focus out-of-order event rejected bundle=\(bundleID) owner=\(owner.token)")
                return nil
            }
            guard FocusEventRules.mayTakeOwnership(
                incomingBundleID: bundleID,
                currentOwnerBundleID: owner.bundleID,
                frontmostBundleID: frontmostBundleID,
                incomingHostKind: hostResolution.kind
            ) else { return nil }
        }

        // Cache only after event ordering and ownership gates have accepted the
        // callback. A rejected stale event must not leave a durable proxy/PID
        // association behind.
        if FocusEventRules.mayCacheClientProcess(
            hostKind: hostResolution.kind,
            resolvedIdentityWasVerified:
                resolvedClientProcessIdentityWasVerified
        ) {
            if let knownProcess,
               knownProcess.int32Value
                != hostResolution.clientProcessIdentifier {
                IMELog.write("focus client process rebound bundle=\(bundleID) old=\(knownProcess.int32Value) new=\(hostResolution.clientProcessIdentifier)")
            }
            knownClientProcesses.setObject(
                NSNumber(value: hostResolution.clientProcessIdentifier),
                forKey: clientObject
            )
        }

        if eventType == .keyDown,
           eventCanEstablishTransientSurface,
           trustedSurfaceAuthority,
           reusesExactOwner,
           hostResolutionMatchesOwner,
           let owner,
           owner.awaitingSystemSurfaceKeyDown,
           epochs.isCurrent(owner.token) {
            // The activation already minted a fresh token. Promote that same
            // lease after the first positive key proof; manufacturing another
            // same-proxy epoch would make all lifecycle callbacks ambiguous.
            if owner.hostKind == .appKitOpenSavePanel {
                guard let pendingSystemPanelWindowNumber else {
                    suspendDelivery(
                        token: owner.token,
                        reason: "open/save panel window was not frozen"
                    )
                    return nil
                }
                owner.systemPanelWindowNumber = pendingSystemPanelWindowNumber
            }
            owner.awaitingSystemSurfaceKeyDown = false
            owner.deliverySuspended = false
            owner.lastAcceptedEventTimestamp = eventTimestamp
            confirmReusedClientLifecycleIfNeeded(owner, eventType: eventType)
            let windowDescription = owner.systemPanelWindowNumber.map {
                String($0)
            } ?? "service-owned"
            IMELog.write("focus transient surface promoted token=\(owner.token) bundle=\(bundleID) window=\(windowDescription)")
            onChange?()
            return Activation(token: owner.token, displaced: nil)
        }

        let confirmsProvisionalEvent = forceNewEpoch && owner.map {
            hostResolutionMatchesOwner
                && (!$0.hostKind.requiresTransientSurfaceAuthority
                    || trustedSurfaceAuthority)
                && FocusActivationRules.shouldConfirmProvisional(
                    isProvisional: $0.provisionalFromEvent,
                    sameControllerAndClient: reusesExactOwner,
                    age: activationNow - $0.createdAtUptime,
                    hostKind: $0.hostKind
                )
                && !FocusEventRules.verifiedIdentityRequiresFreshEpoch(
                    reusesExactOwner: reusesExactOwner,
                    ownerProcessIdentityWasVerified:
                        $0.processIdentityWasVerified,
                    resolvedIdentityWasVerified:
                        resolvedClientProcessIdentityWasVerified
                )
                && !$0.deliverySuspended
                && epochs.isCurrent($0.token)
        } ?? false

        // `markedRange()` touches the host proxy. Do it only after the app/PID,
        // host/anchor, event-order and visibility gates have all succeeded.
        let shouldInspectMarkedRange = eventTimestamp != nil
            && reusesExactOwner
            && hostResolutionMatchesOwner
            && owner?.deliverySuspended == false
            && owner?.compositionActive == true
            && owner?.markedRangeReliable == true
            && owner?.markedRangeWasObservable == true
        let markedRangeIsMissing = shouldInspectMarkedRange
            && client.markedRange().location == NSNotFound
        let eventRevealsFieldChange = FocusActivationRules.eventRevealsFieldChange(
            hasEvent: eventTimestamp != nil,
            reusesExactOwner: reusesExactOwner,
            compositionActive: owner?.compositionActive == true,
            markedRangeReliable: owner?.markedRangeReliable == true,
            markedRangeWasObservable: owner?.markedRangeWasObservable == true,
            markedRangeIsMissing: markedRangeIsMissing
        )
        let verifiedIdentityRequiresFreshEpoch = owner.map {
            FocusEventRules.verifiedIdentityRequiresFreshEpoch(
                reusesExactOwner: reusesExactOwner,
                ownerProcessIdentityWasVerified:
                    $0.processIdentityWasVerified,
                resolvedIdentityWasVerified:
                    resolvedClientProcessIdentityWasVerified
            )
        } ?? false
        let eventRequiresFreshEpoch = eventRevealsFieldChange
            || verifiedIdentityRequiresFreshEpoch
            || (eventTimestamp != nil
                && reusesExactOwner
                && (owner?.deliverySuspended == true
                    || !hostResolutionMatchesOwner))

        // Some hosts deliver the first key before activateServer. That event
        // creates a provisional epoch; a matching activation confirms it.
        if confirmsProvisionalEvent, let owner {
            owner.provisionalFromEvent = false
            if let eventFloor {
                owner.activationEventFloor = max(
                    owner.activationEventFloor ?? eventFloor,
                    eventFloor
                )
            }
            return Activation(token: owner.token, displaced: nil)
        }

        if let owner,
           !forceNewEpoch,
           !eventRequiresFreshEpoch,
           reusesExactOwner,
           hostResolutionMatchesOwner,
           epochs.isCurrent(owner.token) {
            if let eventTimestamp {
                owner.lastAcceptedEventTimestamp = eventTimestamp
            }
            confirmReusedClientLifecycleIfNeeded(owner, eventType: eventType)
            return Activation(token: owner.token, displaced: nil)
        }

        let displaced = owner
        if let displaced,
           FocusHostRules.displacedLeaseRequiresNoClientCleanup(
            hostKind: displaced.hostKind
           ) {
            displaced.deliverySuspended = true
            displaced.awaitingSystemSurfaceKeyDown = false
        }
        let token = epochs.activate()
        let ownBundleID = Bundle.main.bundleIdentifier
            ?? "com.isaac.inputmethod.RimeBuffer"
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let targetProcessIdentifier = hostResolution.clientProcessIdentifier
        let isExternalTarget = FocusTargetRules.identifiesExternalTarget(
            bundleID: bundleID,
            processIdentifier: targetProcessIdentifier,
            ownBundleID: ownBundleID,
            ownProcessIdentifier: ownProcessIdentifier
        )
        // An IMK proxy may be reused across controller instances as well as
        // fields within one controller. Identity reuse alone makes the old
        // destination unsafe.
        let reusesDisplacedIdentity = displaced?.clientIdentity == identity
        let eventConfirmsReusedIdentity = reusesDisplacedIdentity
            && FocusActivationRules.acceptedEventConfirmsReusedClientLifecycle(
                eventType: eventType
            )
        let initialLifecycleSuppression = reusesDisplacedIdentity
            ? activationNow
                + FocusActivationRules.reusedClientLifecycleSuppressionWindow
            : activationNow
        let lifecycleSuppressionUntil = eventConfirmsReusedIdentity
            ? FocusActivationRules.suppressionDeadlineAfterConfirmedKeyDown(
                current: initialLifecycleSuppression,
                confirmationUptime: activationNow
            )
            : initialLifecycleSuppression
        let newOwner = FocusLease(
            token: token,
            controller: controller,
            client: client,
            bundleID: bundleID,
            processIdentifier: targetProcessIdentifier,
            hostKind: hostResolution.kind,
            foregroundAnchorBundleID: hostResolution.foregroundAnchorBundleID,
            foregroundAnchorProcessIdentifier:
                hostResolution.foregroundAnchorProcessIdentifier,
            isExternalTarget: isExternalTarget,
            activationEventFloor: eventFloor ?? eventTimestamp,
            lastAcceptedEventTimestamp: eventTimestamp,
            provisionalFromEvent: !forceNewEpoch,
            createdAtUptime: activationNow,
            lifecycleSuppressionUntilUptime: lifecycleSuppressionUntil,
            clientIdentityWasReused: reusesDisplacedIdentity
                && !eventConfirmsReusedIdentity,
            processIdentityWasVerified:
                resolvedClientProcessIdentityWasVerified
        )
        // System-surface activation may precede its window becoming visible.
        // Preheat the engine under a fresh token, but the first fresh keyDown
        // must establish delivery; keyUp/flagsChanged cannot unlock it.
        newOwner.systemPanelWindowNumber =
            hostResolution.kind == .appKitOpenSavePanel
                ? pendingSystemPanelWindowNumber
                : nil
        newOwner.deliverySuspended = FocusHostRules.shouldSuspendNewLease(
            kind: hostResolution.kind,
            explicitActivation: explicitActivation
        )
        newOwner.awaitingSystemSurfaceKeyDown = newOwner.deliverySuspended
        owner = newOwner
        let hostDescription: String
        switch hostResolution.kind {
        case .frontmostApplication:
            hostDescription = "frontmost"
        case .nonactivatingSystemOverlay:
            hostDescription = "overlay"
        case .appKitOpenSavePanel:
            hostDescription = "open-save-panel"
        }
        IMELog.write("focus activate token=\(token) bundle=\(bundleID) host=\(hostDescription) anchor=\(hostResolution.foregroundAnchorBundleID ?? "unknown") suspended=\(newOwner.deliverySuspended) external=\(isExternalTarget)")
        onChange?()
        return Activation(token: token, displaced: displaced)
    }

    @discardableResult
    func deactivate(controller: RimeBufferController, token: FocusToken) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner,
              owner.controller === controller,
              owner.token == token,
              epochs.deactivate(token) else {
            IMELog.write("focus stale deactivate ignored token=\(token)")
            return nil
        }
        self.owner = nil
        IMELog.write("focus deactivate token=\(token) bundle=\(owner.bundleID)")
        onInvalidated?(token)
        onChange?()
        return owner
    }

    /// `markedRangeReliable` is false while the buffer keeps IMK alive with an
    /// invisible zero-width placeholder: hosts report that placeholder's marked
    /// range inconsistently (NSNotFound during fast chords / in terminals /
    /// Electron), so arming the marked-range field-change detector on it makes
    /// activate() spuriously fresh-epoch a valid key and drop it — the user then
    /// has to press again (broken 并击, F4 "select twice"). Identity + bundle +
    /// PID still guard delivery; only this one unreliable signal is skipped.
    func setCompositionActive(_ active: Bool, token: FocusToken, markedRangeReliable: Bool = true) {
        guard let owner, owner.token == token, epochs.isCurrent(token) else { return }
        owner.markedRangeReliable = markedRangeReliable
        if active,
           markedRangeReliable,
           !owner.markedRangeWasObservable,
           let client = owner.client,
           client.markedRange().location != NSNotFound {
            owner.markedRangeWasObservable = true
        } else if !active || !markedRangeReliable {
            owner.markedRangeWasObservable = false
        }
        guard owner.compositionActive != active else { return }
        owner.compositionActive = active
        onChange?()
    }

    /// A lifecycle callback that cannot yet be attributed safely must never
    /// leave the old field eligible for buffered delivery. A subsequent exact
    /// key event or activation restores trust without discarding composition.
    func suspendDelivery(token: FocusToken, reason: String) {
        guard let owner,
              owner.token == token,
              epochs.isCurrent(token) else { return }
        let changed = !owner.deliverySuspended
            || owner.awaitingSystemSurfaceKeyDown
        guard changed else { return }
        owner.deliverySuspended = true
        owner.awaitingSystemSurfaceKeyDown = false
        IMELog.write("focus delivery suspended token=\(token) reason=\(reason)")
        onInvalidated?(token)
        onChange?()
    }

    func isCurrent(_ token: FocusToken, controller: RimeBufferController? = nil) -> Bool {
        if Thread.isMainThread { _ = pruneExpiredOwner() }
        guard let owner,
              owner.token == token,
              epochs.isCurrent(token),
              owner.controller != nil,
              owner.client != nil else { return false }
        if let controller { return owner.controller === controller }
        return true
    }

    func controller(for token: FocusToken) -> RimeBufferController? {
        guard isCurrent(token) else { return nil }
        return owner?.controller
    }

    func lease(for token: FocusToken) -> FocusLease? {
        guard isCurrent(token) else { return nil }
        return owner
    }

    func maySynchronizePendingOverlayModifierBaseline(
        controller: RimeBufferController,
        client: IMKTextInput,
        eventTimestamp: TimeInterval
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner,
              epochs.isCurrent(owner.token),
              owner.controller === controller,
              owner.clientIdentity == ObjectIdentifier(client as AnyObject),
              owner.client != nil,
              owner.hostKind.permitsPendingModifierBaselineSync,
              owner.deliverySuspended,
              owner.awaitingSystemSurfaceKeyDown else { return false }
        return FocusEventRules.isOrdered(
            eventTimestamp,
            activationFloor: owner.activationEventFloor,
            lastAccepted: owner.lastAcceptedEventTimestamp
        )
    }

    /// Lifecycle callbacks can be the first signal that a system surface closed.
    /// Refresh rather than using the per-key cache, then mark the lease unsafe
    /// while still returning it to the controller for no-client cleanup.
    func refreshTransientSurfaceLifecycleTrust(_ lease: FocusLease) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard owner === lease,
              epochs.isCurrent(lease.token),
              lease.hostKind.requiresTransientSurfaceAuthority else { return }
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        var currentTrustedOverlayProcessIdentifier: pid_t?
        let trustedSurfaceAuthority: Bool
        switch lease.hostKind {
        case .frontmostApplication:
            return
        case .nonactivatingSystemOverlay:
            currentTrustedOverlayProcessIdentifier =
                trustedNonactivatingSystemOverlayProcessIdentifier(
                for: lease.bundleID,
                boundProcessIdentifier: lease.processIdentifier
            )
            trustedSurfaceAuthority =
                currentTrustedOverlayProcessIdentifier
                    == lease.processIdentifier
                && trustedOverlayHasVisibleWindow(
                    processIdentifier: lease.processIdentifier,
                    forceRefresh: true
                )
        case .appKitOpenSavePanel:
            let serviceAvailable =
                trustedAppKitOpenSavePanelServiceIsAvailable(
                    for: lease.bundleID
                )
            let windowAvailable = lease.systemPanelWindowNumber.map {
                FocusSystemPanelWindowRules.windowRemainsTrusted(
                    $0,
                    anchorProcessIdentifier: lease.processIdentifier,
                    onScreenWindows: onScreenWindowSnapshots()
                )
            } ?? false
            trustedSurfaceAuthority = serviceAvailable && windowAvailable
        }
        let authority = FocusHostRules.applicationAuthorityMatches(
            kind: lease.hostKind,
            leaseBundleID: lease.bundleID,
            leaseProcessIdentifier: lease.processIdentifier,
            foregroundAnchorBundleID: lease.foregroundAnchorBundleID,
            foregroundAnchorProcessIdentifier:
                lease.foregroundAnchorProcessIdentifier,
            currentFrontmostBundleID: frontmostApplication?.bundleIdentifier,
            currentFrontmostProcessIdentifier:
                frontmostApplication?.processIdentifier,
            currentTrustedOverlayProcessIdentifier:
                currentTrustedOverlayProcessIdentifier,
            trustedSurfaceAuthority: trustedSurfaceAuthority
        )
        if !authority.bundle || !authority.process {
            suspendDelivery(
                token: lease.token,
                reason: "transient surface lifecycle authority unavailable"
            )
        }
    }

    private func validatedTarget(expected token: FocusToken?,
                                 requireExternal: Bool,
                                 forceOverlayVisibilityRefresh: Bool) -> FocusLease? {
        if Thread.isMainThread { _ = pruneExpiredOwner() }
        guard let owner else { return nil }
        let client = owner.client
        let controllerClient = owner.controller?.client()
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        var currentTrustedOverlayProcessIdentifier: pid_t?
        var trustedSurfaceAuthority = false
        switch owner.hostKind {
        case .frontmostApplication:
            break
        case .nonactivatingSystemOverlay:
            currentTrustedOverlayProcessIdentifier =
                trustedNonactivatingSystemOverlayProcessIdentifier(
                    for: owner.bundleID,
                    boundProcessIdentifier: owner.processIdentifier
                )
            if currentTrustedOverlayProcessIdentifier == owner.processIdentifier {
                trustedSurfaceAuthority = trustedOverlayHasVisibleWindow(
                    processIdentifier: owner.processIdentifier,
                    forceRefresh: forceOverlayVisibilityRefresh
                )
            }
            // Remember a sampled hidden/restarted state. If the surface reopens
            // without a reliable deactivate callback, only a fresh keyDown can
            // create a new deliverable epoch.
            if currentTrustedOverlayProcessIdentifier
                != owner.processIdentifier {
                suspendDelivery(
                    token: owner.token,
                    reason: "overlay process unavailable"
                )
            } else if !trustedSurfaceAuthority,
                      !owner.deliverySuspended {
                // A pending activation is expected to precede visibility; an
                // already-deliverable lease observing a hidden window is not.
                suspendDelivery(
                    token: owner.token,
                    reason: "overlay window unavailable"
                )
            }
        case .appKitOpenSavePanel:
            let serviceAvailable =
                trustedAppKitOpenSavePanelServiceIsAvailable(
                    for: owner.bundleID
                )
            let windowAvailable = owner.systemPanelWindowNumber.map {
                FocusSystemPanelWindowRules.windowRemainsTrusted(
                    $0,
                    anchorProcessIdentifier: owner.processIdentifier,
                    onScreenWindows: onScreenWindowSnapshots()
                )
            } ?? false
            trustedSurfaceAuthority = serviceAvailable && windowAvailable
            if !serviceAvailable {
                suspendDelivery(
                    token: owner.token,
                    reason: "open/save panel service provenance unavailable"
                )
            } else if !windowAvailable,
                      !owner.deliverySuspended {
                suspendDelivery(
                    token: owner.token,
                    reason: "open/save panel window unavailable"
                )
            }
        }
        // A normal running application can briefly expose a PID before its
        // bundle ID. A trusted overlay instead validates its own system process
        // plus the unchanged foreground anchor captured by the key event.
        let authority = FocusHostRules.applicationAuthorityMatches(
            kind: owner.hostKind,
            leaseBundleID: owner.bundleID,
            leaseProcessIdentifier: owner.processIdentifier,
            foregroundAnchorBundleID: owner.foregroundAnchorBundleID,
            foregroundAnchorProcessIdentifier: owner.foregroundAnchorProcessIdentifier,
            currentFrontmostBundleID: frontmostApplication?.bundleIdentifier,
            currentFrontmostProcessIdentifier: frontmostApplication?.processIdentifier,
            currentTrustedOverlayProcessIdentifier:
                currentTrustedOverlayProcessIdentifier,
            trustedSurfaceAuthority: trustedSurfaceAuthority
        )
        if owner.hostKind.requiresTransientSurfaceAuthority {
            let anchorAuthority = FocusHostRules.applicationAuthorityMatches(
                kind: owner.hostKind,
                leaseBundleID: owner.bundleID,
                leaseProcessIdentifier: owner.processIdentifier,
                foregroundAnchorBundleID: owner.foregroundAnchorBundleID,
                foregroundAnchorProcessIdentifier:
                    owner.foregroundAnchorProcessIdentifier,
                currentFrontmostBundleID:
                    frontmostApplication?.bundleIdentifier,
                currentFrontmostProcessIdentifier:
                    frontmostApplication?.processIdentifier,
                currentTrustedOverlayProcessIdentifier:
                    owner.hostKind == .nonactivatingSystemOverlay
                        ? owner.processIdentifier
                        : nil,
                trustedSurfaceAuthority: true
            )
            if !anchorAuthority.bundle || !anchorAuthority.process {
                // Authority is monotonic: an observed anchor mismatch cannot
                // become trusted again merely because the old app returns.
                suspendDelivery(
                    token: owner.token,
                    reason: "transient surface foreground anchor changed"
                )
            }
        }
        guard FocusTargetRules.allows(
            tokenIsCurrent: epochs.isCurrent(owner.token),
            expectedTokenMatches: token == nil || owner.token == token,
            externalTarget: !requireExternal || owner.isExternalTarget,
            deliveryTrusted: !owner.deliverySuspended,
            controllerAlive: owner.controller != nil,
            clientAlive: client != nil,
            clientIdentityMatches: client.map { ObjectIdentifier($0 as AnyObject) == owner.clientIdentity } ?? false,
            controllerClientIdentityMatches: controllerClient.map {
                ObjectIdentifier($0 as AnyObject) == owner.clientIdentity
            } ?? false,
            clientBundleMatches: client.map { ($0.bundleIdentifier() ?? "unknown") == owner.bundleID } ?? false,
            frontmostApplicationMatches: authority.bundle,
            frontmostProcessMatches: authority.process
        ) else { return nil }
        return owner
    }

    /// Exact current client eligible for candidate interaction. Unlike buffered
    /// delivery this may be an ETInput-owned editor, but it still requires a
    /// trusted lifecycle plus the current bundle and process.
    func interactionTarget(
        expected token: FocusToken? = nil,
        forceOverlayVisibilityRefresh: Bool = false
    ) -> FocusLease? {
        validatedTarget(
            expected: token,
            requireExternal: false,
            forceOverlayVisibilityRefresh: forceOverlayVisibilityRefresh
        )
    }

    /// Returns a target only while the exact external app/client lease is live.
    /// There is deliberately no recent-controller or last-client fallback.
    func liveTarget(
        expected token: FocusToken? = nil,
        forceOverlayVisibilityRefresh: Bool = false
    ) -> FocusLease? {
        validatedTarget(
            expected: token,
            requireExternal: true,
            forceOverlayVisibilityRefresh: forceOverlayVisibilityRefresh
        )
    }

    /// Workspace activation can arrive before or after IMK focus callbacks.
    /// Ordinary leases survive only an exact same-app notification. Since
    /// The system surface itself never activates, so any such notification
    /// retires its overlay lease fail-closed.
    func invalidateIfFrontmostChanged(to application: NSRunningApplication?) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner else { return nil }
        let bundleID = application?.bundleIdentifier
        let processIdentifier = application?.processIdentifier
        guard FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: owner.hostKind,
            leaseBundleID: owner.bundleID,
            leaseProcessIdentifier: owner.processIdentifier,
            foregroundAnchorBundleID: owner.foregroundAnchorBundleID,
            foregroundAnchorProcessIdentifier:
                owner.foregroundAnchorProcessIdentifier,
            activatedBundleID: bundleID,
            activatedProcessIdentifier: processIdentifier
        ) else { return nil }
        if owner.hostKind.requiresTransientSurfaceAuthority {
            // Finalize without touching the now-hidden system proxy; unresolved
            // text is recovered to the buffer instead.
            owner.deliverySuspended = true
        }
        _ = epochs.deactivate(owner.token)
        self.owner = nil
        IMELog.write("focus invalidated token=\(owner.token) activated=\(bundleID ?? "unknown")")
        onInvalidated?(owner.token)
        onChange?()
        return owner
    }

    func invalidateAll(reason: String) -> FocusLease? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owner else { return nil }
        if owner.hostKind.requiresTransientSurfaceAuthority {
            // Global invalidations (notably input-source changes) can arrive
            // after a system surface hides without a deactivate callback. Never
            // settle composition through that stale nonactivating proxy.
            owner.deliverySuspended = true
        }
        _ = epochs.deactivate(owner.token)
        self.owner = nil
        IMELog.write("focus invalidated token=\(owner.token) reason=\(reason)")
        onInvalidated?(owner.token)
        onChange?()
        return owner
    }
}
