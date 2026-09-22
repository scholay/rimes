import UIKit
import RimesCore

final class KeySurface: UIView {
    var onKey: ((String) -> Void)?
    var onChord: ((ChordResolution?) -> Void)?
    var onPreview: ((String) -> Void)?
    var profile = ChordProfile.builtIn { didSet { retire() } }
    var chordMode = false { didSet { retire(); setNeedsLayout() } }
    var numeric = false { didSet { retire(); setNeedsLayout() } }
    var shifted = false { didSet { setNeedsDisplay() } }
    private var boxes: [(String, CGRect)] = []
    private var gesture = ChordGesture()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var ordinary: [ObjectIdentifier: String] = [:]
    override init(frame: CGRect) {
        super.init(frame: frame); isMultipleTouchEnabled = true; backgroundColor = .clear
        accessibilityLabel = L("字母键盘", "Letter keyboard")
    }
    required init?(coder: NSCoder) { fatalError() }
    func cancel() { gesture.cancel(); ordinary.removeAll(); onPreview?(""); setNeedsDisplay() }
    /// Context loss may never deliver matching touch-up events. Retire old IDs so
    /// late callbacks cannot commit and a fresh keyboard session is not stuck.
    func retire() { gesture.reset(); touchIDs.removeAll(); ordinary.removeAll(); onPreview?(""); setNeedsDisplay() }
    override func layoutSubviews() {
        super.layoutSubviews(); boxes.removeAll()
        let rowHeight = bounds.height / 3
        if chordMode && !numeric {
            let w = (bounds.width - 14) / 2
            for (side, keys) in [profile.leftKeys, profile.rightKeys].enumerated() {
                let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm,."].map { row in row.filter { keys.contains($0) }.map(String.init) }
                for (r, row) in rows.enumerated() {
                    let columns = CGFloat(max(5, row.count))
                    for (c, key) in row.enumerated() { boxes.append((key, CGRect(x: CGFloat(side) * (w + 14) + CGFloat(c) * w / columns + 2, y: CGFloat(r) * rowHeight + 3, width: w / columns - 4, height: rowHeight - 6))) }
                }
            }
        } else {
            let rows = numeric ? [Array("1234567890"), Array("-/:;()$&@\""), Array(".,?!'[]#%")] : [Array("qwertyuiop"), Array("asdfghjkl"), Array("zxcvbnm,.")]
            let unit = bounds.width / 10
            for (r,row) in rows.enumerated() {
                let inset = (bounds.width - CGFloat(row.count) * unit) / 2
                for (c,key) in row.enumerated() { boxes.append((String(key), CGRect(x: inset + CGFloat(c) * unit + 2, y: CGFloat(r) * rowHeight + 3, width: unit - 4, height: rowHeight - 6))) }
            }
        }
        accessibilityElements = boxes.map { key, rect in
            let item = KeyAccessibility(accessibilityContainer: self); item.accessibilityLabel = key; item.accessibilityTraits = .keyboardKey; item.accessibilityFrameInContainerSpace = rect
            item.activate = { [weak self] in self?.onKey?(key) }; return item
        }
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        let selected = gesture.keys ?? []
        for (key, box) in boxes {
            let active = key.first.map(selected.contains) ?? false
            (active ? UIColor.systemTeal : UIColor.secondarySystemGroupedBackground).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 7).fill()
            let value = shifted && !numeric && !chordMode ? key.uppercased() : key
            let attr: [NSAttributedString.Key: Any] = [.font:UIFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor:active ? UIColor.white : UIColor.label]
            let size = value.size(withAttributes: attr)
            value.draw(at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attr)
        }
    }
    private func key(at point: CGPoint) -> String? { boxes.first { $0.1.contains(point) }?.0 }
    private func preview() {
        if let keys = gesture.keys { onPreview?(profile.canonical(keys).uppercased() + "  →  " + (profile.resolve(keys)?.preview ?? L("无映射", "No mapping"))) }
        else { onPreview?(gesture.cancelled ? L("已取消", "Cancelled") : L("滑回本区选择字母", "Slide back to a letter")) }
        setNeedsDisplay()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let oid = ObjectIdentifier(t); let key = key(at: t.location(in: self))
            if chordMode && !numeric { nextID += 1; touchIDs[oid] = nextID; gesture.begin(id: nextID, key: key?.first, profile: profile) }
            else { ordinary[oid] = key }
        }
        if chordMode && !numeric { preview() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard chordMode && !numeric else { return }
        for t in touches { if let id = touchIDs[ObjectIdentifier(t)] { gesture.move(id: id, key: key(at: t.location(in: self))?.first, profile: profile) } }
        preview()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let oid = ObjectIdentifier(t), key = key(at: t.location(in: self))
            if let id = touchIDs.removeValue(forKey: oid) {
                let result = gesture.end(id: id, key: key?.first, profile: profile)
                if !gesture.active { onPreview?(""); onChord?(result) }
            } else if let original = ordinary.removeValue(forKey: oid), key == original { onKey?(shifted && !numeric ? original.uppercased() : original) }
        }
        setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        gesture.cancel()
        for t in touches { let oid = ObjectIdentifier(t); if let id = touchIDs.removeValue(forKey: oid) { _ = gesture.end(id: id, key: nil, profile: profile) }; ordinary.removeValue(forKey: oid) }
        onPreview?(""); setNeedsDisplay()
    }
}
private final class KeyAccessibility: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return true }
}
