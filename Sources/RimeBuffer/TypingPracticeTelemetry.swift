import AppKit
import Carbon.HIToolbox

protocol TypingPracticeTelemetrySink: AnyObject {
    func practiceKey(_ event: NSEvent, isComposing: Bool)
    func practiceChord(schemaID: String)
    func practiceBackspaceBecameComposition()
}

/// Scoped to the explicitly armed, first-responder practice editor. This is
/// not a global keyboard monitor and carries neither text nor an IMK proxy.
/// The local monitor sees physical events before an IME consumes them; IMK
/// observations are deduplicated fallbacks and the source of actual batches.
final class TypingPracticeTelemetry {
    static let shared = TypingPracticeTelemetry()
    private weak var textView: NSTextView?
    private weak var sink: (any TypingPracticeTelemetrySink)?
    private var localMonitor: Any?
    private var ledger = KeyLedger()
    private var imkOwner: ObjectIdentifier?

    struct KeyIdentity: Hashable {
        let timestamp: TimeInterval
        let keyCode: UInt16
        let isRepeat: Bool
        init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
            isRepeat = event.isARepeat
        }
    }

    struct KeyLedger {
        enum Decision { case record, duplicate, upgradeBackspace }
        private var recent: [KeyIdentity] = []
        private var composing: Set<KeyIdentity> = []

        mutating func admit(_ identity: KeyIdentity, isComposing: Bool,
                            authoritative: Bool) -> Decision {
            if recent.contains(identity) {
                if authoritative, identity.keyCode == 51, isComposing,
                   composing.insert(identity).inserted { return .upgradeBackspace }
                return .duplicate
            }
            recent.append(identity)
            if isComposing { composing.insert(identity) }
            if recent.count > 64 { composing.remove(recent.removeFirst()) }
            return .record
        }
    }

    /// Also excludes the finishing commit after the editor's sink disarms.
    static var isPracticeInputFocused: Bool {
        NSApp?.keyWindow?.firstResponder is TypingTestTextView
    }

    func activate(textView: NSTextView, sink: any TypingPracticeTelemetrySink) {
        precondition(Thread.isMainThread)
        stop()
        self.textView = textView
        self.sink = sink
        TypingSpeedStore.shared.endCurrentSession()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, let view = self.textView,
               event.window === view.window {
                self.noteLocalKey(event, textView: view)
            }
            return event
        }
    }

    func deactivate(textView: NSTextView) {
        guard self.textView === textView else { return }
        stop()
    }

    private func stop() {
        if textView != nil { TypingSpeedStore.shared.endCurrentSession() }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        textView = nil
        sink = nil
        ledger = KeyLedger()
        imkOwner = nil
    }

    private var eligibleEditor: NSTextView? {
        guard Thread.isMainThread, !IsSecureEventInputEnabled(),
              let textView, sink != nil,
              let window = textView.window, window.isKeyWindow, window.isVisible,
              window.firstResponder === textView, textView.isEditable,
              !textView.isHiddenOrHasHiddenAncestor else { return nil }
        return textView
    }

    func noteLocalKey(_ event: NSEvent, textView: NSTextView) {
        guard eligibleEditor === textView else { return }
        receive(event, isComposing: textView.hasMarkedText())
    }

    /// Called only after the controller has checked its exact live own-client
    /// lease. No client reference or text crosses this boundary.
    func noteIMEKey(_ event: NSEvent, isComposing: Bool, owner: ObjectIdentifier) {
        guard eligibleEditor != nil else { return }
        imkOwner = owner
        receive(event, isComposing: isComposing, authoritative: true)
    }

    func noteIMEChord(schemaID: String, owner: ObjectIdentifier) {
        guard eligibleEditor != nil, imkOwner == owner else { return }
        sink?.practiceChord(schemaID: schemaID)
    }

    private func receive(_ event: NSEvent, isComposing: Bool, authoritative: Bool = false) {
        guard Self.countsKey(event) else { return }
        switch ledger.admit(KeyIdentity(event), isComposing: isComposing,
                            authoritative: authoritative) {
        case .record: sink?.practiceKey(event, isComposing: isComposing)
        case .upgradeBackspace: sink?.practiceBackspaceBecameComposition()
        case .duplicate: break
        }
    }

    static func countsKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !KeyboardLayout.isModifierKey(event.keyCode) else { return false }
        // Navigation, Escape and function keys change state, not text. OEM
        // ISO/JIS printable keys still count even outside our heatmap layout.
        let controls: Set<UInt16> = [53, 123, 124, 125, 126, 115, 119, 116, 121,
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107,
            113, 106, 64, 79, 80, 90]
        if controls.contains(event.keyCode) { return false }
        if [UInt16(36), 48, 49, 51, 76, 117].contains(event.keyCode) { return true }
        if KeyboardLayout.keyId(forKeyCode: event.keyCode) != nil { return true }
        return event.characters?.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        } ?? false
    }
}

func runTypingPracticeTelemetrySmokeTest() -> Bool {
    func counts(_ code: UInt16, characters: String = "",
                modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: modifiers, timestamp: 1,
                                          windowNumber: 0, context: nil,
                                          characters: characters,
                                          charactersIgnoringModifiers: characters,
                                          isARepeat: false, keyCode: code) else { return false }
        return TypingPracticeTelemetry.countsKey(event)
    }
    guard counts(0, characters: "a"), counts(0, characters: "A", modifiers: .shift),
          counts(10, characters: "§"), counts(93, characters: "¥"),
          counts(51), counts(117), counts(49, characters: " "),
          !counts(0, characters: "a", modifiers: .command),
          !counts(0, characters: "a", modifiers: .control),
          !counts(0, characters: "å", modifiers: .option),
          !counts(56), !counts(123), !counts(53), !counts(122),
          !counts(255, characters: "\u{F700}") else { return false }
    func identity(_ code: UInt16, at time: TimeInterval, repeatKey: Bool = false)
        -> TypingPracticeTelemetry.KeyIdentity {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: time, windowNumber: 0, context: nil,
                                    characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: repeatKey, keyCode: code)!
        return .init(event)
    }
    var ledger = TypingPracticeTelemetry.KeyLedger()
    let backspace = identity(51, at: 1)
    guard ledger.admit(backspace, isComposing: false, authoritative: false) == .record,
          ledger.admit(backspace, isComposing: true, authoritative: true) == .upgradeBackspace,
          ledger.admit(backspace, isComposing: true, authoritative: true) == .duplicate,
          ledger.admit(backspace, isComposing: false, authoritative: false) == .duplicate else { return false }
    let ordinary = identity(0, at: 2)
    guard ledger.admit(ordinary, isComposing: false, authoritative: true) == .record,
          ledger.admit(ordinary, isComposing: false, authoritative: false) == .duplicate,
          ledger.admit(identity(51, at: 3, repeatKey: true), isComposing: true,
                       authoritative: false) == .record else { return false }
    print("typing practice telemetry smoke OK")
    return true
}
