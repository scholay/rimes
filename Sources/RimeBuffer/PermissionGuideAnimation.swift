import AppKit

/// Local, looping GIFs. They are instruction artwork only; the live file drag
/// is provided separately by PermissionApplicationIcon and the running bundle.
final class PermissionGuideAnimation: NSImageView {
    enum Kind: String, CaseIterable { case drag, enable, disable, repair }
    let kind: Kind
    private var observer: NSObjectProtocol?

    static func resourceURL(_ name: String, extension ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Permissions")
    }

    init(_ kind: Kind, width: CGFloat) {
        self.kind = kind
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: 232.0 / 720.0),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        let descriptions: [Kind: String] = [.drag: "演示：把本弹窗中的应用图标拖入系统设置的权限列表。",
            .enable: "演示：点击应用右侧的系统开关，开启权限。",
            .disable: "演示：点击应用右侧的系统开关，关闭权限。",
            .repair: "演示：选中旧版应用，点减号移除，再拖入当前应用并开启。"]
        setAccessibilityLabel(descriptions[kind])
        observer = NotificationCenter.default.addObserver(forName: .rimeAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in self?.loadAnimation() }
        loadAnimation()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); loadAnimation()
    }

    private func loadAnimation() {
        let dark = (RimeUI.appKitAppearance ?? effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let url = Self.resourceURL(kind.rawValue + (dark ? "-dark" : "-light"), extension: "gif") {
            image = NSImage(contentsOf: url)
        }
        animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
