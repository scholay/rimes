import UIKit

/// One cap geometry/palette for drawn letters and UIKit-backed controls.
enum KeycapStyle {
    static func capRect(in rect: CGRect, pressed: Bool, compact: Bool = false) -> CGRect {
        rect.insetBy(dx: compact ? 0 : 0.5, dy: compact ? 0.75 : 1.5).offsetBy(dx: 0, dy: pressed ? (compact ? 0.75 : 1.5) : (compact ? -0.25 : -0.5))
    }
    static func draw(in rect: CGRect, pressed: Bool, selected: Bool = false, enabled: Bool = true, compact: Bool = false) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        if !enabled { context.setAlpha(0.4) }
        let base = UIBezierPath(roundedRect: rect.insetBy(dx: compact ? 0 : 0.5, dy: compact ? 0.75 : 1.5).offsetBy(dx: 0, dy: compact ? 0.75 : 1.5), cornerRadius: compact ? 3 : 6)
        context.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1, color: UIColor.black.withAlphaComponent(0.12).cgColor)
        UIColor.separator.setFill(); base.fill()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        let cap = UIBezierPath(roundedRect: capRect(in: rect, pressed: pressed, compact: compact), cornerRadius: compact ? 3 : 6)
        (pressed || selected ? UIColor.systemTeal : UIColor.secondarySystemGroupedBackground).setFill(); cap.fill()
        UIColor.label.withAlphaComponent(pressed || selected ? 0.15 : 0.10).setStroke()
        cap.lineWidth = 0.7; cap.stroke()
        context.restoreGState()
    }
}

class KeycapButton: UIButton {
    var compactCap = false { didSet { setNeedsDisplay(); setNeedsLayout() } }
    var titleHorizontalInset: CGFloat = 6 { didSet { setNeedsLayout() } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw
        titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.textAlignment = .center
        setTitleColor(.label, for: .normal)
        setTitleColor(.white, for: .highlighted)
        setTitleColor(.white, for: .selected)
        setTitleColor(.label.withAlphaComponent(0.4), for: .disabled)
        setPreferredSymbolConfiguration(.init(pointSize: 17, weight: .medium), forImageIn: .normal)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: KeycapButton, _: UITraitCollection) in button.updateAppearance() }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool { didSet { updateAppearance() } }
    private func updateAppearance() {
        tintColor = !isEnabled ? .label.withAlphaComponent(0.4) : isHighlighted || isSelected ? .white : .label
        setNeedsDisplay(); setNeedsLayout()
    }
    override func draw(_ rect: CGRect) {
        KeycapStyle.draw(in: bounds, pressed: isHighlighted, selected: isSelected, enabled: isEnabled, compact: compactCap)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let cap = KeycapStyle.capRect(in: bounds, pressed: isHighlighted, compact: compactCap)
        let textHeight = min(cap.height, ceil(titleLabel?.font.lineHeight ?? 0))
        titleLabel?.frame = CGRect(x: titleHorizontalInset, y: cap.midY - textHeight / 2, width: max(0, bounds.width - 2 * titleHorizontalInset), height: textHeight)
        if let imageView, let image = imageView.image {
            let size = CGSize(width: min(image.size.width, cap.width - 8), height: min(image.size.height, cap.height - 6))
            imageView.frame = CGRect(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2, width: size.width, height: size.height)
        }
    }
    func symbol(_ name: String, label: String) {
        setTitle(nil, for: .normal); setImage(UIImage(systemName: name), for: .normal)
        accessibilityLabel = label
    }
}

/// Time-based state is shared by real touch tracking and deterministic tests.
struct InsertionPress {
    enum Action: Equatable { case next, all }
    static let holdDuration: TimeInterval = 1
    private var beganAt: TimeInterval?
    private var fired = false
    mutating func begin(at time: TimeInterval) { beganAt = time; fired = false }
    mutating func cancel() { beganAt = nil; fired = false }
    mutating func advance(to time: TimeInterval) -> Action? {
        guard let beganAt, !fired, time - beganAt >= Self.holdDuration else { return nil }
        fired = true; return .all
    }
    mutating func end(at time: TimeInterval, inside: Bool) -> Action? {
        defer { cancel() }
        guard let beganAt, !fired, inside else { return nil }
        return time - beganAt >= Self.holdDuration ? .all : .next
    }
}

final class InsertKeycapButton: KeycapButton {
    var onPressBegan: (() -> Void)?
    var onInsert: ((InsertionPress.Action) -> Void)?
    private var press = InsertionPress()
    private var holdTimer: Timer?
    private var deadline: TimeInterval = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: L("插入全部", "Insert all"), target: self, selector: #selector(accessibilityInsertAll))]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isEnabled: Bool { didSet { if !isEnabled { cancelPress() } } }
    func cancelPress() { holdTimer?.invalidate(); holdTimer = nil; press.cancel(); isHighlighted = false }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard super.beginTracking(touch, with: event) else { return false }
        onPressBegan?()
        let now = ProcessInfo.processInfo.systemUptime
        press.begin(at: now); deadline = now + InsertionPress.holdDuration
        scheduleHold(); return true
    }
    private func scheduleHold() {
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
            guard let self else { return }
            if let action = self.press.advance(to: ProcessInfo.processInfo.systemUptime) { self.onInsert?(action) }
            else if self.isTracking && self.isEnabled { self.scheduleHold() }
        }
        holdTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard bounds.contains(touch.location(in: self)) else { cancelPress(); return false }
        return super.continueTracking(touch, with: event)
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        holdTimer?.invalidate(); holdTimer = nil
        let action = press.end(at: ProcessInfo.processInfo.systemUptime, inside: touch.map { bounds.contains($0.location(in: self)) } ?? false)
        super.endTracking(touch, with: event)
        if let action { onInsert?(action) }
    }
    override func cancelTracking(with event: UIEvent?) { cancelPress(); super.cancelTracking(with: event) }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelPress() } }
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }; onPressBegan?(); onInsert?(.next); return true
    }
    @objc private func accessibilityInsertAll() -> Bool {
        guard isEnabled else { return false }; onPressBegan?(); onInsert?(.all); return true
    }
}
