import Cocoa

/// The application whose text field the workbench was last attached to.
///
/// A focus lease dies the moment another application comes forward — a click
/// on the desktop is enough — and nothing brought it back. The workbench then
/// showed a rail that refused every click, and the only way out was to click
/// the original text field by hand. Remembering which application held the
/// target turns that into something the workbench can do itself.
///
/// Only the application is remembered, never the field, its contents, or any
/// element reference. Bringing an application forward restores whatever it
/// had focused, which is both sufficient and the least this can know.
struct BufferTargetRecall: Equatable {
    /// Long enough to cover looking something up in another window, short
    /// enough that yesterday's target is never resurrected under the cursor.
    static let lifetime: TimeInterval = 180

    let bundleID: String
    let processIdentifier: pid_t
    let rememberedAt: Date

    func isLive(at moment: Date = Date(),
                lifetime: TimeInterval = lifetime) -> Bool {
        let age = moment.timeIntervalSince(rememberedAt)
        return age >= 0 && age < lifetime
    }

    /// Never recall ourselves: the workbench's own process is not a target,
    /// and activating it would fight the panel for focus.
    static func isRecallable(bundleID: String,
                             processIdentifier: pid_t,
                             ownProcessIdentifier: pid_t) -> Bool {
        !bundleID.isEmpty && processIdentifier != ownProcessIdentifier
    }
}

enum BufferTargetRecallOutcome: Equatable {
    case restored(bundleID: String)
    case alreadyFrontmost
    case expired
    case unavailable
    case none
}

/// Holds the last known target and can bring it back.
final class BufferTargetRecallStore {
    static let shared = BufferTargetRecallStore()

    private(set) var recall: BufferTargetRecall?

    private init() {}

    func remember(bundleID: String, processIdentifier: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard BufferTargetRecall.isRecallable(
            bundleID: bundleID,
            processIdentifier: processIdentifier,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        ) else { return }
        let next = BufferTargetRecall(bundleID: bundleID,
                                      processIdentifier: processIdentifier,
                                      rememberedAt: Date())
        guard recall?.bundleID != next.bundleID
            || recall?.processIdentifier != next.processIdentifier else {
            recall = next
            return
        }
        recall = next
        IMELog.write("buffer target remembered \(bundleID)")
    }

    func forget() {
        dispatchPrecondition(condition: .onQueue(.main))
        recall = nil
    }

    /// Brings the remembered application forward so its own focused field
    /// becomes the input target again. The lease that follows arrives through
    /// the ordinary IMK activation, which is why nothing here touches focus
    /// state directly.
    @discardableResult
    func restore(now: Date = Date()) -> BufferTargetRecallOutcome {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let recall else { return .none }
        guard recall.isLive(at: now) else {
            self.recall = nil
            IMELog.write("buffer target recall expired \(recall.bundleID)")
            return .expired
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier == recall.processIdentifier {
            return .alreadyFrontmost
        }
        guard let application = NSRunningApplication(
            processIdentifier: recall.processIdentifier
        ), !application.isTerminated else {
            self.recall = nil
            IMELog.write("buffer target recall unavailable \(recall.bundleID)")
            return .unavailable
        }
        application.activate()
        IMELog.write("buffer target recalled \(recall.bundleID)")
        return .restored(bundleID: recall.bundleID)
    }
}
