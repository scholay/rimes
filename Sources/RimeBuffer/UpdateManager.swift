import Cocoa

// MARK: - GitHub Release models

private struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - Update state

enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String, downloadUrl: String, notes: String)
    case noUpdate
    case downloading
    case readyToInstall(version: String, localZip: URL)
    case installing
    case error(String)

    static func == (lhs: UpdateStatus, rhs: UpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.noUpdate, .noUpdate),
             (.downloading, .downloading), (.installing, .installing):
            return true
        case let (.available(v1, _, _), .available(v2, _, _)): return v1 == v2
        case let (.readyToInstall(v1, u1), .readyToInstall(v2, u2)): return v1 == v2 && u1 == u2
        case let (.error(m1), .error(m2)): return m1 == m2
        default: return false
        }
    }
}

/// Pulls RIMES releases from GitHub while preserving the legacy ETInput update path.
///
/// Design mirrors Toolbit's UpdateManager (silent check → silent download →
/// notify → user-confirmed install), but:
///   * the install path is reworked for an IMK input method — the bundle lives
///     in `~/Library/Input Methods`, not `/Applications`, and must be
///     re-registered with Launch Services after the swap so the text-input
///     system picks up the new binary;
///   * it deliberately avoids actor isolation to match the rest of this
///     plain-AppKit codebase. Everything runs on the main thread: network
///     callbacks hop back via `onMain`, and `status` is only ever mutated there.
///
/// Not thread-safe by construction — call it from the main thread only.
final class UpdateManager {
    static let shared = UpdateManager()

    // Source of truth for the repo; matches .github/workflows and README.
    private let githubOwner = "scholay"
    private let githubRepo = "rimes"

    private(set) var status: UpdateStatus = .idle
    /// Invoked on the main thread whenever `status` changes, so the status-bar
    /// menu can rebuild and reflect an available update.
    var onChange: (() -> Void)?

    var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: Self.autoCheckKey) }
    }
    private(set) var lastCheckDate: Date?

    private static let autoCheckKey = "updateAutoCheckEnabled"
    private let checkInterval: TimeInterval = 3600  // 1 hour
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The version the user can install right now, if any.
    var pendingVersion: String? {
        switch status {
        case let .available(v, _, _): return v
        case let .readyToInstall(v, _): return v
        default: return nil
        }
    }

    var isUpdateReady: Bool {
        if case .readyToInstall = status { return true }
        return false
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            autoCheckEnabled = true                 // opt-out, not opt-in
        } else {
            autoCheckEnabled = UserDefaults.standard.bool(forKey: Self.autoCheckKey)
        }
    }

    // MARK: - Periodic silent check

    /// Kick off an immediate check and schedule hourly ones. Runs on the main
    /// runloop (started from `main.swift` before `NSApplication.run()`).
    func startPeriodicUpdateCheck() {
        guard autoCheckEnabled else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.silentCheckAndDownload()
        }
        silentCheckAndDownload()
    }

    func stopPeriodicUpdateCheck() {
        timer?.invalidate()
        timer = nil
    }

    /// Check, and if there's a newer release, download it quietly, leaving
    /// `status` at `.readyToInstall` so the menu can offer a one-click install.
    private func silentCheckAndDownload() {
        guard autoCheckEnabled else { return }
        if isUpdateReady { onChange?(); return }     // already staged
        checkForUpdates { [weak self] in
            guard let self else { return }
            if case let .available(version, url, _) = self.status {
                self.downloadZip(from: url, version: version, completion: { _ in })
            }
        }
    }

    // MARK: - Manual check (from the status menu)

    func checkNowManually() {
        if isUpdateReady { onChange?(); return }
        checkForUpdates { [weak self] in
            guard let self else { return }
            switch self.status {
            case let .available(version, url, _):
                self.downloadZip(from: url, version: version) { _ in
                    if case let .error(msg) = self.status {
                        self.showAlert(title: "下载更新失败", message: msg, warning: true)
                    }
                }
            case .noUpdate:
                self.showAlert(title: "已是最新版本", message: "当前版本 \(self.currentVersion) 已经是最新。")
            case let .error(msg):
                self.showAlert(title: "检查更新失败", message: msg, warning: true)
            default:
                break
            }
        }
    }

    // MARK: - Networking (completion-based; results delivered on the main thread)

    private func checkForUpdates(completion: @escaping () -> Void) {
        setStatus(.checking)
        let urlString = "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            setStatus(.error("无效的更新地址")); completion(); return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.onMain {
                guard let self else { return }
                defer { completion() }
                if let error {
                    self.setStatus(.error("检查更新失败: \(error.localizedDescription)")); return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    self.setStatus(.error("网络响应错误")); return
                }
                if http.statusCode == 404 {
                    // No published release yet — treat as up-to-date, don't nag.
                    self.lastCheckDate = Date()
                    self.setStatus(.noUpdate); return
                }
                guard http.statusCode == 200 else {
                    self.setStatus(.error("服务器错误: \(http.statusCode)")); return
                }
                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    self.lastCheckDate = Date()
                    let latest = release.tagName.hasPrefix("v")
                        ? String(release.tagName.dropFirst()) : release.tagName
                    guard self.isNewerVersion(latest, than: self.currentVersion) else {
                        self.setStatus(.noUpdate); return
                    }
                    // A stable release may also contain ZIP assets for browser
                    // extensions or other platforms. Only the frozen ETInput
                    // bundle name is a valid in-app update payload.
                    let expectedAssetName = "ETInput-\(latest).zip"
                    guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
                        self.setStatus(.error("最新 Release 未附带 \(expectedAssetName)")); return
                    }
                    IMELog.write("update: \(self.currentVersion) -> \(latest) available")
                    self.setStatus(.available(version: latest,
                                              downloadUrl: asset.browserDownloadUrl,
                                              notes: release.body))
                } catch {
                    self.setStatus(.error("解析 Release 失败: \(error.localizedDescription)"))
                }
            }
        }.resume()
    }

    private func downloadZip(from urlString: String, version: String,
                             completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            setStatus(.error("无效的下载地址")); completion(false); return
        }
        setStatus(.downloading)
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            // IMPORTANT: URLSession deletes `tempURL` as soon as this handler
            // returns, so move it synchronously here (on the background thread)
            // BEFORE hopping to main for the status update.
            guard let self else { return }
            if let error {
                self.onMain { self.setStatus(.error("下载失败: \(error.localizedDescription)")); completion(false) }
                return
            }
            guard let tempURL else {
                self.onMain { self.setStatus(.error("下载文件不存在")); completion(false) }
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ETInput-\(version).zip")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: tempURL, to: dest)
            } catch {
                self.onMain { self.setStatus(.error("保存文件失败: \(error.localizedDescription)")); completion(false) }
                return
            }
            self.onMain {
                IMELog.write("update: downloaded v\(version) -> \(dest.path)")
                self.setStatus(.readyToInstall(version: version, localZip: dest))
                completion(true)
            }
        }.resume()
    }

    // MARK: - Install (in place, IME-aware)

    /// Confirm with the user, then swap the running bundle for the downloaded
    /// one and relaunch. Only valid when an update is staged. Main thread only.
    func promptAndInstall() {
        guard case let .readyToInstall(version, zip) = status else { return }
        let alert = NSAlert()
        alert.messageText = "更新到 \(ProductIdentity.displayName) v\(version)？"
        alert.informativeText = "输入法进程会关闭并以新版本重启。若正在输入，请先完成再更新。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "稍后")
        alert.window.appearance = RimeUI.appKitAppearance
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installStagedUpdate(version: version, zip: zip)
    }

    private func installStagedUpdate(version: String, zip: URL) {
        setStatus(.installing)
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        let extractDir = tempDir.appendingPathComponent("ETInput_Update")

        do {
            if fm.fileExists(atPath: extractDir.path) { try fm.removeItem(at: extractDir) }
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // Strip quarantine off the zip, then unzip.
            runTool("/usr/bin/xattr", ["-cr", zip.path])
            runTool("/usr/bin/unzip", ["-o", zip.path, "-d", extractDir.path])

            let contents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                setStatus(.error("解压后未找到 \(ProductIdentity.displayName) 更新应用")); return
            }
            runTool("/usr/bin/xattr", ["-cr", newApp.path])

            // Install over the running bundle when we're a real .app; otherwise
            // fall back to the canonical Input Methods location (dev binaries).
            let current = Bundle.main.bundleURL
            let target = current.pathExtension == "app"
                ? current
                : URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Input Methods/ETInput.app")

            let pid = ProcessInfo.processInfo.processIdentifier
            let lsregister = "/System/Library/Frameworks/CoreServices.framework"
                + "/Frameworks/LaunchServices.framework/Support/lsregister"
            let scriptURL = tempDir.appendingPathComponent("rimebuffer-update.sh")
            let logURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("rimebuffer-update.log")

            // Every interpolated value goes through q() into a bash variable so
            // nothing (paths, or the version string, which comes from a GitHub
            // tag) can be shell-injected. The swap itself is copy-to-staging →
            // atomic rename → rollback, so a failed/interrupted copy can never
            // leave the input method with no installed bundle.
            let script = """
            #!/bin/bash
            exec > \(q(logURL.path)) 2>&1
            TARGET=\(q(target.path))
            NEWAPP=\(q(newApp.path))
            EXTRACT=\(q(extractDir.path))
            ZIP=\(q(zip.path))
            SCRIPT=\(q(scriptURL.path))
            LSREGISTER=\(q(lsregister))
            VERSION=\(q(version))
            echo "ETInput update -> v$VERSION"

            # Select ABC (or another non-ETInput ASCII source) while the old
            # controller is still alive. This gives the active host a normal
            # IMK deactivate before we exit and replace the bundle.
            if ! "$NEWAPP/Contents/MacOS/ETInput" --prepare-update; then
              echo "could not select a safe fallback; refusing hot replacement"
              exit 1
            fi

            # Wait for the old process to exit, then kill any instance the
            # text-input system may have relaunched so nothing holds the bundle.
            for i in $(seq 1 40); do
              kill -0 \(pid) 2>/dev/null || { echo "old process exited"; break; }
              sleep 0.25
            done
            pkill -x ETInput 2>/dev/null || true
            sleep 0.5

            # Stage the new bundle BESIDE the target first. If this fails, the
            # current install is untouched — never rm the only copy up front.
            STAGED="$TARGET.new"
            rm -rf "$STAGED"
            if ! cp -R "$NEWAPP" "$STAGED"; then
              echo "stage copy failed; leaving current install in place"
              rm -rf "$STAGED"
              "$TARGET/Contents/MacOS/ETInput" --install || true
              open "$TARGET" || true
              exit 1
            fi
            xattr -cr "$STAGED" 2>/dev/null || true
            xattr -d com.apple.quarantine "$STAGED" 2>/dev/null || true

            # Atomic same-volume swap, with rollback if anything goes wrong.
            BACKUP="$TARGET.bak"
            rm -rf "$BACKUP"
            if [ -e "$TARGET" ] && ! mv "$TARGET" "$BACKUP"; then
              echo "could not move current bundle aside; aborting"
              rm -rf "$STAGED"
              "$TARGET/Contents/MacOS/ETInput" --install || true
              open "$TARGET" || true
              exit 1
            fi
            if ! mv "$STAGED" "$TARGET"; then
              echo "swap failed; rolling back"
              [ -e "$BACKUP" ] && mv "$BACKUP" "$TARGET"
              rm -rf "$STAGED"
              "$TARGET/Contents/MacOS/ETInput" --install || true
              open "$TARGET" || true
              exit 1
            fi
            echo "re-registering and activating input source"
            "$LSREGISTER" -f "$TARGET" || true
            killall imklaunchagent 2>/dev/null || true
            killall TextInputMenuAgent 2>/dev/null || true
            if ! "$TARGET/Contents/MacOS/ETInput" --install; then
              echo "input-source activation failed; rolling back"
              "$LSREGISTER" -u "$TARGET" 2>/dev/null || true
              rm -rf "$TARGET"
              [ -e "$BACKUP" ] && mv "$BACKUP" "$TARGET"
              "$LSREGISTER" -f "$TARGET" || true
              killall imklaunchagent 2>/dev/null || true
              killall TextInputMenuAgent 2>/dev/null || true
              "$TARGET/Contents/MacOS/ETInput" --install || true
              open "$TARGET" || true
              exit 1
            fi
            killall TextInputMenuAgent 2>/dev/null || true
            rm -rf "$BACKUP"

            echo "relaunching"
            open "$TARGET"

            # Only remove the recovery sources after a successful swap.
            rm -rf "$EXTRACT"
            rm -f "$ZIP"
            echo "done"
            sleep 2
            rm -f "$SCRIPT"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            // nohup + detach so the swap survives our own exit.
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            proc.arguments = ["/bin/bash", scriptURL.path]
            proc.standardOutput = nil
            proc.standardError = nil
            // Don't strand a composition or lose key stats before we go.
            RimeBufferController.active?.forceCommit()
            InputMetricsPersistence.saveNow()
            try proc.run()

            IMELog.write("update: install script launched for v\(version), exiting")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exit(0) }
        } catch {
            setStatus(.error("安装失败: \(error.localizedDescription)"))
            IMELog.write("update: install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    func openReleasesPage() {
        if let url = URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setStatus(_ new: UpdateStatus) {
        guard new != status else { return }
        status = new
        onChange?()
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func runTool(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        try? p.run()
        p.waitUntilExit()
    }

    /// Single-quote a path for safe embedding in the generated bash script.
    private func q(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func showAlert(title: String, message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "好的")
        alert.window.appearance = RimeUI.appKitAppearance
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Numeric, component-wise semver compare (ignores any pre-release suffix).
    private func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
