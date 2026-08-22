import Cocoa
import InputMethodKit

extension Notification.Name {
    static let chordDurationDidChange = Notification.Name("ChordDurationDidChange")
}

/// User-tunable 并击 (chord) release window, persisted in UserDefaults and
/// surfaced in Settings ▸ 输入. This is the single source of truth: the value
/// replaces the old squirrel.yaml `chord_duration` read so tuning never needs a
/// config-file edit or redeploy. Changing it posts `.chordDurationDidChange`,
/// which every live controller observes to update its `ChordController` at once.
enum ChordSettings {
    static let defaultDuration: TimeInterval = 0.10
    static let range: ClosedRange<TimeInterval> = 0.02...0.50
    private static let key = "chord.duration"

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static var duration: TimeInterval {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: key) != nil else { return defaultDuration }
            return clamp(defaults.double(forKey: key))
        }
        set {
            let clamped = clamp(newValue)
            UserDefaults.standard.set(clamped, forKey: key)
            IMELog.write("chord_duration=\(clamped) source=preference")
            NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
        }
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        IMELog.write("chord_duration reset -> \(defaultDuration)")
        NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
    }
}

/// Synchronous routing barrier used while a focus lease is being revoked or
/// suspended. `ChordController.flush()` still feeds every release into Rime so
/// the composition can be recovered, but its callback must not touch the IMK
/// client proxy whose destination is no longer trustworthy.
final class ChordClientRoutingGate {
    private var isolationDepth = 0

    var allowsClientRouting: Bool { isolationDepth == 0 }

    func withIsolatedClientRouting(_ action: () -> Void) {
        isolationDepth += 1
        defer { isolationDepth -= 1 }
        action()
    }
}

/// FlyYao divides every printable chording key by physical keyboard half.  The
/// split is expressed in Rime keysyms (not macOS virtual key codes), because a
/// keyboard layout may change the latter's printable character.
enum FlyChordHalf: Hashable {
    case left
    case right
}

enum FlyChordLayout {
    static let leftAlphabet = "qwertasdfgzxcvb"
    static let rightAlphabet = "yuiophjklnm,."

    private static let leftKeycodes = Set(leftAlphabet.unicodeScalars.map { Int32($0.value) })
    private static let rightKeycodes = Set(rightAlphabet.unicodeScalars.map { Int32($0.value) })

    static func half(for keycode: Int32) -> FlyChordHalf? {
        if leftKeycodes.contains(keycode) { return .left }
        if rightKeycodes.contains(keycode) { return .right }
        return nil
    }
}

/// Product-level settlement policy layered over the same FlyYao key map.
///
/// - `sameBatchOnly` is 并击: every key inside the current timer batch resolves
///   together. Multi-key left-only/right-only mappings are useful chords, while
///   a one-key batch remains literal. Separate batches are never recombined.
/// - `independentHalves` is 互击: it has the same per-batch settlement, plus a
///   settled left-only initial may pair with the next right-only final when at
///   least one of those halves is a real multi-key chord.
enum FlyChordSettlementPolicy: Equatable {
    case sameBatchOnly
    case independentHalves
}

/// A my_combo session only owns plain alphabet presses while it is composing
/// Chinese.  In ASCII mode Rime intentionally returns those keys to the host;
/// staging them here would swallow ordinary Latin typing until the chord timer
/// fires.
enum FlyChordRoutingRules {
    static func shouldStage(schemaID: String, asciiMode: Bool) -> Bool {
        schemaID == "my_combo" && !asciiMode
    }

    static func shouldStage(schemaID: String,
                            asciiMode: Bool,
                            extensionEnabled: Bool) -> Bool {
        extensionEnabled && shouldStage(schemaID: schemaID,
                                        asciiMode: asciiMode)
    }
}

/// Every settled multi-key FlyYao batch is one syllable. Rime's speller
/// otherwise has no way to distinguish two physical strokes whose canonical
/// spellings also form a valid single syllable (`ni` + `an` -> `nian`). A
/// one-key batch is deliberately literal: it may be part of an English word,
/// so it must neither gain an apostrophe nor be forced into a half-key mapping.
/// The structural plan is still retained for a one-key left batch because a
/// later multi-key right complement may turn both batches into one real chord.
struct FlyChordBoundaryPlan: Equatable {
    let before: Bool
    let after: Bool
}

enum FlyChordBoundaryRules {
    static let delimiterKeycode: Int32 = 0x27

    static func shouldInsert(forKeyCount count: Int) -> Bool {
        count > 1
    }

    static func plan(for context: RimeContextModel) -> FlyChordBoundaryPlan {
        let bytes = Array(context.input.utf8)
        let cursor = min(max(context.cursorPos, 0), bytes.count)
        let delimiter = UInt8(delimiterKeycode)
        return FlyChordBoundaryPlan(
            before: cursor > 0 && bytes[cursor - 1] != delimiter,
            after: cursor < bytes.count && bytes[cursor] != delimiter
        )
    }
}

struct FlyChordKeyEvent: Equatable {
    let keycode: Int32
    let mask: Int32
}

enum FlyChordPressDecision: Equatable {
    /// The event is an auto-repeat/overflow/unknown key that must not be added
    /// to the replay set a second time.
    case consume
    /// Add these newly staged press events to the eventual Rime replay set.
    case process([FlyChordKeyEvent])
}

enum FlyChordBatchShape: Equatable {
    case leftOnly
    case rightOnly
    case bothHalves

    init?(keys: [(keycode: Int32, mask: Int32)]) {
        let halves = Set(keys.compactMap { FlyChordLayout.half(for: $0.keycode) })
        switch halves {
        case [.left]: self = .leftOnly
        case [.right]: self = .rightOnly
        case [.left, .right]: self = .bothHalves
        default: return nil
        }
    }
}

/// Tracks the one cross-batch relationship that 互击 must preserve: a settled
/// left-only initial followed by a right-only final belongs to one syllable.
/// The left batch is visible immediately; when its right complement arrives,
/// the controller removes that one insertion and replays both physical halves
/// as a normal full chord. Rime therefore ends with the exact same canonical
/// raw input, candidates, editing positions and commit semantics as a
/// simultaneous chord—no hidden sentinel spelling is left in the session.
struct FlyChordMutualPairingState {
    struct SettledLeft: Equatable {
        let keys: [FlyChordKeyEvent]
        let baseInput: String
        let settledInput: String
        let settledCursorPos: Int
        let settledSelStart: Int
        let settledSelEnd: Int
        let boundaryPlan: FlyChordBoundaryPlan
        let insertedScalarCount: Int
    }

    private var settledLeft: SettledLeft?

    mutating func recordSettledLeft(keys: [FlyChordKeyEvent],
                                    baseInput: String,
                                    settledContext: RimeContextModel,
                                    boundaryPlan: FlyChordBoundaryPlan,
                                    policy: FlyChordSettlementPolicy,
                                    shape: FlyChordBatchShape) {
        guard policy == .independentHalves,
              shape == .leftOnly,
              let inserted = FlyChordInputRollback.insertedScalarCount(
                before: baseInput,
                after: settledContext.input
              ),
              inserted > 0 else {
            settledLeft = nil
            return
        }
        settledLeft = SettledLeft(keys: keys,
                                  baseInput: baseInput,
                                  settledInput: settledContext.input,
                                  settledCursorPos: settledContext.cursorPos,
                                  settledSelStart: settledContext.selStart,
                                  settledSelEnd: settledContext.selEnd,
                                  boundaryPlan: boundaryPlan,
                                  insertedScalarCount: inserted)
    }

    mutating func takeComplement(before shape: FlyChordBatchShape,
                                 currentKeyCount: Int,
                                 policy: FlyChordSettlementPolicy,
                                 currentContext: RimeContextModel) -> SettledLeft? {
        guard policy == .independentHalves,
              shape == .rightOnly,
              let pending = settledLeft,
              pending.keys.count > 1 || currentKeyCount > 1,
              pending.settledInput == currentContext.input,
              pending.settledCursorPos == currentContext.cursorPos,
              pending.settledSelStart == currentContext.selStart,
              pending.settledSelEnd == currentContext.selEnd else {
            settledLeft = nil
            return nil
        }
        settledLeft = nil
        return pending
    }

    mutating func reset() {
        settledLeft = nil
    }
}

/// Pure batching state. Keeping this independent of Timer/IMK makes the
/// important "same-batch chord vs cross-batch mutual pairing" contract
/// executable in the CLI smoke test.
struct FlyChordBatchState {
    private(set) var pending: [FlyChordKeyEvent] = []
    private(set) var handled: [FlyChordKeyEvent] = []

    var hasPending: Bool { !pending.isEmpty }

    mutating func stage(_ key: FlyChordKeyEvent,
                        policy: FlyChordSettlementPolicy) -> FlyChordPressDecision {
        guard FlyChordLayout.half(for: key.keycode) != nil else { return .consume }
        guard !pending.contains(where: { $0.keycode == key.keycode }) else {
            return .consume
        }
        guard pending.count < 50 else { return .consume }
        pending.append(key)

        switch policy {
        case .sameBatchOnly, .independentHalves:
            // Both modes settle every current batch. Their only semantic
            // difference is whether the owner later recombines two batches.
            return .process([key])
        }
    }

    mutating func noteHandled(_ key: FlyChordKeyEvent) {
        guard pending.contains(key), !handled.contains(key) else { return }
        handled.append(key)
    }

    mutating func settle() -> [FlyChordKeyEvent] {
        let replay = handled
        pending.removeAll(keepingCapacity: true)
        handled.removeAll(keepingCapacity: true)
        return replay
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        handled.removeAll(keepingCapacity: true)
    }
}

/// Detect the only mutation chord_composer is allowed to make when a failed
/// press subset is released: one contiguous insertion at the current raw-input
/// cursor.  The cursor remains immediately after that insertion, so ordinary
/// BackSpace events can remove it without disturbing the prefix or suffix that
/// predated the failed batch.
enum FlyChordInputRollback {
    static func insertedScalarCount(before: String, after: String) -> Int? {
        let old = Array(before.unicodeScalars)
        let new = Array(after.unicodeScalars)
        guard new.count >= old.count else { return nil }
        let insertedCount = new.count - old.count
        for offset in 0...old.count {
            guard new.prefix(offset).elementsEqual(old.prefix(offset)) else { continue }
            guard new.dropFirst(offset + insertedCount)
                    .elementsEqual(old.dropFirst(offset)) else { continue }
            return insertedCount
        }
        return nil
    }
}

/// Chord (并击) release-replay, Squirrel-style: chord keys that Rime handled are
/// buffered; when `duration` elapses with no new chord key, every buffered key
/// is replayed with releaseMask so chord_composer resolves the chord.
///
/// The OWNER gates this on the active schema (only my_combo uses
/// chord_composer) — sequential schemas must never see synthetic releases.
/// `duration` is seeded from `ChordSettings.duration` by the owner; never
/// hardcode a competing value here.
final class ChordController {
    var duration: TimeInterval = ChordSettings.defaultDuration

    private var batch = FlyChordBatchState()
    private var timer: Timer?
    private weak var client: (any IMKTextInput)?

    /// Replays keys (with releaseMask) against the session and drains commits.
    var onFlush: ((_ keys: [(keycode: Int32, mask: Int32)], _ client: (any IMKTextInput)?) -> Void)?

    /// A defensive empty batch still needs to retire the owner's temporary
    /// marked-text guard.
    var onDiscard: ((_ client: (any IMKTextInput)?) -> Void)?

    var hasPending: Bool { batch.hasPending }

    /// Stage a physical chord press before it reaches Rime. All accepted keys
    /// enter Rime together at settlement, so neither mode may discard a useful
    /// one-sided mapping merely to distinguish 并击 from 互击.
    func stageChordKey(_ keycode: Int32,
                       mask: Int32,
                       client: any IMKTextInput,
                       policy: FlyChordSettlementPolicy) -> FlyChordPressDecision {
        let decision = batch.stage(FlyChordKeyEvent(keycode: keycode, mask: mask),
                                   policy: policy)
        self.client = client
        guard batch.hasPending else { return decision }
        timer?.invalidate()
        let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.flush()
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        return decision
    }

    /// Record only presses that Rime accepted.  Releases are synthesized only
    /// for this subset, preserving the original Squirrel replay invariant.
    func noteHandledChordKey(_ keycode: Int32, mask: Int32) {
        batch.noteHandled(FlyChordKeyEvent(keycode: keycode, mask: mask))
    }

    /// Resolve the pending chord NOW (timer fired, a non-chord key arrived,
    /// focus is leaving, or a commit is being forced).
    func flush() {
        guard batch.hasPending else { return }
        let keys = batch.settle().map { (keycode: $0.keycode, mask: $0.mask) }
        let flushClient = client      // strong for the duration of the flush
        timer?.invalidate()
        timer = nil
        client = nil
        if keys.isEmpty {
            onDiscard?(flushClient)
        } else {
            onFlush?(keys, flushClient)
        }
    }

    /// Cancel a batch after Rime rejects one of its press events. The caller
    /// receives the already-staged subset so it can synthesize matching
    /// releases before clearing the failed composition. No normal flush or
    /// client callback is fired.
    func abort() -> [(keycode: Int32, mask: Int32)] {
        let keys = batch.settle().map { (keycode: $0.keycode, mask: $0.mask) }
        timer?.invalidate()
        timer = nil
        client = nil
        return keys
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        client = nil
        batch.reset()
    }
}
