import UIKit

struct RepeatingPress {
    static let delay: TimeInterval = 0.4
    static let interval: TimeInterval = 0.075
    private(set) var next: TimeInterval?
    mutating func begin(at time: TimeInterval) { next = time + Self.delay }
    mutating func cancel() { next = nil }
    mutating func advance(to time: TimeInterval) -> Bool {
        guard let next, time >= next else { return false }
        // No catch-up burst after a busy main run loop.
        self.next = time + Self.interval; return true
    }
}

final class RepeatKeycapButton: KeycapButton {
    var onPressBegan: (() -> Bool)?
    var onDelete: (() -> Bool)?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var press = RepeatingPress()
    private var timer: Timer?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        addAction(UIAction { [weak self] _ in self?.beginPress() }, for: .touchDown)
        addAction(UIAction { [weak self] _ in self?.cancelPress() }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isEnabled: Bool { didSet { if !isEnabled { cancelPress() } } }
    func beginPress() {
        cancelPress()
        guard isEnabled, onPressBegan?() == true else { return }
        isHighlighted = true
        press.begin(at: clock())
        guard onDelete?() == true, press.next != nil else { cancelPress(); return }
        schedule()
    }
    func cancelPress() { timer?.invalidate(); timer = nil; press.cancel(); isHighlighted = false }
    func advance() {
        guard isEnabled, press.advance(to: clock()) else { return }
        if onDelete?() != true { cancelPress() }
    }
    private func schedule() {
        guard let next = press.next else { return }
        let timer = Timer(timeInterval: max(0.001, next - clock()), repeats: false) { [weak self] _ in
            guard let self else { return }; self.advance(); self.schedule()
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard bounds.contains(touch.location(in: self)) else { cancelPress(); return false }
        return super.continueTracking(touch, with: event)
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { cancelPress(); super.endTracking(touch, with: event) }
    override func cancelTracking(with event: UIEvent?) { cancelPress(); super.cancelTracking(with: event) }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelPress() } }
    override func accessibilityActivate() -> Bool {
        guard isEnabled, onPressBegan?() == true else { return false }
        let deleted = onDelete?() == true; cancelPress(); return deleted
    }
}
