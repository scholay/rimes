import UIKit
import UniformTypeIdentifiers

/// System paste control grants access for this explicit tap. The small fallback
/// explains Full Access without inspecting the user's clipboard.
final class BufferPasteButton: UIControl {
    private let native: UIPasteControl
    private let access = UIButton(type: .system)
    var onPaste: (([NSItemProvider]) -> Void)?
    var onNeedsAccess: (() -> Void)?
    var fullAccess = false { didSet { native.isHidden = !fullAccess; access.isHidden = fullAccess } }
    override var isEnabled: Bool { didSet { isUserInteractionEnabled = isEnabled; alpha = isEnabled ? 1 : 0.45 } }
    /// The control's opaque background must not cover the input line's outline.
    static let lineInset: CGFloat = 3
    var controlFrame: CGRect { native.frame }

    override init(frame: CGRect) {
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconOnly
        configuration.baseBackgroundColor = .systemBackground
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .fixed
        configuration.cornerRadius = 5
        native = UIPasteControl(configuration: configuration)
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.buffer.paste"
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.text.identifier])
        native.target = self; native.isHidden = true
        native.accessibilityLabel = L("粘贴剪贴板文字", "Paste clipboard text")
        native.accessibilityHint = L("插入 Buffer 当前光标位置", "Insert at the Buffer cursor")
        access.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        access.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .regular), forImageIn: .normal)
        access.accessibilityLabel = native.accessibilityLabel
        access.addAction(UIAction { [weak self] _ in self?.onNeedsAccess?() }, for: .touchUpInside)
        addSubview(native); addSubview(access)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        fullAccess && isEnabled && itemProviders.contains { $0.canLoadObject(ofClass: NSString.self) }
    }
    override func paste(itemProviders: [NSItemProvider]) {
        guard fullAccess, isEnabled else { return }
        onPaste?(itemProviders)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Below its intrinsic size UIPasteControl can render an empty, inert
        // slot. Keep its native layout size and scale it into the input line,
        // clear of that line's border and rounded corners.
        let intrinsic = native.intrinsicContentSize
        let size = CGSize(width: max(44, ceil(intrinsic.width)), height: max(36, ceil(intrinsic.height)))
        let fit = bounds.insetBy(dx: Self.lineInset, dy: Self.lineInset)
        let scale = max(0, min(1, fit.width / size.width, fit.height / size.height))
        native.bounds = CGRect(origin: .zero, size: size)
        native.center = CGPoint(x: bounds.midX, y: bounds.midY)
        native.transform = CGAffineTransform(scaleX: scale, y: scale)
        access.frame = bounds
    }
}

/// The host field's text shown as hint text inside the empty source line, with
/// a breathing icon as the only cue that a tap moves it in. The preview never
/// becomes Buffer text.
final class BufferImportPrompt: UIControl {
    private let icon = UIImageView(image: UIImage(systemName: "arrow.down.doc"))
    private let preview = UILabel()
    private var shownText: String?
    var font: UIFont = .systemFont(ofSize: 15) { didSet { preview.font = font } }
    var isBreathing: Bool { icon.layer.animation(forKey: Self.breath) != nil }
    private static let breath = "importHint"

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.buffer.importHost"
        accessibilityTraits = .button
        isAccessibilityElement = true
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        preview.font = font
        preview.textColor = .placeholderText
        preview.lineBreakMode = .byTruncatingTail
        for item in [icon, preview] { item.isUserInteractionEnabled = false; addSubview(item) }
        tintColorDidChange()
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(text: String?) {
        guard shownText != text else { return }
        shownText = text
        isHidden = text == nil
        defer { breathe() }
        guard let text else { preview.text = nil; accessibilityLabel = nil; return }
        // Only this preview is shortened; the captured source is kept verbatim.
        preview.text = text.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: "")
        accessibilityLabel = L("移入输入框文字：", "Import text from the input field: ") + text
        accessibilityHint = L("轻点导入 Buffer；无法完整读取时保留原文", "Tap to import into Buffer; the original stays if it cannot be read in full")
    }
    /// Core Animation drops running animations when the view leaves its window.
    override func didMoveToWindow() { super.didMoveToWindow(); breathe() }
    private func breathe() {
        let wanted = shownText != nil && window != nil && !UIAccessibility.isReduceMotionEnabled
        guard wanted != isBreathing else { return }
        guard wanted else { icon.layer.removeAnimation(forKey: Self.breath); return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.85; pulse.toValue = 0.25; pulse.duration = 1.4
        pulse.autoreverses = true; pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.layer.add(pulse, forKey: Self.breath)
    }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.5 : 1 } }
    override func tintColorDidChange() {
        super.tintColorDidChange()
        icon.tintColor = tintColor; icon.alpha = 0.85
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 5, y: (bounds.height - 16) / 2, width: 16, height: 16)
        preview.frame = CGRect(x: 26, y: 0, width: max(0, bounds.width - 30), height: bounds.height)
    }
}
