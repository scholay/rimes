import UIKit
import RimesCore

/// Visual blocks share the exact boundaries used by Default's delivery queue.
final class BufferBlockStrip: UIView {
    private let scroll = UIScrollView()
    private var labels: [UILabel] = []
    private var activeIndex = 0
    private var caretOffset: CGFloat = 0
    private var followCaret = true
    private var previousContent = ""
    private(set) var blockTexts: [String] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(scroll); scroll.showsHorizontalScrollIndicator = false
        accessibilityIdentifier = "keyboard.buffer.blocks"
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(source: String, cursor: Int, preedit: String, font: UIFont) {
        let signature = "\(source)\u{0}\(cursor)\u{0}\(preedit)"
        followCaret = followCaret || signature != previousContent; previousContent = signature
        blockTexts = DefaultBlockSegmenter.segments(from: source)
        let blocks = blockTexts.isEmpty ? [""] : blockTexts
        while labels.count > blocks.count { labels.removeLast().removeFromSuperview() }
        while labels.count < blocks.count {
            let label = UILabel()
            label.layer.cornerRadius = 6; label.layer.masksToBounds = true
            label.backgroundColor = .secondarySystemGroupedBackground
            label.isAccessibilityElement = true
            labels.append(label); scroll.addSubview(label)
        }
        var offset = 0
        var assigned = false
        for (index, block) in blocks.enumerated() {
            let active = !assigned && cursor <= offset + block.count
            if active { activeIndex = index; assigned = true }
            let text: NSAttributedString
            if active {
                let composition = BufferComposition(source: block, cursor: cursor - offset, preedit: preedit, font: font)
                text = composition.text
                caretOffset = text.attributedSubstring(from: NSRange(location: 0, length: composition.caretRange.location + 1)).size().width + 8
            } else {
                text = NSAttributedString(string: block, attributes: [.font: font, .foregroundColor: UIColor.label])
            }
            // Spaces provide padding without putting artificial characters in source data.
            let padded = NSMutableAttributedString(string: " ", attributes: [.font: font])
            padded.append(text); padded.append(NSAttributedString(string: " ", attributes: [.font: font]))
            labels[index].attributedText = padded
            labels[index].accessibilityLabel = (active ? block + preedit : block)
            labels[index].layer.borderWidth = 1
            labels[index].layer.borderColor = (active ? UIColor.systemTeal : UIColor.separator).cgColor
            offset += block.count
        }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        var x: CGFloat = 0
        for label in labels {
            let width = max(28, ceil(label.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: bounds.height)).width) + 2)
            label.frame = CGRect(x: x, y: 1, width: width, height: max(0, bounds.height - 2))
            x += width + 4
        }
        scroll.contentSize = CGSize(width: max(bounds.width, x - 4), height: bounds.height)
        if followCaret, labels.indices.contains(activeIndex) {
            let label = labels[activeIndex]
            scroll.scrollRectToVisible(CGRect(x: label.frame.minX + max(0, caretOffset - 12), y: 0,
                                             width: 16, height: bounds.height), animated: false)
            followCaret = false
        }
    }
}
