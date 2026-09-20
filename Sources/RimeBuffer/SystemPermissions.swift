import AVFoundation
import ApplicationServices
import Cocoa
import CoreGraphics

/// Every macOS permission RIMES actually uses, what stops working without it,
/// and how to reach the pane that grants it.
///
/// Written as one list because the alternative is what happened before: a
/// feature declines, logs a line nobody reads, and silently falls back — so a
/// missing grant looks like a broken feature. Anything not listed here is not
/// requested.
///
/// Input Monitoring was deliberately absent while the global monitors watched
/// mouse buttons only. Screen capture's keystroke overlay reads keys, so it is
/// listed now — the comment claiming otherwise outlived the feature that
/// justified it.
enum SystemPermission: String, CaseIterable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case camera
    case microphone
    case localNetwork

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .screenRecording: return "屏幕录制"
        case .inputMonitoring: return "输入监控"
        case .camera: return "摄像头"
        case .microphone: return "麦克风"
        case .localNetwork: return "本地网络"
        }
    }

    /// Named features, not categories. "Needed for accessibility reasons" tells
    /// the user nothing about what they lose.
    var enables: String {
        switch self {
        case .accessibility:
            return "剪贴板自动粘贴、工作台对齐目标输入框、输入框高亮提示、"
                + "滚动截图的自动滚动"
        case .screenRecording:
            return "截图、滚动截图、贴图与录屏"
        case .inputMonitoring:
            return "录屏时显示全局按键"
        case .camera:
            return "录屏时的摄像头画面"
        case .microphone:
            return "录屏时录制麦克风"
        case .localNetwork:
            return "Marine 局域网配对与跨设备直连"
        }
    }

    var whenMissing: String {
        switch self {
        case .accessibility:
            return "内容仍会写入剪贴板，但需要自己按 ⌘V；工作台改用光标位置定位；"
                + "滚动截图只能手动滚动。"
        case .screenRecording:
            return "截图与录屏无法取得画面，捕获面板不可用。"
        case .inputMonitoring:
            return "录屏可继续，但需关闭「显示按键」选项。"
        case .camera:
            return "录屏可继续，画面中不含摄像头。"
        case .microphone:
            return "录屏可继续，只录系统声或无声。"
        case .localNetwork:
            return "本机回环网关不受影响，仅跨设备配对不可用。"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_Accessibility")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_ScreenCapture")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_ListenEvent")
        case .camera:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_Camera")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference"
                + ".security?Privacy_Microphone")
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
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .denied
        case .camera:
            return mediaStatus(for: .video)
        case .microphone:
            return mediaStatus(for: .audio)
        case .localNetwork:
            // There is no API that reports local-network authorization.
            return .undeterminable
        }
    }

    private static func mediaStatus(
        for type: AVMediaType
    ) -> SystemPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return .granted
        default: return .denied
        }
    }

    /// An ad-hoc signed build is re-signed on every rebuild, so a grant made
    /// against the previous binary no longer matches. TCC keeps the row and
    /// System Settings keeps the checkbox ticked, but the trust check fails
    /// and `AXIsProcessTrustedWithOptions` will not prompt for an app it has
    /// already recorded. That combination is why a grant looks present and
    /// behaves absent.
    /// The signing authority, when there is one. An identity-signed build has
    /// a designated requirement naming its certificate rather than a cdhash,
    /// which is what lets a grant outlive a rebuild.
    static func signingAuthority(bundleURL: URL = Bundle.main.bundleURL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
                == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let details = information as? [String: Any],
              let certificates = details[kSecCodeInfoCertificates as String]
                as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        var common: CFString?
        guard SecCertificateCopyCommonName(leaf, &common) == errSecSuccess,
              let name = common as String? else { return nil }
        return name
    }

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
        case .camera, .microphone:
            // These prompt exactly once. After any answer the system returns
            // the recorded one without showing anything.
            let type: AVMediaType = permission == .camera ? .video : .audio
            silent = AVCaptureDevice.authorizationStatus(for: type)
                != .notDetermined
        case .screenRecording, .inputMonitoring:
            // CoreGraphics exposes no "not determined" state for these, so a
            // request may or may not raise a prompt. Attempting it and
            // falling back to System Settings is the honest behaviour;
            // claiming to know in advance is not.
            silent = false
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

    /// The identity macOS actually records a grant against, which is not the
    /// name on the bundle. This app carries three: the folder and executable
    /// say ETInput, the display name says RIMES, and the identifier — the only
    /// one TCC uses — says RimeBuffer. Anyone hunting for the right row in
    /// System Settings needs the third one, so it is shown rather than
    /// assumed.
    struct Identity: Equatable {
        let bundleIdentifier: String
        let bundleName: String
        let executableName: String
        let bundlePath: String
        let isAdHocSigned: Bool

        var namesAgree: Bool {
            let tail = bundleIdentifier.split(separator: ".").last.map(String.init)
            return tail == executableName && executableName == bundleName
        }
    }

    static func identity(bundle: Bundle = .main) -> Identity {
        Identity(
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            bundleName: (bundle.object(forInfoDictionaryKey: "CFBundleName")
                as? String) ?? "unknown",
            executableName: (bundle.object(
                forInfoDictionaryKey: "CFBundleExecutable"
            ) as? String) ?? "unknown",
            bundlePath: bundle.bundleURL.path,
            isAdHocSigned: isAdHocSigned(bundleURL: bundle.bundleURL)
        )
    }

    /// Clears this app's recorded decision so the system will ask again.
    ///
    /// `AXIsProcessTrustedWithOptions` prompts only for an app macOS has no
    /// record of, and an ad-hoc rebuild leaves a record that no longer matches
    /// the binary — granted in appearance, denied in effect, and unable to ask
    /// again. Removing the record is the only way back to a working prompt
    /// without the user hand-editing a list.
    @discardableResult
    static func resetAccessibilityRecord(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            IMELog.write("permissions: tccutil unavailable: \(error.localizedDescription)")
            return false
        }
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let unknownBundle = output.contains("No such bundle")
        let ok = process.terminationStatus == 0 && !unknownBundle
        IMELog.write(
            "permissions: reset Accessibility for \(bundleIdentifier) ok=\(ok) "
                + "status=\(process.terminationStatus) unknownBundle=\(unknownBundle)"
        )
        return ok
    }

    /// Requests or reveals, whichever can actually help. Returns whether a
    /// system prompt was attempted.
    @discardableResult
    static func requestOrReveal(_ permission: SystemPermission) -> Bool {
        let report = report(for: permission)
        guard report.status != .granted else {
            if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
            return false
        }
        switch permission {
        case .accessibility:
            if !report.promptWouldBeSilent {
                ClipboardAutoPaste.requestPermission()
                return true
            }
        case .screenRecording:
            // Returns false when macOS has a recorded denial and shows
            // nothing; fall through to Settings in that case.
            if CGRequestScreenCaptureAccess() { return true }
        case .inputMonitoring:
            if CGRequestListenEventAccess() { return true }
        case .camera, .microphone:
            let type: AVMediaType = permission == .camera ? .video : .audio
            if AVCaptureDevice.authorizationStatus(for: type) == .notDetermined {
                AVCaptureDevice.requestAccess(for: type) { _ in }
                return true
            }
        case .localNetwork:
            break
        }
        if let url = permission.settingsURL {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    /// One call for a feature about to need a permission: true when it can
    /// proceed now. Everything that needs a grant goes through here so the
    /// panel and the feature can never disagree about what was asked for.
    @discardableResult
    static func ensure(_ permission: SystemPermission) -> Bool {
        if status(for: permission) == .granted { return true }
        requestOrReveal(permission)
        return status(for: permission) == .granted
    }
}
