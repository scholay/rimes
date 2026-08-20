import Cocoa
import Carbon.HIToolbox

/// Reasons clipboard content must not be read or rendered. Multiple reasons can
/// be active at once during fast user/session transitions.
struct ClipboardHistoryProtection: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let secureInput = ClipboardHistoryProtection(rawValue: 1 << 0)
    static let screenLocked = ClipboardHistoryProtection(rawValue: 1 << 1)
    static let sessionInactive = ClipboardHistoryProtection(rawValue: 1 << 2)
}

struct ClipboardHistoryCaptureState: Equatable, Sendable {
    var workbenchVisible: Bool
    var railEnabled: Bool
    var protection: ClipboardHistoryProtection

    init(workbenchVisible: Bool = false,
         railEnabled: Bool = false,
         protection: ClipboardHistoryProtection = []) {
        self.workbenchVisible = workbenchVisible
        self.railEnabled = railEnabled
        self.protection = protection
    }

    var allowsClipboardObservation: Bool {
        workbenchVisible && railEnabled && protection.isEmpty
    }
}

struct ClipboardHistoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let byteCount: Int
    let capturedAt: Date
}

struct ClipboardHistoryConfiguration: Equatable, Sendable {
    let maximumItems: Int
    let maximumItemBytes: Int
    let maximumTotalBytes: Int
    let pollingInterval: TimeInterval

    init(maximumItems: Int = 30,
         maximumItemBytes: Int = 64 * 1024,
         maximumTotalBytes: Int = 512 * 1024,
         pollingInterval: TimeInterval = 0.45) {
        let resolvedTotal = max(1, maximumTotalBytes)
        self.maximumItems = max(1, maximumItems)
        self.maximumItemBytes = min(max(1, maximumItemBytes), resolvedTotal)
        self.maximumTotalBytes = resolvedTotal
        self.pollingInterval = max(0.1, pollingInterval)
    }
}

protocol ClipboardHistoryPasteboardReading: AnyObject {
    var changeCount: Int { get }
    func readPlainText() -> String?
}

private final class SystemClipboardHistoryPasteboard: ClipboardHistoryPasteboardReading {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func readPlainText() -> String? {
        pasteboard.string(forType: .string)
    }
}

/// Ephemeral, process-local clipboard history for the native workbench.
///
/// The model deliberately has no persistence API. It touches NSPasteboard only
/// while `start()` is active and the latest capture state says that both the
/// workbench and Clipboard rail are visible. Every protected or inactive gap is
/// followed by a change-count-only baseline, so text copied while the rail was
/// hidden or protected is never backfilled on resume.
@MainActor
final class ClipboardHistoryModel {
    typealias Observer = () -> Void

    private let configuration: ClipboardHistoryConfiguration
    private let pasteboard: ClipboardHistoryPasteboardReading
    private let protectionProbe: () -> ClipboardHistoryProtection
    private let clock: () -> Date
    private let schedulesAutomaticPolling: Bool

    private var timer: Timer?
    private var observers: [UUID: Observer] = [:]
    private var lastObservedPasteboardChangeCount: Int?
    private var needsPasteboardBaseline = true
    private var effectiveProtection: ClipboardHistoryProtection = []
    private var started = false
    private var totalBytes = 0

    private(set) var captureState = ClipboardHistoryCaptureState()
    private var storedItems: [ClipboardHistoryItem] = []
    private(set) var selectedID: UUID?

    init(configuration: ClipboardHistoryConfiguration = .init()) {
        self.configuration = configuration
        pasteboard = SystemClipboardHistoryPasteboard()
        protectionProbe = {
            IsSecureEventInputEnabled() ? [.secureInput] : []
        }
        clock = Date.init
        schedulesAutomaticPolling = true
    }

    init(configuration: ClipboardHistoryConfiguration,
         pasteboard: ClipboardHistoryPasteboardReading,
         protectionProbe: @escaping () -> ClipboardHistoryProtection = { [] },
         clock: @escaping () -> Date = Date.init,
         schedulesAutomaticPolling: Bool = true) {
        self.configuration = configuration
        self.pasteboard = pasteboard
        self.protectionProbe = protectionProbe
        self.clock = clock
        self.schedulesAutomaticPolling = schedulesAutomaticPolling
    }

    deinit {
        timer?.invalidate()
    }

    var isStarted: Bool { started }

    /// Re-probe Secure Input on every content access and action, not only on
    /// the polling cadence. This closes the interval between a password field
    /// gaining focus and the next scheduled timer tick.
    var isContentShielded: Bool {
        !resolveEffectiveProtection(notifyOnChange: false).isEmpty
    }

    var activeProtection: ClipboardHistoryProtection {
        resolveEffectiveProtection(notifyOnChange: false)
    }
    var storedByteCount: Int { totalBytes }
    var itemCount: Int { storedItems.count }
    var hasScheduledPolling: Bool { timer != nil }

    var isCaptureEligible: Bool {
        started
            && captureState.workbenchVisible
            && captureState.railEnabled
            && !isContentShielded
    }

    /// Safe UI projection. Protected content stays in process memory but never
    /// crosses into a view hierarchy while the protection gate is active.
    var items: [ClipboardHistoryItem] {
        isContentShielded ? [] : storedItems
    }

    var visibleItems: [ClipboardHistoryItem] { items }

    var selectedItem: ClipboardHistoryItem? {
        guard !isContentShielded, let selectedID else { return nil }
        return storedItems.first { $0.id == selectedID }
    }

    func start() {
        guard !started else {
            reconcilePolling()
            return
        }
        started = true
        needsPasteboardBaseline = true
        reconcilePolling()
        notifyObservers()
    }

    /// Stops all observation without clearing the in-memory history. A later
    /// start establishes a fresh change-count baseline before any text read.
    func stop() {
        guard started || timer != nil else { return }
        started = false
        invalidateTimer()
        needsPasteboardBaseline = true
        notifyObservers()
    }

    func update(_ state: ClipboardHistoryCaptureState) {
        let oldNominalEligibility = captureState.allowsClipboardObservation
        guard state != captureState else {
            reconcilePolling()
            return
        }
        captureState = state
        if oldNominalEligibility != state.allowsClipboardObservation {
            needsPasteboardBaseline = true
        }
        reconcilePolling()
        notifyObservers()
    }

    func update(workbenchVisible: Bool,
                railEnabled: Bool,
                protection: ClipboardHistoryProtection) {
        update(ClipboardHistoryCaptureState(
            workbenchVisible: workbenchVisible,
            railEnabled: railEnabled,
            protection: protection
        ))
    }

    @discardableResult
    func addObserver(_ observer: @escaping Observer) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    @discardableResult
    func select(id: UUID) -> Bool {
        guard !isContentShielded,
              storedItems.contains(where: { $0.id == id }) else { return false }
        guard selectedID != id else { return true }
        selectedID = id
        notifyObservers()
        return true
    }

    @discardableResult
    func moveSelection(delta: Int) -> Bool {
        guard !isContentShielded, !storedItems.isEmpty, delta != 0 else { return false }
        let current = selectedID.flatMap { id in storedItems.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, current + delta), storedItems.count - 1)
        guard next != current else { return true }
        selectedID = storedItems[next].id
        notifyObservers()
        return true
    }

    @discardableResult
    func deleteSelected() -> Bool {
        guard !isContentShielded,
              let selectedID,
              let index = storedItems.firstIndex(where: { $0.id == selectedID }) else {
            return false
        }
        return removeItem(at: index, selectionNeighborIndex: index)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard !isContentShielded,
              let index = storedItems.firstIndex(where: { $0.id == id }) else {
            return false
        }
        return removeItem(at: index, selectionNeighborIndex: index)
    }

    func clear() {
        guard !storedItems.isEmpty || selectedID != nil else { return }
        storedItems.removeAll(keepingCapacity: false)
        selectedID = nil
        totalBytes = 0
        notifyObservers()
    }

    /// Moves an activated item to the front without changing its identity.
    @discardableResult
    func promote(id: UUID) -> Bool {
        guard !isContentShielded,
              let index = storedItems.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let item = storedItems.remove(at: index)
        storedItems.insert(item, at: 0)
        selectedID = item.id
        notifyObservers()
        return true
    }

    /// Test seam and timer target. It never reads the pasteboard when any
    /// visibility, enablement, or protection gate is closed.
    @discardableResult
    func pollNow() -> Bool {
        guard started, captureState.workbenchVisible, captureState.railEnabled else {
            needsPasteboardBaseline = true
            return false
        }

        let protection = resolveEffectiveProtection(notifyOnChange: true)
        guard protection.isEmpty else {
            needsPasteboardBaseline = true
            return false
        }

        if needsPasteboardBaseline {
            lastObservedPasteboardChangeCount = pasteboard.changeCount
            needsPasteboardBaseline = false
            return false
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedPasteboardChangeCount else { return false }
        lastObservedPasteboardChangeCount = changeCount

        // Re-check the live Secure Input probe immediately before asking a
        // potentially lazy pasteboard provider for its string payload.
        guard resolveEffectiveProtection(notifyOnChange: true).isEmpty else {
            needsPasteboardBaseline = true
            return false
        }
        guard let text = pasteboard.readPlainText() else { return false }

        // A protection transition during the synchronous provider read must
        // discard the result before it reaches history or a view.
        guard resolveEffectiveProtection(notifyOnChange: true).isEmpty,
              captureState.workbenchVisible,
              captureState.railEnabled else {
            needsPasteboardBaseline = true
            return false
        }
        return ingest(text)
    }

    /// Internal deterministic seam used by the standalone model/view smoke.
    @discardableResult
    func ingest(_ text: String) -> Bool {
        guard !isContentShielded,
              !text.isEmpty,
              !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount > 0,
              byteCount <= configuration.maximumItemBytes,
              byteCount <= configuration.maximumTotalBytes else {
            return false
        }

        if let existingIndex = storedItems.firstIndex(where: { $0.text == text }) {
            let existing = storedItems.remove(at: existingIndex)
            let promoted = ClipboardHistoryItem(
                id: existing.id,
                text: existing.text,
                byteCount: existing.byteCount,
                capturedAt: clock()
            )
            storedItems.insert(promoted, at: 0)
            selectedID = promoted.id
            trimToBounds()
            notifyObservers()
            return true
        }

        let item = ClipboardHistoryItem(
            id: UUID(),
            text: text,
            byteCount: byteCount,
            capturedAt: clock()
        )
        storedItems.insert(item, at: 0)
        totalBytes += byteCount
        selectedID = item.id
        trimToBounds()
        notifyObservers()
        return storedItems.contains { $0.id == item.id }
    }

    private func reconcilePolling() {
        let nominallyEligible = started
            && captureState.workbenchVisible
            && captureState.railEnabled

        guard nominallyEligible, captureState.protection.isEmpty else {
            invalidateTimer()
            needsPasteboardBaseline = true
            _ = resolveEffectiveProtection(notifyOnChange: true)
            return
        }

        let protection = resolveEffectiveProtection(notifyOnChange: true)
        if protection.isEmpty, needsPasteboardBaseline {
            // Baseline only: never import content that appeared while capture
            // was stopped, hidden, disabled, locked, or protected.
            lastObservedPasteboardChangeCount = pasteboard.changeCount
            needsPasteboardBaseline = false
        }

        guard schedulesAutomaticPolling, timer == nil else { return }
        let timer = Timer(timeInterval: configuration.pollingInterval,
                          repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = self?.pollNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    private func resolveEffectiveProtection(notifyOnChange: Bool) -> ClipboardHistoryProtection {
        let resolved = captureState.protection.union(protectionProbe())
        guard resolved != effectiveProtection else { return resolved }
        effectiveProtection = resolved
        if !resolved.isEmpty {
            needsPasteboardBaseline = true
        }
        if notifyOnChange {
            notifyObservers()
        }
        return resolved
    }

    private func trimToBounds() {
        while storedItems.count > configuration.maximumItems
                || totalBytes > configuration.maximumTotalBytes {
            guard let removed = storedItems.popLast() else { break }
            totalBytes -= removed.byteCount
        }
        totalBytes = max(0, totalBytes)
        if let selectedID, !storedItems.contains(where: { $0.id == selectedID }) {
            self.selectedID = storedItems.first?.id
        }
    }

    @discardableResult
    private func removeItem(at index: Int, selectionNeighborIndex: Int) -> Bool {
        guard storedItems.indices.contains(index) else { return false }
        let removed = storedItems.remove(at: index)
        totalBytes = max(0, totalBytes - removed.byteCount)
        if selectedID == removed.id {
            let neighborIndex = min(selectionNeighborIndex, storedItems.count - 1)
            selectedID = neighborIndex >= 0 ? storedItems[neighborIndex].id : nil
        }
        notifyObservers()
        return true
    }

    private func notifyObservers() {
        let callbacks = Array(observers.values)
        callbacks.forEach { $0() }
    }
}
