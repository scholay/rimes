import Cocoa

/// A brief, non-interactive confirmation near the bottom of the screen.
///
/// Clipboard activation restores rich content to the pasteboard and closes
/// silently. Without a word from the app that reads as nothing happening, so
/// this says what the app just did. It carries a fixed message and never any
/// clipboard content, which keeps it safe to show while the history itself is
/// protected.
enum ClipboardCopyToast {
    private static let width: CGFloat = 208
    private static let height: CGFloat = 34
    private static let bottomInset: CGFloat = 96
    private static let holdDuration: TimeInterval = 1.05
    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.34

    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ message: String = "已复制到剪贴板") {
        dispatchPrecondition(condition: .onQueue(.main))
        // The pointer's screen is where the user is looking; the clipboard
        // window itself has already gone by the time this runs.
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let screen else { return }

        dismiss()
        generation &+= 1
        let currentGeneration = generation

        let frame = NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.minY + bottomInset,
            width: width,
            height: height
        )
        let toast = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        toast.isFloatingPanel = true
        toast.level = .statusBar
        toast.hidesOnDeactivate = false
        toast.worksWhenModal = true
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toast.backgroundColor = .clear
        toast.isOpaque = false
        toast.hasShadow = true
        toast.appearance = RimeUI.appKitAppearance
        // Purely informational: it must never take a click away from the host
        // the user is about to paste into.
        toast.ignoresMouseEvents = true

        let chrome = NSView(frame: NSRect(origin: .zero, size: frame.size))
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = height / 2
        chrome.layer?.backgroundColor = RimeUI.workbenchChrome.cgColor
        chrome.layer?.borderColor = RimeUI.borderStrong.cgColor
        chrome.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.image = RimeUI.symbol("doc.on.clipboard", pointSize: 12,
                                   weight: .semibold)
        icon.image?.isTemplate = true
        icon.contentTintColor = RimeUI.isRasta
            ? RimeUI.brandGreen
            : RimeUI.accentBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = RimeUI.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
        ])
        toast.contentView = chrome
        panel = toast

        let reduceMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        toast.alphaValue = reduceMotion ? 1 : 0
        toast.orderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeInDuration
                toast.animator().alphaValue = 1
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) {
            guard generation == currentGeneration else { return }
            guard !reduceMotion else {
                dismiss()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeOutDuration
                toast.animator().alphaValue = 0
            } completionHandler: {
                guard generation == currentGeneration else { return }
                dismiss()
            }
        }
    }

    static func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        panel?.orderOut(nil)
        panel = nil
    }
}
