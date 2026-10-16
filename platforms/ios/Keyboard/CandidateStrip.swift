import UIKit
#if KEYBOARD_LAYOUT_TESTS
@testable import RIMES
#endif
import RimesCore

struct CandidateLayout {
    let frames: [CGRect]
    let contentSize: CGSize
    let height: CGFloat
    static func rowHeight(landscape: Bool) -> CGFloat { ceil(UIFont.systemFont(ofSize: landscape ? 18 : 20).lineHeight) + 6 }
    static func commentFont(landscape: Bool) -> UIFont { .systemFont(ofSize: landscape ? 12 : 13) }
    static func measure(_ texts: [String], comments: [String] = [], width: CGFloat, expanded: Bool, landscape: Bool) -> CandidateLayout {
        let font = UIFont.systemFont(ofSize: landscape ? 18 : 20)
        let rowHeight = rowHeight(landscape: landscape)
        let available = max(1, width)
        var row = 0, x: CGFloat = 0, frames: [CGRect] = []
        for (index, text) in texts.enumerated() {
            let comment = comments.indices.contains(index) ? comments[index] : ""
            let annotationWidth = comment.isEmpty ? 0 : 4 + (comment as NSString).size(withAttributes: [.font: commentFont(landscape: landscape)]).width
            let natural = max(32, ceil((text as NSString).size(withAttributes: [.font: font]).width + annotationWidth) + 12)
            if expanded && x > 0 && x + natural > available {
                row += 1; x = 0
            }
            let rowWidth = available
            let w = expanded ? min(max(1, rowWidth), natural) : natural
            frames.append(CGRect(x: x, y: CGFloat(row) * (rowHeight + 4), width: w, height: rowHeight)); x += w + 4
        }
        let contentHeight = texts.isEmpty ? 0 : CGFloat(row) * (rowHeight + 4) + rowHeight
        let contentWidth = expanded ? available : max(0, x - 4)
        return CandidateLayout(frames: frames, contentSize: CGSize(width: contentWidth, height: contentHeight), height: min(contentHeight, expanded ? (landscape ? 2 : 3) * rowHeight + (landscape ? 1 : 2) * 4 : rowHeight))
    }
}

private final class CandidateScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

final class CandidateStrip: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scroll: UIScrollView = CandidateScrollView()
    let expandButton = CandidateButton()
    private let content = UIView()
    private(set) var buttons: [CandidateButton] = []
    private var texts: [String] = []
    private var comments: [String] = []
    private var context = ""
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
    private var selectionPoint: CGPoint?
    private var selectionTimer: Timer?
    private var lastSelectionTick: TimeInterval = 0
    private(set) var selectedIndex: Int?
    private var lastFeedbackIndex: Int?
    private var layoutWidth: CGFloat = 0
    private var layingOutCandidates = false
    var onSelect: ((Int) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onExpand: (() -> Void)?
    var onPress: (() -> Void)?
    var expanded = false { didSet { if expanded != oldValue { cancelSelection(); setNeedsLayout() } } }
    var landscape = false { didSet { if landscape != oldValue { cancelSelection(); setNeedsLayout() } } }
    /// The nine-key punctuation strip draws its marks in their Chinese forms.
    var showsChineseMarks = false { didSet { if showsChineseMarks != oldValue { setNeedsLayout() } } }
    override var isHidden: Bool { didSet { if isHidden { cancelSelection() } } }
    /// Controls occupy fixed gutters outside the scrolling candidate content.
    var controlInsets = UIEdgeInsets.zero { didSet { if controlInsets != oldValue { cancelSelection(); setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(scroll); scroll.addSubview(content); addSubview(expandButton)
        scroll.delegate = self; scroll.delaysContentTouches = false
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false; scroll.hideEdgeEffects()
        hold.minimumPressDuration = 0.45; hold.allowableMovement = 10; hold.delegate = self
        addGestureRecognizer(hold)
        // A quick swipe still scrolls normally. Once the hold wins, dragging selects
        // instead; approaching an edge scrolls without ending that same gesture.
        scroll.panGestureRecognizer.require(toFail: hold)
        expandButton.accessibilityIdentifier = "keyboard.candidates.expand"
        expandButton.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
        expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { selectionTimer?.invalidate() }
    func update(_ values: [String], comments: [String] = [], context: String = "") {
        let sameContext = context == self.context
        if !sameContext { cancelSelection(); self.context = context }
        guard values != texts || comments != self.comments else { return }
        cancelSelection()
        let appending = expanded && sameContext && !texts.isEmpty && values.count >= texts.count
            && Array(values.prefix(texts.count)) == texts
            && texts.indices.allSatisfy { (comments.indices.contains($0) ? comments[$0] : "") == (self.comments.indices.contains($0) ? self.comments[$0] : "") }
        texts = values
        self.comments = comments
        // Keep idle buttons across compositions instead of constructing sixty
        // UIKit controls on every key. A button under a finger is retired so its
        // eventual release cannot select a different word at the reused index.
        while buttons.count > values.count { buttons.removeLast().removeFromSuperview() }
        if !appending { scroll.setContentOffset(.zero, animated: false) }
        for (index, text) in values.enumerated() {
            if index == buttons.count { buttons.append(makeButton(at: index)) }
            else if buttons[index].isTracking || buttons[index].isHighlighted {
                buttons[index].removeFromSuperview(); buttons[index] = makeButton(at: index)
            }
            let button = buttons[index]
            if button.currentTitle != text { button.setTitle(text, for: .normal); button.accessibilityLabel = text }
            button.comment = comments.indices.contains(index) ? comments[index] : ""
        }
        setNeedsLayout()
    }
    private func makeButton(at index: Int) -> CandidateButton {
        let button = CandidateButton()
        button.accessibilityIdentifier = "keyboard.candidate.\(index)"
        button.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, self.selectionPoint == nil, self.buttons.indices.contains(index),
                  self.buttons[index] === button else { return }
            self.onSelect?(index)
        }, for: .touchUpInside)
        content.addSubview(button)
        return button
    }
    private var reservedInsets: UIEdgeInsets {
        .init(top: 0, left: controlInsets.left, bottom: 0, right: controlInsets.right + (texts.isEmpty ? 0 : 36))
    }
    func fittingHeight(width: CGFloat) -> CGFloat {
        // A collapsed strip always has one row; measuring every candidate here
        // repeats text shaping during each host sizing/layout callback.
        guard expanded else { return texts.isEmpty ? 0 : CandidateLayout.rowHeight(landscape: landscape) }
        return CandidateLayout.measure(texts, comments: comments, width: max(1, width - reservedInsets.left - reservedInsets.right), expanded: true, landscape: landscape).height
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if layoutWidth != bounds.width { cancelSelection(); layoutWidth = bounds.width }
        layoutCandidates()
    }
    private func layoutCandidates() {
        guard !layingOutCandidates else { return }
        layingOutCandidates = true
        defer { layingOutCandidates = false; refreshSelection() }
        let insets = reservedInsets
        let width = max(1, bounds.width - insets.left - insets.right)
        scroll.frame = CGRect(x: insets.left, y: 0, width: width, height: bounds.height)
        // Layout depends only on the candidate list and available width, never on
        // scroll position. Every row has the same width, including under controls.
        let layout = CandidateLayout.measure(texts, comments: comments, width: width,
            expanded: expanded, landscape: landscape)
        var offset = scroll.contentOffset
        offset.x = expanded ? 0 : min(max(0, offset.x), max(0, layout.contentSize.width - width))
        offset.y = expanded ? min(max(0, offset.y), max(0, layout.contentSize.height - bounds.height)) : 0
        content.frame = CGRect(origin: .zero, size: layout.contentSize)
        scroll.contentSize = layout.contentSize
        let rowHeight = layout.frames.first?.height ?? 32
        expandButton.isHidden = texts.isEmpty
        expandButton.frame = CGRect(x: bounds.width - controlInsets.right - 32, y: 0, width: 32, height: rowHeight)
        expandButton.symbol(expanded ? "chevron.down" : "chevron.up", label: expanded ? L("收起候选", "Collapse candidates") : L("展开候选", "Expand candidates"))
        for (button, frame) in zip(buttons, layout.frames) {
            button.titleLabel?.font = showsChineseMarks ? .chineseMarks(ofSize: landscape ? 18 : 20) : .systemFont(ofSize: landscape ? 18 : 20)
            button.commentLabel.font = CandidateLayout.commentFont(landscape: landscape)
            button.frame = frame
        }
        if offset != scroll.contentOffset { scroll.contentOffset = offset }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelSelection() }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer !== hold { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return candidate(at: gestureRecognizer.location(in: self)) != nil
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began: beginSelection(at: point)
        case .changed: moveSelection(to: point)
        case .ended: finishSelection(at: point)
        case .cancelled, .failed: cancelSelection()
        default: break
        }
    }
    private func candidate(at point: CGPoint) -> Int? {
        guard bounds.contains(point), !isHidden else { return nil }
        for (index, button) in buttons.enumerated() {
            let viewport = scroll.frame
            guard viewport.contains(point) else { continue }
            let visible = button.convert(button.bounds, to: self).intersection(viewport)
            if !visible.isNull && visible.insetBy(dx: -2, dy: -2).contains(point) { return index }
        }
        return nil
    }
    private func beginSelection(at point: CGPoint) {
        guard candidate(at: point) != nil else { return }
        cancelSelection()
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        selectionPoint = point; refreshSelection()
        lastSelectionTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            self.advanceSelection(by: min(0.05, now - self.lastSelectionTick))
            self.lastSelectionTick = now
        }
        selectionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func moveSelection(to point: CGPoint) {
        guard selectionPoint != nil else { return }
        selectionPoint = point; refreshSelection()
    }
    private func finishSelection(at point: CGPoint) {
        guard selectionPoint != nil else { return }
        // Resolve the release against the current scroll position, not the button
        // where the gesture began or a highlight from before the last scroll tick.
        moveSelection(to: point)
        let index = selectedIndex
        cancelSelection()
        if let index { onSelect?(index) }
    }
    func cancelSelection() {
        selectionPoint = nil; selectionTimer?.invalidate(); selectionTimer = nil
        setSelection(nil); lastFeedbackIndex = nil
    }
    private func setSelection(_ index: Int?) {
        guard selectedIndex != index else { return }
        if let old = selectedIndex, buttons.indices.contains(old) { buttons[old].isDragTarget = false }
        selectedIndex = index
        if let index {
            buttons[index].isDragTarget = true
            if lastFeedbackIndex != index { lastFeedbackIndex = index; onSelectionChanged?() }
        }
    }
    private func refreshSelection() {
        guard let point = selectionPoint else { return }
        setSelection(candidate(at: point))
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOutCandidates else { return }
        refreshSelection()
    }
    private func advanceSelection(by elapsed: TimeInterval) {
        guard let point = selectionPoint, scroll.frame.contains(point) else { return }
        let position = expanded ? point.y - scroll.frame.minY : point.x - scroll.frame.minX
        let length = expanded ? scroll.bounds.height : scroll.bounds.width
        let edge = min(24, length / 3)
        guard edge > 0 else { return }
        let velocity: CGFloat
        if position < edge { velocity = -260 * (1 - position / edge) }
        else if position > length - edge { velocity = 260 * (1 - (length - position) / edge) }
        else { return }
        let limit = max(0, expanded ? scroll.contentSize.height - length : scroll.contentSize.width - length)
        let old = expanded ? scroll.contentOffset.y : scroll.contentOffset.x
        let next = min(limit, max(0, old + velocity * elapsed))
        scroll.contentOffset = expanded ? CGPoint(x: 0, y: next) : CGPoint(x: next, y: 0)
        refreshSelection()
    }
    #if KEYBOARD_LAYOUT_TESTS
    func developmentBeginSelection(at point: CGPoint) { beginSelection(at: point) }
    func developmentMoveSelection(to point: CGPoint) { moveSelection(to: point) }
    func developmentFinishSelection(at point: CGPoint) { finishSelection(at: point) }
    func developmentAdvanceSelection(by elapsed: TimeInterval) { advanceSelection(by: elapsed) }
    #endif
}

/// Candidates read as text, with a transient touch highlight and no keycap base.
final class CandidateButton: UIButton {
    let commentLabel = UILabel()
    var comment = "" {
        didSet {
            guard comment != oldValue else { return }
            commentLabel.text = comment; commentLabel.isHidden = comment.isEmpty
            accessibilityValue = comment.isEmpty ? nil : comment
            setNeedsLayout()
        }
    }
    var isDragTarget = false { didSet { if oldValue != isDragTarget { updateHighlight(); setNeedsLayout() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; layer.cornerRadius = 4
        commentLabel.font = CandidateLayout.commentFont(landscape: false)
        commentLabel.lineBreakMode = .byTruncatingTail; commentLabel.isHidden = true
        commentLabel.isUserInteractionEnabled = false; addSubview(commentLabel)
        titleLabel?.textAlignment = .center; titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.lineBreakMode = .byTruncatingTail
        setTitleColor(.label, for: .normal)
        setPreferredSymbolConfiguration(.init(pointSize: 17, weight: .medium), forImageIn: .normal)
        updateHighlight()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isHighlighted: Bool {
        didSet { if oldValue != isHighlighted { updateHighlight() } }
    }
    override func tintColorDidChange() { super.tintColorDidChange(); updateHighlight() }
    private func updateHighlight() {
        let accent = tintColor ?? UIColor.systemBlue
        backgroundColor = isHighlighted || isDragTarget ? accent : .clear
        setTitleColor(isDragTarget ? KeyboardPalette.contrastingInk(on: accent) : .label, for: .normal)
        setTitleColor(KeyboardPalette.contrastingInk(on: accent), for: .highlighted)
        imageView?.tintColor = isHighlighted ? KeyboardPalette.contrastingInk(on: accent) : .label
        commentLabel.textColor = isHighlighted || isDragTarget ? KeyboardPalette.contrastingInk(on: accent) : .secondaryLabel
    }
    func symbol(_ name: String, label: String) {
        setImage(UIImage(systemName: name), for: .normal); accessibilityLabel = label
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel?.transform = .identity
        let textHeight = min(bounds.height, ceil(titleLabel?.font.lineHeight ?? 0))
        titleLabel?.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 12), height: textHeight)
        titleLabel?.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if !comment.isEmpty {
            let available = max(0, bounds.width - 12)
            let titleWidth = min(available, ceil(titleLabel?.sizeThatFits(.init(width: .greatestFiniteMagnitude, height: bounds.height)).width ?? 0))
            let commentWidth = min(max(0, available - titleWidth - 4), ceil(commentLabel.intrinsicContentSize.width))
            let left = (bounds.width - titleWidth - 4 - commentWidth) / 2
            titleLabel?.frame = CGRect(x: left, y: (bounds.height - textHeight) / 2, width: titleWidth, height: textHeight)
            commentLabel.frame = CGRect(x: left + titleWidth + 4, y: 0, width: commentWidth, height: bounds.height)
        }
        let scale = isDragTarget ? min(1.08, (bounds.width - 2) / max(1, bounds.width - 12)) : 1
        titleLabel?.transform = CGAffineTransform(scaleX: scale, y: scale)
        if let imageView, let image = imageView.image {
            imageView.frame = CGRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
        }
    }
}

/// Temporarily replaces the candidate row while a chord is held. Mirrored about
/// the centre: left keys, left mapping, [combined result], right mapping, right keys.
final class ChordHandPreviewView: UIView {
    var theme: StatusSkin = .apple { didSet { if oldValue != theme { update(preview) } } }
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
            output.textColor = side == nil ? .tertiaryLabel : side?.output == nil ? .systemRed : theme.palette.accentText
        }
        side(value?.left, keys: leftKeys, output: leftOutput)
        side(value?.right, keys: rightKeys, output: rightOutput)
        let mapped = value?.combined != nil
        combined.font = mapped ? .systemFont(ofSize: landscape ? 20 : 22, weight: .bold) : .systemFont(ofSize: 13, weight: .semibold)
        combined.textColor = mapped ? theme.palette.accentInk : .secondaryLabel
        combined.text = value == nil ? "" : value?.combined ?? L("无映射", "No mapping")
        pill.backgroundColor = mapped ? theme.palette.accent : .tertiarySystemFill
        pill.isHidden = value == nil
        accessibilityLabel = value == nil ? nil : texts.filter { !$0.isEmpty }.joined(separator: " ")
        setNeedsLayout()
    }
}

/// Fills the empty candidate row: one button per plugin, each two squares wide.
final class PluginShortcutBar: UIView {
    private let scroll = UIScrollView()
    private(set) var buttons: [(plugin: KeyboardPlugin, button: UIButton)] = []
    var onSelect: ((KeyboardPlugin) -> Void)?
    /// Holding a shortcut opens that plugin's settings.
    var onSettings: ((KeyboardPlugin) -> Void)?
    var onPress: (() -> Void)?
    /// The plugin open in the Buffer, highlighted; nil for Default or Buffer off.
    var selected: KeyboardPlugin? { didSet { if selected != oldValue { refresh() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false; addSubview(scroll); scroll.hideEdgeEffects()
        for plugin in KeyboardPlugin.allCases {
            let button = UIButton(configuration: .gray())
            button.accessibilityIdentifier = "keyboard.shortcut.\(plugin.rawValue)"
            button.accessibilityLabel = plugin.title
            button.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(plugin) }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:))); hold.minimumPressDuration = 0.45
            button.addGestureRecognizer(hold)
            scroll.addSubview(button); buttons.append((plugin, button))
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tintColorDidChange() { super.tintColorDidChange(); refresh() }
    @objc private func hold(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let plugin = buttons.first(where: { $0.button === recognizer.view })?.plugin else { return }
        onSettings?(plugin)
    }
    private func refresh() {
        for (plugin, button) in buttons {
            var config = UIButton.Configuration.gray()
            config.image = UIImage(systemName: plugin.symbol)
            config.preferredSymbolConfigurationForImage = .init(pointSize: 12, weight: .medium)
            config.imagePadding = 3; config.cornerStyle = .medium
            config.contentInsets = .init(top: 0, leading: 4, bottom: 0, trailing: 4)
            config.titleLineBreakMode = .byTruncatingTail
            var title = AttributedString(plugin.shortTitle); title.font = .systemFont(ofSize: plugin.shortTitle.count > 2 ? 12 : 13, weight: .medium)
            config.attributedTitle = title
            let on = plugin == selected
            config.baseBackgroundColor = on ? tintColor : .tertiarySystemFill
            config.baseForegroundColor = on ? KeyboardPalette.contrastingInk(on: tintColor ?? .systemBlue) : .label
            button.configuration = config
            button.accessibilityTraits = on ? [.button, .selected] : [.button]
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        let unit = bounds.height, gap: CGFloat = 6, width = 2 * unit + 4
        let total = CGFloat(buttons.count) * width + CGFloat(max(0, buttons.count - 1)) * gap
        // Centred in the row when they fit; scroll sideways when more plugins arrive.
        var x = max(0, (bounds.width - total) / 2)
        for (_, button) in buttons {
            button.frame = CGRect(x: x, y: 1, width: width, height: max(0, unit - 2)); x += width + gap
        }
        scroll.contentSize = CGSize(width: max(bounds.width, total), height: bounds.height)
    }
}

/// One choice in the Buffer settings panel.
struct PanelItem: Equatable {
    enum Role: Equatable { case choice, action, destructive }
    var id: String
    var title: String
    var symbol: String? = nil
    var selected = false
    var role = Role.choice
    var enabled = true
}
struct PanelSection {
    var title: String
    var note: String?
    var items: [PanelItem]
    /// A row the controller owns (and keeps across renders), shown below the note.
    var custom: UIView?
    var customHeight: CGFloat = 0
    /// Changes whenever the custom row's content changes, so the panel knows to relayout.
    var customKey = ""
    var action: (String) -> Void
    init(title: String, note: String? = nil, items: [PanelItem] = [], custom: UIView? = nil, customHeight: CGFloat = 0, customKey: String = "", action: @escaping (String) -> Void = { _ in }) {
        self.title = title; self.note = note; self.items = items; self.custom = custom
        self.customHeight = customHeight; self.customKey = customKey; self.action = action
    }
}

/// Chip drawn by RIMES rather than a system control, so the panel reads as part of the keyboard.
final class PanelChip: UIControl {
    let label = UILabel()
    let icon = UIImageView()
    var item: PanelItem { didSet { apply() } }
    init(_ item: PanelItem) {
        self.item = item
        super.init(frame: .zero)
        layer.cornerRadius = 9; layer.cornerCurve = .continuous
        label.textAlignment = .center; label.isUserInteractionEnabled = false
        icon.contentMode = .scaleAspectFit; icon.isUserInteractionEnabled = false
        addSubview(icon); addSubview(label); isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (chip: PanelChip, _: UITraitCollection) in chip.apply() }
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tintColorDidChange() { super.tintColorDidChange(); apply() }
    static let height: CGFloat = 32
    static let font = UIFont.systemFont(ofSize: 14, weight: .medium)
    func fittingWidth() -> CGFloat { ceil((item.title as NSString).size(withAttributes: [.font: Self.font]).width) + 24 + (item.symbol == nil ? 0 : 22) }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.55 : item.enabled ? 1 : 0.35 } }
    private func apply() {
        label.text = item.title; label.font = Self.font
        icon.image = item.symbol.flatMap { UIImage(systemName: $0) }; icon.isHidden = item.symbol == nil
        let (fill, text, border): (UIColor, UIColor, UIColor?) = switch item.role {
        case .choice: item.selected ? (tintColor ?? .systemBlue, KeyboardPalette.contrastingInk(on: tintColor ?? .systemBlue), nil) : (.secondarySystemGroupedBackground, .label, .separator)
        case .action: ((tintColor ?? .systemBlue).withAlphaComponent(0.14), .label, nil)
        case .destructive: (UIColor.systemRed.withAlphaComponent(0.12), .systemRed, nil)
        }
        backgroundColor = fill; label.textColor = text; icon.tintColor = text
        layer.borderWidth = border == nil ? 0 : 0.7
        layer.borderColor = border?.resolvedColor(with: traitCollection).cgColor
        isEnabled = item.enabled; alpha = item.enabled ? 1 : 0.35
        accessibilityLabel = item.title
        accessibilityTraits = item.selected ? [.button, .selected] : item.enabled ? .button : [.button, .notEnabled]
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = item.symbol == nil ? bounds.insetBy(dx: 8, dy: 0) : CGRect(x: 34, y: 0, width: max(0, bounds.width - 46), height: bounds.height)
    }
}

/// Buffer and plugin settings, drawn over the keys: a header, then titled rows of
/// wrapping chips. Rebuilt only when its content changes, keeping the scroll position.
final class KeyboardPanel: UIView {
    var onClose: (() -> Void)?
    var onPress: (() -> Void)?
    private let titleLabel = UILabel(), closeButton = UIButton(type: .custom), scroll = UIScrollView()
    private var rows: [(title: UILabel, note: UILabel?, custom: UIView?, customHeight: CGFloat, chips: [PanelChip])] = []
    private var sections: [PanelSection] = []
    private var signature = ""
    private(set) var chips: [PanelChip] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold); titleLabel.textColor = .label
        addSubview(titleLabel); addSubview(scroll)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
        closeButton.tintColor = .secondaryLabel; closeButton.backgroundColor = .tertiarySystemFill
        closeButton.layer.cornerRadius = 14; closeButton.accessibilityLabel = L("关闭设置", "Close settings")
        closeButton.accessibilityIdentifier = "keyboard.panel.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        addSubview(closeButton)
        scroll.showsVerticalScrollIndicator = false; scroll.alwaysBounceVertical = true; scroll.hideEdgeEffects()
        accessibilityIdentifier = "keyboard.panel"
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(title: String, sections: [PanelSection]) {
        titleLabel.text = title
        self.sections = sections
        let next = sections.map { "\($0.title)|\($0.note ?? "")|\($0.customKey)|" + $0.items.map { "\($0.id)\($0.title)\($0.symbol ?? "")\($0.selected)\($0.enabled)" }.joined(separator: ",") }.joined(separator: ";")
        guard next != signature else { return }
        signature = next
        let offset = scroll.contentOffset
        rows.forEach { row in
            row.title.removeFromSuperview(); row.note?.removeFromSuperview(); row.chips.forEach { $0.removeFromSuperview() }
            if let custom = row.custom, !sections.contains(where: { $0.custom === custom }) { custom.removeFromSuperview() }
        }
        rows = []; chips = []
        for (index, section) in sections.enumerated() {
            let heading = UILabel(); heading.text = section.title
            heading.font = .systemFont(ofSize: 12, weight: .semibold); heading.textColor = .secondaryLabel
            scroll.addSubview(heading)
            var note: UILabel?
            if let text = section.note {
                let label = UILabel(); label.text = text; label.numberOfLines = 0
                label.font = .systemFont(ofSize: 13); label.textColor = .secondaryLabel
                scroll.addSubview(label); note = label
            }
            let row = section.items.map { item -> PanelChip in
                let chip = PanelChip(item)
                chip.accessibilityIdentifier = "keyboard.panel.\(index).\(item.id)"
                chip.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchDown)
                chip.addAction(UIAction { [weak self, weak chip] _ in
                    guard let self, let chip, chip.item.enabled, self.sections.indices.contains(index) else { return }
                    self.sections[index].action(chip.item.id)
                }, for: .touchUpInside)
                scroll.addSubview(chip); return chip
            }
            if let custom = section.custom, custom.superview !== scroll { scroll.addSubview(custom) }
            rows.append((heading, note, section.custom, section.customHeight, row)); chips += row
        }
        setNeedsLayout(); layoutIfNeeded()
        scroll.contentOffset = CGPoint(x: 0, y: min(offset.y, max(0, scroll.contentSize.height - scroll.bounds.height)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 12, width = bounds.width - 2 * inset
        titleLabel.frame = CGRect(x: inset, y: 6, width: max(0, width - 36), height: 28)
        closeButton.frame = CGRect(x: bounds.width - inset - 28, y: 6, width: 28, height: 28)
        scroll.frame = CGRect(x: 0, y: 38, width: bounds.width, height: max(0, bounds.height - 38))
        var y: CGFloat = 4
        for row in rows {
            row.title.frame = CGRect(x: inset, y: y, width: width, height: 18); y += 22
            if let note = row.note {
                let height = ceil(note.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
                note.frame = CGRect(x: inset, y: y, width: width, height: height); y += height + 6
            }
            if let custom = row.custom {
                custom.frame = CGRect(x: inset, y: y, width: width, height: row.customHeight); y += row.customHeight + (row.chips.isEmpty ? 0 : 8)
            }
            var x = inset
            for (i, chip) in row.chips.enumerated() {
                let w = min(width, chip.fittingWidth())
                if i > 0 && x + w > inset + width { x = inset; y += PanelChip.height + 8 }
                chip.frame = CGRect(x: x, y: y, width: w, height: PanelChip.height); x += w + 8
            }
            if !row.chips.isEmpty { y += PanelChip.height }
            y += 14
        }
        scroll.contentSize = CGSize(width: bounds.width, height: y)
    }
}

/// Three-row wheel, like a meter counter: the current item sits in a lit band with its
/// neighbours above and below, tilted back in 3D and fading, so the list reads as a
/// drum turning. Swipe to roll; tap the row above or below (or the middle) to step.
final class DrumPicker: UIView, UIScrollViewDelegate {
    var onChange: ((Int) -> Void)?
    /// Fires as each item rolls past the band, for haptics.
    var onTick: (() -> Void)?
    private let scroll = UIScrollView(), band = UIView(), fade = CAGradientLayer()
    private var labels: [UILabel] = []
    private(set) var items: [String] = []
    private(set) var selectedIndex = 0
    private var tickIndex = 0
    private var row: CGFloat { bounds.height / 3 }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 10; layer.cornerCurve = .continuous; layer.borderWidth = 0.7
        clipsToBounds = true
        band.isUserInteractionEnabled = false; band.layer.cornerRadius = 7; band.layer.cornerCurve = .continuous
        band.layer.borderWidth = 1
        addSubview(band)
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        scroll.decelerationRate = .fast; scroll.delegate = self; scroll.alwaysBounceVertical = true; scroll.hideEdgeEffects()
        addSubview(scroll)
        // Top and bottom rows sink into the background, like the ends of a drum.
        fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.locations = [0, 0.3, 0.7, 1]
        layer.addSublayer(fade)
        scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true; accessibilityTraits = .adjustable
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (drum: DrumPicker, _: UITraitCollection) in drum.applyColors() }
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tintColorDidChange() { super.tintColorDidChange(); applyColors() }
    private func applyColors() {
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        band.backgroundColor = (tintColor ?? .systemBlue).withAlphaComponent(0.12)
        band.layer.borderColor = (tintColor ?? .systemBlue).withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
        let base = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traitCollection)
        fade.colors = [base.withAlphaComponent(0.85).cgColor, base.withAlphaComponent(0).cgColor, base.withAlphaComponent(0).cgColor, base.withAlphaComponent(0.85).cgColor]
    }
    /// Sets the list and the current item without animation, unless the user is rolling it.
    func set(items next: [String], selected: Int) {
        if next != items {
            items = next; labels.forEach { $0.removeFromSuperview() }
            labels = next.map { text in
                let label = UILabel(); label.text = text; label.textAlignment = .center
                label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.7
                scroll.addSubview(label); return label
            }
            setNeedsLayout()
        }
        guard !scroll.isTracking, !scroll.isDecelerating else { return }
        selectedIndex = min(max(0, selected), max(0, items.count - 1)); tickIndex = selectedIndex
        layoutIfNeeded(); scroll.contentOffset.y = offset(for: selectedIndex); shape()
        accessibilityValue = items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }
    private func offset(for index: Int) -> CGFloat { CGFloat(index) * row - scroll.contentInset.top }
    private var centreIndex: Int { Int(((scroll.contentOffset.y + scroll.contentInset.top) / max(1, row)).rounded()) }
    override func layoutSubviews() {
        super.layoutSubviews()
        let h = row
        scroll.frame = bounds
        // One row of inset above and below lets the first and last items reach the band.
        scroll.contentInset = UIEdgeInsets(top: h, left: 0, bottom: h, right: 0)
        for (i, label) in labels.enumerated() {
            label.transform3D = CATransform3DIdentity
            label.frame = CGRect(x: 8, y: CGFloat(i) * h, width: max(0, bounds.width - 16), height: h)
        }
        scroll.contentSize = CGSize(width: bounds.width, height: CGFloat(labels.count) * h)
        band.frame = CGRect(x: 4, y: h, width: bounds.width - 8, height: h)
        fade.frame = bounds
        if !scroll.isTracking && !scroll.isDecelerating { scroll.contentOffset.y = offset(for: selectedIndex) }
        shape()
    }
    /// Tilts, shrinks and dims each row by its distance from the band: a turning drum.
    private func shape() {
        let h = max(1, row), middle = scroll.contentOffset.y + bounds.height / 2
        for label in labels {
            let distance = (label.center.y - middle) / h // 0 in the band, ±1 one row away
            let d = max(-1.6, min(1.6, distance))
            var t = CATransform3DIdentity; t.m34 = -1 / 260
            t = CATransform3DRotate(t, -d * 0.62, 1, 0, 0)
            t = CATransform3DScale(t, 1 - abs(d) * 0.12, 1 - abs(d) * 0.12, 1)
            label.layer.transform = t
            label.alpha = max(0.15, 1 - abs(d) * 0.5)
            let centred = abs(distance) < 0.5
            label.font = .systemFont(ofSize: centred ? 16 : 14, weight: centred ? .semibold : .regular)
            label.textColor = centred ? .label : .secondaryLabel
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        shape()
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        let index = centreIndex
        if index != tickIndex, items.indices.contains(index) { tickIndex = index; onTick?() }
    }
    /// Always come to rest with an item in the band.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
        let h = max(1, row)
        let index = min(max(0, Int(((target.pointee.y + scroll.contentInset.top) / h).rounded())), max(0, items.count - 1))
        target.pointee.y = offset(for: index)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settle() }
    private func settle() {
        guard !items.isEmpty else { return }
        let index = min(max(0, centreIndex), items.count - 1)
        guard index != selectedIndex else { return }
        selectedIndex = index; accessibilityValue = items[index]; onChange?(index)
    }
    /// Upper row steps back, lower row steps forward, the band steps forward (wrapping).
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard !items.isEmpty else { return }
        let y = tap.location(in: self).y
        if y < row { roll(to: max(0, selectedIndex - 1)) }
        else if y > 2 * row { roll(to: min(items.count - 1, selectedIndex + 1)) }
        else { roll(to: (selectedIndex + 1) % items.count) }
    }
    func roll(to index: Int) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        onTick?(); scroll.setContentOffset(CGPoint(x: 0, y: offset(for: index)), animated: true)
    }
    override func accessibilityIncrement() { roll(to: min(items.count - 1, selectedIndex + 1)) }
    override func accessibilityDecrement() { roll(to: max(0, selectedIndex - 1)) }
}

/// On/off switch using the active theme accent with a sliding knob.
final class PanelToggle: UIControl {
    private let knob = UIView()
    private(set) var isOn = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        knob.backgroundColor = .white; knob.isUserInteractionEnabled = false
        knob.layer.shadowColor = UIColor.black.cgColor; knob.layer.shadowOpacity = 0.18; knob.layer.shadowRadius = 2; knob.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(knob)
        addAction(UIAction { [weak self] _ in guard let self else { return }; self.setOn(!self.isOn, animated: true); self.sendActions(for: .valueChanged) }, for: .touchUpInside)
        isAccessibilityElement = true; accessibilityTraits = .button
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tintColorDidChange() { super.tintColorDidChange(); apply() }
    override var intrinsicContentSize: CGSize { CGSize(width: 48, height: 28) }
    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        if animated { UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) { self.apply(); self.layoutIfNeeded() } } else { apply() }
    }
    private func apply() {
        backgroundColor = isOn ? tintColor : .tertiarySystemFill
        accessibilityValue = isOn ? L("开", "On") : L("关", "Off")
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        let size = bounds.height - 4
        knob.frame = CGRect(x: isOn ? bounds.width - size - 2 : 2, y: 2, width: size, height: size); knob.layer.cornerRadius = size / 2
    }
}

/// [from ▲▼]  ⇄  [to ▲▼] on one line.
final class LanguagePairRow: UIView {
    let source = DrumPicker(), target = DrumPicker(), swap = UIButton(type: .custom)
    override init(frame: CGRect) {
        super.init(frame: frame)
        swap.setImage(UIImage(systemName: "arrow.left.arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        swap.backgroundColor = (tintColor ?? .systemBlue).withAlphaComponent(0.14)
        swap.layer.cornerRadius = 9; swap.layer.cornerCurve = .continuous
        swap.accessibilityLabel = L("交换方向", "Swap direction"); swap.accessibilityIdentifier = "keyboard.panel.swap"
        source.accessibilityLabel = L("原文语言", "From"); target.accessibilityLabel = L("译文语言", "To")
        source.accessibilityIdentifier = "keyboard.panel.source"; target.accessibilityIdentifier = "keyboard.panel.target"
        for view in [source, swap, target] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tintColorDidChange() {
        super.tintColorDidChange()
        swap.backgroundColor = (tintColor ?? .systemBlue).withAlphaComponent(0.14)
        swap.imageView?.tintColor = .label
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let gap: CGFloat = 8, swapWidth: CGFloat = 44, drum = max(0, (bounds.width - swapWidth - 2 * gap) / 2)
        source.frame = CGRect(x: 0, y: 0, width: drum, height: bounds.height)
        // The swap button lines up with the rollers' middle band.
        let band = min(40, bounds.height / 3 + 6)
        swap.frame = CGRect(x: drum + gap, y: (bounds.height - band) / 2, width: swapWidth, height: band)
        target.frame = CGRect(x: bounds.width - drum, y: 0, width: drum, height: bounds.height)
    }
}

/// A title with a RIMES toggle on the right.
final class PanelSwitchRow: UIView {
    let label = UILabel(), toggle = PanelToggle()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 15, weight: .medium); label.textColor = .label
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.8
        addSubview(label); addSubview(toggle)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let size = toggle.intrinsicContentSize
        toggle.frame = CGRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        label.frame = CGRect(x: 0, y: 0, width: max(0, toggle.frame.minX - 12), height: bounds.height)
        toggle.accessibilityLabel = label.text
    }
}
