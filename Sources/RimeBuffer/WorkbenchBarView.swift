import Cocoa

/// Visual realization of the three-layer workbench, using the candidate
/// window's own palette (RimeUI) — deliberately understated, one accent, one
/// chip style shared across all layers:
///   ① 源头   a SINGLE external source, just its name (shared chip style)
///   ② 缓冲区  staged chunks, laid out right-to-left, + active preedit + caret
///   ③ 候选窗  the existing numbered candidate strip (unchanged look)
///
/// Standalone visual; live wiring into CandidateWindow lands with M2.
final class WorkbenchBarView: NSView {
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 108))
        wantsLayer = true
        layer?.backgroundColor = RimeUI.candidateBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderColor = RimeUI.border.cgColor
        layer?.borderWidth = 1

        let stack = NSStackView(views: [sourceRow(), divider(), bufferRow(), divider(), candidateRow()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let contentWidth: CGFloat = 436

    // ① The one external source currently feeding the buffer — name only, right-aligned.
    private func sourceRow() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = RimeUI.accentBlue.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let name = label("远端 · MacBook Pro", RimeUI.textSecondary, 11, weight: .medium)
        let source = chip([dot, name], bg: RimeUI.surface2, border: RimeUI.border)
        return alignedRow([source], right: true)
    }

    // ② Staged chunks, right-to-left: newest on the right, then the live preedit.
    private func bufferRow() -> NSView {
        let ordinary = ["朋友", "晚点"].map {
            chip([label($0, RimeUI.textPrimary, 13, weight: .medium)],
                 bg: RimeUI.surface3, border: RimeUI.border)
        }
        let preedit = chip([label("shij", RimeUI.textPrimary, 13, weight: .semibold)],
                           bg: RimeUI.bufferBg2, border: RimeUI.accentBlue)
        let caret = NSView()
        caret.wantsLayer = true
        caret.layer?.backgroundColor = RimeUI.accentBlue.cgColor
        caret.translatesAutoresizingMaskIntoConstraints = false
        caret.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caret.heightAnchor.constraint(equalToConstant: 17).isActive = true
        // Right-to-left, matching the existing buffer-active layout: first block
        // sits rightmost, newer blocks grow left, the active preedit + caret at
        // the left edge.
        return alignedRow([caret, preedit] + ordinary.reversed(), right: true)
    }

    // ③ The existing candidate strip — numbered, first one selected, left-aligned.
    private func candidateRow() -> NSView {
        let items = ["时间", "实践", "事件", "时刻", "识记"].enumerated().map { i, text -> NSView in
            let selected = i == 0
            let num = label("\(i + 1)", selected ? RimeUI.selectedCandidateTextColor : RimeUI.textMuted,
                            11, weight: .semibold)
            let word = label(text, selected ? RimeUI.selectedCandidateTextColor : RimeUI.textPrimary,
                             13, weight: .regular)
            let cell = NSStackView(views: [num, word])
            cell.spacing = 3
            cell.alignment = .centerY
            cell.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 7)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 5
            if selected {
                cell.layer?.backgroundColor = RimeUI.selectedCandidateBackgroundColor.cgColor
            }
            return cell
        }
        return alignedRow(items, right: false)
    }

    // A fixed-width row whose chips hug content and pin to one edge; a flexible
    // spacer on the opposite side absorbs the slack.
    private func alignedRow(_ content: [NSView], right: Bool) -> NSView {
        content.forEach { $0.setContentHuggingPriority(.required, for: .horizontal) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let views = right ? [spacer] + content : content + [spacer]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = RimeUI.border.withAlphaComponent(0.6).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    // MARK: shared chip style (one style for all layers)

    private func chip(_ views: [NSView], bg: NSColor, border: NSColor) -> NSView {
        let inner = NSStackView(views: views)
        inner.orientation = .horizontal
        inner.alignment = .centerY
        inner.spacing = 5
        inner.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        inner.wantsLayer = true
        inner.layer?.backgroundColor = bg.cgColor
        inner.layer?.borderColor = border.cgColor
        inner.layer?.borderWidth = 1
        inner.layer?.cornerRadius = 6
        return inner
    }

    private func label(_ text: String, _ color: NSColor, _ size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private static var previewWindow: NSWindow?

    /// Show the demo bar in a floating window (dev preview, from the input menu),
    /// so the three-layer layout can be seen in the running app before it is
    /// wired into the live candidate window (M2).
    static func showPreviewWindow() {
        let bar = WorkbenchBarView()
        bar.layoutSubtreeIfNeeded()
        let size = NSSize(width: 460, height: max(108, bar.fittingSize.height))
        let win = previewWindow ?? NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "工作台预览（未接入实时输入）"
        win.isReleasedWhenClosed = false
        win.contentView = bar
        win.setContentSize(size)
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        previewWindow = win
    }

    /// Render the demo bar to a PNG (dev preview; no window server needed).
    static func renderDemo(to path: String) {
        let view = WorkbenchBarView()
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(x: 0, y: 0, width: 460,
                            height: view.fittingSize.height > 0 ? view.fittingSize.height : 108)
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}
