import UIKit
import RimesCore

final class KeySurface: UIView {
    let feedback = KeyboardFeedback()
    private var reachable = ChordReachability(profile: .builtIn)
    var onTypingPress: (() -> Void)?
    var onKey: ((String) -> Void)?
    var onChord: ((ChordResolution?) -> Void)?
    var onPreview: ((String) -> Void)?
    var onEmoji: ((String) -> Void)?
    var onLanguageToggle: (() -> Void)?
    var profile = ChordProfile.builtIn { didSet { if oldValue != profile { reachable = ChordReachability(profile: profile) }; retire(); setNeedsLayout() } }
    var chordMode = false { didSet { retire(); setNeedsLayout() } }
    var numeric = false { didSet { retire(); setNeedsLayout() } }
    var shifted = false { didSet { if oldValue != shifted { retire() }; setNeedsDisplay() } }
    var englishInput = false { didSet { if oldValue != englishInput { retire() }; updateLanguageButton() } }
    var chordLayout: ChordLayout = .orthogonal { didSet { if oldValue != chordLayout { retire(); setNeedsLayout() } } }
    var resolvesChords: Bool { chordMode && !numeric && !emojiMode && !shifted && !englishInput }
    var hasUtilityCells: Bool { chordMode && !numeric }
    var onModeChanged: (() -> Void)?
    private(set) var emojiMode = false { didSet { cancel(); setNeedsLayout(); if oldValue != emojiMode { onModeChanged?() } } }
    private let emojiButton = UtilityKeycapButton(), languageButton = UtilityKeycapButton(), backButton = UtilityKeycapButton()
    private var emojiButtons: [UtilityKeycapButton] = []
    private var utilityGeneration = UUID()
    private var boxes: [(String, CGRect)] = []
    private var gesture = ChordGesture()
    var isChordActive: Bool { resolvesChords && gesture.active }
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var ordinary: [ObjectIdentifier: String] = [:]
    override init(frame: CGRect) {
        super.init(frame: frame); isMultipleTouchEnabled = true; backgroundColor = .clear
        accessibilityLabel = L("字母键盘", "Letter keyboard")
        emojiButton.symbol("face.smiling", label: L("表情", "Emoji"))
        emojiButton.accessibilityIdentifier = "keyboard.emoji"
        languageButton.accessibilityIdentifier = "keyboard.mode"
        languageButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        installUtility(emojiButton) { [weak self] in self?.emojiMode = true }
        installUtility(languageButton) { [weak self] in self?.onLanguageToggle?() }
        backButton.symbol("arrow.uturn.backward", label: L("返回字母键盘", "Back to letters"))
        backButton.accessibilityIdentifier = "keyboard.emoji.back"
        let emojis = ["😀", "😄", "😂", "🥹", "😊", "😍", "😘", "😎", "🤔", "😅",
                      "😭", "🥲", "😮", "😴", "😡", "🥳", "👍", "👎", "👏", "🙏",
                      "👋", "👌", "💪", "❤️", "💔", "🔥", "🎉", "✅", "🌹"]
        for (index, emoji) in emojis.enumerated() {
            let button = UtilityKeycapButton(); button.setTitle(emoji, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 21)
            button.accessibilityIdentifier = "keyboard.emoji.preset.\(index)"
            installUtility(button) { [weak self] in self?.onEmoji?(emoji) }
            button.titleHorizontalInset = 0.5
            emojiButtons.append(button)
        }
        installUtility(backButton) { [weak self] in self?.emojiMode = false }
        updateLanguageButton()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func installUtility(_ button: UtilityKeycapButton, action: @escaping () -> Void) {
        addSubview(button); button.isHidden = true; button.isExclusiveTouch = true; button.titleHorizontalInset = 2
        // A utility tap cannot change mode in the middle of a two-thumb chord.
        // Sliding onto a utility preserves the last letter endpoint and never
        // activates that utility; only a fresh tap may invoke it.
        var beganIn: UUID?
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            beganIn = self.touchIDs.isEmpty && !self.gesture.active && self.ordinary.isEmpty ? self.utilityGeneration : nil
            if beganIn != nil { self.feedback.send(.press) }
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            defer { beganIn = nil }
            guard let self, beganIn == self.utilityGeneration, !self.gesture.active, self.touchIDs.isEmpty else { return }
            action()
        }, for: .touchUpInside)
        button.addAction(UIAction { _ in beganIn = nil }, for: [.touchCancel, .touchUpOutside])
        button.onAccessibilityActivate = { [weak self, weak button] in
            guard let self, button?.isHidden == false, !self.gesture.active, self.touchIDs.isEmpty else { return false }
            self.feedback.send(.press); action(); return true
        }
    }
    private func updateLanguageButton() {
        languageButton.setTitle(englishInput ? "EN" : "中", for: .normal)
        languageButton.isSelected = englishInput
        languageButton.accessibilityLabel = englishInput ? L("英文，切换中文", "English; switch to Chinese") : L("中文，切换英文", "Chinese; switch to English")
    }
    func showEmoji() { retire(); emojiMode = true }

    private func redraw() {
        let dimmed = resolvesChords && gesture.active
        [emojiButton, languageButton].forEach { $0.alpha = dimmed ? 0.3 : 1 }
        setNeedsDisplay()
    }
    func cancel() { utilityGeneration = UUID(); feedback.reset(); gesture.cancel(); ordinary.removeAll(); onPreview?(""); redraw() }
    /// Context loss may never deliver matching touch-up events. Retire old IDs so
    /// late callbacks cannot commit and a fresh keyboard session is not stuck.
    func retire() { feedback.reset(); gesture.reset(); touchIDs.removeAll(); ordinary.removeAll(); emojiMode = false; onPreview?(""); redraw() }
    override func layoutSubviews() {
        super.layoutSubviews(); boxes.removeAll()
        let rowHeight = bounds.height / 3
        let utilitiesVisible = hasUtilityCells && !emojiMode
        emojiButton.isHidden = !utilitiesVisible; languageButton.isHidden = !utilitiesVisible
        (emojiButtons + [backButton]).forEach { $0.isHidden = !emojiMode }
        if emojiMode {
            let unit = bounds.width / 10
            for (index, button) in (emojiButtons + [backButton]).enumerated() {
                button.frame = CGRect(x: CGFloat(index % 10) * unit + 2, y: CGFloat(index / 10) * rowHeight + 3, width: unit - 4, height: rowHeight - 6)
            }
        } else {
            let geometry = KeyboardGeometry.make(size: bounds.size, profile: profile, chord: chordMode, numeric: numeric, layout: chordLayout)
            boxes = geometry.keys
            emojiButton.isHidden = geometry.emoji == nil; languageButton.isHidden = geometry.language == nil
            emojiButton.frame = geometry.emoji ?? .zero; languageButton.frame = geometry.language ?? .zero
            emojiButton.compactCap = chordMode && !numeric; languageButton.compactCap = chordMode && !numeric
        }
        let letters: [Any] = boxes.map { key, rect in
            let item = KeyAccessibility(accessibilityContainer: self); item.accessibilityLabel = key.uppercased(); item.accessibilityTraits = .keyboardKey; item.accessibilityFrameInContainerSpace = rect
            item.activate = { [weak self] in guard let self else { return }; self.onTypingPress?(); self.feedback.send(.press); self.onKey?(self.shifted && !self.numeric ? key.uppercased() : key) }; return item
        }
        accessibilityElements = letters + ([emojiButton, languageButton] + emojiButtons + [backButton]).filter { !$0.isHidden }
        redraw()
    }
    override func draw(_ rect: CGRect) {
        let selected = gesture.keys ?? []
        let eligible = gesture.availableKeys(in: reachable)
        for (key, box) in boxes {
            let active = (key.first.map(selected.contains) ?? false) || ordinary.values.contains(key)
            let dimmed = resolvesChords && gesture.active && !active && !(key.first.map(eligible.contains) ?? false)
            let context = UIGraphicsGetCurrentContext()!
            context.saveGState(); context.setAlpha(dimmed ? 0.30 : 1)
            let cap = KeycapStyle.capRect(in: box, pressed: active, compact: chordMode && !numeric)
            KeycapStyle.draw(in: box, pressed: active, compact: chordMode && !numeric)
            let value = key.uppercased()
            let font = UIFont.monospacedSystemFont(ofSize: 21, weight: .medium)
            let fittedFont = font.withSize(min(21, max(1, floor(21 * cap.height / font.lineHeight))))
            let attr: [NSAttributedString.Key: Any] = [.font: fittedFont, .foregroundColor: active ? UIColor.white : UIColor.label]
            let size = value.size(withAttributes: attr)
            value.draw(at: CGPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2), withAttributes: attr)
            context.restoreGState()
        }
    }
    private func key(at point: CGPoint) -> String? { boxes.first { $0.1.contains(point) }?.0 }
    private func preview() {
        onPreview?(gesture.resolution(in: profile)?.preview ?? "")
        feedback.send(.selection, combination: gesture.resolution(in: profile)?.keys)
        redraw()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !emojiMode else { return }
        utilityGeneration = UUID()
        for t in touches {
            // Mapping captions and blank areas never start or poison a chord.
            guard let key = key(at: t.location(in: self)) else { continue }
            let oid = ObjectIdentifier(t)
            onTypingPress?(); feedback.send(.press)
            if resolvesChords {
                nextID += 1; touchIDs[oid] = nextID; gesture.begin(id: nextID, key: key.first, profile: profile)
            }
            else { ordinary[oid] = key }
        }
        if resolvesChords { preview() }; redraw()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard resolvesChords else { return }
        for t in touches { if let id = touchIDs[ObjectIdentifier(t)] { gesture.move(id: id, key: key(at: t.location(in: self))?.first, profile: profile) } }
        preview()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let oid = ObjectIdentifier(t), key = key(at: t.location(in: self))
            if let id = touchIDs.removeValue(forKey: oid) {
                let result = gesture.end(id: id, key: key?.first, profile: profile)
                if !gesture.active { if result != nil { feedback.send(.commit) }; feedback.reset(); onChord?(result); onPreview?("") }
            } else if let original = ordinary.removeValue(forKey: oid), key == original { onKey?(shifted && !numeric ? original.uppercased() : original) }
        }
        redraw()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        gesture.cancel()
        for t in touches { let oid = ObjectIdentifier(t); if let id = touchIDs.removeValue(forKey: oid) { _ = gesture.end(id: id, key: nil, profile: profile) }; ordinary.removeValue(forKey: oid) }
        onPreview?(""); redraw()
    }
    #if DEBUG
    var developmentKeyFrames: [String: CGRect] {
        var frames = Dictionary(uniqueKeysWithValues: boxes)
        if !emojiButton.isHidden { frames["emoji"] = emojiButton.frame; frames["mode"] = languageButton.frame }
        return frames
    }
    func developmentKey(at point: CGPoint) -> String? { key(at: point) }
    func developmentPress(_ start: Character, end: Character, id: Int = 900) {
        gesture.begin(id: id, key: start, profile: profile)
        gesture.move(id: id, key: end, profile: profile); preview()
    }
    func developmentMove(_ key: Character?, id: Int = 900) {
        gesture.move(id: id, key: key, profile: profile); preview()
    }
    #endif

}
private final class UtilityKeycapButton: KeycapButton {
    var onAccessibilityActivate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { onAccessibilityActivate?() ?? false }
}
private final class KeyAccessibility: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}
