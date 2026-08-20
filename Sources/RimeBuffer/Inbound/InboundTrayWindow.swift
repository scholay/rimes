import Cocoa

/// User-reviewed handoff for external text. Incoming content never opens or
/// edits the workbench by itself; it becomes a Buffer block only after an
/// explicit accept action in this window.
final class InboundTrayWindow: NSObject {
    static let shared = InboundTrayWindow()

    private var window: NSWindow?
    private var listStack = NSStackView()
    private var appearanceObserver: NSObjectProtocol?
    private var acceptedCount = 0
    private var rejectedCount = 0
    private var acceptButtons: [UUID: NSButton] = [:]
    private let countLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    static func refreshIfOpen() { shared.reloadIfVisible() }
    static var isVisible: Bool { shared.window?.isVisible == true }

    func show() {
        if window == nil { build() }
        applyAppearance(rebuild: true)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func reloadIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 612, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "外部来源收件箱"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 560, height: 380)
        win.appearance = RimeUI.appKitAppearance
        window = win
        rebuildContent()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance(rebuild: true)
        }
    }

    private func applyAppearance(rebuild: Bool) {
        window?.appearance = RimeUI.appKitAppearance
        if rebuild { rebuildContent() }
    }

    private func rebuildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = RimeUI.surface.cgColor
        window.contentView = content

        listStack = NSStackView()
        let root = NSStackView(views: [headerView(), gatewayCard(), listScroll(), footerView()])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        reload()
    }

    private func headerView() -> NSView {
        let icon = NSImageView()
        icon.image = RimeUI.symbol("tray", pointSize: 15, weight: .medium)
        icon.contentTintColor = RimeUI.accentTextColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        icon.wantsLayer = true
        icon.layer?.backgroundColor = RimeUI.accentGreen.withAlphaComponent(0.12).cgColor
        icon.layer?.cornerRadius = 7

        let title = NSTextField(labelWithString: "外部来源收件箱")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        let subtitle = NSTextField(labelWithString: "审核外部传入内容后，再明确加入 Buffer。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = RimeUI.textMuted
        let copy = NSStackView(views: [title, subtitle])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2

        countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = RimeUI.accentTextColor
        countLabel.alignment = .center
        countLabel.wantsLayer = true
        countLabel.layer?.backgroundColor = RimeUI.accentGreen.withAlphaComponent(0.12).cgColor
        countLabel.layer?.cornerRadius = 9
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.heightAnchor.constraint(equalToConstant: 20).isActive = true
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true

        let row = NSStackView(views: [icon, copy, flexibleSpacer(), countLabel])
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func gatewayCard() -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (LocalGateway.shared.running
            ? RimeUI.accentGreen
            : RimeUI.textMuted).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let title = NSTextField(labelWithString: "外部传字网关")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        let detail = NSTextField(labelWithString:
            "仅接收明确配对的外部来源；剪贴板历史由 Buffer 中的独立开关控制。")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = RimeUI.textMuted
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let state = NSTextField(labelWithString: LocalGateway.shared.running ? "在线" : "离线")
        state.font = .systemFont(ofSize: 10, weight: .semibold)
        state.textColor = LocalGateway.shared.running ? RimeUI.accentTextColor : RimeUI.textMuted

        return card(views: [dot, labels, flexibleSpacer(), state], spacing: 10)
    }

    private func listScroll() -> NSView {
        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.documentView = document
        let height = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 228)
        height.priority = .defaultLow
        height.isActive = true
        return scroll
    }

    private func footerView() -> NSView {
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = RimeUI.textMuted

        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.bezelStyle = .rounded
        doneButton.bezelColor = RimeUI.accentGreen
        doneButton.contentTintColor = RimeUI.accentForegroundColor

        let row = NSStackView(views: [footerLabel, flexibleSpacer(), doneButton])
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func reload(focusIndex: Int? = nil) {
        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        acceptButtons.removeAll()

        let items = InboundBus.shared.pending
        countLabel.stringValue = items.isEmpty ? "无待审" : "\(items.count) 项待审"
        footerLabel.stringValue = "待审 \(items.count) · 已接受 \(acceptedCount) · 已拒绝 \(rejectedCount)"

        if items.isEmpty {
            let empty = NSTextField(labelWithString: "没有待审内容")
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.textColor = RimeUI.textSecondary
            let hint = NSTextField(labelWithString: "新的外部内容会先出现在这里，不会自动写入 Buffer。")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = RimeUI.textMuted
            let stack = NSStackView(views: [empty, hint])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 36, left: 12, bottom: 36, right: 12)
            listStack.addArrangedSubview(stack)
        } else {
            for item in items { listStack.addArrangedSubview(row(for: item)) }
        }

        guard let focusIndex else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = InboundBus.shared.pending
            if current.isEmpty {
                self.window?.makeFirstResponder(self.doneButton)
            } else {
                let next = current[min(focusIndex, current.count - 1)].id
                self.window?.makeFirstResponder(self.acceptButtons[next])
            }
        }
    }

    private func row(for item: InboundItem) -> NSView {
        let symbol = NSImageView()
        symbol.image = RimeUI.symbol(symbolName(for: item.origin), pointSize: 13, weight: .medium)
        symbol.contentTintColor = RimeUI.textSecondary
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.widthAnchor.constraint(equalToConstant: 28).isActive = true
        symbol.heightAnchor.constraint(equalToConstant: 28).isActive = true
        symbol.wantsLayer = true
        symbol.layer?.backgroundColor = RimeUI.surface3.cgColor
        symbol.layer?.cornerRadius = 7

        let title = NSTextField(labelWithString: item.title ?? displayName(for: item.origin))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        let metadata = NSTextField(labelWithString: metadataText(for: item))
        metadata.font = .systemFont(ofSize: 9)
        metadata.textColor = RimeUI.textMuted
        let titleRow = NSStackView(views: [title, metadata])
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8

        let preview = NSTextField(wrappingLabelWithString: item.text.isEmpty ? "（空）" : item.text)
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = RimeUI.textSecondary
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail

        let acceptTitle = item.pluginMetadata?.stale == true
            ? "作为普通文本加入 Buffer"
            : "接受并加入 Buffer"
        let accept = NSButton(title: acceptTitle, target: self, action: #selector(acceptTapped(_:)))
        accept.bezelStyle = .rounded
        accept.bezelColor = RimeUI.accentGreen
        accept.contentTintColor = RimeUI.accentForegroundColor
        accept.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        accept.isEnabled = InboundBus.shared.canAccept(item.id)
        accept.toolTip = item.streaming ? "等待接收完成后才能加入 Buffer" : nil
        accept.setAccessibilityLabel(item.streaming
            ? "\(title.stringValue) 内容仍在接收，暂不可加入 Buffer"
            : "接受 \(title.stringValue) 内容并加入 Buffer")
        acceptButtons[item.id] = accept

        let reject = NSButton(title: "拒绝", target: self, action: #selector(rejectTapped(_:)))
        reject.bezelStyle = .inline
        reject.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        reject.setAccessibilityLabel("拒绝 \(title.stringValue) 内容")

        let actions = NSStackView(views: [flexibleSpacer(), reject, accept])
        actions.alignment = .centerY
        actions.spacing = 8

        let body = NSStackView(views: [titleRow, preview, actions])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 5

        if item.pluginMetadata?.stale == true {
            let warning = NSTextField(labelWithString: "原目标已变化，接受后将按普通文本处理")
            warning.font = .systemFont(ofSize: 9, weight: .medium)
            warning.textColor = RimeUI.color(RimeUI.isDark ? 0xFF9230 : 0x8A4B00)
            body.insertArrangedSubview(warning, at: 2)
        }
        return card(views: [symbol, body], spacing: 10)
    }

    private func card(views: [NSView], spacing: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = RimeUI.surface2.cgColor
        stack.layer?.cornerRadius = 9
        stack.layer?.borderColor = RimeUI.border.cgColor
        stack.layer?.borderWidth = 1
        return stack
    }

    @objc private func acceptTapped(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let index = InboundBus.shared.pending.firstIndex(where: { $0.id == id }) else { return }
        guard InboundBus.shared.canAccept(id),
              InboundBus.shared.accept(id) else {
            reload(focusIndex: index)
            return
        }
        acceptedCount += 1
        reload(focusIndex: index)
    }

    @objc private func rejectTapped(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let index = InboundBus.shared.pending.firstIndex(where: { $0.id == id }) else { return }
        InboundBus.shared.reject(id)
        rejectedCount += 1
        reload(focusIndex: index)
    }

    @objc private func doneTapped() {
        window?.close()
    }

    private func metadataText(for item: InboundItem) -> String {
        let source: String
        switch item.origin {
        case .marine: source = "网页摘录"
        case .remotePeer: source = "文本传入"
        case .plugin: source = "插件结果"
        case .mcp: source = "MCP"
        case .http: source = "HTTP"
        case .sse: source = "SSE"
        case .ssh: source = "SSH"
        case .processor: source = "处理器"
        case .rime: source = "输入法"
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        let age = relative.localizedString(for: item.createdAt, relativeTo: Date())
        return "\(source) · \(item.streaming ? "接收中" : age)"
    }

    private func displayName(for origin: Origin) -> String {
        switch origin {
        case .marine: return "Marine Chrome"
        case .remotePeer: return "配对设备"
        case .plugin: return "插件"
        case .mcp: return "MCP 客户端"
        case .http: return "HTTP 来源"
        case .sse: return "SSE 来源"
        case .ssh: return "SSH 来源"
        case .processor: return "处理器"
        case .rime: return "RIMES"
        }
    }

    private func symbolName(for origin: Origin) -> String {
        switch origin {
        case .marine: return "network"
        case .remotePeer: return "rectangle.connected.to.line.below"
        case .plugin: return "puzzlepiece.extension"
        case .mcp, .http, .sse, .ssh: return "point.3.connected.trianglepath.dotted"
        case .processor: return "gearshape.2"
        case .rime: return "keyboard"
        }
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
}
