import AppKit

extension Notification.Name {
    static let systemPermissionStatusDidChange = Notification.Name("RIMES.systemPermissionStatusDidChange")
}

enum PermissionChangeIntent: Equatable {
    case enable, disable

    init(status: SystemPermissionStatus) {
        self = status == .granted ? .disable : .enable
    }

    func isSatisfied(by status: SystemPermissionStatus) -> Bool {
        switch self {
        case .enable: return status == .granted
        case .disable: return status == .denied
        }
    }
}

extension SystemPermission {
    var symbolName: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .inputMonitoring: return "keyboard"
        case .camera: return "camera"
        case .microphone: return "mic"
        case .localNetwork: return "network"
        }
    }

    var cardPurpose: String {
        switch self {
        case .accessibility: return "粘贴、定位与滚动截图"
        case .screenRecording: return "截图与录屏"
        case .inputMonitoring: return "录屏时显示按键"
        case .camera: return "录屏时加入摄像头画面"
        case .microphone: return "录屏时加入你的声音"
        case .localNetwork: return "连接附近设备"
        }
    }
}

/// A centered dash is deliberately distinct from an off switch. macOS has no
/// public local-network authorization read API; never invent a persisted grant.
final class PermissionStatusSwitch: RimeFixedAccentSwitch {
    var reportedStatus: SystemPermissionStatus = .denied {
        didSet {
            state = reportedStatus == .granted ? .on : .off
            needsDisplay = true
        }
    }

    override func accessibilityValue() -> Any? {
        reportedStatus == .undeterminable ? "待确认" : super.accessibilityValue()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard reportedStatus == .undeterminable else { super.draw(dirtyRect); return }
        let track = NSRect(x: bounds.midX - 18, y: bounds.midY - 10, width: 36, height: 20)
        let shape = NSBezierPath(roundedRect: track, xRadius: 10, yRadius: 10)
        RimeUI.surface3.setFill(); shape.fill()
        RimeUI.border.setStroke(); shape.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)).fill()
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: bounds.midX - 3, y: bounds.midY))
        dash.line(to: NSPoint(x: bounds.midX + 3, y: bounds.midY))
        dash.lineWidth = 1.5; NSColor.darkGray.setStroke(); dash.stroke()
        if window?.firstResponder === self {
            RimeUI.accentGreen.setStroke()
            let focus = NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: 12, yRadius: 12)
            focus.lineWidth = 2; focus.stroke()
        }
    }
}

final class SystemPermissionCard: NSView {
    let permission: SystemPermission
    let permissionSwitch = PermissionStatusSwitch(frame: .zero)
    private(set) var report: SystemPermissionReport
    private let changed: (SystemPermission, PermissionChangeIntent) -> Void

    init(report: SystemPermissionReport, changed: @escaping (SystemPermission, PermissionChangeIntent) -> Void) {
        permission = report.permission; self.report = report; self.changed = changed
        super.init(frame: .zero)
        let icon = NSImageView(image: RimeUI.symbol(permission.symbolName, pointSize: 22, weight: .regular)
            ?? NSImage())
        icon.contentTintColor = RimeUI.accentTextColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionSwitch.target = self; permissionSwitch.action = #selector(togglePermission)
        permissionSwitch.setAccessibilityLabel(permission.title)
        permissionSwitch.setAccessibilityIdentifier("permission-switch-\(permission.rawValue)")
        let header = CaptureUI.row([icon, spacer, permissionSwitch])
        let title = NSTextField(labelWithString: permission.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = RimeUI.textPrimary
        let purpose = NSTextField(labelWithString: permission.cardPurpose)
        purpose.font = .systemFont(ofSize: 12)
        purpose.textColor = RimeUI.textSecondary
        purpose.lineBreakMode = .byTruncatingTail
        purpose.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = CaptureUI.column([header, title, purpose], spacing: 7)
        CaptureUI.fill(content, in: self, inset: 16)
        header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        purpose.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 118).isActive = true
        setAccessibilityIdentifier("permission-card-\(permission.rawValue)")
        update(report)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ report: SystemPermissionReport) {
        self.report = report
        permissionSwitch.reportedStatus = report.status
        let status = report.status == .granted ? "已开启" : report.status == .denied ? "未开启" : "待确认"
        permissionSwitch.toolTip = report.status == .undeterminable
            ? "在系统设置中确认此权限。"
            : "\(status)；点击在系统设置中\(report.status == .granted ? "关闭" : "开启")。"
        permissionSwitch.setAccessibilityHelp(permissionSwitch.toolTip)
    }

    @objc private func togglePermission() {
        // The click expresses intent, not authorization. Keep the actual OS
        // value until its real check changes, including when the user cancels.
        let intent = PermissionChangeIntent(status: report.status)
        permissionSwitch.state = report.status == .granted ? .on : .off
        changed(permission, intent)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        RimeUI.surface2.setFill(); shape.fill()
        RimeUI.border.setStroke(); shape.stroke()
    }
}

/// No polling lives on the ordinary input path. Settings refreshes on return,
/// and the temporary guide publishes any changes it observes while open.
final class SystemPermissionsView: NSStackView {
    private(set) var cards: [SystemPermissionCard] = []
    private let reports: () -> [SystemPermissionReport]
    private var observer: NSObjectProtocol?

    init(width: CGFloat = 650,
         reports: @escaping () -> [SystemPermissionReport] = SystemPermissionAudit.reportAll,
         changed: @escaping (SystemPermission, PermissionChangeIntent) -> Void) {
        self.reports = reports
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 14
        let intro = NSTextField(labelWithString: "正常打字无需授权，用到扩展功能时再开启。")
        intro.font = .systemFont(ofSize: 13); intro.textColor = RimeUI.textSecondary
        addArrangedSubview(intro)
        cards = reports().map { SystemPermissionCard(report: $0, changed: changed) }
        for index in stride(from: 0, to: cards.count, by: 3) {
            let group = Array(cards[index..<min(index + 3, cards.count)])
            let row = CaptureUI.row(group, spacing: 12)
            row.distribution = .fillEqually
            addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        observer = NotificationCenter.default.addObserver(forName: .systemPermissionStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func refresh() {
        let latest = Dictionary(uniqueKeysWithValues: reports().map { ($0.permission, $0) })
        for card in cards { if let report = latest[card.permission] { card.update(report) } }
    }
}
