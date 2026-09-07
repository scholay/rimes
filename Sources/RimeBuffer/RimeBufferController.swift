import Cocoa
import InputMethodKit

// One librime instance per process (librime is global); SESSIONS are
// per-controller so composition never bleeds across fields. One shared
// candidate window (only one field composes at a time).
let rimeEngine = RimeEngine()
let candidateWindow = CandidateWindow()

enum BufferControlDisposition: Equatable {
    case passThrough
    case executeBufferAction
    case consumeOnly
}

enum BufferControlRoutingRules {
    static func disposition(bufferActive: Bool,
                            ownClient: Bool,
                            exactFocus: Bool) -> BufferControlDisposition {
        guard bufferActive, !ownClient else { return .passThrough }
        return exactFocus ? .executeBufferAction : .consumeOnly
    }
}

enum CandidateKeyboardRoutingRules {
    /// Candidate chrome owns navigation/commit keys, plus 1...9 only while the
    /// expanded matrix maps those digits onto its visible columns. Zero has no
    /// candidate-window action and must continue to librime like any other
    /// schema binding or printable input.
    static func ownsLocally(keycode: Int32, isExpanded: Bool) -> Bool {
        switch keycode {
        case RimeKey.left, RimeKey.right, RimeKey.down, RimeKey.up,
             RimeKey.return, RimeKey.space:
            return true
        case 0x31...0x39:
            return isExpanded
        default:
            return false
        }
    }
}

/// A committed string becomes visible as soon as the synchronous IMK host
/// insertion returns. Retire the old candidate projection before crossing that
/// re-entrant boundary so the next host callback can never observe or operate
/// on candidates belonging to text that is already on screen.
enum CommitPresentationRetirement {
    static func perform<Owner>(
        owner: Owner?,
        clearInline: (Owner) -> Void,
        hideCandidates: (Owner) -> Void
    ) {
        guard let owner else { return }
        clearInline(owner)
        hideCandidates(owner)
    }
}

enum BufferWorkbenchEscapeDisposition: Equatable {
    case passThrough
    case closeWorkbench
    case consumeOnly
}

/// A visible nonactivating workbench owns plain Escape independently from the
/// Buffer capture route. This is what lets Clipboard-only presentation close
/// without first turning text capture on. Stale external callbacks are still
/// swallowed so Escape cannot leak into a displaced host field.
enum BufferWorkbenchEscapeRoutingRules {
    static func disposition(
        isUnmodifiedEscape: Bool,
        workbenchVisible: Bool,
        ownClient: Bool,
        exactExternalFocus: Bool
    ) -> BufferWorkbenchEscapeDisposition {
        guard isUnmodifiedEscape, workbenchVisible, !ownClient else {
            return .passThrough
        }
        return exactExternalFocus ? .closeWorkbench : .consumeOnly
    }
}

enum BufferLogicalNavigationAction: Equatable {
    case moveToStart
    case moveToEnd
    case deleteForward
    case consume
}

/// Editing/navigation keys belong to the logical Buffer surface while its
/// exact capture route is active. Unsupported character-level movement is
/// consumed rather than leaking into the still-focused host field.
enum BufferLogicalNavigationRules {
    static func owns(keycode: Int32) -> Bool {
        switch keycode {
        case RimeKey.home, RimeKey.end, RimeKey.deleteForward,
             RimeKey.left, RimeKey.right, RimeKey.up, RimeKey.down,
             RimeKey.tab, RimeKey.pageUp, RimeKey.pageDown:
            return true
        default:
            return false
        }
    }

    static func action(keycode: Int32,
                       compositionSettled: Bool) -> BufferLogicalNavigationAction? {
        guard compositionSettled else { return nil }
        switch keycode {
        case RimeKey.home: return .moveToStart
        case RimeKey.end: return .moveToEnd
        case RimeKey.deleteForward: return .deleteForward
        case RimeKey.left, RimeKey.right, RimeKey.up, RimeKey.down,
             RimeKey.tab, RimeKey.pageUp, RimeKey.pageDown:
            return .consume
        default:
            return nil
        }
    }

    static func commandAction(selectorName: String)
        -> BufferLogicalNavigationAction? {
        switch selectorName {
        case "moveToBeginningOfParagraph:", "moveToBeginningOfLine:",
             "moveToBeginningOfDocument:", "moveToLeftEndOfLine:":
            return .moveToStart
        case "moveToEndOfParagraph:", "moveToEndOfLine:",
             "moveToEndOfDocument:", "moveToRightEndOfLine:":
            return .moveToEnd
        case "deleteForward:":
            return .deleteForward
        case "moveUp:", "moveDown:", "pageUp:", "pageDown:",
             "scrollPageUp:", "scrollPageDown:", "insertTab:",
             "insertBacktab:":
            return .consume
        default:
            return nil
        }
    }
}

enum BufferClipboardShortcut: Equatable {
    case selectAll
    case paste
    case copyGeneratedResult
}

/// `modifierFlags` is an aggregate bitset: pressing the second physical Shift,
/// Command, Option, or Control key can emit `flagsChanged` without changing
/// that bitset. The event type itself is therefore the stream-chord boundary;
/// a delta in the aggregate flags is not required.
enum StreamInputModifierBoundaryRules {
    static func closesPairing(eventType: NSEvent.EventType) -> Bool {
        eventType == .flagsChanged
    }
}

enum BufferClipboardShortcutRules {
    /// Source editing accepts both the user's Control convention and native
    /// macOS Command shortcuts. Generated-result Copy is intentionally exact
    /// Command+C only. Extra Shift/Option or Control+Command combinations
    /// remain host shortcuts and are never reinterpreted.
    static func shortcut(keycode: Int32?, mask: Int32) -> BufferClipboardShortcut? {
        let primary = mask & (RimeKey.controlMask | RimeKey.superMask)
        guard primary == RimeKey.controlMask || primary == RimeKey.superMask,
              mask & (RimeKey.shiftMask | RimeKey.altMask) == 0 else { return nil }
        switch keycode {
        case 0x61: return .selectAll
        case 0x76: return .paste
        case 0x63 where mask == RimeKey.superMask:
            return .copyGeneratedResult
        default: return nil
        }
    }
}

enum BufferClipboardPhysicalShortcutRules {
    static func shortcut(aKeyDown: Bool,
                         vKeyDown: Bool,
                         cKeyDown: Bool = false,
                         mask: Int32) -> BufferClipboardShortcut? {
        // A simultaneous A/V/C snapshot is ambiguous and must never turn an
        // unrelated Cocoa command into a workbench edit.
        let keysDown = [aKeyDown, vKeyDown, cKeyDown].filter { $0 }
        guard keysDown.count == 1 else { return nil }
        let keycode: Int32
        if aKeyDown {
            keycode = 0x61
        } else if vKeyDown {
            keycode = 0x76
        } else {
            keycode = 0x63
        }
        return BufferClipboardShortcutRules.shortcut(
            keycode: keycode,
            mask: mask
        )
    }
}

enum BufferClipboardCommandRules {
    static func shortcut(selectorName: String,
                         physicalShortcut: BufferClipboardShortcut?)
        -> BufferClipboardShortcut? {
        switch selectorName {
        case "selectAll:":
            return .selectAll
        case "paste:":
            return .paste
        case "copy:":
            // Unlike Select All and Paste, generated-result copying is owned
            // only by the exact physical Command+C gesture. A native Copy
            // callback without that live chord remains the host's action.
            return physicalShortcut == .copyGeneratedResult
                ? .copyGeneratedResult
                : nil
        // Cocoa's standard key-binding dictionary translates physical
        // Control+A/V before some native clients offer the event to IMK.
        // Require the matching live physical chord so real navigation keys
        // that share these selectors retain their native behavior.
        case "moveToBeginningOfParagraph:",
             "moveToBeginningOfLine:",
             "moveToLeftEndOfLine:":
            return physicalShortcut == .selectAll ? .selectAll : nil
        case "pageDown:", "scrollPageDown:":
            return physicalShortcut == .paste ? .paste : nil
        default:
            return nil
        }
    }
}

enum BufferClipboardTextRules {
    static let maximumBytes = 1_048_576

    static func validated(_ text: String?) -> String? {
        guard let text,
              !text.isEmpty,
              !text.contains("\0"),
              text.utf8.count <= maximumBytes else { return nil }
        return text
    }
}

enum BufferPluginKeyboardShortcutRules {
    /// Only the exact Command+Shift+Up/Down chord belongs to plugin cycling.
    /// Extra modifiers retain their host/Rime behavior.
    static func direction(keycode: Int32?, mask: Int32) -> Int? {
        guard mask == RimeKey.superMask | RimeKey.shiftMask else { return nil }
        switch keycode {
        case RimeKey.up: return -1
        case RimeKey.down: return 1
        default: return nil
        }
    }

    /// Runtime matching uses the user-configurable physical shortcut. The
    /// keysym helper above remains pure for legacy smoke coverage and Cocoa
    /// command fallbacks.
    static func direction(hardwareKeyCode: UInt16,
                          modifierFlags: NSEvent.ModifierFlags) -> Int? {
        if RimeShortcutPreferences.shortcut(for: .previousPlugin).matches(
            keyCode: hardwareKeyCode,
            modifiers: modifierFlags
        ) {
            return -1
        }
        if RimeShortcutPreferences.shortcut(for: .nextPlugin).matches(
            keyCode: hardwareKeyCode,
            modifiers: modifierFlags
        ) {
            return 1
        }
        return nil
    }

    /// Some AppKit clients translate Command+Shift+arrow to selection commands
    /// before IMK sees an NSEvent. Accept only the matching physical chord.
    static func commandDirection(selectorName: String,
                                 physicalDirection: Int?) -> Int? {
        guard let physicalDirection else { return nil }
        let upward = ["moveUp:",
                      "moveUpAndModifySelection:",
                      "moveToBeginningOfParagraph:",
                      "moveToBeginningOfParagraphAndModifySelection:",
                      "moveToBeginningOfDocumentAndModifySelection:",
                      "moveParagraphBackward:",
                      "moveParagraphBackwardAndModifySelection:"]
        let downward = ["moveDown:",
                        "moveDownAndModifySelection:",
                        "moveToEndOfParagraph:",
                        "moveToEndOfParagraphAndModifySelection:",
                        "moveToEndOfDocumentAndModifySelection:",
                        "moveParagraphForward:",
                        "moveParagraphForwardAndModifySelection:"]
        if physicalDirection < 0, upward.contains(selectorName) { return -1 }
        if physicalDirection > 0, downward.contains(selectorName) { return 1 }
        return nil
    }
}

enum BufferUnhandledPrintableRules {
    private static let excludedModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .function,
    ]

    static func capturedText(characters: String?,
                             modifierFlags: NSEvent.ModifierFlags,
                             bufferEnabled: Bool,
                             exactExternalFocus: Bool,
                             secureInputEnabled: Bool) -> String? {
        guard bufferEnabled,
              exactExternalFocus,
              !secureInputEnabled,
              isPlainASCIIPrintable(characters,
                                    modifierFlags: modifierFlags) else { return nil }
        return characters
    }

    /// A printable event whose focus lease was rejected cannot safely be
    /// attached to either the old or the new field. While an external buffer
    /// session is enabled, consume it fail-closed so it never leaks into the
    /// host. Secure input and shortcut-modified events retain native handling.
    static func shouldConsumeRejectedEvent(
        characters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        bufferEnabled: Bool,
        externalClient: Bool,
        secureInputEnabled: Bool
    ) -> Bool {
        bufferEnabled
            && externalClient
            && !secureInputEnabled
            && isPlainASCIIPrintable(characters,
                                     modifierFlags: modifierFlags)
    }

    private static func isPlainASCIIPrintable(
        _ characters: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        modifierFlags.intersection(excludedModifiers).isEmpty
            && characters?.isEmpty == false
            && characters?.unicodeScalars.allSatisfy({
                (0x20...0x7e).contains($0.value)
            }) == true
    }
}

enum BufferEnterSecureInputDisposition: Equatable {
    case normal
    case consumeWithoutGuardOrGeneration
}

enum BufferEnterSecureInputRules {
    static func disposition(secureInputEnabled: Bool)
        -> BufferEnterSecureInputDisposition {
        secureInputEnabled ? .consumeWithoutGuardOrGeneration : .normal
    }
}

enum BufferEnterPollDecision: Equatable {
    case wait(progress: Double)
    case sendNext
    case sendAll
}

enum BufferEnterGestureRules {
    static func pollDecision(isPhysicalDown: Bool,
                             elapsed: TimeInterval,
                             holdDelay: TimeInterval) -> BufferEnterPollDecision {
        // Prefer a detected release over elapsed wall time. If the run loop was
        // briefly stalled after a quick tap, it must not become an accidental
        // send-all when polling resumes late.
        guard isPhysicalDown else { return .sendNext }
        guard elapsed < holdDelay else { return .sendAll }
        return .wait(progress: min(max(elapsed / max(holdDelay, 0.1), 0), 1))
    }
}

enum BufferEnterCallbackDecision: Equatable {
    case consumeOwned
    case routeFresh
    case noOwnership
}

/// Delivery state and IMK callback ownership deliberately have separate
/// lifetimes. Sending the last transient block can make `BufferModel.active`
/// false before AppKit supplies keyUp / insertNewline:. Those callbacks still
/// belong to the already-consumed physical press and must never reach the host.
struct BufferEnterCallbackOwnership: Equatable {
    private(set) var suppressesKeyUp = false
    private(set) var suppressesNewlineCommand = false

    var ownsCallbacks: Bool { suppressesKeyUp || suppressesNewlineCommand }

    mutating func claimPress() {
        suppressesKeyUp = true
        suppressesNewlineCommand = true
    }

    mutating func prepareForKeyDown(isRepeat: Bool) -> BufferEnterCallbackDecision {
        if isRepeat, ownsCallbacks {
            return .consumeOwned
        }
        if !isRepeat {
            // A real new press retires callbacks that the previous host never
            // emitted. The same event must then be routed normally; it must not
            // require a second press.
            self = .init()
        }
        return .routeFresh
    }

    mutating func consumeKeyUp() -> BufferEnterCallbackDecision {
        guard suppressesKeyUp else { return .noOwnership }
        // Like newline commands, keyUp can be duplicated or arrive after a
        // later callback. Keep this generation suppressed until a definite
        // fresh non-repeat keyDown retires it.
        return .consumeOwned
    }

    func routeNewlineCommand() -> BufferEnterCallbackDecision {
        guard suppressesNewlineCommand else { return .routeFresh }
        // Keep suppression armed until the next definite fresh press. IMK may
        // emit duplicate or stale newline commands, and one must not consume
        // the protection needed by another callback from this generation.
        return .consumeOwned
    }
}

enum ShiftGestureReleaseDecision: Equatable {
    case replayStandaloneTap(rimeKeycode: Int32)
    case discard
}

/// `flagsChanged` reports the aggregate modifier mask, but `keyCode` still
/// identifies the physical modifier that changed. A Command release after a
/// Command-Shift global shortcut can therefore carry a Shift-only aggregate
/// mask. Treating that aggregate delta as a new Shift press makes the later
/// real Shift release look like a standalone language toggle. Only a physical
/// left/right Shift event may create or finish a Shift gesture.
enum ShiftModifierEventRules {
    static func rimeKeycode(forHardwareKeyCode keyCode: UInt16) -> Int32? {
        guard let eventKey = RimeKey.fromVirtualKeyCode(keyCode),
              eventKey == RimeKey.shiftL || eventKey == RimeKey.shiftR else {
            return nil
        }
        return eventKey
    }
}

/// librime treats a sub-500ms Shift press/release with no intervening Rime key
/// as its standalone ASCII switch. Defer that pair until physical release so
/// a modified/held gesture can be discarded before `commit_code` mutates the
/// current composition. Only a proven standalone tap is replayed to librime.
struct ShiftModifierGesture: Equatable {
    static let standaloneTapLimit: TimeInterval = 0.5

    let beganAt: TimeInterval
    let rimeKeycode: Int32
    let session: UInt64
    let schemaID: String
    private(set) var usedAsModifier = false

    init(beganAt: TimeInterval,
         rimeKeycode: Int32,
         session: UInt64,
         schemaID: String,
         beganWithOtherModifier: Bool = false) {
        self.beganAt = beganAt
        self.rimeKeycode = rimeKeycode
        self.session = session
        self.schemaID = schemaID
        usedAsModifier = beganWithOtherModifier
    }

    mutating func noteModifierUse() {
        usedAsModifier = true
    }

    mutating func cancelForFocusChange() {
        usedAsModifier = true
    }

    func releaseDecision(at releasedAt: TimeInterval,
                         currentSession: UInt64,
                         currentSchemaID: String) -> ShiftGestureReleaseDecision {
        guard session != 0,
              session == currentSession,
              schemaID == currentSchemaID else { return .discard }
        let elapsed = max(0, releasedAt - beganAt)
        guard !usedAsModifier, elapsed < Self.standaloneTapLimit else {
            return .discard
        }
        return .replayStandaloneTap(rimeKeycode: rimeKeycode)
    }
}

/// Process-wide evidence that a registered Carbon command consumed Shift as
/// part of a global shortcut. Carbon and IMK can deliver their callbacks in
/// either order, and host calls made while opening the workbench can re-enter
/// IMK or move the eventual flagsChanged callback to another controller. A
/// timestamp tombstone follows the physical gesture instead of one controller
/// instance. It is intentionally not consumed by the first matching release:
/// duplicate/cross-controller releases from the same physical cycle must all
/// be discarded. A later standalone Shift starts after `hotKeyAt` and therefore
/// cannot match stale evidence.
struct GlobalHotKeyShiftTombstone: Equatable {
    private(set) var hotKeyAt: TimeInterval?
    private(set) var route: GlobalHotKeyRoute = .ignore

    @discardableResult
    mutating func record(route: GlobalHotKeyRoute,
                         eventTimestamp: TimeInterval,
                         shortcutUsesShift: Bool) -> Bool {
        guard route != .ignore,
              shortcutUsesShift,
              eventTimestamp.isFinite,
              eventTimestamp >= 0 else { return false }
        if let hotKeyAt, eventTimestamp < hotKeyAt {
            // Never let a delayed Carbon callback replace newer evidence.
            return false
        }
        hotKeyAt = eventTimestamp
        self.route = route
        return true
    }

    /// Suppress only when the Carbon event lies inside the exact physical
    /// Shift interval. This remains valid across controller replacement and
    /// duplicate releases, while a standalone Shift completed before the hot
    /// key or begun afterwards can never be swallowed by stale evidence.
    func suppressesRelease(beganAt: TimeInterval?,
                           releasedAt: TimeInterval) -> Bool {
        guard let hotKeyAt,
              let beganAt,
              beganAt.isFinite,
              releasedAt.isFinite,
              beganAt <= hotKeyAt,
              hotKeyAt <= releasedAt else { return false }
        let elapsed = releasedAt - beganAt
        return elapsed >= 0
            && elapsed < ShiftModifierGesture.standaloneTapLimit
    }
}

/// Identity shared by the Carbon and NSEvent wrappers of one physical key
/// event. `CGEvent.timestamp` is an integer token from the underlying event;
/// unlike `GetEventTime` and `NSEvent.timestamp`, it does not require comparing
/// floating-point values obtained through two framework adapters.
struct GlobalHotKeyPrimaryKeyEventIdentity: Equatable, Hashable {
    enum Phase: Equatable, Hashable {
        case keyDown
        case keyUp
    }

    let keyCode: UInt16
    let phase: Phase
    let cgTimestamp: UInt64

    init?(keyCode: UInt16, phase: Phase, cgTimestamp: UInt64) {
        guard cgTimestamp > 0 else { return nil }
        self.keyCode = keyCode
        self.phase = phase
        self.cgTimestamp = cgTimestamp
    }

    static func from(_ event: NSEvent) -> Self? {
        let phase: Phase
        switch event.type {
        case .keyDown: phase = .keyDown
        case .keyUp: phase = .keyUp
        default: return nil
        }
        guard let cgEvent = event.cgEvent else { return nil }
        return Self(
            keyCode: event.keyCode,
            phase: phase,
            cgTimestamp: cgEvent.timestamp
        )
    }
}

/// Carbon can claim a registered shortcut before or after InputMethodKit sees
/// a duplicate callback for the shortcut's primary key. Keep a process-wide
/// ledger of exact underlying event identities. The fallback floating clocks
/// are consulted only when neither side exposes a CGEvent identity, avoiding a
/// broad suppression window that could swallow the next ordinary same-key tap.
struct GlobalHotKeyPrimaryKeyTombstone: Equatable {
    enum Disposition: Equatable {
        case passThrough
        case consume
    }

    struct Evaluation: Equatable {
        let disposition: Disposition
        let deltaMicroseconds: Int64?
        let route: GlobalHotKeyRoute
    }

    private struct RecentEvent: Equatable {
        let identity: GlobalHotKeyPrimaryKeyEventIdentity
        let route: GlobalHotKeyRoute
    }

    private static let recentEventCapacity = 8

    private(set) var keyCode: UInt16?
    /// Carbon EventTime values. They are never compared with NSEvent time.
    private(set) var pressedAtMicroseconds: Int64?
    private(set) var releasedAtMicroseconds: Int64?
    /// NSEvent timestamp values used only for identity-less IMK fallback.
    private(set) var imkPressedAtMicroseconds: Int64?
    private(set) var imkReleasedAtMicroseconds: Int64?
    private(set) var pressedEventIdentity: GlobalHotKeyPrimaryKeyEventIdentity?
    private(set) var releasedEventIdentity: GlobalHotKeyPrimaryKeyEventIdentity?
    private(set) var route: GlobalHotKeyRoute = .ignore
    private(set) var action: GlobalHotKeyAction?
    private(set) var matchedKeyDown = false
    private var recentEvents: [RecentEvent] = []

    static func timestampMicroseconds(_ timestamp: TimeInterval) -> Int64? {
        guard timestamp.isFinite, timestamp >= 0,
              timestamp <= Double(Int64.max) / 1_000_000 else { return nil }
        return Int64((timestamp * 1_000_000).rounded())
    }

    @discardableResult
    mutating func record(
        action: GlobalHotKeyAction,
        route: GlobalHotKeyRoute,
        keyCode: UInt16,
        eventTimestamp: TimeInterval,
        eventIdentity: GlobalHotKeyPrimaryKeyEventIdentity? = nil
    ) -> Bool {
        guard route != .ignore else { return false }
        let timestamp = Self.timestampMicroseconds(eventTimestamp)
        let identity = validatedIdentity(
            eventIdentity,
            keyCode: keyCode,
            phase: .keyDown
        )
        if let identity {
            remember(identity, route: route)
        }
        guard timestamp != nil || identity != nil else { return false }
        let attachesToIMKFirstRecord = self.action == action
            && self.keyCode == keyCode
            && pressedAtMicroseconds == nil
            && imkPressedAtMicroseconds != nil
            && releasedAtMicroseconds == nil
        if !attachesToIMKFirstRecord,
           let pressedAtMicroseconds,
           let timestamp,
           timestamp < pressedAtMicroseconds {
            return false
        }
        if attachesToIMKFirstRecord {
            pressedAtMicroseconds = timestamp
            if pressedEventIdentity == nil {
                pressedEventIdentity = identity
            }
            self.route = route
            return true
        }
        self.keyCode = keyCode
        self.pressedAtMicroseconds = timestamp
        releasedAtMicroseconds = nil
        imkPressedAtMicroseconds = nil
        imkReleasedAtMicroseconds = nil
        pressedEventIdentity = identity
        releasedEventIdentity = nil
        self.route = route
        self.action = action
        matchedKeyDown = false
        return true
    }

    @discardableResult
    mutating func recordRelease(
        action: GlobalHotKeyAction,
        eventTimestamp: TimeInterval,
        eventIdentity: GlobalHotKeyPrimaryKeyEventIdentity? = nil
    ) -> Bool {
        guard self.action == action, let keyCode else { return false }
        let timestamp = Self.timestampMicroseconds(eventTimestamp)
        let identity = validatedIdentity(
            eventIdentity,
            keyCode: keyCode,
            phase: .keyUp
        )
        if let identity {
            remember(identity, route: route)
        }
        guard timestamp != nil || identity != nil else { return false }
        if let pressedAtMicroseconds,
           let timestamp,
           timestamp < pressedAtMicroseconds {
            return false
        }
        if let timestamp {
            releasedAtMicroseconds = max(
                releasedAtMicroseconds ?? pressedAtMicroseconds ?? timestamp,
                timestamp
            )
        }
        releasedEventIdentity = identity
        return true
    }

    /// Consume an exact keyDown already proven to belong to a live Carbon
    /// registration. This is the order-independent half of the tombstone: IMK
    /// can establish the record before Carbon, or attach itself to a record
    /// Carbon established first. The caller performs the exact modifier match,
    /// so this path never claims an ordinary unmodified press of the same key.
    mutating func observeRegisteredKeyDown(
        action: GlobalHotKeyAction,
        route: GlobalHotKeyRoute,
        keyCode incomingKeyCode: UInt16,
        eventTimestamp: TimeInterval,
        eventIdentity: GlobalHotKeyPrimaryKeyEventIdentity? = nil
    ) -> Evaluation {
        guard route != .ignore else {
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: nil,
                route: .ignore
            )
        }
        let incomingTimestamp = Self.timestampMicroseconds(eventTimestamp)
        let identity = validatedIdentity(
            eventIdentity,
            keyCode: incomingKeyCode,
            phase: .keyDown
        )
        if let identity {
            remember(identity, route: route)
        }

        let priorTimestamp = imkPressedAtMicroseconds
        let delta = priorTimestamp.flatMap { prior in
            incomingTimestamp.map { $0 - prior }
        }
        let identityMatchesCurrent = identity != nil
            && identity == pressedEventIdentity
        let belongsToCurrentRecord = self.action == action
            && keyCode == incomingKeyCode
            && (identityMatchesCurrent
                || priorTimestamp == nil
                || priorTimestamp.flatMap { prior in
                    incomingTimestamp.map { incoming in
                        incoming >= prior
                            && imkReleasedAtMicroseconds.map {
                                incoming <= $0
                            } != false
                    }
                } == true)

        if belongsToCurrentRecord {
            matchedKeyDown = true
            imkPressedAtMicroseconds = incomingTimestamp
            imkReleasedAtMicroseconds = nil
            if pressedEventIdentity == nil {
                pressedEventIdentity = identity
            }
        } else if priorTimestamp == nil
                    || incomingTimestamp == nil
                    || incomingTimestamp.flatMap({ incoming in
                        priorTimestamp.map { incoming >= $0 }
                    }) == true {
            self.keyCode = incomingKeyCode
            pressedAtMicroseconds = nil
            releasedAtMicroseconds = nil
            imkPressedAtMicroseconds = incomingTimestamp
            imkReleasedAtMicroseconds = nil
            pressedEventIdentity = identity
            releasedEventIdentity = nil
            self.route = route
            self.action = action
            matchedKeyDown = true
        }

        let reportedDelta: Int64? = delta ?? (priorTimestamp == nil ? 0 : nil)
        return Evaluation(
            disposition: .consume,
            deltaMicroseconds: reportedDelta,
            route: route
        )
    }

    mutating func evaluate(
        eventType: NSEvent.EventType,
        keyCode incomingKeyCode: UInt16,
        eventTimestamp: TimeInterval,
        eventIdentity: GlobalHotKeyPrimaryKeyEventIdentity? = nil
    ) -> Evaluation {
        let evaluatedRoute = route
        guard eventType == .keyDown || eventType == .keyUp else {
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: nil,
                route: evaluatedRoute
            )
        }
        let phase: GlobalHotKeyPrimaryKeyEventIdentity.Phase =
            eventType == .keyDown ? .keyDown : .keyUp
        let identity = validatedIdentity(
            eventIdentity,
            keyCode: incomingKeyCode,
            phase: phase
        )
        if let identity,
           let recent = recentEvents.last(where: { $0.identity == identity }) {
            if eventType == .keyDown,
               identity == pressedEventIdentity {
                matchedKeyDown = true
            }
            let delta = imkPressedAtMicroseconds.flatMap { pressed in
                Self.timestampMicroseconds(eventTimestamp).map { $0 - pressed }
            }
            return Evaluation(
                disposition: .consume,
                deltaMicroseconds: delta,
                route: recent.route
            )
        }

        guard let keyCode,
              incomingKeyCode == keyCode else {
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: nil,
                route: evaluatedRoute
            )
        }
        let incomingTimestamp = Self.timestampMicroseconds(eventTimestamp)
        let delta = imkPressedAtMicroseconds.flatMap { pressed in
            incomingTimestamp.map { $0 - pressed }
        }

        // If either wrapper exposed an underlying identity and it did not match
        // above, this is a different physical event. A keyDown must pass and
        // retire only the active record; exact completed identities stay in the
        // small recent ledger for a duplicate that arrives even later.
        if pressedEventIdentity != nil || identity != nil {
            if eventType == .keyUp,
               releasedEventIdentity == nil {
                releasedEventIdentity = identity
                if let identity {
                    remember(identity, route: evaluatedRoute)
                }
                if let incomingTimestamp {
                    imkReleasedAtMicroseconds = incomingTimestamp
                }
                return Evaluation(
                    disposition: .consume,
                    deltaMicroseconds: delta,
                    route: evaluatedRoute
                )
            }
            if eventType == .keyDown {
                resetActive()
            }
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: delta,
                route: evaluatedRoute
            )
        }

        guard let imkPressedAtMicroseconds else {
            // Carbon supplied no common identity and IMK did not observe the
            // registered chord first. A same-key keyDown is ambiguous with the
            // user's next ordinary press, so fail open and retire active debt.
            if eventType == .keyDown {
                resetActive()
            }
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: nil,
                route: evaluatedRoute
            )
        }

        guard let incomingTimestamp else {
            if eventType == .keyDown {
                resetActive()
            }
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: nil,
                route: evaluatedRoute
            )
        }
        let fallbackDelta = incomingTimestamp - imkPressedAtMicroseconds
        if let imkReleasedAtMicroseconds {
            if incomingTimestamp >= imkPressedAtMicroseconds,
               incomingTimestamp <= imkReleasedAtMicroseconds {
                if eventType == .keyDown { matchedKeyDown = true }
                return Evaluation(
                    disposition: .consume,
                    deltaMicroseconds: fallbackDelta,
                    route: evaluatedRoute
                )
            }
            if eventType == .keyDown,
               incomingTimestamp > imkReleasedAtMicroseconds {
                resetActive()
            }
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: fallbackDelta,
                route: evaluatedRoute
            )
        }
        if eventType == .keyDown {
            if fallbackDelta == 0 {
                matchedKeyDown = true
                return Evaluation(
                    disposition: .consume,
                    deltaMicroseconds: fallbackDelta,
                    route: evaluatedRoute
                )
            }
            if fallbackDelta > 0 {
                resetActive()
            }
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: fallbackDelta,
                route: evaluatedRoute
            )
        }
        guard fallbackDelta >= 0 else {
            return Evaluation(
                disposition: .passThrough,
                deltaMicroseconds: fallbackDelta,
                route: evaluatedRoute
            )
        }
        imkReleasedAtMicroseconds = incomingTimestamp
        return Evaluation(
            disposition: .consume,
            deltaMicroseconds: fallbackDelta,
            route: evaluatedRoute
        )
    }

    mutating func reset() {
        resetActive()
        recentEvents.removeAll()
    }

    private mutating func resetActive() {
        keyCode = nil
        pressedAtMicroseconds = nil
        releasedAtMicroseconds = nil
        imkPressedAtMicroseconds = nil
        imkReleasedAtMicroseconds = nil
        pressedEventIdentity = nil
        releasedEventIdentity = nil
        route = .ignore
        action = nil
        matchedKeyDown = false
    }

    private func validatedIdentity(
        _ identity: GlobalHotKeyPrimaryKeyEventIdentity?,
        keyCode: UInt16,
        phase: GlobalHotKeyPrimaryKeyEventIdentity.Phase
    ) -> GlobalHotKeyPrimaryKeyEventIdentity? {
        guard identity?.keyCode == keyCode,
              identity?.phase == phase else { return nil }
        return identity
    }

    private mutating func remember(
        _ identity: GlobalHotKeyPrimaryKeyEventIdentity,
        route: GlobalHotKeyRoute
    ) {
        recentEvents.removeAll { $0.identity == identity }
        recentEvents.append(RecentEvent(identity: identity, route: route))
        if recentEvents.count > Self.recentEventCapacity {
            recentEvents.removeFirst(
                recentEvents.count - Self.recentEventCapacity
            )
        }
    }
}

enum InputCaretGeometryRules {
    /// `attributes(forCharacterIndex:)` is relative to the inline session.
    /// Zero also asks for the current selection when no inline session exists.
    static let inlineSessionAnchorIndex = 0

    static func queryAtInlineSessionAnchor<Result>(
        _ query: (Int) -> Result
    ) -> Result {
        query(inlineSessionAnchorIndex)
    }
}

@objc(RimeBufferController)
final class RimeBufferController: IMKInputController {

    /// The controller currently owning focus — menu commands and F4 preference
    /// persistence route through the live session here.
    static var active: RimeBufferController? {
        InputFocusCoordinator.shared.interactionTarget()?.controller
    }

    /// Carbon consumes registered global-shortcut key events before IMK sees
    /// the accompanying Command/key press. Record process-wide timing only;
    /// mutating the owner's current gesture here would misclassify a standalone
    /// Shift that physically ended before the hot key but whose flags callback
    /// is still queued. Release-time timestamps provide the exact ordering.
    static func globalHotKeyWillPerform(
        _ action: GlobalHotKeyAction,
        _ route: GlobalHotKeyRoute,
        eventTimestamp: TimeInterval,
        primaryKeyEventTimestamp: TimeInterval,
        primaryKeyCode: UInt16,
        primaryKeyEventIdentity: GlobalHotKeyPrimaryKeyEventIdentity?,
        shortcutUsesShift: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if globalHotKeyPrimaryKeyTombstone.record(
            action: action,
            route: route,
            keyCode: primaryKeyCode,
            eventTimestamp: primaryKeyEventTimestamp,
            eventIdentity: primaryKeyEventIdentity
        ) {
            IMELog.write(
                "global hotkey primary-key tombstone armed route=\(route) "
                    + "keyCode=\(primaryKeyCode) "
                    + "cg_identity=\(primaryKeyEventIdentity != nil)"
            )
        }
        guard globalHotKeyShiftTombstone.record(
                route: route,
                eventTimestamp: eventTimestamp,
                shortcutUsesShift: shortcutUsesShift
              ) else { return }
        IMELog.write(
            "global hotkey Shift tombstone armed route=\(route)"
        )
    }

    @discardableResult
    static func globalHotKeyDidRelease(
        _ action: GlobalHotKeyAction,
        eventTimestamp: TimeInterval,
        primaryKeyEventIdentity: GlobalHotKeyPrimaryKeyEventIdentity?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard globalHotKeyPrimaryKeyTombstone.recordRelease(
            action: action,
            eventTimestamp: eventTimestamp,
            eventIdentity: primaryKeyEventIdentity
        ) else { return false }
        IMELog.write(
            "global hotkey primary-key release recorded action=\(action) "
                + "cg_identity=\(primaryKeyEventIdentity != nil)"
        )
        return true
    }

    private static let duplicateBackspaceCommandWindow: CFTimeInterval = 0.05
    private static let duplicateArrowCommandWindow: CFTimeInterval = 0.05
    private static let duplicateClipboardCommandWindow: CFTimeInterval = 0.5
    private static let duplicateWorkbenchEscapeCommandWindow: CFTimeInterval = 0.25
    private static let bufferEnterHoldDelay: TimeInterval = 0.6
    private static let bufferEnterPollInterval: TimeInterval = 0.02
    private static let keyboardLayoutOverrideCache = RimeKeyboardLayoutOverrideCache()
    /// Rime pages fetched per matrix batch — also the initial expand size, so
    /// the first ↓ costs the same as before and deeper rows load on demand.
    private static let expandedPageBatch = 3
    private static var globalHotKeyShiftTombstone =
        GlobalHotKeyShiftTombstone()
    private static var globalHotKeyPrimaryKeyTombstone =
        GlobalHotKeyPrimaryKeyTombstone()

    private var session: UInt64 = 0
    private var currentSchemaId = ""
    private var currentASCIIMode = false
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var shiftGesture: ShiftModifierGesture?
    private var focusToken: FocusToken?
    private var clipboardSearchOwnerToken: FocusToken?
    private var clipboardSearchPresentationRestoreGeneration: UInt64 = 0
    private var loggedInactiveInputSourceCallback = false
    private var lastBufferBackspaceKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferBackspaceCommandHandledAt: CFAbsoluteTime = 0
    private var lastBufferEnterKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowCommandHandledAt: CFAbsoluteTime = 0
    private var lastBufferArrowKeyDirection = 0
    private var lastBufferArrowCommandDirection = 0
    private var lastStreamAlternativeArrowKeyHandledAt: CFAbsoluteTime = 0
    private var lastStreamAlternativeArrowDirection = 0
    private var streamAlternativeNavigationKeysDown = Set<UInt16>()
    private var lastDerivedResultArrowKeyHandledAt: CFAbsoluteTime = 0
    private var lastDerivedResultArrowDirection = 0
    private var derivedResultNavigationKeysDown = Set<UInt16>()
    private var bufferPluginNavigationKeysDown = Set<UInt16>()
    private var lastBufferPluginArrowKeyHandledAt: CFAbsoluteTime = 0
    private var lastBufferPluginArrowDirection = 0
    private var bufferClipboardShortcutKeysDown = Set<UInt16>()
    private var lastBufferClipboardShortcutHandledAt: CFAbsoluteTime = 0
    private var lastBufferClipboardShortcutHandled: BufferClipboardShortcut?
    private var lastBufferClipboardShortcutClientIdentity: ObjectIdentifier?
    private var lastWorkbenchEscapeHandledAt: CFAbsoluteTime = 0
    private var lastWorkbenchEscapeClientIdentity: ObjectIdentifier?
    private var bufferEnterPending = false
    private var bufferEnterSuppressUntilPhysicalUp = false
    private var bufferEnterCallbackOwnership = BufferEnterCallbackOwnership()
    private var bufferEnterClient: IMKTextInput?
    private var bufferEnterOwner: FocusToken?
    private var bufferEnterUsesStreamInput = false
    /// Freeze both the selected owner and the concrete delivery source at
    /// keyDown. Focus alone is insufficient: a plugin switch during the same
    /// physical Return must not let keyUp deliver a different workspace.
    private var bufferEnterPluginOwner: PluginKey?
    private var bufferEnterDeliveryWorkspaceID: String?
    private var bufferEnterDeliverySourceIdentity: ObjectIdentifier?
    private var bufferEnterDeliveryGeneration: UInt64?
    private var bufferEnterHardwareKeyCode: CGKeyCode = 36
    private var bufferEnterStartedAt: CFAbsoluteTime = 0
    private var bufferEnterPollTimer: Timer?
    /// A Return that settles composition while the workbench is active must
    /// stage that text even when the active mode came from a transient external
    /// block. Without this scoped override, chord replay could drain straight
    /// into the host field before the gesture has a chance to suppress Return.
    private var forcedBufferCaptureDepth = 0
    private var candidateOptionSelecting = false
    private var candidateOptionClient: IMKTextInput?
    private let chordClientRoutingGate = ChordClientRoutingGate()
    private let composition = CompositionSession()
    private let chord = ChordController()
    /// Snapshot and focus identity from immediately before a FlyYao batch.
    /// Regular settlement uses it for exact left/right recombination; failure
    /// recovery uses the same base to preserve all pre-existing raw input.
    private var pendingFlyChordBase: (context: RimeContextModel,
                                      policy: FlyChordSettlementPolicy,
                                      profile: ChordKeymapProfile,
                                      owner: FocusToken,
                                      clientIdentity: ObjectIdentifier)?
    private var mutualPairingState = FlyChordMutualPairingState()
    private var chordDurationObserver: NSObjectProtocol?
    private var chordExtensionObserver: NSObjectProtocol?
    private var chordKeymapObserver: NSObjectProtocol?
    private var userDictionaryMaintenanceObserver: NSObjectProtocol?
    private var userDictionaryMaintenanceEndObserver: NSObjectProtocol?

    private var chordGated: Bool {
        FlyChordRoutingRules.shouldStage(schemaID: currentSchemaId,
                                         asciiMode: currentASCIIMode,
                                         extensionEnabled:
                                            ChordExtensionStore.shared.isEnabled)
    }
    private var flyChordSettlementPolicy: FlyChordSettlementPolicy {
        ChordExtensionStore.shared.settlementPolicy
    }

    private func shouldUseBufferCommands(client: IMKTextInput?) -> Bool {
        guard let client,
              let focusToken,
              BufferModel.shared.capturesInput(for: focusToken),
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else { return false }
        return !isOwnClient(client)
    }

    /// Consciousness-stream capture is intentionally stricter than ordinary
    /// buffer commands: persistent capture must be enabled and the exact
    /// external client must still own the lease. Sequential mode consumes
    /// physical a-z as continuous full pinyin. Both FlyYao modes stage the
    /// effective alphabet while preserving their same-batch/cross-batch
    /// settlement policy.
    private var streamInputModeSelected: Bool {
        focusToken.map { BufferModel.shared.capturesInput(for: $0) } == true
            && BufferPluginSelectionStore.shared.isSelected(
                StreamInputWorkspace.pluginKey
            )
    }

    private var streamInputChordRoute: StreamInputChordRoute? {
        StreamInputChordRoutingRules.route(for: ChordExtensionStore.shared)
    }

    private func streamInputLease(client: IMKTextInput) -> FocusLease? {
        guard streamInputModeSelected,
              !IsSecureEventInputEnabled(),
              let focusToken,
              let lease = InputFocusCoordinator.shared.liveTarget(
                expected: focusToken,
                forceOverlayVisibilityRefresh: true
              ),
              lease.controller === self,
              lease.clientIdentity == ObjectIdentifier(client as AnyObject) else {
            return nil
        }
        return lease
    }

    private func streamInputDisposition(keycode: Int32?,
                                        mask: Int32,
                                        exactExternalFocus: Bool,
                                        hasLiveComposition: Bool = false,
                                        chordRoute: StreamInputChordRoute?)
        -> StreamInputCaptureRules.Disposition {
        StreamInputCaptureRules.disposition(
            keycode: keycode,
            mask: mask,
            bufferEnabled: focusToken.map {
                BufferModel.shared.capturesInput(for: $0)
            } == true,
            pluginSelected: BufferPluginSelectionStore.shared.isSelected(
                StreamInputWorkspace.pluginKey
            ),
            secureInput: IsSecureEventInputEnabled(),
            exactExternalFocus: exactExternalFocus,
            hasLiveComposition: hasLiveComposition,
            chordSchemaID: chordRoute?.schemaID
        )
    }

    private func streamAlternativeDirection(keycode: Int32?, mask: Int32) -> Int? {
        StreamInputAlternativeNavigationRules.direction(keycode: keycode,
                                                        mask: mask)
    }

    /// Stream raw input and librime composition are mutually exclusive. The
    /// plugin-selection callback normally settles the old composition, but a
    /// delayed IMK callback can race that transition. Recheck and settle it on
    /// the exact event lease, then prove both local and librime state are idle
    /// before this same physical printable key is allowed into the raw rail.
    private func prepareForStreamInputCapture(client: IMKTextInput,
                                              lease: FocusLease) -> Bool {
        guard streamInputLease(client: client) === lease else { return false }

        var pending = chord.hasPending
            || composition.composing
            || !candidateWindow.rawInputForCommit.isEmpty
        if session != 0 {
            guard rimeEngine.isHealthy else { return false }
            let context = rimeEngine.getContext(session: session)
            pending = pending
                || context.active
                || !context.input.isEmpty
                || !context.preedit.isEmpty
        }

        if pending {
            // A local pending marker without a healthy session cannot be
            // committed faithfully. Consume the new stream key instead of
            // clearing or mixing that unresolved state into the raw rail.
            guard session != 0, rimeEngine.isHealthy else { return false }
            resolveComposition(
                client: client,
                owner: lease.token,
                externalTarget: lease.isExternalTarget,
                trustedLease: lease
            )
        }

        guard streamInputLease(client: client) === lease,
              !chord.hasPending,
              !composition.composing,
              candidateWindow.rawInputForCommit.isEmpty else { return false }
        if session != 0 {
            guard rimeEngine.isHealthy else { return false }
            let context = rimeEngine.getContext(session: session)
            guard !context.active,
                  context.input.isEmpty,
                  context.preedit.isEmpty else { return false }
        }
        return true
    }

    private var ownsActiveExternalBufferLease: Bool {
        guard let focusToken,
              BufferModel.shared.capturesInput(for: focusToken),
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self else { return false }
        return lease.isExternalTarget
    }

    private func bufferControlDisposition(client: IMKTextInput?) -> BufferControlDisposition {
        let ownClient = client.map(isOwnClient) ?? !ownsActiveExternalBufferLease
        return BufferControlRoutingRules.disposition(
            bufferActive: BufferModel.shared.active,
            ownClient: ownClient,
            exactFocus: shouldUseBufferCommands(client: client)
        )
    }

    private func bufferClipboardDisposition(client: IMKTextInput?) -> BufferControlDisposition {
        // Secure fields retain native shortcut handling. In particular, never
        // inspect NSPasteboard while macOS secure event input is active.
        guard !IsSecureEventInputEnabled() else { return .passThrough }
        return bufferControlDisposition(client: client)
    }

    private var generatedResultCopyAvailable: Bool {
        !IsSecureEventInputEnabled()
            && BufferWindowController.shared.canCopyGeneratedResult
    }

    private func bufferPluginShortcutDisposition(client: IMKTextInput?)
        -> BufferControlDisposition {
        // A protected workbench must neither reveal nor activate a plugin;
        // leave native Command+Shift+arrow selection intact in secure fields.
        guard !IsSecureEventInputEnabled() else { return .passThrough }
        return bufferControlDisposition(client: client)
    }

    private func shouldCaptureCommit(from client: IMKTextInput,
                                     externalTarget: Bool? = nil) -> Bool {
        !IsSecureEventInputEnabled()
            && (BufferModel.shared.capturesInput(for: focusToken)
                || forcedBufferCaptureDepth > 0)
            && (externalTarget ?? !isOwnClient(client))
    }

    private func shouldCaptureClipboardSearchCommit(from client: IMKTextInput) -> Bool {
        guard !IsSecureEventInputEnabled(), let focusToken else { return false }
        let captures = ClipboardHistoryWindowController.shared.capturesSearchInput(
            expected: focusToken,
            client: client
        )
        if captures { clipboardSearchOwnerToken = focusToken }
        return captures
    }

    @discardableResult
    private func appendClipboardSearchCommit(
        _ text: String,
        client: IMKTextInput
    ) -> Bool {
        guard let focusToken,
              ClipboardHistoryWindowController.shared.appendSearchText(
                text,
                expected: focusToken,
                client: client
              ) else { return false }
        BufferWindowController.shared.clearInlineComposition(owner: focusToken)
        candidateWindow.hide(owner: focusToken)
        clearCompositionPresentation(client: client)
        publishCompositionActive(false)
        IMELog.write("clipboard search commit accepted characters=\(text.count)")
        return true
    }

    private func withForcedBufferCapture<T>(_ body: () -> T) -> T {
        forcedBufferCaptureDepth += 1
        defer { forcedBufferCaptureDepth -= 1 }
        return body()
    }

    private func isOwnClient(_ client: IMKTextInput) -> Bool {
        if let lease = currentLease(matching: client) {
            return !lease.isExternalTarget
        }
        // Client classification is frozen when focus authority is adopted.
        // Never query an unowned proxy merely to recover its bundle ID.
        return false
    }

    private func clearCompositionPresentation(
        client: IMKTextInput,
        trustedLease: FocusLease? = nil
    ) {
        ClipboardHistoryWindowController.shared.clearSearchComposition()
        if let focusToken {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
        }
        // The selected input source can change synchronously while an IMK
        // proxy call is in flight. Once that happens, even an "empty" marked
        // text write belongs to the newly selected input method's field and is
        // therefore forbidden. Retire only our local bookkeeping here; the
        // input-source observer performs the remaining engine/focus cleanup.
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            composition.markCleared()
            IMELog.write("marked-text clear skipped; RIMES authority retired")
            return
        }
        let frozenLease = trustedLease.flatMap { lease in
            lease.controller === self
                && lease.clientIdentity == ObjectIdentifier(client as AnyObject)
                ? lease
                : nil
        } ?? currentLease(matching: client)
        guard let frozenLease else {
            composition.markCleared()
            IMELog.write("marked-text clear skipped; no frozen client lease")
            return
        }
        let requiresTransientSurfaceGate = frozenLease.hostKind
            .requiresTransientSurfaceAuthority
        if requiresTransientSurfaceGate {
            guard InputFocusCoordinator.shared.interactionTarget(
                    expected: frozenLease.token,
                    forceOverlayVisibilityRefresh: true
                  ) === frozenLease else {
                // Keep local composition bookkeeping correct without invoking
                // a system-surface proxy whose exact window disappeared.
                composition.markCleared()
                return
            }
        }
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            composition.markCleared()
            IMELog.write("marked-text clear abandoned after source change")
            return
        }
        composition.clear(client: client)
    }

    @discardableResult
    private func deliverDirectText(_ text: String,
                                   client: IMKTextInput,
                                   externalTarget: Bool? = nil) -> Bool {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            IMELog.write("direct insert blocked; RIMES authority retired")
            return false
        }
        let frozenLease = currentLease(matching: client)
        guard let frozenLease else {
            composition.markCleared()
            IMELog.write("direct insert blocked; no frozen client lease")
            return false
        }
        let requiresTransientSurfaceGate = frozenLease.hostKind
            .requiresTransientSurfaceAuthority
        if requiresTransientSurfaceGate {
            guard InputFocusCoordinator.shared.interactionTarget(
                    expected: frozenLease.token,
                    forceOverlayVisibilityRefresh: true
                  ) === frozenLease else {
                // Do not call clearMarkedText on a hidden system-surface proxy.
                composition.markCleared()
                IMELog.write("direct insert blocked; transient surface window authority unavailable")
                return false
            }
        }
        // Keep the host marked-text transaction intact for `insertText`, but
        // retire every auxiliary projection first. IMK client calls may
        // synchronously re-enter this controller after the committed text is
        // already visible; at that point the old candidate state must be gone.
        CommitPresentationRetirement.perform(
            owner: frozenLease.token,
            clearInline: { owner in
                BufferWindowController.shared.clearInlineComposition(
                    owner: owner
                )
            },
            hideCandidates: { owner in
                candidateWindow.hide(owner: owner)
            }
        )
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              Delivery.insert(text, into: client) else {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                clearCompositionPresentation(client: client)
            } else {
                composition.markCleared()
            }
            return false
        }
        composition.commitDidInsert()
        return true
    }

    private func currentLease(matching client: IMKTextInput? = nil) -> FocusLease? {
        guard let focusToken,
              let lease = InputFocusCoordinator.shared.lease(for: focusToken),
              lease.controller === self else { return nil }
        if let client,
           ObjectIdentifier(client as AnyObject) != lease.clientIdentity {
            return nil
        }
        return lease
    }

    private func cachedBundleID(for client: IMKTextInput) -> String {
        currentLease(matching: client)?.bundleID ?? "retired"
    }

    /// `IMKInputController.client()` is itself a host-proxy lookup. Keep every
    /// nil-sender/lifecycle fallback behind a live TIS check on both sides so a
    /// source switch cannot turn a convenience lookup into foreign-IME access.
    private func currentControllerClientWithSourceAuthority() -> IMKTextInput? {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else { return nil }
        let current = self.client()
        guard RimeInputSourceAuthority.currentSourceIsOwn() else { return nil }
        return current
    }

    private func currentCallbackClient(_ sender: Any?) -> IMKTextInput? {
        guard let client = sender as? IMKTextInput,
              let focusToken,
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else { return nil }
        return client
    }

    /// Some hosts translate Escape directly into `cancelOperation:` and omit
    /// the IMK client sender. Recover only the exact live external lease; an
    /// explicitly stale sender is never replaced by the current field.
    private func currentEscapeCommandClient(_ sender: Any?) -> IMKTextInput? {
        if sender is IMKTextInput {
            return currentCallbackClient(sender)
        }
        guard let focusToken,
              let lease = InputFocusCoordinator.shared.interactionTarget(
                expected: focusToken
              ),
              lease.controller === self,
              lease.isExternalTarget,
              let client = lease.client,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else {
            return nil
        }
        return client
    }

    /// Native AppKit clients may send a command-only callback with a nil or
    /// non-client sender after translating Control+A/V or Command+C through
    /// the standard key-binding dictionary. Recover only for a matching live
    /// physical chord and a fully revalidated current lease/controller client
    /// identity.
    private func currentClipboardCommandClient(
        _ sender: Any?,
        shortcut: BufferClipboardShortcut,
        physicalShortcut: BufferClipboardShortcut?
    ) -> IMKTextInput? {
        if sender is IMKTextInput {
            return currentCallbackClient(sender)
        }
        guard physicalShortcut == shortcut,
              let focusToken,
              let lease = InputFocusCoordinator.shared.liveTarget(
                expected: focusToken,
                forceOverlayVisibilityRefresh: true
              ),
              lease.controller === self,
              let leaseClient = lease.client,
              let controllerClient = currentControllerClientWithSourceAuthority(),
              ObjectIdentifier(leaseClient as AnyObject)
                == lease.clientIdentity,
              ObjectIdentifier(controllerClient as AnyObject)
                == lease.clientIdentity,
              RimeInputSourceAuthority.currentSourceIsOwn() else { return nil }
        return leaseClient
    }

    /// Lifecycle callbacks are less regular than key callbacks: some hosts
    /// pass nil/non-client senders, while others reuse one IMK proxy across
    /// fields and deliver the old field's deactivate late. Resolve only the
    /// current lease. A reused proxy makes lifecycle attribution unsafe until a
    /// fully validated keyDown proves the current field owns it; keyUp, flags,
    /// elapsed time, or activation alone never clear that latch.
    private func lifecycleLease(for sender: Any?, operation: String) -> FocusLease? {
        guard let lease = currentLease(), lease.client != nil else {
            IMELog.write("\(operation): no current focus lease")
            return nil
        }

        let explicitClient = sender as? IMKTextInput
        if let explicitClient,
           ObjectIdentifier(explicitClient as AnyObject) != lease.clientIdentity {
            IMELog.write("\(operation): stale explicit callback ignored")
            return nil
        }
        let implicitClient = currentControllerClientWithSourceAuthority()
        let implicitIdentityMatches = implicitClient.map {
            ObjectIdentifier($0 as AnyObject) == lease.clientIdentity
        } ?? false
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              FocusActivationRules.currentControllerClientMayApply(
            clientExists: implicitClient != nil,
            identityMatches: implicitIdentityMatches
        ) else {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                IMELog.write(
                    "\(operation): callback has no matching current controller client"
                )
                suspendUntrustedFocusLease(
                    lease,
                    reason: "\(operation) current client unavailable or mismatched"
                )
            } else {
                retireForInactiveInputSource(
                    reason: "input source changed during \(operation) client lookup",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return nil
        }

        let now = ProcessInfo.processInfo.systemUptime
        let leaseAge = max(0, now - lease.createdAtUptime)
        guard FocusActivationRules.lifecycleCallbackMayApply(
            now: now,
            suppressionUntil: lease.lifecycleSuppressionUntilUptime,
            leaseAge: leaseAge,
            senderIsExplicit: explicitClient != nil,
            clientIdentityWasReused: lease.clientIdentityWasReused
        ) else {
            IMELog.write("\(operation): lifecycle callback suppressed age=\(leaseAge)")
            suspendUntrustedFocusLease(lease,
                                       reason: "\(operation) lifecycle attribution")
            return nil
        }
        // A system surface can hide without notifying a new frontmost app.
        // Revalidate its exact authority here; a failed check suspends delivery
        // but still returns the lease for no-client Rime cleanup.
        InputFocusCoordinator.shared.refreshTransientSurfaceLifecycleTrust(lease)
        return lease
    }

    /// Revoke every client-bound asynchronous path before marking the lease
    /// untrusted. In particular a pending chord timer must resolve in Rime but
    /// must not drain a commit or clear marked text through a moved IMK proxy.
    private func suspendUntrustedFocusLease(_ lease: FocusLease, reason: String) {
        cancelFocusBoundGestures()
        chordClientRoutingGate.withIsolatedClientRouting {
            chord.flush()
        }
        mutualPairingState.reset()
        InputFocusCoordinator.shared.suspendDelivery(token: lease.token, reason: reason)
    }

    private func publishCompositionActive(_ active: Bool, markedRangeReliable: Bool = true) {
        guard let focusToken else { return }
        InputFocusCoordinator.shared.setCompositionActive(active, token: focusToken,
                                                          markedRangeReliable: markedRangeReliable)
    }

    // MARK: Init / teardown

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        chord.onFlush = { [weak self] keys, client in
            self?.replayChordReleases(keys, client: client)
        }
        chord.onDiscard = { [weak self] client in
            self?.finishDiscardedChord(client: client)
        }
        chord.duration = ChordSettings.duration
        // Settings ▸ 输入 can retune the chord window while this controller is
        // live; pick up the new value immediately instead of only on next focus.
        chordDurationObserver = NotificationCenter.default.addObserver(
            forName: .chordDurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.chord.duration = ChordSettings.duration
        }
        chordExtensionObserver = NotificationCenter.default.addObserver(
            forName: .chordExtensionDidChange,
            object: ChordExtensionStore.shared,
            queue: .main
        ) { [weak self] notification in
            self?.chordExtensionDidChange(notification)
        }
        chordKeymapObserver = NotificationCenter.default.addObserver(
            forName: .chordKeymapDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.chord.invalidate()
            self?.pendingFlyChordBase = nil
            self?.mutualPairingState.reset()
        }
        userDictionaryMaintenanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeUserDictionaryMaintenanceWillBegin,
            object: rimeEngine,
            queue: .main
        ) { [weak self] _ in
            self?.prepareForUserDictionaryMaintenance()
        }
        userDictionaryMaintenanceEndObserver = NotificationCenter.default.addObserver(
            forName: .rimeUserDictionaryMaintenanceDidEnd,
            object: rimeEngine,
            queue: .main
        ) { [weak self] _ in
            self?.finishUserDictionaryMaintenance()
        }
        // NOTE: candidateWindow is shared; its onSelect is wired ONCE in
        // main.swift to route through `active` — wiring it here per-controller
        // would leave clicks bound to whichever controller initialized last.
    }

    deinit {
        resetBufferEnterGesture()
        resetCandidateOptionGesture()
        chord.invalidate()
        if let chordDurationObserver {
            NotificationCenter.default.removeObserver(chordDurationObserver)
        }
        if let chordExtensionObserver {
            NotificationCenter.default.removeObserver(chordExtensionObserver)
        }
        if let chordKeymapObserver {
            NotificationCenter.default.removeObserver(chordKeymapObserver)
        }
        if let userDictionaryMaintenanceObserver {
            NotificationCenter.default.removeObserver(userDictionaryMaintenanceObserver)
        }
        if let userDictionaryMaintenanceEndObserver {
            NotificationCenter.default.removeObserver(userDictionaryMaintenanceEndObserver)
        }
        if Thread.isMainThread, let focusToken {
            _ = InputFocusCoordinator.shared.deactivate(controller: self, token: focusToken)
            candidateWindow.hide(owner: focusToken)
        }
        if session != 0 { rimeEngine.destroySession(session) }
    }

    // MARK: Server lifecycle (focus in/out per client)

    /// ETInput remains resident for process-global utility shortcuts after the
    /// user selects another input source. Reject callbacks from the retired IMK
    /// connection before they can adopt focus, set marked text, or consume a
    /// key intended for the newly selected input method.
    private func callbackHasCurrentInputSourceAuthority(
        operation: String
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentID = RimeInputSourceAuthority.currentInputSourceID()
        guard let currentID,
              RimeInputSourceAuthority.isOwnInputSourceID(currentID) else {
            retireForInactiveInputSource(
                reason: "inactive input source callback: \(operation)",
                currentInputSourceID: currentID
            )
            return false
        }
        // A transient nil TIS read retires IMK authority and the RIMES-only
        // shortcut while leaving standalone utilities registered. A later exact
        // IMK callback is fresh authority, so reconcile the full Carbon set even
        // if macOS never emits a second TIS notification.
        _ = GlobalHotKeyController.shared.setRuntimeEnabledForInputSource(true)
        loggedInactiveInputSourceCallback = false
        return true
    }

    /// No old IMK client is called from this path. The selected input source
    /// already owns that field, so only process-local Rime state and frozen
    /// delivery authority may be retired safely.
    private func retireForInactiveInputSource(
        reason: String,
        currentInputSourceID: String?
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        _ = GlobalHotKeyController.shared.setRuntimeEnabledForInputSource(false)
        let rejectedToken = focusToken

        // The stale IMK callback can arrive before the distributed TIS change
        // notification. Detach Clip first so focus invalidation observes a
        // passive window with no presentation owner and therefore cannot close
        // an already visible clipboard history surface.
        ClipboardHistoryWindowController.shared
            .inputSourceDidChangeAwayFromRIMES()
        clipboardSearchPresentationRestoreGeneration &+= 1
        if let lease = InputFocusCoordinator.shared.invalidateAll(reason: reason) {
            lease.controller?.finalizeProtectedSession(lease, reason: reason)
            candidateWindow.hide(owner: lease.token)
        }

        if let rejectedToken, focusToken == rejectedToken {
            cancelFocusBoundGestures()
            clipboardSearchOwnerToken = nil
            pendingFlyChordBase = nil
            mutualPairingState.reset()
            if session != 0 {
                rimeEngine.clearComposition(session: session)
            }
            composition.markCleared()
            BufferWindowController.shared.clearInlineComposition(
                owner: rejectedToken
            )
            candidateWindow.hide(owner: rejectedToken)
            if BufferModel.shared.captureFocusToken == rejectedToken {
                BufferModel.shared.routeDirectPreservingContent(reason: reason)
            }
            focusToken = nil
        } else if let captureToken = BufferModel.shared.captureFocusToken,
                  !InputFocusCoordinator.shared.isCurrent(captureToken) {
            BufferModel.shared.routeDirectPreservingContent(reason: reason)
        }

        ClipboardHistoryWindowController.shared.clearSearchComposition()
        BufferWindowController.shared.refresh()
        guard !loggedInactiveInputSourceCallback else { return }
        loggedInactiveInputSourceCallback = true
        IMELog.write(
            "\(reason) rejected current="
                + (currentInputSourceID ?? "unavailable")
        )
    }

    override func activateServer(_ sender: Any!) {
        guard callbackHasCurrentInputSourceAuthority(
            operation: "activate"
        ) else { return }
        // Seed from real hardware state — clearing to [] would desync the
        // flagsChanged delta stream whenever a modifier (esp. Caps Lock) is
        // held or locked across a focus change.
        lastModifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !lastModifiers.contains(.shift) {
            shiftGesture = nil
        } else {
            // A Shift that began outside this trusted focus can modify keys,
            // but its eventual release must never become a standalone toggle.
            shiftGesture?.cancelForFocusChange()
        }
        let activeClient: IMKTextInput? = (sender as? IMKTextInput)
            ?? currentControllerClientWithSourceAuthority()
        if let activeClient {
            guard adoptActivationFocus(client: activeClient) else {
                IMELog.write("activate: stale client callback rejected")
                return
            }
            // Match Squirrel's keyboard-layout policy. `last` deliberately
            // leaves the client's physical layout untouched; forcing ABC here
            // perturbs TextInputUI's per-document state (notably in WeChat).
            let keyboard = Self.resolveKeyboardLayoutOverride()
            if let layout = keyboard.layout {
                guard RimeInputSourceAuthority.currentSourceIsOwn() else {
                    retireForInactiveInputSource(
                        reason: "source changed during activation",
                        currentInputSourceID: RimeInputSourceAuthority
                            .currentInputSourceID()
                    )
                    return
                }
                let clientIdentity = ObjectIdentifier(activeClient as AnyObject)
                guard let lease = currentLease(matching: activeClient),
                      InputFocusCoordinator.shared.exactCurrentLease(
                        expected: lease.token,
                        controller: self,
                        clientIdentity: clientIdentity
                      ) === lease,
                      let controllerClient =
                        currentControllerClientWithSourceAuthority(),
                      ObjectIdentifier(controllerClient as AnyObject)
                        == clientIdentity,
                      InputFocusCoordinator.shared.exactCurrentLease(
                        expected: lease.token,
                        controller: self,
                        clientIdentity: clientIdentity
                      ) === lease else {
                    if RimeInputSourceAuthority.currentSourceIsOwn() {
                        IMELog.write(
                            "activate: keyboard override abandoned; focus changed"
                        )
                    } else {
                        retireForInactiveInputSource(
                            reason: "source changed before keyboard override",
                            currentInputSourceID: RimeInputSourceAuthority
                                .currentInputSourceID()
                        )
                    }
                    return
                }
                activeClient.overrideKeyboard(withKeyboardNamed: layout)
                guard RimeInputSourceAuthority.currentSourceIsOwn() else {
                    retireForInactiveInputSource(
                        reason: "source changed after keyboard override",
                        currentInputSourceID: RimeInputSourceAuthority
                            .currentInputSourceID()
                    )
                    return
                }
                guard let controllerClient =
                        currentControllerClientWithSourceAuthority(),
                      ObjectIdentifier(controllerClient as AnyObject)
                        == clientIdentity,
                      InputFocusCoordinator.shared.exactCurrentLease(
                        expected: lease.token,
                        controller: self,
                        clientIdentity: clientIdentity
                      ) === lease else {
                    if RimeInputSourceAuthority.currentSourceIsOwn() {
                        IMELog.write(
                            "activate: keyboard override completed after focus changed"
                        )
                    } else {
                        retireForInactiveInputSource(
                            reason: "source changed after keyboard override validation",
                            currentInputSourceID: RimeInputSourceAuthority
                                .currentInputSourceID()
                        )
                    }
                    return
                }
            }
            IMELog.write("activate: client=\(cachedBundleID(for: activeClient)) keyboard=\(keyboard.layout ?? "last") source=\(keyboard.source) cache=\(keyboard.cacheStatus.rawValue)")
        } else if !RimeInputSourceAuthority.currentSourceIsOwn() {
            retireForInactiveInputSource(
                reason: "input source changed while resolving activation client",
                currentInputSourceID:
                    RimeInputSourceAuthority.currentInputSourceID()
            )
            return
        } else if InputFocusCoordinator.shared.owner != nil {
            IMELog.write(
                "activate: missing current client; suspending global focus lease"
            )
            suspendGlobalFocusLeaseIfPresent(reason: "activate missing client")
        }
        guard rimeEngine.start() else {
            StatusMenu.shared.setHealthy(false)
            IMELog.write("activate: engine down — raw passthrough mode")
            // Buffer Return/Backspace isolation is a host contract, not a
            // librime feature. Install the idle marked guard even with no
            // healthy engine/session so Chromium cannot submit raw Return.
            if let activeClient {
                updateUI(client: activeClient)
            }
            return
        }
        StatusMenu.shared.setHealthy(true)
        _ = ensureSessionReady(applyPreference: true)
        if let activeClient {
            // Arm the idle guard during activation. Waiting for the first key
            // is too late for a field whose first key is Return.
            updateUI(client: activeClient)
        }
        BufferWindowController.shared.refresh()
    }

    /// Post-start initialization, shared by activateServer AND the key paths —
    /// an engine that recovers mid-session must still get the configured chord
    /// duration and schema gating before its first processKey.
    @discardableResult
    private func ensureSessionReady(applyPreference: Bool = false) -> Bool {
        guard !ChordKeymapActivationCoordinator.shared.isApplying else { return false }
        guard rimeEngine.isHealthy else {
            clearTransientCompositionAfterSessionFailure()
            return false
        }
        // Official user-dictionary maintenance closes all librime sessions.
        // A nonzero cached id is therefore not proof that this controller still
        // owns a session (also covers a missed lifecycle notification).
        if session != 0, !rimeEngine.sessionExists(session) {
            IMELog.write("rime session invalidated; recreating after maintenance")
            // Presses/releases are session-scoped. Never let a staged batch
            // created against the dead session settle into its replacement.
            chord.invalidate()
            pendingFlyChordBase = nil
            mutualPairingState.reset()
            session = 0
            currentSchemaId = ""
            currentASCIIMode = false
            shiftGesture = nil
            composition.markCleared()
            clearTransientCompositionAfterSessionFailure()
        }
        var fresh = false
        if session == 0 {
            session = rimeEngine.createSession()
            fresh = session != 0
        }
        guard session != 0 else {
            clearTransientCompositionAfterSessionFailure()
            return false
        }

        chord.duration = ChordSettings.duration

        if applyPreference || fresh {
            applyStoredPreferenceIfNeeded()
            // A reused controller may still cache my_combo after another
            // controller changed the global preference to melt_eng. Refresh
            // before the first key so chord gating follows the actual schema.
            refreshSchema()
        } else if currentSchemaId.isEmpty {
            refreshSchema()
        }
        return true
    }

    /// A Buffer preedit and its candidate panel are projections of one live
    /// librime session. If that session disappears, neither may outlive it.
    private func clearTransientCompositionAfterSessionFailure() {
        guard let focusToken else { return }
        ClipboardHistoryWindowController.shared.clearSearchComposition()
        BufferWindowController.shared.clearInlineComposition(owner: focusToken)
        candidateWindow.hide(owner: focusToken)
    }

    /// UserDictManager requires the LevelDB to be closed. The engine posts a
    /// synchronous main-thread notification before invoking it, giving every
    /// controller a chance to preserve trusted text and retire its per-client
    /// session without ever writing through a stale IMK proxy.
    private func prepareForUserDictionaryMaintenance() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelFocusBoundGestures()
        if let lease = currentLease() {
            if !lease.deliverySuspended,
               let client = lease.client,
               InputFocusCoordinator.shared.interactionTarget(expected: lease.token) === lease {
                resolveComposition(client: client,
                                   owner: lease.token,
                                   externalTarget: lease.isExternalTarget,
                                   isolateChordClientRouting: true,
                                   trustedLease: lease)
            } else {
                abandonCompositionWithoutClient(lease,
                                                reason: "user dictionary maintenance")
            }
        } else {
            chordClientRoutingGate.withIsolatedClientRouting {
                chord.flush()
            }
            mutualPairingState.reset()
            if session != 0 {
                rimeEngine.clearComposition(session: session)
            }
            composition.markCleared()
        }

        if session != 0 {
            rimeEngine.destroySession(session)
            session = 0
        }
        currentSchemaId = ""
        currentASCIIMode = false
        shiftGesture = nil
        candidateWindow.hideAll()
        IMELog.write("rime session retired for user dictionary maintenance")
    }

    private func finishUserDictionaryMaintenance() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let lease = currentLease(),
              let client = lease.client,
              InputFocusCoordinator.shared.interactionTarget(expected: lease.token) === lease,
              ensureSessionReady(applyPreference: true) else {
            return
        }
        updateUI(client: client)
        IMELog.write("rime session restored after user dictionary maintenance")
    }

    /// Resolve Squirrel's `keyboard_layout` setting without requiring a
    /// deployed `build/squirrel.yaml`. `last`/missing means no override;
    /// `default` is ABC; an explicit TIS layout id is passed through.
    private static func resolveKeyboardLayoutOverride()
        -> RimeKeyboardLayoutOverrideResolution {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let userDirectory = environment["RIMEBUFFER_USER_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent("Library/RimeBuffer", isDirectory: true)
        let squirrelDirectory = home.appendingPathComponent("Library/Rime", isDirectory: true)
        let candidates = [
            userDirectory.appendingPathComponent("build/squirrel.yaml"),
            userDirectory.appendingPathComponent("squirrel.custom.yaml"),
            userDirectory.appendingPathComponent("squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("build/squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.custom.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.yaml"),
        ]

        var visited: Set<String> = []
        let uniqueCandidates = candidates.filter { url in
            let path = url.standardizedFileURL.path
            return visited.insert(path).inserted
        }
        return keyboardLayoutOverrideCache.resolve(candidates: uniqueCandidates)
    }

    @discardableResult
    private func adoptActivationFocus(client: IMKTextInput) -> Bool {
        guard currentControllerClientMatches(client) else {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                suspendGlobalFocusLeaseIfPresent(
                    reason: "activation current client mismatch"
                )
            } else {
                retireForInactiveInputSource(
                    reason: "input source changed before activation",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return false
        }
        // NSEvent timestamps and systemUptime share the system-boot clock. A
        // small grace window admits a key already generated during activation
        // while still rejecting older callbacks queued for the prior field.
        let eventFloor = NSApp.currentEvent?.timestamp
            ?? max(0, ProcessInfo.processInfo.systemUptime
                - FocusActivationRules.provisionalConfirmationWindow)
        guard let activation = InputFocusCoordinator.shared.beginActivation(
            controller: self,
            client: client,
            eventFloor: eventFloor
        ) else {
            if !RimeInputSourceAuthority.currentSourceIsOwn() {
                retireForInactiveInputSource(
                    reason: "input source changed while beginning activation",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return false
        }
        applyFocusActivation(activation, client: client)
        return true
    }

    @discardableResult
    private func adoptEventFocus(client: IMKTextInput,
                                 eventTimestamp: TimeInterval,
                                 eventType: NSEvent.EventType) -> Bool {
        guard currentControllerClientMatches(client) else {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                suspendGlobalFocusLeaseIfPresent(
                    reason: "event current client mismatch"
                )
            } else {
                retireForInactiveInputSource(
                    reason: "input source changed before event focus",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return false
        }
        guard let activation = InputFocusCoordinator.shared.noteEvent(
            controller: self,
            client: client,
            eventTimestamp: eventTimestamp,
            eventType: eventType
        ) else {
            if !RimeInputSourceAuthority.currentSourceIsOwn() {
                retireForInactiveInputSource(
                    reason: "input source changed while adopting event focus",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return false
        }
        applyFocusActivation(activation, client: client)
        return true
    }

    private func currentControllerClientMatches(_ proposed: IMKTextInput) -> Bool {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            return false
        }
        let implicitClient = currentControllerClientWithSourceAuthority()
        return FocusActivationRules.currentControllerClientMayApply(
            clientExists: implicitClient != nil,
            identityMatches: implicitClient.map {
                ObjectIdentifier($0 as AnyObject) == ObjectIdentifier(proposed as AnyObject)
            } ?? false
        )
    }

    private func suspendGlobalFocusLeaseIfPresent(reason: String) {
        guard let lease = InputFocusCoordinator.shared.owner else { return }
        if let ownerController = lease.controller {
            ownerController.suspendUntrustedFocusLease(lease, reason: reason)
        } else {
            InputFocusCoordinator.shared.suspendDelivery(token: lease.token, reason: reason)
        }
    }

    private func applyFocusActivation(_ activation: InputFocusCoordinator.Activation,
                                      client: IMKTextInput) {
        guard focusActivationStillCurrent(
            activation,
            client: client,
            stage: "before apply"
        ) else { return }
        let focusChanged = focusToken != activation.token
        if focusChanged {
            BufferModel.shared.clearAllContentSelection()
            guard focusActivationStillCurrent(
                activation,
                client: client,
                stage: "after selection clear"
            ) else { return }
        }
        // Resolve the displaced session before exposing the new token. If the
        // same proxy is reused, a pending chord flush can otherwise publish the
        // old session's candidates under the new owner.
        if let displaced = activation.displaced {
            displaced.controller?.finalizeDisplacedFocus(displaced)
            guard focusActivationStillCurrent(
                activation,
                client: client,
                stage: "after displaced cleanup"
            ) else { return }
        }
        if focusChanged {
            // Visibility and staged content survive focus changes, but capture
            // authority never does. The newly focused field therefore starts
            // in ordinary direct-input mode until the user explicitly chooses
            // the Buffer logical input surface again.
            BufferModel.shared.routeDirectPreservingContent(
                reason: "focus changed to \(activation.token)"
            )
            guard focusActivationStillCurrent(
                activation,
                client: client,
                stage: "after buffer route reset"
            ) else { return }
        }
        focusToken = activation.token
        BufferWindowController.shared.focusedInputDidActivate(
            expected: activation.token
        )
    }

    /// Cleanup of a displaced IMK client and Buffer presentation callbacks can
    /// synchronously re-enter focus handling. Never publish the outer token
    /// after a newer activation has won, and retire all RIMES authority if the
    /// input source changed during that callback chain.
    private func focusActivationStillCurrent(
        _ activation: InputFocusCoordinator.Activation,
        client: IMKTextInput,
        stage: String
    ) -> Bool {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            retireForInactiveInputSource(
                reason: "input source changed \(stage) focus activation",
                currentInputSourceID:
                    RimeInputSourceAuthority.currentInputSourceID()
            )
            return false
        }
        let clientIdentity = ObjectIdentifier(client as AnyObject)
        guard let lease = InputFocusCoordinator.shared.exactCurrentLease(
            expected: activation.token,
            controller: self,
            clientIdentity: clientIdentity
        ),
        let controllerClient = currentControllerClientWithSourceAuthority(),
        ObjectIdentifier(controllerClient as AnyObject) == clientIdentity,
        InputFocusCoordinator.shared.exactCurrentLease(
            expected: activation.token,
            controller: self,
            clientIdentity: clientIdentity
        ) === lease
        else {
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                IMELog.write(
                    "focus activation apply abandoned stage=\(stage) "
                        + "token=\(activation.token)"
                )
            } else {
                retireForInactiveInputSource(
                    reason: "input source changed during \(stage) focus validation",
                    currentInputSourceID:
                        RimeInputSourceAuthority.currentInputSourceID()
                )
            }
            return false
        }
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            retireForInactiveInputSource(
                reason: "input source changed after \(stage) focus validation",
                currentInputSourceID:
                    RimeInputSourceAuthority.currentInputSourceID()
            )
            return false
        }
        return true
    }

    /// Resolve a lease that was replaced by a newer focus epoch. Candidate hide
    /// and composition-state writes are owner-checked, so a delayed cleanup can
    /// never erase the new controller's presentation.
    func finalizeDisplacedFocus(_ lease: FocusLease) {
        guard lease.controller === self else { return }
        cancelFocusBoundGestures()
        let replacement = InputFocusCoordinator.shared.owner
        let reusedProxy = replacement?.token != lease.token
            && replacement?.clientIdentity == lease.clientIdentity
        let displacedClient = lease.client
        if reusedProxy || lease.deliverySuspended || displacedClient == nil {
            abandonCompositionWithoutClient(
                lease,
                reason: reusedProxy
                    ? "reused client proxy"
                    : (displacedClient == nil ? "expired client" : "untrusted lifecycle")
            )
        } else {
            resolveComposition(client: displacedClient,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget,
                               isolateChordClientRouting: true,
                               trustedLease: lease)
        }
        if focusToken == lease.token {
            focusToken = nil
        }
    }

    /// Lock, sleep and privacy protection revoke the destination before any
    /// cleanup. Never call the old client from this path: recover the current
    /// Rime result to the enabled buffer, or discard it when capture is off.
    func finalizeProtectedSession(_ lease: FocusLease, reason: String) {
        guard lease.controller === self else { return }
        BufferModel.shared.clearAllContentSelection()
        cancelFocusBoundGestures()
        abandonCompositionWithoutClient(lease, reason: reason)
        if BufferModel.shared.captureFocusToken == lease.token {
            BufferModel.shared.routeDirectPreservingContent(reason: reason)
        }
        if focusToken == lease.token {
            focusToken = nil
        }
    }

    /// Once an application-level IMK proxy has moved to another field, sending
    /// the old session through that proxy would target the new field. Resolve
    /// entirely inside librime instead: preserve the result in the buffer when
    /// capture was enabled, otherwise discard the unconfirmed composition.
    private func abandonCompositionWithoutClient(_ lease: FocusLease, reason: String) {
        BufferWindowController.shared.clearInlineComposition(owner: lease.token)
        candidateWindow.hide(owner: lease.token)
        guard session != 0 else {
            composition.markCleared()
            candidateWindow.hide(owner: lease.token)
            return
        }

        chordClientRoutingGate.withIsolatedClientRouting {
            chord.flush()
        }
        mutualPairingState.reset()
        let rawInput = rimeEngine.getContext(session: session).input
        _ = rimeEngine.commitComposition(session: session)
        let commit = rimeEngine.takeCommit(session: session)
        let recovered = (commit?.isEmpty == false ? commit : nil)
            ?? (rawInput.isEmpty ? nil : rawInput)
        if BufferModel.shared.capturesInput(for: lease.token),
           lease.isExternalTarget,
           let recovered {
            BufferModel.shared.append(recovered)
            IMELog.write("focus \(reason); recovered composition to buffer \(IMELog.redact(recovered))")
        } else if let recovered {
            IMELog.write("focus \(reason); discarded unsafe composition \(IMELog.redact(recovered))")
        }
        rimeEngine.clearComposition(session: session)
        composition.markCleared()
        InputFocusCoordinator.shared.setCompositionActive(false, token: lease.token)
        candidateWindow.hide(owner: lease.token)
        BufferWindowController.shared.refresh()
    }

    override func deactivateServer(_ sender: Any!) {
        guard callbackHasCurrentInputSourceAuthority(
            operation: "deactivate"
        ) else { return }
        guard let lease = lifecycleLease(for: sender, operation: "deactivate"),
              let client = lease.client else {
            return
        }
        BufferModel.shared.clearAllContentSelection()
        cancelFocusBoundGestures()
        if lease.deliverySuspended {
            abandonCompositionWithoutClient(lease, reason: "deactivate after lifecycle suspension")
        } else {
            resolveComposition(client: client,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget,
                               trustedLease: lease)
        }
        if BufferModel.shared.captureFocusToken == lease.token {
            BufferModel.shared.routeDirectPreservingContent(
                reason: "input focus deactivated"
            )
        }
        _ = InputFocusCoordinator.shared.deactivate(controller: self, token: lease.token)
        if focusToken == lease.token { focusToken = nil }
    }

    override func commitComposition(_ sender: Any!) {
        guard callbackHasCurrentInputSourceAuthority(
            operation: "commitComposition"
        ) else { return }
        guard let lease = lifecycleLease(for: sender, operation: "commitComposition"),
              let client = lease.client else {
            return
        }
        if lease.deliverySuspended {
            abandonCompositionWithoutClient(lease, reason: "commit after lifecycle suspension")
        } else {
            resolveComposition(client: client,
                               owner: lease.token,
                               externalTarget: lease.isExternalTarget,
                               trustedLease: lease)
        }
        // Let the host finish the current command/blur first. If the exact
        // external lease survives, restore its idle guard before another key.
        DispatchQueue.main.async {
            RimeBufferController.refreshActiveUI()
        }
    }

    /// Safety net for paths that bypass IMK's callbacks (hostile apps on
    /// Cmd-Tab, status-menu restart, schema switch): resolve any in-flight
    /// chord + composition into the field NOW.
    func forceCommit() {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            IMELog.write("forceCommit ignored; RIMES authority retired")
            return
        }
        guard let lease = currentLease(), let client = lease.client else {
            IMELog.write("forceCommit ignored; no current focus lease")
            return
        }
        guard InputFocusCoordinator.shared.interactionTarget(expected: lease.token) === lease,
              focusToken == lease.token else {
            suspendUntrustedFocusLease(lease, reason: "force commit target validation")
            abandonCompositionWithoutClient(lease, reason: "force commit on untrusted target")
            return
        }
        resolveComposition(client: client,
                           owner: lease.token,
                           externalTarget: lease.isExternalTarget,
                           trustedLease: lease)
        if currentCallbackClient(client) != nil {
            updateUI(client: client)
        }
    }

    /// Commit-on-blur: flush the chord, commit what Rime holds, close the
    /// marked-text session. Safe to call redundantly.
    private func resolveComposition(client: IMKTextInput?,
                                    owner: FocusToken?,
                                    externalTarget: Bool? = nil,
                                    isolateChordClientRouting: Bool = false,
                                    trustedLease: FocusLease? = nil) {
        // `owner` may already be displaced from the coordinator. Retire that
        // exact lease's projections before commit-on-blur can call the old
        // client; owner-scoped cleanup cannot erase the replacement focus.
        CommitPresentationRetirement.perform(
            owner: owner,
            clearInline: { owner in
                BufferWindowController.shared.clearInlineComposition(
                    owner: owner
                )
            },
            hideCandidates: { owner in
                candidateWindow.hide(owner: owner)
            }
        )
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            chordClientRoutingGate.withIsolatedClientRouting {
                chord.flush()
            }
            mutualPairingState.reset()
            if session != 0 {
                rimeEngine.clearComposition(session: session)
            }
            composition.markCleared()
            if let owner {
                InputFocusCoordinator.shared.setCompositionActive(
                    false,
                    token: owner
                )
                candidateWindow.hide(owner: owner)
            }
            IMELog.write("composition resolved locally; RIMES authority retired")
            return
        }
        var frozenClientLease: FocusLease?
        if let client {
            let frozenLease = trustedLease.flatMap { lease in
                lease.controller === self
                    && lease.clientIdentity
                        == ObjectIdentifier(client as AnyObject)
                    && owner == lease.token
                    ? lease
                    : nil
            } ?? currentLease(matching: client)
            guard let frozenLease else {
                chordClientRoutingGate.withIsolatedClientRouting {
                    chord.flush()
                }
                mutualPairingState.reset()
                if session != 0 {
                    rimeEngine.clearComposition(session: session)
                }
                composition.markCleared()
                IMELog.write("composition discarded; no frozen client lease")
                return
            }
            frozenClientLease = frozenLease
            let requiresTransientSurfaceGate = frozenLease.hostKind
                .requiresTransientSurfaceAuthority
            guard !requiresTransientSurfaceGate || (
                owner == frozenLease.token
                    && InputFocusCoordinator.shared.interactionTarget(
                        expected: frozenLease.token,
                        forceOverlayVisibilityRefresh: true
                    ) === frozenLease
            ) else {
                suspendUntrustedFocusLease(
                    frozenLease,
                    reason: "transient surface composition target validation"
                )
                abandonCompositionWithoutClient(
                    frozenLease,
                    reason: "transient surface window unavailable"
                )
                return
            }
        }
        resetCandidateOptionGesture()
        if isolateChordClientRouting {
            chordClientRoutingGate.withIsolatedClientRouting {
                chord.flush()
            }
        } else {
            chord.flush()
        }
        mutualPairingState.reset()
        guard session != 0 else {
            // The buffer's idle marked guard can exist without librime. It
            // still must be retired on an exact trusted blur/deactivation.
            if let client, RimeInputSourceAuthority.currentSourceIsOwn() {
                clearCompositionPresentation(
                    client: client,
                    trustedLease: frozenClientLease
                )
            } else {
                composition.markCleared()
            }
            if let owner {
                InputFocusCoordinator.shared.setCompositionActive(false, token: owner)
                candidateWindow.hide(owner: owner)
            }
            return
        }
        if let client, RimeInputSourceAuthority.currentSourceIsOwn() {
            _ = rimeEngine.commitComposition(session: session)
            drainCommit(client, externalTarget: externalTarget)
            if RimeInputSourceAuthority.currentSourceIsOwn() {
                clearCompositionPresentation(
                    client: client,
                    trustedLease: frozenClientLease
                )
            } else {
                // `drainCommit` can synchronously re-enter the host. A source
                // switch during that call revokes the old proxy immediately.
                composition.markCleared()
            }
        } else {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
        }
        if let owner {
            InputFocusCoordinator.shared.setCompositionActive(false, token: owner)
            candidateWindow.hide(owner: owner)
        }
    }

    /// Called only by BufferDeliveryCoordinator for the exact live lease.
    func resolveCompositionForBufferDelivery(target: FocusLease) {
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              target.controller === self,
              InputFocusCoordinator.shared.liveTarget(
                expected: target.token,
                forceOverlayVisibilityRefresh: true
              ) === target,
              focusToken == target.token else { return }
        resolveComposition(client: target.client,
                           owner: target.token,
                           externalTarget: target.isExternalTarget,
                           trustedLease: target)
    }

    /// Closing the workbench or opening its editor must also settle a suspended
    /// lease, but an untrusted proxy cannot receive text. Recover into the
    /// buffer when possible and otherwise discard the unresolved session.
    func resolveCompositionForWorkbenchTransition(target: FocusLease) {
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              target.controller === self,
              InputFocusCoordinator.shared.isCurrent(target.token, controller: self),
              focusToken == target.token else { return }
        guard InputFocusCoordinator.shared.interactionTarget(expected: target.token) === target else {
            suspendUntrustedFocusLease(target, reason: "workbench transition target validation")
            abandonCompositionWithoutClient(target, reason: "workbench transition on untrusted target")
            return
        }
        resolveComposition(client: target.client,
                           owner: target.token,
                           externalTarget: target.isExternalTarget,
                           trustedLease: target)
    }

    /// Exact-target delivery used by the standalone Clipboard History window.
    /// The window retains only a FocusToken; this method resolves any remaining
    /// composition, revalidates the same lease/client, then enters the sole
    /// Delivery.insert path without mutating BufferModel.
    @discardableResult
    func deliverClipboardHistoryText(
        _ text: String,
        expected token: FocusToken
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !text.isEmpty,
              !IsSecureEventInputEnabled(),
              focusToken == token,
              let initial = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              initial.controller === self,
              initial.isExternalTarget,
              let initialClient = initial.client,
              ObjectIdentifier(initialClient as AnyObject)
                == initial.clientIdentity else { return false }

        if initial.compositionActive || composition.composing || chord.hasPending {
            resolveCompositionForWorkbenchTransition(target: initial)
        }

        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              focusToken == token,
              let current = InputFocusCoordinator.shared.liveTarget(
                expected: token,
                forceOverlayVisibilityRefresh: true
              ),
              current === initial,
              current.controller === self,
              current.isExternalTarget,
              let client = current.client,
              ObjectIdentifier(client as AnyObject) == current.clientIdentity else {
            return false
        }
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            return false
        }
        let delivered = deliverDirectText(
            text,
            client: client,
            externalTarget: true
        )
        if delivered,
           RimeInputSourceAuthority.currentSourceIsOwn(),
           InputFocusCoordinator.shared.liveTarget(
            expected: token,
            forceOverlayVisibilityRefresh: true
           ) === current {
            updateUI(client: client)
        }
        return delivered
    }

    /// Clipboard History owns a logical search field while leaving the real
    /// host client focused. These probes let the window defer editing keys to
    /// librime only while that exact search composition is alive.
    func clipboardSearchCompositionIsActive(
        expected token: FocusToken,
        client: IMKTextInput
    ) -> Bool {
        guard focusToken == token,
              shouldCaptureClipboardSearchCommit(from: client) else {
            return false
        }
        if chord.hasPending || composition.composing { return true }
        guard session != 0, rimeEngine.isHealthy else { return false }
        let context = rimeEngine.getContext(session: session)
        return context.active || !context.input.isEmpty || !context.preedit.isEmpty
    }

    /// A newly opened Clip search must start from an empty Rime context. Some
    /// prediction schemas retain candidates after ordinary host composition is
    /// inactive; borrowing that context would make the hotkey's late primary
    /// key or an old prediction appear as a search query.
    @discardableResult
    func beginClipboardSearch(expected target: FocusLease) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              target.controller === self,
              target.isExternalTarget,
              focusToken == target.token,
              let client = target.client,
              ObjectIdentifier(client as AnyObject) == target.clientIdentity,
              InputFocusCoordinator.shared.interactionTarget(
                expected: target.token
              ) === target else { return false }
        clipboardSearchPresentationRestoreGeneration &+= 1
        clipboardSearchOwnerToken = target.token
        chord.invalidate()
        pendingFlyChordBase = nil
        mutualPairingState.reset()
        if session != 0 {
            rimeEngine.clearComposition(session: session)
        }
        composition.markCleared()
        InputFocusCoordinator.shared.setCompositionActive(
            false,
            token: target.token
        )
        candidateWindow.hide(owner: target.token)
        ClipboardHistoryWindowController.shared.clearSearchComposition()
        return RimeInputSourceAuthority.currentSourceIsOwn()
            && focusToken == target.token
            && InputFocusCoordinator.shared.interactionTarget(
                expected: target.token
            ) === target
    }

    /// Return activates the selected history item, so an unfinished borrowed
    /// search preedit must be discarded before archive loading begins. Keep the
    /// search owner alive until `hide()` performs its normal exact-client
    /// marked-text cleanup; clearing ownership here would strand the host guard.
    @discardableResult
    func discardClipboardSearchCompositionForActivation(
        expected token: FocusToken,
        client: IMKTextInput
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              focusToken == token,
              shouldCaptureClipboardSearchCommit(from: client),
              clipboardSearchOwnerToken == token,
              let lease = InputFocusCoordinator.shared.interactionTarget(
                expected: token
              ),
              lease.controller === self,
              lease.clientIdentity == ObjectIdentifier(client as AnyObject)
        else { return false }
        clipboardSearchPresentationRestoreGeneration &+= 1
        let generation = clipboardSearchPresentationRestoreGeneration
        chord.invalidate()
        pendingFlyChordBase = nil
        mutualPairingState.reset()
        if session != 0 {
            rimeEngine.clearComposition(session: session)
        }
        composition.markCleared()
        InputFocusCoordinator.shared.setCompositionActive(false, token: token)
        candidateWindow.hide(owner: token)
        ClipboardHistoryWindowController.shared.clearSearchComposition()

        let clientIdentity = lease.clientIdentity
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  RimeInputSourceAuthority.currentSourceIsOwn(),
                  self.clipboardSearchPresentationRestoreGeneration
                    == generation,
                  self.clipboardSearchOwnerToken == token,
                  self.focusToken == token,
                  let current = InputFocusCoordinator.shared.interactionTarget(
                    expected: token
                  ),
                  current === lease,
                  current.clientIdentity == clientIdentity,
                  let currentClient = current.client,
                  ObjectIdentifier(currentClient as AnyObject)
                    == clientIdentity else { return }
            self.clearCompositionPresentation(client: currentClient)
        }
        return true
    }

    /// Closing/protecting the standalone search surface discards its unfinished
    /// query composition. It never commits that text into the external field.
    func cancelClipboardSearchComposition(
        expected token: FocusToken,
        restoreHostPresentation: Bool = true
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        clipboardSearchPresentationRestoreGeneration &+= 1
        let restoreGeneration = clipboardSearchPresentationRestoreGeneration
        guard clipboardSearchOwnerToken == token else { return }
        clipboardSearchOwnerToken = nil
        chord.invalidate()
        pendingFlyChordBase = nil
        mutualPairingState.reset()
        if session != 0 {
            rimeEngine.clearComposition(session: session)
        }
        // Cancelling Clip can run inside IMK's handle stack. Keep the synchronous
        // half process-local so it cannot re-enter the host through marked-text
        // calls while the original key callback is still unwinding.
        composition.markCleared()
        InputFocusCoordinator.shared.setCompositionActive(false, token: token)
        candidateWindow.hide(owner: token)
        ClipboardHistoryWindowController.shared.clearSearchComposition()

        // Freeze only local lease identity here. The foreign-input-source path
        // returns before resolving either weak client or IMKInputController's
        // current client, so it performs zero host client calls.
        guard restoreHostPresentation,
              RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              clipboardSearchOwnerToken == nil,
              focusToken == token,
              let frozenLease = InputFocusCoordinator.shared.lease(for: token),
              frozenLease.controller === self else { return }
        let frozenClientIdentity = frozenLease.clientIdentity

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let client = self.clipboardSearchPresentationRestoreClient(
                    expected: token,
                    generation: restoreGeneration,
                    clientIdentity: frozenClientIdentity
                  ) else { return }

            self.clearCompositionPresentation(client: client)

            // clearMarkedText can synchronously move focus. Restore normal Rime
            // presentation or Buffer's idle guard only if the exact same lease
            // and controller client survived that call.
            guard self.clipboardSearchPresentationRestoreClient(
                expected: token,
                generation: restoreGeneration,
                clientIdentity: frozenClientIdentity
            ) === client else { return }
            self.updateUI(client: client)
        }
    }

    /// Resolves the host client only after source, generation, token and lease
    /// preflight have succeeded. Keep the source check first: when another input
    /// method owns the field this helper must not touch either client proxy.
    private func clipboardSearchPresentationRestoreClient(
        expected token: FocusToken,
        generation: UInt64,
        clientIdentity: ObjectIdentifier
    ) -> IMKTextInput? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              clipboardSearchPresentationRestoreGeneration == generation,
              clipboardSearchOwnerToken == nil,
              !IsSecureEventInputEnabled(),
              focusToken == token,
              let lease = InputFocusCoordinator.shared.interactionTarget(
                expected: token
              ),
              lease.controller === self,
              lease.clientIdentity == clientIdentity,
              let leaseClient = lease.client,
              ObjectIdentifier(leaseClient as AnyObject) == clientIdentity,
              let controllerClient = currentControllerClientWithSourceAuthority(),
              ObjectIdentifier(controllerClient as AnyObject)
                == clientIdentity,
              RimeInputSourceAuthority.currentSourceIsOwn() else { return nil }
        return leaseClient
    }

    // MARK: Key routing

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        guard callbackHasCurrentInputSourceAuthority(
            operation: "handle"
        ) else { return false }
        let primaryKeyEventIdentity = GlobalHotKeyPrimaryKeyEventIdentity.from(
            event
        )
        if let registeredHotKey = GlobalHotKeyController.shared
            .registeredPrimaryKeyMatch(
                eventType: event.type,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            ) {
            let evaluation = Self.globalHotKeyPrimaryKeyTombstone
                .observeRegisteredKeyDown(
                    action: registeredHotKey.action,
                    route: registeredHotKey.route,
                    keyCode: registeredHotKey.keyCode,
                    eventTimestamp: event.timestamp,
                    eventIdentity: primaryKeyEventIdentity
                )
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).rawValue
            IMELog.write(
                "global hotkey registered primary-key callback "
                    + "delta_us=\(evaluation.deltaMicroseconds ?? 0) "
                    + "cg_identity=\(primaryKeyEventIdentity != nil) "
                    + "modifiers=\(modifiers) route=\(evaluation.route) "
                    + "disposition=\(evaluation.disposition)"
            )
            return evaluation.disposition == .consume
        }
        let hotKeyPrimaryEvaluation = Self.globalHotKeyPrimaryKeyTombstone
            .evaluate(
                eventType: event.type,
                keyCode: event.keyCode,
                eventTimestamp: event.timestamp,
                eventIdentity: primaryKeyEventIdentity
            )
        if hotKeyPrimaryEvaluation.deltaMicroseconds != nil
            || hotKeyPrimaryEvaluation.route != .ignore {
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask).rawValue
            let deltaMicrosecondsText = hotKeyPrimaryEvaluation.deltaMicroseconds
                .map(String.init) ?? "unavailable"
            IMELog.write(
                "global hotkey primary-key callback type=\(event.type.rawValue) "
                    + "delta_us=\(deltaMicrosecondsText) modifiers=\(modifiers) "
                    + "cg_identity=\(primaryKeyEventIdentity != nil) "
                    + "route=\(hotKeyPrimaryEvaluation.route) "
                    + "disposition=\(hotKeyPrimaryEvaluation.disposition)"
            )
        }
        if hotKeyPrimaryEvaluation.disposition == .consume {
            return true
        }
        if event.type == .keyDown,
           !event.isARepeat {
            // Any fresh physical press retires missing-release debt for that
            // key before another logical surface gets first refusal.
            bufferClipboardShortcutKeysDown.remove(event.keyCode)
            if lastBufferClipboardShortcutHandled == .copyGeneratedResult {
                lastBufferClipboardShortcutHandled = nil
                lastBufferClipboardShortcutHandledAt = 0
                lastBufferClipboardShortcutClientIdentity = nil
            }
        }
        if event.type == .keyDown,
           event.isARepeat,
           bufferClipboardShortcutKeysDown.contains(event.keyCode) {
            IMELog.write("buffer clipboard owned repeat consumed before routing")
            return true
        }
        if event.type == .keyUp,
           bufferClipboardShortcutKeysDown.remove(event.keyCode) != nil {
            // Copy closes Buffer synchronously. Consume its already-owned
            // release before focus adoption or a newly visible surface can
            // reinterpret it.
            IMELog.write("buffer clipboard owned keyUp consumed before routing")
            return true
        }
        if event.type == .keyUp {
            switch ClipboardHistoryWindowController.shared.route(
                event,
                client: client
            ) {
            case .handledBySurface:
                return true
            case .routeToRime, .passThrough:
                break
            }
        }
        guard adoptEventFocus(client: client,
                              eventTimestamp: event.timestamp,
                              eventType: event.type) else {
            let rejectedModifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
            let releasedModifiers = lastModifiers
                .subtracting(rejectedModifiers)
            let addedModifiers = rejectedModifiers
                .subtracting(lastModifiers)
            let shortcutModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift,
            ]
            if event.type == .flagsChanged,
               !releasedModifiers.isEmpty,
               addedModifiers.isEmpty,
               releasedModifiers.subtracting(shortcutModifiers).isEmpty,
               InputFocusCoordinator.shared
                .maySynchronizePendingOverlayModifierBaseline(
                    controller: self,
                    client: client,
                    eventTimestamp: event.timestamp
                ) {
                // A pending Spotlight activation intentionally rejects the
                // launcher-shortcut release. Keep the hardware baseline in sync
                // without feeding that untrusted transition into Rime.
                lastModifiers = rejectedModifiers
            }
            IMELog.write("handle: stale event rejected")
            if event.type == .keyDown {
                let disposition = BufferWorkbenchEscapeRoutingRules.disposition(
                    isUnmodifiedEscape: isUnmodifiedEscape(
                        keycode: keysym(for: event),
                        mask: RimeKey.modifierMask(from: event.modifierFlags)
                    ),
                    workbenchVisible: BufferWindowController.shared.isVisible,
                    ownClient: isOwnClient(client),
                    exactExternalFocus: false
                )
                if disposition == .consumeOnly {
                    noteWorkbenchEscapeHandled(client: client)
                    IMELog.write("buffer workbench escape consumed after stale event")
                    return true
                }
            }
            if event.type == .keyDown || event.type == .keyUp {
                if event.type == .keyUp,
                   bufferClipboardShortcutKeysDown.remove(event.keyCode) != nil {
                    IMELog.write("buffer clipboard keyUp consumed after stale event")
                    return true
                }
                if let shortcut = BufferClipboardShortcutRules.shortcut(
                    keycode: keysym(for: event),
                    mask: RimeKey.modifierMask(from: event.modifierFlags)
                ), (shortcut != .copyGeneratedResult
                    || generatedResultCopyAvailable),
                   bufferClipboardDisposition(client: client) != .passThrough {
                    if shortcut == .copyGeneratedResult {
                        if event.type == .keyDown {
                            bufferClipboardShortcutKeysDown.insert(event.keyCode)
                            noteGeneratedResultCopyHandled(client: client)
                        }
                    } else {
                        bufferClipboardShortcutKeysDown.remove(event.keyCode)
                        BufferModel.shared.clearAllContentSelection()
                        if streamInputModeSelected {
                            StreamInputWorkspace.shared.authorityRejected()
                        }
                    }
                    IMELog.write("buffer clipboard shortcut consumed after stale event")
                    return true
                }
                if BufferPluginKeyboardShortcutRules.direction(
                    hardwareKeyCode: event.keyCode,
                    modifierFlags: event.modifierFlags
                ) != nil,
                   bufferPluginShortcutDisposition(client: client) != .passThrough {
                    bufferPluginNavigationKeysDown.remove(event.keyCode)
                    IMELog.write("buffer plugin arrow consumed after stale event")
                    return true
                }
                if streamAlternativeDirection(
                    keycode: keysym(for: event),
                    mask: RimeKey.modifierMask(from: event.modifierFlags)
                ) != nil,
                   streamInputModeSelected,
                   StreamInputWorkspace.shared.ownsAlternativeNavigation {
                    streamAlternativeNavigationKeysDown.remove(event.keyCode)
                    StreamInputWorkspace.shared.authorityRejected()
                    IMELog.write("stream alternative arrow consumed after stale event")
                    return true
                }
                if streamAlternativeDirection(
                    keycode: keysym(for: event),
                    mask: RimeKey.modifierMask(from: event.modifierFlags)
                ) != nil,
                   let controls = DerivedBufferWorkspaceRouter
                    .selectedWorkspace as? any DerivedResultSelectionControls,
                   controls.ownsResultNavigation {
                    derivedResultNavigationKeysDown.remove(event.keyCode)
                    IMELog.write("derived result arrow consumed after stale event")
                    return true
                }
                switch streamInputDisposition(
                    keycode: keysym(for: event),
                    mask: RimeKey.modifierMask(from: event.modifierFlags),
                    exactExternalFocus: false,
                    chordRoute: streamInputChordRoute
                ) {
                case .passThrough:
                    break
                case .capture, .stageChordKey,
                     .consumeOwned, .consumeUntrusted:
                    StreamInputWorkspace.shared.authorityRejected()
                    IMELog.write("stream printable consumed after stale event")
                    return true
                }
            }
            let isPlainReturn = isBufferDeliveryShortcut(event)
            if isPlainReturn, bufferEnterGestureActive {
                lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
                // A stale field must never mutate callback ownership belonging
                // to the current press or cancel its action. Keep both armed and
                // swallow the unrelated callback; the poll revalidates its own
                // exact token independently.
                IMELog.write("buffer enter callback consumed without mutating ownership after stale event")
                return true
            }
            if isUnmodifiedBufferControlEvent(event),
               bufferControlDisposition(client: client) != .passThrough {
                if streamInputModeSelected {
                    StreamInputWorkspace.shared.authorityRejected()
                }
                if isPlainReturn, event.type == .keyDown {
                    suppressUntrustedBufferEnter(hardwareKeyCode: event.keyCode)
                }
                IMELog.write("buffer control consumed without action after stale event")
                return true
            }
            if event.type == .keyDown || event.type == .keyUp,
               BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
                   characters: event.characters,
                   modifierFlags: rejectedModifiers,
                   bufferEnabled: BufferModel.shared.enabled,
                   externalClient: !isOwnClient(client),
                   secureInputEnabled: IsSecureEventInputEnabled()
               ) {
                IMELog.write("buffer printable consumed after stale event")
                return true
            }
            return false
        }
        if event.type == .keyDown {
            switch ClipboardHistoryWindowController.shared.route(
                event,
                client: client
            ) {
            case .handledBySurface:
                return true
            case .routeToRime:
                return handleClipboardSearchKeyDown(event, client: client)
            case .passThrough:
                break
            }
        }
        if event.type == .keyDown,
           isBufferDeliveryShortcut(event),
           prepareBufferEnterKeyDown(event) {
            return true
        }
        switch event.type {
        case .flagsChanged: return handleFlags(event, client: client)
        case .keyDown:      return handleKeyDown(event, client: client)
        case .keyUp:        return handleKeyUp(event, client: client)
        default:            return false
        }
    }

    private func isUnmodifiedBufferControlEvent(_ event: NSEvent) -> Bool {
        if isBufferDeliveryShortcut(event) { return true }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let keycode = keysym(for: event) else { return false }
        return keycode == RimeKey.backspace
    }

    private func isBufferDeliveryShortcut(_ event: NSEvent) -> Bool {
        RimeShortcutPreferences.shortcut(for: .deliverBuffer).matches(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        )
    }

    /// Returns a concrete routing result only when the configured delivery
    /// shortcut is owned by the current buffer/focus state. A pass-through
    /// result stays `nil` so the host still receives an unavailable shortcut.
    private func routeBufferDeliveryShortcut(
        _ event: NSEvent,
        client: IMKTextInput
    ) -> Bool? {
        guard isBufferDeliveryShortcut(event) else { return nil }
        switch bufferControlDisposition(client: client) {
        case .passThrough:
            return nil
        case .consumeOnly:
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer delivery consumed without action; focus not trusted")
            suppressUntrustedBufferEnter(hardwareKeyCode: event.keyCode)
            return true
        case .executeBufferAction:
            return handleBufferEnter(
                RimeKey.return,
                client: client,
                hardwareKeyCode: event.keyCode
            )
        }
    }

    private var bufferEnterGestureActive: Bool {
        bufferEnterActionActive || bufferEnterCallbackOwnership.ownsCallbacks
    }

    private var bufferEnterActionActive: Bool {
        bufferEnterPending || bufferEnterSuppressUntilPhysicalUp
    }

    /// Called only after exact focus adoption. A fresh non-repeat Return retires
    /// suppression left by a host that omitted didCommand. Return actions are
    /// driven exclusively by this NSEvent path; didCommand is consume-only.
    private func prepareBufferEnterKeyDown(_ event: NSEvent) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        let decision = bufferEnterCallbackOwnership.prepareForKeyDown(
            isRepeat: event.isARepeat
        )
        if decision == .consumeOwned {
            lastBufferEnterKeyHandledAt = now
            IMELog.write("buffer enter repeat consumed for owned press")
            return true
        }
        if !event.isARepeat, bufferEnterActionActive {
            // A non-repeat keyDown proves the prior physical press ended even
            // if its keyUp callback was omitted. Finish its pending tap before
            // routing this new event so rapid consecutive presses do not lose
            // the first block.
            if bufferEnterPending {
                _ = performBufferEnterSend(
                    all: false,
                    client: bufferEnterClient,
                    expectedOwner: bufferEnterOwner,
                    source: "fresh keyDown finalized prior tap"
                )
            }
            resetBufferEnterGesture()
            IMELog.write("buffer enter prior action completed by fresh keyDown")
        }
        return false
    }

    private func handleKeyUp(_ event: NSEvent, client: IMKTextInput) -> Bool {
        guard let keycode = keysym(for: event) else { return false }
        if bufferPluginNavigationKeysDown.remove(event.keyCode) != nil {
            return true
        }
        if BufferPluginKeyboardShortcutRules.direction(
            hardwareKeyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) != nil,
           bufferPluginShortcutDisposition(client: client) != .passThrough {
            return true
        }
        if bufferClipboardShortcutKeysDown.remove(event.keyCode) != nil {
            return true
        }
        if let shortcut = BufferClipboardShortcutRules.shortcut(
            keycode: keycode,
            mask: RimeKey.modifierMask(from: event.modifierFlags)
        ), (shortcut != .copyGeneratedResult
            || generatedResultCopyAvailable),
           bufferClipboardDisposition(client: client) != .passThrough {
            return true
        }
        if streamAlternativeNavigationKeysDown.remove(event.keyCode) != nil {
            if streamInputLease(client: client) == nil {
                StreamInputWorkspace.shared.authorityRejected()
            }
            return true
        }
        if derivedResultNavigationKeysDown.remove(event.keyCode) != nil {
            return true
        }
        if streamAlternativeDirection(
            keycode: keycode,
            mask: RimeKey.modifierMask(from: event.modifierFlags)
        ) != nil,
           let controls = DerivedBufferWorkspaceRouter
            .selectedWorkspace as? any DerivedResultSelectionControls,
           controls.ownsResultNavigation,
           bufferControlDisposition(client: client) != .passThrough {
            return true
        }
        if streamAlternativeDirection(
            keycode: keycode,
            mask: RimeKey.modifierMask(from: event.modifierFlags)
        ) != nil,
           streamInputModeSelected,
           StreamInputWorkspace.shared.ownsAlternativeNavigation {
            if streamInputLease(client: client) == nil {
                StreamInputWorkspace.shared.authorityRejected()
            }
            return true
        }
        let releasesOwnedDeliveryKey = bufferEnterGestureActive
            && event.keyCode == UInt16(bufferEnterHardwareKeyCode)
        if !releasesOwnedDeliveryKey && !isBufferDeliveryShortcut(event) {
            let streamLease = streamInputLease(client: client)
            switch streamInputDisposition(
                keycode: keycode,
                mask: RimeKey.modifierMask(from: event.modifierFlags),
                exactExternalFocus: streamLease != nil,
                chordRoute: streamInputChordRoute
            ) {
            case .passThrough:
                return false
            case .capture, .stageChordKey, .consumeOwned:
                return true
            case .consumeUntrusted:
                StreamInputWorkspace.shared.authorityRejected()
                return true
            }
        }
        if streamInputModeSelected,
           bufferControlDisposition(client: client) != .passThrough,
           streamInputLease(client: client) == nil {
            StreamInputWorkspace.shared.authorityRejected()
        }
        if bufferEnterActionActive,
           bufferEnterCallbackOwnership.suppressesKeyUp,
           isBufferEnterPhysicallyDown() {
            // A keyUp from an older generation arrived while the currently
            // owned Return is still physically held. Swallow it without
            // completing or mutating the current press.
            IMELog.write("buffer enter stale keyUp consumed while current press remains down")
            return true
        }
        let callback = bufferEnterCallbackOwnership.consumeKeyUp()
        guard bufferEnterActionActive
                || callback == .consumeOwned
                || bufferControlDisposition(client: client) != .passThrough else {
            return false
        }

        lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
        if bufferEnterPending {
            let owner = bufferEnterOwner
            _ = performBufferEnterSend(all: false,
                                       client: bufferEnterClient ?? client,
                                       expectedOwner: owner,
                                       source: "keyUp tap")
            resetBufferEnterGesture()
            IMELog.write("buffer enter keyUp consumed; newline command remains suppressed=\(bufferEnterCallbackOwnership.suppressesNewlineCommand)")
            return true
        }
        if bufferEnterSuppressUntilPhysicalUp || callback == .consumeOwned {
            resetBufferEnterGesture()
            IMELog.write("buffer enter keyUp consumed without tap; newline command remains suppressed=\(bufferEnterCallbackOwnership.suppressesNewlineCommand)")
            return true
        }
        return true
    }

    /// Dedicated logical-search route for the standalone Clipboard window.
    /// It intentionally bypasses every Buffer plug-in, stream-input, delivery,
    /// and workbench-navigation branch while reusing the current Rime session,
    /// candidate selection, and exact focus lease.
    private func handleClipboardSearchKeyDown(
        _ event: NSEvent,
        client: IMKTextInput
    ) -> Bool {
        guard let eventLease = currentLease(matching: client),
              ClipboardHistoryWindowController.shared.capturesSearchInput(
                expected: eventLease.token,
                client: client
              ) else {
            IMELog.write("clipboard search key consumed after authority changed")
            return true
        }

        if event.modifierFlags.contains(.shift) {
            shiftGesture?.noteModifierUse()
        }
        publishTelemetryKey(event, client: client)

        if let shiftedText = shiftedDirectText(for: event) {
            _ = rimeEngine.start()
            _ = ensureSessionReady()
            return insertDirectText(
                shiftedText,
                client: client,
                source: "clipboard search shift",
                expectedLease: eventLease
            )
        }

        guard rimeEngine.start(), ensureSessionReady() else {
            // Only literal text has a meaningful engine-down fallback in the
            // logical search field. Cocoa function-key characters must remain
            // navigation commands rather than invisible query content.
            if ClipboardHistoryWindowController.isPlainSearchInputEvent(event) {
                _ = rawFallback(
                    event,
                    client: client,
                    expectedLease: eventLease
                )
            }
            return true
        }
        guard let keycode = keysym(for: event) else {
            if let text = event.characters,
               ClipboardHistoryWindowController.isPlainSearchInputEvent(event),
               ClipboardHistoryWindowController.isLiteralSearchText(text) {
                _ = insertDirectText(
                    text,
                    client: client,
                    source: "clipboard search unmapped",
                    expectedLease: eventLease
                )
            }
            return true
        }
        let mask = RimeKey.modifierMask(from: event.modifierFlags)
        let commandMask = RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask

        if keycode == RimeKey.return,
           mask & commandMask == 0,
           commitRawInput(client: client) {
            return true
        }
        if mask == 0, handleCandidateKey(keycode, client: client) {
            return true
        }

        let handled = processRimeKey(keycode, mask: mask, client: client)
        if handled { return true }
        if captureUnhandledPrintableIfNeeded(
            event,
            client: client,
            expectedLease: eventLease
        ) {
            return true
        }
        if let text = event.characters,
           ClipboardHistoryWindowController.isPlainSearchInputEvent(event),
           ClipboardHistoryWindowController.isLiteralSearchText(text) {
            _ = insertDirectText(
                text,
                client: client,
                source: "clipboard search printable fallback",
                expectedLease: eventLease
            )
        }
        // A key routed to the logical search field never falls through to the
        // still-focused host, even if the engine rejects it during a race.
        return true
    }

    private func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
        // Freeze the lease adopted for this physical event before any Rime/UI
        // callback can synchronously reenter and move the same IMK proxy to a
        // different field.
        let eventLease = currentLease(matching: client)
        // Mark before every early return (Cmd shortcuts, stream capture,
        // buffer controls and direct shifted text). Those paths deliberately
        // do not feed this keyDown to librime, but it still means Shift was a
        // modifier rather than a standalone mode-toggle tap.
        if event.modifierFlags.contains(.shift) {
            shiftGesture?.noteModifierUse()
        }
        publishTelemetryKey(event, client: client)

        let routedKeycode = keysym(for: event)
        let routedMask = RimeKey.modifierMask(from: event.modifierFlags)
        if let routedKeycode,
           handleWorkbenchEscape(
                routedKeycode,
                mask: routedMask,
                client: client,
                expectedLease: eventLease
           ) {
            return true
        }
        if let shortcut = BufferClipboardShortcutRules.shortcut(
            keycode: routedKeycode,
            mask: routedMask
        ) {
            if event.isARepeat,
               bufferClipboardShortcutKeysDown.contains(event.keyCode) {
                IMELog.write("buffer clipboard shortcut repeat consumed")
                return true
            }
            if !event.isARepeat {
                // A definite new press retires key-up ownership from a host
                // that omitted the preceding release callback.
                bufferClipboardShortcutKeysDown.remove(event.keyCode)
            }
            if shortcut == .copyGeneratedResult,
               !generatedResultCopyAvailable {
                // A normal source rail has no generated target to copy. Leave
                // the exact Command+C entirely to the host without settling or
                // otherwise mutating Buffer composition.
                return false
            }
            switch bufferClipboardDisposition(client: client) {
            case .passThrough:
                if shortcut == .copyGeneratedResult
                    || IsSecureEventInputEnabled()
                    || isOwnClient(client) {
                    return false
                }
                break
            case .consumeOnly:
                bufferClipboardShortcutKeysDown.insert(event.keyCode)
                if shortcut == .copyGeneratedResult {
                    noteGeneratedResultCopyHandled(client: client)
                } else {
                    BufferModel.shared.clearAllContentSelection()
                    if streamInputModeSelected {
                        StreamInputWorkspace.shared.authorityRejected()
                    }
                }
                IMELog.write("buffer clipboard shortcut consumed without authority")
                return true
            case .executeBufferAction:
                bufferClipboardShortcutKeysDown.insert(event.keyCode)
                if shortcut == .copyGeneratedResult {
                    // Arm duplicate-command suppression before the copy.
                    // A successful action closes Buffer synchronously, so
                    // recording ownership afterward would be too late for
                    // a re-entrant `copy:` callback from the host.
                    noteGeneratedResultCopyHandled(client: client)
                }
                _ = performBufferClipboardShortcut(
                    shortcut,
                    client: client,
                    expectedLease: eventLease
                )
                if shortcut != .copyGeneratedResult {
                    lastBufferClipboardShortcutHandledAt =
                        CFAbsoluteTimeGetCurrent()
                    lastBufferClipboardShortcutHandled = shortcut
                    lastBufferClipboardShortcutClientIdentity = nil
                }
                return true
            }
        }

        if let direction = BufferPluginKeyboardShortcutRules.direction(
            hardwareKeyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) {
            switch bufferPluginShortcutDisposition(client: client) {
            case .passThrough:
                break
            case .consumeOnly:
                IMELog.write("buffer plugin arrow consumed without authority")
                return true
            case .executeBufferAction:
                bufferPluginNavigationKeysDown.insert(event.keyCode)
                if event.isARepeat {
                    IMELog.write("buffer plugin arrow repeat consumed")
                    return true
                }
                lastBufferPluginArrowKeyHandledAt = CFAbsoluteTimeGetCurrent()
                lastBufferPluginArrowDirection = direction
                _ = performBufferPluginSwitch(direction: direction,
                                              client: client,
                                              source: "key")
                return true
            }
        }

        // A user-configured modified delivery shortcut is the deliberate
        // exception to modifier/stream pass-through. Route it before those
        // generic gates so Settings never persists a combination that the
        // controller ignores. Bare Return/F6–F12 retain their existing order.
        if RimeShortcutPreferences.shortcut(for: .deliverBuffer)
            .hasCommandLikeModifier,
           let handled = routeBufferDeliveryShortcut(event, client: client) {
            return handled
        }

        // A modified navigation key must not move/select text in the still-
        // focused host while the logical Buffer surface owns input. Candidate
        // navigation and configured Buffer shortcuts had first refusal above.
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false,
           let routedKeycode,
           handleBufferLogicalNavigation(routedKeycode, client: client) {
            return true
        }

        // Cmd otherwise belongs to the app (macOS Rime configs never bind
        // Super). In my_combo every letter is a chording key, so without this
        // early-out chord_composer would eat Cmd+C/Cmd+V outright. Resolve any
        // live composition first so the shortcut acts on committed text.
        if event.modifierFlags.contains(.command) {
            if composition.composing || chord.hasPending { forceCommit() }
            if streamInputModeSelected {
                if let lease = streamInputLease(client: client) {
                    _ = StreamInputWorkspace.shared.settlePendingChord(
                        focusToken: lease.token,
                        closesPairingAfterSettlement: true
                    )
                } else {
                    StreamInputWorkspace.shared.authorityRejected()
                }
            }
            return false
        }

        let streamLease = streamInputLease(client: client)
        if let direction = streamAlternativeDirection(
            keycode: routedKeycode,
            mask: routedMask
        ), StreamInputWorkspace.shared.ownsAlternativeNavigation {
            guard let streamLease,
                  StreamInputWorkspace.shared.moveAlternativeSelection(
                    delta: direction,
                    focusToken: streamLease.token
                  ),
                  self.streamInputLease(client: client) === streamLease else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream alternative arrow consumed after authority changed")
                return true
            }
            streamAlternativeNavigationKeysDown.insert(event.keyCode)
            lastStreamAlternativeArrowKeyHandledAt = CFAbsoluteTimeGetCurrent()
            lastStreamAlternativeArrowDirection = direction
            updateUI(client: client)
            return true
        }
        // A keysym only covers printable ASCII, so any other script arrives
        // with no keycode at all and would otherwise fall through to the host
        // — the one case where stream input silently loses what was typed.
        // Hand the characters straight to the raw line instead.
        if routedKeycode == nil,
           let streamLease,
           routedMask & (RimeKey.controlMask | RimeKey.altMask
               | RimeKey.superMask) == 0,
           let typed = event.characters,
           !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0)
           }),
           prepareForStreamInputCapture(client: client, lease: streamLease),
           StreamInputWorkspace.shared.insertTypedText(
             typed,
             focusToken: streamLease.token
           ),
           streamInputLease(client: client) === streamLease {
            updateUI(client: client)
            return true
        }
        let streamChordRoute = streamInputChordRoute
        switch streamInputDisposition(
            keycode: routedKeycode,
            mask: routedMask,
            exactExternalFocus: streamLease != nil,
            hasLiveComposition: composition.composing || chord.hasPending,
            chordRoute: streamChordRoute
        ) {
        case .passThrough:
            if let streamLease {
                _ = StreamInputWorkspace.shared.settlePendingChord(
                    focusToken: streamLease.token,
                    closesPairingAfterSettlement: true
                )
            }
            break
        case .consumeUntrusted:
            StreamInputWorkspace.shared.authorityRejected()
            IMELog.write("stream printable consumed without exact authority")
            return true
        case let .capture(letter):
            guard let streamLease,
                  prepareForStreamInputCapture(
                    client: client,
                    lease: streamLease
                  ),
                  StreamInputWorkspace.shared.capture(
                    letter: letter,
                    focusToken: streamLease.token
                  ),
                  self.streamInputLease(client: client) === streamLease else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream letter consumed after authority changed")
                return true
            }
            updateUI(client: client)
            return true
        case let .stageChordKey(keycode):
            guard let streamLease,
                  let streamChordRoute,
                  prepareForStreamInputCapture(
                    client: client,
                    lease: streamLease
                  ),
                  StreamInputWorkspace.shared.captureChordKey(
                    keycode,
                    schemaID: streamChordRoute.schemaID,
                    policy: streamChordRoute.policy,
                    focusToken: streamLease.token
                  ),
                  self.streamInputLease(client: client) === streamLease else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream chord key consumed after authority changed")
                return true
            }
            updateUI(client: client)
            return true
        case .consumeOwned:
            guard let streamLease,
                  prepareForStreamInputCapture(
                    client: client,
                    lease: streamLease
                  ),
                  StreamInputWorkspace.shared.consumeIgnoredKey(
                    keycode: routedKeycode,
                    focusToken: streamLease.token
                  ),
                  self.streamInputLease(client: client) === streamLease else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream separator consumed after authority changed")
                return true
            }
            updateUI(client: client)
            return true
        }
        let controlMask = RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask
        let isUnmodifiedBackspace = routedMask & controlMask == 0
            && routedKeycode == RimeKey.backspace
        if let handled = routeBufferDeliveryShortcut(event, client: client) {
            return handled
        }
        if isUnmodifiedBackspace {
            switch bufferControlDisposition(client: client) {
            case .passThrough:
                break
            case .consumeOnly:
                if streamInputModeSelected {
                    StreamInputWorkspace.shared.authorityRejected()
                }
                IMELog.write("buffer backspace consumed without action; focus not trusted")
                return true
            case .executeBufferAction:
                // This must run before the engine-health fallback. If the
                // engine is unavailable, performBufferBackspace removes a
                // staged block or consumes an empty no-op; it never lets the
                // host field delete text.
                return handleBufferBackspace(RimeKey.backspace,
                                             mask: routedMask,
                                             client: client)
            }
        }
        // Keep Shift+Return/Backspace inside the buffer-control contract even
        // if a host reports a printable Unicode line/paragraph separator.
        if let shiftedText = shiftedDirectText(for: event) {
            if rimeEngine.start(), ensureSessionReady() {
                return insertDirectText(shiftedText,
                                        client: client,
                                        source: "shift",
                                        expectedLease: eventLease)
            }
            return insertDirectText(shiftedText,
                                    client: client,
                                    source: "shift fallback",
                                    expectedLease: eventLease)
        }
        // Result navigation is owned by the visible derived workspace, not by
        // librime. Keep it available during an engine outage; the helper still
        // requires exact focus, a settled composition, and no Rime candidates.
        if handleDerivedResultVerticalArrow(
            routedKeycode ?? 0,
            mask: routedMask,
            event: event,
            client: client
        ) {
            return true
        }
        // Engine down → raw fallback so the user can still type latin.
        guard rimeEngine.start(), ensureSessionReady() else {
            if let routedKeycode,
               handleBufferLogicalNavigation(routedKeycode, client: client) {
                return true
            }
            if consumeLeakedCodexBufferControlText(event, client: client, path: "engine down") {
                return true
            }
            return rawFallback(event, client: client, expectedLease: eventLease)
        }
        guard let keycode = routedKeycode else {
            chord.flush()   // the app will insert this key NOW; a pending chord must land first
            mutualPairingState.reset()
            if consumeLeakedCodexBufferControlText(event, client: client, path: "unmapped key") {
                return true
            }
            return false
        }
        let mask = routedMask
        if keycode == RimeKey.return,
           mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0,
           commitRawInput(client: client) {
            return true
        }
        if candidateOptionSelecting {
            if !candidateWindow.hasInteractableCandidates {
                resetCandidateOptionGesture()
                IMELog.write("candidate option gesture cancelled; panel not interactable")
            } else {
                if mask == 0 {
                    _ = handleCandidateKey(keycode, client: client)
                } else {
                    _ = handleCandidateOptionSelectionKey(keycode, client: client)
                }
                return true
            }
        }
        if mask == 0 {
            if handleCandidateKey(keycode, client: client) {
                return true
            }
            if keycode == RimeKey.return, commitRawInput(client: client) {
                return true
            }
        }
        if handleBufferHorizontalArrow(keycode, mask: mask, client: client, source: "key") {
            return true
        }
        if handleBufferLogicalNavigation(keycode, client: client) {
            return true
        }
        let handled = processRimeKey(keycode, mask: mask, client: client)
        if !handled,
           consumeLeakedCodexBufferControlText(event, client: client, path: "Rime unhandled") {
            return true
        }
        if !handled,
           captureUnhandledPrintableIfNeeded(event,
                                             client: client,
                                             expectedLease: eventLease) {
            return true
        }
        if !handled,
           BufferLogicalNavigationRules.owns(keycode: keycode),
           shouldUseBufferCommands(client: client) {
            IMELog.write("buffer logical navigation consumed after Rime rejected key=\(keycode)")
            return true
        }
        return handled
    }

    /// In librime ASCII mode ordinary Latin keys are intentionally delegated
    /// to the frontend. While persistent buffer capture owns the exact external
    /// field, that frontend is the workbench rather than the host editor.
    private func captureUnhandledPrintableIfNeeded(_ event: NSEvent,
                                                    client: IMKTextInput,
                                                    expectedLease: FocusLease?) -> Bool {
        let exactExternalFocus = expectedLease.map { lease in
            lease.controller === self
                && lease.clientIdentity == ObjectIdentifier(client as AnyObject)
                && lease.isExternalTarget
                && InputFocusCoordinator.shared.interactionTarget(
                    expected: lease.token
                ) === lease
        } ?? false
        let captureAuthorized = expectedLease.map { lease in
            BufferModel.shared.capturesInput(for: lease.token)
                || ClipboardHistoryWindowController.shared.capturesSearchInput(
                    expected: lease.token,
                    client: client
                )
        } ?? false
        if BufferModel.shared.active,
           expectedLease?.isExternalTarget == true,
           !exactExternalFocus {
            IMELog.write("Rime ASCII fallback consumed; adopted focus lease changed")
            return true
        }
        guard let text = BufferUnhandledPrintableRules.capturedText(
            characters: event.characters,
            modifierFlags: event.modifierFlags
                .intersection(.deviceIndependentFlagsMask),
            bufferEnabled: captureAuthorized,
            exactExternalFocus: exactExternalFocus,
            secureInputEnabled: IsSecureEventInputEnabled()
        ) else { return false }
        return insertDirectText(text,
                                client: client,
                                source: "Rime ASCII fallback",
                                expectedLease: expectedLease)
    }

    private func handleWorkbenchEscape(
        _ keycode: Int32,
        mask: Int32,
        client: IMKTextInput,
        expectedLease: FocusLease?
    ) -> Bool {
        let exactExternalFocus = expectedLease.map { lease in
            lease.controller === self
                && lease.clientIdentity == ObjectIdentifier(client as AnyObject)
                && lease.isExternalTarget
                && InputFocusCoordinator.shared.interactionTarget(
                    expected: lease.token
                ) === lease
        } ?? false
        let disposition = BufferWorkbenchEscapeRoutingRules.disposition(
            isUnmodifiedEscape: isUnmodifiedEscape(keycode: keycode, mask: mask),
            workbenchVisible: BufferWindowController.shared.isVisible,
            ownClient: isOwnClient(client),
            exactExternalFocus: exactExternalFocus
        )
        switch disposition {
        case .passThrough:
            return false
        case .consumeOnly:
            noteWorkbenchEscapeHandled(client: client)
            IMELog.write("buffer workbench escape consumed without exact focus")
            return true
        case .closeWorkbench:
            noteWorkbenchEscapeHandled(client: client)
            _ = BufferWindowController.shared.dismissFromEscape()
            return true
        }
    }

    private func isUnmodifiedEscape(keycode: Int32?, mask: Int32) -> Bool {
        let modifiers = RimeKey.controlMask
            | RimeKey.altMask
            | RimeKey.superMask
            | RimeKey.shiftMask
        return keycode == RimeKey.escape && mask & modifiers == 0
    }

    private func noteWorkbenchEscapeHandled(client: IMKTextInput?) {
        lastWorkbenchEscapeHandledAt = CFAbsoluteTimeGetCurrent()
        lastWorkbenchEscapeClientIdentity = client.map {
            ObjectIdentifier($0 as AnyObject)
        }
    }

    private func recentlyHandledWorkbenchEscape(client: IMKTextInput?) -> Bool {
        guard CFAbsoluteTimeGetCurrent() - lastWorkbenchEscapeHandledAt
                < Self.duplicateWorkbenchEscapeCommandWindow else { return false }
        guard let client else {
            // A few hosts omit the sender only for the command translated from
            // this same physical Escape. Keep the suppression window narrow.
            return lastWorkbenchEscapeClientIdentity != nil
        }
        return lastWorkbenchEscapeClientIdentity
            == ObjectIdentifier(client as AnyObject)
    }

    private func handleBufferEnter(_ keycode: Int32,
                                   client: IMKTextInput,
                                   hardwareKeyCode: UInt16) -> Bool {
        guard keycode == RimeKey.return else {
            return false
        }

        let now = CFAbsoluteTimeGetCurrent()
        if bufferEnterPending || bufferEnterSuppressUntilPhysicalUp {
            lastBufferEnterKeyHandledAt = now
            return true
        }

        guard shouldUseBufferCommands(client: client) else {
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer enter key consumed without action after focus changed")
            suppressUntrustedBufferEnter(hardwareKeyCode: hardwareKeyCode)
            return true
        }
        lastBufferEnterKeyHandledAt = now
        if BufferEnterSecureInputRules.disposition(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) == .consumeWithoutGuardOrGeneration {
            // Fail closed at the outer Return boundary, before composition
            // settlement, stream capture, AI generation or delivery timing.
            suppressBufferEnterForImmediateAction(client: client,
                                                  hardwareKeyCode: hardwareKeyCode)
            DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            IMELog.write("buffer enter consumed at secure-input boundary")
            updateUI(client: client)
            BufferWindowController.shared.refresh()
            return true
        }
        if streamInputModeSelected {
            guard let lease = streamInputLease(client: client) else {
                StreamInputWorkspace.shared.authorityRejected()
                suppressUntrustedBufferEnter(hardwareKeyCode: hardwareKeyCode)
                IMELog.write("stream return consumed without exact authority")
                return true
            }
            let settled = StreamInputWorkspace.shared.settleForReturn(
                focusToken: lease.token
            )
            guard streamInputLease(client: client) === lease else {
                StreamInputWorkspace.shared.authorityRejected()
                suppressUntrustedBufferEnter(hardwareKeyCode: hardwareKeyCode)
                IMELog.write("stream return consumed after authority changed")
                return true
            }
            if settled {
                suppressBufferEnterAfterComposition(
                    client: client,
                    hardwareKeyCode: hardwareKeyCode
                )
                updateUI(client: client)
                return true
            }
            beginBufferEnterGesture(client: client,
                                    hardwareKeyCode: hardwareKeyCode)
            return true
        }
        if settlePendingBufferCompositionIfNeeded(client: client,
                                                  source: "keyDown") {
            suppressBufferEnterAfterComposition(client: client,
                                                hardwareKeyCode: hardwareKeyCode)
            return true
        }
        if handleWorkbenchManualGenerationBufferEnterIfNeeded(
            client: client,
            hardwareKeyCode: hardwareKeyCode
        ) {
            return true
        }
        beginBufferEnterGesture(client: client,
                                hardwareKeyCode: hardwareKeyCode)
        return true
    }

    /// Manual-generation owners use the same physical Return as their
    /// right-side primary control. Only a ready target enters tap/hold
    /// delivery; every other state owns the whole press immediately so a
    /// synchronous result can never be delivered again by that press's keyUp.
    private func handleWorkbenchManualGenerationBufferEnterIfNeeded(
        client: IMKTextInput,
        hardwareKeyCode: UInt16
    ) -> Bool {
        guard let controls = WorkbenchManualGenerationRouter.selectedControls else {
            return false
        }

        if BufferEnterSecureInputRules.disposition(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) == .consumeWithoutGuardOrGeneration {
            suppressBufferEnterForImmediateAction(client: client,
                                                  hardwareKeyCode: hardwareKeyCode)
            DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            IMELog.write("buffer enter consumed; secure input blocked generation")
            updateUI(client: client)
            BufferWindowController.shared.refresh()
            return true
        }

        let action = controls.primaryAction
        guard !action.beginsDeliveryGesture else { return false }
        suppressBufferEnterForImmediateAction(client: client,
                                              hardwareKeyCode: hardwareKeyCode)
        // setMarkedText can synchronously re-enter a host. Recheck immediately
        // before calling a provider so a secure-input transition during guard
        // installation still fails closed.
        if BufferEnterSecureInputRules.disposition(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) == .consumeWithoutGuardOrGeneration {
            DerivedBufferWorkspaceRouter.setProtectedOnAll(true)
            BuiltInBufferActionWorkspaceRouter.setProtectedOnAll(true)
            ActionPluginHost.shared.cancelActiveInvocationForWorkbench()
            IMELog.write("buffer enter consumed; secure input changed before generation request")
            updateUI(client: client)
            BufferWindowController.shared.refresh()
            return true
        }
        switch action {
        case .requestGeneration:
            let result = AITextGenerationCommandRouter.request(
                controls: controls
            )
            switch result {
            case .inlineStarted:
                IMELog.write("buffer enter requested inline AI generation")
            case .rejected:
                NSSound.beep()
                IMELog.write("buffer enter AI generation rejected")
            }
        case .generating:
            IMELog.write("buffer enter consumed while generation is running")
        case .disabled:
            IMELog.write("buffer enter consumed while generation is unavailable")
        case .deliver:
            break
        }
        updateUI(client: client)
        BufferWindowController.shared.refresh()
        return true
    }

    private func handleBufferBackspace(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        guard keycode == RimeKey.backspace,
              mask & (RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0 else {
            return false
        }
        guard shouldUseBufferCommands(client: client) else {
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer backspace key consumed without action after focus changed")
            return true
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferBackspaceCommandHandledAt < Self.duplicateBackspaceCommandWindow {
            IMELog.write("buffer backspace key consumed after command")
            lastBufferBackspaceKeyHandledAt = now
            return true
        }

        lastBufferBackspaceKeyHandledAt = now
        return performBufferBackspace(client: client, source: "key")
    }

    private func handleBufferHorizontalArrow(_ keycode: Int32,
                                             mask: Int32,
                                             client: IMKTextInput,
                                             source: String) -> Bool {
        let direction: Int
        switch keycode {
        case RimeKey.left: direction = -1
        case RimeKey.right: direction = 1
        default: return false
        }
        guard shouldUseBufferCommands(client: client),
              mask & (RimeKey.shiftMask | RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask) == 0 else {
            return false
        }
        // Translation deliberately presents its source as one continuous text
        // rail.  BufferModel still stores commit-sized blocks internally, so
        // moving its block insertion index would create an invisible caret and
        // make the next insert/backspace disagree with what the rail displays.
        // Consume plain arrows until this workspace has a real character caret.
        if usesContinuousDerivedSourceRail {
            IMELog.write("derived source arrow consumed direction=\(direction)")
            return true
        }
        guard canMoveBufferInsertionPoint() else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferArrowCommandHandledAt < Self.duplicateArrowCommandWindow,
           lastBufferArrowCommandDirection == direction {
            IMELog.write("buffer arrow \(source) consumed after command direction=\(direction)")
            lastBufferArrowKeyHandledAt = now
            lastBufferArrowKeyDirection = direction
            return true
        }

        lastBufferArrowKeyHandledAt = now
        lastBufferArrowKeyDirection = direction
        _ = BufferModel.shared.moveInsertionPoint(delta: direction)
        updateUI(client: client)
        return true
    }

    private func handleBufferLogicalNavigation(_ keycode: Int32,
                                               client: IMKTextInput) -> Bool {
        guard shouldUseBufferCommands(client: client),
              let action = BufferLogicalNavigationRules.action(
                keycode: keycode,
                compositionSettled: canMoveBufferInsertionPoint()
              ) else { return false }

        switch action {
        case .moveToStart:
            if !usesContinuousDerivedSourceRail {
                _ = BufferModel.shared.setInsertionPoint(0)
            }
        case .moveToEnd:
            if !usesContinuousDerivedSourceRail {
                _ = BufferModel.shared.setInsertionPoint(
                    BufferModel.shared.blocks.count
                )
            }
        case .deleteForward:
            if !usesContinuousDerivedSourceRail {
                _ = BufferModel.shared.deleteForwardAtInsertionPoint()
            }
        case .consume:
            break
        }
        updateUI(client: client)
        IMELog.write("buffer logical navigation consumed key=\(keycode) action=\(action)")
        return true
    }

    private func handleDerivedResultVerticalArrow(
        _ keycode: Int32,
        mask: Int32,
        event: NSEvent,
        client: IMKTextInput
    ) -> Bool {
        guard let direction = streamAlternativeDirection(
                keycode: keycode,
                mask: mask
              ),
              let controls = DerivedBufferWorkspaceRouter
                .selectedWorkspace as? any DerivedResultSelectionControls,
              controls.ownsResultNavigation,
              !candidateWindow.hasCandidates,
              bufferCompositionIsSettledForSourceEditing() else {
            return false
        }
        // Candidate navigation has already had first refusal. Once the query
        // composition is settled, plain vertical arrows belong to the visible
        // My Prompt result list and must not move the host application's caret.
        guard shouldUseBufferCommands(client: client) else {
            IMELog.write("derived result arrow consumed without exact focus")
            return true
        }
        guard controls.moveResultSelection(delta: direction),
              shouldUseBufferCommands(client: client) else {
            IMELog.write("derived result arrow consumed after authority changed")
            return true
        }
        derivedResultNavigationKeysDown.insert(event.keyCode)
        lastDerivedResultArrowKeyHandledAt = CFAbsoluteTimeGetCurrent()
        lastDerivedResultArrowDirection = direction
        updateUI(client: client)
        return true
    }

    override func didCommand(by selector: Selector!, client sender: Any!) -> Bool {
        guard let selector else { return false }
        guard callbackHasCurrentInputSourceAuthority(
            operation: "didCommand"
        ) else { return false }
        if ClipboardHistoryWindowController.shared.consumeCommandIfRecentlyHandled(
            selector,
            client: sender as? IMKTextInput
        ) {
            return true
        }
        let newlineCommand = isInsertNewlineSelector(selector)
        let callbackClient = currentCallbackClient(sender)
        let explicitClientMismatch = sender is IMKTextInput && callbackClient == nil
        if newlineCommand,
           ClipboardHistoryWindowController.shared
            .consumeActivationCommandIfVisible(
                client: callbackClient,
                controller: self
            ) {
            return true
        }
        if isCancelOperationSelector(selector) {
            let escapeClient = currentEscapeCommandClient(sender)
            if recentlyHandledWorkbenchEscape(
                client: (sender as? IMKTextInput) ?? escapeClient
            ) {
                IMELog.write("buffer workbench duplicate escape command consumed")
                return true
            }
            let senderClient = sender as? IMKTextInput
            let ownClient = senderClient.map(isOwnClient)
                ?? escapeClient.map(isOwnClient)
                ?? false
            let disposition = BufferWorkbenchEscapeRoutingRules.disposition(
                isUnmodifiedEscape: true,
                workbenchVisible: BufferWindowController.shared.isVisible,
                ownClient: ownClient,
                exactExternalFocus: escapeClient != nil && !ownClient
            )
            switch disposition {
            case .passThrough:
                return false
            case .consumeOnly:
                noteWorkbenchEscapeHandled(client: escapeClient)
                IMELog.write("buffer workbench escape command consumed without exact focus")
                return true
            case .closeWorkbench:
                noteWorkbenchEscapeHandled(client: escapeClient)
                _ = BufferWindowController.shared.dismissFromEscape()
                return true
            }
        }
        if recentlyHandledGeneratedResultCopyCommand(selector, sender: sender) {
            IMELog.write("buffer generated-result copy command consumed after owned keyDown")
            return true
        }
        let physicalClipboardShortcut = physicalBufferClipboardShortcut()
        if let shortcut = bufferClipboardShortcut(
            for: selector,
            physicalShortcut: physicalClipboardShortcut
        ) {
            if shortcut == .copyGeneratedResult,
               !generatedResultCopyAvailable {
                return false
            }
            let clipboardClient = callbackClient
                ?? currentClipboardCommandClient(
                    sender,
                    shortcut: shortcut,
                    physicalShortcut: physicalClipboardShortcut
                )
            let hasOwnedKeyDown = shortcut == .copyGeneratedResult
                ? bufferClipboardShortcutKeysDown.contains(
                    UInt16(kVK_ANSI_C)
                  )
                : !bufferClipboardShortcutKeysDown.isEmpty
            if hasOwnedKeyDown {
                IMELog.write("buffer clipboard command consumed after owned keyDown")
                return true
            }
            switch bufferClipboardDisposition(client: clipboardClient) {
            case .passThrough:
                return false
            case .consumeOnly:
                if shortcut == .copyGeneratedResult {
                    bufferClipboardShortcutKeysDown.insert(
                        UInt16(kVK_ANSI_C)
                    )
                    noteGeneratedResultCopyHandled(client: clipboardClient)
                } else {
                    BufferModel.shared.clearAllContentSelection()
                    if streamInputModeSelected {
                        StreamInputWorkspace.shared.authorityRejected()
                    }
                }
                IMELog.write("buffer clipboard command consumed without authority")
                return true
            case .executeBufferAction:
                // A command-only Command+C fallback has no owned keyDown yet.
                // `recentlyHandledGeneratedResultCopyCommand` already removes
                // the true late callback above, so a live physical chord here
                // is a fresh press even when the user copies twice rapidly.
                let duplicate = shortcut == .copyGeneratedResult
                    ? false
                    : lastBufferClipboardShortcutHandled == shortcut
                        && CFAbsoluteTimeGetCurrent()
                            - lastBufferClipboardShortcutHandledAt
                                < Self.duplicateClipboardCommandWindow
                if !duplicate, let client = clipboardClient {
                    if shortcut == .copyGeneratedResult {
                        bufferClipboardShortcutKeysDown.insert(
                            UInt16(kVK_ANSI_C)
                        )
                        noteGeneratedResultCopyHandled(client: client)
                    }
                    _ = performBufferClipboardShortcut(
                        shortcut,
                        client: client,
                        expectedLease: currentLease(matching: client)
                    )
                    if shortcut != .copyGeneratedResult {
                        lastBufferClipboardShortcutHandledAt =
                            CFAbsoluteTimeGetCurrent()
                        lastBufferClipboardShortcutHandled = shortcut
                        lastBufferClipboardShortcutClientIdentity = nil
                    }
                }
                return true
            }
        }
        let physicalPluginDirection = physicalBufferPluginSwitchDirection()
        if let direction = BufferPluginKeyboardShortcutRules.commandDirection(
            selectorName: NSStringFromSelector(selector),
            physicalDirection: physicalPluginDirection
        ) {
            switch bufferPluginShortcutDisposition(client: callbackClient) {
            case .passThrough:
                return false
            case .consumeOnly:
                IMELog.write("buffer plugin arrow command consumed without authority")
                return true
            case .executeBufferAction:
                let duplicateKeyEvent = !bufferPluginNavigationKeysDown.isEmpty
                    || (CFAbsoluteTimeGetCurrent()
                        - lastBufferPluginArrowKeyHandledAt
                            < Self.duplicateArrowCommandWindow
                        && lastBufferPluginArrowDirection == direction)
                if !duplicateKeyEvent, let client = callbackClient {
                    lastBufferPluginArrowKeyHandledAt = CFAbsoluteTimeGetCurrent()
                    lastBufferPluginArrowDirection = direction
                    _ = performBufferPluginSwitch(direction: direction,
                                                  client: client,
                                                  source: "command")
                }
                return true
            }
        }
        if newlineCommand {
            if explicitClientMismatch, bufferEnterGestureActive {
                // Do not let an old field's command mutate ownership belonging
                // to the current press. It is stale, but still must be hidden.
                IMELog.write("buffer enter stale newline command consumed without ownership mutation selector=\(NSStringFromSelector(selector))")
                return true
            }
            let ownershipDecision = bufferEnterCallbackOwnership
                .routeNewlineCommand()
            if ownershipDecision == .consumeOwned {
                IMELog.write("buffer enter owned newline command consumed selector=\(NSStringFromSelector(selector)) keyUpSuppressed=\(bufferEnterCallbackOwnership.suppressesKeyUp) suppressionRetained=true")
                return true
            }
        }

        if let direction = verticalMoveDirection(for: selector),
           streamInputModeSelected,
           StreamInputWorkspace.shared.ownsAlternativeNavigation {
            guard !explicitClientMismatch,
                  let client = callbackClient,
                  let lease = streamInputLease(client: client) else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream alternative arrow command consumed without authority")
                return true
            }
            // A handled NSEvent may still be followed by AppKit's command
            // callback. The physical-key set makes that callback consume-only.
            let duplicateKeyEvent = !streamAlternativeNavigationKeysDown.isEmpty
                || (CFAbsoluteTimeGetCurrent()
                    - lastStreamAlternativeArrowKeyHandledAt
                        < Self.duplicateArrowCommandWindow
                    && lastStreamAlternativeArrowDirection == direction)
            if !duplicateKeyEvent {
                guard StreamInputWorkspace.shared.moveAlternativeSelection(
                    delta: direction,
                    focusToken: lease.token
                ), streamInputLease(client: client) === lease else {
                    StreamInputWorkspace.shared.authorityRejected()
                    return true
                }
                updateUI(client: client)
            }
            return true
        }
        if let direction = verticalMoveDirection(for: selector),
           let controls = DerivedBufferWorkspaceRouter
            .selectedWorkspace as? any DerivedResultSelectionControls,
           controls.ownsResultNavigation,
           !candidateWindow.hasCandidates,
           bufferCompositionIsSettledForSourceEditing() {
            guard !explicitClientMismatch,
                  shouldUseBufferCommands(client: callbackClient) else {
                IMELog.write("derived result arrow command consumed without authority")
                return true
            }
            let duplicateKeyEvent = !derivedResultNavigationKeysDown.isEmpty
                || (CFAbsoluteTimeGetCurrent()
                    - lastDerivedResultArrowKeyHandledAt
                        < Self.duplicateArrowCommandWindow
                    && lastDerivedResultArrowDirection == direction)
            if !duplicateKeyEvent {
                guard controls.moveResultSelection(delta: direction),
                      shouldUseBufferCommands(client: callbackClient) else {
                    return true
                }
                if let client = callbackClient {
                    updateUI(client: client)
                } else {
                    BufferWindowController.shared.refresh()
                }
            }
            return true
        }

        if explicitClientMismatch {
            let newlineMustStayConsumed = newlineCommand
                && (bufferEnterGestureActive
                    || bufferControlDisposition(client: sender as? IMKTextInput) != .passThrough)
            let backspaceMustStayConsumed = isDeleteBackwardSelector(selector)
                && bufferControlDisposition(client: sender as? IMKTextInput) != .passThrough
            if newlineMustStayConsumed || backspaceMustStayConsumed {
                if streamInputModeSelected {
                    StreamInputWorkspace.shared.authorityRejected()
                }
                IMELog.write("buffer control command consumed without action after client mismatch selector=\(NSStringFromSelector(selector))")
                return true
            }
            IMELog.write("command rejected; current client mismatch selector=\(NSStringFromSelector(selector))")
            suspendGlobalFocusLeaseIfPresent(reason: "command current client mismatch")
            if let focusToken { candidateWindow.hide(owner: focusToken) }
            return false
        }
        if let keycode = candidateCommandKey(for: selector),
           candidateWindow.hasInteractableCandidates {
            guard let client = callbackClient else {
                IMELog.write("candidate command ignored; stale callback selector=\(NSStringFromSelector(selector))")
                return false
            }
            return handleCandidateKey(keycode, client: client)
        }
        if newlineCommand {
            switch bufferControlDisposition(client: callbackClient) {
            case .passThrough:
                IMELog.write("buffer enter fresh command passed through selector=\(NSStringFromSelector(selector))")
                return false
            case .consumeOnly, .executeBufferAction:
                if streamInputModeSelected,
                   callbackClient.flatMap({ streamInputLease(client: $0) }) == nil {
                    StreamInputWorkspace.shared.authorityRejected()
                }
                // `handle(_:client:)` is the sole Return action path. IMK's
                // informal protocol requires choosing one event strategy; this
                // defensive callback only prevents a duplicate AppKit command
                // from reaching the host and never sends or settles a block.
                IMELog.write("buffer enter command consumed; NSEvent path owns action selector=\(NSStringFromSelector(selector))")
                return true
            }
        }
        if let direction = horizontalMoveDirection(for: selector) {
            let client = callbackClient
            guard shouldUseBufferCommands(client: client) else { return false }
            if usesContinuousDerivedSourceRail {
                IMELog.write("derived source arrow command consumed direction=\(direction)")
                return true
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastBufferArrowKeyHandledAt < Self.duplicateArrowCommandWindow,
               lastBufferArrowKeyDirection == direction {
                IMELog.write("buffer arrow command consumed after key selector=\(NSStringFromSelector(selector)) direction=\(direction)")
                lastBufferArrowCommandHandledAt = now
                lastBufferArrowCommandDirection = direction
                return true
            }

            guard canMoveBufferInsertionPoint() else { return false }
            lastBufferArrowCommandHandledAt = now
            lastBufferArrowCommandDirection = direction
            _ = BufferModel.shared.moveInsertionPoint(delta: direction)
            if let client {
                updateUI(client: client)
            } else {
                BufferWindowController.shared.refresh()
            }
            return true
        }
        if let action = BufferLogicalNavigationRules.commandAction(
            selectorName: NSStringFromSelector(selector)
        ) {
            guard shouldUseBufferCommands(client: callbackClient) else {
                return false
            }
            guard canMoveBufferInsertionPoint() else {
                // The command still belongs to the active logical surface;
                // unresolved composition may ignore it, but the host must not
                // observe it behind the workbench.
                return true
            }
            switch action {
            case .moveToStart:
                if !usesContinuousDerivedSourceRail {
                    _ = BufferModel.shared.setInsertionPoint(0)
                }
            case .moveToEnd:
                if !usesContinuousDerivedSourceRail {
                    _ = BufferModel.shared.setInsertionPoint(
                        BufferModel.shared.blocks.count
                    )
                }
            case .deleteForward:
                if !usesContinuousDerivedSourceRail {
                    _ = BufferModel.shared.deleteForwardAtInsertionPoint()
                }
            case .consume:
                break
            }
            if let client = callbackClient {
                updateUI(client: client)
            } else {
                BufferWindowController.shared.refresh()
            }
            IMELog.write("buffer logical command consumed selector=\(NSStringFromSelector(selector)) action=\(action)")
            return true
        }
        guard isDeleteBackwardSelector(selector) else { return false }

        switch bufferControlDisposition(client: callbackClient) {
        case .passThrough:
            return false
        case .consumeOnly:
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer backspace command consumed without action selector=\(NSStringFromSelector(selector))")
            return true
        case .executeBufferAction:
            break
        }

        if streamInputModeSelected,
           callbackClient.flatMap({ streamInputLease(client: $0) }) == nil {
            StreamInputWorkspace.shared.authorityRejected()
            IMELog.write("stream backspace command consumed after authority changed")
            return true
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBufferBackspaceKeyHandledAt < Self.duplicateBackspaceCommandWindow {
            IMELog.write("buffer backspace command consumed after key selector=\(NSStringFromSelector(selector))")
            lastBufferBackspaceCommandHandledAt = now
            return true
        }

        guard let client = callbackClient else { return true }

        lastBufferBackspaceCommandHandledAt = now
        return performBufferBackspace(client: client, source: "command:\(NSStringFromSelector(selector))")
    }

    private func isDeleteBackwardSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.deleteBackward(_:))
            || selector == #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:))
    }

    private func bufferClipboardShortcut(
        for selector: Selector,
        physicalShortcut: BufferClipboardShortcut?
    ) -> BufferClipboardShortcut? {
        BufferClipboardCommandRules.shortcut(
            selectorName: NSStringFromSelector(selector),
            physicalShortcut: physicalShortcut
        )
    }

    private func physicalBufferClipboardShortcut() -> BufferClipboardShortcut? {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var mask: Int32 = 0
        if flags.contains(.maskShift) { mask |= RimeKey.shiftMask }
        if flags.contains(.maskControl) { mask |= RimeKey.controlMask }
        if flags.contains(.maskAlternate) { mask |= RimeKey.altMask }
        if flags.contains(.maskCommand) { mask |= RimeKey.superMask }
        if flags.contains(.maskAlphaShift) { mask |= RimeKey.lockMask }
        return BufferClipboardPhysicalShortcutRules.shortcut(
            aKeyDown: CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(0)
            ),
            vKeyDown: CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(9)
            ),
            cKeyDown: CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(kVK_ANSI_C)
            ),
            mask: mask
        )
    }

    private func recentlyHandledGeneratedResultCopyCommand(
        _ selector: Selector,
        sender: Any?
    ) -> Bool {
        guard NSStringFromSelector(selector) == "copy:",
              lastBufferClipboardShortcutHandled == .copyGeneratedResult,
              CFAbsoluteTimeGetCurrent()
                - lastBufferClipboardShortcutHandledAt
                    < Self.duplicateClipboardCommandWindow else {
            return false
        }
        if let expectedIdentity = lastBufferClipboardShortcutClientIdentity,
           let client = sender as? IMKTextInput,
           expectedIdentity != ObjectIdentifier(client as AnyObject) {
            return false
        }
        // If C is physically down but this controller does not own its keyDown,
        // this is a fresh command-only fallback rather than a late callback
        // from the copied-and-closed press.
        let cKeyCode = UInt16(kVK_ANSI_C)
        if CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(kVK_ANSI_C)
        ), !bufferClipboardShortcutKeysDown.contains(cKeyCode) {
            return false
        }
        return true
    }

    private func noteGeneratedResultCopyHandled(client: IMKTextInput?) {
        lastBufferClipboardShortcutHandledAt = CFAbsoluteTimeGetCurrent()
        lastBufferClipboardShortcutHandled = .copyGeneratedResult
        lastBufferClipboardShortcutClientIdentity = client.map {
            ObjectIdentifier($0 as AnyObject)
        }
    }

    private func physicalBufferPluginSwitchDirection() -> Int? {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }

        let previous = RimeShortcutPreferences.shortcut(for: .previousPlugin)
        let next = RimeShortcutPreferences.shortcut(for: .nextPlugin)
        let previousDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(previous.keyCode)
        ) && previous.modifiers == modifiers
        let nextDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(next.keyCode)
        ) && next.modifiers == modifiers
        guard previousDown != nextDown else { return nil }
        return previousDown ? -1 : 1
    }

    @discardableResult
    private func performBufferPluginSwitch(direction: Int,
                                           client: IMKTextInput,
                                           source: String) -> Bool {
        guard shouldUseBufferCommands(client: client),
              !IsSecureEventInputEnabled() else { return false }
        let plugins = PluginRegistry.shared.plugins(capability: .bufferAction)
        let entry = BufferPluginMenuCatalog.adjacentEntry(
            from: BufferPluginSelectionStore.shared.activeKey,
            direction: direction,
            plugins: plugins
        )
        do {
            if let key = entry.key {
                try PluginRegistry.shared.setBufferPluginActive(true, for: key)
            } else {
                BufferPluginSelectionStore.shared.clear()
            }
        } catch {
            NSSound.beep()
            IMELog.write("buffer plugin switch failed source=\(source)")
            return true
        }
        guard shouldUseBufferCommands(client: client),
              BufferPluginSelectionStore.shared.activeKey == entry.key else {
            IMELog.write("buffer plugin switch consumed after state changed source=\(source)")
            return true
        }
        IMELog.write("buffer plugin switched direction=\(direction) title=\(entry.title) source=\(source)")
        updateUI(client: client)
        BufferWindowController.shared.refresh()
        return true
    }

    private func isCancelOperationSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.cancelOperation(_:))
    }

    private func isInsertNewlineSelector(_ selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:))
            || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(NSResponder.insertParagraphSeparator(_:))
    }

    private func horizontalMoveDirection(for selector: Selector) -> Int? {
        if selector == #selector(NSResponder.moveLeft(_:)) {
            return -1
        }
        if selector == #selector(NSResponder.moveRight(_:)) {
            return 1
        }
        return nil
    }

    private func verticalMoveDirection(for selector: Selector) -> Int? {
        if selector == #selector(NSResponder.moveUp(_:)) {
            return -1
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            return 1
        }
        return nil
    }

    private func candidateCommandKey(for selector: Selector) -> Int32? {
        if selector == #selector(NSResponder.moveLeft(_:)) {
            return RimeKey.left
        }
        if selector == #selector(NSResponder.moveRight(_:)) {
            return RimeKey.right
        }
        if selector == #selector(NSResponder.moveUp(_:)) {
            return RimeKey.up
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            return RimeKey.down
        }
        return nil
    }

    private func canMoveBufferInsertionPoint() -> Bool {
        guard !chord.hasPending, !composition.composing else { return false }
        guard session != 0 else { return true }
        let ctx = rimeEngine.getContext(session: session)
        return !ctx.active && ctx.input.isEmpty && ctx.preedit.isEmpty
    }

    private func cancelFocusBoundGestures() {
        // Shift press is deferred, so cancellation creates no librime release
        // debt. Keep the physical gesture only to discard a later same-focus
        // release if the key remains held across activation.
        shiftGesture?.cancelForFocusChange()
        let mustConsumeRelease = bufferEnterPending
            || bufferEnterSuppressUntilPhysicalUp
            || bufferEnterCallbackOwnership.suppressesKeyUp
        resetBufferEnterGesture()
        if mustConsumeRelease {
            // The action is cancelled with the lease, but the physical key may
            // still be down. Keep swallowing its release/repeat events without
            // retaining a client or permitting delivery to the displaced field.
            bufferEnterSuppressUntilPhysicalUp = true
            scheduleBufferEnterPoll()
        }
        resetCandidateOptionGesture()
        streamAlternativeNavigationKeysDown.removeAll()
        derivedResultNavigationKeysDown.removeAll()
        bufferPluginNavigationKeysDown.removeAll()
        let copyKeyCode = UInt16(kVK_ANSI_C)
        let preservesGeneratedCopyRelease =
            bufferClipboardShortcutKeysDown.contains(copyKeyCode)
        bufferClipboardShortcutKeysDown.removeAll()
        if preservesGeneratedCopyRelease {
            // Copy may synchronously close Buffer and revoke its capture lease.
            // The already-owned physical release must still not leak into the
            // newly direct host route.
            bufferClipboardShortcutKeysDown.insert(copyKeyCode)
        }
    }

    /// End delivery/hold tracking only. Callback ownership is intentionally not
    /// reset here: keyUp and insertNewline: can arrive after this action changes
    /// focus or makes the last transient buffer block inactive.
    private func resetBufferEnterGesture() {
        bufferEnterPending = false
        bufferEnterSuppressUntilPhysicalUp = false
        bufferEnterClient = nil
        bufferEnterOwner = nil
        bufferEnterUsesStreamInput = false
        bufferEnterPluginOwner = nil
        bufferEnterDeliveryWorkspaceID = nil
        bufferEnterDeliverySourceIdentity = nil
        bufferEnterDeliveryGeneration = nil
        bufferEnterPollTimer?.invalidate()
        bufferEnterPollTimer = nil
        BufferWindowController.shared.setEnterHoldProgress(nil)
    }

    /// Editing the staged source cancels a pending tap/hold action. Keep the
    /// physical Return callbacks owned until release so its later timer/keyUp
    /// cannot send the text that was just selected or pasted.
    private func cancelBufferEnterActionForSourceEditing() {
        guard bufferEnterActionActive || bufferEnterCallbackOwnership.ownsCallbacks else {
            return
        }
        let mustConsumeRelease = bufferEnterActionActive
            || bufferEnterCallbackOwnership.suppressesKeyUp
        resetBufferEnterGesture()
        if mustConsumeRelease {
            bufferEnterSuppressUntilPhysicalUp = true
            scheduleBufferEnterPoll()
        }
    }

    private func beginBufferEnterGesture(client: IMKTextInput,
                                         hardwareKeyCode: UInt16) {
        guard let lease = currentLease(matching: client) else { return }
        bufferEnterPending = true
        bufferEnterSuppressUntilPhysicalUp = false
        bufferEnterCallbackOwnership.claimPress()
        bufferEnterClient = client
        bufferEnterOwner = lease.token
        bufferEnterUsesStreamInput = streamInputModeSelected
        let deliverySource = BufferDeliveryContentRouter.current()
        bufferEnterPluginOwner = BufferPluginSelectionStore.shared.activeKey
        bufferEnterDeliveryWorkspaceID = deliverySource.deliveryWorkspaceID
        bufferEnterDeliverySourceIdentity = ObjectIdentifier(deliverySource)
        bufferEnterDeliveryGeneration = deliverySource.deliveryGeneration
        bufferEnterHardwareKeyCode = CGKeyCode(hardwareKeyCode)
        bufferEnterStartedAt = CFAbsoluteTimeGetCurrent()
        // Reassert only for the exact Return keyDown. This gives Chromium a
        // current IME marked-text transaction even if the web editor silently
        // ended the lease's earlier idle guard, while preserving tap/hold
        // timing for the actual delivery decision.
        reassertBufferControlGuardIfAllowed(client: client)
        BufferWindowController.shared.setEnterHoldProgress(0)
        scheduleBufferEnterPoll()
        IMELog.write("buffer enter gesture began keyCode=\(hardwareKeyCode)")
    }

    /// A Return that settled composition must consume the rest of the same
    /// physical press without becoming a tap-send on keyUp.
    private func suppressBufferEnterAfterComposition(client: IMKTextInput,
                                                     hardwareKeyCode: UInt16) {
        let lease = currentLease(matching: client)
        bufferEnterPending = false
        bufferEnterSuppressUntilPhysicalUp = true
        bufferEnterCallbackOwnership.claimPress()
        bufferEnterClient = client
        bufferEnterOwner = lease?.token
        bufferEnterUsesStreamInput = streamInputModeSelected
        bufferEnterPluginOwner = nil
        bufferEnterDeliveryWorkspaceID = nil
        bufferEnterDeliverySourceIdentity = nil
        bufferEnterDeliveryGeneration = nil
        bufferEnterHardwareKeyCode = CGKeyCode(hardwareKeyCode)
        bufferEnterStartedAt = CFAbsoluteTimeGetCurrent()
        BufferWindowController.shared.setEnterHoldProgress(nil)
        scheduleBufferEnterPoll()
    }

    /// Claim a non-delivery Return on keyDown, reasserting the invisible IME
    /// guard before an AI request or no-op state can reach a web editor.
    private func suppressBufferEnterForImmediateAction(client: IMKTextInput,
                                                       hardwareKeyCode: UInt16) {
        let lease = currentLease(matching: client)
        bufferEnterPending = false
        bufferEnterSuppressUntilPhysicalUp = true
        bufferEnterCallbackOwnership.claimPress()
        bufferEnterClient = client
        bufferEnterOwner = lease?.token
        bufferEnterUsesStreamInput = false
        bufferEnterPluginOwner = nil
        bufferEnterDeliveryWorkspaceID = nil
        bufferEnterDeliverySourceIdentity = nil
        bufferEnterDeliveryGeneration = nil
        bufferEnterHardwareKeyCode = CGKeyCode(hardwareKeyCode)
        bufferEnterStartedAt = CFAbsoluteTimeGetCurrent()
        reassertBufferControlGuardIfAllowed(client: client)
        BufferWindowController.shared.setEnterHoldProgress(nil)
        scheduleBufferEnterPoll()
    }

    /// The invisible Chromium guard is never legal in a secure field. This is
    /// checked at the action boundary instead of relying on the workbench's
    /// periodic privacy refresh, which can lag an OS secure-input transition.
    private func reassertBufferControlGuardIfAllowed(client: IMKTextInput) {
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              BufferEnterSecureInputRules.disposition(
            secureInputEnabled: IsSecureEventInputEnabled()
        ) == .normal else { return }
        composition.reassertBufferGuard(rimeComposing: false,
                                        client: client)
    }

    /// Own an untrusted Return press without retaining a client or focus token.
    /// This prevents a repeat event from starting a gesture if focus becomes
    /// trustworthy again while the same physical key is still held.
    private func suppressUntrustedBufferEnter(hardwareKeyCode: UInt16) {
        resetBufferEnterGesture()
        bufferEnterSuppressUntilPhysicalUp = true
        bufferEnterCallbackOwnership.claimPress()
        bufferEnterHardwareKeyCode = CGKeyCode(hardwareKeyCode)
        bufferEnterStartedAt = CFAbsoluteTimeGetCurrent()
        scheduleBufferEnterPoll()
    }

    private func scheduleBufferEnterPoll() {
        bufferEnterPollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.bufferEnterPollInterval,
                          repeats: false) { [weak self] _ in
            self?.pollBufferEnterGesture()
        }
        bufferEnterPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollBufferEnterGesture() {
        if bufferEnterSuppressUntilPhysicalUp, bufferEnterOwner == nil {
            if isBufferEnterPhysicallyDown() {
                scheduleBufferEnterPoll()
            } else {
                resetBufferEnterGesture()
            }
            return
        }

        guard let owner = bufferEnterOwner,
              focusToken == owner,
              InputFocusCoordinator.shared.isCurrent(owner, controller: self) else {
            let stillDown = isBufferEnterPhysicallyDown()
            resetBufferEnterGesture()
            if stillDown {
                bufferEnterSuppressUntilPhysicalUp = true
                scheduleBufferEnterPoll()
            }
            return
        }

        if bufferEnterSuppressUntilPhysicalUp {
            if isBufferEnterPhysicallyDown() {
                scheduleBufferEnterPoll()
            } else {
                resetBufferEnterGesture()
            }
            return
        }

        guard bufferEnterPending else { return }
        guard shouldUseBufferCommands(client: bufferEnterClient) else {
            let stillDown = isBufferEnterPhysicallyDown()
            resetBufferEnterGesture()
            if stillDown {
                bufferEnterSuppressUntilPhysicalUp = true
                scheduleBufferEnterPoll()
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - bufferEnterStartedAt
        switch BufferEnterGestureRules.pollDecision(
            isPhysicalDown: isBufferEnterPhysicallyDown(),
            elapsed: elapsed,
            holdDelay: Self.bufferEnterHoldDelay
        ) {
        case let .wait(progress):
            BufferWindowController.shared.setEnterHoldProgress(progress)
            scheduleBufferEnterPoll()
        case .sendNext:
            lastBufferEnterKeyHandledAt = now
            _ = performBufferEnterSend(all: false,
                                       client: bufferEnterClient,
                                       expectedOwner: owner,
                                       source: "physical tap")
            resetBufferEnterGesture()
        case .sendAll:
            lastBufferEnterKeyHandledAt = CFAbsoluteTimeGetCurrent()
            bufferEnterPending = false
            bufferEnterSuppressUntilPhysicalUp = true
            BufferWindowController.shared.setEnterHoldProgress(1)
            _ = performBufferEnterSend(all: true,
                                       client: bufferEnterClient,
                                       expectedOwner: owner,
                                       source: "physical hold")
            scheduleBufferEnterPoll()
        }
    }

    private func isBufferEnterPhysicallyDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState,
                               key: bufferEnterHardwareKeyCode)
    }

    @discardableResult
    private func beginCandidateOptionSelection(client: IMKTextInput) -> Bool {
        if candidateOptionSelecting { return true }
        if chord.hasPending {
            IMELog.write("candidate option resolving pending chord before local action")
            chord.flush()
        }
        mutualPairingState.reset()
        guard candidateWindow.hasInteractableCandidates,
              let candidateText = candidateWindow.selectedCandidateText,
              candidateWindow.beginSingleCharacterSelection(candidateText: candidateText) else {
            return false
        }
        candidateOptionSelecting = true
        candidateOptionClient = client
        IMELog.write("candidate option selection started text=\(IMELog.redact(candidateText))")
        return true
    }

    private func resetCandidateOptionGesture() {
        candidateOptionSelecting = false
        candidateOptionClient = nil
        candidateWindow.cancelSingleCharacterSelection()
    }

    private func finishCandidateOptionSelection(client: IMKTextInput?, source: String) {
        guard candidateOptionSelecting else { return }
        guard candidateWindow.hasInteractableCandidates else {
            IMELog.write("candidate option release consumed; panel not interactable")
            resetCandidateOptionGesture()
            return
        }
        let proposedClient = client ?? candidateOptionClient
        let resolvedClient = proposedClient.flatMap {
            currentCallbackClient($0)
        }
        guard resolvedClient != nil else {
            IMELog.write("candidate option release ignored; focus changed")
            resetCandidateOptionGesture()
            return
        }
        IMELog.write("candidate option released by \(source); commit selected character")
        _ = commitSelectedSingleCharacter(client: resolvedClient, source: source)
        resetCandidateOptionGesture()
    }

    private func handleCandidateOptionSelectionKey(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard candidateOptionSelecting || candidateWindow.isSingleCharacterSelectionActive else { return false }
        switch keycode {
        case RimeKey.left:
            return candidateWindow.moveSingleCharacterSelection(delta: -1)
        case RimeKey.right:
            return candidateWindow.moveSingleCharacterSelection(delta: 1)
        case RimeKey.space, RimeKey.return:
            finishCandidateOptionSelection(client: client, source: "candidate key")
            return true
        case RimeKey.escape:
            resetCandidateOptionGesture()
            return true
        default:
            return true
        }
    }

    @discardableResult
    private func commitCandidateSpaceTap(client: IMKTextInput?, source: String) -> Bool {
        let resolvedClient = client.flatMap {
            currentCallbackClient($0)
        }
        guard let resolvedClient else {
            IMELog.write("candidate space ignored; focus changed")
            return true
        }
        guard let selection = candidateWindow.selectedCandidateSelection else {
            return processRimeKey(RimeKey.space, mask: 0, client: resolvedClient)
        }
        IMELog.write("candidate space \(source); commit pageOffset=\(selection.pageOffset) index=\(selection.index)")
        selectCandidate(selection)
        return true
    }

    @discardableResult
    private func commitSelectedSingleCharacter(client: IMKTextInput?, source: String) -> Bool {
        let resolvedClient = client.flatMap {
            currentCallbackClient($0)
        }
        guard let resolvedClient else {
            IMELog.write("candidate single-character ignored; focus changed")
            return true
        }
        guard let text = candidateWindow.selectedSingleCharacterText, !text.isEmpty else {
            return commitCandidateSpaceTap(client: resolvedClient, source: "\(source) fallback")
        }

        if session != 0 {
            rimeEngine.clearComposition(session: session)
        }

        let capturesInClipboardSearch = shouldCaptureClipboardSearchCommit(
            from: resolvedClient
        )
        let capturesInBuffer = shouldCaptureCommit(from: resolvedClient)
        if capturesInClipboardSearch {
            guard appendClipboardSearchCommit(text, client: resolvedClient) else {
                IMELog.write("candidate single-character clipboard search commit rejected")
                return true
            }
        } else if capturesInBuffer {
            if let focusToken {
                BufferWindowController.shared.clearInlineComposition(owner: focusToken)
                candidateWindow.hide(owner: focusToken)
            }
            BufferModel.shared.append(text)
            clearCompositionPresentation(client: resolvedClient)
            publishAuthoredCommitTelemetry(characterCount: text.count,
                                           source: .buffer,
                                           client: resolvedClient)
            IMELog.write("candidate single-character \(IMELog.redact(text)) -> buffer by \(source) (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(text, client: resolvedClient)
            if inserted {
                publishAuthoredCommitTelemetry(characterCount: text.count,
                                               source: .direct,
                                               client: resolvedClient)
            }
            IMELog.write("candidate single-character \(IMELog.redact(text)) inserted=\(inserted) target=\(cachedBundleID(for: resolvedClient)) by \(source)")
        }

        if let focusToken {
            InputFocusCoordinator.shared.setCompositionActive(false, token: focusToken)
        }
        updateUI(client: resolvedClient)
        return true
    }

    /// Returns true when this Return press was spent settling (or safely
    /// preserving) an in-flight composition. The caller must then suppress the
    /// rest of that physical press so the newly created block is not sent by
    /// the same keyUp.
    private func settlePendingBufferCompositionIfNeeded(client: IMKTextInput,
                                                        source: String) -> Bool {
        let localPending = chord.hasPending || composition.composing
        var contextPending = false
        if session != 0, rimeEngine.isHealthy {
            let ctx = rimeEngine.getContext(session: session)
            contextPending = ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty
        }
        let candidateRawPending = candidateWindow.isVisible
            && !candidateWindow.rawInputForCommit.isEmpty
        guard localPending || contextPending || candidateRawPending else {
            return false
        }

        guard rimeEngine.start(), ensureSessionReady(), session != 0 else {
            IMELog.write("buffer enter \(source) consumed; engine unavailable while composing")
            return true
        }

        let blockCountBefore = BufferModel.shared.blocks.count
        withForcedBufferCapture {
            if !commitRawInput(client: client) {
                let ctx = rimeEngine.getContext(session: session)
                if chord.hasPending || composition.composing || ctx.active
                    || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                    resolveComposition(
                        client: client,
                        owner: focusToken,
                        trustedLease: currentLease(matching: client)
                    )
                    updateUI(client: client)
                }
            }
        }
        IMELog.write("buffer enter \(source) settled composition blocks=\(blockCountBefore)->\(BufferModel.shared.blocks.count); delivery deferred to next press")
        return true
    }

    private func bufferCompositionIsSettledForSourceEditing() -> Bool {
        guard !chord.hasPending,
              !composition.composing,
              candidateWindow.rawInputForCommit.isEmpty else { return false }
        guard session != 0 else { return true }
        // If the engine is unavailable, the controller-owned mirrors above are
        // the only state we can safely inspect. A pending mirror already failed
        // the guard; an idle mirror must not disable clipboard editing entirely.
        guard rimeEngine.isHealthy else { return true }
        let context = rimeEngine.getContext(session: session)
        return !context.active && context.input.isEmpty && context.preedit.isEmpty
    }

    @discardableResult
    private func performBufferEnterSend(all: Bool,
                                        client: IMKTextInput?,
                                        expectedOwner: FocusToken?,
                                        source: String) -> Bool {
        let currentDeliverySource = BufferDeliveryContentRouter.current()
        guard BufferPluginSelectionStore.shared.activeKey == bufferEnterPluginOwner,
              let expectedWorkspaceID = bufferEnterDeliveryWorkspaceID,
              let expectedSourceIdentity = bufferEnterDeliverySourceIdentity,
              let expectedGeneration = bufferEnterDeliveryGeneration,
              currentDeliverySource.deliveryWorkspaceID == expectedWorkspaceID,
              ObjectIdentifier(currentDeliverySource) == expectedSourceIdentity,
              currentDeliverySource.deliveryGeneration == expectedGeneration else {
            IMELog.write("buffer enter \(source) consumed without delivery; delivery source changed")
            return true
        }
        if bufferEnterUsesStreamInput {
            guard streamInputModeSelected,
                  let resolvedClient = client,
                  let expectedOwner,
                  let lease = streamInputLease(client: resolvedClient),
                  lease.token == expectedOwner else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream return \(source) consumed without delivery; authority changed")
                return true
            }
        }
        guard let resolvedClient = client,
              currentCallbackClient(resolvedClient) != nil,
              shouldUseBufferCommands(client: resolvedClient),
              let expectedOwner,
              focusToken == expectedOwner,
              InputFocusCoordinator.shared.isCurrent(expectedOwner,
                                                     controller: self) else {
            if bufferEnterUsesStreamInput {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer enter \(source) consumed without delivery; focus changed")
            return true
        }

        if !bufferEnterUsesStreamInput,
           settlePendingBufferCompositionIfNeeded(client: resolvedClient,
                                                   source: source) {
            return true
        }

        let pendingBefore = BufferModel.shared.pendingDeliveryCount
        let result = all
            ? BufferDeliveryCoordinator.shared.sendAll(
                resolveCompositionIfNeeded: false,
                expectedToken: expectedOwner
              )
            : BufferDeliveryCoordinator.shared.sendNext(
                resolveCompositionIfNeeded: false,
                expectedToken: expectedOwner
              )
        IMELog.write("buffer enter \(source) consumed; action=\(all ? "send-all" : "send-next") sent=\(result.sentCount) pending=\(pendingBefore)->\(BufferModel.shared.pendingDeliveryCount)")
        if currentCallbackClient(resolvedClient) != nil {
            updateUI(client: resolvedClient)
        }
        return true
    }

    @discardableResult
    private func performBufferClipboardShortcut(
        _ shortcut: BufferClipboardShortcut,
        client: IMKTextInput,
        expectedLease: FocusLease?
    ) -> Bool {
        guard !IsSecureEventInputEnabled(),
              let lease = expectedLease ?? currentLease(matching: client),
              lease.controller === self,
              lease.clientIdentity == ObjectIdentifier(client as AnyObject),
              shouldUseBufferCommands(client: client),
              InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
              ) === lease,
              focusToken == lease.token else {
            if shortcut != .copyGeneratedResult {
                BufferModel.shared.clearAllContentSelection()
                if streamInputModeSelected {
                    StreamInputWorkspace.shared.authorityRejected()
                }
            }
            IMELog.write("buffer clipboard shortcut rejected before source access")
            return true
        }

        if shortcut == .copyGeneratedResult {
            return BufferWindowController.shared.copyGeneratedResultAndClose(
                expectedToken: lease.token
            )
        }

        cancelBufferEnterActionForSourceEditing()

        if streamInputModeSelected {
            guard let streamLease = streamInputLease(client: client),
                  streamLease === lease,
                  prepareForStreamInputCapture(client: client, lease: streamLease),
                  self.streamInputLease(client: client) === streamLease else {
                StreamInputWorkspace.shared.authorityRejected()
                return true
            }
        } else {
            // Make Select All include any active chord/preedit. Paste likewise
            // resolves the composition before it changes the selected source.
            _ = settlePendingBufferCompositionIfNeeded(
                client: client,
                source: "clipboard shortcut"
            )
            guard bufferCompositionIsSettledForSourceEditing() else {
                IMELog.write("buffer clipboard shortcut consumed with unresolved composition")
                return true
            }
        }

        guard !IsSecureEventInputEnabled(),
              shouldUseBufferCommands(client: client),
              currentLease(matching: client) === lease,
              InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
              ) === lease,
              focusToken == lease.token else {
            BufferModel.shared.clearAllContentSelection()
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer clipboard shortcut rejected after composition settlement")
            return true
        }

        // Chromium/Electron can silently end the lease's idle marked-text
        // session, then observe an owned A/V key around IMK's handled result.
        // Reinstall the guard for every exact shortcut, after real preedit has
        // settled but before source mutation or any pasteboard access.
        reassertBufferControlGuardIfAllowed(client: client)

        // setMarkedText may synchronously re-enter the host and move focus or
        // enable secure input. The shortcut remains consumed, but it cannot
        // inspect the clipboard or edit source unless the same lease survived.
        guard !IsSecureEventInputEnabled(),
              shouldUseBufferCommands(client: client),
              currentLease(matching: client) === lease,
              InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
              ) === lease,
              focusToken == lease.token else {
            BufferModel.shared.clearAllContentSelection()
            if streamInputModeSelected {
                StreamInputWorkspace.shared.authorityRejected()
            }
            IMELog.write("buffer clipboard shortcut rejected after guard reassertion")
            return true
        }

        switch shortcut {
        case .selectAll:
            if streamInputModeSelected {
                _ = StreamInputWorkspace.shared.selectAllInput(
                    focusToken: lease.token
                )
            } else {
                _ = BufferModel.shared.selectAllContent()
            }
        case .paste:
            // Pasteboard access happens only after every secure-input and exact
            // lease check above. Revalidate once more after AppKit returns the
            // value because pasteboard providers can be lazy.
            guard let text = BufferClipboardTextRules.validated(
                NSPasteboard.general.string(forType: .string)
            ) else {
                IMELog.write("buffer paste consumed without accepted plain text")
                return true
            }
            guard !IsSecureEventInputEnabled(),
                  shouldUseBufferCommands(client: client),
                  currentLease(matching: client) === lease,
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: lease.token
                  ) === lease,
                  focusToken == lease.token else {
                BufferModel.shared.clearAllContentSelection()
                if streamInputModeSelected {
                    StreamInputWorkspace.shared.authorityRejected()
                }
                IMELog.write("buffer paste rejected after pasteboard read")
                return true
            }
            if streamInputModeSelected {
                _ = StreamInputWorkspace.shared.insertPastedText(
                    text,
                    focusToken: lease.token
                )
            } else {
                _ = BufferModel.shared.insertPastedText(text)
            }
        case .copyGeneratedResult:
            // Handled above before any source-editing or pasteboard-read path.
            break
        }

        IMELog.write("buffer clipboard shortcut handled action=\(shortcut)")
        updateUI(client: client)
        BufferWindowController.shared.refresh()
        return true
    }

    private func performBufferBackspace(client: IMKTextInput, source: String) -> Bool {
        if streamInputModeSelected {
            guard let lease = streamInputLease(client: client),
                  StreamInputWorkspace.shared.deleteBackward(
                    focusToken: lease.token
                  ),
                  streamInputLease(client: client) === lease else {
                StreamInputWorkspace.shared.authorityRejected()
                IMELog.write("stream input backspace consumed without authority source=\(source)")
                return true
            }
            IMELog.write("stream input backspace consumed source=\(source)")
            updateUI(client: client)
            return true
        }
        if !BufferModel.shared.enabled {
            if chord.hasPending || composition.composing {
                IMELog.write("buffer backspace \(source) consumed; transient mode left host composition untouched")
                return true
            }
            if session != 0 {
                let ctx = rimeEngine.getContext(session: session)
                if ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                    IMELog.write("buffer backspace \(source) consumed; transient preedit not resolved")
                    return true
                }
            }
            _ = removeLastBufferedInput()
            BufferWindowController.shared.refresh()
            return true
        }

        guard rimeEngine.start(), ensureSessionReady(), session != 0 else {
            if !removeLastBufferedInput() {
                IMELog.write("buffer backspace \(source) consumed; engine unavailable/no blocks")
            }
            publishCompositionActive(false)
            BufferWindowController.shared.refresh()
            return true
        }

        if chord.hasPending || composition.composing {
            _ = processRimeKey(RimeKey.backspace, mask: 0, client: client)
            return true
        }

        let ctx = rimeEngine.getContext(session: session)
        if ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
            _ = processRimeKey(RimeKey.backspace, mask: 0, client: client)
            return true
        }

        if !removeLastBufferedInput() {
            IMELog.write("buffer backspace \(source) consumed; no blocks")
        }
        publishCompositionActive(false)
        updateUI(client: client)
        return true
    }

    private func removeLastBufferedInput() -> Bool {
        if usesContinuousDerivedSourceRail {
            return BufferModel.shared.removeLastCharacter()
        }
        if let focusToken,
           BufferModel.shared.deleteBackwardInDirectInput(
               owner: .focus(focusToken)
           ) {
            return true
        }
        return BufferModel.shared.removeLastBlock()
    }

    private var usesContinuousDerivedSourceRail: Bool {
        DerivedBufferWorkspaceRouter.selectedWorkspace != nil
    }

    private func shiftedDirectText(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift),
              flags.intersection([.control, .option, .command, .function]).isEmpty,
              let text = event.characters,
              !text.isEmpty,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return nil
        }
        return text
    }

    private func insertDirectText(_ text: String,
                                  client: IMKTextInput,
                                  source: String,
                                  expectedLease: FocusLease? = nil) -> Bool {
        // Secure fields keep native host handling. If secure input appears
        // later in this transaction, fail closed instead of retaining text.
        guard !IsSecureEventInputEnabled() else { return false }
        let capturesInClipboardSearch = shouldCaptureClipboardSearchCommit(
            from: client
        )
        let capturesInBuffer = expectedLease.map {
            $0.isExternalTarget
                && BufferModel.shared.capturesInput(for: $0.token)
        } ?? false
        if BufferModel.shared.enabled,
           !capturesInBuffer,
           !capturesInClipboardSearch,
           !isOwnClient(client) {
            IMELog.write("\(source) text consumed; no adopted external buffer lease")
            return true
        }
        if capturesInBuffer || capturesInClipboardSearch {
            guard let expectedLease,
                  expectedLease.controller === self,
                  expectedLease.clientIdentity == ObjectIdentifier(client as AnyObject),
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: expectedLease.token
                  ) === expectedLease,
                  focusToken == expectedLease.token else {
                IMELog.write("\(source) text consumed; adopted logical-input lease changed")
                return true
            }
        }
        if rimeEngine.isHealthy, session != 0 {
            let ctx = rimeEngine.getContext(session: session)
            if chord.hasPending || composition.composing || ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty {
                resolveComposition(client: client,
                                   owner: expectedLease?.token ?? focusToken,
                                   trustedLease: expectedLease
                                       ?? currentLease(matching: client))
            }
        }

        if capturesInClipboardSearch {
            guard !IsSecureEventInputEnabled(),
                  let expectedLease,
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: expectedLease.token
                  ) === expectedLease,
                  focusToken == expectedLease.token,
                  appendClipboardSearchCommit(text, client: client) else {
                IMELog.write("\(source) text consumed; clipboard search lease changed")
                return true
            }
        } else if capturesInBuffer {
            guard let expectedLease,
                  !IsSecureEventInputEnabled(),
                  InputFocusCoordinator.shared.interactionTarget(
                    expected: expectedLease.token
                  ) === expectedLease,
                  focusToken == expectedLease.token else {
                IMELog.write("\(source) text consumed; buffer lease changed before append")
                return true
            }
            BufferWindowController.shared.clearInlineComposition(
                owner: expectedLease.token
            )
            candidateWindow.hide(owner: expectedLease.token)
            // Rime declines ASCII letters in English mode and passes most
            // symbols straight through. Those keys are exactly how the user
            // writes English and punctuation, so in stream mode they belong in
            // the raw line rather than as hidden buffer blocks.
            if streamInputModeSelected,
               StreamInputWorkspace.shared.insertTypedText(
                 text,
                 focusToken: expectedLease.token
               ) {
                clearCompositionPresentation(client: client)
                publishAuthoredCommitTelemetry(characterCount: text.count,
                                               source: .buffer,
                                               client: client)
                IMELog.write(
                    "\(source) text \(IMELog.redact(text)) -> stream raw"
                )
                return true
            }
            BufferModel.shared.appendDirectInputFragment(
                text,
                owner: .focus(expectedLease.token)
            )
            clearCompositionPresentation(client: client)
            publishAuthoredCommitTelemetry(characterCount: text.count,
                                           source: .buffer,
                                           client: client)
            IMELog.write("\(source) text \(IMELog.redact(text)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(text, client: client)
            if inserted {
                publishAuthoredCommitTelemetry(characterCount: text.count,
                                               source: .direct,
                                               client: client)
            }
            IMELog.write("\(source) text \(IMELog.redact(text)) inserted=\(inserted) target=\(cachedBundleID(for: client))")
            guard inserted else { return false }
        }
        publishCompositionActive(false)
        BufferWindowController.shared.refresh()
        // Always refresh the exact lease after direct/fallback insertion.
        // `updateUI` owns the sessionless path that reinstalls the invisible
        // buffer guard; skipping it here lets Chromium/Codex observe the next
        // raw Return after one engine-down character.
        updateUI(client: client)
        return true
    }

    /// keyDown → Rime keysym: letters/punct/F-keys via the virtual-key table,
    /// then editing/navigation keys, then any typed ASCII character.
    private func keysym(for event: NSEvent) -> Int32? {
        if let k = RimeKey.fromVirtualKeyCode(event.keyCode) { return k }
        switch event.keyCode {
        case 36, 76: return RimeKey.return
        case 48:     return RimeKey.tab
        case 49:     return RimeKey.space
        case 50:
            // grave/backtick. Ctrl+grave & Ctrl+Shift+grave are the user's
            // switcher hotkeys (Rime matches keysym `grave`); a plain Shift+`
            // must stay asciitilde so ～ punctuation keeps working.
            if event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.control) {
                return 0x7e
            }
            return 0x60
        case 51:     return RimeKey.backspace
        case 53:     return RimeKey.escape
        case 117:    return RimeKey.deleteForward
        case 115:    return RimeKey.home
        case 119:    return RimeKey.end
        case 116:    return RimeKey.pageUp
        case 121:    return RimeKey.pageDown
        case 123:    return RimeKey.left
        case 124:    return RimeKey.right
        case 125:    return RimeKey.down
        case 126:    return RimeKey.up
        default:
            if let scalar = event.characters?.unicodeScalars.first {
                return RimeKey.fromScalar(scalar)
            }
            return nil
        }
    }

    /// Single unified path for every key. Modifier-held keys are fed to Rime
    /// FIRST (the user's config binds e.g. Control+Shift+3 → ascii_punct);
    /// unhandled ones fall through to the app (Cmd-C etc. keep working).
    private func processRimeKey(_ keycode: Int32, mask: Int32, client: IMKTextInput) -> Bool {
        let isPress = mask & RimeKey.releaseMask == 0
        // A chord key is a PLAIN press of a chording letter — anything carrying
        // Ctrl/Opt/Cmd is a shortcut/binding, never chord material.
        let hasCommandModifier = mask & (
            RimeKey.controlMask | RimeKey.altMask | RimeKey.superMask
        ) != 0
        let isChordKey = isPress
            && !hasCommandModifier
            && ChordKeymapStore.shared.activeProfile.half(for: keycode) != nil
            && chordGated
        // Prototype semantics: a PRESS of a non-chord key resolves the pending
        // chord before processing; release events never pre-flush.
        if isPress, !isChordKey {
            chord.flush()
            mutualPairingState.reset()
        }

        if isChordKey {
            let batchPolicy: FlyChordSettlementPolicy
            if !chord.hasPending {
                guard let focusToken else {
                    IMELog.write("FlyYao press rejected without a focus owner")
                    return false
                }
                let policy = flyChordSettlementPolicy
                pendingFlyChordBase = (
                    context: rimeEngine.getContext(session: session),
                    policy: policy,
                    profile: ChordKeymapStore.shared.activeProfile,
                    owner: focusToken,
                    clientIdentity: ObjectIdentifier(client as AnyObject)
                )
                batchPolicy = pendingFlyChordBase?.policy ?? policy
            } else {
                batchPolicy = pendingFlyChordBase?.policy ?? flyChordSettlementPolicy
            }
            let decision = chord.stageChordKey(
                keycode,
                mask: mask,
                client: client,
                policy: batchPolicy,
                layout: pendingFlyChordBase?.profile
            )
            switch decision {
            case .consume:
                // Duplicate/overflow events stay consumed while the original
                // staged batch owns the temporary composition guard.
                updateUI(client: client)
                return true
            case let .process(keys):
                // Presses are deliberately staged until the batch boundary.
                // Every shape settles; unified 并击 may later recombine a left-only
                // batch with the following right-only batch.
                for key in keys {
                    chord.noteHandledChordKey(key.keycode, mask: key.mask)
                }
                updateUI(client: client)
                return true
            }
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let handled = rimeEngine.processKey(keycode, mask: mask, session: session)
        watchdog("processKey k=\(keycode) m=\(mask)", since: t0)

        if handled {
            chord.flush()   // prototype flushed after any handled non-chord event
        }
        drainCommit(client)
        updateUI(client: client)
        return handled
    }

    private func handleFlags(_ event: NSEvent, client: IMKTextInput) -> Bool {
        let modifiers = event.modifierFlags
        var changes = lastModifiers.symmetricDifference(modifiers)
        if !changes.isEmpty {
            publishTelemetryModifierPress(event, client: client)
        }

        let nonShiftChanges = changes.subtracting(.shift)
        let isSecondShiftTransition = changes.isEmpty
            && modifiers.contains(.shift)
            && (event.keyCode == 56 || event.keyCode == 60)
        if !nonShiftChanges.isEmpty
            || (modifiers.contains(.shift) && isSecondShiftTransition) {
            shiftGesture?.noteModifierUse()
        }

        // Every trusted flagsChanged is a physical boundary for stream chords,
        // including a second left/right modifier whose aggregate flags have no
        // delta. Settle and close before consulting librime, whose availability
        // must not decide whether a later FlyYao half can recombine with raw.
        if StreamInputModifierBoundaryRules.closesPairing(
            eventType: event.type
        ), streamInputModeSelected {
            guard let lease = streamInputLease(client: client) else {
                StreamInputWorkspace.shared.authorityRejected()
                lastModifiers = modifiers
                return false
            }
            _ = StreamInputWorkspace.shared.settlePendingChord(
                focusToken: lease.token,
                closesPairingAfterSettlement: true
            )
            guard streamInputLease(client: client) === lease else {
                StreamInputWorkspace.shared.authorityRejected()
                lastModifiers = modifiers
                return false
            }
        }

        guard !changes.isEmpty else {
            lastModifiers = modifiers
            return false
        }

        guard rimeEngine.start(), ensureSessionReady() else {
            lastModifiers = event.modifierFlags
            return false
        }

        let rimeMask = RimeKey.modifierMask(from: modifiers)
        var handled = false

        // Do not put librime's ascii_composer into its pending-Shift state on
        // physical keyDown. Its release path can run `commit_code` before a
        // frontend has a chance to restore ascii_mode, which would destroy an
        // existing composition for Shift+Option and other controller-owned
        // paths. Replay a matched press/release only after we have proved this
        // was a short standalone tap; modified, long and focus-cancelled
        // gestures never reach ascii_composer at all.
        let physicalShiftKey = changes.contains(.shift)
            ? ShiftModifierEventRules.rimeKeycode(
                forHardwareKeyCode: event.keyCode
            )
            : nil
        if changes.contains(.shift), physicalShiftKey == nil {
            // An aggregate Shift delta attached to another modifier cannot
            // authenticate a tap. If a real gesture was already in flight,
            // fail closed so a later physical release cannot toggle ASCII.
            shiftGesture?.noteModifierUse()
            IMELog.write(
                "aggregate Shift delta ignored for non-Shift keyCode=\(event.keyCode)"
            )
        }
        if let shiftKey = physicalShiftKey {
            let pressed = modifiers.contains(.shift)
            if pressed {
                // Preserve processRimeKey's non-chord boundary even though the
                // mode-switch event itself is deferred until release.
                chord.flush()
                mutualPairingState.reset()
                let otherModifiers = modifiers.intersection([
                    .control, .option, .command, .function,
                ])
                shiftGesture = ShiftModifierGesture(
                    beganAt: event.timestamp,
                    rimeKeycode: shiftKey,
                    session: session,
                    schemaID: currentSchemaId,
                    beganWithOtherModifier: !otherModifiers.isEmpty
                )
            } else {
                var releaseGesture = shiftGesture
                shiftGesture = nil
                let suppressedByGlobalHotKey =
                    Self.globalHotKeyShiftTombstone.suppressesRelease(
                        beganAt: releaseGesture?.beganAt,
                        releasedAt: event.timestamp
                    )
                if suppressedByGlobalHotKey {
                    releaseGesture?.noteModifierUse()
                }
                if let releaseGesture,
                   case let .replayStandaloneTap(rimeKeycode) = releaseGesture.releaseDecision(
                    at: event.timestamp,
                    currentSession: session,
                    currentSchemaID: currentSchemaId
                ) {
                    let lock = rimeMask & RimeKey.lockMask
                    handled = processRimeKey(
                        rimeKeycode,
                        mask: RimeKey.shiftMask | lock,
                        client: client
                    ) || handled
                    handled = processRimeKey(
                        rimeKeycode,
                        mask: rimeMask | RimeKey.releaseMask,
                        client: client
                    ) || handled
                    IMELog.write("standalone Shift tap replayed to Rime key=\(rimeKeycode)")
                } else if suppressedByGlobalHotKey {
                    IMELog.write(
                        "standalone Shift tap discarded by global hotkey tombstone "
                            + "route=\(Self.globalHotKeyShiftTombstone.route)"
                    )
                }
            }
        }
        if changes.contains(.shift) {
            // Keep the aggregate baseline synchronized even when a different
            // modifier's flagsChanged callback exposed the Shift delta. The
            // physical Shift callback, if any, is the only event allowed to
            // authenticate a standalone language-toggle gesture.
            changes.remove(.shift)
            if changes.isEmpty {
                lastModifiers = modifiers
                return handled
            }
        }

        if changes.contains(.option) {
            if modifiers.contains(.option) {
                if beginCandidateOptionSelection(client: client) {
                    lastModifiers = modifiers
                    return true
                }
            } else if candidateOptionSelecting {
                finishCandidateOptionSelection(client: client, source: "option release")
                lastModifiers = modifiers
                return true
            }
        }
        if candidateOptionSelecting {
            lastModifiers = modifiers
            return true
        }

        var keyCode = event.keyCode
        if RimeKey.fromVirtualKeyCode(keyCode) == nil,
           let inferred = RimeKey.changedModifierKeyCode(from: changes) {
            keyCode = inferred
        }
        guard let keycode = RimeKey.fromVirtualKeyCode(keyCode) else {
            lastModifiers = modifiers
            return handled
        }

        // Preserve the proven press/release stream, with Caps sent as
        // mask^lockMask (good_old_caps_lock depends on this exact ordering).
        if changes.contains(.capsLock) {
            handled = processRimeKey(keycode, mask: rimeMask ^ RimeKey.lockMask, client: client) || handled
        } else {
            let watched: [NSEvent.ModifierFlags] = [.control, .option, .command]
            for flag in watched where changes.contains(flag) {
                let pressed = modifiers.contains(flag)
                let mask = pressed ? rimeMask : (rimeMask | RimeKey.releaseMask)
                handled = processRimeKey(keycode, mask: mask, client: client) || handled
            }
        }
        lastModifiers = modifiers
        return handled
    }

    /// Engine-down path: printable keys and Return still insert (never drop a
    /// printable character); non-textual keys pass to the app.
    private func rawFallback(_ event: NSEvent,
                             client: IMKTextInput,
                             expectedLease: FocusLease?) -> Bool {
        StatusMenu.shared.setHealthy(false)
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .control]).isEmpty {
            return insertDirectText("\n",
                                    client: client,
                                    source: "engine fallback",
                                    expectedLease: expectedLease)
        }
        if let chars = event.characters, !chars.isEmpty,
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            return insertDirectText(chars,
                                    client: client,
                                    source: "engine fallback",
                                    expectedLease: expectedLease)
        }
        return false
    }

    /// Codex currently inserts U+001E/U+001F when their Control-key events are
    /// returned unhandled. In buffer mode those bytes are never buffer content
    /// and must not leak into the editor. Keep this host-specific so terminal
    /// Control+^ / Control+_ semantics remain untouched.
    private func consumeLeakedCodexBufferControlText(
        _ event: NSEvent,
        client: IMKTextInput,
        path: String
    ) -> Bool {
        guard let characters = event.characters,
              !characters.isEmpty else { return false }
        let scalars = characters.unicodeScalars.map(\.value)
        guard Self.shouldConsumeCodexBufferControlText(
            scalars,
            bundleId: cachedBundleID(for: client),
            bufferActive: shouldUseBufferCommands(client: client)
        ) else { return false }

        let renderedScalars = scalars
            .map { String(format: "U+%04X", $0) }
            .joined(separator: ",")
        let ignoringModifiers = event.charactersIgnoringModifiers?.unicodeScalars
            .map { String(format: "U+%04X", $0.value) }
            .joined(separator: ",") ?? ""
        IMELog.write("buffer swallowed Codex control text path=\(path) keyCode=\(event.keyCode) scalars=\(renderedScalars) ignoring=\(ignoringModifiers) flags=\(event.modifierFlags.rawValue)")
        return true
    }

    static func shouldConsumeCodexBufferControlText(
        _ scalars: [UInt32],
        bundleId: String,
        bufferActive: Bool
    ) -> Bool {
        bufferActive
            && bundleId == "com.openai.codex"
            && !scalars.isEmpty
            && scalars.allSatisfy { $0 == 0x1e || $0 == 0x1f }
    }

    // MARK: Chord replay

    private func finishDiscardedChord(client: (any IMKTextInput)?) {
        pendingFlyChordBase = nil
        guard chordClientRoutingGate.allowsClientRouting,
              let client,
              let focusToken,
              let target = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              target.controller === self,
              target.clientIdentity == ObjectIdentifier(client as AnyObject) else { return }
        IMELog.write("chord batch discarded without replayable keys")
        updateUI(client: client)
    }

    private func replayChordReleases(_ keys: [(keycode: Int32, mask: Int32)],
                                     client: (any IMKTextInput)?) {
        let base = pendingFlyChordBase
        pendingFlyChordBase = nil
        guard session != 0 else { return }
        // Validate the focus epoch before touching the session.  A delayed
        // timer from a displaced field must not first mutate Rime and only
        // discover the stale destination when it is ready to drain a commit.
        guard let base,
              base.profile == ChordKeymapStore.shared.activeProfile,
              focusToken == base.owner,
              client.map({ ObjectIdentifier($0 as AnyObject) == base.clientIdentity }) != false else {
            mutualPairingState.reset()
            IMELog.write("FlyYao replay discarded before session mutation; focus epoch changed")
            return
        }
        let initialTarget: FocusLease?
        if chordClientRoutingGate.allowsClientRouting {
            guard client != nil,
                  let target = InputFocusCoordinator.shared.interactionTarget(
                expected: base.owner
            ),
            target.controller === self,
            target.clientIdentity == base.clientIdentity else {
                mutualPairingState.reset()
                IMELog.write("FlyYao replay discarded before session mutation; target changed")
                return
            }
            initialTarget = target
        } else {
            // A synchronous displaced/protected-focus cleanup intentionally
            // replaces the global owner before asking the old controller to
            // settle. The routing gate guarantees this replay can touch only
            // the old private Rime session.
            initialTarget = nil
        }
        let profile = base.profile
        guard let shape = FlyChordBatchShape(keys: keys, layout: profile) else {
            IMELog.write("FlyYao batch rejected unknown keyboard-half shape")
            return
        }

        let policy = base.policy
        let contextBefore = base.context
        var engineKeys = keys
        var engineBaseInput = contextBefore.input
        var replayedLeft: FlyChordMutualPairingState.SettledLeft?
        var boundaryPlan = ChordKeymapBoundaryRules.plan(for: contextBefore, profile: profile)

        func replaySettledLeft(_ left: FlyChordMutualPairingState.SettledLeft) -> Bool {
            let insertsBoundary = ChordKeymapBoundaryRules.shouldInsert(
                keys: left.keys.map(\.keycode), profile: profile
            )
            if insertsBoundary,
               left.boundaryPlan.before,
               !rimeEngine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                      mask: 0,
                                      session: session) {
                return false
            }
            var accepted: [FlyChordKeyEvent] = []
            for key in left.keys where rimeEngine.processKey(
                key.keycode,
                mask: key.mask,
                session: session
            ) {
                accepted.append(key)
            }
            var released = 0
            for key in accepted where rimeEngine.processKey(
                key.keycode,
                mask: key.mask | RimeKey.releaseMask,
                session: session
            ) {
                released += 1
            }
            let trailingBoundaryAccepted = !insertsBoundary
                || !left.boundaryPlan.after
                || rimeEngine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                         mask: 0,
                                         session: session)
            return accepted.count == left.keys.count
                && released == accepted.count
                && trailingBoundaryAccepted
        }

        if let previousLeft = mutualPairingState.takeComplement(
            before: shape,
            currentKeyCount: keys.count,
            policy: policy,
            currentContext: contextBefore
        ), ChordKeymapBoundaryRules.mayCombine(
            keys: previousLeft.keys.map(\.keycode) + keys.map(\.keycode), profile: profile
        ) {
            var rollbackHandled = true
            for _ in 0..<previousLeft.insertedScalarCount {
                if !rimeEngine.processKey(RimeKey.backspace,
                                          mask: 0,
                                          session: session) {
                    rollbackHandled = false
                }
            }
            if rollbackHandled,
               rimeEngine.getContext(session: session).input == previousLeft.baseInput {
                engineKeys = previousLeft.keys.map {
                    (keycode: $0.keycode, mask: $0.mask)
                } + keys
                engineBaseInput = previousLeft.baseInput
                replayedLeft = previousLeft
                boundaryPlan = previousLeft.boundaryPlan
            } else {
                // The saved input snapshot makes this path unreachable for the
                // product schema. If a custom processor rejects BackSpace,
                // restore the left batch whenever we reached its known base;
                // never clear unrelated preedit.
                if rimeEngine.getContext(session: session).input == previousLeft.baseInput {
                    if replaySettledLeft(previousLeft) {
                        mutualPairingState.recordSettledLeft(
                            keys: previousLeft.keys,
                            baseInput: previousLeft.baseInput,
                            settledContext: rimeEngine.getContext(session: session),
                            boundaryPlan: previousLeft.boundaryPlan,
                            policy: .independentHalves,
                            shape: .leftOnly
                        )
                    }
                }
                IMELog.write("FlyYao could not recombine settled left half")
                if chordClientRoutingGate.allowsClientRouting, let client {
                    updateUI(client: client)
                }
                return
            }
        }

        let insertsBoundary = ChordKeymapBoundaryRules.shouldInsert(
            keys: engineKeys.map(\.keycode), profile: profile
        )
        let leadingBoundaryAccepted = !insertsBoundary
            || !boundaryPlan.before
            || rimeEngine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                     mask: 0,
                                     session: session)
        var acceptedKeys: [(keycode: Int32, mask: Int32)] = []
        for key in engineKeys where rimeEngine.processKey(
            key.keycode,
            mask: key.mask,
            session: session
        ) {
            acceptedKeys.append(key)
        }

        var handledCount = 0
        for key in acceptedKeys {
            if rimeEngine.processKey(key.keycode,
                                     mask: key.mask | RimeKey.releaseMask,
                                     session: session) {
                handledCount += 1
            }
        }
        let trailingBoundaryAccepted = !insertsBoundary
            || !boundaryPlan.after
            || rimeEngine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                     mask: 0,
                                     session: session)
        let batchAccepted = leadingBoundaryAccepted
            && trailingBoundaryAccepted
            && acceptedKeys.count == engineKeys.count
            && handledCount == acceptedKeys.count
        if batchAccepted {
            let settledContext = rimeEngine.getContext(session: session)
            mutualPairingState.recordSettledLeft(
                keys: keys.map { FlyChordKeyEvent(keycode: $0.keycode, mask: $0.mask) },
                baseInput: contextBefore.input,
                settledContext: settledContext,
                boundaryPlan: boundaryPlan,
                policy: ChordKeymapBoundaryRules.mayAwaitComplement(
                    keys: engineKeys.map(\.keycode), profile: profile
                ) ? policy : .sameBatchOnly,
                shape: shape
            )
        } else {
            // The product schema accepts every FlyYao alphabet press. If a
            // custom/broken schema violates that contract, remove only the
            // insertion made by this failed batch and preserve prior preedit.
            let afterRelease = rimeEngine.getContext(session: session)
            if let insertedCount = FlyChordInputRollback.insertedScalarCount(
                before: engineBaseInput,
                after: afterRelease.input
            ) {
                for _ in 0..<insertedCount {
                    _ = rimeEngine.processKey(RimeKey.backspace,
                                              mask: 0,
                                              session: session)
                }
            }
            if let replayedLeft,
               rimeEngine.getContext(session: session).input == replayedLeft.baseInput {
                if replaySettledLeft(replayedLeft) {
                    let restoredContext = rimeEngine.getContext(session: session)
                    mutualPairingState.recordSettledLeft(
                        keys: replayedLeft.keys,
                        baseInput: replayedLeft.baseInput,
                        settledContext: restoredContext,
                        boundaryPlan: replayedLeft.boundaryPlan,
                        policy: .independentHalves,
                        shape: .leftOnly
                    )
                }
            }
            IMELog.write("FlyYao batch rejected accepted=\(acceptedKeys.count) total=\(engineKeys.count)")
        }
        if !chordClientRoutingGate.allowsClientRouting {
            IMELog.write("chord replay isolated from reused client proxy keys=\(keys.count) handled=\(handledCount)")
            return
        }
        guard focusToken == base.owner,
              let client,
              let initialTarget,
              let target = InputFocusCoordinator.shared.interactionTarget(expected: base.owner),
              target.controller === self,
              target === initialTarget,
              target.clientIdentity == base.clientIdentity else {
            IMELog.write("chord replay blocked; current client no longer matches pending chord")
            if let lease = currentLease() {
                suspendUntrustedFocusLease(lease, reason: "asynchronous chord target validation")
                abandonCompositionWithoutClient(lease,
                                                reason: "asynchronous chord target changed")
            } else {
                rimeEngine.clearComposition(session: session)
                composition.markCleared()
            }
            return
        }
        if batchAccepted {
            publishTelemetryChord(keys: keys,
                                  duration: chord.duration,
                                  handledReleaseCount: handledCount,
                                  client: client)
        }
        // Match Squirrel's batch boundary: all synthesized releases must reach
        // chord_composer before the resulting commit is observed by the buffer.
        drainCommit(client, externalTarget: target.isExternalTarget)
        updateUI(client: client)
        if batchAccepted, keys.count > 1 {
            IMELog.write("chord replay keys=\(keys.count) handled=\(handledCount) duration=\(chord.duration)")
        }
    }

    // MARK: Candidate selection (mouse; routed here via `active` from main.swift)

    private func handleCandidateKey(_ keycode: Int32, client: IMKTextInput) -> Bool {
        guard candidateWindow.hasInteractableCandidates else {
            if candidateOptionSelecting
                || candidateWindow.isSingleCharacterSelectionActive {
                resetCandidateOptionGesture()
            }
            return false
        }
        if candidateOptionSelecting || candidateWindow.isSingleCharacterSelectionActive {
            return handleCandidateOptionSelectionKey(keycode, client: client)
        }
        let isLocalCandidateAction = CandidateKeyboardRoutingRules.ownsLocally(
            keycode: keycode,
            isExpanded: candidateWindow.isExpanded
        )
        if isLocalCandidateAction {
            if chord.hasPending {
                IMELog.write("candidate key \(keycode) resolving pending chord before local action")
                chord.flush()
                guard candidateWindow.hasInteractableCandidates else { return false }
            }
            mutualPairingState.reset()
        }
        switch keycode {
        case RimeKey.left:
            return candidateWindow.moveSelection(delta: -1)
        case RimeKey.right:
            return candidateWindow.moveSelection(delta: 1)
        case RimeKey.down:
            if candidateWindow.isExpanded {
                extendExpandedPagesIfNeeded()
                return candidateWindow.moveExpandedSelection(rowDelta: 1)
            }
            let pages = previewCandidatePages(maxCount: Self.expandedPageBatch)
            if pages.count > 1 {
                IMELog.write("candidate matrix expanded rows=\(pages.count)")
                return candidateWindow.expand(with: pages)
            }
            return pageCandidates(delta: 1, client: client)
        case RimeKey.up:
            if candidateWindow.isExpanded {
                return candidateWindow.moveExpandedSelection(rowDelta: -1)
            }
            return pageCandidates(delta: -1, client: client)
        case RimeKey.return:
            return commitRawInput(client: client)
        case RimeKey.space:
            guard let selection = candidateWindow.selectedCandidateSelection else { return false }
            selectCandidate(selection)
            return true
        case 0x31...0x39 where candidateWindow.isExpanded:
            let visibleIndex = Int(keycode - 0x31)
            guard let selection = candidateWindow.expandedSelection(atVisibleIndex: visibleIndex) else {
                IMELog.write("candidate matrix digit \(visibleIndex + 1) ignored; candidate is hidden")
                return true
            }
            selectCandidate(selection)
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func pageCandidates(delta: Int, client: IMKTextInput) -> Bool {
        guard candidateWindow.hasInteractableCandidates else { return false }
        if candidateWindow.movePage(delta: delta) { return true }
        let keycode = delta < 0 ? RimeKey.pageUp : RimeKey.pageDown
        _ = processRimeKey(keycode, mask: 0, client: client)
        return true
    }

    @discardableResult
    func selectCandidate(_ selection: CandidateSelection) -> Bool {
        guard let focusToken else {
            IMELog.write("candidate select failed stage=no-focus-token")
            return false
        }
        return selectCandidate(selection, owner: focusToken)
    }

    @discardableResult
    func selectCandidate(_ selection: CandidateSelection, owner: FocusToken) -> Bool {
        guard session != 0,
              focusToken == owner,
              let lease = InputFocusCoordinator.shared.interactionTarget(expected: owner),
              lease.controller === self,
              let client = lease.client else {
            IMELog.write("candidate select failed stage=session-or-owner pageOffset=\(selection.pageOffset) index=\(selection.index)")
            return false
        }
        if chord.hasPending {
            chord.flush()
        }
        mutualPairingState.reset()
        let moved = moveRimeCandidatePage(delta: selection.pageOffset)
        guard moved == selection.pageOffset else {
            _ = moveRimeCandidatePage(delta: -moved)
            updateUI(client: client)
            IMELog.write("candidate select failed stage=page-move requested=\(selection.pageOffset) moved=\(moved)")
            return false
        }
        guard rimeEngine.selectCandidate(onPage: selection.index, session: session) else {
            _ = moveRimeCandidatePage(delta: -moved)
            updateUI(client: client)
            IMELog.write("candidate select failed stage=select pageOffset=\(selection.pageOffset) index=\(selection.index)")
            return false
        }
        if drainCommit(client) == nil {
            IMELog.write("candidate selected without commit pageOffset=\(selection.pageOffset) index=\(selection.index)")
        }
        updateUI(client: client)
        return true
    }

    /// The matrix shows three rows but must reach every candidate, so pull the
    /// next batch of Rime pages once the selection lands on the fetched tail.
    /// Pages are re-read from the anchor (cheap: the session never leaves page
    /// 0), which keeps `expandedPages` index == anchor-relative page offset.
    private func extendExpandedPagesIfNeeded() {
        guard candidateWindow.isExpanded,
              !candidateWindow.expandedTailIsLastPage else { return }
        let loaded = candidateWindow.expandedPageCount
        guard candidateWindow.expandedSelectionPage >= loaded - 1 else { return }
        let pages = previewCandidatePages(maxCount: loaded + Self.expandedPageBatch)
        candidateWindow.extendExpandedPages(with: pages)
    }

    private func previewCandidatePages(maxCount: Int) -> [RimeContextModel] {
        guard session != 0, maxCount > 0 else { return [] }
        let current = rimeEngine.getContext(session: session)
        guard !current.candidates.isEmpty else { return [] }

        var pages = [current]
        var moved = 0
        var last = current
        while pages.count < maxCount, !last.isLastPage {
            let before = rimeEngine.getContext(session: session)
            guard rimeEngine.processKey(RimeKey.pageDown, mask: 0, session: session) else { break }
            let next = rimeEngine.getContext(session: session)
            guard !sameCandidatePage(before, next) else { break }
            moved += 1
            guard !next.candidates.isEmpty else { break }
            pages.append(next)
            last = next
        }
        if moved > 0 {
            _ = moveRimeCandidatePage(delta: -moved)
        }
        return pages
    }

    @discardableResult
    private func moveRimeCandidatePage(delta: Int) -> Int {
        guard session != 0, delta != 0 else { return 0 }
        let direction = delta > 0 ? 1 : -1
        let keycode = direction > 0 ? RimeKey.pageDown : RimeKey.pageUp
        var moved = 0
        for _ in 0..<abs(delta) {
            let before = rimeEngine.getContext(session: session)
            guard rimeEngine.processKey(keycode, mask: 0, session: session) else { break }
            let after = rimeEngine.getContext(session: session)
            guard !sameCandidatePage(before, after) else { break }
            moved += direction
        }
        return moved
    }

    private func sameCandidatePage(_ lhs: RimeContextModel, _ rhs: RimeContextModel) -> Bool {
        lhs.pageNo == rhs.pageNo && candidatePageSignature(lhs) == candidatePageSignature(rhs)
    }

    private func candidatePageSignature(_ ctx: RimeContextModel) -> String {
        ctx.candidates.map { "\($0.label):\($0.text):\($0.comment)" }.joined(separator: "|")
    }

    private func commitRawInput(client: IMKTextInput) -> Bool {
        guard session != 0 else { return false }

        var ctx = rimeEngine.getContext(session: session)
        var raw = ctx.input
        if raw.isEmpty, candidateWindow.isVisible {
            raw = candidateWindow.rawInputForCommit
        }
        if chord.hasPending {
            chord.flush()
            ctx = rimeEngine.getContext(session: session)
            raw = ctx.input
            if raw.isEmpty, candidateWindow.isVisible {
                raw = candidateWindow.rawInputForCommit
            }
        }
        mutualPairingState.reset()
        guard !raw.isEmpty else { return false }

        rimeEngine.clearComposition(session: session)
        let capturesInClipboardSearch = shouldCaptureClipboardSearchCommit(from: client)
        let capturesInBuffer = shouldCaptureCommit(from: client)
        if capturesInClipboardSearch {
            guard appendClipboardSearchCommit(raw, client: client) else {
                IMELog.write("raw clipboard search commit rejected")
                return true
            }
        } else if capturesInBuffer {
            if let focusToken {
                BufferWindowController.shared.clearInlineComposition(owner: focusToken)
                candidateWindow.hide(owner: focusToken)
            }
            BufferModel.shared.append(raw)
            clearCompositionPresentation(client: client)
            publishAuthoredCommitTelemetry(characterCount: raw.count,
                                           source: .buffer,
                                           client: client)
            IMELog.write("raw input \(IMELog.redact(raw)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(raw, client: client)
            if inserted {
                publishAuthoredCommitTelemetry(characterCount: raw.count,
                                               source: .direct,
                                               client: client)
            }
            IMELog.write("raw input \(IMELog.redact(raw)) inserted=\(inserted) target=\(cachedBundleID(for: client))")
        }
        publishCompositionActive(false)
        updateUI(client: client)
        return true
    }

    // MARK: Commit drain + UI

    /// The single routing point (§5.9): buffer-OFF → straight to the field;
    /// buffer-ON → the commit becomes a staged block and the inline preedit is
    /// cleared from the field (nothing lands until the buffer flushes).
    @discardableResult
    private func drainCommit(_ client: IMKTextInput,
                             externalTarget: Bool? = nil) -> String? {
        guard let commit = rimeEngine.takeCommit(session: session) else { return nil }
        let capturesInClipboardSearch = shouldCaptureClipboardSearchCommit(from: client)
        let capturesInBuffer = shouldCaptureCommit(from: client,
                                                   externalTarget: externalTarget)
        if capturesInClipboardSearch {
            if !appendClipboardSearchCommit(commit, client: client) {
                IMELog.write("clipboard search commit rejected after Rime drain")
                clearCompositionPresentation(client: client)
            }
        } else if capturesInBuffer {
            if let focusToken {
                BufferWindowController.shared.clearInlineComposition(owner: focusToken)
                candidateWindow.hide(owner: focusToken)
            }
            // Consciousness-stream input is an ordinary input surface, so what
            // Rime commits is what the user wrote: it belongs in that raw line
            // rather than as a finished buffer block.
            if streamInputModeSelected, let focusToken,
               StreamInputWorkspace.shared.insertTypedText(
                 commit,
                 focusToken: focusToken
               ) {
                clearCompositionPresentation(client: client)
                publishAuthoredCommitTelemetry(characterCount: commit.count,
                                               source: .buffer,
                                               client: client)
                IMELog.write(
                    "commit \(IMELog.redact(commit)) -> stream raw"
                )
                return nil
            }
            BufferModel.shared.append(commit)
            clearCompositionPresentation(client: client)
            publishAuthoredCommitTelemetry(characterCount: commit.count,
                                           source: .buffer,
                                           client: client)
            IMELog.write("commit \(IMELog.redact(commit)) -> buffer (\(BufferModel.shared.blocks.count) blocks)")
        } else {
            let inserted = deliverDirectText(commit,
                                             client: client,
                                             externalTarget: externalTarget)
            if inserted {
                publishAuthoredCommitTelemetry(characterCount: commit.count,
                                               source: .direct,
                                               client: client)
            }
            IMELog.write("commit \(IMELog.redact(commit)) inserted=\(inserted) target=\(cachedBundleID(for: client))")
        }
        return commit
    }

    private func telemetryAllowsObservation(client: IMKTextInput) -> Bool {
        guard !IsSecureEventInputEnabled(),
              let focusToken,
              let target = InputFocusCoordinator.shared.liveTarget(expected: focusToken),
              target.controller === self,
              target.clientIdentity == ObjectIdentifier(client as AnyObject) else {
            return false
        }
        return true
    }

    private func practiceAllowsObservation(client: IMKTextInput) -> Bool {
        guard TypingPracticeTelemetry.isPracticeInputFocused,
              !IsSecureEventInputEnabled(), let focusToken,
              let target = InputFocusCoordinator.shared.interactionTarget(expected: focusToken),
              !target.isExternalTarget, target.controller === self,
              target.clientIdentity == ObjectIdentifier(client as AnyObject) else { return false }
        return true
    }

    private func publishTelemetryKey(_ event: NSEvent, client: IMKTextInput) {
        if practiceAllowsObservation(client: client) {
            TypingPracticeTelemetry.shared.noteIMEKey(
                event, isComposing: composition.composing || chord.hasPending,
                owner: ObjectIdentifier(client as AnyObject)
            )
            return
        }
        guard telemetryAllowsObservation(client: client),
              let keyID = KeyboardLayout.keyId(forKeyCode: event.keyCode) else { return }
        InputTelemetryBus.shared.publish(.key(.init(
            keyID: keyID,
            timestamp: Date().timeIntervalSince1970,
            isRepeat: event.isARepeat,
            modifierFlags: event.modifierFlags.rawValue,
            schemaID: currentSchemaId
        )))
    }

    private func publishTelemetryModifierPress(_ event: NSEvent, client: IMKTextInput) {
        guard telemetryAllowsObservation(client: client),
              KeyboardLayout.isModifierKey(event.keyCode),
              KeyboardLayout.isModifierPressed(keyCode: event.keyCode,
                                               flags: event.modifierFlags),
              let keyID = KeyboardLayout.keyId(forKeyCode: event.keyCode)
        else { return }
        InputTelemetryBus.shared.publish(.key(.init(
            keyID: keyID,
            timestamp: Date().timeIntervalSince1970,
            isRepeat: false,
            modifierFlags: event.modifierFlags.rawValue,
            schemaID: currentSchemaId
        )))
    }

    private func publishTelemetryChord(
        keys: [(keycode: Int32, mask: Int32)],
        duration: TimeInterval,
        handledReleaseCount: Int,
        client: IMKTextInput
    ) {
        if practiceAllowsObservation(client: client) {
            TypingPracticeTelemetry.shared.noteIMEChord(
                schemaID: currentSchemaId, owner: ObjectIdentifier(client as AnyObject)
            )
            return
        }
        guard telemetryAllowsObservation(client: client) else { return }
        InputTelemetryBus.shared.publish(.chord(.init(
            rimeKeyCodes: keys.map(\.keycode),
            timestamp: Date().timeIntervalSince1970,
            duration: duration,
            handledReleaseCount: handledReleaseCount,
            schemaID: currentSchemaId
        )))
    }

    private func publishAuthoredCommitTelemetry(
        characterCount: Int,
        source: InputTelemetryEvent.CommitSource,
        client: IMKTextInput
    ) {
        guard characterCount > 0,
              telemetryAllowsObservation(client: client) else { return }
        InputTelemetryBus.shared.publish(.commit(.init(
            characterCount: characterCount,
            timestamp: Date().timeIntervalSince1970,
            source: source,
            schemaID: currentSchemaId
        )))
    }

    /// Token-aware destination used only by BufferDeliveryCoordinator.
    func deliverBufferedBlock(_ text: String, origin _: Origin, target: FocusLease) -> Bool {
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              target.controller === self,
              focusToken == target.token,
              InputFocusCoordinator.shared.liveTarget(
                expected: target.token,
                forceOverlayVisibilityRefresh: true
              ) === target,
              let client = target.client,
              ObjectIdentifier(client as AnyObject) == target.clientIdentity else {
            IMELog.write("buffer send blocked; stale target token=\(target.token)")
            return false
        }
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              Delivery.insert(text, into: client) else {
            return false
        }
        composition.commitDidInsert()
        return true
    }

    static func refreshActiveUI() {
        if RimeInputSourceAuthority.currentSourceIsOwn(),
           let owner = InputFocusCoordinator.shared.interactionTarget(),
           let controller = owner.controller,
           let client = owner.client,
           InputFocusCoordinator.shared.isCurrent(owner.token, controller: controller) {
            controller.updateUI(client: client)
        } else {
            BufferWindowController.shared.refresh()
        }
    }

    /// Retires session-local FlyYao state at the extension lifecycle boundary.
    /// Disabling is synchronous and fail-closed: the trusted active owner first
    /// settles its text through the normal delivery path, while inactive or
    /// suspended sessions discard their private composition without touching a
    /// possibly moved IMK proxy. The already-persisted ordinary fallback is
    /// then selected before another physical key can arrive.
    private func chordExtensionDidChange(_ notification: Notification) {
        dispatchPrecondition(condition: .onQueue(.main))
        chord.duration = ChordExtensionStore.shared.duration

        let previousEnabled = notification.userInfo?[
            ChordExtensionNotificationKey.previousEnabled
        ] as? Bool
        let currentEnabled = notification.userInfo?[
            ChordExtensionNotificationKey.currentEnabled
        ] as? Bool ?? ChordExtensionStore.shared.isEnabled

        guard !currentEnabled else {
            // A mode change may not reinterpret an already-started batch. Its
            // frozen base policy settles first; future batches read the new
            // extension mode.
            if chord.hasPending { chord.flush() }
            pendingFlyChordBase = nil
            mutualPairingState.reset()
            return
        }

        // Editing the remembered mode while the extension is already off has
        // no live route to retire. In particular, the compatibility API may
        // set a mode immediately before explicitly enabling my_combo; that
        // must not commit or clear an unrelated ordinary composition.
        guard previousEnabled != false else { return }

        let sessionSchemaID = session == 0
            ? currentSchemaId
            : rimeEngine.getStatus(session: session).schemaId
        let mustRetireRimeChordState = chord.hasPending
            || pendingFlyChordBase != nil
            || currentSchemaId == ChordExtensionStore.schemaID
            || sessionSchemaID == ChordExtensionStore.schemaID
        guard mustRetireRimeChordState else {
            mutualPairingState.reset()
            IMELog.write(
                "chord_extension disabled; ordinary Rime composition preserved"
            )
            return
        }

        if RimeBufferController.active === self,
           currentLease() != nil {
            applyStoredInputConfigurationToLiveSession()
            IMELog.write("chord_extension disabled active_session fallback=\(currentSchemaId)")
            return
        }

        chordClientRoutingGate.withIsolatedClientRouting {
            chord.flush()
        }
        pendingFlyChordBase = nil
        mutualPairingState.reset()
        if session != 0 {
            rimeEngine.clearComposition(session: session)
            composition.markCleared()
            let fallback = InputConfigurationStore.shared.runtimeProfile.schemaID
            let available = rimeEngine.schemaList().map(\.id)
            if (available.isEmpty || available.contains(fallback)),
               rimeEngine.getStatus(session: session).schemaId != fallback {
                _ = rimeEngine.selectSchema(fallback, session: session)
            }
            refreshSchema()
        }
        if let focusToken {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            candidateWindow.hide(owner: focusToken)
        }
        IMELog.write("chord_extension disabled inactive_session fallback=\(currentSchemaId)")
    }

    /// Applies the atomic product-level encoding/keying selection to the one
    /// controller that currently owns a trusted text-input lease. Inactive
    /// controllers read the same preference when they are next activated.
    static func applyStoredInputConfiguration() {
        guard let controller = active else { return }
        controller.applyStoredInputConfigurationToLiveSession()
    }

    private func applyStoredInputConfigurationToLiveSession() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let lease = currentLease(), lease.compositionActive {
            forceCommit()
        } else {
            chord.flush()
        }
        mutualPairingState.reset()
        guard ensureSessionReady() else { return }
        let schemaID = InputConfigurationStore.shared.runtimeProfile.schemaID
        let available = rimeEngine.schemaList().map(\.id)
        guard available.isEmpty || available.contains(schemaID) else {
            IMELog.write("input configuration schema not deployed id=\(schemaID)")
            return
        }
        if rimeEngine.getStatus(session: session).schemaId != schemaID {
            _ = rimeEngine.selectSchema(schemaID, session: session)
        }
        refreshSchema()
        if let lease = currentLease(), let client = lease.client {
            updateUI(client: client)
        }
    }

    private func updateUI(client: IMKTextInput) {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            chordClientRoutingGate.withIsolatedClientRouting {
                chord.flush()
            }
            mutualPairingState.reset()
            if session != 0 {
                rimeEngine.clearComposition(session: session)
            }
            if let focusToken {
                BufferWindowController.shared.clearInlineComposition(
                    owner: focusToken
                )
                candidateWindow.hide(owner: focusToken)
            } else {
                BufferWindowController.shared.clearInlineComposition()
            }
            composition.markCleared()
            IMELog.write("updateUI ignored; RIMES authority retired")
            return
        }
        guard let focusToken else {
            BufferWindowController.shared.clearInlineComposition()
            return
        }
        guard let lease = InputFocusCoordinator.shared.interactionTarget(
                expected: focusToken
              ),
              lease.controller === self,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity else {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            IMELog.write("updateUI ignored; client no longer owns token=\(focusToken)")
            return
        }

        let bufferControlsActive = shouldUseBufferCommands(client: client)
        let clipboardSearchActive = shouldCaptureClipboardSearchCommit(from: client)
        let logicalControlsActive = bufferControlsActive || clipboardSearchActive
        let capturesRimeCommits = shouldCaptureCommit(from: client)
            || clipboardSearchActive
        let secureInput = IsSecureEventInputEnabled()

        // Host isolation cannot depend on a healthy Rime session. In fallback
        // mode there is no semantic composition, but the exact external buffer
        // lease still needs its idle U+200B guard before Return is pressed.
        guard session != 0, rimeEngine.isHealthy else {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            let presentation = HostMarkedTextPresentationRules.presentation(
                bufferControlsActive: logicalControlsActive,
                capturesRimeCommits: capturesRimeCommits,
                rimeComposing: false,
                secureInput: secureInput
            )
            let guardActive: Bool
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                candidateWindow.hide(owner: focusToken)
                IMELog.write("updateUI fallback presentation blocked before host write token=\(focusToken)")
                return
            }
            switch presentation {
            case .none, .normalPreedit:
                clearCompositionPresentation(client: client)
                guardActive = false
            case let .bufferGuard(rimeComposing):
                composition.updateBufferGuard(rimeComposing: rimeComposing,
                                              client: client)
                guardActive = true
            }
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                candidateWindow.hide(owner: focusToken)
                IMELog.write("updateUI fallback presentation abandoned after focus change token=\(focusToken)")
                return
            }
            publishCompositionActive(false, markedRangeReliable: !guardActive)
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                candidateWindow.hide(owner: focusToken)
                IMELog.write("updateUI fallback ownership changed while publishing token=\(focusToken)")
                return
            }
            if clipboardSearchActive {
                ClipboardHistoryWindowController.shared.clearSearchComposition()
            }
            candidateWindow.hide(owner: focusToken)
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let status = rimeEngine.getStatus(session: session)
        let ctx = rimeEngine.getContext(session: session)
        watchdog("getContext", since: t0)

        // A schema switch made INSIDE Rime (F4 switcher) must feel as global
        // as a menu switch: persist it so other controllers adopt it on focus.
        let staleChordSchema = ChordExtensionStore.isChordSchema(status.schemaId)
            && (status.schemaId != ChordExtensionStore.schemaID || !ChordExtensionStore.shared.isEnabled)
        if staleChordSchema || (!currentSchemaId.isEmpty && status.schemaId != currentSchemaId && !status.schemaId.isEmpty) {
            let adopted = InputConfigurationStore.shared.adoptRuntimeSchema(
                status.schemaId
            )
            if !adopted,
               ChordExtensionStore.isChordSchema(status.schemaId) {
                let fallback = InputConfigurationStore.shared.runtimeProfile.schemaID
                rimeEngine.clearComposition(session: session)
                composition.markCleared()
                pendingFlyChordBase = nil
                mutualPairingState.reset()
                chord.invalidate()
                guard fallback != status.schemaId,
                      rimeEngine.selectSchema(fallback, session: session),
                      rimeEngine.getStatus(session: session).schemaId == fallback else {
                    candidateWindow.hideAll()
                    return
                }
                refreshSchema()
                IMELog.write(
                    "stale F4 chord selection rejected fallback=\(fallback)"
                )
                updateUI(client: client)
                return
            }
            IMELog.write("schema switched in-Rime -> \(status.schemaId)")
        }
        currentSchemaId = status.schemaId
        currentASCIIMode = status.asciiMode
        StatusMenu.shared.update(schemaId: status.schemaId, schemaName: status.schemaName)

        // Bundle identity was frozen when this exact lease was adopted. Do
        // not query the IMK proxy again after librime work may have allowed an
        // input-source transition to occur.
        let bid = lease.bundleID
        let mode = CompositionSession.mode(for: bid)
        let rimeContextActive = ctx.active || !ctx.input.isEmpty || !ctx.preedit.isEmpty
        let compositionActive = chord.hasPending || rimeContextActive
        let stagedChordGuardActive = chord.hasPending && !rimeContextActive
        let presentation = HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: logicalControlsActive,
            capturesRimeCommits: capturesRimeCommits,
            rimeComposing: compositionActive,
            secureInput: secureInput,
            stagedChordGuardActive: stagedChordGuardActive
        )
        let guardActive: Bool
        guard uiTransactionStillCurrent(
            lease: lease,
            client: client,
            secureInput: secureInput
        ) else {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            candidateWindow.hide(owner: focusToken)
            IMELog.write("updateUI presentation blocked before host write token=\(focusToken)")
            return
        }
        switch presentation {
        case .none:
            clearCompositionPresentation(client: client)
            guardActive = false
        case .normalPreedit:
            composition.update(preedit: ctx.preedit, cursorPosUTF8: ctx.cursorPos,
                               client: client, mode: mode)
            guardActive = false
        case let .bufferGuard(rimeComposing):
            composition.updateBufferGuard(rimeComposing: rimeComposing,
                                          client: client)
            guardActive = true
        }
        // IMK host proxy calls above may synchronously re-enter focus handling.
        // Never publish the old context or anchor its candidates under a newly
        // activated field/token.
        guard uiTransactionStillCurrent(
            lease: lease,
            client: client,
            secureInput: secureInput
        ) else {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            candidateWindow.hide(owner: focusToken)
            IMELog.write("updateUI presentation abandoned after focus change token=\(focusToken)")
            return
        }
        // In buffer mode the marked text is our invisible zero-width guard, not
        // a real field marker; don't let its unreliable markedRange drive
        // field-change detection (would drop chord/F4 keys — press-twice bug).
        publishCompositionActive(compositionActive,
            markedRangeReliable: !guardActive)
        guard uiTransactionStillCurrent(
            lease: lease,
            client: client,
            secureInput: secureInput
        ) else {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            candidateWindow.hide(owner: focusToken)
            IMELog.write("updateUI ownership changed while publishing token=\(focusToken)")
            return
        }

        if presentation == .none {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            candidateWindow.hide(owner: focusToken)
            return
        }

        if clipboardSearchActive {
            BufferWindowController.shared.clearInlineComposition(owner: focusToken)
            let inlinePreedit = ctx.preedit.isEmpty ? ctx.input : ctx.preedit
            let anchor = ClipboardHistoryWindowController.shared
                .updateSearchComposition(
                    inlinePreedit,
                    expected: focusToken,
                    client: client
                )
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                ClipboardHistoryWindowController.shared.clearSearchComposition()
                candidateWindow.hide(owner: focusToken)
                IMELog.write(
                    "clipboard search candidate anchor abandoned after focus change token=\(focusToken)"
                )
                return
            }
            if !ctx.candidates.isEmpty, let anchor {
                candidateWindow.update(
                    ctx,
                    caretRect: anchor,
                    bundleId: bid,
                    showPreedit: false,
                    owner: focusToken,
                    presentation: .clipboardCaret
                )
            } else {
                candidateWindow.hide(owner: focusToken)
            }
            return
        }

        let followsBufferCaret = bufferControlsActive
            && capturesRimeCommits
            && BufferWindowController.shared
                .shouldPresentCandidatesAtBufferCaret(for: focusToken)
        if followsBufferCaret {
            let inlinePreedit = ctx.preedit.isEmpty ? ctx.input : ctx.preedit
            let anchor = BufferWindowController.shared.updateInlineComposition(
                preedit: inlinePreedit,
                cursorPosUTF8: ctx.cursorPos,
                owner: focusToken
            )
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                BufferWindowController.shared.clearInlineComposition(owner: focusToken)
                candidateWindow.hide(owner: focusToken)
                IMELog.write("buffer candidate anchor abandoned after focus change token=\(focusToken)")
                return
            }
            if !ctx.candidates.isEmpty, let anchor {
                candidateWindow.update(
                    ctx,
                    caretRect: anchor,
                    bundleId: bid,
                    showPreedit: false,
                    owner: focusToken,
                    presentation: .bufferCaret
                )
            } else {
                // Marked text stays inline; a missing logical caret must not
                // fall back to an old host coordinate.
                candidateWindow.hide(owner: focusToken)
            }
            return
        }

        BufferWindowController.shared.clearInlineComposition(owner: focusToken)
        let showPreeditInPanel = mode == .placeholder
        let wantsPanel = !ctx.candidates.isEmpty
            || (showPreeditInPanel && (!ctx.preedit.isEmpty || !ctx.input.isEmpty))
        if wantsPanel {
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                candidateWindow.hide(owner: focusToken)
                IMELog.write("candidate caret blocked before host query token=\(focusToken)")
                return
            }
            let anchor = caretRect(for: client)
            guard uiTransactionStillCurrent(
                lease: lease,
                client: client,
                secureInput: secureInput
            ) else {
                candidateWindow.hide(owner: focusToken)
                IMELog.write("candidate caret abandoned after focus change token=\(focusToken)")
                return
            }
            candidateWindow.update(ctx,
                                   caretRect: anchor,
                                   bundleId: bid,
                                   showPreedit: showPreeditInPanel,
                                   owner: focusToken,
                                   presentation: .caret)
        } else {
            candidateWindow.hide(owner: focusToken)
        }
    }

    private func uiTransactionStillCurrent(
        lease: FocusLease,
        client: IMKTextInput,
        secureInput: Bool
    ) -> Bool {
        RimeInputSourceAuthority.currentSourceIsOwn()
            && focusToken == lease.token
            && ObjectIdentifier(client as AnyObject) == lease.clientIdentity
            && InputFocusCoordinator.shared.interactionTarget(
                expected: lease.token
            ) === lease
            && IsSecureEventInputEnabled() == secureInput
    }

    private func refreshSchema() {
        guard session != 0 else { return }
        let status = rimeEngine.getStatus(session: session)
        currentSchemaId = status.schemaId
        currentASCIIMode = status.asciiMode
        StatusMenu.shared.update(schemaId: status.schemaId, schemaName: status.schemaName)
    }

    /// Fresh, exact-target caret geometry for a newly summoned workbench. Host
    /// proxy calls are bracketed by the same live lease validation used by
    /// delivery; a synchronous focus change discards the returned rectangle.
    func workbenchCaretRect(expected lease: FocusLease) -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              lease.controller === self,
              focusToken == lease.token,
              let client = lease.client,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity,
              InputFocusCoordinator.shared.liveTarget(
                expected: lease.token,
                forceOverlayVisibilityRefresh: true
              ) === lease else { return nil }

        let rect = caretRect(for: client)
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              focusToken == lease.token,
              InputFocusCoordinator.shared.liveTarget(
                expected: lease.token,
                forceOverlayVisibilityRefresh: true
              ) === lease,
              BufferWindowGeometry.isPlausibleInputAnchor(
                rect,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
              ) else { return nil }
        return rect
    }

    /// Focused text-box frame for a newly summoned workbench, behind the same
    /// live lease validation as `workbenchCaretRect`. The Accessibility read
    /// is bracketed by two ownership checks, so a synchronous focus change
    /// discards the rectangle rather than aligning the workbench to a field
    /// the user has already left. Returns nil whenever alignment is off, the
    /// grant is missing, or the host exposes no usable text box.
    func workbenchInputBoxRect(expected lease: FocusLease) -> NSRect? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              lease.controller === self,
              focusToken == lease.token,
              let client = lease.client,
              ObjectIdentifier(client as AnyObject) == lease.clientIdentity,
              InputFocusCoordinator.shared.liveTarget(
                expected: lease.token,
                forceOverlayVisibilityRefresh: true
              ) === lease else { return nil }

        guard let box = FocusedInputBoxProbe.focusedBoxFrame() else { return nil }
        guard RimeInputSourceAuthority.currentSourceIsOwn(),
              !IsSecureEventInputEnabled(),
              focusToken == lease.token,
              InputFocusCoordinator.shared.liveTarget(
                expected: lease.token,
                forceOverlayVisibilityRefresh: true
              ) === lease else { return nil }
        return box
    }

    /// Caret rect in screen coords. Reliable while a marked-text session is
    /// active (§4.2); the candidate window validates it and only caches it for
    /// the lifetime of the current exact owner token.
    private func caretRect(for client: IMKTextInput) -> NSRect {
        guard RimeInputSourceAuthority.currentSourceIsOwn() else {
            return .zero
        }
        // InputMethodKit defines this index relative to the inline session,
        // while selectedRange/markedRange are document-relative. Index 0 also
        // means the current selection when a host exposes no inline session.
        // Mixing those coordinate systems moves both the ordinary candidate
        // panel and the explicitly opened workbench in Chromium/Electron clients.
        let rect = InputCaretGeometryRules.queryAtInlineSessionAnchor { index in
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: index,
                                  lineHeightRectangle: &rect)
            return rect
        }
        guard RimeInputSourceAuthority.currentSourceIsOwn() else { return .zero }
        return rect
    }

    private func watchdog(_ what: String, since t0: CFAbsoluteTime) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if ms > 250 {
            IMELog.write("WATCHDOG \(what) took \(ms)ms schema=\(currentSchemaId)")
        }
    }

    // MARK: System input-source menu / stored F4 schema preference

    override func menu() -> NSMenu! {
        StatusMenu.shared.makeInputSourceMenu(target: self)
    }

    // InputMethodKit routes commands from the system text-input menu back to
    // the active controller. Keep these selectors on the controller (as the
    // framework expects) and forward the work to the shared menu coordinator.
    @objc func openSettingsFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openSettings()
    }

    @objc func toggleBufferWindowFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.toggleBufferWindow()
    }

    @objc func toggleClipboardHistoryFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.toggleClipboardHistory()
    }

    @objc func openMaintenanceFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.showMaintenanceMenu(target: self)
    }
    @objc func openMailboxFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openMailbox()
    }

    @objc func openCapsuleFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openCapsule()
    }

    @objc func checkUpdateFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.checkUpdate()
    }

    @objc func openLogFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.openLog()
    }

    @objc func deployAndRestartFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.deployAndRestart()
    }

    @objc func reinstallFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.reinstallInputMethod()
    }

    @objc func restartFromInputMenu(_ sender: Any?) {
        StatusMenu.shared.restart()
    }

    private func applyStoredPreferenceIfNeeded() {
        guard session != 0 else { return }
        let pref = InputConfigurationStore.shared.runtimeProfile.schemaID
        // Only switch if the preferred schema is actually deployed. A stale or
        // removed preference (e.g. a custom 并击 schema not bundled in this build)
        // would otherwise put the session on an empty schema with no candidates.
        let available = rimeEngine.schemaList().map(\.id)
        guard available.isEmpty || available.contains(pref) else {
            IMELog.write("preferredSchema \(pref) not deployed; keeping current schema")
            return
        }
        let current = rimeEngine.getStatus(session: session).schemaId
        if current != pref {
            _ = rimeEngine.selectSchema(pref, session: session)
        }
    }
}
