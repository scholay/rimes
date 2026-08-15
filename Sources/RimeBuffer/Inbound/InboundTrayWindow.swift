import Cocoa

/// A standalone "外部来源收件箱" window: shows InboundBus pending items with
/// accept/reject, plus the gateway connect info (port + token + a ready-to-paste
/// `claude mcp add` line). This is a stepping stone — the same accept/reject
/// belongs in the panel's inbound rail (delayed to the careful candidate-window
/// integration), but the tray makes the whole MCP→buffer flow usable today.
final class InboundTrayWindow: NSObject {
    static let shared = InboundTrayWindow()

    private var window: NSWindow?
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "还没有外部来源推送内容。")
    private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    static func refreshIfOpen() { shared.reloadIfVisible() }
    static var isVisible: Bool { shared.window?.isVisible == true }

    func show() {
        if window == nil { build() }
        window?.appearance = RimeUI.appKitAppearance
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func reloadIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "外部来源收件箱"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 360)
        win.appearance = RimeUI.appKitAppearance

        let root = NSStackView(views: [connectBox(), divider(), listScroll()])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        win.contentView = NSView()
        win.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: win.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: win.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: win.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: win.contentView!.bottomAnchor),
        ])
        window = win
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window?.appearance = RimeUI.appKitAppearance
            self.reloadIfVisible()
        }
    }

    // MARK: connect info

    private func connectBox() -> NSView {
        let running = LocalGateway.shared.running || LocalGateway.shared.enabled
        let status = NSTextField(labelWithString:
            running ? "网关运行中 · 127.0.0.1:\(LocalGateway.shared.port)" : "网关已关闭（在设置 › 连接里开启）")
        status.font = .systemFont(ofSize: 13, weight: .semibold)

        let cmd = "claude mcp add --transport http etinput http://127.0.0.1:\(LocalGateway.shared.port)/mcp --header \"Authorization: Bearer \(GatewayToken.current())\""
        let field = NSTextField(string: cmd)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 4
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 528).isActive = true

        let copyBtn = NSButton(title: "复制 Claude Code 命令", target: self, action: #selector(copyCommand))
        let hint = NSTextField(wrappingLabelWithString:
            "标准 MCP 端点，任何 MCP 客户端／智能体都能接入用 buffer_push 往这里推文字。"
            + "上面这行是 Claude Code 的便捷写法；通用 JSON 配置见「设置 › 连接」。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 528

        let box = NSStackView(views: [status, field, copyBtn, hint])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        return box
    }

    @objc private func copyCommand() {
        let cmd = "claude mcp add --transport http etinput http://127.0.0.1:\(LocalGateway.shared.port)/mcp --header \"Authorization: Bearer \(GatewayToken.current())\""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    // MARK: pending list

    private func listScroll() -> NSView {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])
        scroll.documentView = doc
        scroll.widthAnchor.constraint(equalToConstant: 528).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        doc.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        return scroll
    }

    private func reload() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let items = InboundBus.shared.pending
        if items.isEmpty {
            listStack.addArrangedSubview(emptyLabel)
            return
        }
        for item in items { listStack.addArrangedSubview(row(for: item)) }
    }

    private func row(for item: InboundItem) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = badgeColor(item.origin).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let source = NSTextField(labelWithString:
            "\(item.title ?? item.origin.tag)\(item.streaming ? " · 接收中…" : "")")
        source.font = .systemFont(ofSize: 12, weight: .semibold)
        let head = NSStackView(views: [dot, source])
        head.spacing = 6; head.alignment = .centerY

        var cardRows: [NSView] = [head]
        if item.pluginMetadata?.stale == true {
            var warningText = "原投放目标已经变化；接受后会降级为普通文本，只发送到你届时聚焦的输入框"
            if let target = item.pluginMetadata?.targetSummary,
               !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warningText += " · 原目标：\(target)"
            }
            let warning = NSTextField(wrappingLabelWithString: warningText)
            warning.font = .systemFont(ofSize: 11, weight: .semibold)
            warning.textColor = .systemOrange
            warning.maximumNumberOfLines = 2
            cardRows.append(warning)
        }

        let preview = NSTextField(wrappingLabelWithString: item.text.isEmpty ? "（空）" : item.text)
        preview.font = .systemFont(ofSize: 13)
        preview.textColor = .labelColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let acceptTitle = item.pluginMetadata?.stale == true
            ? "作为普通文本加入"
            : "发送到缓冲区"
        let accept = NSButton(title: acceptTitle, target: self, action: #selector(acceptTapped(_:)))
        accept.bezelColor = RimeUI.accentGreen
        accept.tag = 0
        accept.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        let reject = NSButton(title: "拒绝", target: self, action: #selector(rejectTapped(_:)))
        reject.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        let actions = NSStackView(views: [accept, reject])
        actions.spacing = 6

        let body = NSStackView(views: [preview, flexSpacer(), actions])
        body.spacing = 10; body.alignment = .centerY
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: 528).isActive = true

        cardRows.append(body)
        let card = NSStackView(views: cardRows)
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 5
        card.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        card.wantsLayer = true
        card.layer?.backgroundColor = RimeUI.surface2.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderColor = RimeUI.border.cgColor
        card.layer?.borderWidth = 1
        return card
    }

    @objc private func acceptTapped(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) {
            InboundBus.shared.accept(id)
        }
        reload()
    }

    @objc private func rejectTapped(_ sender: NSButton) {
        if let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) {
            InboundBus.shared.reject(id)
        }
        reload()
    }

    private func badgeColor(_ origin: Origin) -> NSColor {
        switch origin {
        case .remotePeer: return RimeUI.color(0x9B8CFF)
        case .marine, .plugin, .processor, .mcp: return RimeUI.color(0xF59E0B)
        case .http, .sse, .ssh: return RimeUI.color(0x4A9FD8)
        case .rime: return .tertiaryLabelColor
        }
    }

    private func flexSpacer() -> NSView {
        let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v
    }

    private func divider() -> NSView {
        let d = NSBox(); d.boxType = .separator
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 528).isActive = true
        return d
    }
}
