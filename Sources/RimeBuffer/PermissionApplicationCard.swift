import AppKit
import Carbon.HIToolbox

/// Always identifies the running bundle, never a similarly named app found
/// through Spotlight or a hard-coded development installation. Bare SwiftPM
/// executables cannot be added as if they were the installed input method.
enum PermissionApplication {
    static func appURL(bundleURL: URL = Bundle.main.bundleURL,
                       expectedIdentifier: String = RimesIdentity.bundleIdentifier) -> URL? {
        guard bundleURL.isFileURL else { return nil }
        let url = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              bundle.bundleIdentifier == expectedIdentifier,
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return url
    }

    static func fileWriter(for url: URL,
                           expectedIdentifier: String = RimesIdentity.bundleIdentifier) -> NSURL? {
        appURL(bundleURL: url, expectedIdentifier: expectedIdentifier).map { $0 as NSURL }
    }
}

/// The drag exports a real file URL to System Settings, not a picture of the
/// app or a file promise. Never advertise move/delete of the installed IME.
final class PermissionApplicationIcon: NSImageView, NSDraggingSource {
    let applicationURL: URL?
    private let allowsSystemActions: Bool
    static let dragOperations: NSDragOperation = .copy

    init(applicationURL: URL?, allowsSystemActions: Bool) {
        self.applicationURL = applicationURL
        self.allowsSystemActions = allowsSystemActions
        super.init(frame: .zero)
        image = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("RIMES 应用，可拖入系统权限列表")
        setAccessibilityHelp("也可使用旁边的在 Finder 中显示按钮定位应用。")
        toolTip = "拖动应用图标到系统权限列表；不需要移动或重新安装应用"
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() {
        if allowsSystemActions, applicationURL != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    func fileWriterForDrag() -> NSURL? {
        guard allowsSystemActions, !IsSecureEventInputEnabled(), let applicationURL else { return nil }
        return PermissionApplication.fileWriter(for: applicationURL)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let writer = fileWriterForDrag() else { return }
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.dragOperations
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// Reused in both the permission guide and Settings, so removing an app from
/// macOS's list never leaves the user with only an unfindable Library path.
final class PermissionApplicationCard: NSView {
    private let applicationURL: URL?
    private let allowsSystemActions: Bool
    private let feedback: NSTextField

    init(width: CGFloat, allowsSystemActions: Bool = true,
         bundleURL: URL = Bundle.main.bundleURL) {
        applicationURL = PermissionApplication.appURL(bundleURL: bundleURL)
        self.allowsSystemActions = allowsSystemActions
        feedback = NSTextField(wrappingLabelWithString: applicationURL == nil
            ? "当前不是可添加的 RIMES.app，请从已安装的输入法打开此页。"
            : "列表里没有 RIMES？拖动图标到权限列表，或点「＋」选择应用。")
        super.init(frame: .zero)
        let innerWidth = width - 28
        func label(_ text: String, size: CGFloat = 11) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: size)
            label.textColor = RimeUI.textSecondary
            label.preferredMaxLayoutWidth = innerWidth
            return label
        }
        let icon = PermissionApplicationIcon(applicationURL: applicationURL, allowsSystemActions: allowsSystemActions)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        let title = CaptureUI.label("RIMES.app", size: 15)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = label("拖动左侧图标 → 系统权限列表")
        let header = CaptureUI.row([icon, CaptureUI.column([title, hint], spacing: 5)], spacing: 12)
        let location = label(applicationURL?.path ?? "未找到当前应用包")
        location.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        location.isSelectable = true
        location.lineBreakMode = .byCharWrapping
        let reveal = CaptureButton("在 Finder 中显示", symbol: "folder") { [weak self] in self?.reveal() }
        let copy = CaptureButton("复制应用路径", symbol: "doc.on.doc") { [weak self] in self?.copyPath() }
        reveal.isEnabled = allowsSystemActions && applicationURL != nil
        copy.isEnabled = reveal.isEnabled
        reveal.toolTip = "选中正在运行的 RIMES.app，不复制、不移动应用"
        copy.toolTip = "在系统设置的添加窗口按 ⇧⌘G，粘贴此路径即可定位应用"
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = RimeUI.textSecondary
        feedback.preferredMaxLayoutWidth = innerWidth
        let fallback = label("拖不进去时：点列表下方「＋」→ 按 ⇧⌘G → 粘贴应用路径 → 添加。\n添加后打开 RIMES 的开关，再返回检测。无需把输入法搬到「应用程序」。")
        let body = CaptureUI.column([header, location, CaptureUI.row([reveal, copy]), feedback, fallback], spacing: 9)
        CaptureUI.fill(body, in: self, inset: 14)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        for view in [location, feedback, fallback] {
            view.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        RimeUI.surface2.setFill(); shape.fill()
        RimeUI.border.setStroke(); shape.stroke()
    }

    private func currentURL() -> URL? {
        guard allowsSystemActions, !IsSecureEventInputEnabled(), let applicationURL else { return nil }
        guard let url = PermissionApplication.appURL(bundleURL: applicationURL) else {
            feedback.stringValue = "应用位置已变化，请关闭此页后重新打开。"
            return nil
        }
        return url
    }

    private func reveal() {
        guard let url = currentURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath() {
        guard let url = currentURL() else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(url.path, forType: .string)
        feedback.stringValue = copied
            ? "路径已复制。在系统设置的「＋」添加窗口按 ⇧⌘G，再粘贴。"
            : "复制未成功，请使用「在 Finder 中显示」定位应用。"
    }
}
