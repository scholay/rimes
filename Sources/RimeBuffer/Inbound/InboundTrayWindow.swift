import Cocoa

enum MailboxWindowToggleAction: Equatable {
    case show
    case close
}

enum MailboxWindowVisibilityRules {
    static func action(isVisible: Bool) -> MailboxWindowToggleAction {
        isVisible ? .close : .show
    }
}

/// Standalone, key-capable Mailbox window. Its lifecycle is independent from
/// Buffer capture and the workbench window.
final class MailboxWindowController: NSObject, NSWindowDelegate {
    static let shared = MailboxWindowController()

    private static let frameAutosaveName = "RIMES.MailboxWindow"

    private var window: NSWindow?
    private var contentController: MailboxStandaloneViewController?
    private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    static func refreshIfOpen() {
        guard shared.window?.isVisible == true else { return }
        shared.contentController?.paneController.reloadFromStore()
    }

    static var isVisible: Bool { shared.window?.isVisible == true }

    static var isKeyAndVisible: Bool {
        shared.window?.isVisible == true && shared.window?.isKeyWindow == true
    }

    /// The configured global Mailbox shortcut is a true visibility toggle.
    /// Closing deliberately reuses the normal window lifecycle so it neither
    /// restores Buffer capture nor keeps a stale Mailbox editing focus alive.
    @discardableResult
    func toggleVisibility() -> MailboxWindowToggleAction {
        let action = MailboxWindowVisibilityRules.action(
            isVisible: window?.isVisible == true
        )
        switch action {
        case .show:
            show()
        case .close:
            window?.close()
        }
        return action
    }

    func show(selecting threadID: UUID? = nil) {
        // Mailbox is a standalone key window; showing it does not require the
        // current input source to belong to RIMES.
        if window == nil { build() }
        if let threadID, MailboxStore.shared.snapshot.thread(id: threadID) != nil {
            _ = MailboxStore.shared.selectThread(id: threadID)
        } else {
            _ = MailboxStore.shared.selectLatestUnreadOrMostRecent()
        }
        applyAppearance()
        contentController?.paneController.reloadFromStore()
        if let window {
            StandaloneWindowFocusCoordinator.shared.windowWillPresent(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            self?.contentController?.paneController.windowBecameKey()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        contentController?.paneController.windowBecameKey()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing Mailbox is intentionally terminal for this window only. It
        // must not restore Buffer or reuse a stale host-focus token.
        InboundToast.shared.hide()
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
        StandaloneWindowFocusCoordinator.shared.windowWillClose(closingWindow)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "RIMES Mailbox"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 760, height: 520)
        win.appearance = RimeUI.appKitAppearance
        win.animationBehavior = .documentWindow
        win.delegate = self

        let paneController = MailboxPaneViewController(
            reviewRouter: MailboxBufferReviewAdapter.shared
        )
        let contentController = MailboxStandaloneViewController(
            paneController: paneController
        )
        win.contentViewController = contentController

        let restored = win.setFrameUsingName(Self.frameAutosaveName)
        _ = win.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { win.center() }

        window = win
        self.contentController = contentController
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .rimeAppearanceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        window?.appearance = RimeUI.appKitAppearance
        contentController?.applyAppearance()
    }
}

func runMailboxWindowSmokeTest() -> Bool {
    let own = StandaloneWindowFocusIdentity(
        bundleID: "com.isaac.inputmethod.RimeBuffer",
        processIdentifier: 900
    )
    let external = StandaloneWindowFocusIdentity(
        bundleID: "com.example.Editor",
        processIdentifier: 101
    )
    let sameBundleOtherProcess = StandaloneWindowFocusIdentity(
        bundleID: own.bundleID,
        processIdentifier: 901
    )
    let canRestore = StandaloneWindowFocusReturnRules.shouldRestore(
        closeCompleted: true,
        remainingTrackedWindowCount: 0,
        frontmost: own,
        own: own,
        returnTarget: external,
        returnTargetIsRunning: true,
        returnTargetIdentityMatches: true,
        hasOtherVisibleKeyCapableOwnWindow: false
    )
    guard MailboxWindowVisibilityRules.action(isVisible: false) == .show,
          MailboxWindowVisibilityRules.action(isVisible: true) == .close,
          StandaloneWindowFocusReturnRules.isExternalReturnTarget(
            external,
            own: own
          ),
          !StandaloneWindowFocusReturnRules.isExternalReturnTarget(
            own,
            own: own
          ),
          !StandaloneWindowFocusReturnRules.isExternalReturnTarget(
            sameBundleOtherProcess,
            own: own
          ),
          canRestore,
          !StandaloneWindowFocusReturnRules.shouldRestore(
            closeCompleted: false,
            remainingTrackedWindowCount: 0,
            frontmost: own,
            own: own,
            returnTarget: external,
            returnTargetIsRunning: true,
            returnTargetIdentityMatches: true,
            hasOtherVisibleKeyCapableOwnWindow: false
          ),
          !StandaloneWindowFocusReturnRules.shouldRestore(
            closeCompleted: true,
            remainingTrackedWindowCount: 1,
            frontmost: own,
            own: own,
            returnTarget: external,
            returnTargetIsRunning: true,
            returnTargetIdentityMatches: true,
            hasOtherVisibleKeyCapableOwnWindow: false
          ),
          !StandaloneWindowFocusReturnRules.shouldRestore(
            closeCompleted: true,
            remainingTrackedWindowCount: 0,
            frontmost: external,
            own: own,
            returnTarget: external,
            returnTargetIsRunning: true,
            returnTargetIdentityMatches: true,
            hasOtherVisibleKeyCapableOwnWindow: false
          ),
          !StandaloneWindowFocusReturnRules.shouldRestore(
            closeCompleted: true,
            remainingTrackedWindowCount: 0,
            frontmost: own,
            own: own,
            returnTarget: external,
            returnTargetIsRunning: true,
            returnTargetIdentityMatches: true,
            hasOtherVisibleKeyCapableOwnWindow: true
          ),
          !StandaloneWindowFocusReturnRules.shouldRestore(
            closeCompleted: true,
            remainingTrackedWindowCount: 0,
            frontmost: own,
            own: own,
            returnTarget: external,
            returnTargetIsRunning: false,
            returnTargetIdentityMatches: true,
            hasOtherVisibleKeyCapableOwnWindow: false
          ) else {
        fputs("mailbox-window-smoke: lifecycle/focus-return mismatch\n", stderr)
        return false
    }
    print("mailbox-window-smoke: ok")
    return true
}

private final class MailboxStandaloneViewController: NSViewController {
    let paneController: MailboxPaneViewController

    private let titleLabel = NSTextField(labelWithString: "$ rimes mailbox")
    private let subtitleLabel = NSTextField(labelWithString: "外部推送 + AI 会话 · local persistence")

    init(paneController: MailboxPaneViewController) {
        self.paneController = paneController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        titleLabel.font = MailboxTerminalTypography.font(ofSize: 15, weight: .semibold)
        subtitleLabel.font = MailboxTerminalTypography.font(ofSize: 10)
        let copy = NSStackView(views: [titleLabel, subtitleLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 2
        copy.translatesAutoresizingMaskIntoConstraints = false

        addChild(paneController)
        let pane = paneController.view
        pane.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(copy)
        root.addSubview(pane)
        NSLayoutConstraint.activate([
            copy.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            copy.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),
            copy.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),

            pane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            pane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            pane.topAnchor.constraint(equalTo: copy.bottomAnchor, constant: 12),
            pane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),
        ])
        view = root
        applyAppearance()
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = RimeUI.surface.cgColor
        titleLabel.textColor = RimeUI.textPrimary
        subtitleLabel.textColor = RimeUI.textSecondary
        paneController.applyAppearanceForHost()
    }
}

private extension MailboxPaneViewController {
    func applyAppearanceForHost() {
        reloadFromStore()
    }
}
