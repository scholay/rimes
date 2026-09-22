import AppKit
import Carbon.HIToolbox

/// Ephemeral, read-only card content. The library, search index, thumbnail,
/// tooltip and accessibility projections never receive decrypted text.
final class CapsuleCardPasswordView: NSView {
    var onConceal: (() -> Void)?
    private let verifier: CapsuleInlinePasscodeView
    private let readSecret: () throws -> String
    private let presentationAllowed: () -> Bool
    private var secretView: CapsulePasswordCanvas?
    private var secretScroll: NSScrollView?
    private var concealTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var isRevealed = false
    private var ended = false

    init(store: CapsuleRevealPasscodeStore,
         readSecret: @escaping () throws -> String,
         presentationAllowed: @escaping () -> Bool) {
        verifier = CapsuleInlinePasscodeView(store: store)
        self.readSecret = readSecret
        self.presentationAllowed = presentationAllowed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = RimeUI.surface2.cgColor
        install(verifier)
        verifier.onVerified = { [weak self] in self?.reveal() }
        verifier.onCancel = { [weak self] in self?.conceal() }
        for name in [NSApplication.didResignActiveNotification,
                     .capsuleRevealPasscodeDidChange, .capsuleStoreDidChange] {
            observe(.default, name: name)
        }
        observe(.default, name: NSWindow.didResignKeyNotification, ownWindowOnly: true)
        observe(.default, name: NSWindow.willCloseNotification, ownWindowOnly: true)
        for name in [NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification] {
            observe(NSWorkspace.shared.notificationCenter, name: name)
        }
        observe(DistributedNotificationCenter.default(),
                name: Notification.Name("com.apple.screenIsLocked"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        concealTimer?.invalidate()
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func focus() { verifier.focus() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { conceal() }
        // Revealed text is view-only. Never route typing or copy to a host.
    }

    override func resignFirstResponder() -> Bool {
        if isRevealed { conceal() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { conceal() }
    }

    override func layout() {
        super.layout()
        if let secretScroll { secretView?.fit(width: secretScroll.contentSize.width) }
    }

    func conceal() {
        guard !ended else { return }
        ended = true
        concealTimer?.invalidate()
        concealTimer = nil
        verifier.reset()
        secretView?.clear()
        secretView?.removeFromSuperview()
        secretView = nil
        secretScroll?.removeFromSuperview()
        secretScroll = nil
        isRevealed = false
        onConceal?()
    }

    private func reveal() {
        guard !ended, window?.isKeyWindow == true,
              !IsSecureEventInputEnabled(), presentationAllowed() else {
            conceal(); return
        }
        do {
            let text = try readSecret()
            guard !ended, window?.isKeyWindow == true,
                  !IsSecureEventInputEnabled(), presentationAllowed() else {
                conceal(); return
            }
            verifier.removeFromSuperview()
            let content = CapsulePasswordCanvas(text: text)
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = content
            scroll.setAccessibilityElement(false)
            install(scroll)
            secretView = content
            secretScroll = scroll
            content.fit(width: bounds.width)
            isRevealed = true
            window?.makeFirstResponder(self)
            let timer = Timer(timeInterval: CapsulePasswordEditorSecurityPolicy.revealDuration,
                              repeats: false) { [weak self] _ in self?.conceal() }
            concealTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            // Do not expose store diagnostics or record contents in a card.
            conceal()
            NSSound.beep()
        }
    }

    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name,
                         ownWindowOnly: Bool = false) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] notification in
            guard let self else { return }
            if ownWindowOnly, (notification.object as? NSWindow) !== self.window { return }
            self.conceal()
        }
        observers.append((center, token))
    }
}

/// Draw-only plaintext: no NSTextView value, selection, undo history, drag
/// representation, or accessibility text object is created for a card reveal.
private final class CapsulePasswordCanvas: NSView {
    private var text: NSAttributedString
    override var isFlipped: Bool { true }

    init(text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        self.text = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: RimeUI.textPrimary,
            .paragraphStyle: paragraph,
        ])
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setAccessibilityChildren([])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func fit(width: CGFloat) {
        let height = text.boundingRect(with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        setFrameSize(NSSize(width: width, height: ceil(height) + 12))
    }

    func clear() { text = NSAttributedString(string: ""); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(with: bounds.insetBy(dx: 6, dy: 6), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
