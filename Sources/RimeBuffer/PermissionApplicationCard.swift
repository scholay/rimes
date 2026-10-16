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
            ?? PermissionGuideAnimation.resourceURL("application", extension: "png").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        imageScaling = .scaleProportionallyUpOrDown
        if allowsSystemActions, applicationURL != nil {
            setAccessibilityLabel("\(ProductBrand.name) 应用，可拖入系统权限列表")
            setAccessibilityHelp("将此图标拖入系统设置中的权限列表。")
            toolTip = "拖入系统设置的权限列表"
        } else {
            setAccessibilityLabel(ProductBrand.name)
        }
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
