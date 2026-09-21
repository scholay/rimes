import AppKit
import ScreenCaptureKit

@MainActor
enum CapturePermissionSmoke {
    /// Fakes only: never requests TCC, reads real screen content, resets a
    /// permission, opens System Settings or restarts the live input method.
    static func run() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw CaptureError.message("permission: " + message) }
        }
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
        print("capture-permission-smoke: OK (real-error classification, async answer, cancellation, retry, optional inputs, app identity, file drag, inert preview)")
    }
}
