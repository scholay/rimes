import AppKit

private final class MarineChromePairingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Non-modal, single-instance approval UI for the browser companion. Return
/// and Escape reject; approval therefore always requires an explicit click.
final class MarineChromePairingPromptController: NSObject, NSWindowDelegate {
    static let shared = MarineChromePairingPromptController()

    private var panel: MarineChromePairingPanel?
    private weak var codeLabel: NSTextField?
    private var requestID: UUID?
    private var response: ((Bool) -> Void)?
    private var expiryTimer: Timer?
    private var appearanceObserver: NSObjectProtocol?

    override init() {
        super.init()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func present(_ request: MarineChromePairingBroker.ApprovalRequest,
                 respond: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        finish(approved: false)

        let panel = MarineChromePairingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "RIMES · marine-chrome"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = RimeUI.appKitAppearance
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(approved: false) }

        let title = NSTextField(labelWithString: "允许 marine-chrome 连接 RIMES？")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center

        let explanation = NSTextField(wrappingLabelWithString:
            "确认码应与 Chrome 连接页一致。允许后，扩展只能把当前网页的短期上下文交给本机 RIMES；它不会替你输入、点击或发布。")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .center
        explanation.maximumNumberOfLines = 4

        let code = NSTextField(labelWithString: request.displayCode)
        code.font = .monospacedSystemFont(ofSize: 26, weight: .bold)
        code.alignment = .center
        code.textColor = RimeUI.isNight
            ? RimeUI.accentGreen
            : RimeUI.selectedCandidateBackgroundColor
        code.setContentHuggingPriority(.required, for: .vertical)
        codeLabel = code

        let allow = NSButton(title: "允许", target: self,
                             action: #selector(approve))
        allow.bezelStyle = .rounded
        allow.keyEquivalent = ""

        let reject = NSButton(title: "拒绝", target: self,
                              action: #selector(reject))
        reject.bezelStyle = .rounded
        reject.keyEquivalent = "\r"

        let buttons = NSStackView(views: [reject, allow])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.distribution = .fillEqually
        buttons.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let stack = NSStackView(views: [title, explanation, code, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 28,
                                        bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            explanation.widthAnchor.constraint(equalToConstant: 390),
        ])

        self.panel = panel
        requestID = request.requestID
        response = respond
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60,
                                           repeats: false) { [weak self] _ in
            self?.finish(approved: false)
        }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.requestUserAttention(.criticalRequest)
        panel.makeKeyAndOrderFront(nil)
    }

    private func applyAppearance() {
        panel?.appearance = RimeUI.appKitAppearance
        codeLabel?.textColor = RimeUI.isNight
            ? RimeUI.accentGreen
            : RimeUI.selectedCandidateBackgroundColor
        panel?.contentView?.needsDisplay = true
    }

    func cancel(requestID expectedRequestID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard expectedRequestID == nil || requestID == expectedRequestID else {
            return
        }
        finish(approved: false)
    }

    @objc private func approve() { finish(approved: true) }
    @objc private func reject() { finish(approved: false) }

    func windowWillClose(_ notification: Notification) {
        finish(approved: false, closeWindow: false)
    }

    private func finish(approved: Bool, closeWindow: Bool = true) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        let callback = response
        response = nil
        requestID = nil
        let currentPanel = panel
        panel = nil
        codeLabel = nil
        currentPanel?.delegate = nil
        currentPanel?.onCancel = nil
        if closeWindow { currentPanel?.close() }
        callback?(approved)
    }
}
