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
    private static let legacyMigrationKey = "chord.duration.legacyConfigMigrated.v1"

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultDuration }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static var duration: TimeInterval {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: key) != nil {
                let raw = defaults.double(forKey: key)
                let stored = clamp(raw)
                if stored != raw {
                    defaults.set(stored, forKey: key)
                }
                if !defaults.bool(forKey: legacyMigrationKey) {
                    defaults.set(true, forKey: legacyMigrationKey)
                }
                return stored
            }
            guard !defaults.bool(forKey: legacyMigrationKey) else {
                return defaultDuration
            }

            // Directory probing belongs only to the one-time migration path;
            // this getter is also read from the ordinary per-key session gate.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let userDirectory = ProcessInfo.processInfo.environment[
                "RIMEBUFFER_USER_DIR"
            ].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(
                "Library/\(RimesPaths.directoryName)",
                isDirectory: true
            )
            return resolvedDuration(
                defaults: defaults,
                userDirectory: userDirectory,
                squirrelDirectory: home.appendingPathComponent(
                    "Library/Rime",
                    isDirectory: true
                )
            )
        }
        set {
            let clamped = clamp(newValue)
            let defaults = UserDefaults.standard
            defaults.set(clamped, forKey: key)
            if !defaults.bool(forKey: legacyMigrationKey) {
                defaults.set(true, forKey: legacyMigrationKey)
            }
            IMELog.write("chord_duration=\(clamped) source=preference")
            NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
        }
    }

    static func resetToDefault() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        // Reset is an explicit choice of the product default. Do not import an
        // old squirrel.yaml value again on the next read.
        defaults.set(true, forKey: legacyMigrationKey)
        IMELog.write("chord_duration reset -> \(defaultDuration)")
        NotificationCenter.default.post(name: .chordDurationDidChange, object: nil)
    }

    /// Settings became UserDefaults-backed in 0.4, but existing installations
    /// already carried their tuned `chord_duration` in the Squirrel frontend
    /// config. Import that value exactly once so an upgrade does not silently
    /// replace (for example) a 50 ms chord window with the 100 ms default.
    static func resolvedDuration(
        defaults: UserDefaults,
        userDirectory: URL,
        squirrelDirectory: URL
    ) -> TimeInterval {
        if defaults.object(forKey: key) != nil {
            let stored = clamp(defaults.double(forKey: key))
            if stored != defaults.double(forKey: key) {
                defaults.set(stored, forKey: key)
            }
            if !defaults.bool(forKey: legacyMigrationKey) {
                defaults.set(true, forKey: legacyMigrationKey)
            }
            return stored
        }

        guard !defaults.bool(forKey: legacyMigrationKey) else {
            return defaultDuration
        }

        let candidates = [
            userDirectory.appendingPathComponent("build/squirrel.yaml"),
            userDirectory.appendingPathComponent("squirrel.custom.yaml"),
            userDirectory.appendingPathComponent("squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("build/squirrel.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.custom.yaml"),
            squirrelDirectory.appendingPathComponent("squirrel.yaml"),
        ]
        var visited: Set<String> = []
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard visited.insert(path).inserted,
                  let legacy = legacyDuration(in: url) else {
                continue
            }
            let migrated = clamp(legacy)
            defaults.set(migrated, forKey: key)
            defaults.set(true, forKey: legacyMigrationKey)
            IMELog.write(
                "chord_duration=\(migrated) source=legacy-config path=\(path)"
            )
            return migrated
        }
        // Freeze the one-shot decision only after the scan completes. Even a
        // missing or malformed legacy config must not be re-imported after the
        // user later chooses "reset to default" by removing the preference.
        defaults.set(true, forKey: legacyMigrationKey)
        return defaultDuration
    }

    private static func legacyDuration(in url: URL) -> TimeInterval? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            let uncommented = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first ?? ""
            let parts = uncommented.split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces)
                    == "chord_duration",
                  let duration = Double(
                    parts[1].trimmingCharacters(in: .whitespaces)
                  ),
                  duration.isFinite,
                  duration > 0 else {
                continue
            }
            return duration
        }
        return nil
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

/// Internal settlement decisions, not selectable input modes. Unified 并击
/// always permits compatible left-then-right split strokes. A completed
/// syllable can still opt out of future pairing through `sameBatchOnly`.
///
/// - `sameBatchOnly` closes the batch without recording a pairing candidate.
/// - `independentHalves` settles the batch, then a settled left-only fragment
///   may pair with the next right-only batch when at least one is multi-key.
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
        schemaID == ChordExtensionStore.schemaID && !asciiMode
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
        let cursor = min(max(context.inputCaretPos ?? context.cursorPos, 0), bytes.count)
        let delimiter = UInt8(delimiterKeycode)
        return FlyChordBoundaryPlan(
            before: cursor > 0 && bytes[cursor - 1] != delimiter,
            after: cursor < bytes.count && bytes[cursor] != delimiter
        )
    }
}

/// Custom maps declare whether an output closes a pinyin syllable. Keep the
/// legacy FlyYao delimiter contract while making that distinction explicit for
/// new profiles, including complete syllables assigned wholly to one hand.
enum ChordKeymapBoundaryRules {
    static func shouldInsert(keys: [Int32], profile: ChordKeymapProfile) -> Bool {
        if profile.boundaryPolicy == .legacyBatches {
            return FlyChordBoundaryRules.shouldInsert(forKeyCount: keys.count)
        }
        return profile.entry(for: Set(keys))?.kind == .syllable
    }

    static func plan(for context: RimeContextModel,
                     profile: ChordKeymapProfile) -> FlyChordBoundaryPlan {
        let legacy = FlyChordBoundaryRules.plan(for: context)
        // Close custom complete syllables at the end as well. Otherwise a
        // following literal or fragment could silently join the previous one.
        return FlyChordBoundaryPlan(before: legacy.before,
                                    after: profile.boundaryPolicy == .legacyBatches ? legacy.after : true)
    }

    static func mayCombine(keys: [Int32], profile: ChordKeymapProfile) -> Bool {
        profile.boundaryPolicy == .legacyBatches || profile.entry(for: Set(keys))?.kind == .syllable
    }

    static func mayAwaitComplement(keys: [Int32], profile: ChordKeymapProfile) -> Bool {
        profile.boundaryPolicy == .legacyBatches || profile.entry(for: Set(keys))?.kind != .syllable
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

    init?(keys: [(keycode: Int32, mask: Int32)], layout: ChordKeymapProfile? = nil) {
        let halves = Set(keys.compactMap { key in
            if let layout { return layout.half(for: key.keycode) }
            return FlyChordLayout.half(for: key.keycode)
        })
        switch halves {
        case [.left]: self = .leftOnly
        case [.right]: self = .rightOnly
        case [.left, .right]: self = .bothHalves
        default: return nil
        }
    }
}

/// Tracks the cross-batch relationship unified 并击 preserves: a settled
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
/// important "same-batch settlement plus guarded cross-batch pairing" contract
/// executable in the CLI smoke test.
struct FlyChordBatchState {
    private(set) var pending: [FlyChordKeyEvent] = []
    private(set) var handled: [FlyChordKeyEvent] = []

    var hasPending: Bool { !pending.isEmpty }

    mutating func stage(_ key: FlyChordKeyEvent,
                        policy: FlyChordSettlementPolicy,
                        layout: ChordKeymapProfile? = nil) -> FlyChordPressDecision {
        let half: FlyChordHalf?
        if let layout { half = layout.half(for: key.keycode) }
        else { half = FlyChordLayout.half(for: key.keycode) }
        guard half != nil else { return .consume }
        guard !pending.contains(where: { $0.keycode == key.keycode }) else {
            return .consume
        }
        guard pending.count < 50 else { return .consume }
        pending.append(key)

        switch policy {
        case .sameBatchOnly, .independentHalves:
            // Every batch settles normally. Whether it remains eligible for
            // later pairing is a separate decision owned by the caller.
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
    /// enter Rime together at settlement, without discarding a useful
    /// one-sided mapping while waiting for a possible right-hand complement.
    func stageChordKey(_ keycode: Int32,
                       mask: Int32,
                       client: any IMKTextInput,
                       policy: FlyChordSettlementPolicy,
                       layout: ChordKeymapProfile? = nil) -> FlyChordPressDecision {
        let decision = batch.stage(FlyChordKeyEvent(keycode: keycode, mask: mask),
                                   policy: policy, layout: layout)
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
