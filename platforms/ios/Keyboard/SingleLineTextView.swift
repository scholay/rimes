import UIKit
import RimesCore

/// One line that never wraps; drag horizontally to read the rest.
final class SingleLineTextView: UIScrollView {
    private let label = UILabel()
    private var plain: String?
    private var focus: NSRange?
    private var followedSignature = ""
    private static let inset: CGFloat = 8
    /// Input accepts the typed text (outlined, with caret); output only displays.
    enum Role { case input, output }
    var role = Role.input { didSet { applyRole(); if let plain { text = plain } } }
    var font: UIFont = .systemFont(ofSize: 15) { didSet { if let plain, oldValue != font { text = plain } } }
    var text: String {
        get { label.attributedText?.string ?? "" }
        set { attributedText = NSAttributedString(string: newValue, attributes: [.font: font, .foregroundColor: role == .input ? UIColor.label : UIColor.secondaryLabel]); plain = newValue }
    }
    var attributedText: NSAttributedString? {
        get { label.attributedText }
        set { plain = nil; label.attributedText = newValue; setNeedsLayout() }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 1; label.lineBreakMode = .byClipping
        addSubview(label)
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false; alwaysBounceVertical = false; bounces = true
        layer.cornerRadius = 7; layer.cornerCurve = .continuous
        applyRole()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SingleLineTextView, _: UITraitCollection) in view.applyRole() }
    }
    private func applyRole() {
        switch role {
        case .input:
            backgroundColor = .systemBackground
            layer.borderWidth = 1; layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.7).resolvedColor(with: traitCollection).cgColor
            accessibilityTraits = [.updatesFrequently]
        case .output:
            backgroundColor = .tertiarySystemFill
            layer.borderWidth = 0
            accessibilityTraits = [.staticText, .notEnabled]
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Keeps a UTF-16 range in view, only when text or range changed, so a
    /// manual drag stays where the user left it until the content moves on.
    func scrollRangeToVisible(_ range: NSRange) { focus = range; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height)).width)
        label.frame = CGRect(x: Self.inset, y: 0, width: width, height: bounds.height)
        contentSize = CGSize(width: max(bounds.width, width + 2 * Self.inset), height: bounds.height)
        if contentOffset.y != 0 || contentOffset.x > contentSize.width - bounds.width {
            contentOffset = CGPoint(x: max(0, min(contentOffset.x, contentSize.width - bounds.width)), y: 0)
        }
        guard let focus, let attributed = label.attributedText else { return }
        let signature = "\(attributed.string)\u{0}\(focus.location)\u{0}\(bounds.width)"
        guard signature != followedSignature else { return }
        followedSignature = signature
        let end = min(attributed.length, NSMaxRange(focus))
        let x = Self.inset + ceil(attributed.attributedSubstring(from: NSRange(location: 0, length: end)).size().width)
        scrollRectToVisible(CGRect(x: max(0, x - 24), y: 0, width: 48, height: bounds.height), animated: false)
    }
}
