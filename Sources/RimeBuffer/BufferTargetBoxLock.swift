import ApplicationServices
import Foundation

/// Whether the Buffer knows exactly which input box it would send to.
enum BufferTargetBoxState: Equatable {
    /// One identified box — and, while capturing, the same box capture was
    /// granted for. An app that exposes no boxes at all counts its input
    /// session as the box.
    case locked
    /// No box can be named: Accessibility is not granted, or focus is on
    /// something that is not a text box. Typing into the Buffer still works;
    /// sending does not, and the text can be copied out instead.
    case unidentified
    /// Capture was granted for one box and focus has since left it.
    case changed
}

/// A `FocusToken` names an IMK client and its application, and one client can
/// front many boxes — a whole web page is one client. So a send also needs the
/// box: the one focused now, and while capturing, the one capture was granted
/// for. Generic over the box so the rule is testable without Accessibility.
enum BufferTargetBoxRules {
    static func state<Box: Equatable>(capturing: Bool,
                                      lockedBox: Box?,
                                      currentBox: Box?) -> BufferTargetBoxState {
        guard capturing else { return currentBox == nil ? .unidentified : .locked }
        // Capture granted without a box stays unlocked until it is granted
        // again with one; a box that appears later was never chosen.
        guard let lockedBox else { return .unidentified }
        return currentBox == lockedBox ? .locked : .changed
    }

    /// A focus sample older than this no longer vouches for the box.
    static let deliverySampleLifetime: TimeInterval = 1.0

    /// Sending needs a locked box confirmed by a recent sample. A stale or
    /// missing sample refuses; it never assumes the box is unchanged.
    static func deliveryAllowed(state: BufferTargetBoxState,
                                sampleAge: TimeInterval?) -> Bool {
        guard state == .locked, let sampleAge else { return false }
        return sampleAge >= 0 && sampleAge <= deliverySampleLifetime
    }
}

/// What a capture is locked to inside its application.
enum BufferTargetBox: Equatable {
    /// An Accessibility text element, compared by identity only.
    case element(AXUIElement)
    /// The application answered that nothing in it has focus: it draws its
    /// own controls and exposes no boxes (WeChat). Its input session — the
    /// capture's `FocusToken` — stands in for the box.
    case wholeSession

    static func == (lhs: BufferTargetBox, rhs: BufferTargetBox) -> Bool {
        switch (lhs, rhs) {
        case let (.element(lhs), .element(rhs)): return CFEqual(lhs, rhs)
        case (.wholeSession, .wholeSession): return true
        default: return false
        }
    }
}

/// How a capture grant names its box.
enum BufferCaptureBoxBinding {
    /// The user chose the route: lock whichever box is focused now.
    case current
    /// The route is being restored after the host lost its input session, not
    /// chosen again, so it may only re-lock the box it already had — or, for
    /// an app that exposes no boxes, the same application, which the pending
    /// request already requires.
    case sameAs(BufferTargetBox?)
}

/// The input box a Buffer capture is bound to, kept beside the capture's
/// `FocusToken`.
///
/// Every Accessibility query runs on a background queue. A Chromium host can
/// take its whole timeout to answer, and a stall that long on the main thread
/// breaks chord timing and delays every key. The main thread only reads the
/// latest published sample. Sampling runs about three times a second while the
/// workbench is visible, and a send refuses unless a sample from the last
/// second still shows the locked box. A query the host leaves unanswered is
/// not a sample: the last answer stands until it ages out.
final class BufferTargetBoxLock {
    static let shared = BufferTargetBoxLock()
    static let sampleInterval: TimeInterval = 0.3

    /// Called on the main queue after each sample lands.
    var onSample: (() -> Void)?

    private struct Sample {
        let token: FocusToken
        let box: BufferTargetBox?
        let uptime: TimeInterval
    }

    private let queue = DispatchQueue(label: "com.scholay.rimes.target-box",
                                      qos: .userInitiated)
    private var token: FocusToken?
    private(set) var box: BufferTargetBox?
    /// A grant waiting for its first sample; until it lands nothing is locked.
    private var pendingBinding: BufferCaptureBoxBinding?
    /// Bumped by every grant, so a sample requested before it can never
    /// resolve it — that sample describes the box focused before the click.
    private var generation: UInt64 = 0
    private var sample: Sample?
    private var inFlight: FocusToken?
    private var heldState: (token: FocusToken, state: BufferTargetBoxState)?
    /// Runs once when the pending grant resolves; a later grant replaces it.
    private var bindingResolved: (() -> Void)?
    private var unansweredLoggedGeneration: UInt64?

    private init() {}

    /// Starts binding a new capture grant to a box. It stays unlocked until a
    /// sample taken after the grant lands; `resolved` then runs once on the
    /// main queue, whether that sample named the box or not.
    func bind(to lease: FocusLease,
              _ binding: BufferCaptureBoxBinding,
              resolved: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        token = lease.token
        box = nil
        pendingBinding = binding
        bindingResolved = resolved
        // The toolbar keeps its last state for this target until the grant's
        // sample lands instead of flashing "unidentified" for a few
        // milliseconds; sending needs the new sample regardless.
        sample = nil
        requestSample(for: lease, force: true)
    }

    /// Never blocks: reads the latest sample and, when it is getting old,
    /// asks the background queue for a new one.
    func state(for lease: FocusLease) -> BufferTargetBoxState {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = ProcessInfo.processInfo.systemUptime
        let current = sample.flatMap { sample -> Sample? in
            guard sample.token == lease.token else { return nil }
            let age = now - sample.uptime
            return age >= 0 && age <= BufferTargetBoxRules.deliverySampleLifetime
                ? sample
                : nil
        }
        if current.map({ now - $0.uptime >= Self.sampleInterval }) ?? true {
            requestSample(for: lease)
        }
        guard let current else {
            // No recent sample yet: keep showing what was last known for this
            // target rather than flashing a false change. Sending still
            // refuses, because it needs a recent sample.
            if let heldState, heldState.token == lease.token { return heldState.state }
            return .unidentified
        }
        let model = BufferModel.shared
        let capturing = model.captureFocusToken == lease.token
            && model.capturesInput(for: lease.token)
        let state = BufferTargetBoxRules.state(
            capturing: capturing,
            lockedBox: token == lease.token && pendingBinding == nil ? box : nil,
            currentBox: current.box
        )
        heldState = (lease.token, state)
        return state
    }

    /// Checked immediately before every block is sent, without querying
    /// Accessibility on the main thread.
    func permitsDelivery(to lease: FocusLease) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let state = state(for: lease)
        let age = sample.flatMap {
            $0.token == lease.token
                ? ProcessInfo.processInfo.systemUptime - $0.uptime
                : nil
        }
        return BufferTargetBoxRules.deliveryAllowed(state: state, sampleAge: age)
    }

    private func requestSample(for lease: FocusLease, force: Bool = false) {
        guard force || inFlight != lease.token else { return }
        inFlight = lease.token
        let token = lease.token
        let generation = generation
        // An ordinary application's box must belong to that application.
        // System surfaces (Spotlight, open/save panels) are drawn by a process
        // the lease does not name, so there only the element is compared.
        let owner = lease.hostKind == .frontmostApplication
            ? lease.processIdentifier
            : nil
        queue.async { [weak self] in
            let result = FocusedInputBoxProbe.probeFocusedTextBox(ownedBy: owner)
            let uptime = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self?.publish(token: token,
                              generation: generation,
                              element: result.element,
                              failure: result.failure,
                              answered: result.answered,
                              exposesNoBoxes: result.exposesNoBoxes,
                              uptime: uptime)
            }
        }
    }

    private func publish(token: FocusToken,
                         generation: UInt64,
                         element: AXUIElement?,
                         failure: String?,
                         answered: Bool,
                         exposesNoBoxes: Bool,
                         uptime: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        if inFlight == token { inFlight = nil }
        guard generation == self.generation else { return }
        guard answered else {
            // A host busy with the block just sent can miss the timeout. That
            // is not a different box: keep the last answer, and let a pending
            // grant wait for the next sample.
            if token == self.token, pendingBinding != nil,
               unansweredLoggedGeneration != generation {
                unansweredLoggedGeneration = generation
                IMELog.write("buffer target box query unanswered (\(failure ?? "timeout")); retrying token=\(token)")
            }
            return
        }
        if let sample, sample.token == token, sample.uptime > uptime { return }
        // An app that answered "nothing in me has focus" draws its own
        // controls and exposes no boxes: its input session stands in for one.
        let box: BufferTargetBox? = element.map { .element($0) }
            ?? (exposesNoBoxes ? .wholeSession : nil)
        sample = Sample(token: token, box: box, uptime: uptime)
        var resolved: (() -> Void)?
        if token == self.token, let binding = pendingBinding {
            pendingBinding = nil
            resolved = bindingResolved
            bindingResolved = nil
            switch binding {
            case .current:
                self.box = box
            case let .sameAs(previous):
                self.box = previous != nil && box == previous ? box : nil
            }
            let detail: String
            switch self.box {
            case .element?:
                detail = "locked"
            case .wholeSession?:
                detail = "locked to its input session (the app exposes no boxes)"
            case nil:
                detail = "unidentified (\(failure ?? "not the box the route had"))"
            }
            IMELog.write("buffer target box \(detail) token=\(token)")
        }
        onSample?()
        resolved?()
    }
}
