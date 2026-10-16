import AppKit
import ImageIO
import ScreenCaptureKit

@MainActor
enum CapturePermissionSmoke {
    /// Fakes only: never requests TCC, reads real screen content, resets a
    /// permission, opens System Settings or restarts the live input method.
    static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("permission: " + message) }
        }
        let firstUse = CapturePermissionPresentation(permission: .accessibility, intent: .enable, state: .idle, continuing: false)
        try require(firstUse.showsAddition && !firstUse.showsContinue, "manual grant shows drag instructions without action buttons")
        let camera = CapturePermissionPresentation(permission: .camera, intent: .enable, state: .idle, continuing: false)
        try require(!camera.showsAddition, "request-only panes never promise a file drag")
        let revoke = CapturePermissionPresentation(permission: .accessibility, intent: .disable, state: .idle, continuing: false)
        try require(!revoke.showsAddition && revoke.message.contains("关闭"), "off intent explains the system switch without requesting a new grant")
        let revoked = CapturePermissionPresentation(permission: .screenRecording, intent: .enable, state: .blocked, continuing: true)
        try require(!revoked.showsContinue, "actual denial overrides a stale granted preflight")
        let granted = CapturePermissionPresentation(permission: .screenRecording, intent: .enable, state: .ready, continuing: true)
        try require(granted.showsContinue, "capture still requires explicit continuation after authorization")
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        try require(CapturePermissionCheck.isPermissionFailure(denied), "recognizes framework denial")
        try require(CapturePermissionCheck.isPermissionFailure(NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: denied])), "wrapped denial")
        try require(!CapturePermissionCheck.isPermissionFailure(NSError(domain: SCStreamErrorDomain, code: -3811)), "capture service failure is not permission denial")
        try require(!CapturePermissionCheck.isPermissionFailure(NSError(domain: "another.domain", code: -3801)), "error domain matters")
        let check = CapturePermissionCheck()
        var calls = 0
        await check.check { calls += 1 }
        try require(check.state == .ready && calls == 1, "actual success accepted without preflight gate")
        await check.check { throw denied }
        try require(check.state == .blocked, "revocation invalidates earlier success")
        await check.check { throw CaptureError.message("service unavailable") }
        try require(check.state == .failed("service unavailable"), "nonpermission error preserved")
        await check.check {}
        try require(check.state == .ready, "explicit retry recovers")

        var reply: CheckedContinuation<Void, Error>?
        let pending = Task { await check.check { try await withCheckedThrowingContinuation { reply = $0 } } }
        while reply == nil { await Task.yield() }
        try require(check.state == .checking, "no denial while awaiting system answer")
        var duplicateRan = false
        await check.check { duplicateRan = true }
        try require(!duplicateRan && check.state == .checking, "deduplicates repeated clicks")
        check.cancel()
        await check.check { throw denied }
        reply?.resume(); await pending.value
        try require(check.state == .blocked, "late success cannot resurrect cancelled request")

        var fakeStatus = SystemPermissionStatus.denied
        var events: [String] = []
        var systemReply: CheckedContinuation<Void, Never>?
        let environment = PermissionGuideEnvironment(status: { _ in fakeStatus },
            openSettings: { events.append("settings:\($0.rawValue)") },
            request: { permission in
                events.append("request:\(permission.rawValue)")
                await withCheckedContinuation { systemReply = $0 }
            }, verify: { _ in if fakeStatus != .granted { throw denied } })
        let guide = CapturePermissionGuide(environment: environment)
        guide.show(.accessibility)
        try require(events == ["settings:accessibility"], "a single switch action reveals the exact pane immediately")
        while systemReply == nil { await Task.yield() }
        try require(events == ["settings:accessibility", "request:accessibility"], "the same attempt invokes the native request")
        fakeStatus = .granted; systemReply?.resume(); systemReply = nil
        for _ in 0..<100 where guide.isPresented { await Task.yield() }
        try require(!guide.isPresented, "verified grant completes without an I-enabled button")
        events.removeAll()
        guide.show(.accessibility, intent: .disable)
        try require(events == ["settings:accessibility"], "turning off never triggers a permission request")
        fakeStatus = .denied
        guide.refreshPermissionStatus()
        try require(!guide.isPresented, "observed system revocation closes the guide")

        var continued = false
        events.removeAll()
        guide.show(.camera) { continued = true }
        while systemReply == nil { await Task.yield() }
        fakeStatus = .granted; systemReply?.resume(); systemReply = nil
        for _ in 0..<100 { await Task.yield() }
        try require(guide.isPresented && !continued, "returning from settings never starts a delayed capture")
        guide.dismiss()

        var networkStarted = false, networkCancelled = false, networkVerified = false
        let networkGuide = CapturePermissionGuide(environment: PermissionGuideEnvironment(
            status: { _ in .undeterminable }, openSettings: { events.append("settings:\($0.rawValue)") },
            request: { _ in
                networkStarted = true
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { networkCancelled = true }
            }, verify: { _ in networkVerified = true }))
        networkGuide.show(.localNetwork)
        while !networkStarted { await Task.yield() }
        try require(events.last == "settings:localNetwork", "unknown network status still requests access and reveals its pane")
        networkGuide.dismiss()
        for _ in 0..<100 where !networkCancelled { await Task.yield() }
        try require(networkCancelled && !networkVerified, "closing cancels the bounded network request without inventing a grant")

        var cardReports = SystemPermission.allCases.map { SystemPermissionReport(permission: $0,
            status: $0 == .localNetwork ? .undeterminable : .denied, promptWouldBeSilent: false) }
        var changes: [(SystemPermission, PermissionChangeIntent)] = []
        let cards = SystemPermissionsView(reports: { cardReports }) { changes.append(($0, $1)) }
        cards.cards[0].permissionSwitch.performClick(nil)
        try require(changes.last?.0 == .accessibility && changes.last?.1 == .enable
                    && cards.cards[0].permissionSwitch.state == .off,
                    "permission intent never fakes an enabled system state")
        cardReports[0] = .init(permission: .accessibility, status: .granted, promptWouldBeSilent: true)
        cards.refresh(); cards.cards[0].permissionSwitch.performClick(nil)
        try require(changes.last?.1 == .disable && cards.cards[0].permissionSwitch.state == .on,
                    "granted switch asks to disable while retaining the real state")
        try require(cards.cards.last?.permissionSwitch.reportedStatus == .undeterminable,
                    "local network does not fabricate a known grant")
        let cardWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 290),
            styleMask: [.borderless], backing: .buffered, defer: false)
        cardWindow.isReleasedWhenClosed = false
        cardWindow.appearance = RimeUI.appKitAppearance
        let host = cardWindow.contentView!
        host.wantsLayer = true; host.layer?.backgroundColor = RimeUI.surface.cgColor
        host.addSubview(cards)
        NSLayoutConstraint.activate([cards.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                                     cards.topAnchor.constraint(equalTo: host.topAnchor)])
        host.layoutSubtreeIfNeeded()
        for card in cards.cards {
            try require(card.bounds.width > 180 && card.bounds.height == 118, "compact three-column cards keep usable width")
            try require(card.permissionSwitch.visibleRect.contains(card.permissionSwitch.bounds), "permission switch remains fully visible")
        }
        if let path = ProcessInfo.processInfo.environment["RIMES_PERMISSION_SMOKE_OUTPUT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        cardWindow.close()
        for kind in PermissionGuideAnimation.Kind.allCases {
            for theme in ["light", "dark"] {
                guard let url = PermissionGuideAnimation.resourceURL("\(kind.rawValue)-\(theme)", extension: "gif"),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CaptureError.message("permission GIF missing") }
                try require(CGImageSourceGetCount(source) > 1, "guide resource is a real animated GIF")
            }
        }

        var options = CaptureRecordingOptions()
        try require(CaptureRecorderController.optionalPermissions(options).isEmpty, "plain recording asks no optional permission")
        options.camera = true; options.microphone = true; options.keys = true
        try require(CaptureRecorderController.optionalPermissions(options) == [.camera, .microphone, .inputMonitoring, .accessibility], "only enabled inputs, deterministic sequence")
        options.format = "GIF"
        try require(!CaptureRecorderController.optionalPermissions(options).contains(.microphone), "GIF does not request microphone")

        let manual: Set<SystemPermission> = [.screenRecording, .accessibility, .inputMonitoring]
        try require(Set(SystemPermission.allCases.filter(\.supportsManualApplicationAddition)) == manual,
                    "camera and microphone must not promise manual app addition")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-permission-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ name: String, identifier: String) throws -> URL {
            let app = root.appendingPathComponent(name)
            let contents = app.appendingPathComponent("Contents")
            let executables = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleName": "RIMES",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "RIMES"
            ], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            let executable = executables.appendingPathComponent("RIMES")
            try Data("test fixture, never executed".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            return app
        }
        // Never create/register a second real input-method bundle identity.
        let fixtureIdentifier = "example.rimes-permission-smoke.\(UUID().uuidString)"
        let app = try fixture("含空格 RIMES.app", identifier: fixtureIdentifier)
        let other = try fixture("Other.app", identifier: "example.other")
        try require(PermissionApplication.appURL(bundleURL: root) == nil, "bare build folder is not an installed app")
        try require(PermissionApplication.appURL(bundleURL: other) == nil, "wrong app identity rejected")
        let resolved = app.standardizedFileURL.resolvingSymlinksInPath()
        try require(PermissionApplication.appURL(bundleURL: app, expectedIdentifier: fixtureIdentifier) == resolved, "exact app bundle, including spaces and Unicode")
        guard let writer = PermissionApplication.fileWriter(for: app, expectedIdentifier: fixtureIdentifier) else { throw CaptureError.message("permission: file writer missing") }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try require(pasteboard.writeObjects([writer]), "native file URL writer")
        try require(pasteboard.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL == resolved,
                    "drag transfers actual app URL, not icon data or a path string")
        try require(PermissionApplicationIcon.dragOperations == .copy, "app drag never offers move/delete")
        let inert = PermissionApplicationIcon(applicationURL: app, allowsSystemActions: false)
        try require(inert.fileWriterForDrag() == nil, "preview cannot export an app drag")
        try FileManager.default.removeItem(at: app)
        try require(PermissionApplication.fileWriter(for: app, expectedIdentifier: fixtureIdentifier) == nil, "deleted app cannot be dragged through a stale view")
        print("capture-permission-smoke: OK (switch truth, direct settings/request, observed grants/revocations, explicit capture continuation, GIFs, async cancellation, exact app drag)")
    }
}
