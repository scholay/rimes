import UIKit

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
