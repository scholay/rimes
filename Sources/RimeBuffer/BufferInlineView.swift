import Cocoa
import QuartzCore

/// Dense, shared chrome metrics for passive text blocks. Keeping these values
/// together prevents ordinary, preedit, message, and translation blocks from
/// drifting back to different padding rules.
enum BufferInlineMetrics {
    static let blockSpacing: CGFloat = 3
    static let railHorizontalInset: CGFloat = 5
    static let chipHorizontalInset: CGFloat = 4
    static let chipVerticalInset: CGFloat = 1
    static let chipHeight: CGFloat = 20
    static let chipCornerRadius: CGFloat = 5
    static let contentSpacing: CGFloat = 3
    static let originBadgeSize: CGFloat = 5
    static let messageHorizontalInset: CGFloat = 5

    /// Width used by repeated block chrome, excluding text and the rail edge.
    static func packedBlockChromeWidth(blockCount: Int,
                                       badgedBlockCount: Int) -> CGFloat {
        let blocks = max(0, blockCount)
        let badges = min(max(0, badgedBlockCount), blocks)
        let gaps = max(0, blocks - 1)
        return CGFloat(blocks) * chipHorizontalInset * 2
            + CGFloat(gaps) * blockSpacing
            + CGFloat(badges) * (originBadgeSize + contentSpacing)
    }
}

struct TranslationRailRoleSymbol: Equatable {
    let name: String
    let accessibilityLabel: String
}

enum TranslationRailRoleSymbolRules {
    static func resolve(_ role: String, target: Bool) -> TranslationRailRoleSymbol {
        switch role {
        case "原": return .init(name: "text.bubble", accessibilityLabel: "原始内容")
        case "译": return .init(name: "globe", accessibilityLabel: "翻译结果")
        case "答": return .init(name: "sparkles", accessibilityLabel: "AI 回答")
        case "拼": return .init(name: "keyboard", accessibilityLabel: "拼音输入")
        case "文": return .init(name: "text.bubble.fill", accessibilityLabel: "转换结果")
        case "搜": return .init(name: "magnifyingglass", accessibilityLabel: "提示词查询")
        case "词": return .init(name: "doc.text.magnifyingglass", accessibilityLabel: "提示词结果")
        default:
            return target
                ? .init(name: "sparkles", accessibilityLabel: "处理结果")
                : .init(name: "text.bubble", accessibilityLabel: "原始内容")
        }
    }
}

/// Mutable translation chip used by keyed rail reconciliation. Keeping the
/// view and label alive across snapshots avoids stack-view teardown flicker and
/// lets consciousness-stream input distinguish a confirmed prefix from an
/// inert tail retained while the next full-context request catches up.
private final class TranslationRailChipView: NSStackView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let target: Bool
    private var activationHandler: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerHovered = false
    private var pointerPressed = false
    private var renderedSelected = false
    private var renderedStale = false
    private var renderedScale: CGFloat = 2
    private(set) var renderedRetainedTailStart: Int?

    init(target: Bool) {
        self.target = target
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = BufferInlineMetrics.contentSpacing
        edgeInsets = NSEdgeInsets(
            top: BufferInlineMetrics.chipVerticalInset,
            left: BufferInlineMetrics.chipHorizontalInset,
            bottom: BufferInlineMetrics.chipVerticalInset,
            right: BufferInlineMetrics.chipHorizontalInset
        )
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.widthAnchor.constraint(
                lessThanOrEqualToConstant: target ? 900 : 1200
            ),
            heightAnchor.constraint(equalToConstant: BufferInlineMetrics.chipHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if activationHandler != nil, bounds.contains(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let activationHandler else {
            super.mouseDown(with: event)
            return
        }
        pointerPressed = true
        applySurfaceAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerPressed = false
            self.applySurfaceAppearance()
            activationHandler()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        activationHandler != nil
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard activationHandler != nil else { return }
        pointerHovered = true
        applySurfaceAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerHovered = false
        pointerPressed = false
        applySurfaceAppearance()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if activationHandler != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func update(text: String,
                ordinal: Int? = nil,
                selected: Bool = false,
                retainedTailStart: Int? = nil,
                stale: Bool,
                scale: CGFloat,
                activationHandler: (() -> Void)? = nil) {
        self.activationHandler = activationHandler
        renderedSelected = selected
        renderedStale = stale
        renderedScale = scale
        if activationHandler == nil {
            pointerHovered = false
            pointerPressed = false
        }
        window?.invalidateCursorRects(for: self)
        renderedRetainedTailStart = nil
        let prefix: String
        if let ordinal {
            prefix = selected ? "✓ \(ordinal) · " : "\(ordinal) · "
        } else {
            prefix = ""
        }
        let combined = prefix + text
        let attributed = NSMutableAttributedString(
            string: combined,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: RimeUI.textPrimary,
            ]
        )
        if !prefix.isEmpty {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: selected ? RimeUI.accentBlue : RimeUI.textSecondary,
            ], range: NSRange(location: 0, length: prefix.utf16.count))
        }
        if let retainedTailStart {
            let textLength = text.utf16.count
            let start = min(max(retainedTailStart, 0), textLength)
            if start < textLength {
                renderedRetainedTailStart = start
                attributed.addAttribute(
                    .foregroundColor,
                    value: RimeUI.textMuted.withAlphaComponent(0.58),
                    range: NSRange(location: prefix.utf16.count + start,
                                   length: textLength - start)
                )
            }
        }
        valueLabel.attributedStringValue = attributed
        valueLabel.toolTip = text
        toolTip = activationHandler == nil ? text : "\(text)\n点击选择"
        applySurfaceAppearance()
    }

    private func applySurfaceAppearance() {
        let selectable = activationHandler != nil && !renderedStale
        alphaValue = renderedStale ? 0.70 : (pointerPressed ? 0.82 : 1)
        layer?.cornerRadius = BufferInlineMetrics.chipCornerRadius
        let extraEmphasis: CGFloat
        if selectable, pointerPressed {
            extraEmphasis = 0.10
        } else if selectable, pointerHovered {
            extraEmphasis = 0.05
        } else {
            extraEmphasis = 0
        }
        layer?.backgroundColor = (target
            ? RimeUI.accentBlue.withAlphaComponent(
                renderedSelected
                    ? (RimeUI.isNight ? 0.30 : 0.20) + extraEmphasis
                    : (RimeUI.isNight ? 0.22 : 0.14) + extraEmphasis
            )
            : RimeUI.surface2).cgColor
        layer?.borderColor = (renderedSelected || pointerHovered
            ? RimeUI.accentBlue
            : RimeUI.border).cgColor
        layer?.borderWidth = 1 / max(renderedScale, 1)
    }

    func scrub() {
        activationHandler = nil
        pointerHovered = false
        pointerPressed = false
        renderedSelected = false
        renderedStale = false
        window?.invalidateCursorRects(for: self)
        renderedRetainedTailStart = nil
        valueLabel.stringValue = ""
        valueLabel.toolTip = nil
        toolTip = nil
    }
}

private final class TranslationRailMessageView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = BufferInlineMetrics.chipCornerRadius
        valueLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: BufferInlineMetrics.messageHorizontalInset
            ),
            valueLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -BufferInlineMetrics.messageHorizontalInset
            ),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            heightAnchor.constraint(equalToConstant: BufferInlineMetrics.chipHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ text: String) {
        valueLabel.stringValue = text
        valueLabel.toolTip = text
        valueLabel.textColor = .systemOrange
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
    }

    func scrub() {
        valueLabel.stringValue = ""
        valueLabel.toolTip = nil
    }
}

/// One independently scrollable target row. The stable row key lets a stream
/// candidate keep its row while partial text grows or the selection changes.
private final class TranslationTargetRail {
    let key: Int
    let scroll = NSScrollView()
    let row = NSStackView()
    let leadingPlaceholder = NSView()
    let trailingSpacer = NSView()

    init(key: Int) {
        self.key = key
        leadingPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingPlaceholder.widthAnchor.constraint(equalToConstant: 14),
            leadingPlaceholder.heightAnchor.constraint(equalToConstant: 14),
        ])
        leadingPlaceholder.setContentHuggingPriority(.required, for: .horizontal)
        leadingPlaceholder.setContentCompressionResistancePriority(.required,
                                                                   for: .horizontal)
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentCompressionResistancePriority(.defaultLow,
                                                               for: .horizontal)
    }
}

struct BufferTranslationRailLayoutProbe {
    struct Rail {
        let key: Int?
        let viewportFrame: NSRect
        let viewportHeight: CGFloat
        let documentHeight: CGFloat
    }

    let boundsHeight: CGFloat
    let containerHeight: CGFloat
    let rails: [Rail]
}

/// Compact block rail used by the independent workbench window. It never holds
/// an IMK client or action buttons; it only renders staged blocks.
final class BufferInlineView: NSView {
    var onDerivedTargetSelection: ((UUID) -> Void)?

    static let standardPreferredHeight: CGFloat = 34
    static let translationPreferredHeight: CGFloat = 68
    static let additionalTranslationTargetRowHeight: CGFloat = 31

    static func translationPreferredHeight(targetRows: Int) -> CGFloat {
        translationPreferredHeight
            + CGFloat(min(max(targetRows, 1), 3) - 1)
                * additionalTranslationTargetRowHeight
    }

    private struct RenderedBlock: Equatable {
        let id: UUID
        let text: String
        let origin: Origin
        let pluginMetadata: BufferModel.PluginMetadata?
    }

    private struct RenderSignature: Equatable {
        let blocks: [RenderedBlock]
        let insertionIndex: Int
        let allContentSelected: Bool
        let active: Bool
        let preedit: String
        let loadingMessage: String?
        let loadingActive: Bool
        let translation: TranslationRailSnapshot?
        let shielded: Bool
        let isNight: Bool
    }

    private let chipScroll = NSScrollView()
    private let chipRow = NSStackView()
    private let normalRailContainer = NSStackView()
    private let translationContainer = NSStackView()
    private let translationSourceScroll = NSScrollView()
    private let translationSourceRow = NSStackView()
    private let leadingSpacer = NSView()
    private let translationSourceSpacer = NSView()
    private let caretView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "等待暂存内容")
    private let translationSourceEmptyLabel = NSTextField(labelWithString: "等待原文")
    private let translationTargetEmptyLabel = NSTextField(labelWithString: "等待译文")
    private let loadingIndicator = NSProgressIndicator()
    private let enterHoldProgressLayer = CALayer()
    private var renderedBlockIDs: [UUID] = []
    private var translationSourceRoleView: NSImageView?
    private var translationTargetRoleView: NSImageView?
    private var translationSourceChipView: TranslationRailChipView?
    private var translationTargetRails: [Int: TranslationTargetRail] = [:]
    private var renderedTranslationTargetRowKeys: [Int] = []
    private var translationTargetChipViews: [UUID: TranslationRailChipView] = [:]
    private var translationMessageView: TranslationRailMessageView?
    private var translationLoadingActive = false
    private var lastRenderSignature: RenderSignature?
    private var contentShielded = false
    private var enterHoldProgress: CGFloat?
    private(set) var renderPassCount = 0
    private(set) var renderedSelectedStandardBlockCount = 0
    private(set) var renderedTranslationSourceSelected = false
    var renderedBlockCount: Int { renderedBlockIDs.count }
    var renderedTranslationTargetViewIdentities: [ObjectIdentifier] {
        renderedBlockIDs.compactMap {
            translationTargetChipViews[$0].map(ObjectIdentifier.init)
        }
    }
    var renderedTranslationRetainedTailStarts: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: translationTargetChipViews.compactMap { id, chip in
            chip.renderedRetainedTailStart.map { (id, $0) }
        })
    }
    var isEnterHoldProgressVisible: Bool { enterHoldProgress != nil }
    var renderedTextFragments: [String] {
        func collect(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(collect)
        }
        return collect(chipRow)
            + collect(translationSourceRow)
            + renderedTranslationTargetRowKeys.flatMap {
                translationTargetRails[$0].map { collect($0.row) } ?? []
            }
    }

    var preferredHeight: CGFloat {
        translationContainer.isHidden
            ? Self.standardPreferredHeight
            : Self.translationPreferredHeight(
                targetRows: renderedTranslationTargetRowKeys.count
            )
    }

    var usesStackedTranslationLayout: Bool { !translationContainer.isHidden }
    var translationRailCount: Int {
        usesStackedTranslationLayout
            ? 1 + max(renderedTranslationTargetRowKeys.count, 1)
            : 0
    }
    var renderedTranslationTargetRowCount: Int {
        usesStackedTranslationLayout ? max(renderedTranslationTargetRowKeys.count, 1) : 0
    }
    var translationLayoutProbe: BufferTranslationRailLayoutProbe {
        let source = BufferTranslationRailLayoutProbe.Rail(
            key: nil,
            viewportFrame: translationSourceScroll.convert(
                translationSourceScroll.bounds,
                to: self
            ),
            viewportHeight: translationSourceScroll.contentSize.height,
            documentHeight: translationSourceRow.frame.height
        )
        let targets = renderedTranslationTargetRowKeys.compactMap { key in
            translationTargetRails[key].map { rail in
                BufferTranslationRailLayoutProbe.Rail(
                    key: key,
                    viewportFrame: rail.scroll.convert(
                        rail.scroll.bounds,
                        to: self
                    ),
                    viewportHeight: rail.scroll.contentSize.height,
                    documentHeight: rail.row.frame.height
                )
            }
        }
        return BufferTranslationRailLayoutProbe(
            boundsHeight: bounds.height,
            containerHeight: translationContainer.bounds.height,
            rails: [source] + targets
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        enterHoldProgressLayer.cornerRadius = 1
        enterHoldProgressLayer.zPosition = 50
        enterHoldProgressLayer.opacity = 0
        layer?.addSublayer(enterHoldProgressLayer)
        updateHairlineWidth()

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.lineBreakMode = .byTruncatingTail
        for label in [translationSourceEmptyLabel, translationTargetEmptyLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
        }

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            loadingIndicator.widthAnchor.constraint(equalToConstant: 12),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])

        chipRow.orientation = .horizontal
        chipRow.spacing = BufferInlineMetrics.blockSpacing
        chipRow.alignment = .centerY
        chipRow.distribution = .fill
        for spacer in [leadingSpacer, translationSourceSpacer] {
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        caretView.wantsLayer = true
        caretView.layer?.cornerRadius = 1
        caretView.translatesAutoresizingMaskIntoConstraints = false
        caretView.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caretView.heightAnchor.constraint(equalToConstant: 18).isActive = true

        configureHorizontalRail(chipScroll, row: chipRow)
        chipScroll.heightAnchor.constraint(equalToConstant: 24).isActive = true

        normalRailContainer.addArrangedSubview(chipScroll)
        normalRailContainer.orientation = .horizontal
        normalRailContainer.alignment = .centerY
        normalRailContainer.edgeInsets = NSEdgeInsets(
            top: 5,
            left: BufferInlineMetrics.railHorizontalInset,
            bottom: 5,
            right: BufferInlineMetrics.railHorizontalInset
        )
        normalRailContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(normalRailContainer)

        configureHorizontalRail(translationSourceScroll, row: translationSourceRow)
        let initialTargetRail = makeTranslationTargetRail(key: 0)
        translationTargetRails[0] = initialTargetRail
        renderedTranslationTargetRowKeys = [0]
        translationContainer.orientation = .vertical
        translationContainer.alignment = .width
        translationContainer.distribution = .fillEqually
        translationContainer.spacing = 4
        translationContainer.translatesAutoresizingMaskIntoConstraints = false
        translationContainer.addArrangedSubview(translationSourceScroll)
        translationContainer.addArrangedSubview(initialTargetRail.scroll)
        translationContainer.isHidden = true
        addSubview(translationContainer)
        NSLayoutConstraint.activate([
            normalRailContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            normalRailContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            normalRailContainer.topAnchor.constraint(equalTo: topAnchor),
            normalRailContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            translationContainer.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: BufferInlineMetrics.railHorizontalInset
            ),
            translationContainer.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -BufferInlineMetrics.railHorizontalInset
            ),
            translationContainer.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            translationContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureHorizontalRail(_ scroll: NSScrollView, row: NSStackView) {
        row.orientation = .horizontal
        row.spacing = BufferInlineMetrics.blockSpacing
        row.alignment = .centerY
        row.distribution = .fill
        // NSScrollView owns the document frame, which this view updates from
        // fittingSize/contentSize. An autoresizing-mask width/height constraint
        // would freeze a newly inserted third row at its initial 0×0 frame and
        // conflict with every chip before the host rail finishes resizing.
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = row
        // Horizontal rails scroll only along x; pinning the document height to
        // the clip viewport centers the 20pt chips inside each 27pt rail and
        // prevents AppKit from collapsing the document back to fittingSize.
        row.heightAnchor.constraint(
            equalTo: scroll.contentView.heightAnchor
        ).isActive = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.masksToBounds = true
    }

    private func makeTranslationTargetRail(key: Int) -> TranslationTargetRail {
        let rail = TranslationTargetRail(key: key)
        configureHorizontalRail(rail.scroll, row: rail.row)
        return rail
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateHairlineWidth()
    }

    override func layout() {
        super.layout()
        updateHairlineWidth()
        updateEnterHoldProgressLayer()
        if !translationContainer.isHidden {
            updateTranslationDocumentSizes()
        }
    }

    /// Host geometry changes and row reconciliation are deliberately separate
    /// operations. Recompute every document frame after the panel has reached
    /// its final height so 1↔2↔3-row transitions cannot retain stale sizes.
    func reconcileTranslationDocumentGeometry() {
        guard !translationContainer.isHidden else { return }
        layoutSubtreeIfNeeded()
        updateTranslationDocumentSizes()
    }

    private func updateHairlineWidth() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.borderWidth = 1 / max(scale, 1)
    }

    func setEnterHoldProgress(_ progress: Double?) {
        enterHoldProgress = progress.map { CGFloat(min(max($0, 0), 1)) }
        updateEnterHoldProgressLayer()
    }

    private func updateEnterHoldProgressLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let enterHoldProgress {
            enterHoldProgressLayer.opacity = 1
            enterHoldProgressLayer.frame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width * enterHoldProgress,
                height: 2
            )
        } else {
            enterHoldProgressLayer.opacity = 0
            enterHoldProgressLayer.frame = .zero
        }
        CATransaction.commit()
    }

    @discardableResult
    func refresh(preedit: String = "", shielded: Bool = false) -> Bool {
        // The privacy branch must run before asking either the source model or
        // a derived workspace for text. Besides keeping the rail hidden, this
        // replaces the cached render signature with a plaintext-free value.
        if shielded { return refreshShielded() }
        return refresh(preedit: preedit,
                       translation: DerivedBufferWorkspaceRouter
                            .selectedWorkspace?.railSnapshot)
    }

    /// Runtime seam for callers that already froze a derived snapshot to size
    /// the panel. Using the exact same value for geometry and rendering avoids
    /// a one-frame row-count mismatch during streaming updates.
    @discardableResult
    func refresh(preedit: String = "",
                 shielded: Bool,
                 translationSnapshot: TranslationRailSnapshot?) -> Bool {
        if shielded { return refreshShielded() }
        return refresh(preedit: preedit, translation: translationSnapshot)
    }

    /// Deterministic standard-rail seam for CLI smoke tests and previews. It
    /// deliberately ignores the user's currently selected buffer plugin.
    @discardableResult
    func renderStandardForPreview(preedit: String = "",
                                  shielded: Bool = false) -> Bool {
        if shielded { return refreshShielded() }
        return refresh(preedit: preedit, translation: nil)
    }

    private func refresh(preedit: String,
                         translation: TranslationRailSnapshot?) -> Bool {
        let model = BufferModel.shared
        let preeditText = preedit.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = model.active
        let wasRenderingTranslation = !contentShielded
            && lastRenderSignature?.translation != nil
        contentShielded = false

        let signature = RenderSignature(
            blocks: model.blocks.map {
                RenderedBlock(id: $0.id,
                              text: $0.text,
                              origin: $0.origin,
                              pluginMetadata: $0.pluginMetadata)
            },
            insertionIndex: min(max(model.insertionIndex, 0), model.blocks.count),
            allContentSelected: model.allContentSelected,
            active: active,
            preedit: preeditText,
            loadingMessage: model.loadingMessage,
            loadingActive: model.transientLoadingActive,
            translation: translation,
            shielded: false,
            isNight: RimeUI.isNight
        )
        if signature == lastRenderSignature {
            isHidden = false
            applyAppearance()
            return false
        }
        lastRenderSignature = signature
        renderPassCount += 1

        if let translation {
            if !wasRenderingTranslation { resetRailContents() }
            normalRailContainer.isHidden = true
            translationContainer.isHidden = false
            renderedSelectedStandardBlockCount = 0
            renderedTranslationSourceSelected = translation.sourceSelected
            renderTranslation(translation, active: active)
            applyAppearance()
            layoutSubtreeIfNeeded()
            updateTranslationDocumentSizes()
            scrollTranslationRails(for: translation.phase)
            isHidden = false
            return true
        }

        resetRailContents()
        normalRailContainer.isHidden = false
        translationContainer.isHidden = true
        renderedSelectedStandardBlockCount = signature.allContentSelected
            ? model.blocks.count
            : 0
        renderedTranslationSourceSelected = false

        let insertionIndex = signature.insertionIndex
        if model.blocks.isEmpty, preeditText.isEmpty {
            emptyLabel.stringValue = model.loadingMessage ?? "等待暂存内容"
            if model.transientLoadingActive {
                chipRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
            }
            chipRow.addArrangedSubview(emptyLabel)
            if active {
                chipRow.addArrangedSubview(caretView)
            }
        } else if active {
            for index in 0...model.blocks.count {
                if index == insertionIndex {
                    if !preeditText.isEmpty {
                        chipRow.addArrangedSubview(preeditChip(text: preeditText))
                    }
                    if !signature.allContentSelected {
                        chipRow.addArrangedSubview(caretView)
                    }
                }
                if index < model.blocks.count {
                    chipRow.addArrangedSubview(chip(
                        for: model.blocks[index],
                        index: index,
                        selected: signature.allContentSelected
                    ))
                }
            }
        } else {
            for (index, block) in model.blocks.enumerated() {
                chipRow.addArrangedSubview(chip(
                    for: block,
                    index: index,
                    selected: signature.allContentSelected
                ))
            }
            if !preeditText.isEmpty {
                chipRow.addArrangedSubview(preeditChip(text: preeditText))
            }
        }
        if let message = model.loadingMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty,
           !(model.blocks.isEmpty && preeditText.isEmpty) {
            if model.transientLoadingActive {
                chipRow.addArrangedSubview(loadingIndicator)
                loadingIndicator.startAnimation(nil)
            }
            chipRow.addArrangedSubview(messageChip(text: message))
        }

        active ? startCaretBlinking() : stopCaretBlinking()
        applyAppearance()
        layoutSubtreeIfNeeded()
        updateChipDocumentSize()
        scrollChipsToInsertionPoint()
        isHidden = false
        return true
    }

    private func refreshShielded() -> Bool {
        contentShielded = true
        setEnterHoldProgress(nil)
        let signature = RenderSignature(
            blocks: [],
            insertionIndex: 0,
            allContentSelected: false,
            active: false,
            preedit: "",
            loadingMessage: nil,
            loadingActive: false,
            translation: nil,
            shielded: true,
            isNight: RimeUI.isNight
        )
        if signature == lastRenderSignature {
            isHidden = true
            applyAppearance()
            return false
        }
        lastRenderSignature = signature
        renderPassCount += 1
        resetRailContents()
        renderedSelectedStandardBlockCount = 0
        renderedTranslationSourceSelected = false
        normalRailContainer.isHidden = false
        translationContainer.isHidden = true
        emptyLabel.stringValue = "内容已隐藏"
        chipRow.addArrangedSubview(emptyLabel)
        stopCaretBlinking()
        isHidden = true
        applyAppearance()
        return true
    }

    /// Dev-only render seam used by the CLI smoke and visual previews. Runtime
    /// Runtime derived rails still come exclusively from their selected,
    /// trusted workspace.
    @discardableResult
    func renderTranslationForPreview(_ snapshot: TranslationRailSnapshot,
                                     active: Bool = true) -> Bool {
        lastRenderSignature = nil
        contentShielded = false
        if translationContainer.isHidden { resetRailContents() }
        normalRailContainer.isHidden = true
        translationContainer.isHidden = false
        renderedSelectedStandardBlockCount = 0
        renderedTranslationSourceSelected = snapshot.sourceSelected
        renderTranslation(snapshot, active: active)
        applyAppearance()
        layoutSubtreeIfNeeded()
        updateTranslationDocumentSizes()
        scrollTranslationRails(for: snapshot.phase)
        isHidden = false
        return usesStackedTranslationLayout && translationRailCount >= 2
    }

    private func renderTranslation(_ snapshot: TranslationRailSnapshot,
                                   active: Bool) {
        renderedBlockIDs.removeAll(keepingCapacity: true)
        let sourceRole = translationSourceRoleView
            ?? translationRoleIcon(snapshot.sourceRole, target: false)
        translationSourceRoleView = sourceRole
        updateTranslationRoleIcon(sourceRole,
                                  role: snapshot.sourceRole,
                                  target: false)
        var sourceViews: [NSView] = [sourceRole]
        if snapshot.sourceText.isEmpty {
            translationSourceEmptyLabel.stringValue = snapshot.sourceEmptyText
            sourceViews.append(translationSourceEmptyLabel)
        } else {
            let sourceChip = translationSourceChipView
                ?? TranslationRailChipView(target: false)
            translationSourceChipView = sourceChip
            sourceChip.update(
                text: snapshot.sourceText,
                selected: snapshot.sourceSelected,
                stale: false,
                scale: window?.backingScaleFactor ?? 2
            )
            sourceViews.append(sourceChip)
        }
        if active, !snapshot.sourceSelected { sourceViews.append(caretView) }
        sourceViews.append(translationSourceSpacer)
        reconcileArrangedSubviews(sourceViews, in: translationSourceRow)

        let targetRole = translationTargetRoleView
            ?? translationRoleIcon(snapshot.targetRole, target: true)
        translationTargetRoleView = targetRole
        updateTranslationRoleIcon(targetRole,
                                  role: snapshot.targetRole,
                                  target: true)
        let rowSnapshots: [TranslationOutputRow]
        if snapshot.outputRows.isEmpty {
            rowSnapshots = [TranslationOutputRow(key: 0,
                                                 blocks: snapshot.outputBlocks)]
        } else {
            rowSnapshots = Array(snapshot.outputRows.prefix(3))
        }
        let hasSelectableResults =
            (DerivedBufferWorkspaceRouter.selectedWorkspace
                as? any DerivedResultSelectionControls)?
                .ownsResultNavigation == true
        let desiredRowKeys = rowSnapshots.map(\.key)
        let oldRowKeys = Set(renderedTranslationTargetRowKeys)
        for key in desiredRowKeys where translationTargetRails[key] == nil {
            translationTargetRails[key] = makeTranslationTargetRail(key: key)
        }
        renderedTranslationTargetRowKeys = desiredRowKeys
        let desiredTargetScrolls = desiredRowKeys.compactMap {
            translationTargetRails[$0]?.scroll
        }
        reconcileArrangedSubviews(
            [translationSourceScroll] + desiredTargetScrolls,
            in: translationContainer
        )

        var loading = false
        var message: String?
        if snapshot.outputBlocks.isEmpty {
            switch snapshot.phase {
            case .waiting, .translating:
                loading = true
                message = snapshot.message ?? (snapshot.phase == .waiting
                    ? snapshot.waitingText
                    : snapshot.processingText)
            case .failed:
                message = snapshot.message ?? "处理失败"
            case .unavailable:
                message = snapshot.message ?? "插件不可用"
            case .idle, .ready:
                translationTargetEmptyLabel.stringValue = snapshot.targetEmptyText
            }
        } else {
            let liveIDs = Set(rowSnapshots.flatMap(\.blocks).map(\.id))
            let obsoleteIDs = translationTargetChipViews.keys.filter {
                !liveIDs.contains($0)
            }
            for id in obsoleteIDs {
                translationTargetChipViews[id]?.scrub()
                translationTargetChipViews.removeValue(forKey: id)
            }
            if snapshot.phase == .waiting || snapshot.phase == .translating {
                loading = true
                message = snapshot.message ?? snapshot.updatingText
            }
        }
        if snapshot.outputBlocks.isEmpty {
            for (_, chip) in translationTargetChipViews { chip.scrub() }
            translationTargetChipViews.removeAll()
        }
        if loading {
            if !translationLoadingActive {
                loadingIndicator.startAnimation(nil)
                translationLoadingActive = true
            }
        } else if translationLoadingActive {
            loadingIndicator.stopAnimation(nil)
            translationLoadingActive = false
        }
        if let message {
            let messageView = translationMessageView ?? TranslationRailMessageView()
            translationMessageView = messageView
            messageView.update(message)
        }

        for (rowIndex, rowSnapshot) in rowSnapshots.enumerated() {
            guard let rail = translationTargetRails[rowSnapshot.key] else { continue }
            var targetViews: [NSView] = [
                rowIndex == 0 ? targetRole : rail.leadingPlaceholder,
            ]
            if snapshot.outputBlocks.isEmpty, rowIndex == 0 {
                if !loading, message == nil {
                    targetViews.append(translationTargetEmptyLabel)
                }
            } else {
                let targetIsCurrent = snapshot.phase == .ready
                for block in rowSnapshot.blocks {
                    renderedBlockIDs.append(block.id)
                    let chip = translationTargetChipViews[block.id]
                        ?? TranslationRailChipView(target: true)
                    translationTargetChipViews[block.id] = chip
                    chip.update(
                        text: block.text,
                        ordinal: block.ordinal,
                        selected: block.selected,
                        retainedTailStart: block.retainedTailStart,
                        stale: !targetIsCurrent,
                        scale: window?.backingScaleFactor ?? 2,
                        activationHandler: hasSelectableResults ? { [weak self] in
                            self?.onDerivedTargetSelection?(block.id)
                        } : nil
                    )
                    targetViews.append(chip)
                }
            }
            if rowIndex == rowSnapshots.count - 1 {
                if loading { targetViews.append(loadingIndicator) }
                if let messageView = translationMessageView, message != nil {
                    targetViews.append(messageView)
                }
            }
            targetViews.append(rail.trailingSpacer)
            reconcileArrangedSubviews(targetViews, in: rail.row)
        }

        let obsoleteRowKeys = oldRowKeys.subtracting(desiredRowKeys)
        for key in obsoleteRowKeys {
            guard let rail = translationTargetRails.removeValue(forKey: key) else { continue }
            clearArrangedSubviews(of: rail.row)
            rail.scroll.removeFromSuperview()
        }
        active ? startCaretBlinking() : stopCaretBlinking()
    }

    private func reconcileArrangedSubviews(_ desired: [NSView],
                                           in row: NSStackView) {
        let desiredIDs = Set(desired.map(ObjectIdentifier.init))
        for view in row.arrangedSubviews
            where !desiredIDs.contains(ObjectIdentifier(view)) {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in desired.enumerated() {
            if view.superview !== row {
                if let previousRow = view.superview as? NSStackView {
                    previousRow.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                row.insertArrangedSubview(view, at: index)
                continue
            }
            guard row.arrangedSubviews.indices.contains(index),
                  row.arrangedSubviews[index] !== view else { continue }
            row.removeArrangedSubview(view)
            row.insertArrangedSubview(view, at: index)
        }
    }

    private func translationRoleIcon(_ role: String, target: Bool) -> NSImageView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateTranslationRoleIcon(icon, role: role, target: target)
        return icon
    }

    private func updateTranslationRoleIcon(_ icon: NSImageView,
                                           role: String,
                                           target: Bool) {
        let descriptor = TranslationRailRoleSymbolRules.resolve(role, target: target)
        icon.image = RimeUI.symbol(descriptor.name, pointSize: 10, weight: .semibold)
        icon.image?.isTemplate = true
        icon.contentTintColor = target ? RimeUI.accentBlue : RimeUI.textSecondary
        icon.toolTip = descriptor.accessibilityLabel
        icon.setAccessibilityElement(true)
        icon.setAccessibilityRole(.image)
        icon.setAccessibilityLabel(descriptor.accessibilityLabel)
    }

    /// Colored provenance dot for a non-local block. Rime commits (local typing)
    /// stay unbadged so ordinary use looks exactly as before; external origins
    /// get a 6pt dot whose color matches the source family.
    private func originBadge(for origin: Origin) -> NSView? {
        let color: NSColor
        switch origin {
        case .rime: return nil
        case .remotePeer: color = RimeUI.color(0x9B8CFF)        // paired Mac — violet
        case .marine, .plugin, .processor, .mcp:
            color = RimeUI.color(0xF59E0B) // local action/transform/agent — amber
        case .http, .sse, .ssh: color = RimeUI.color(0x4A9FD8)  // network feed — blue
        }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = BufferInlineMetrics.originBadgeSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: BufferInlineMetrics.originBadgeSize),
            dot.heightAnchor.constraint(equalToConstant: BufferInlineMetrics.originBadgeSize),
        ])
        return dot
    }

    private func chip(for block: BufferModel.Block,
                      index: Int,
                      selected: Bool = false) -> NSView {
        if renderedBlockIDs.count <= index {
            renderedBlockIDs.append(block.id)
        } else {
            renderedBlockIDs[index] = block.id
        }
        let label = NSTextField(labelWithString: block.text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = RimeUI.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = blockToolTip(block)

        let row = NSStackView(views: [label])
        row.spacing = BufferInlineMetrics.contentSpacing
        if let badge = originBadge(for: block.origin) {
            row.insertArrangedSubview(badge, at: 0)
            row.setCustomSpacing(BufferInlineMetrics.contentSpacing, after: badge)
        }
        if block.pluginMetadata?.incomplete == true {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.isDisplayedWhenStopped = false
            progress.toolTip = "插件正在生成，当前内容不可发送或编辑"
            progress.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                progress.widthAnchor.constraint(equalToConstant: 10),
                progress.heightAnchor.constraint(equalToConstant: 10),
            ])
            row.addArrangedSubview(progress)
            progress.startAnimation(nil)
        }
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = RimeUI.accentBlue.withAlphaComponent(
            selected
                ? (RimeUI.isNight ? 0.34 : 0.24)
                : (RimeUI.isNight ? 0.22 : 0.14)
        ).cgColor
        box.layer?.cornerRadius = BufferInlineMetrics.chipCornerRadius
        box.layer?.borderColor = (selected ? RimeUI.accentBlue : RimeUI.border).cgColor
        box.layer?.borderWidth = selected
            ? 1 / max(window?.backingScaleFactor ?? 2, 1)
            : 0
        box.toolTip = blockToolTip(block)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: box.leadingAnchor,
                constant: BufferInlineMetrics.chipHorizontalInset
            ),
            row.trailingAnchor.constraint(
                equalTo: box.trailingAnchor,
                constant: -BufferInlineMetrics.chipHorizontalInset
            ),
            row.topAnchor.constraint(
                equalTo: box.topAnchor,
                constant: BufferInlineMetrics.chipVerticalInset
            ),
            row.bottomAnchor.constraint(
                equalTo: box.bottomAnchor,
                constant: -BufferInlineMetrics.chipVerticalInset
            ),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            box.heightAnchor.constraint(equalToConstant: BufferInlineMetrics.chipHeight),
        ])
        return box
    }

    private func blockToolTip(_ block: BufferModel.Block) -> String {
        guard let metadata = block.pluginMetadata else { return block.text }
        var lines = [metadata.title, metadata.targetSummary]
            .compactMap { value -> String? in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
        if metadata.stale { lines.append("原投放目标已失效，接受前请重新确认") }
        if metadata.incomplete { lines.append("正在生成，完成并复核目标前不能发送") }
        if metadata.reviewedAsPlainText {
            lines.append("已人工确认并降级为普通文本；发送时不再绑定原目标")
        }
        lines.append(block.text)
        return lines.joined(separator: "\n")
    }

    private func preeditChip(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text
        label.textColor = RimeUI.textPrimary

        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = RimeUI.accentBlue.withAlphaComponent(
            RimeUI.isNight ? 0.34 : 0.22
        ).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = RimeUI.accentBlue.withAlphaComponent(0.45).cgColor
        box.layer?.cornerRadius = BufferInlineMetrics.chipCornerRadius
        box.toolTip = text
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: box.leadingAnchor,
                constant: BufferInlineMetrics.chipHorizontalInset
            ),
            row.trailingAnchor.constraint(
                equalTo: box.trailingAnchor,
                constant: -BufferInlineMetrics.chipHorizontalInset
            ),
            row.topAnchor.constraint(
                equalTo: box.topAnchor,
                constant: BufferInlineMetrics.chipVerticalInset
            ),
            row.bottomAnchor.constraint(
                equalTo: box.bottomAnchor,
                constant: -BufferInlineMetrics.chipVerticalInset
            ),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            box.heightAnchor.constraint(equalToConstant: BufferInlineMetrics.chipHeight),
        ])
        return box
    }

    private func messageChip(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .systemOrange
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = text

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        box.layer?.cornerRadius = BufferInlineMetrics.chipCornerRadius
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: box.leadingAnchor,
                constant: BufferInlineMetrics.messageHorizontalInset
            ),
            label.trailingAnchor.constraint(
                equalTo: box.trailingAnchor,
                constant: -BufferInlineMetrics.messageHorizontalInset
            ),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            box.heightAnchor.constraint(equalToConstant: BufferInlineMetrics.chipHeight),
        ])
        return box
    }

    private func configureIconButton(_ button: FirstMouseButton,
                                     symbolName: String,
                                     toolTip: String) {
        button.image = RimeUI.symbol(symbolName, pointSize: 13, weight: .semibold)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.focusRingType = .none
        button.toolTip = toolTip
        button.contentTintColor = RimeUI.textSecondary
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func clearArrangedSubviews(of row: NSStackView) {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    private func resetRailContents() {
        translationSourceChipView?.scrub()
        translationTargetChipViews.values.forEach { $0.scrub() }
        translationMessageView?.scrub()
        clearArrangedSubviews(of: chipRow)
        clearArrangedSubviews(of: translationSourceRow)
        for rail in translationTargetRails.values {
            clearArrangedSubviews(of: rail.row)
            rail.scroll.removeFromSuperview()
        }
        loadingIndicator.stopAnimation(nil)
        translationLoadingActive = false
        translationSourceRoleView = nil
        translationTargetRoleView = nil
        translationSourceChipView = nil
        translationTargetRails.removeAll()
        let initialTargetRail = makeTranslationTargetRail(key: 0)
        translationTargetRails[0] = initialTargetRail
        renderedTranslationTargetRowKeys = [0]
        reconcileArrangedSubviews(
            [translationSourceScroll, initialTargetRail.scroll],
            in: translationContainer
        )
        translationTargetChipViews.removeAll()
        translationMessageView = nil
        renderedBlockIDs.removeAll(keepingCapacity: true)
        chipRow.addArrangedSubview(leadingSpacer)
    }

    private func updateChipDocumentSize() {
        let fit = chipRow.fittingSize
        let documentWidth = max(fit.width, chipScroll.contentSize.width)
        chipRow.setFrameSize(NSSize(width: documentWidth, height: 24))
        chipRow.needsLayout = true
        chipRow.layoutSubtreeIfNeeded()
    }

    private func updateTranslationDocumentSizes() {
        updateDocumentSize(for: translationSourceRow, in: translationSourceScroll)
        for key in renderedTranslationTargetRowKeys {
            guard let rail = translationTargetRails[key] else { continue }
            updateDocumentSize(for: rail.row, in: rail.scroll)
        }
    }

    private func updateDocumentSize(for row: NSStackView, in scroll: NSScrollView) {
        let fit = row.fittingSize
        let documentWidth = max(fit.width, scroll.contentSize.width)
        let documentHeight = max(fit.height, scroll.contentSize.height)
        row.setFrameSize(NSSize(width: documentWidth, height: documentHeight))
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
    }

    private func scrollTranslationRails(for phase: TranslationRailSnapshot.Phase) {
        scrollToEnd(row: translationSourceRow, in: translationSourceScroll)
        for key in renderedTranslationTargetRowKeys {
            guard let rail = translationTargetRails[key] else { continue }
            if phase == .waiting || phase == .translating {
                scrollToEnd(row: rail.row, in: rail.scroll)
            } else {
                scrollToStart(in: rail.scroll)
            }
        }
    }

    private func scrollToStart(in scroll: NSScrollView) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollToEnd(row: NSView, in scroll: NSScrollView) {
        let maxX = max(0, row.frame.width - scroll.contentSize.width)
        scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollChipsToInsertionPoint() {
        let maxX = max(0, chipRow.frame.width - chipScroll.contentSize.width)
        if BufferModel.shared.loadingMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false {
            chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            chipScroll.reflectScrolledClipView(chipScroll.contentView)
            return
        }
        guard BufferModel.shared.active else {
            chipScroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
            chipScroll.reflectScrolledClipView(chipScroll.contentView)
            return
        }

        let visible = chipScroll.contentView.bounds
        let caretFrame = caretView.frame.insetBy(dx: -14, dy: 0)
        var targetX = visible.minX
        if caretFrame.minX < visible.minX {
            targetX = max(0, caretFrame.minX)
        } else if caretFrame.maxX > visible.maxX {
            targetX = max(0, min(maxX, caretFrame.maxX - chipScroll.contentSize.width))
        } else {
            targetX = min(max(0, visible.minX), maxX)
        }

        chipScroll.contentView.scroll(to: NSPoint(x: targetX, y: 0))
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    private func applyAppearance() {
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.borderColor = RimeUI.borderStrong.cgColor
        translationSourceScroll.layer?.backgroundColor = RimeUI.surface2
            .withAlphaComponent(RimeUI.isNight ? 0.70 : 0.78).cgColor
        for rail in translationTargetRails.values {
            rail.scroll.layer?.backgroundColor = RimeUI.accentBlue
                .withAlphaComponent(RimeUI.isNight ? 0.13 : 0.08).cgColor
        }
        caretView.layer?.backgroundColor = RimeUI.accentBlue.cgColor
        enterHoldProgressLayer.backgroundColor = RimeUI.accentBlue.cgColor
        emptyLabel.textColor = RimeUI.isNight ? RimeUI.textSecondary : RimeUI.textMuted
        translationSourceEmptyLabel.textColor = RimeUI.textSecondary
        translationTargetEmptyLabel.textColor = RimeUI.textSecondary
    }

    private func startCaretBlinking() {
        guard caretView.layer?.animation(forKey: "bufferCaretBlink") == nil else { return }
        caretView.layer?.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.15
        animation.duration = 0.58
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        caretView.layer?.add(animation, forKey: "bufferCaretBlink")
    }

    private func stopCaretBlinking() {
        caretView.layer?.removeAnimation(forKey: "bufferCaretBlink")
        caretView.layer?.opacity = 1
    }

}

/// A button that works on the first click inside a never-key panel.
class FirstMouseButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?
    private var pointerHovered = false
    private var pointerPressed = false
    private var previewPointerState: BufferWorkbenchPointerState?

    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled { pointerPressed = false }
            refreshInteractionAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configurePointerFeedback()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configurePointerFeedback()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: BufferWorkbenchPointerRules.cursor(
            enabled: isEnabled
        ).cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        pointerHovered = true
        refreshInteractionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        pointerHovered = false
        refreshInteractionAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPointerPressed(true)
        defer { setPointerPressed(false) }
        super.mouseDown(with: event)
    }

    func setPointerPressed(_ pressed: Bool) {
        pointerPressed = pressed
        refreshInteractionAppearance()
    }

    func refreshInteractionAppearance() {
        let state = previewPointerState ?? BufferWorkbenchPointerRules.state(
            enabled: isEnabled,
            hovered: pointerHovered,
            pressed: pointerPressed
        )
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = BufferWorkbenchPointerRules.backgroundColor(for: state).cgColor
        layer?.borderColor = BufferWorkbenchPointerRules.borderColor(for: state).cgColor
        layer?.borderWidth = (state == .idle || state == .disabled)
            ? 0
            : 1 / max(window?.backingScaleFactor ?? 2, 1)
        window?.invalidateCursorRects(for: self)
    }

    func setPreviewPointerState(_ state: BufferWorkbenchPointerState?) {
        previewPointerState = state
        refreshInteractionAppearance()
    }

    private func configurePointerFeedback() {
        wantsLayer = true
        layer?.masksToBounds = true
        refreshInteractionAppearance()
    }
}

final class HoldProgressButton: FirstMouseButton {
    var holdDuration: TimeInterval = 1.2

    private var holdStartedAt: CFAbsoluteTime = 0
    private var completed = false
    private var externalProgressActive = false
    private var progressAmount: CGFloat = 0
    private var progressVisible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupProgressDrawing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupProgressDrawing()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawIconFillProgress()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPointerPressed(true)
        defer { setPointerPressed(false) }
        externalProgressActive = false
        beginHold()

        var tracking = true
        while tracking {
            if !completed {
                updateHoldProgress()
            }

            guard let window,
                  let next = window.nextEvent(
                    matching: NSEvent.EventTypeMask([.leftMouseDragged, .leftMouseUp]),
                    until: Date(timeIntervalSinceNow: 1.0 / 60.0),
                    inMode: .eventTracking,
                    dequeue: true
                  ) else {
                continue
            }

            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !bounds.insetBy(dx: -8, dy: -8).contains(point), !completed {
                    cancelHold()
                    tracking = false
                }
            case .leftMouseUp:
                tracking = false
            default:
                break
            }
        }

        resetProgressAfterTracking()
    }

    func setExternalProgress(_ progress: Double?) {
        guard let progress else {
            guard externalProgressActive else { return }
            externalProgressActive = false
            setIconProgress(0, visible: false)
            return
        }

        externalProgressActive = true
        let clamped = CGFloat(min(max(progress, 0), 1))
        setIconProgress(clamped, visible: clamped > 0)
    }

    private func setupProgressDrawing() {
        wantsLayer = true
    }

    private func beginHold() {
        completed = false
        holdStartedAt = CFAbsoluteTimeGetCurrent()
        setIconProgress(0, visible: true)
    }

    private func updateHoldProgress() {
        let elapsed = CFAbsoluteTimeGetCurrent() - holdStartedAt
        let progress = min(max(elapsed / max(holdDuration, 0.1), 0), 1)
        setIconProgress(CGFloat(progress), visible: true)
        if progress >= 1 {
            completed = true
            sendAction(action, to: target)
        }
    }

    private func cancelHold() {
        completed = false
        setIconProgress(0, visible: false)
    }

    private func resetProgressAfterTracking() {
        if completed {
            setIconProgress(1, visible: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.externalProgressActive else { return }
            self.setIconProgress(0, visible: false)
            self.completed = false
        }
    }

    private func setIconProgress(_ progress: CGFloat, visible: Bool) {
        progressAmount = min(max(progress, 0), 1)
        progressVisible = visible
        needsDisplay = true
    }

    private func drawIconFillProgress() {
        guard progressVisible,
              progressAmount > 0,
              let symbol = image,
              let tinted = tintedSymbolImage(symbol, color: RimeUI.accentBlue) else {
            return
        }

        let rect = iconRect(for: symbol)
        guard rect.width > 0, rect.height > 0 else { return }

        let fillHeight = rect.height * progressAmount
        let clipRect = isFlipped
            ? NSRect(x: rect.minX, y: rect.maxY - fillHeight, width: rect.width, height: fillHeight)
            : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillHeight)

        NSGraphicsContext.saveGraphicsState()
        clipRect.clip()
        tinted.draw(in: rect,
                    from: NSRect(origin: .zero, size: tinted.size),
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func iconRect(for symbol: NSImage) -> NSRect {
        let maxSide = max(1, min(bounds.width, bounds.height) - 8)
        let imageSize = symbol.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }

        let scale = min(1, maxSide / max(imageSize.width, imageSize.height))
        let drawSize = NSSize(width: imageSize.width * scale,
                              height: imageSize.height * scale)
        return NSRect(x: bounds.midX - drawSize.width / 2,
                      y: bounds.midY - drawSize.height / 2,
                      width: drawSize.width,
                      height: drawSize.height)
    }

    private func tintedSymbolImage(_ symbol: NSImage, color: NSColor) -> NSImage? {
        let image = NSImage(size: symbol.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: nil)
        color.set()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
