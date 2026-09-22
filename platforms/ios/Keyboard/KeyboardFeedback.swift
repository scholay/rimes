import UIKit
import RimesCore

@MainActor final class KeyboardFeedback {
    var enabled = true
    var strength: HapticStrength = .light
    private let strong = UIImpactFeedbackGenerator(style: .medium)
    private let strongest = UIImpactFeedbackGenerator(style: .heavy)
    private let press = UIImpactFeedbackGenerator(style: .light)
    private let selection = UISelectionFeedbackGenerator()
    private let commit = UIImpactFeedbackGenerator(style: .medium)
    private var gate = FeedbackGate()
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    #if DEBUG
    var onFeedback: ((KeyFeedback) -> Void)?
    #endif
    func reset() { gate.reset() }
    func send(_ event: KeyFeedback, combination: String? = nil) {
        guard enabled, gate.accept(event, combination: combination, at: clock()) else { return }
        #if DEBUG
        onFeedback?(event)
        #endif
        if strength != .light {
            let generator = strength == .strong ? strong : strongest
            generator.prepare(); generator.impactOccurred(intensity: strength == .strong ? 0.85 : 1)
            return
        }
        switch event {
        case .press: press.prepare(); press.impactOccurred(intensity: 0.55)
        case .selection: selection.prepare(); selection.selectionChanged()
        case .commit: commit.prepare(); commit.impactOccurred(intensity: 0.65)
        }
    }
}
