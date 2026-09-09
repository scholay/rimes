import ApplicationServices
import Cocoa

/// Every macOS permission RIMES actually uses, what stops working without it,
/// and how to reach the pane that grants it.
///
/// Written as one list because the alternative is what happened before: a
/// feature declines, logs a line nobody reads, and silently falls back — so a
/// missing grant looks like a broken feature. Anything not listed here is not
/// requested. Input Monitoring in particular is deliberately absent: the
/// global monitors watch mouse buttons only, and the hotkeys are Carbon
/// registrations, neither of which needs it.
enum SystemPermission: String, CaseIterable {
    case accessibility
    case localNetwork

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .localNetwork: return "本地网络"
        }
    }

    /// Named features, not categories. "Needed for accessibility reasons" tells
    /// the user nothing about what they lose.
    var enables: String {
        switch self {
        case .accessibility:
            return "剪贴板自动粘贴、工作台对齐目标输入框、输入框高亮提示"
        case .localNetwork:
            return "Marine 局域网配对与跨设备直连"
        }
    }

    var whenMissing: String {
        switch self {
        case .accessibility:
            return "内容仍会写入剪贴板，但需要自己按 ⌘V；工作台改用光标位置定位。"
        case .localNetwork:
            return "本机回环网关不受影响，仅跨设备配对不可用。"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_Accessibility")
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_LocalNetwork")
        }
    }
}

enum SystemPermissionStatus: Equatable {
    case granted
    case denied
    /// macOS exposes no read API for this one. Claiming to know would be
    /// worse than saying so.
    case undeterminable
}

struct SystemPermissionReport: Equatable {
    let permission: SystemPermission
    let status: SystemPermissionStatus
    /// True when asking the system to prompt cannot produce a dialog, because
    /// the app is already listed. The user has to toggle it themselves, and
    /// telling them to "click allow" on a prompt that will never appear is
    /// how this wasted their time.
    let promptWouldBeSilent: Bool

    var actionTitle: String {
        switch status {
        case .granted: return "打开设置"
        case .denied: return promptWouldBeSilent ? "前往系统设置" : "请求权限"
        case .undeterminable: return "打开设置"
        }
    }
}

enum SystemPermissionAudit {
    static func status(for permission: SystemPermission) -> SystemPermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .localNetwork:
            // There is no API that reports local-network authorization.
            return .undeterminable
        }
    }

    /// An ad-hoc signed build is re-signed on every rebuild, so a grant made
    /// against the previous binary no longer matches. TCC keeps the row and
    /// System Settings keeps the checkbox ticked, but the trust check fails
    /// and `AXIsProcessTrustedWithOptions` will not prompt for an app it has
    /// already recorded. That combination is why a grant looks present and
    /// behaves absent.
    static func isAdHocSigned(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
                == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode,
                                            SecCSFlags(rawValue: 0),
                                            &information) == errSecSuccess,
              let details = information as? [String: Any] else { return false }
        // An ad-hoc signature carries no certificate chain.
        let certificates = details[kSecCodeInfoCertificates as String] as? [Any]
        return (certificates?.isEmpty ?? true)
    }

    static func report(for permission: SystemPermission) -> SystemPermissionReport {
        let status = status(for: permission)
        let silent: Bool
        switch permission {
        case .accessibility:
            // Already listed — which an ad-hoc rebuild guarantees once the
            // user has granted it even once — means no prompt will appear.
            silent = status == .denied && isAdHocSigned()
        case .localNetwork:
            silent = true
        }
        return SystemPermissionReport(permission: permission,
                                      status: status,
                                      promptWouldBeSilent: silent)
    }

    static func reportAll() -> [SystemPermissionReport] {
        SystemPermission.allCases.map(report)
    }

    /// Requests or reveals, whichever can actually help. Returns whether a
    /// system prompt was attempted.
    @discardableResult
    static func requestOrReveal(_ permission: SystemPermission) -> Bool {
        let report = report(for: permission)
        if permission == .accessibility,
           report.status == .denied,
           !report.promptWouldBeSilent {
            ClipboardAutoPaste.requestPermission()
            return true
        }
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
