import UIKit
import RimesCore

struct CandidateLayout {
    let frames: [CGRect]
    let contentSize: CGSize
    let height: CGFloat
    static func measure(_ texts: [String], width: CGFloat, expanded: Bool, landscape: Bool) -> CandidateLayout {
        let font = UIFont.systemFont(ofSize: landscape ? 18 : 20)
        let rowHeight = ceil(font.lineHeight) + 6
        let available = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, frames: [CGRect] = []
        for text in texts {
            let natural = max(32, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12)
            let w = expanded ? min(available, natural) : natural
            if expanded && x > 0 && x + w > available { x = 0; y += rowHeight + 4 }
            frames.append(CGRect(x: x, y: y, width: w, height: rowHeight)); x += w + 4
        }
        let contentHeight = texts.isEmpty ? 0 : y + rowHeight
        let contentWidth = expanded ? available : max(0, x - 4)
        return CandidateLayout(frames: frames, contentSize: CGSize(width: contentWidth, height: contentHeight), height: min(contentHeight, expanded ? (landscape ? 2 : 3) * rowHeight + (landscape ? 1 : 2) * 4 : rowHeight))
    }
}

final class CandidateStrip: UIView {
    let scroll = UIScrollView()
    let expandButton = CandidateButton()
    private let content = UIView()
    private(set) var buttons: [CandidateButton] = []
    private var texts: [String] = []
    var onSelect: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onPress: (() -> Void)?
    var expanded = false
    var landscape = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(scroll); scroll.addSubview(content); addSubview(expandButton)
        scroll.showsHorizontalScrollIndicator = false
        expandButton.accessibilityIdentifier = "keyboard.candidates.expand"
        expandButton.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ values: [String]) {
        guard values != texts else { return }
        texts = values; buttons.forEach { $0.removeFromSuperview() }; buttons = []
        scroll.setContentOffset(.zero, animated: false)
        for (index, text) in values.enumerated() {
            let button = CandidateButton(); button.setTitle(text, for: .normal)
            button.accessibilityLabel = text; button.accessibilityIdentifier = "keyboard.candidate.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            content.addSubview(button); buttons.append(button)
        }
        setNeedsLayout()
    }
    func fittingHeight(width: CGFloat) -> CGFloat {
        CandidateLayout.measure(texts, width: width - 36, expanded: expanded, landscape: landscape).height
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width - 36), height: bounds.height)
        let layout = CandidateLayout.measure(texts, width: scroll.bounds.width, expanded: expanded, landscape: landscape)
        content.frame = CGRect(origin: .zero, size: layout.contentSize); scroll.contentSize = layout.contentSize
        let rowHeight = layout.frames.first?.height ?? 32
        expandButton.isHidden = texts.isEmpty
        expandButton.frame = CGRect(x: bounds.width - 32, y: 0, width: 32, height: rowHeight)
        expandButton.symbol(expanded ? "chevron.down" : "chevron.up", label: expanded ? L("收起候选", "Collapse candidates") : L("展开候选", "Expand candidates"))
        for (button, frame) in zip(buttons, layout.frames) {
            button.titleLabel?.font = .systemFont(ofSize: landscape ? 18 : 20)
            button.frame = frame
        }
        // Clamp after wrapping/orientation changes without losing horizontal scrolling.
        let offset = CGPoint(x: expanded ? 0 : min(scroll.contentOffset.x, max(0, layout.contentSize.width - scroll.bounds.width)), y: expanded ? min(scroll.contentOffset.y, max(0, layout.contentSize.height - scroll.bounds.height)) : 0)
        if offset != scroll.contentOffset { scroll.contentOffset = offset }
    }
}

/// Candidates read as text, with a transient touch highlight and no keycap base.
final class CandidateButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; layer.cornerRadius = 4
        titleLabel?.textAlignment = .center; titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.lineBreakMode = .byTruncatingTail
        setTitleColor(.label, for: .normal); setTitleColor(.systemTeal, for: .highlighted)
        setPreferredSymbolConfiguration(.init(pointSize: 17, weight: .medium), forImageIn: .normal)
        tintColor = .label
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .clear }
    }
    func symbol(_ name: String, label: String) {
        setImage(UIImage(systemName: name), for: .normal); accessibilityLabel = label
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let textHeight = min(bounds.height, ceil(titleLabel?.font.lineHeight ?? 0))
        titleLabel?.frame = CGRect(x: 6, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - 12), height: textHeight)
        if let imageView, let image = imageView.image {
            imageView.frame = CGRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
        }
    }
}

/// Temporarily replaces the candidate row while a chord is held. Mirrored about
/// the centre: left keys, left mapping, [combined result], right mapping, right keys.
final class ChordHandPreviewView: UIView {
    private let leftKeys = UILabel(), leftOutput = UILabel(), combined = UILabel(), rightOutput = UILabel(), rightKeys = UILabel()
    private let pill = UIView()
    private var columns: [UILabel] { [leftKeys, leftOutput, combined, rightOutput, rightKeys] }
    private(set) var preview: ChordHandPreview?
    var landscape = false { didSet { if oldValue != landscape { update(preview) } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isHidden = true
        pill.layer.cornerRadius = 8; pill.layer.cornerCurve = .continuous; addSubview(pill)
        for (label, id) in zip(columns, ["left.keys", "left.output", "combined", "right.output", "right.keys"]) {
            label.textAlignment = .center; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
            label.accessibilityIdentifier = "keyboard.chord.\(id)"; addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height, mid = bounds.midX
        func natural(_ label: UILabel) -> CGFloat { (label.text?.isEmpty ?? true) ? 0 : ceil(label.intrinsicContentSize.width) }
        // Result pill stays centred; each side packs outward from it.
        let pillWidth = min(bounds.width * 0.42, max(58, natural(combined) + 20))
        pill.frame = CGRect(x: mid - pillWidth / 2, y: 2, width: pillWidth, height: max(0, h - 4))
        combined.frame = pill.frame.insetBy(dx: 6, dy: 0)
        let room = max(0, (bounds.width - pillWidth) / 2 - 4)
        for (output, keys, sign) in [(leftOutput, leftKeys, CGFloat(-1)), (rightOutput, rightKeys, CGFloat(1))] {
            let outputWidth = min(natural(output), room * 0.55), keysWidth = min(natural(keys), max(0, room - outputWidth - 14))
            let outputCentre = mid + sign * (pillWidth / 2 + 8 + outputWidth / 2)
            output.frame = CGRect(x: outputCentre - outputWidth / 2, y: 0, width: outputWidth, height: h)
            let keysCentre = outputCentre + sign * (outputWidth / 2 + 6 + keysWidth / 2)
            keys.frame = CGRect(x: keysCentre - keysWidth / 2, y: 0, width: keysWidth, height: h)
        }
    }
    /// Column texts left to right, for tests and accessibility.
    var texts: [String] { columns.map { $0.text ?? "" } }
    func update(_ value: ChordHandPreview?) {
        preview = value
        let keyFont = UIFont.monospacedSystemFont(ofSize: landscape ? 12 : 13, weight: .medium)
        let outputFont = UIFont.systemFont(ofSize: landscape ? 15 : 17, weight: .semibold)
        func side(_ side: ChordHandPreview.Side?, keys: UILabel, output: UILabel) {
            keys.font = keyFont; keys.textColor = .secondaryLabel; keys.text = side?.keys.uppercased() ?? ""
            output.font = outputFont
            output.text = side == nil ? "—" : side?.output ?? "?"
            output.textColor = side == nil ? .tertiaryLabel : side?.output == nil ? .systemRed : .systemTeal
        }
        side(value?.left, keys: leftKeys, output: leftOutput)
        side(value?.right, keys: rightKeys, output: rightOutput)
        let mapped = value?.combined != nil
        combined.font = mapped ? .systemFont(ofSize: landscape ? 20 : 22, weight: .bold) : .systemFont(ofSize: 13, weight: .semibold)
        combined.textColor = mapped ? .white : .secondaryLabel
        combined.text = value == nil ? "" : value?.combined ?? L("无映射", "No mapping")
        pill.backgroundColor = mapped ? .systemTeal : .tertiarySystemFill
        pill.isHidden = value == nil
        accessibilityLabel = value == nil ? nil : texts.filter { !$0.isEmpty }.joined(separator: " ")
        setNeedsLayout()
    }
}
