import Cocoa
import InputMethodKit
import Network
import CryptoKit
import Carbon
import Darwin

// OpenSSH invokes this same executable as a narrowly scoped SSH_ASKPASS
// helper. Handle that request before any smoke, installer, AppKit, or IMK
// startup so the helper can return the saved password and terminate without
// creating a second input-method process.
if let status = RemarkableSSHAskPassHandler.handleIfRequested() {
    exit(status)
}

/// Standalone commands share the shipped executable with the live IMK server,
/// but must never share its LevelDB-backed Rime user directory. Keep this rule
/// above every smoke/subcommand dispatch so even a newly added smoke that starts
/// `rimeEngine` inherits isolation before the lazy global is initialized.
private enum StandaloneRimeCommandRules {
    private static let engineHostingCommands: Set<String> = [
        "settings-preview",
        "settings-render",
    ]

    static func requiresIsolatedUserDir(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { argument in
            argument == "smoke"
                || argument.hasSuffix("-smoke")
                || engineHostingCommands.contains(argument)
        }
    }

    static func isLiveUserDir(_ path: String,
                              homeDirectory: String = NSHomeDirectory()) -> Bool {
        let candidateURL = URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let liveURL = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/RimeBuffer", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        // macOS user volumes are commonly case-insensitive, and firmlinks or
        // symlinks can spell the same directory with a different path. Compare
        // every existing candidate ancestor by filesystem identity so a child
        // of the live profile is rejected even when its final leaf does not yet
        // exist. The string fallback is deliberately case-insensitive/fail-
        // closed for test homes or a profile that has not been created yet.
        func identity(_ url: URL) -> (device: UInt64, inode: UInt64)? {
            var metadata = stat()
            guard url.path.withCString({ stat($0, &metadata) }) == 0 else {
                return nil
            }
            return (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
        }
        if let liveIdentity = identity(liveURL) {
            var ancestor = candidateURL
            // Bound traversal by the syntactic depth as well as checking `/`.
            // Foundation may represent deleting the parent of root as `/..` on
            // some SDKs, so parent equality alone is not a termination proof.
            for _ in 0...candidateURL.pathComponents.count {
                if let candidateIdentity = identity(ancestor),
                   candidateIdentity.device == liveIdentity.device,
                   candidateIdentity.inode == liveIdentity.inode {
                    return true
                }
                if ancestor.path == "/" { break }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
        }

        let candidate = candidateURL.path
        let live = liveURL.path
        return candidate.compare(live, options: [.caseInsensitive]) == .orderedSame
            || candidate.range(
                of: live + "/",
                options: [.anchored, .caseInsensitive]
            ) != nil
    }
}

private var automaticallyCreatedStandaloneUserDir: String?

private func removeAutomaticallyCreatedStandaloneUserDir() {
    guard let path = automaticallyCreatedStandaloneUserDir else { return }
    automaticallyCreatedStandaloneUserDir = nil
    let root = URL(fileURLWithPath: path, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let temporaryRoot = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    guard root.deletingLastPathComponent().path == temporaryRoot.path,
          root.lastPathComponent.hasPrefix("rimebuffer-standalone-") else {
        return
    }
    try? FileManager.default.removeItem(at: root)
}

/// Finds the source trees used by `build_install.sh` when the smoke binary is
/// run directly from a SwiftPM checkout. A packaged ETInput.app already has a
/// complete SharedSupport directory and never takes this path.
private func engineSmokeRepositoryRoot() -> URL? {
    let fileManager = FileManager.default
    var startingPoints = [
        URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
    ]
    if let executable = CommandLine.arguments.first, !executable.isEmpty {
        let executableURL = URL(fileURLWithPath: executable)
        startingPoints.append(
            executableURL.isFileURL
                ? executableURL.deletingLastPathComponent()
                : executableURL
        )
    }

    for startingPoint in startingPoints {
        var candidate = startingPoint.standardizedFileURL
        for _ in 0..<8 {
            let productData = candidate.appendingPathComponent(
                "rime-data/default.custom.yaml"
            )
            let vendorData = candidate.appendingPathComponent(
                "Vendor/rime/SharedSupport/default.yaml"
            )
            let vendorRuntime = candidate.appendingPathComponent(
                "Vendor/rime/Frameworks/librime.1.dylib"
            )
            if fileManager.fileExists(atPath: productData.path),
               fileManager.fileExists(atPath: vendorData.path),
               fileManager.fileExists(atPath: vendorRuntime.path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
    }
    return nil
}

/// Merge a reviewed fixture tree without following symlinks. The destination
/// is always a fresh child of the isolated smoke directory, so replacements
/// can only affect disposable test data.
private func mergeEngineSmokeFixtureTree(from source: URL,
                                         into destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: destination,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard let enumerator = fileManager.enumerator(
        at: source,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ],
        options: [.skipsHiddenFiles]
    ) else {
        throw CocoaError(.fileReadUnknown)
    }

    let sourcePrefix = source.standardizedFileURL.path + "/"
    for case let item as URL in enumerator {
        let values = try item.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true,
              item.standardizedFileURL.path.hasPrefix(sourcePrefix) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relativePath = String(
            item.standardizedFileURL.path.dropFirst(sourcePrefix.count)
        )
        guard !relativePath.isEmpty else { continue }
        let target = destination.appendingPathComponent(
            relativePath,
            isDirectory: values.isDirectory == true
        )
        if values.isDirectory == true {
            try fileManager.createDirectory(
                at: target,
                withIntermediateDirectories: true
            )
        } else if values.isRegularFile == true {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: item, to: target)
        } else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
}

/// A checkout build has no app-bundle SharedSupport. Recreate the same
/// Vendor+rime-data overlay as `build_install.sh`, but only inside the isolated
/// smoke directory. This avoids both Squirrel's schemas and the live RIMES
/// userdb while exercising the current checkout's product data.
private func configureEngineSmokeRuntime(isolatedUserDir: String) -> Bool {
    let environment = ProcessInfo.processInfo.environment
    if let explicit = environment["RIMEBUFFER_SHARED_DIR"], !explicit.isEmpty {
        return true
    }
    if let bundled = Bundle.main.sharedSupportURL,
       FileManager.default.fileExists(
           atPath: bundled.appendingPathComponent("default.custom.yaml").path
       ),
       FileManager.default.fileExists(
           atPath: bundled.appendingPathComponent("my_combo.schema.yaml").path
       ) {
        return true
    }
    guard let repositoryRoot = engineSmokeRepositoryRoot() else {
        FileHandle.standardError.write(Data(
            "cannot locate product Rime data for engine smoke\n".utf8
        ))
        return false
    }

    let isolatedRoot = URL(fileURLWithPath: isolatedUserDir, isDirectory: true)
    let sharedSupport = isolatedRoot.appendingPathComponent(
        ".engine-smoke-shared-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try mergeEngineSmokeFixtureTree(
            from: repositoryRoot.appendingPathComponent(
                "Vendor/rime/SharedSupport",
                isDirectory: true
            ),
            into: sharedSupport
        )
        try mergeEngineSmokeFixtureTree(
            from: repositoryRoot.appendingPathComponent(
                "rime-data",
                isDirectory: true
            ),
            into: sharedSupport
        )
    } catch {
        FileHandle.standardError.write(Data(
            "cannot stage product Rime data for engine smoke\n".utf8
        ))
        return false
    }

    guard setenv("RIMEBUFFER_SHARED_DIR", sharedSupport.path, 1) == 0 else {
        FileHandle.standardError.write(Data(
            "cannot activate product Rime data for engine smoke\n".utf8
        ))
        return false
    }
    if environment["RIMEBUFFER_FRAMEWORKS_DIR"]
        .flatMap({ $0.isEmpty ? nil : $0 }) == nil {
        let frameworks = repositoryRoot.appendingPathComponent(
            "Vendor/rime/Frameworks",
            isDirectory: true
        )
        guard setenv("RIMEBUFFER_FRAMEWORKS_DIR", frameworks.path, 1) == 0 else {
            FileHandle.standardError.write(Data(
                "cannot activate isolated Rime runtime for engine smoke\n".utf8
            ))
            return false
        }
    }
    return true
}

private func standaloneIsolationAliasProbe(isolatedUserDir: String) -> Bool {
    let fileManager = FileManager.default
    let fixture = URL(fileURLWithPath: isolatedUserDir, isDirectory: true)
        .appendingPathComponent(
            ".isolation-alias-probe-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? fileManager.removeItem(at: fixture) }
    let fakeHome = fixture.appendingPathComponent("home", isDirectory: true)
    let live = fakeHome.appendingPathComponent(
        "Library/RimeBuffer",
        isDirectory: true
    )
    let alias = fixture.appendingPathComponent("profile-alias", isDirectory: true)
    do {
        try fileManager.createDirectory(
            at: live,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: live)
    } catch {
        return false
    }
    return StandaloneRimeCommandRules.isLiveUserDir(
            alias.appendingPathComponent("future-child").path,
            homeDirectory: fakeHome.path
        )
        && !StandaloneRimeCommandRules.isLiveUserDir(
            fixture.appendingPathComponent("unrelated/profile").path,
            homeDirectory: fakeHome.path
        )
}

/// Returns the isolated directory in force, respecting an explicit non-live
/// override. An override that resolves to the installed IME's user directory is
/// replaced rather than trusted: smoke tooling is never authorized to open the
/// live userdb, even when invoked accidentally with that path in its environment.
@discardableResult
private func isolateStandaloneRimeUserDir() -> String? {
    let environment = ProcessInfo.processInfo.environment
    let configured = environment["RIMEBUFFER_USER_DIR"]
        .flatMap { $0.isEmpty ? nil : $0 }
    let directory: String
    let createdAutomatically: Bool
    if let configured,
       !StandaloneRimeCommandRules.isLiveUserDir(configured) {
        directory = configured
        createdAutomatically = false
    } else {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "rimebuffer-standalone-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            ).path
        createdAutomatically = true
        if configured != nil {
            FileHandle.standardError.write(Data(
                "refusing live RIMEBUFFER_USER_DIR for standalone command; using an isolated directory\n".utf8
            ))
        }
    }

    do {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        FileHandle.standardError.write(Data(
            "cannot create isolated Rime user directory\n".utf8
        ))
        return nil
    }
    guard setenv("RIMEBUFFER_USER_DIR", directory, 1) == 0 else {
        FileHandle.standardError.write(Data(
            "cannot activate isolated Rime user directory\n".utf8
        ))
        return nil
    }
    if createdAutomatically,
       automaticallyCreatedStandaloneUserDir == nil {
        automaticallyCreatedStandaloneUserDir = directory
        atexit(removeAutomaticallyCreatedStandaloneUserDir)
    }
    return directory
}

if StandaloneRimeCommandRules.requiresIsolatedUserDir(
    arguments: CommandLine.arguments
) {
    guard let isolatedUserDir = isolateStandaloneRimeUserDir() else {
        exit(1)
    }
    if CommandLine.arguments.contains("smoke"),
       !configureEngineSmokeRuntime(isolatedUserDir: isolatedUserDir) {
        exit(1)
    }
}

// Recovery seam for the unpacked companion extension. Credentials remain
// internal: reset rotates them and reports only a non-secret completion line.
if CommandLine.arguments.contains("marine-chrome-reset-pairing") {
    do {
        // Advance the credential generation under the same cross-process lock
        // used by interactive issuance. A pre-reset approval can therefore no
        // longer race this helper and publish a usable credential afterwards.
        _ = try MarineChromeCredentialTransaction.reset()
        DistributedNotificationCenter.default().postNotificationName(
            .marineChromeCredentialsDidReset,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        print("marine-chrome pairing reset")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data(
            "cannot reset marine-chrome pairing\n".utf8
        ))
        exit(1)
    }
}

private var marineChromeCredentialsResetObserver: NSObjectProtocol?

private func installMarineChromePairingApprovalHandler() {
    MarineChromePairingBroker.shared.setApprovalHandler { request, respond in
        MarineChromePairingPromptController.shared.present(
            request,
            respond: respond
        )
    }
    MarineChromePairingBroker.shared.setCancellationHandler { requestID in
        DispatchQueue.main.async {
            MarineChromePairingPromptController.shared.cancel(
                requestID: requestID
            )
        }
    }
    guard marineChromeCredentialsResetObserver == nil else { return }
    marineChromeCredentialsResetObserver = DistributedNotificationCenter
        .default().addObserver(
            forName: .marineChromeCredentialsDidReset,
            object: nil,
            queue: .main
        ) { _ in
            MarineChromePairingBroker.shared.cancelAll()
            MarineChromePairingPromptController.shared.cancel()
            MarineChromeContextStore.shared.clear()
            NotificationCenter.default.post(
                name: .marineChromePairingDidChange,
                object: nil
            )
        }
}

// Safe maintenance seam used by installers and support diagnostics. Loading
// applies narrowly scoped, atomic configuration migrations without printing
// Base URLs, model names, or API keys.
if CommandLine.arguments.contains("openai-config-migrate") {
    do {
        guard try OpenAICompatibleConfigurationStore.shared.load() != nil else {
            print("OpenAI-compatible configuration is not set")
            exit(2)
        }
        print("OpenAI-compatible configuration is ready")
        exit(0)
    } catch {
        print("OpenAI-compatible configuration is invalid")
        exit(1)
    }
}

// `swift run RimeBuffer smoke` validates the engine end-to-end without IMK.
if CommandLine.arguments.contains("stats-smoke") {
    exit(runStatsSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("buffer-smoke") {
    exit(runBufferSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("buffer-window-smoke") {
    exit(runBufferWindowSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("schema-smoke") {
    exit(runSchemaListStoreSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("marine-bridge-smoke") {
    exit(runMarineBridgeSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("marine-chrome-smoke") {
    exit(runMarineChromeSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("plugin-stream-smoke") {
    exit(runActionPluginStreamSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("plugin-smoke") {
    exit(runActionPluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("plugin-platform-smoke") {
    exit(runPluginPlatformSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("plugin-configuration-smoke") {
    exit(runPluginConfigurationSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("translation-smoke") {
    exit(runTranslationPluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("ai-text-smoke") {
    exit(runAITextPluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("stream-input-smoke") {
    exit(runStreamInputPluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("my-prompt-smoke") {
    exit(runMyPromptPluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("remarkable-plugin-smoke") {
    exit(runRemarkablePluginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("settings-routing-smoke") {
    exit(runSettingsRoutingSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("history-heatmap-smoke") {
    exit(runHistoryHeatmapSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("typing-speed-smoke") {
    exit(runTypingSpeedStoreSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("fly-chord-learning-smoke") {
    exit(runFlyChordLearningSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("input-telemetry-smoke") {
    exit(runInputTelemetrySmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("user-lexicon-smoke") {
    exit(runUserLexiconServiceSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("user-lexicon-bridge-smoke") {
    exit(runRimeUserLexiconBridgeSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("remote-smoke") {
    exit(runRemoteSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("matrix-smoke") {
    exit(runCandidateMatrixSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("origin-smoke") {
    exit(runOriginSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("inbound-smoke") {
    exit(runInboundBusSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("candidate-metrics-smoke") {
    exit(runCandidateMetricsSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("activation-cache-smoke") {
    exit(runRimeActivationMetadataCacheSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("theme-smoke") {
    exit(runThemeSmokeTest() ? 0 : 1)
}
if CommandLine.arguments.contains("smoke") {
    exit(runEngineSmokeTest() ? 0 : 1)
}

// Self-install into the input-source list. TIS enable/select only persist when
// run INSIDE the login (Aqua) session — a detached CLI's writes return success
// but never land. So the installer / build script launches THIS bundle in the
// user session (`open -n ETInput.app --args --install`) to register + enable +
// select itself, exactly like Squirrel's --install. Runs before the IMK server
// so this short-lived instance never contends for the connection.
if CommandLine.arguments.contains("--install") {
    exit(installInputSource() ? 0 : 1)
}
if CommandLine.arguments.contains("--prepare-update") {
    exit(selectFallbackInputSourceForUpdate() ? 0 : 1)
}
// A standalone SettingsWindowController spins up its OWN RimeEngine. If that
// engine opened the live ~/Library/RimeBuffer userdb while the installed IME is
// running, the two librime instances would fight over the LevelDB lock and break
// the user's live typing. So the dev GUI tools redirect to an isolated userdb
// (unless the caller already pinned RIMEBUFFER_USER_DIR).
func isolatePreviewUserDir() {
    guard let dir = isolateStandaloneRimeUserDir() else { return }
    let environment = ProcessInfo.processInfo.environment
    if environment["RIMEBUFFER_LOCAL_DATA_ROOT"] == nil {
        setenv("RIMEBUFFER_LOCAL_DATA_ROOT", dir, 1)
    }
    if environment["RIMEBUFFER_PLUGIN_ROOT"] == nil {
        setenv("RIMEBUFFER_PLUGIN_ROOT", dir + "/plugins", 1)
    }
}

// Dev-only: show the Settings window standalone (no IMK) so it can be reviewed
// or screenshotted without a live input session. Not wired into the shipped
// menus; invoked manually as `ETInput settings-preview`.
if CommandLine.arguments.contains("settings-preview") {
    isolatePreviewUserDir()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    SettingsWindowController.shared.show()
    app.activate(ignoringOtherApps: true)
    app.run()
}
// Dev-only: render every stable route/subpage plus manifest.json.
if let i = CommandLine.arguments.firstIndex(of: "settings-render"),
   i + 1 < CommandLine.arguments.count {
    isolatePreviewUserDir()
    let dir = CommandLine.arguments[i + 1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let rendered = SettingsWindowController.shared.renderAllForPreview(to: dir)
    print(rendered
        ? "rendered settings routes to \(dir)"
        : "failed to render one or more settings routes")
    exit(rendered ? 0 : 1)
}
// Dev-only: `ETInput panel-render <path> [translation|marine]
// [hover=<control>]` renders the actual compact workbench.
if let i = CommandLine.arguments.firstIndex(of: "panel-render"),
   i + 1 < CommandLine.arguments.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let model = BufferModel.shared
    model.onChange = nil
    model.discardForPrivacy()
    model.stageExternal("这次", origin: .rime)
    model.append("做了", origin: .mcp(client: "preview"))
    model.append("缓冲工作台", origin: .remotePeer(deviceID: "preview"))
    let options = Array(CommandLine.arguments.dropFirst(i + 2))
    let translation = options.contains("translation")
    let marine = options.contains("marine")
    if marine { model.discardForPrivacy() }
    let scaleValue = options.first { Double($0) != nil }.flatMap { Double($0) }
    let scale = CGFloat(scaleValue ?? 2)
    let hoveredControl = options.compactMap { option -> BufferWorkbenchControl? in
        guard option.hasPrefix("hover=") else { return nil }
        return BufferWorkbenchControl(rawValue: String(option.dropFirst("hover=".count)))
    }.first
    let translationSnapshot: TranslationRailSnapshot?
    if marine {
        translationSnapshot = TranslationRailSnapshot(
            sourceText: "",
            showsSourceRail: false,
            outputBlocks: [],
            phase: .idle,
            targetRole: "答",
            targetEmptyText: "等待网页上下文"
        )
    } else if translation {
        translationSnapshot = TranslationRailSnapshot(
            sourceText: "今天终于把翻译缓冲区分成上下两个区域了。",
            outputBlocks: [
                TranslationOutputBlock(id: UUID(),
                                       text: "Today the translation buffer is finally split"),
                TranslationOutputBlock(id: UUID(),
                                       text: "into two vertically stacked areas."),
            ],
            phase: .ready
        )
    } else {
        translationSnapshot = nil
    }
    let previewStatuses: [WorkbenchStatusIndicator]? = marine
        ? MarineChromeStatusSnapshot(
            paired: true,
            contextOnline: false,
            platform: nil,
            sourceKind: nil,
            aiAvailability: .ready
        ).indicators
        : nil
    let rendered = BufferWindowController.shared.renderForPreview(
        to: CommandLine.arguments[i + 1],
        scale: scale,
        translationSnapshot: translationSnapshot,
        statusIndicators: previewStatuses,
        hoveredControl: hoveredControl
    )
    print(rendered
        ? "rendered \(marine ? "marine " : (translation ? "translation " : ""))expanded workbench @\(scale)x"
        : "failed to render workbench")
    exit(rendered ? 0 : 1)
}
// Dev-only: `ETInput gateway-serve` runs the local gateway + a runloop and prints
// each inbound event, so the productized HTTP/MCP path can be exercised by curl
// and the real `claude` client without the full IMK bootstrap.
if CommandLine.arguments.contains("gateway-serve") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    InboundBus.shared.onChange = {
        let p = InboundBus.shared.pending
        print("[inbound] pending=\(p.count) latest=\(p.last.map { "\($0.origin.tag):\($0.text.count)chars streaming=\($0.streaming)" } ?? "-")")
        fflush(stdout)
    }
    installMarineChromePairingApprovalHandler()
    LocalGateway.shared.start()
    print("gateway-serve on 127.0.0.1:\(LocalGateway.shared.port) token=\(GatewayToken.current())")
    fflush(stdout)
    app.run()
}

// IMK bootstrap. The connection name MUST match Info.plist; IMK finds our
// controller via InputMethodServerControllerClass = RimeBufferController.
// Start enabled built-in observers before the first controller can receive a
// key. The registry is discovery/enablement only; external Action Plugin
// execution and revocation remain owned by ActionPluginHost/Manager.
let pluginRegistry = PluginRegistry.shared
BufferPluginSelectionStore.shared.migrateDefaultIfNeeded(
    from: pluginRegistry.plugins(capability: .bufferAction)
)
let bufferPluginSelectionObserver = NotificationCenter.default.addObserver(
    forName: .activeBufferPluginDidChange,
    object: BufferPluginSelectionStore.shared,
    queue: .main
) { notification in
    BufferModel.shared.clearAllContentSelection()
    if notification.userInfo?["current"] as? PluginKey
        == StreamInputWorkspace.pluginKey {
        if BufferModel.shared.enabled,
           let target = InputFocusCoordinator.shared.liveTarget(
            forceOverlayVisibilityRefresh: true
           ) {
            // A pre-existing Rime composition belongs to the old workspace.
            // Settle it before the first stream key can be captured; the two
            // source models must never coexist as one invisible composition.
            target.controller?.resolveCompositionForWorkbenchTransition(
                target: target
            )
        }
    }
    ActionPluginHost.shared.bufferPluginSelectionDidChange()
    BufferWindowController.shared.refresh()
}
IMELog.reset("=== \(ProductIdentity.displayName) IME launch ===")
let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String)
    ?? "RimeBuffer_1_Connection"

NSApplication.shared.setActivationPolicy(.accessory)   // background app; panels can float above others

// Held for the process lifetime so the IMK connection stays up.
let imkServer = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
if imkServer == nil {
    // No connection = a selectable-but-dead input source. Exit loudly; the
    // text-input system respawns us on demand once the cause is fixed.
    IMELog.write("FATAL: IMKServer(name: \(connectionName)) returned nil — exiting")
    exit(1)
}
// A Carbon hot key is process-global and remains independent from IMK's normal
// Command-key passthrough. Retain the controller for the entire server lifetime.
let globalHotKeyController = GlobalHotKeyController.shared
_ = globalHotKeyController.install()
// Warm the engine so the first keystroke isn't slow / so failures surface early.
_ = rimeEngine.start()

// Mouse-selection routes to whichever controller currently owns focus — the
// shared window must never bind to one specific controller.
candidateWindow.onSelect = { owner, selection in
    InputFocusCoordinator.shared.controller(for: owner)?
        .selectCandidate(selection, owner: owner)
}
candidateWindow.onSettings = {
    SettingsWindowController.shared.show()
}
// Buffer presentation is independent from the caret-owned candidate panel.
var lastBufferControlsActive = BufferModel.shared.active
BufferModel.shared.onChange = {
    BufferWindowController.shared.refresh()
    let active = BufferModel.shared.active
    let shouldRefreshHostGuard = HostMarkedTextPresentationRules
        .shouldRefreshForActiveChange(previous: lastBufferControlsActive,
                                      current: active)
    lastBufferControlsActive = active
    if shouldRefreshHostGuard {
        // Model mutations can occur inside a commit/drain callback. Defer the
        // host-guard refresh to avoid re-entering getContext/setMarkedText.
        DispatchQueue.main.async {
            RimeBufferController.refreshActiveUI()
        }
    }
}
InputFocusCoordinator.shared.onChange = {
    ActionPluginHost.shared.focusDidChange()
    StreamInputWorkspace.shared.focusDidChange()
    MarineChromeWorkspace.shared.focusDidChange()
    BufferWindowController.shared.refresh()
}
InputFocusCoordinator.shared.onInvalidated = { owner in
    BufferModel.shared.clearAllContentSelection()
    candidateWindow.hide(owner: owner)
    ActionPluginHost.shared.focusInvalidated(owner)
    StreamInputWorkspace.shared.focusInvalidated(owner)
    MarineChromeWorkspace.shared.focusDidChange()
}
ActionPluginHost.shared.onChange = {
    BufferWindowController.shared.refresh()
}
BufferWindowController.shared.showOnLaunchIfNeeded()

// Local gateway: accept MCP / HTTP pushes from local agents into the inbound
// bus (loopback-only, token-gated). Off is a one-line setting.
InboundBus.shared.onChange = {
    InboundTrayWindow.refreshIfOpen()
    InboundToast.shared.update(pendingCount: InboundBus.shared.pendingCount,
                               trayVisible: InboundTrayWindow.isVisible)
}
installMarineChromePairingApprovalHandler()
LocalGateway.shared.startIfEnabled()

// No standalone NSStatusItem: ETInput's commands are supplied by
// RimeBufferController.menu() under the system input-source icon.
StatusMenu.shared.setHealthy(rimeEngine.isHealthy)

// Auto-update: silently check GitHub Releases on launch + hourly, download in the
// background, and surface it through the input method's controls when ready.
UpdateManager.shared.startPeriodicUpdateCheck()

// Remote typing ("隔空传字"): text committed here mirrors to a paired Mac; text
// from the peer lands here — into the focused field if ETInput is active, else
// on the clipboard as a fallback. Both callbacks run on the main thread.
var remoteClipboardBuffer = ""   // accumulates received text while no field is focused
RemoteTypingService.shared.onReceiveText = { text in
    if RimeBufferController.insertRemoteText(text) {
        remoteClipboardBuffer = ""
        IMELog.write("remote: inserted received text into focused field")
    } else {
        // No safely deliverable field (focus changed, secure input, or active
        // composition) — accumulate without clobbering the prior message.
        remoteClipboardBuffer += text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remoteClipboardBuffer, forType: .string)
        IMELog.write("remote: direct insert unavailable; accumulated \(remoteClipboardBuffer.count) chars to clipboard")
    }
}
// A peer asks to pair — show 同意/拒绝 with the 4-digit SAS. One tap, no code entry.
RemoteTypingService.shared.onPairRequest = { peerName, sas, respond in
    let alert = NSAlert()
    alert.messageText = "「\(peerName)」请求隔空传字"
    alert.informativeText = "同意后，对方打的字会即时出现在你这里，你打的字也会发给对方。\n验证码：\(sas)（两台显示一致即代表安全，无中间人）"
    alert.addButton(withTitle: "同意")
    alert.addButton(withTitle: "拒绝")
    NSApp.activate(ignoringOtherApps: true)
    respond(alert.runModal() == .alertFirstButtonReturn)
}
// We initiated pairing and reached the peer — confirm the SAS matches, then request.
RemoteTypingService.shared.onPairConfirm = { peerName, sas, proceed in
    let alert = NSAlert()
    alert.messageText = "与「\(peerName)」配对"
    alert.informativeText = "请核对两台 Mac 显示的验证码一致：\(sas)\n一致后点「配对」，再请对方点「同意」。"
    alert.addButton(withTitle: "配对")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    proceed(alert.runModal() == .alertFirstButtonReturn)
}
RemoteTypingService.shared.onStatusChange = {
    SettingsWindowController.shared.remoteStatusDidChange()
}
RemoteTypingService.shared.restart()   // starts only if enabled

private enum InputSourceChangeDiagnosticRules {
    static func elapsedMilliseconds(previousUptime: TimeInterval?,
                                    now: TimeInterval) -> Int? {
        guard let previousUptime,
              previousUptime.isFinite,
              now.isFinite,
              now >= previousUptime else { return nil }
        let milliseconds = (now - previousUptime) * 1_000
        guard milliseconds <= Double(Int.max) else { return Int.max }
        return Int(milliseconds.rounded())
    }

    static func controlIsDown(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.contains(.control)
    }
}

// macOS 26 can omit deactivateServer when another process switches input
// sources through TISSelectInputSource. The distributed TIS notification still
// arrives, so finish the live controller before its client becomes stranded.
var lastObservedInputSourceID: String? = {
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        else { return nil }
    return tisStringProperty(current, kTISPropertyInputSourceID)
}()
var lastObservedInputSourceUptime: TimeInterval? =
    ProcessInfo.processInfo.systemUptime
let inputSourceChangedObserver = DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
    object: nil,
    queue: .main
) { _ in
    let now = ProcessInfo.processInfo.systemUptime
    let modifierFlags = NSEvent.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
    let elapsed = InputSourceChangeDiagnosticRules.elapsedMilliseconds(
        previousUptime: lastObservedInputSourceUptime,
        now: now
    ).map(String.init) ?? "unknown"
    let previousID = lastObservedInputSourceID ?? "unknown"
    let controlDown = InputSourceChangeDiagnosticRules.controlIsDown(
        modifierFlags
    )
    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let currentID = tisStringProperty(current, kTISPropertyInputSourceID) else {
        IMELog.write("TIS source changed: previous=\(previousID) current=unavailable deltaMs=\(elapsed) controlDown=\(controlDown) modifiers=\(modifierFlags.rawValue)")
        lastObservedInputSourceID = nil
        lastObservedInputSourceUptime = now
        return
    }
    let frontmostID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    IMELog.write("TIS source changed: previous=\(previousID) current=\(currentID) deltaMs=\(elapsed) controlDown=\(controlDown) modifiers=\(modifierFlags.rawValue) frontmost=\(frontmostID)")
    lastObservedInputSourceID = currentID
    lastObservedInputSourceUptime = now
    let ownID = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
    guard currentID != ownID, !currentID.hasPrefix(ownID + ".") else { return }
    IMELog.write("input source changed away -> \(currentID); finalizing active controller")
    if let lease = InputFocusCoordinator.shared.invalidateAll(reason: "input source changed") {
        lease.controller?.finalizeDisplacedFocus(lease)
        candidateWindow.hide(owner: lease.token)
    } else {
        candidateWindow.hideAll()
    }
}

let privacyOwnBundleID = Bundle.main.bundleIdentifier ?? "com.isaac.inputmethod.RimeBuffer"
let privacyOwnProcessIdentifier = ProcessInfo.processInfo.processIdentifier
let initialFrontmostApplication = NSWorkspace.shared.frontmostApplication
var lastExternalForegroundIdentity = BufferPrivacyTransitionRules.externalIdentity(
    bundleID: initialFrontmostApplication?.bundleIdentifier,
    processIdentifier: initialFrontmostApplication?.processIdentifier ?? 0,
    ownBundleID: privacyOwnBundleID,
    ownProcessIdentifier: privacyOwnProcessIdentifier
)

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil, queue: .main) { note in
    let activatedApplication = note.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
    if let lease = InputFocusCoordinator.shared.invalidateIfFrontmostChanged(
        to: activatedApplication
    ) {
        lease.controller?.finalizeDisplacedFocus(lease)
        candidateWindow.hide(owner: lease.token)
    } else if InputFocusCoordinator.shared.owner == nil {
        candidateWindow.hideAll()
    }

    // Reset only on a real external A -> B transition. Activating our editor or
    // settings leaves the last external identity unchanged, so A -> ETInput -> A
    // cannot self-wipe. Mixed/external content is kept as a whole because it was
    // staged specifically for delivery to another application.
    let activatedExternal = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: activatedApplication?.bundleIdentifier,
        processIdentifier: activatedApplication?.processIdentifier ?? 0,
        ownBundleID: privacyOwnBundleID,
        ownProcessIdentifier: privacyOwnProcessIdentifier
    )
    if BufferPrivacyTransitionRules.shouldDiscard(
        previousExternal: lastExternalForegroundIdentity,
        activatedExternal: activatedExternal,
        resetOnSwitch: BufferModel.shared.resetOnAppSwitch,
        holdsExternalContent: BufferModel.shared.holdsExternalContent
    ) {
        BufferWindowController.shared.discardForPrivacyTransition()
    }
    lastExternalForegroundIdentity = BufferPrivacyTransitionRules.updatedPrevious(
        lastExternalForegroundIdentity,
        activatedExternal: activatedExternal
    )
}
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: NSApp,
    queue: .main
) { _ in
    InputMetricsPersistence.saveNow()
}

IMELog.write("bootstrap done: server=\(imkServer != nil) engineHealthy=\(rimeEngine.isHealthy)")

NSApplication.shared.run()

// MARK: - Input-source lifecycle

private func tisStringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func tisBoolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    return Unmanaged<NSNumber>.fromOpaque(pointer).takeUnretainedValue().boolValue
}

/// Move the login session off ETInput before replacing its bundle or killing
/// its process. Long-lived clients (notably WeChat/Electron) otherwise retain a
/// dead IMK document connection and can immediately undo later source changes.
/// The legacy ETInput identity is included so an upgrade from older builds is
/// also handed off cleanly.
func selectFallbackInputSourceForUpdate() -> Bool {
    let ownBundleIDs = Set([
        Bundle.main.bundleIdentifier ?? "",
        "com.isaac.inputmethod.RimeBuffer",
        "com.isaac.inputmethod.ETInput",
    ].filter { !$0.isEmpty })

    func belongsToETInput(_ source: TISInputSource) -> Bool {
        if let bundleID = tisStringProperty(source, kTISPropertyBundleID),
           ownBundleIDs.contains(bundleID) {
            return true
        }
        guard let sourceID = tisStringProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        return ownBundleIDs.contains { sourceID == $0 || sourceID.hasPrefix($0 + ".") }
    }

    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        print("prepare-update: no current keyboard input source")
        return false
    }
    let currentID = tisStringProperty(current, kTISPropertyInputSourceID) ?? "(unknown)"
    guard belongsToETInput(current) else {
        print("prepare-update: current source is already safe: \(currentID)")
        return true
    }

    var candidates: [TISInputSource] = []
    if let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
        candidates.append(layout)
    }
    if let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
        candidates.append(ascii)
    }
    if let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] {
        candidates.append(contentsOf: all.filter {
            tisBoolProperty($0, kTISPropertyInputSourceIsASCIICapable)
        })
    }

    for fallback in candidates {
        guard !belongsToETInput(fallback),
              tisBoolProperty(fallback, kTISPropertyInputSourceIsEnabled),
              tisBoolProperty(fallback, kTISPropertyInputSourceIsSelectCapable) else {
            continue
        }
        let fallbackID = tisStringProperty(fallback, kTISPropertyInputSourceID) ?? "(unknown)"
        let status = TISSelectInputSource(fallback)
        print("prepare-update: select fallback=\(status) \(fallbackID)")
        guard status == noErr else { continue }

        for _ in 0..<20 {
            if let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
               !belongsToETInput(selected) {
                let selectedID = tisStringProperty(selected, kTISPropertyInputSourceID) ?? fallbackID
                print("prepare-update: fallback verified: \(selectedID)")
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    print("prepare-update: could not select a non-\(ProductIdentity.displayName) ASCII fallback")
    return false
}

/// Registers this bundle's path with TIS, then enables + selects our input mode.
/// Must run inside the login session (see call site). Mirrors Squirrel's
/// RegisterInputSource + ActivateInputSource.
func installInputSource() -> Bool {
    guard let component = Bundle.main.infoDictionary?["ComponentInputModeDict"] as? [String: Any],
          let visibleModes = component["tsVisibleInputModeOrderedArrayKey"] as? [String],
          let modeID = visibleModes.first,
          let bundleID = Bundle.main.bundleIdentifier else {
        print("install: missing bundle/input-mode metadata")
        return false
    }

    // Register THIS bundle's URL so the input-source id resolves to this exact
    // copy (kills the "duplicate id at multiple paths → blank row" problem).
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("install: register \(Bundle.main.bundleURL.path) -> \(status)")
    guard status == noErr else { return false }

    guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else {
        print("install: no input source list")
        return false
    }
    let list = cf as! [TISInputSource]
    func matchingSources(in sources: [TISInputSource])
        -> (parent: TISInputSource?, mode: TISInputSource?) {
        var parent: TISInputSource?
        var mode: TISInputSource?
        for source in sources {
            guard tisStringProperty(source, kTISPropertyBundleID) == bundleID else {
                continue
            }
            let id = tisStringProperty(source, kTISPropertyInputSourceID)
            if id == bundleID,
               !tisBoolProperty(source, kTISPropertyInputSourceIsSelectCapable) {
                parent = source
            }
            if id == modeID,
               tisBoolProperty(source, kTISPropertyInputSourceIsSelectCapable) {
                mode = source
            }
        }
        return (parent, mode)
    }

    // TIS exposes a non-selectable parent input method plus one or more
    // selectable modes. Both must be enabled, but only the child mode may be
    // passed to TISSelectInputSource. Discover both first because TIS does not
    // promise list order; enabling the child before its parent can fail.
    let discovered = matchingSources(in: list)
    let parentSource = discovered.parent
    let selectableMode = discovered.mode
    guard let parentSource, let selectableMode else {
        print("install: parent or selectable mode \(modeID) not found in TIS list")
        return false
    }

    let parentIsASCIICapable = tisBoolProperty(parentSource, kTISPropertyInputSourceIsASCIICapable)
    let parentType = tisStringProperty(parentSource, kTISPropertyInputSourceType) ?? "(unknown)"
    let parentCategory = tisStringProperty(parentSource, kTISPropertyInputSourceCategory) ?? "(unknown)"
    print("install: parent metadata id=\(bundleID) type=\(parentType) category=\(parentCategory) ascii=\(parentIsASCIICapable)")

    let isASCIICapable = tisBoolProperty(selectableMode, kTISPropertyInputSourceIsASCIICapable)
    let sourceType = tisStringProperty(selectableMode, kTISPropertyInputSourceType) ?? "(unknown)"
    let category = tisStringProperty(selectableMode, kTISPropertyInputSourceCategory) ?? "(unknown)"
    print("install: mode metadata id=\(modeID) type=\(sourceType) category=\(category) ascii=\(isASCIICapable)")
    guard !isASCIICapable else {
        print("install: refusing ASCII-capable Chinese mode; TIS is serving stale metadata")
        return false
    }

    // Reconcile both levels on every install, even when the cached IsEnabled
    // property already says true. On macOS 26 that property can reflect the
    // mode's default state while Control-Space's enabled-source roster is still
    // stale. TISEnableInputSource is idempotent and is the API that makes a
    // source available for UI/keyboard selection.
    let parentWasEnabled = tisBoolProperty(parentSource,
                                           kTISPropertyInputSourceIsEnabled)
    let parentEnableStatus = TISEnableInputSource(parentSource)
    print("install: enable parent=\(parentEnableStatus) reportedBefore=\(parentWasEnabled) \(bundleID)")
    guard parentEnableStatus == noErr else { return false }

    let modeWasEnabled = tisBoolProperty(selectableMode,
                                         kTISPropertyInputSourceIsEnabled)
    let modeEnableStatus = TISEnableInputSource(selectableMode)
    print("install: enable mode=\(modeEnableStatus) reportedBefore=\(modeWasEnabled) \(modeID)")
    guard modeEnableStatus == noErr else { return false }

    // Re-fetch from the enabled-only list. Re-reading the two discovery
    // objects above would merely validate the same stale cache that caused the
    // shortcut bug, and selecting that old child reference would not prove it
    // participates in the Control-Space roster.
    var enabledPair: (parent: TISInputSource, mode: TISInputSource)?
    for _ in 0..<20 {
        if let enabledCF = TISCreateInputSourceList(nil, false)?.takeRetainedValue() {
            let enabledList = enabledCF as! [TISInputSource]
            let refreshed = matchingSources(in: enabledList)
            if let parent = refreshed.parent,
               let mode = refreshed.mode,
               tisBoolProperty(parent, kTISPropertyInputSourceIsEnabled),
               !tisBoolProperty(parent, kTISPropertyInputSourceIsSelectCapable),
               tisBoolProperty(parent, kTISPropertyInputSourceIsASCIICapable),
               tisBoolProperty(mode, kTISPropertyInputSourceIsEnabled),
               tisBoolProperty(mode, kTISPropertyInputSourceIsSelectCapable),
               !tisBoolProperty(mode, kTISPropertyInputSourceIsASCIICapable) {
                enabledPair = (parent, mode)
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let enabledPair else {
        print("install: parent/mode missing from enabled-only TIS roster")
        return false
    }
    print("install: enabled roster verified parent=\(bundleID) mode=\(modeID)")

    // The historical WeChat crash is in Apple's input-source HUD before our
    // controller runs. Never trigger that path automatically while WeChat is
    // frontmost; registration/enabling still succeeds and ABC remains active.
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.tencent.xinWeChat" {
        print("install: WeChat is frontmost; skipping automatic selection")
        return true
    }

    let selectStatus = TISSelectInputSource(enabledPair.mode)
    print("install: select=\(selectStatus) \(modeID)")

    // On macOS 26 the first selection after changing input-mode metadata can
    // return paramErr even though TextInputMenuAgent applies it asynchronously.
    // Trust the observable TIS state, not only the immediate OSStatus.
    for _ in 0..<20 {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           tisStringProperty(current, kTISPropertyInputSourceID) == modeID {
            print("install: selected mode verified")
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    print("install: selection verification timed out")
    return false
}

// MARK: - Engine smoke harness (bring-up only)

func runEngineSmokeTest() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let isolatedUserDir = environment["RIMEBUFFER_USER_DIR"],
          !isolatedUserDir.isEmpty,
          !StandaloneRimeCommandRules.isLiveUserDir(isolatedUserDir),
          StandaloneRimeCommandRules.requiresIsolatedUserDir(
            arguments: ["ETInput", "smoke"]
          ),
          StandaloneRimeCommandRules.requiresIsolatedUserDir(
            arguments: ["ETInput", "user-lexicon-bridge-smoke"]
          ),
          StandaloneRimeCommandRules.requiresIsolatedUserDir(
            arguments: ["ETInput", "settings-preview"]
          ),
          !StandaloneRimeCommandRules.requiresIsolatedUserDir(
            arguments: ["ETInput", "--install"]
          ),
          StandaloneRimeCommandRules.isLiveUserDir(
            "/Users/smoke/Library/RimeBuffer/../RimeBuffer",
            homeDirectory: "/Users/smoke"
          ),
          StandaloneRimeCommandRules.isLiveUserDir(
            "/Users/smoke/Library/RimeBuffer/smoke-child",
            homeDirectory: "/Users/smoke"
          ),
          StandaloneRimeCommandRules.isLiveUserDir(
            "/users/smoke/library/rimebuffer",
            homeDirectory: "/Users/smoke"
          ),
          standaloneIsolationAliasProbe(
            isolatedUserDir: isolatedUserDir
          ),
          !StandaloneRimeCommandRules.isLiveUserDir(
            "/tmp/rimebuffer-smoke",
            homeDirectory: "/Users/smoke"
          ) else {
        print("FAILED: standalone Rime userdir isolation")
        return false
    }
    let engine = RimeEngine()
    print("== \(ProductIdentity.displayName) engine smoke test ==")
    let ok = engine.start()
    print("start:", ok, "healthy:", engine.isHealthy)
    guard ok, engine.isHealthy else {
        print("FAILED: engine start:", engine.lastError())
        return false
    }

    let session = engine.createSession()
    print("session:", session)
    guard session != 0 else {
        print("FAILED: no session")
        return false
    }
    defer { engine.destroySession(session) }

    let expectedSchemas = InputSchemaCatalog.defaultEnabledIDs
    let deployedSchemas = engine.schemaList()
    let deployedIDs = deployedSchemas.map(\.id)
    print("deployed schemas:", deployedSchemas.map { "\($0.id)=\($0.name)" }.joined(separator: ", "))
    guard deployedIDs == expectedSchemas else {
        print("FAILED: schema_list expected=\(expectedSchemas) actual=\(deployedIDs)")
        return false
    }

    let defaultStatus = engine.getStatus(session: session)
    print("default schema: \(defaultStatus.schemaId) (\(defaultStatus.schemaName))")

    // Use a sequential Chinese schema for deterministic CLI key replay. The
    // default my_combo schema expects physical chord press/release timing.
    guard engine.selectSchema("rime_ice", session: session),
          engine.getStatus(session: session).schemaId == "rime_ice" else {
        print("FAILED: cannot select rime_ice")
        return false
    }
    engine.setOption("ascii_mode", false, session: session)
    engine.clearComposition(session: session)
    print("typing 'nihao' on rime_ice ...")
    for scalar in "nihao".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: session)
    }
    let ctx = engine.getContext(session: session)
    print("active=\(ctx.active) preedit='\(ctx.preedit)' page=\(ctx.pageNo) cands=\(ctx.candidates.count)")
    for c in ctx.candidates {
        print("  [\(c.label)] \(c.text)\(c.comment.isEmpty ? "" : "  · \(c.comment)")")
    }
    guard ctx.candidates.contains(where: { $0.text == "你好" }) else {
        print("FAILED: rime_ice did not produce 你好")
        return false
    }
    _ = engine.processKey(0x20, session: session)
    let chineseCommit = engine.takeCommit(session: session) ?? ""
    print("committed:", chineseCommit)
    guard chineseCommit == "你好" else {
        print("FAILED: unexpected Chinese commit '\(chineseCommit)'")
        return false
    }

    // The frontend's deferred Shift contract must protect a live composition:
    // a used/held gesture emits no mode-switch pair, while a proven standalone
    // tap still reaches librime and preserves its configured commit_code
    // semantics. This exercises the bundled engine rather than only the pure
    // gesture reducer below.
    let shiftSession = engine.createSession()
    guard shiftSession != 0,
          engine.selectSchema("rime_ice", session: shiftSession) else {
        print("FAILED: cannot create isolated Shift smoke session")
        return false
    }
    engine.clearComposition(session: shiftSession)
    engine.setOption("ascii_mode", false, session: shiftSession)
    _ = engine.takeCommit(session: shiftSession)
    for scalar in "ni".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: shiftSession)
    }
    let protectedShiftBefore = engine.getContext(session: shiftSession)
    var protectedShift = ShiftModifierGesture(
        beganAt: 1,
        rimeKeycode: RimeKey.shiftL,
        session: shiftSession,
        schemaID: "rime_ice"
    )
    protectedShift.noteModifierUse()
    guard protectedShift.releaseDecision(
            at: 1.1,
            currentSession: shiftSession,
            currentSchemaID: "rime_ice"
          ) == .discard else {
        print("FAILED: modified Shift should not replay into librime")
        return false
    }
    let protectedShiftAfter = engine.getContext(session: shiftSession)
    guard protectedShiftAfter.active == protectedShiftBefore.active,
          protectedShiftAfter.input == protectedShiftBefore.input,
          protectedShiftAfter.preedit == protectedShiftBefore.preedit,
          protectedShiftAfter.candidates.map(\.text)
            == protectedShiftBefore.candidates.map(\.text),
          engine.takeCommit(session: shiftSession) == nil,
          !engine.getStatus(session: shiftSession).asciiMode else {
        print("FAILED: modified Shift changed live composition")
        return false
    }

    let standaloneShift = ShiftModifierGesture(
        beganAt: 2,
        rimeKeycode: RimeKey.shiftL,
        session: shiftSession,
        schemaID: "rime_ice"
    )
    guard case let .replayStandaloneTap(rimeKeycode) = standaloneShift.releaseDecision(
        at: 2.1,
        currentSession: shiftSession,
        currentSchemaID: "rime_ice"
    ) else {
        print("FAILED: standalone Shift replay decision")
        return false
    }
    _ = engine.processKey(rimeKeycode,
                          mask: RimeKey.shiftMask,
                          session: shiftSession)
    _ = engine.processKey(rimeKeycode,
                          mask: RimeKey.releaseMask,
                          session: shiftSession)
    let standaloneShiftCommit = engine.takeCommit(session: shiftSession)
    guard standaloneShiftCommit == protectedShiftBefore.input,
          engine.getContext(session: shiftSession).input.isEmpty,
          engine.getStatus(session: shiftSession).asciiMode else {
        print("FAILED: standalone Shift did not preserve commit_code semantics",
              standaloneShiftCommit ?? "<nil>")
        return false
    }
    engine.setOption("ascii_mode", false, session: shiftSession)
    engine.clearComposition(session: shiftSession)
    engine.destroySession(shiftSession)

    guard engine.selectSchema("english", session: session),
          engine.getStatus(session: session).schemaId == "english" else {
        print("FAILED: cannot select english")
        return false
    }
    engine.setOption("ascii_mode", false, session: session)

    engine.clearComposition(session: session)
    for scalar in "hel".unicodeScalars {
        _ = engine.processKey(Int32(scalar.value), session: session)
    }
    let completionContext = engine.getContext(session: session)
    let completionSamples = completionContext.candidates.prefix(8).map(\.text)
    print("english 'hel' candidates:", completionSamples)
    guard completionSamples.contains(where: { $0.lowercased().hasPrefix("hel") && $0.count > 3 }) else {
        print("FAILED: English prefix completion is unavailable")
        return false
    }

    func typeAndCommitEnglish(_ text: String) -> String {
        engine.clearComposition(session: session)
        for scalar in text.unicodeScalars {
            _ = engine.processKey(Int32(scalar.value), session: session)
        }
        _ = engine.processKey(0x20, session: session)
        return engine.takeCommit(session: session) ?? ""
    }

    let helloCommit = typeAndCommitEnglish("hello")
    let worldCommit = typeAndCommitEnglish("world")
    let rawCommit = typeAndCommitEnglish("codexzzq")
    print("english commits:", [helloCommit, worldCommit, rawCommit])
    guard helloCommit == "hello",
          worldCommit == " world",
          rawCommit.trimmingCharacters(in: .whitespaces) == "codexzzq" else {
        print("FAILED: English commit/spacing/raw fallback")
        return false
    }

    guard engine.selectSchema("my_combo", session: session) else {
        print("FAILED: cannot return to my_combo")
        return false
    }
    engine.clearComposition(session: session)
    engine.setOption("ascii_mode", true, session: session)
    let asciiLetterHandled = engine.processKey(0x61, session: session)
    let asciiLetterContext = engine.getContext(session: session)
    let asciiLetterCommit = engine.takeCommit(session: session)
    guard !FlyChordRoutingRules.shouldStage(schemaID: "my_combo", asciiMode: true),
          !asciiLetterHandled,
          asciiLetterContext.input.isEmpty,
          asciiLetterCommit == nil else {
        print("FAILED: my_combo ASCII mode must pass Latin keys through immediately",
              asciiLetterHandled, asciiLetterContext.input,
              asciiLetterCommit ?? "<nil>")
        return false
    }
    engine.setOption("ascii_mode", false, session: session)

    func typeFlyChordStrokes(
        _ strokes: [String],
        clearComposition: Bool = true,
        policy: FlyChordSettlementPolicy = .independentHalves
    )
        -> (context: RimeContextModel, allPressesHandled: Bool) {
        if clearComposition {
            engine.clearComposition(session: session)
        }
        var allPressesHandled = true
        var pairing = FlyChordMutualPairingState()
        for stroke in strokes {
            let keys = stroke.unicodeScalars.map {
                FlyChordKeyEvent(keycode: Int32($0.value), mask: 0)
            }
            let shapedKeys = keys.map { (keycode: $0.keycode, mask: $0.mask) }
            guard let shape = FlyChordBatchShape(keys: shapedKeys) else {
                return (engine.getContext(session: session), false)
            }
            let contextBefore = engine.getContext(session: session)
            var engineKeys = keys
            var boundaryPlan = FlyChordBoundaryRules.plan(for: contextBefore)
            if let previousLeft = pairing.takeComplement(
                before: shape,
                currentKeyCount: keys.count,
                policy: policy,
                currentContext: contextBefore
            ) {
                for _ in 0..<previousLeft.insertedScalarCount {
                    if !engine.processKey(RimeKey.backspace, session: session) {
                        allPressesHandled = false
                    }
                }
                guard engine.getContext(session: session).input == previousLeft.baseInput else {
                    return (engine.getContext(session: session), false)
                }
                engineKeys = previousLeft.keys + keys
                boundaryPlan = previousLeft.boundaryPlan
            }
            let insertsBoundary = FlyChordBoundaryRules.shouldInsert(
                forKeyCount: engineKeys.count
            )
            if insertsBoundary,
               boundaryPlan.before,
               !engine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                  session: session) {
                allPressesHandled = false
            }
            for key in engineKeys {
                if !engine.processKey(key.keycode, mask: key.mask, session: session) {
                    allPressesHandled = false
                }
            }
            for key in engineKeys {
                if !engine.processKey(key.keycode,
                                      mask: key.mask | RimeKey.releaseMask,
                                      session: session) {
                    allPressesHandled = false
                }
            }
            if insertsBoundary,
               boundaryPlan.after,
               !engine.processKey(FlyChordBoundaryRules.delimiterKeycode,
                                  session: session) {
                allPressesHandled = false
            }
            pairing.recordSettledLeft(
                keys: keys,
                baseInput: contextBefore.input,
                settledContext: engine.getContext(session: session),
                boundaryPlan: boundaryPlan,
                policy: policy,
                shape: shape
            )
        }
        return (engine.getContext(session: session), allPressesHandled)
    }

    func collectCandidatePages(maxPages: Int = 128)
        -> (contexts: [RimeContextModel], texts: [String], pagingWorked: Bool) {
        var contexts = [engine.getContext(session: session)]
        var texts = contexts[0].candidates.map(\.text)
        var pagingWorked = true
        while let current = contexts.last,
              !current.isLastPage,
              contexts.count < maxPages {
            guard engine.processKey(0x3d, session: session) else {
                pagingWorked = false
                break
            }
            let next = engine.getContext(session: session)
            guard next.pageNo > current.pageNo else {
                pagingWorked = false
                break
            }
            contexts.append(next)
            texts.append(contentsOf: next.candidates.map(\.text))
        }
        return (contexts, texts, pagingWorked)
    }

    // 并击 settles every current timer batch, including a useful one-sided
    // initial/final. It differs from 互击 only by refusing to recombine two
    // already-settled batches into one syllable.
    let sameBatchOneSided = typeFlyChordStrokes(["dv"], policy: .sameBatchOnly)
    let sameBatchCombined = typeFlyChordStrokes(["qkm"], policy: .sameBatchOnly)
    let sameBatchSplit = typeFlyChordStrokes(["q", "km"], policy: .sameBatchOnly)
    let mutualSplit = typeFlyChordStrokes(["q", "km"], policy: .independentHalves)
    guard sameBatchOneSided.allPressesHandled,
          !sameBatchOneSided.context.input.isEmpty,
          !sameBatchOneSided.context.candidates.isEmpty,
          sameBatchCombined.context.candidates.map(\.text).contains("穷"),
          sameBatchSplit.allPressesHandled,
          !sameBatchSplit.context.candidates.isEmpty,
          sameBatchSplit.context.input != sameBatchCombined.context.input,
          mutualSplit.context.input == sameBatchCombined.context.input,
          mutualSplit.context.candidates.map(\.text)
            == sameBatchCombined.context.candidates.map(\.text) else {
        print("FAILED: FlyYao same-batch/mutual settlement distinction",
              sameBatchOneSided.context.input,
              sameBatchOneSided.context.candidates.map(\.text),
              sameBatchCombined.context.input,
              sameBatchSplit.context.input,
              mutualSplit.context.input)
        return false
    }

    // A genuinely unmapped chord must keep its transformed raw code available
    // for Return-to-commit even when abbreviation candidates occupy every page.
    let unmappedChord = typeFlyChordStrokes(["qs"], policy: .sameBatchOnly)
    let unmappedRaw = unmappedChord.context.input
    let unmappedReturnHandled = engine.processKey(RimeKey.return, session: session)
    let unmappedCommit = engine.takeCommit(session: session)
    guard unmappedChord.allPressesHandled,
          !unmappedRaw.isEmpty,
          unmappedReturnHandled,
          unmappedCommit == unmappedRaw else {
        print("FAILED: FlyYao unmapped chord raw commit",
              unmappedRaw, unmappedReturnHandled,
              unmappedCommit ?? "<nil>")
        return false
    }

    // Comma and period remain chord keys in multi-key mappings, but a batch
    // containing only one of them must fall through to Rime's punctuator.
    let punctuationCases: [(key: String, chinese: String, ascii: String)] = [
        (",", "，", ","),
        (".", "。", "."),
    ]
    for policy in [FlyChordSettlementPolicy.sameBatchOnly, .independentHalves] {
        for punctuation in punctuationCases {
            for asciiPunct in [false, true] {
                engine.clearComposition(session: session)
                _ = engine.takeCommit(session: session)
                engine.setOption("ascii_punct", asciiPunct, session: session)
                let outcome = typeFlyChordStrokes(
                    [punctuation.key],
                    clearComposition: false,
                    policy: policy
                )
                let commit = engine.takeCommit(session: session)
                let expected = asciiPunct ? punctuation.ascii : punctuation.chinese
                guard outcome.allPressesHandled, commit == expected else {
                    print("FAILED: FlyYao punctuation settlement",
                          policy, punctuation.key, asciiPunct,
                          commit ?? "<nil>", outcome.context.input,
                          outcome.context.candidates.map(\.text))
                    return false
                }
            }
        }
    }
    engine.setOption("ascii_punct", false, session: session)

    let flyYaoCases: [(name: String, combined: [String], split: [String], expected: String)] = [
        ("compound initial", ["dvi"], ["dv", "i"], "你"),
        ("contextual ong/iong", ["qkm"], ["q", "km"], "穷"),
        ("compound final", ["efuo"], ["ef", "uo"], "双"),
        ("literal period", ["qm."], ["q", "m."], "却"),
        ("zero initial", ["xvo"], ["xv", "o"], "哦"),
        ("contextual zero initial", ["eui"], ["e", "ui"], "而"),
        ("closed alias lve", ["sdm."], ["sd", "m."], "略"),
        ("multi-syllable boundary", ["qkm", "dvi"], ["q", "km", "dv", "i"], "穷你"),
    ]
    let forbiddenAlternateSegmentation: [String: Set<String>] = [
        "zero initial": ["欧", "偶", "呕"],
        "closed alias lve": ["路", "露", "卤鹅"],
    ]
    for test in flyYaoCases {
        let combined = typeFlyChordStrokes(test.combined)
        let split = typeFlyChordStrokes(test.split)
        let combinedTexts = combined.context.candidates.map(\.text)
        let splitTexts = split.context.candidates.map(\.text)
        print("FlyYao \(test.name): combined=\(combined.context.preedit) split=\(split.context.preedit)")
        guard combined.allPressesHandled,
              split.allPressesHandled,
              combined.context.input == split.context.input,
              combined.context.preedit == split.context.preedit,
              combinedTexts == splitTexts,
              forbiddenAlternateSegmentation[test.name, default: []]
                .isDisjoint(with: splitTexts),
              combinedTexts.contains(test.expected),
              splitTexts.contains(test.expected) else {
            print("FAILED: FlyYao combined/split mismatch",
                  test.combined, test.split, test.expected,
                  combinedTexts, splitTexts)
            return false
        }
    }

    // Two keys pressed in one timing batch remain a real chord even when each
    // physical half contains only one key. The same keys pressed separately
    // are intentionally literal so ordinary Latin typing stays possible.
    let simultaneousSingletonChords: [(stroke: String, expected: String)] = [
        ("fo", "佛"),
        ("gy", "怪"),
    ]
    for test in simultaneousSingletonChords {
        let combined = typeFlyChordStrokes([test.stroke])
        guard combined.allPressesHandled,
              combined.context.candidates.map(\.text).contains(test.expected) else {
            print("FAILED: FlyYao simultaneous singleton chord",
                  test.stroke, test.expected,
                  combined.context.input,
                  combined.context.candidates.map(\.text))
            return false
        }
    }

    let explicitTwoSyllables = typeFlyChordStrokes(["fu", "xvo"])
    guard explicitTwoSyllables.allPressesHandled,
          explicitTwoSyllables.context.preedit == "fu'o",
          !explicitTwoSyllables.context.input.contains("J"),
          !explicitTwoSyllables.context.candidates.map(\.text).contains("佛") else {
        print("FAILED: FlyYao preserved-stroke boundary for fu'o",
              explicitTwoSyllables.context.preedit,
              explicitTwoSyllables.context.candidates.map(\.text))
        return false
    }

    // `ni'hao` must expose both the full phrase and partial single-character
    // choices, with a real next page that Rime can navigate to.
    let candidatePagingProbe = typeFlyChordStrokes(["dvi", "xck"])
    let candidatePages = collectCandidatePages()
    guard candidatePagingProbe.allPressesHandled,
          candidatePagingProbe.context.input == "ni'hao",
          candidatePagingProbe.context.candidates.map(\.text).contains("你好"),
          !candidatePages.texts.contains(candidatePagingProbe.context.input),
          !candidatePagingProbe.context.isLastPage,
          candidatePages.pagingWorked,
          candidatePages.contexts.count > 1,
          candidatePages.contexts[1].pageNo > candidatePages.contexts[0].pageNo,
          candidatePages.texts.contains("你") else {
        print("FAILED: FlyYao partial candidate paging",
              candidatePagingProbe.context.input,
              candidatePages.contexts.map(\.pageNo),
              candidatePages.texts.prefix(30))
        return false
    }

    // In both product modes, separately pressed physical singleton keys are
    // literal Latin input. They must never acquire automatic syllable marks or
    // be recombined into a Chinese chord behind the user's back.
    for policy in [FlyChordSettlementPolicy.sameBatchOnly, .independentHalves] {
        let singletonEnglish = typeFlyChordStrokes(
            ["c", "o", "d", "e", "x"],
            policy: policy
        )
        guard singletonEnglish.allPressesHandled,
              singletonEnglish.context.input == "codex",
              singletonEnglish.context.preedit == "codex",
              !singletonEnglish.context.input.contains("'") else {
            print("FAILED: FlyYao singleton Latin passthrough",
                  policy,
                  singletonEnglish.context.input,
                  singletonEnglish.context.preedit,
                  singletonEnglish.context.candidates.map(\.text))
            return false
        }

        // rime_ice historically reserved lowercase v as a symbols prefix.
        // FlyYao must override that inherited route so a physical singleton v
        // can begin a normal English word in either product keying mode.
        let vPrefix = typeFlyChordStrokes(
            ["v", "a"],
            policy: policy
        )
        let vPrefixCandidateTexts = vPrefix.context.candidates.map(\.text)
        let inheritedVSymbols: Set<String> = ["ā", "á", "ǎ", "à"]
        guard vPrefix.allPressesHandled,
              vPrefix.context.input == "va",
              vPrefix.context.preedit == "va",
              vPrefixCandidateTexts.contains(where: {
                  ["van", "vain"].contains($0.lowercased())
              }),
              inheritedVSymbols.isDisjoint(with: vPrefixCandidateTexts) else {
            print("FAILED: FlyYao lowercase v entered inherited symbols mode",
                  policy,
                  vPrefix.context.input,
                  vPrefix.context.preedit,
                  vPrefixCandidateTexts)
            return false
        }

        let vEnglish = typeFlyChordStrokes(
            ["v", "i", "d", "e", "o"],
            policy: policy
        )
        let vCandidateTexts = vEnglish.context.candidates.map(\.text)
        let vReturnHandled = engine.processKey(RimeKey.return, session: session)
        let vRawCommit = engine.takeCommit(session: session)
        guard vEnglish.allPressesHandled,
              vEnglish.context.input == "video",
              vEnglish.context.preedit == "video",
              vCandidateTexts.contains(where: { $0.lowercased() == "video" }),
              vReturnHandled,
              vRawCommit == "video" else {
            print("FAILED: FlyYao lowercase v must stay literal",
                  policy,
                  vEnglish.context.input,
                  vEnglish.context.preedit,
                  vCandidateTexts,
                  vReturnHandled,
                  vRawCommit ?? "<nil>")
            return false
        }
    }

    let ambiguousSyllableBoundaries: [(combined: [String], expected: String)] = [
        (["dvi", "an"], "ni'an"),
        (["ah", "ah"], "ang'ang"),
    ]
    for test in ambiguousSyllableBoundaries {
        let combined = typeFlyChordStrokes(test.combined)
        guard combined.allPressesHandled,
              combined.context.input == test.expected,
              combined.context.preedit == test.expected else {
            print("FAILED: FlyYao explicit syllable boundary",
                  test.combined, test.expected,
                  combined.context.input, combined.context.preedit)
            return false
        }
    }

    _ = typeFlyChordStrokes(["an"])
    guard engine.processKey(RimeKey.home, session: session) else {
        print("FAILED: FlyYao cursor smoke cannot move Home")
        return false
    }
    let insertedAtStart = typeFlyChordStrokes(["dvi"], clearComposition: false)
    guard insertedAtStart.allPressesHandled,
          insertedAtStart.context.input == "ni'an",
          insertedAtStart.context.preedit == "ni'an" else {
        print("FAILED: FlyYao leading cursor syllable boundary",
              insertedAtStart.context.input, insertedAtStart.context.preedit)
        return false
    }

    _ = typeFlyChordStrokes(["an"])
    guard engine.processKey(RimeKey.home, session: session),
          engine.processKey(RimeKey.right, session: session) else {
        print("FAILED: FlyYao cursor smoke cannot move into raw input")
        return false
    }
    let insertedInMiddle = typeFlyChordStrokes(["dvi"], clearComposition: false)
    guard insertedInMiddle.allPressesHandled,
          insertedInMiddle.context.input == "a'ni'n",
          insertedInMiddle.context.preedit == "a'ni'n" else {
        print("FAILED: FlyYao two-sided cursor syllable boundary",
              insertedInMiddle.context.input, insertedInMiddle.context.preedit)
        return false
    }

    do {
        let schema = try FlyChordSchemaParser.loadDefault()
        let crossMappings = schema.mappings.filter { mapping in
            let halves = Set(mapping.chord.unicodeScalars.compactMap {
                FlyChordLayout.half(for: Int32($0.value))
            })
            return halves == Set([.left, .right])
        }
        guard crossMappings.count > 300 else {
            print("FAILED: FlyYao exhaustive mapping set is incomplete", crossMappings.count)
            return false
        }
        var pairableSplitCount = 0
        for mapping in crossMappings {
            let left = String(mapping.chord.filter { character in
                let scalar = String(character).unicodeScalars.first!
                return FlyChordLayout.half(for: Int32(scalar.value)) == .left
            })
            let right = String(mapping.chord.filter { character in
                let scalar = String(character).unicodeScalars.first!
                return FlyChordLayout.half(for: Int32(scalar.value)) == .right
            })
            let combined = typeFlyChordStrokes([mapping.chord])
            guard combined.allPressesHandled else {
                print("FAILED: FlyYao exhaustive combined chord",
                      mapping.chord, mapping.output)
                return false
            }

            // Two separately timed singleton halves are deliberately Latin.
            // Cross-batch equivalence applies only when at least one half is a
            // true multi-key half chord.
            guard left.count > 1 || right.count > 1 else { continue }
            pairableSplitCount += 1
            let split = typeFlyChordStrokes([left, right])
            let combinedTexts = combined.context.candidates.map(\.text)
            let splitTexts = split.context.candidates.map(\.text)
            guard split.allPressesHandled,
                  combined.context.input == split.context.input,
                  combined.context.preedit == split.context.preedit,
                  combinedTexts == splitTexts else {
                print("FAILED: FlyYao exhaustive combined/split mismatch",
                      mapping.chord, mapping.output,
                      combined.context.preedit, split.context.preedit,
                      combined.context.candidates.map(\.text),
                      split.context.candidates.map(\.text))
                return false
            }
        }
        guard pairableSplitCount > 250 else {
            print("FAILED: FlyYao pairable split coverage is incomplete",
                  pairableSplitCount)
            return false
        }
        print("FlyYao exhaustive combined mappings:", crossMappings.count,
              "pairable split mappings:", pairableSplitCount)
    } catch {
        print("FAILED: FlyYao exhaustive schema parse", error)
        return false
    }

    let splitBeforeBackspace = typeFlyChordStrokes(["q", "km"])
    let splitBackspaceHandled = engine.processKey(RimeKey.backspace, session: session)
    let splitAfterBackspace = engine.getContext(session: session)
    let combinedBeforeBackspace = typeFlyChordStrokes(["qkm"])
    let combinedBackspaceHandled = engine.processKey(RimeKey.backspace, session: session)
    let combinedAfterBackspace = engine.getContext(session: session)
    guard splitBeforeBackspace.context.input == combinedBeforeBackspace.context.input,
          splitBackspaceHandled == combinedBackspaceHandled,
          splitAfterBackspace.input == combinedAfterBackspace.input,
          splitAfterBackspace.preedit == combinedAfterBackspace.preedit,
          splitAfterBackspace.candidates.map(\.text)
            == combinedAfterBackspace.candidates.map(\.text) else {
        print("FAILED: FlyYao split/combo BackSpace semantics",
              splitAfterBackspace.input, combinedAfterBackspace.input)
        return false
    }

    // F4 owns schema switching. The configured members/order were asserted
    // above; this additionally proves the switcher key enters Rime's menu.
    engine.clearComposition(session: session)
    let f4Handled = engine.processKey(RimeKey.f1 + 3, session: session)
    let switcherContext = engine.getContext(session: session)
    print("F4 handled=\(f4Handled) candidates=\(switcherContext.candidates.map(\.text))")
    let switcherNames = Set(switcherContext.candidates.map(\.text))
    let expectedNames = Set(InputSchemaCatalog.options.map(\.name))
    guard f4Handled, expectedNames.isSubset(of: switcherNames) else {
        print("FAILED: F4 schema switcher is incomplete")
        return false
    }
    print("engine smoke: OK")
    return true
}

func runSchemaListStoreSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) schema-list store smoke test ==")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rimebuffer-schema-list-\(UUID().uuidString)")
    let config = root.appendingPathComponent("default.custom.yaml")
    defer { try? FileManager.default.removeItem(at: root) }

    let expectedProfiles: [(InputConfiguration, String, RuntimeInputProfile.LexiconFamily)] = [
        (.init(encoding: .naturalDoublePinyin, keyingMode: .sequential),
         "double_pinyin", .chinese),
        (.init(encoding: .fullPinyin, keyingMode: .sequential),
         "rime_ice", .chinese),
        (.init(encoding: .fullPinyin, keyingMode: .chord),
         "my_combo", .chinese),
        (.init(encoding: .fullPinyin, keyingMode: .mutual),
         "my_combo", .chinese),
        (.init(encoding: .english, keyingMode: .sequential),
         "english", .english),
    ]
    for (configuration, schemaID, lexicon) in expectedProfiles {
        guard let profile = InputConfigurationResolver.profile(for: configuration),
              profile.schemaID == schemaID,
              profile.lexiconFamily == lexicon else {
            print("FAILED: input configuration mapping", configuration, schemaID)
            return false
        }
    }
    let chordSelection = InputConfigurationResolver.selecting(
        .chord,
        from: .init(encoding: .english, keyingMode: .sequential)
    )
    let naturalSelection = InputConfigurationResolver.selecting(
        .naturalDoublePinyin,
        from: .init(encoding: .fullPinyin, keyingMode: .chord)
    )
    let mutualSelection = InputConfigurationResolver.selecting(
        .mutual,
        from: .init(encoding: .english, keyingMode: .sequential)
    )
    guard chordSelection == .init(encoding: .fullPinyin, keyingMode: .chord),
          naturalSelection == .init(encoding: .naturalDoublePinyin,
                                    keyingMode: .sequential),
          mutualSelection == .init(encoding: .fullPinyin, keyingMode: .mutual),
          InputConfigurationResolver.profile(schemaID: "my_combo")?.configuration
            == .init(encoding: .fullPinyin, keyingMode: .mutual) else {
        print("FAILED: input configuration reducer")
        return false
    }

    func chordKey(_ character: Character) -> FlyChordKeyEvent {
        FlyChordKeyEvent(
            keycode: Int32(String(character).unicodeScalars.first!.value),
            mask: 0
        )
    }
    let leftQ = chordKey("q")
    let rightY = chordKey("y")
    var sameBatchLeftOnly = FlyChordBatchState()
    let sameBatchLeftDecision = sameBatchLeftOnly.stage(leftQ, policy: .sameBatchOnly)
    sameBatchLeftOnly.noteHandled(leftQ)
    let sameBatchLeftReplay = sameBatchLeftOnly.settle()

    var sameBatchCross = FlyChordBatchState()
    let sameBatchFirstDecision = sameBatchCross.stage(leftQ, policy: .sameBatchOnly)
    let sameBatchSecondDecision = sameBatchCross.stage(rightY, policy: .sameBatchOnly)
    sameBatchCross.noteHandled(leftQ)
    sameBatchCross.noteHandled(rightY)
    let sameBatchCrossReplay = sameBatchCross.settle()

    var mutualLeft = FlyChordBatchState()
    let mutualLeftDecision = mutualLeft.stage(leftQ, policy: .independentHalves)
    mutualLeft.noteHandled(leftQ)
    let mutualLeftReplay = mutualLeft.settle()

    var mutualRight = FlyChordBatchState()
    let mutualRightDecision = mutualRight.stage(rightY, policy: .independentHalves)
    mutualRight.noteHandled(rightY)
    let mutualRightReplay = mutualRight.settle()
    var pairingBoundary = FlyChordMutualPairingState()
    var settledLeftContext = RimeContextModel()
    settledLeftContext.input = "q"
    settledLeftContext.preedit = "q"
    settledLeftContext.cursorPos = 1
    settledLeftContext.selStart = 1
    settledLeftContext.selEnd = 1
    let expectedComplement = FlyChordMutualPairingState.SettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledInput: "q",
        settledCursorPos: 1,
        settledSelStart: 1,
        settledSelEnd: 1,
        boundaryPlan: .init(before: false, after: false),
        insertedScalarCount: 1
    )
    pairingBoundary.recordSettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledContext: settledLeftContext,
        boundaryPlan: .init(before: false, after: false),
        policy: .independentHalves,
        shape: .leftOnly
    )
    let singletonComplement = pairingBoundary.takeComplement(
        before: .rightOnly,
        currentKeyCount: 1,
        policy: .independentHalves,
        currentContext: settledLeftContext
    )
    pairingBoundary.recordSettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledContext: settledLeftContext,
        boundaryPlan: .init(before: false, after: false),
        policy: .independentHalves,
        shape: .leftOnly
    )
    let multiKeyComplement = pairingBoundary.takeComplement(
        before: .rightOnly,
        currentKeyCount: 2,
        policy: .independentHalves,
        currentContext: settledLeftContext
    )
    pairingBoundary.recordSettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledContext: settledLeftContext,
        boundaryPlan: .init(before: false, after: false),
        policy: .independentHalves,
        shape: .leftOnly
    )
    pairingBoundary.reset() // models apostrophe/edit/candidate/focus boundary
    let complementAfterBoundary = pairingBoundary.takeComplement(
        before: .rightOnly,
        currentKeyCount: 2,
        policy: .independentHalves,
        currentContext: settledLeftContext
    )
    var pairingAfterCursorMove = FlyChordMutualPairingState()
    pairingAfterCursorMove.recordSettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledContext: settledLeftContext,
        boundaryPlan: .init(before: false, after: false),
        policy: .independentHalves,
        shape: .leftOnly
    )
    var movedCursorContext = settledLeftContext
    movedCursorContext.cursorPos = 0
    movedCursorContext.selStart = 0
    movedCursorContext.selEnd = 0
    let complementAfterCursorMove = pairingAfterCursorMove.takeComplement(
        before: .rightOnly,
        currentKeyCount: 2,
        policy: .independentHalves,
        currentContext: movedCursorContext
    )
    var sameBatchPairing = FlyChordMutualPairingState()
    sameBatchPairing.recordSettledLeft(
        keys: [leftQ],
        baseInput: "",
        settledContext: settledLeftContext,
        boundaryPlan: .init(before: false, after: false),
        policy: .sameBatchOnly,
        shape: .leftOnly
    )
    let sameBatchComplement = sameBatchPairing.takeComplement(
        before: .rightOnly,
        currentKeyCount: 2,
        policy: .sameBatchOnly,
        currentContext: settledLeftContext
    )

    guard FlyChordLayout.half(for: leftQ.keycode) == .left,
          FlyChordLayout.half(for: rightY.keycode) == .right,
          FlyChordLayout.half(for: RimeKey.space) == nil,
          sameBatchLeftDecision == .process([leftQ]),
          sameBatchLeftReplay == [leftQ],
          sameBatchFirstDecision == .process([leftQ]),
          sameBatchSecondDecision == .process([rightY]),
          sameBatchCrossReplay == [leftQ, rightY],
          mutualLeftDecision == .process([leftQ]),
          mutualLeftReplay == [leftQ],
          mutualRightDecision == .process([rightY]),
          mutualRightReplay == [rightY],
          singletonComplement == nil,
          multiKeyComplement == expectedComplement,
          sameBatchComplement == nil,
          complementAfterBoundary == nil,
          complementAfterCursorMove == nil,
          FlyChordRoutingRules.shouldStage(schemaID: "my_combo", asciiMode: false),
          !FlyChordRoutingRules.shouldStage(schemaID: "my_combo", asciiMode: true),
          !FlyChordRoutingRules.shouldStage(schemaID: "english", asciiMode: false),
          FlyChordBoundaryRules.plan(for: settledLeftContext)
            == .init(before: true, after: false),
          FlyChordBoundaryRules.plan(for: movedCursorContext)
            == .init(before: false, after: true),
          !FlyChordBoundaryRules.shouldInsert(forKeyCount: 1),
          FlyChordBoundaryRules.shouldInsert(forKeyCount: 2),
          FlyChordInputRollback.insertedScalarCount(before: "ni", after: "nshi") == 2,
          FlyChordInputRollback.insertedScalarCount(before: "ni", after: "ni") == 0,
          FlyChordInputRollback.insertedScalarCount(before: "ni", after: "n") == nil,
          FlyChordInputRollback.insertedScalarCount(before: "ni", after: "na") == nil else {
        print("FAILED: FlyYao same-batch/mutual batching policy")
        return false
    }

    let defaultsName = "RimeBuffer.InputConfigurationSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsName) else {
        print("FAILED: input configuration defaults suite")
        return false
    }
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let canonicalLegacyProfiles: [(String, InputConfiguration)] = [
        ("double_pinyin", .init(encoding: .naturalDoublePinyin,
                                keyingMode: .sequential)),
        ("rime_ice", .init(encoding: .fullPinyin, keyingMode: .sequential)),
        ("my_combo", .init(encoding: .fullPinyin, keyingMode: .mutual)),
        ("english", .init(encoding: .english, keyingMode: .sequential)),
    ]
    for (schemaID, configuration) in canonicalLegacyProfiles {
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(schemaID, forKey: "preferredSchema")
        let store = InputConfigurationStore(defaults: defaults)
        guard store.configuration == configuration,
              store.runtimeProfile.schemaID == schemaID else {
            print("FAILED: legacy preferredSchema migration", schemaID)
            return false
        }
    }

    // A v1 FlyYao selection was necessarily labelled chord. It migrates once
    // to mutual; an explicit same-batch chord choice made under v2 is retained.
    defaults.removePersistentDomain(forName: defaultsName)
    defaults.set(InputEncoding.fullPinyin.rawValue,
                 forKey: "input.configuration.encoding.v1")
    defaults.set(KeyingMode.chord.rawValue,
                 forKey: "input.configuration.keyingMode.v1")
    defaults.set("my_combo", forKey: "preferredSchema")
    let migratedFlyYaoStore = InputConfigurationStore(defaults: defaults)
    guard migratedFlyYaoStore.configuration
            == .init(encoding: .fullPinyin, keyingMode: .mutual) else {
        print("FAILED: legacy FlyYao chord-to-mutual migration")
        return false
    }

    defaults.removePersistentDomain(forName: defaultsName)
    defaults.set(InputEncoding.fullPinyin.rawValue,
                 forKey: "input.configuration.encoding.v1")
    defaults.set(KeyingMode.chord.rawValue,
                 forKey: "input.configuration.keyingMode.v1")
    defaults.set(99, forKey: "input.configuration.keyingMode.semantics.v2")
    defaults.set("my_combo", forKey: "preferredSchema")
    let explicitChordStore = InputConfigurationStore(defaults: defaults)
    guard explicitChordStore.configuration
            == .init(encoding: .fullPinyin, keyingMode: .chord),
          explicitChordStore.adoptRuntimeSchema("my_combo"),
          explicitChordStore.configuration
            == .init(encoding: .fullPinyin, keyingMode: .chord),
          defaults.integer(forKey: "input.configuration.keyingMode.semantics.v2") == 99,
          InputConfigurationStore(defaults: defaults).configuration
            == .init(encoding: .fullPinyin, keyingMode: .chord),
          explicitChordStore.adoptRuntimeSchema("rime_ice"),
          explicitChordStore.configuration
            == .init(encoding: .fullPinyin, keyingMode: .sequential),
          explicitChordStore.adoptRuntimeSchema("my_combo"),
          explicitChordStore.configuration
            == .init(encoding: .fullPinyin, keyingMode: .mutual) else {
        print("FAILED: explicit FlyYao chord selection was not preserved")
        return false
    }

    defaults.removePersistentDomain(forName: defaultsName)
    defaults.set("unknown", forKey: "preferredSchema")
    let fallbackStore = InputConfigurationStore(defaults: defaults)
    guard fallbackStore.configuration == .defaultValue,
          fallbackStore.select(keyingMode: .mutual),
          fallbackStore.configuration == .defaultValue else {
        print("FAILED: invalid configuration fallback")
        return false
    }

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let initial = """
        patch:
          schema_list:
            - schema: my_serial
            - schema: melt_eng
          menu:
            page_size: 9
          custom_flag: keep-me
        """
        try initial.write(to: config, atomically: true, encoding: .utf8)
        try SchemaListStore.writeEnabledIDs(["english", "my_combo", "rime_ice", "double_pinyin"],
                                            to: config)
        let ids = SchemaListStore.enabledIDs(at: config)
        let rewritten = try String(contentsOf: config, encoding: .utf8)
        guard ids == InputSchemaCatalog.defaultEnabledIDs,
              rewritten.contains("page_size: 9"),
              rewritten.contains("custom_flag: keep-me"),
              !rewritten.contains("my_serial"),
              !rewritten.contains("melt_eng") else {
            print("FAILED: schema-list rewrite", ids, rewritten)
            return false
        }

        do {
            try SchemaListStore.writeEnabledIDs([], to: config)
            print("FAILED: empty schema selection was accepted")
            return false
        } catch SchemaListStore.StoreError.emptySelection {
            // Expected.
        }
    } catch {
        print("FAILED: schema-list store error:", error)
        return false
    }

    print("schema-list store smoke: OK")
    return true
}

func runStatsSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) key-frequency smoke test ==")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("rimebuffer-key-frequency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let calendar = Calendar(identifier: .gregorian)
    let day1 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5))!
    let day2 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6))!

    let store1 = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day1 }
    store1.record(keyCode: 0)       // A
    store1.record(keyCode: 0)       // A
    store1.record(keyCode: 8)       // C
    store1.recordModifierPress(keyCode: 55, flags: [.command])
    store1.recordModifierPress(keyCode: 55, flags: [])   // release, ignored
    store1.saveNow()

    let reloaded = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day1 }
    let day1Snapshot = reloaded.snapshot(for: day1)
    guard day1Snapshot.counts["KeyA"] == 2,
          day1Snapshot.counts["KeyC"] == 1,
          day1Snapshot.counts["LeftCommand"] == 1,
          day1Snapshot.total == 4 else {
        print("FAILED: day1 snapshot", day1Snapshot)
        return false
    }

    let store2 = KeyFrequencyStore(storageRoot: root, autosaveDelay: 999) { day2 }
    store2.record(keyCode: 11)      // B
    store2.saveNow()
    guard store2.snapshot(for: day1).total == 4,
          store2.snapshot(for: day2).counts["KeyB"] == 1 else {
        print("FAILED: day bucket isolation")
        return false
    }

    store2.clear(day: day1)
    guard store2.snapshot(for: day1).total == 0,
          store2.snapshot(for: day2).total == 1 else {
        print("FAILED: clear day")
        return false
    }

    store2.clear(day: nil)
    guard store2.snapshot(for: day2).total == 0 else {
        print("FAILED: clear all")
        return false
    }

    print("stats smoke: OK")
    return true
}

/// Pins the matrix viewport math. The three-row cap is visual only: the window
/// must slide far enough to reach the last page, never past the ends, and must
/// always keep the selected row on screen — a wrong base here would render one
/// row while selecting a different page's candidate.
func runCandidateMatrixSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) candidate matrix smoke test ==")
    let maxRows = CandidateWindow.expandedMaxRows
    guard maxRows == 3 else {
        print("FAILED: expected a three-row viewport, got \(maxRows)")
        return false
    }

    // The third row is the boundary that used to retain a compact 24pt
    // document height. Pin all transitions and the three-row viewport cap.
    let rowHeight: CGFloat = 24
    let expectedViewportHeights: [CGFloat] = [24, 51, 78, 78]
    for (index, expectedHeight) in expectedViewportHeights.enumerated() {
        let rowCount = index + 1
        let height = CandidateWindow.matrixViewportHeight(rowHeight: rowHeight,
                                                          rowCount: rowCount)
        guard height == expectedHeight else {
            print("FAILED: \(rowCount)-row viewport expected \(expectedHeight)pt, got \(height)pt")
            return false
        }
    }

    // Walking ↓ through six pages: the window pins to the top until the
    // selection leaves it, then trails the selection one row at a time.
    let walkDown = [0, 0, 0, 1, 2, 3]
    var base = 0
    for selection in 0..<6 {
        base = CandidateWindow.windowBase(selection: selection, currentBase: base, pageCount: 6)
        guard base == walkDown[selection] else {
            print("FAILED: ↓ to row \(selection) expected base \(walkDown[selection]), got \(base)")
            return false
        }
    }
    // ...and walking back ↑ retraces it, so the first page stays reachable.
    let walkUp = [0, 1, 2, 3, 3, 3]
    for selection in (0..<6).reversed() {
        base = CandidateWindow.windowBase(selection: selection, currentBase: base, pageCount: 6)
        guard base == walkUp[selection] else {
            print("FAILED: ↑ to row \(selection) expected base \(walkUp[selection]), got \(base)")
            return false
        }
    }

    // Fewer pages than rows must never scroll.
    for pageCount in 1...maxRows {
        for selection in 0..<pageCount {
            let b = CandidateWindow.windowBase(selection: selection, currentBase: 0, pageCount: pageCount)
            guard b == 0 else {
                print("FAILED: \(pageCount) pages should not scroll, got base \(b)")
                return false
            }
        }
    }

    // Invariants over every reachable (pageCount, base, selection): the base is
    // in range and its window contains the selection — from any starting base,
    // so a click or a re-fetch can never strand the selection off screen.
    for pageCount in 1...12 {
        for startBase in 0..<pageCount {
            for selection in 0..<pageCount {
                let b = CandidateWindow.windowBase(selection: selection,
                                                   currentBase: startBase,
                                                   pageCount: pageCount)
                let maxBase = max(0, pageCount - maxRows)
                guard b >= 0, b <= maxBase else {
                    print("FAILED: base \(b) out of 0...\(maxBase) (pages=\(pageCount) sel=\(selection))")
                    return false
                }
                guard selection >= b, selection < b + maxRows else {
                    print("FAILED: row \(selection) outside window \(b)..<\(b + maxRows) (pages=\(pageCount))")
                    return false
                }
            }
        }
    }

    // The last page must be reachable: its window is the final one.
    for pageCount in 4...12 {
        let b = CandidateWindow.windowBase(selection: pageCount - 1, currentBase: 0, pageCount: pageCount)
        guard b == pageCount - maxRows else {
            print("FAILED: last page of \(pageCount) expected base \(pageCount - maxRows), got \(b)")
            return false
        }
    }

    // --- Column viewport ---------------------------------------------------
    // A page_size:9 row that fits (9*40 + 8 separators*8 = 424 <= 460): the
    // common case, where the viewport must never scroll.
    let roomy = Array(repeating: CGFloat(40), count: 9)
    guard CandidateWindow.fittedColumnCount(widths: roomy, separator: 8, available: 460, base: 0) == 9 else {
        print("FAILED: nine 40pt candidates should all fit in 460pt")
        return false
    }
    for selection in 0..<9 {
        let b = CandidateWindow.columnBase(selection: selection, currentBase: 0, widths: roomy,
                                           separator: 8, available: 460)
        guard b == 0 else {
            print("FAILED: a row that fits must not scroll, got base \(b) for column \(selection)")
            return false
        }
    }

    // Narrow row: only some columns fit, so the tail is reachable only if the
    // viewport scrolls — this is the case the fix exists for.
    let tight = Array(repeating: CGFloat(100), count: 9)
    let fits = CandidateWindow.fittedColumnCount(widths: tight, separator: 8, available: 320, base: 0)
    guard fits > 0, fits < 9 else {
        print("FAILED: expected a partially fitting row, got \(fits)/9")
        return false
    }
    // Every candidate must be reachable, and the window must contain it.
    var colBase = 0
    for selection in 0..<9 {
        colBase = CandidateWindow.columnBase(selection: selection, currentBase: colBase, widths: tight,
                                             separator: 8, available: 320)
        let count = CandidateWindow.fittedColumnCount(widths: tight, separator: 8,
                                                      available: 320, base: colBase)
        guard selection >= colBase, selection < colBase + count else {
            print("FAILED: column \(selection) unreachable — window \(colBase)..<\(colBase + count)")
            return false
        }
    }
    // ...and walking back left retraces to the first column.
    for selection in (0..<9).reversed() {
        colBase = CandidateWindow.columnBase(selection: selection, currentBase: colBase, widths: tight,
                                             separator: 8, available: 320)
        let count = CandidateWindow.fittedColumnCount(widths: tight, separator: 8,
                                                      available: 320, base: colBase)
        guard selection >= colBase, selection < colBase + count else {
            print("FAILED: column \(selection) unreachable going back — window \(colBase)..<\(colBase + count)")
            return false
        }
    }
    guard colBase == 0 else {
        print("FAILED: walking left should return to column 0, got base \(colBase)")
        return false
    }

    // A single candidate wider than the whole row still renders (and stays
    // selectable) rather than vanishing.
    guard CandidateWindow.fittedColumnCount(widths: [900, 50], separator: 8, available: 460, base: 0) == 1 else {
        print("FAILED: an over-wide candidate must still occupy one column")
        return false
    }

    // Every matrix row lays itself out independently. A long phrase in the
    // first row must neither widen cells nor reduce the visible count below it.
    let longRow = [CGFloat(250), 40, 40, 40, 40, 40]
    let shortRow = Array(repeating: CGFloat(40), count: 6)
    let longRange = CandidateWindow.fittedColumnRange(
        widths: longRow, separator: 8, available: 320, base: 0
    )
    let shortRange = CandidateWindow.fittedColumnRange(
        widths: shortRow, separator: 8, available: 320, base: 0
    )
    guard longRange == 0..<2, shortRange == 0..<6 else {
        print("FAILED: matrix rows did not fit independently", longRange, shortRange)
        return false
    }
    let scrolledShortRange = CandidateWindow.fittedColumnRange(
        widths: shortRow, separator: 8, available: 120, base: 3
    )
    guard scrolledShortRange == 3..<5 else {
        print("FAILED: per-row viewport base was not preserved", scrolledShortRange)
        return false
    }

    print("candidate matrix smoke OK")
    return true
}

/// Pins the echo guard — the workbench's rule that a peer's text is never
/// mirrored back. A wrong verdict here means two paired Macs bounce text
/// forever (or, the other way, that a legitimately-typed block silently fails
/// to reach the other Mac). Also checks the block-origin plumbing: appended
/// text carries its origin, and the send path can read it back.
/// Pins the inbound gating: trusted sources drop straight to the buffer, `ask`
/// sources wait as pending, blocked sources vanish, the pending cap holds, and
/// accept moves an item into the buffer carrying its origin. A wrong verdict
/// here would let unverified external text reach the buffer without review.
func runInboundBusSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) inbound bus smoke test ==")

    // DNS-rebinding defence: command-line clients omit Origin, while browser
    // origins must parse to an exact loopback host (prefix lookalikes are not local).
    let allowedOrigins: [String?] = [
        nil,
        "http://localhost",
        "https://localhost:47700",
        "http://127.0.0.1:47700",
        "http://[::1]:47700",
    ]
    guard allowedOrigins.allSatisfy({ LocalGateway.isAllowedOrigin($0) }) else {
        print("FAILED: a valid loopback Origin was rejected")
        return false
    }
    let rejectedOrigins = [
        "",
        "null",
        "file://localhost",
        "http://localhost.evil.example",
        "http://127.0.0.1.evil.example",
        "http://localhost@evil.example",
        "http://%6cocalhost",
        "http://localhost:99999",
        "http://localhost/",
        "https://example.com",
        "http://localhost?redirect=evil",
        "http://localhost/#fragment",
    ]
    guard rejectedOrigins.allSatisfy({ !LocalGateway.isAllowedOrigin($0) }) else {
        print("FAILED: a non-loopback or malformed Origin was accepted")
        return false
    }

    let bus = InboundBus.shared
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    defer { model.discardForPrivacy(); bus.clear(); model.enabled = oldEnabled }
    model.enabled = true
    model.discardForPrivacy(); bus.clear()

    // Trust defaults: mcp/http/plugin = ask, marine = trusted.
    guard bus.trust(for: .mcp(client: "x")) == .ask,
          bus.trust(for: .http(source: "s")) == .ask,
          bus.trust(for: .plugin(id: "example")) == .ask,
          bus.trust(for: .marine) == .trusted else {
        print("FAILED: trust defaults wrong")
        return false
    }

    // ask source → pending, NOT in the buffer yet.
    let id = bus.submit(origin: .mcp(client: "codex"), text: "草稿一", title: "t")
    guard let id, bus.pendingCount == 1, model.blocks.isEmpty else {
        print("FAILED: ask source should wait in pending, not enter buffer")
        return false
    }
    // trusted source → straight to buffer, no pending.
    _ = bus.submit(origin: .marine, text: "marine 草稿")
    guard bus.pendingCount == 1, model.blocks.count == 1,
          model.blocks[0].origin == .marine else {
        print("FAILED: trusted source should drop into buffer")
        return false
    }
    // accept the pending mcp item → becomes a buffer block with mcp origin.
    bus.accept(id)
    guard bus.pendingCount == 0, model.blocks.count == 2,
          model.blocks.contains(where: { $0.origin == .mcp(client: "codex") }) else {
        print("FAILED: accept should move item into buffer with its origin")
        return false
    }
    // Externally-staged content must be marked so the switch-app reset spares it
    // (otherwise focusing the target field wipes what MCP/远端 just delivered).
    guard model.holdsExternalContent else {
        print("FAILED: buffer with external blocks must report holdsExternalContent")
        return false
    }
    // reject removes without touching the buffer.
    let rid = bus.submit(origin: .http(source: "s"), text: "拒绝我")
    bus.reject(rid!)
    guard bus.pendingCount == 0, model.blocks.count == 2 else {
        print("FAILED: reject should drop the item, not deliver it")
        return false
    }

    // Streaming: text updates in place, one pending item, endStream settles it.
    model.discardForPrivacy(); bus.clear()
    _ = bus.beginStream(origin: .mcp(client: "a"), streamID: "s1")
    bus.appendStream(streamID: "s1", delta: "部分")
    bus.appendStream(streamID: "s1", delta: "文本")
    guard bus.pendingCount == 1, bus.pending[0].text == "部分文本", bus.pending[0].streaming else {
        print("FAILED: streaming should update one item in place")
        return false
    }
    bus.endStream(streamID: "s1")
    guard !bus.pending[0].streaming else {
        print("FAILED: endStream should settle the item")
        return false
    }

    // Pending cap holds.
    bus.clear()
    for i in 0..<(InboundBus.maxPending + 10) { _ = bus.submit(origin: .mcp(client: "a"), text: "x\(i)") }
    guard bus.pendingCount == InboundBus.maxPending else {
        print("FAILED: pending cap not enforced, got \(bus.pendingCount)")
        return false
    }

    // A purely locally-typed buffer must NOT count as external, so the switch-
    // app reset still clears normal typing.
    model.discardForPrivacy(); bus.clear()
    model.append("本地打字")   // origin defaults to .rime
    guard !model.holdsExternalContent else {
        print("FAILED: locally-typed buffer must not report holdsExternalContent")
        return false
    }

    print("inbound bus smoke OK")
    return true
}

private final class ActionPluginURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler,
                  let url = request.url else {
                throw ActionPluginHTTPError.invalidResponse
            }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: url,
                                           statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class ActionPluginTransportStub: ActionPluginTransport {
    var statusResult: Result<ActionPluginStatus, Error>
    var invokeResult: Result<ActionPluginInvokeResponse, Error>
    var prepareResult: Result<ActionPluginPrepareResponse, Error>?
    var holdInvoke = false
    var holdStatus = false
    private(set) var statusRequestCount = 0
    private(set) var prepareRequestCount = 0
    private(set) var invokeRequestCount = 0
    private(set) var statusBindings: [ActionPluginRuntimeBinding?] = []
    private(set) var invokeBindings: [ActionPluginRuntimeBinding] = []
    let defaultBinding: ActionPluginRuntimeBinding
    private var pendingInvokes: [(
        completion: (Result<ActionPluginInvokeResponse, Error>) -> Void,
        result: Result<ActionPluginInvokeResponse, Error>
    )] = []
    private var pendingStatus: (
        completion: (Result<ActionPluginStatusSnapshot, Error>) -> Void,
        result: Result<ActionPluginStatusSnapshot, Error>
    )?

    init(status: ActionPluginStatus,
         response: ActionPluginInvokeResponse,
         binding: ActionPluginRuntimeBinding? = nil) {
        statusResult = .success(status)
        invokeResult = .success(response)
        defaultBinding = binding ?? ActionPluginRuntimeBinding(
            config: ActionPluginRuntimeConfig(pluginId: "example",
                                              apiBase: "http://127.0.0.1:47701/v1/plugin",
                                              token: "stub-token",
                                              updatedAt: 1,
                                              instanceId: "stub-instance",
                                              processId: 1)
        )
    }

    func fetchStatus(plugin: InstalledActionPlugin,
                     action: ActionPluginDefinition,
                     binding: ActionPluginRuntimeBinding?,
                     completion: @escaping (Result<ActionPluginStatusSnapshot, Error>) -> Void) {
        statusRequestCount += 1
        statusBindings.append(binding)
        let resolvedBinding = binding ?? defaultBinding
        let result = statusResult.map {
            ActionPluginStatusSnapshot(value: $0, binding: resolvedBinding)
        }
        if holdStatus {
            pendingStatus = (completion, result)
        } else {
            completion(result)
        }
    }

    func invoke(plugin: InstalledActionPlugin,
                action: ActionPluginDefinition,
                binding: ActionPluginRuntimeBinding,
                request payload: ActionPluginInvokeRequest,
                onStreamEvent: @escaping (ActionPluginStreamEvent) -> Void,
                completion: @escaping (Result<ActionPluginInvokeResponse, Error>) -> Void)
        -> ActionPluginInvocationCancellable? {
        invokeRequestCount += 1
        invokeBindings.append(binding)
        let result = invokeResult.map { template in
            ActionPluginInvokeResponse(requestId: payload.requestId,
                                       actionId: payload.actionId,
                                       contextId: payload.contextId,
                                       blocks: template.blocks,
                                       targetSummary: template.targetSummary)
        }
        if holdInvoke {
            pendingInvokes.append((completion, result))
        } else {
            completion(result)
        }
        return nil
    }

    func prepare(plugin: InstalledActionPlugin,
                 action: ActionPluginDefinition,
                 binding: ActionPluginRuntimeBinding,
                 request payload: ActionPluginInvokeRequest,
                 completion: @escaping (Result<ActionPluginPrepareResponse, Error>) -> Void)
        -> ActionPluginInvocationCancellable? {
        prepareRequestCount += 1
        guard let prepareResult else {
            completion(.failure(ActionPluginHTTPError.invalidResponse))
            return nil
        }
        completion(prepareResult.map { template in
            ActionPluginPrepareResponse(
                protocolVersion: template.protocolVersion,
                resultFormat: template.resultFormat,
                pluginId: payload.pluginId ?? template.pluginId,
                runtimeInstanceId: payload.runtimeInstanceId ?? template.runtimeInstanceId,
                requestId: payload.requestId,
                actionId: payload.actionId,
                contextId: payload.contextId,
                prompt: template.prompt,
                targetSummary: template.targetSummary
            )
        })
        return nil
    }

    func completeHeldInvoke() {
        guard !pendingInvokes.isEmpty else { return }
        let pending = pendingInvokes.removeFirst()
        pending.completion(pending.result)
    }

    func completeHeldStatus() {
        let pending = pendingStatus
        pendingStatus = nil
        guard let pending else { return }
        pending.completion(pending.result)
    }
}

private final class ActionPluginFocusBox {
    var token: FocusToken?
    var secureInput = false

    var access: ActionPluginFocusAccess {
        ActionPluginFocusAccess(
            currentToken: { [weak self] in self?.token },
            isValid: { [weak self] expected in self?.token == expected },
            secureInputEnabled: { [weak self] in self?.secureInput ?? true }
        )
    }
}

private final class PreparedActionConnectorStub: AITextProvider {
    let kind: AITextProviderKind = .codexCLI
    var availability: AITextProviderAvailability = .ready
    private(set) var requests: [AITextProviderRequest] = []
    var blocks = [AITextProviderBlock(index: 0,
                                      text: "连接器生成结果",
                                      title: "候选")]
    var holdsCompletion = false
    private var pending: (onEvent: (AITextProviderEvent) -> Void,
                          completion: (Result<[AITextProviderBlock], AITextProviderError>) -> Void)?

    func generate(_ request: AITextProviderRequest,
                  onEvent: @escaping (AITextProviderEvent) -> Void,
                  completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void)
        -> any AITextCancellable {
        requests.append(request)
        onEvent(.activity(AITextProviderActivity(
            kind: .reasoning,
            message: "正在分析页面话术"
        )))
        if holdsCompletion {
            pending = (onEvent, completion)
        } else {
            blocks.forEach { onEvent(.blockSnapshot($0)) }
            completion(.success(blocks))
        }
        return AITextNoopCancellation()
    }

    func complete() {
        guard let pending else { return }
        self.pending = nil
        blocks.forEach { pending.onEvent(.blockSnapshot($0)) }
        pending.completion(.success(blocks))
    }

    func emitHeld(_ block: AITextProviderBlock) {
        pending?.onEvent(.blockSnapshot(block))
    }
}

private final class ActionPluginLoaderBox {
    var plugins: [InstalledActionPlugin]

    init(_ plugins: [InstalledActionPlugin]) {
        self.plugins = plugins
    }

    func load(_: URL) -> [InstalledActionPlugin] { plugins }
}

private func runMainLoopUntil(timeout: TimeInterval = 1,
                              _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        _ = RunLoop.main.run(mode: .default,
                             before: min(deadline, Date().addingTimeInterval(0.01)))
    } while Date() < deadline
    return predicate()
}

private func runContextualActionPresentationSmokeTest() -> Bool {
    let presentationId = "contextual.generate-comment"
    let presentationKey = ActionPluginPresentationKey(
        pluginId: "contextual",
        presentationId: presentationId
    )
    let directAction = ActionPluginDefinition(
        id: "contextual.generate-direct",
        title: "生成直评",
        symbol: "bubble.left.and.text.bubble.right",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["direct"],
        presentationId: presentationId,
        presentationTitle: "生成评论"
    )
    let replyAction = ActionPluginDefinition(
        id: "contextual.generate-reply",
        title: "生成回复",
        symbol: "arrowshape.turn.up.left",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["reply"],
        presentationId: presentationId,
        presentationTitle: "生成评论"
    )
    let manifest = ActionPluginManifest(
        schemaVersion: 1,
        id: "contextual",
        name: "Contextual",
        version: "1",
        runtimeConfigPaths: ["runtime.json"],
        actions: [directAction, replyAction]
    )
    guard ActionPluginManifestLoader.validate(manifest) else {
        print("FAILED: contextual presentation manifest validation")
        return false
    }
    let overlappingAction = ActionPluginDefinition(
        id: "contextual.generate-overlap",
        title: "错误重叠动作",
        symbol: "exclamationmark.triangle",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["direct"],
        presentationId: presentationId,
        presentationTitle: "生成评论"
    )
    let overlappingManifest = ActionPluginManifest(
        schemaVersion: manifest.schemaVersion,
        id: manifest.id,
        name: manifest.name,
        version: manifest.version,
        runtimeConfigPaths: manifest.runtimeConfigPaths,
        actions: [directAction, overlappingAction]
    )
    guard !ActionPluginManifestLoader.validate(overlappingManifest) else {
        print("FAILED: contextual presentation accepted overlapping modes")
        return false
    }
    let plugin = InstalledActionPlugin(
        manifest: manifest,
        directory: URL(fileURLWithPath: "/tmp/contextual.etplugin", isDirectory: true)
    )
    let binding = ActionPluginRuntimeBinding(config: ActionPluginRuntimeConfig(
        pluginId: "contextual",
        apiBase: "http://127.0.0.1:47701/v1/plugin",
        token: "contextual-token",
        updatedAt: 1,
        instanceId: "contextual-instance",
        processId: 1
    ))
    func status(available: Bool,
                contextId: String?,
                mode: String?,
                actionId: String,
                label: String) -> ActionPluginStatus {
        ActionPluginStatus(available: available,
                           contextId: contextId,
                           mode: mode,
                           actionId: actionId,
                           label: label,
                           targetSummary: "目标评论",
                           updatedAt: Date().timeIntervalSince1970)
    }
    let unavailable = status(available: false,
                             contextId: nil,
                             mode: nil,
                             actionId: directAction.id,
                             label: "等待评论框")
    let response = ActionPluginInvokeResponse(
        requestId: "template",
        actionId: directAction.id,
        contextId: "ctx-direct",
        blocks: [ActionPluginResultBlock(text: "生成内容", title: nil)],
        targetSummary: "目标评论"
    )
    let preparation = ActionPluginPrepareResponse(
        protocolVersion: ActionPluginPrepareContract.protocolVersion,
        resultFormat: ActionPluginPrepareContract.resultFormat,
        pluginId: "contextual",
        runtimeInstanceId: "contextual-instance",
        requestId: "template",
        actionId: directAction.id,
        contextId: "ctx-direct",
        prompt: "CONTEXTUAL PREPARED PROMPT\nReturn blocks-v1.",
        targetSummary: "目标评论"
    )
    let transport = ActionPluginTransportStub(status: unavailable,
                                              response: response,
                                              binding: binding)
    transport.prepareResult = .success(preparation)
    let connector = PreparedActionConnectorStub()
    connector.blocks = [
        AITextProviderBlock(index: 0, text: "生成内容", title: nil),
    ]
    let focusBox = ActionPluginFocusBox()
    var epochs = FocusEpochState()
    focusBox.token = epochs.activate()
    let model = BufferModel()
    let host = ActionPluginHost(
        rootURL: URL(fileURLWithPath: "/tmp/contextual-plugin-root", isDirectory: true),
        client: transport,
        focus: focusBox.access,
        bufferModel: model,
        inboundBus: InboundBus(),
        pluginLoader: { _ in [plugin] },
        connectorProvider: { connector },
        runtimeBindingIsCurrent: { _, candidate in candidate == binding }
    )
    var changeCount = 0
    host.onChange = { changeCount += 1 }
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({ changeCount > 0 }),
          host.presentations.count == 1,
          host.presentations[0].title == "生成评论",
          host.presentations[0].presentationKey == presentationKey,
          host.presentations[0].key.actionId == directAction.id,
          host.presentations[0].canInvoke == false,
          host.presentations[0].isPreparedGeneration,
          host.presentations[0].preparedGenerationActionIDs
            == Set([directAction.id, replyAction.id]),
          host.primaryGenerationPresentation?.presentationKey == presentationKey,
          host.secondaryPresentations.isEmpty,
          host.generationStatusText == "等待评论框",
          host.primaryAction == .disabled else {
        print("FAILED: contextual action must remain one disabled control without a target")
        return false
    }

    transport.statusResult = .success(status(available: true,
                                             contextId: "ctx-direct",
                                             mode: "direct",
                                             actionId: directAction.id,
                                             label: "生成直评"))
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({
        host.presentations.count == 1
            && host.presentations[0].canInvoke
            && host.presentations[0].presentationKey == presentationKey
            && host.presentations[0].key.actionId == directAction.id
            && host.primaryGenerationPresentation?.key.actionId == directAction.id
            && host.primaryAction == .requestGeneration
    }) else {
        print("FAILED: contextual presentation did not select direct action")
        return false
    }

    transport.statusResult = .success(status(available: true,
                                             contextId: "ctx-reply",
                                             mode: "reply",
                                             actionId: replyAction.id,
                                             label: "生成回复"))
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({
        host.presentations.count == 1
            && host.presentations[0].title == "生成评论"
            && host.presentations[0].canInvoke
            && host.presentations[0].presentationKey == presentationKey
            && host.presentations[0].key.actionId == replyAction.id
            && host.primaryGenerationPresentation?.key.actionId == replyAction.id
            && host.generationStatusText == "生成回复"
            && host.primaryAction == .requestGeneration
    }) else {
        print("FAILED: contextual presentation did not switch its action id")
        return false
    }

    guard host.generate(), host.primaryAction == .generating else {
        print("FAILED: contextual prepared primary action did not start generation")
        return false
    }
    guard runMainLoopUntil({ model.blocks.count == 1 }),
          model.blocks[0].pluginMetadata?.actionId == replyAction.id,
          transport.prepareRequestCount == 1,
          transport.invokeRequestCount == 0,
          connector.requests.count == 1,
          host.primaryAction == .deliver else {
        print("FAILED: unified contextual control invoked the wrong action")
        return false
    }
    return true
}

private func runPreparedActionConnectorSmokeTest() -> Bool {
    let action = ActionPluginDefinition(
        id: "prepared.generate",
        title: "生成",
        symbol: "sparkles",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["direct"]
    )
    let manifest = ActionPluginManifest(
        schemaVersion: 1,
        id: "prepared",
        name: "Prepared",
        version: "1",
        runtimeConfigPaths: ["runtime.json"],
        actions: [action]
    )
    guard ActionPluginManifestLoader.validate(manifest) else {
        print("FAILED: prepared action manifest validation")
        return false
    }
    let groupedDirect = ActionPluginDefinition(
        id: "prepared.direct",
        title: "直评",
        symbol: "sparkles",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["direct"],
        presentationId: "prepared.generate",
        presentationTitle: "生成"
    )
    let groupedReply = ActionPluginDefinition(
        id: "prepared.reply",
        title: "回复",
        symbol: "sparkles",
        statusPath: "/status",
        preparePath: "/other-prepare",
        invokePath: "/invoke",
        modes: ["reply"],
        presentationId: "prepared.generate",
        presentationTitle: "生成"
    )
    let mismatchedPreparationManifest = ActionPluginManifest(
        schemaVersion: 1,
        id: "prepared-group",
        name: "Prepared Group",
        version: "1",
        runtimeConfigPaths: ["runtime.json"],
        actions: [groupedDirect, groupedReply]
    )
    guard !ActionPluginManifestLoader.validate(mismatchedPreparationManifest) else {
        print("FAILED: grouped actions accepted different prepare paths")
        return false
    }
    let binding = ActionPluginRuntimeBinding(config: ActionPluginRuntimeConfig(
        pluginId: "prepared",
        apiBase: "http://127.0.0.1:47701/v1/plugin",
        token: "prepared-token",
        updatedAt: 1,
        instanceId: "prepared-instance",
        processId: 1
    ))
    let status = ActionPluginStatus(
        available: true,
        contextId: "prepared-context",
        mode: "direct",
        actionId: action.id,
        label: "生成话术",
        targetSummary: "直评目标",
        updatedAt: Date().timeIntervalSince1970
    )
    let template = ActionPluginPrepareResponse(
        protocolVersion: ActionPluginPrepareContract.protocolVersion,
        resultFormat: ActionPluginPrepareContract.resultFormat,
        pluginId: "prepared",
        runtimeInstanceId: "prepared-instance",
        requestId: "template",
        actionId: action.id,
        contextId: "prepared-context",
        prompt: "MARINE PREPARED PROMPT\nReturn blocks-v1.",
        targetSummary: "直评目标"
    )
    let expectedIdentity = ActionPluginStreamIdentity(
        pluginId: "prepared",
        runtimeInstanceId: "prepared-instance",
        requestId: "template",
        actionId: action.id,
        contextId: "prepared-context"
    )
    guard ActionPluginPrepareContract.accepts(template,
                                              expectedIdentity: expectedIdentity),
          !ActionPluginPrepareContract.accepts(
            ActionPluginPrepareResponse(
                protocolVersion: template.protocolVersion,
                resultFormat: template.resultFormat,
                pluginId: template.pluginId,
                runtimeInstanceId: template.runtimeInstanceId,
                requestId: "wrong-request",
                actionId: template.actionId,
                contextId: template.contextId,
                prompt: template.prompt,
                targetSummary: template.targetSummary
            ),
            expectedIdentity: expectedIdentity
          ) else {
        print("FAILED: prepared action identity contract")
        return false
    }

    let dummyResponse = ActionPluginInvokeResponse(
        requestId: "unused",
        actionId: action.id,
        contextId: "prepared-context",
        blocks: [ActionPluginResultBlock(text: "legacy must not run", title: nil)],
        targetSummary: nil
    )
    let transport = ActionPluginTransportStub(status: status,
                                              response: dummyResponse,
                                              binding: binding)
    transport.prepareResult = .success(template)
    let connector = PreparedActionConnectorStub()
    connector.blocks = [
        AITextProviderBlock(index: 0, text: "连接器生成结果一", title: "候选一"),
        AITextProviderBlock(index: 1, text: "连接器生成结果二", title: "候选二"),
        AITextProviderBlock(index: 2, text: "连接器生成结果三", title: "候选三"),
    ]
    connector.holdsCompletion = true
    let focusBox = ActionPluginFocusBox()
    var epochs = FocusEpochState()
    focusBox.token = epochs.activate()
    let model = BufferModel()
    let plugin = InstalledActionPlugin(
        manifest: manifest,
        directory: URL(fileURLWithPath: "/tmp/prepared.etplugin", isDirectory: true)
    )
    let host = ActionPluginHost(
        rootURL: URL(fileURLWithPath: "/tmp/prepared-plugin-root", isDirectory: true),
        client: transport,
        focus: focusBox.access,
        bufferModel: model,
        inboundBus: InboundBus(),
        pluginLoader: { _ in [plugin] },
        connectorProvider: { connector },
        runtimeBindingIsCurrent: { _, candidate in candidate == binding }
    )
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({ host.presentations.first?.canInvoke == true }),
          let presentation = host.presentations.first,
          let key = host.presentations.first?.key else {
        print("FAILED: prepared action did not become invokable")
        return false
    }
    guard presentation.isPreparedGeneration,
          presentation.preparedGenerationActionIDs == Set([action.id]),
          host.primaryGenerationPresentation == presentation,
          host.secondaryPresentations.isEmpty,
          host.canGenerate,
          host.generationProviderName == "Prepared",
          host.generationStatusText == "生成话术",
          host.primaryAction == .requestGeneration,
          ActionPluginPrimaryPresentationRules.primary(in: [presentation]) == presentation,
          ActionPluginPrimaryPresentationRules.primary(
            in: [presentation, presentation]
          ) == nil,
          ActionPluginPrimaryPresentationRules.secondary(
            in: [presentation, presentation]
          ).count == 2 else {
        print("FAILED: prepared primary presentation promotion was ambiguous")
        return false
    }

    let legacyPresentation = ActionPluginPresentation(
        key: ActionPluginKey(pluginId: "prepared", actionId: "prepared.legacy"),
        presentationKey: ActionPluginPresentationKey(
            pluginId: "prepared",
            presentationId: "prepared.legacy"
        ),
        pluginName: "Prepared",
        title: "旧动作",
        symbol: "bolt",
        label: "运行旧动作",
        targetSummary: nil,
        available: true,
        canInvoke: true,
        requiresFocus: true,
        preparedGenerationActionIDs: [],
        running: false,
        waitingForFirstContent: false
    )
    guard ActionPluginPrimaryPresentationRules.primary(
            in: [presentation, legacyPresentation]
          ) == nil,
          ActionPluginPrimaryPresentationRules.secondary(
            in: [presentation, legacyPresentation]
          ) == [presentation, legacyPresentation] else {
        print("FAILED: mixed prepared/legacy actions did not retain the explicit shelf")
        return false
    }

    model.stageExternal("ordinary source", origin: .rime)
    guard host.primaryAction == .requestGeneration else {
        print("FAILED: ordinary source promoted the prepared action to delivery")
        return false
    }

    let unrelatedMetadata = BufferModel.PluginMetadata(
        pluginId: "prepared",
        actionId: "prepared.other",
        requestId: "unrelated-request",
        contextId: "prepared-context",
        focusToken: focusBox.token,
        runtimeIdentity: binding.identity
    )
    model.stageExternal("other action result",
                        origin: .plugin(id: "prepared"),
                        pluginMetadata: unrelatedMetadata)
    guard host.primaryAction == .requestGeneration else {
        print("FAILED: unrelated plugin action promoted the prepared action to delivery")
        return false
    }

    let stalePrimaryMetadata = BufferModel.PluginMetadata(
        pluginId: "prepared",
        actionId: action.id,
        requestId: "stale-primary-request",
        contextId: "prepared-context",
        focusToken: focusBox.token,
        runtimeIdentity: binding.identity,
        stale: true
    )
    model.stageExternal("stale primary result",
                        origin: .plugin(id: "prepared"),
                        pluginMetadata: stalePrimaryMetadata)
    guard host.primaryAction == .requestGeneration else {
        print("FAILED: stale prepared result was exposed as ready delivery")
        return false
    }

    guard host.generate(), host.primaryAction == .generating else {
        print("FAILED: prepared primary action did not enter generating state")
        return false
    }
    guard runMainLoopUntil({
        connector.requests.count == 1
            && model.loadingMessage?.contains("正在分析页面话术") == true
    }),
          model.blocks.count == 3,
          model.transientLoadingActive,
          host.presentations.first?.waitingForFirstContent == true else {
        print("FAILED: prepared connector activity was not visible before first content")
        return false
    }
    connector.complete()
    guard runMainLoopUntil({
        model.blocks.count == 6
            && model.blocks.contains {
                $0.text == "连接器生成结果一"
                    && $0.pluginMetadata?.incomplete == false
            }
    }),
          transport.prepareRequestCount == 1,
          transport.invokeRequestCount == 0,
          connector.requests.count == 1,
          connector.requests[0].preparedPrompt == template.prompt,
          connector.requests[0].sourceText.isEmpty,
          host.deliveryPendingBlocks.map(\.text) == [
            "连接器生成结果一",
            "连接器生成结果二",
            "连接器生成结果三",
          ],
          host.deliveryPendingBlocks[0].pluginMetadata?.pluginId == "prepared",
          host.deliveryPendingBlocks[0].pluginMetadata?.contextId == "prepared-context",
          !host.hasIncompleteDeliveryBlocks,
          host.primaryAction == .deliver,
          !host.generate() else {
        print("FAILED: prepared action did not stay on the connector/plugin authority path")
        return false
    }

    let invalidProvisionalBlocks = [
        AITextProviderBlock(index: ActionPluginStreamParser.maximumBlocks,
                            text: "越界索引",
                            title: nil),
        AITextProviderBlock(index: 0,
                            text: String(repeating: "x",
                                         count: AITextRuntimeLimits.maximumWireBytes + 1),
                            title: nil),
        AITextProviderBlock(index: 0,
                            text: "标题越界",
                            title: String(repeating: "题",
                                          count: ActionPluginStreamParser.maximumTitleBytes + 1)),
    ]
    for (offset, invalidBlock) in invalidProvisionalBlocks.enumerated() {
        connector.holdsCompletion = true
        host.invoke(key)
        guard runMainLoopUntil({
            connector.requests.count == offset + 2 && model.transientLoadingActive
        }) else {
            print("FAILED: invalid prepared connector case did not start")
            return false
        }
        connector.emitHeld(invalidBlock)
        guard runMainLoopUntil({ !model.transientLoadingActive }),
              model.blocks.count == 6,
              host.presentations.first?.waitingForFirstContent == false else {
            print("FAILED: invalid provisional connector block reached the workbench")
            return false
        }
    }

    guard let deliveryFocus = focusBox.token else {
        print("FAILED: prepared delivery focus disappeared")
        return false
    }
    var deliveredTexts: [String] = []
    var completedDeliveries: [BufferDeliveryCoordinator.SendResult] = []
    var pendingValidations: [(ActionPluginDeliveryDecision) -> Void] = []
    let preparedCoordinator = BufferDeliveryCoordinator(
        model: model,
        dependencies: .init(
            resolveTarget: { expected in
                guard expected == nil || expected == deliveryFocus else { return nil }
                return .init(
                    token: deliveryFocus,
                    compositionActive: false,
                    resolveComposition: {},
                    deliver: { block in
                        deliveredTexts.append(block.text)
                        return true
                    }
                )
            },
            secureInputEnabled: { false },
            validatePlugin: { _, _, completion in
                pendingValidations.append(completion)
            },
            refreshUI: {}
        ),
        contentSourceResolver: { host }
    )
    let delivery = preparedCoordinator.sendNext(
        expectedToken: deliveryFocus,
        completion: { completedDeliveries.append($0) }
    )
    guard delivery.deferred,
          pendingValidations.count == 1,
          completedDeliveries.isEmpty,
          deliveredTexts.isEmpty else {
        print("FAILED: prepared sendNext did not wait for target validation")
        return false
    }
    let firstValidation = pendingValidations.removeFirst()
    firstValidation(.allowed)
    guard
          completedDeliveries == [.init(sentCount: 1, blockedReason: nil)],
          deliveredTexts == ["连接器生成结果一"],
          host.deliveryPendingBlocks.map(\.text) == [
            "连接器生成结果二",
            "连接器生成结果三",
          ],
          host.primaryAction == .deliver else {
        print("FAILED: prepared sendNext did not select only the first generated block")
        return false
    }
    let partialDelivery = preparedCoordinator.sendAll(
        expectedToken: deliveryFocus,
        completion: { completedDeliveries.append($0) }
    )
    guard partialDelivery.deferred,
          pendingValidations.count == 1 else {
        print("FAILED: prepared sendAll did not validate its first remaining block")
        return false
    }
    let secondValidation = pendingValidations.removeFirst()
    secondValidation(.allowed)
    guard pendingValidations.count == 1,
          completedDeliveries.count == 1 else {
        print("FAILED: prepared sendAll did not advance validation one block at a time")
        return false
    }
    // Simulate ordinary typing while the last target check is held. The
    // already-inserted generated block must still be consumed by stable UUID;
    // advancing BufferModel.changeCount cannot make it deliverable twice.
    model.stageExternal("concurrent ordinary input", origin: .rime)
    let thirdValidation = pendingValidations.removeFirst()
    thirdValidation(.rejected(.targetChanged))
    guard
          completedDeliveries == [
            .init(sentCount: 1, blockedReason: nil),
            .init(sentCount: 1, blockedReason: .pluginTargetChanged),
          ],
          deliveredTexts == [
            "连接器生成结果一",
            "连接器生成结果二",
          ],
          model.blocks.map(\.text) == [
            "ordinary source",
            "other action result",
            "stale primary result",
            "连接器生成结果三",
            "concurrent ordinary input",
          ],
          model.blocks.first(where: { $0.text == "连接器生成结果三" })?
            .pluginMetadata?.stale == true,
          host.deliveryPendingBlocks.isEmpty,
          host.primaryAction == .requestGeneration else {
        print("FAILED: prepared sendAll did not atomically consume accepted and stale rejected blocks")
        return false
    }
    return true
}

private func runContextOnlyPreparedActionSmokeTest() -> Bool {
    let legacyJSON = #"""
    {
      "id": "legacy.generate",
      "title": "生成",
      "symbol": "sparkles",
      "statusPath": "/status",
      "invokePath": "/invoke",
      "modes": ["direct"]
    }
    """#
    let contextOnlyJSON = #"""
    {
      "id": "context-only.generate",
      "title": "生成",
      "symbol": "sparkles",
      "statusPath": "/status",
      "preparePath": "/prepare",
      "invokePath": "/invoke",
      "modes": ["direct"],
      "requiresFocus": false
    }
    """#
    guard let legacyAction = try? JSONDecoder().decode(
        ActionPluginDefinition.self,
        from: Data(legacyJSON.utf8)
    ), legacyAction.requiresFocus,
       let action = try? JSONDecoder().decode(
        ActionPluginDefinition.self,
        from: Data(contextOnlyJSON.utf8)
       ), !action.requiresFocus else {
        print("FAILED: requiresFocus manifest compatibility")
        return false
    }

    let groupedBound = ActionPluginDefinition(
        id: "context-only.bound",
        title: "直评",
        symbol: "sparkles",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["direct"],
        requiresFocus: true,
        presentationId: "context-only.generate",
        presentationTitle: "生成"
    )
    let groupedUnbound = ActionPluginDefinition(
        id: "context-only.unbound",
        title: "回复",
        symbol: "sparkles",
        statusPath: "/status",
        preparePath: "/prepare",
        invokePath: "/invoke",
        modes: ["reply"],
        requiresFocus: false,
        presentationId: "context-only.generate",
        presentationTitle: "生成"
    )
    let mismatchedFocusManifest = ActionPluginManifest(
        schemaVersion: 1,
        id: "context-only-group",
        name: "Context Only Group",
        version: "1",
        runtimeConfigPaths: ["runtime.json"],
        actions: [groupedBound, groupedUnbound]
    )
    guard !ActionPluginManifestLoader.validate(mismatchedFocusManifest) else {
        print("FAILED: grouped actions accepted different focus contracts")
        return false
    }

    let manifest = ActionPluginManifest(
        schemaVersion: 1,
        id: "context-only",
        name: "Context Only",
        version: "1",
        runtimeConfigPaths: ["runtime.json"],
        actions: [action]
    )
    guard ActionPluginManifestLoader.validate(manifest) else {
        print("FAILED: context-only manifest validation")
        return false
    }
    let binding = ActionPluginRuntimeBinding(config: ActionPluginRuntimeConfig(
        pluginId: manifest.id,
        apiBase: "http://127.0.0.1:47701/v1/plugin",
        token: "context-only-token",
        updatedAt: 1,
        instanceId: "context-only-instance",
        processId: 1
    ))
    func status(contextId: String) -> ActionPluginStatus {
        ActionPluginStatus(
            available: true,
            contextId: contextId,
            mode: "direct",
            actionId: action.id,
            label: "生成评论",
            targetSummary: "页面评论目标",
            updatedAt: Date().timeIntervalSince1970
        )
    }
    let initialContextID = "context-only-target-a"
    let template = ActionPluginPrepareResponse(
        protocolVersion: ActionPluginPrepareContract.protocolVersion,
        resultFormat: ActionPluginPrepareContract.resultFormat,
        pluginId: manifest.id,
        runtimeInstanceId: "context-only-instance",
        requestId: "template",
        actionId: action.id,
        contextId: initialContextID,
        prompt: "CONTEXT ONLY PROMPT\nReturn blocks-v1.",
        targetSummary: "页面评论目标"
    )
    let response = ActionPluginInvokeResponse(
        requestId: "unused",
        actionId: action.id,
        contextId: initialContextID,
        blocks: [ActionPluginResultBlock(text: "legacy must not run", title: nil)],
        targetSummary: nil
    )
    let transport = ActionPluginTransportStub(
        status: status(contextId: initialContextID),
        response: response,
        binding: binding
    )
    transport.prepareResult = .success(template)
    let connector = PreparedActionConnectorStub()
    connector.holdsCompletion = true
    let focusBox = ActionPluginFocusBox()
    let model = BufferModel()
    let bus = InboundBus()
    let plugin = InstalledActionPlugin(
        manifest: manifest,
        directory: URL(fileURLWithPath: "/tmp/context-only.etplugin", isDirectory: true)
    )
    let host = ActionPluginHost(
        rootURL: URL(fileURLWithPath: "/tmp/context-only-plugin-root", isDirectory: true),
        client: transport,
        focus: focusBox.access,
        bufferModel: model,
        inboundBus: bus,
        pluginLoader: { _ in [plugin] },
        connectorProvider: { connector },
        runtimeBindingIsCurrent: { _, candidate in candidate == binding }
    )

    host.refreshStatuses(force: true)
    guard runMainLoopUntil({ host.presentations.first?.canInvoke == true }),
          focusBox.token == nil,
          host.presentations.first?.available == true,
          let key = host.presentations.first?.key else {
        print("FAILED: context-only action stayed disabled without IMK focus")
        return false
    }
    connector.availability = .unavailable("连接器不可用")
    guard host.presentations.first?.canInvoke == false else {
        print("FAILED: context-only action ignored connector availability")
        return false
    }
    connector.availability = .ready
    focusBox.secureInput = true
    guard host.presentations.first?.canInvoke == false else {
        print("FAILED: context-only action ignored secure input")
        return false
    }
    focusBox.secureInput = false

    host.invoke(key)
    guard runMainLoopUntil({
        connector.requests.count == 1
            && model.transientLoadingActive
            && host.presentations.first?.waitingForFirstContent == true
    }), transport.prepareRequestCount == 1,
       transport.invokeRequestCount == 0 else {
        print("FAILED: context-only action did not invoke its prepared connector")
        return false
    }
    connector.emitHeld(AITextProviderBlock(index: 0,
                                           text: "无焦点流式候选",
                                           title: "候选"))
    guard runMainLoopUntil({ model.blocks.count == 1 }),
          let provisional = model.blocks[0].pluginMetadata,
          provisional.focusToken == nil,
          provisional.reviewedAsPlainText,
          provisional.incomplete,
          model.blocks[0].text == "无焦点流式候选" else {
        print("FAILED: context-only stream was not staged as unbound reviewed text")
        return false
    }

    var deliveryEpochs = FocusEpochState()
    let temporaryDeliveryFocus = deliveryEpochs.activate()
    var deliveryFocus: FocusToken? = temporaryDeliveryFocus
    var deliveredTexts: [String] = []
    var validationCalled = false
    let deliveryCoordinator = BufferDeliveryCoordinator(
        model: model,
        dependencies: .init(
            resolveTarget: { expected in
                guard let deliveryFocus,
                      expected == nil || expected == deliveryFocus else { return nil }
                return .init(
                    token: deliveryFocus,
                    compositionActive: false,
                    resolveComposition: {},
                    deliver: { block in
                        deliveredTexts.append(block.text)
                        return true
                    }
                )
            },
            secureInputEnabled: { false },
            validatePlugin: { _, _, completion in
                validationCalled = true
                completion(.rejected(.targetChanged))
            },
            refreshUI: {}
        )
    )
    guard deliveryCoordinator.availability() == .blocked(.pluginResultIncomplete) else {
        print("FAILED: context-only partial result became deliverable")
        return false
    }
    deliveryFocus = nil
    connector.complete()
    guard runMainLoopUntil({
        model.blocks.count == 1
            && model.blocks[0].pluginMetadata?.incomplete == false
    }), let finalMetadata = model.blocks[0].pluginMetadata,
       finalMetadata.focusToken == nil,
       finalMetadata.reviewedAsPlainText,
       !finalMetadata.stale,
       focusBox.token == nil else {
        print("FAILED: context-only final result acquired a synthetic focus lease")
        return false
    }
    guard deliveryCoordinator.availability() == .blocked(.noFocusedField),
          deliveryCoordinator.sendNext().blockedReason == .noFocusedField,
          deliveredTexts.isEmpty else {
        print("FAILED: unbound result delivered without a fresh target")
        return false
    }

    let freshDeliveryFocus = deliveryEpochs.activate()
    deliveryFocus = freshDeliveryFocus
    let delivered = deliveryCoordinator.sendNext(expectedToken: freshDeliveryFocus)
    guard delivered.succeeded,
          deliveredTexts == ["连接器生成结果"],
          !validationCalled,
          model.blocks.isEmpty else {
        print("FAILED: reviewed context-only result did not use the fresh target boundary")
        return false
    }

    transport.statusResult = .success(status(contextId: initialContextID))
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({ host.presentations.first?.canInvoke == true }) else {
        print("FAILED: context-only target-change fixture did not refresh")
        return false
    }
    host.invoke(key)
    guard runMainLoopUntil({ connector.requests.count == 2 }) else {
        print("FAILED: second context-only invocation did not start")
        return false
    }
    let staleLargeResult = Array(repeating: "review-word", count: 2_200)
        .joined(separator: " ")
    guard staleLargeResult.utf8.count > InboundBus.maxTextCount else {
        print("FAILED: large stale review fixture is too small")
        return false
    }
    connector.blocks = [
        AITextProviderBlock(index: 0,
                            text: staleLargeResult,
                            title: "长结果"),
    ]
    connector.emitHeld(AITextProviderBlock(index: 0,
                                           text: "目标变化前的部分结果",
                                           title: nil))
    guard runMainLoopUntil({ model.blocks.count == 1 }) else {
        print("FAILED: target-change fixture did not stage its partial result")
        return false
    }
    transport.statusResult = .success(status(contextId: "context-only-target-b"))
    host.refreshStatuses(force: true)
    guard runMainLoopUntil({
        model.blocks.isEmpty && host.presentations.first?.running == false
    }) else {
        print("FAILED: context change did not revoke visible partial output")
        return false
    }
    connector.complete()
    guard runMainLoopUntil({ bus.pendingCount == 1 }),
          bus.pending[0].text == staleLargeResult,
          bus.pending[0].pluginMetadata?.stale == true,
          bus.pending[0].pluginMetadata?.focusToken == nil,
          bus.pending[0].pluginMetadata?.reviewedAsPlainText == false,
          model.blocks.isEmpty else {
        print("FAILED: context-changed result did not route to the review inbox")
        return false
    }
    let staleReviewID = bus.pending[0].id
    let reviewedModel = BufferModel.shared
    reviewedModel.discardForPrivacy()
    defer { reviewedModel.discardForPrivacy() }
    bus.accept(staleReviewID)
    guard bus.pending.isEmpty,
          reviewedModel.stagedText == staleLargeResult,
          reviewedModel.blocks.count > 1,
          reviewedModel.blocks.allSatisfy({
              $0.text.utf8.count <= ActionPluginStreamParser.maximumBlockBytes
          }) else {
        print("FAILED: large stale prepared result was not preserved through review",
              bus.pendingCount,
              reviewedModel.stagedText.count,
              staleLargeResult.count,
              reviewedModel.blocks.count,
              reviewedModel.blocks.map { $0.text.utf8.count }.max() ?? 0)
        return false
    }
    return true
}

func runActionPluginSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) action plugin smoke test ==")
    guard runActionPluginManagerSmokeTest() else { return false }
    guard runActionPluginStreamSmokeTest() else { return false }
    guard runContextualActionPresentationSmokeTest() else { return false }
    guard runPreparedActionConnectorSmokeTest() else { return false }
    guard runContextOnlyPreparedActionSmokeTest() else { return false }
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("rimebuffer-plugin-smoke-\(UUID().uuidString)",
                                isDirectory: true)
    let pluginDirectory = root.appendingPathComponent("example.etplugin", isDirectory: true)
    let fakeHome = root.appendingPathComponent("home", isDirectory: true)
    do {
        try fileManager.createDirectory(at: pluginDirectory,
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeHome,
                                        withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let manifest = #"""
        {
          "schemaVersion": 1,
          "id": "example",
          "name": "Example",
          "version": "1.0.0",
          "runtimeConfigPaths": ["symlink-runtime.json", "borrowed-runtime.json", "runtime.json", "old-runtime.json"],
          "actions": [{
            "id": "example.generate",
            "title": "生成",
            "symbol": "sparkles",
            "statusPath": "/status",
            "invokePath": "/invoke",
            "modes": ["direct", "reply"]
          }]
        }
        """#
        try Data(manifest.utf8).write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        try Data(#"{"pluginId":"example","apiBase":"http://localhost:47701/v1/plugin","token":"old","updatedAt":1}"#.utf8)
            .write(to: fakeHome.appendingPathComponent("old-runtime.json"), options: .atomic)
        try Data(#"{"pluginId":"example","apiBase":"http://localhost:47701/v1/plugin","token":"old","updatedAt":1}"#.utf8)
            .write(to: pluginDirectory.appendingPathComponent("old-runtime.json"), options: .atomic)
        try Data(#"{"pluginId":"example","apiBase":"http://127.0.0.1:47701/v1/plugin","token":"new","updatedAt":2}"#.utf8)
            .write(to: pluginDirectory.appendingPathComponent("runtime.json"), options: .atomic)
        try Data(#"{"pluginId":"other","apiBase":"http://127.0.0.1:47701/v1/plugin","token":"borrowed","updatedAt":3}"#.utf8)
            .write(to: pluginDirectory.appendingPathComponent("borrowed-runtime.json"), options: .atomic)
        try fileManager.createSymbolicLink(
            at: pluginDirectory.appendingPathComponent("symlink-runtime.json"),
            withDestinationURL: pluginDirectory.appendingPathComponent("runtime.json")
        )
        let invalidDirectory = root.appendingPathComponent("invalid.etplugin", isDirectory: true)
        try fileManager.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":2,"id":"invalid","name":"Invalid","runtimeConfigPaths":["runtime.json"],"actions":[{"id":"invalid.action","title":"Invalid","symbol":"xmark","statusPath":"/status","invokePath":"/invoke","modes":[]}] }"#.utf8)
            .write(to: invalidDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        let loaded = ActionPluginManifestLoader.load(from: root)
        guard loaded.count == 1,
              loaded[0].manifest.id == "example",
              loaded[0].manifest.actions.count == 1,
              let config = ActionPluginManifestLoader.runtimeConfig(
                for: loaded[0], homeDirectory: fakeHome
              ),
              config.pluginId == "example",
              config.token == "new",
              config.updatedAt == 2 else {
            print("FAILED: manifest discovery/runtime config precedence")
            return false
        }

        guard ActionPluginManifestLoader.expandedPath(
                "~/old-runtime.json",
                pluginDirectory: pluginDirectory,
                homeDirectory: fakeHome
              ) == fakeHome.appendingPathComponent("old-runtime.json"),
              ActionPluginManifestLoader.expandedPath(
                "../escaped-runtime.json",
                pluginDirectory: pluginDirectory,
                homeDirectory: fakeHome
              ) == nil,
              ActionPluginManifestLoader.expandedPath(
                "nested/../runtime.json",
                pluginDirectory: pluginDirectory,
                homeDirectory: fakeHome
              ) == pluginDirectory.appendingPathComponent("runtime.json").standardizedFileURL,
              ActionPluginHTTPClient.isAllowedLoopbackBase(config.apiBase),
              !ActionPluginHTTPClient.isAllowedLoopbackBase("https://example.com/plugin"),
              !ActionPluginHTTPClient.isAllowedLoopbackBase("http://localhost.evil.test/plugin"),
              !ActionPluginHTTPClient.isAllowedLoopbackBase("http://localhost:99999/plugin"),
              !ActionPluginHTTPClient.isAllowedLoopbackBase("http://localhost/plugin?redirect=evil"),
              let request = ActionPluginHTTPClient.makeRequest(
                config: config,
                path: "/status",
                method: "GET",
                timeout: 1.5
              ),
              request.url?.absoluteString == "http://127.0.0.1:47701/v1/plugin/status",
              request.cachePolicy == .reloadIgnoringLocalCacheData,
              request.httpShouldHandleCookies == false,
              request.value(forHTTPHeaderField: "Cache-Control") == "no-store",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer new" else {
            print("FAILED: tilde expansion/loopback/Bearer request contract")
            return false
        }

        var responseBuffer = ActionPluginResponseBuffer()
        let maximumResponseBytes = ActionPluginHTTPClient.maximumResponseBytes
        guard responseBuffer.append(Data(repeating: 0x61,
                                         count: maximumResponseBytes),
                                    maximumBytes: maximumResponseBytes),
              !responseBuffer.append(Data([0x62]),
                                     maximumBytes: maximumResponseBytes),
              responseBuffer.data.count == maximumResponseBytes else {
            print("FAILED: streaming response cap must reject before appending overflow")
            return false
        }

        let status = try JSONDecoder().decode(
            ActionPluginStatus.self,
            from: Data(#"{"available":true,"contextId":"ctx-1","mode":"reply","actionId":"example.generate","label":"回复 @用户","targetSummary":"原评论","updatedAt":3}"#.utf8)
        )
        let action = loaded[0].manifest.actions[0]
        var focusEpochs = FocusEpochState()
        let firstFocus = focusEpochs.activate()
        let secondFocus = focusEpochs.activate()
        guard ActionPluginRoutingRules.statusMatches(status,
                                                     action: action,
                                                     contextId: "ctx-1"),
              !ActionPluginRoutingRules.statusMatches(status,
                                                      action: action,
                                                      contextId: "ctx-2"),
              ActionPluginRoutingRules.focusBindingMatches(
                bound: secondFocus,
                current: secondFocus
              ),
              !ActionPluginRoutingRules.focusBindingMatches(
                bound: firstFocus,
                current: secondFocus
              ),
              !ActionPluginRoutingRules.focusBindingMatches(
                bound: nil,
                current: secondFocus
              ) else {
            print("FAILED: status/action/context/focus matching")
            return false
        }

        let response = try JSONDecoder().decode(
            ActionPluginInvokeResponse.self,
            from: Data(#"{"requestId":"req-1","actionId":"example.generate","contextId":"ctx-1","blocks":[{"text":"生成的话术","title":"回复 @用户"}],"targetSummary":"原评论"}"#.utf8)
        )
        guard response.blocks.first?.text == "生成的话术",
              ActionPluginRoutingRules.shouldStageDirect(
                responseMatches: true,
                focusValid: true,
                currentStatusMatches: true,
                invocationMarkedStale: false
              ),
              !ActionPluginRoutingRules.shouldStageDirect(
                responseMatches: true,
                focusValid: false,
                currentStatusMatches: true,
                invocationMarkedStale: false
              ),
              !ActionPluginRoutingRules.shouldStageDirect(
                responseMatches: true,
                focusValid: true,
                currentStatusMatches: false,
                invocationMarkedStale: false
              ),
              !ActionPluginRoutingRules.shouldStageDirect(
                responseMatches: false,
                focusValid: true,
                currentStatusMatches: true,
                invocationMarkedStale: false
              ) else {
            print("FAILED: safe result routing predicate")
            return false
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ActionPluginURLProtocolStub.self]
        let httpClient = ActionPluginHTTPClient(
            session: URLSession(configuration: sessionConfiguration)
        )
        func bodyData(from request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
        let requestLock = NSLock()
        var observedHTTPRequests: [String] = []
        ActionPluginURLProtocolStub.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requestLock.lock()
            observedHTTPRequests.append("\(request.httpMethod ?? "") \(request.url?.host ?? "") \(authorization)")
            requestLock.unlock()
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/plugin/status"):
                if authorization == "Bearer new" {
                    return (401, Data(#"{"error":"stale runtime"}"#.utf8))
                }
                guard authorization == "Bearer old" else {
                    return (401, Data(#"{"error":"unauthorized"}"#.utf8))
                }
                return (200, Data(#"{"available":true,"contextId":"ctx-1","mode":"reply","actionId":"example.generate","label":"回复 @用户","targetSummary":"原评论","updatedAt":3}"#.utf8))
            case ("POST", "/v1/plugin/invoke"):
                guard authorization == "Bearer old",
                      request.url?.host == "localhost",
                      let body = bodyData(from: request),
                      let payload = try? JSONDecoder().decode(ActionPluginInvokeRequest.self,
                                                              from: body),
                      payload == ActionPluginInvokeRequest(requestId: "req-1",
                                                           actionId: "example.generate",
                                                           contextId: "ctx-1") else {
                    return (400, Data(#"{"error":"bad request"}"#.utf8))
                }
                return (200, Data(#"{"requestId":"req-1","actionId":"example.generate","contextId":"ctx-1","blocks":[{"text":"生成的话术","title":"回复 @用户"}],"targetSummary":"原评论"}"#.utf8))
            default:
                return (404, Data(#"{"error":"not found"}"#.utf8))
            }
        }
        defer { ActionPluginURLProtocolStub.handler = nil }

        let statusSemaphore = DispatchSemaphore(value: 0)
        var fetchedSnapshot: ActionPluginStatusSnapshot?
        httpClient.fetchStatus(plugin: loaded[0], action: action, binding: nil) { result in
            fetchedSnapshot = try? result.get()
            statusSemaphore.signal()
        }
        guard statusSemaphore.wait(timeout: .now() + 2) == .success,
              fetchedSnapshot?.value == status,
              fetchedSnapshot?.binding.config.token == "old",
              observedHTTPRequests.prefix(2).elementsEqual([
                "GET 127.0.0.1 Bearer new",
                "GET localhost Bearer old",
              ]) else {
            print("FAILED: status must fall back newest-to-oldest and retain successful binding")
            return false
        }

        // A new runtime file appearing after status cannot redirect the invoke
        // to another Marine instance; the successful status binding is exact.
        try Data(#"{"pluginId":"example","apiBase":"http://127.0.0.1:47701/v1/plugin","token":"newest","updatedAt":99}"#.utf8)
            .write(to: pluginDirectory.appendingPathComponent("runtime.json"), options: .atomic)

        let invokeSemaphore = DispatchSemaphore(value: 0)
        var fetchedResponse: ActionPluginInvokeResponse?
        _ = httpClient.invoke(
            plugin: loaded[0],
            action: action,
            binding: fetchedSnapshot!.binding,
            request: ActionPluginInvokeRequest(requestId: "req-1",
                                               actionId: "example.generate",
                                               contextId: "ctx-1")
        ) { _ in
            // Legacy JSON invokes must not produce incremental events.
        } completion: { result in
            fetchedResponse = try? result.get()
            invokeSemaphore.signal()
        }
        guard invokeSemaphore.wait(timeout: .now() + 2) == .success,
              fetchedResponse == response,
              observedHTTPRequests.last == "POST localhost Bearer old" else {
            print("FAILED: invoke must use the exact successful status binding")
            return false
        }

        // Exercise the real host lifecycle with injectable focus/transport.
        // No request may run merely because the workbench or browser target
        // appeared; invocation remains an explicit user action.
        let isolatedModel = BufferModel()
        let isolatedBus = InboundBus()
        let focusBox = ActionPluginFocusBox()
        let transport = ActionPluginTransportStub(status: status, response: response)
        let workbenchFirst = ActionPluginHost(rootURL: root,
                                              client: transport,
                                              focus: focusBox.access,
                                              bufferModel: isolatedModel,
                                              inboundBus: isolatedBus,
                                              runtimeBindingIsCurrent: { _, candidate in
                                                  candidate == transport.defaultBinding
                                              })
        var hostChangeCount = 0
        workbenchFirst.onChange = { hostChangeCount += 1 }

        workbenchFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, { hostChangeCount > 0 }),
              workbenchFirst.presentations.first?.canInvoke == false,
              workbenchFirst.presentations.first?.isPreparedGeneration == false,
              workbenchFirst.presentations.first?.preparedGenerationActionIDs.isEmpty == true,
              workbenchFirst.primaryGenerationPresentation == nil,
              workbenchFirst.secondaryPresentations == workbenchFirst.presentations,
              workbenchFirst.primaryAction == .disabled,
              transport.invokeRequestCount == 0 else {
            print("FAILED: workbench-first must wait for a focused target")
            return false
        }

        focusBox.token = firstFocus
        workbenchFirst.focusDidChange()
        workbenchFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            workbenchFirst.presentations.first?.canInvoke == true
        }), transport.invokeRequestCount == 0 else {
            print("FAILED: workbench-first target should enable without auto-invoking")
            return false
        }

        // Target-first: constructing/showing the host after focus exists must
        // converge to the same enabled action.
        let targetFirstModel = BufferModel()
        let targetFirstBus = InboundBus()
        let targetFirstTransport = ActionPluginTransportStub(status: status,
                                                             response: response)
        var targetRuntimeIsCurrent = true
        var targetFirstPluginSelected = true
        let targetFirst = ActionPluginHost(rootURL: root,
                                           client: targetFirstTransport,
                                           focus: focusBox.access,
                                           bufferModel: targetFirstModel,
                                           inboundBus: targetFirstBus,
                                           pluginIsSelected: { pluginID in
                                               targetFirstPluginSelected
                                                   && pluginID == loaded[0].manifest.id
                                           },
                                           runtimeBindingIsCurrent: { _, candidate in
                                               targetRuntimeIsCurrent
                                                   && candidate == targetFirstTransport.defaultBinding
                                           })
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }), targetFirstTransport.invokeRequestCount == 0,
           let targetFirstKey = targetFirst.presentations.first?.key else {
            print("FAILED: target-first should enable without auto-invoking")
            return false
        }

        // A cached context observed under focus A is unusable under focus B,
        // even before the next status poll completes.
        focusBox.token = secondFocus
        targetFirst.focusDidChange()
        let invokesBeforeStaleTap = targetFirstTransport.invokeRequestCount
        targetFirst.invoke(targetFirstKey)
        guard targetFirst.presentations.first?.canInvoke == false,
              targetFirstTransport.invokeRequestCount == invokesBeforeStaleTap else {
            print("FAILED: cached status crossed a focus epoch")
            return false
        }

        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: fresh status did not bind to the new focus")
            return false
        }

        targetFirst.invoke(targetFirstKey)
        guard runMainLoopUntil(timeout: 1, { targetFirstModel.blocks.count == 1 }),
              targetFirstTransport.invokeRequestCount == invokesBeforeStaleTap + 1,
              targetFirstModel.blocks[0].text == "生成的话术",
              targetFirstModel.blocks[0].pluginMetadata?.stale == false,
              targetFirstBus.pendingCount == 0 else {
            print("FAILED: matching invoke/final-status should stage one buffer block")
            return false
        }

        guard let generatedMetadata = targetFirstModel.blocks[0].pluginMetadata else {
            print("FAILED: generated plugin block is missing target metadata")
            return false
        }
        var deliveryDecision: ActionPluginDeliveryDecision?
        targetFirst.validateForDelivery(metadata: generatedMetadata,
                                        expectedFocusToken: secondFocus) {
            deliveryDecision = $0
        }
        let lastValidationBinding = targetFirstTransport.statusBindings.last ?? nil
        guard runMainLoopUntil(timeout: 1, { deliveryDecision != nil }),
              deliveryDecision == .allowed,
              lastValidationBinding == targetFirstTransport.defaultBinding else {
            print("FAILED: send-time validation must re-check the original runtime binding")
            return false
        }

        // Changing the current workbench owner hides and cancels the old
        // plugin's controls, but a completed target-bound block still carries
        // a valid authority record and must remain deliverable. Selection is
        // not installation or runtime revocation.
        targetFirstPluginSelected = false
        targetFirst.bufferPluginSelectionDidChange()
        guard targetFirst.presentations.isEmpty else {
            print("FAILED: deselected plugin remained visible in workbench")
            return false
        }
        var switchedOwnerDeliveryDecision: ActionPluginDeliveryDecision?
        targetFirst.validateForDelivery(metadata: generatedMetadata,
                                        expectedFocusToken: secondFocus) {
            switchedOwnerDeliveryDecision = $0
        }
        guard runMainLoopUntil(timeout: 1, { switchedOwnerDeliveryDecision != nil }),
              switchedOwnerDeliveryDecision == .allowed else {
            print("FAILED: owner switch revoked a completed plugin block")
            return false
        }
        targetFirst.pluginConfigurationDidChange(changedPluginID: "new-owner")
        var enabledOwnerDeliveryDecision: ActionPluginDeliveryDecision?
        targetFirst.validateForDelivery(metadata: generatedMetadata,
                                        expectedFocusToken: secondFocus) {
            enabledOwnerDeliveryDecision = $0
        }
        guard runMainLoopUntil(timeout: 1, { enabledOwnerDeliveryDecision != nil }),
              enabledOwnerDeliveryDecision == .allowed else {
            print("FAILED: enabling another plugin revoked completed authority")
            return false
        }
        targetFirstPluginSelected = true
        targetFirst.bufferPluginSelectionDidChange()

        // A Settings mutation for inactive plugin B changes only B's
        // enablement/authority. It must not cancel selected plugin A's held
        // generation or remove A's partial/final workbench state.
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: selected plugin did not recover before unrelated mutation")
            return false
        }
        targetFirst.pluginConfigurationDidChange(
            changedPluginID: "inactive-plugin"
        )
        guard targetFirst.presentations.first?.canInvoke == true else {
            print("FAILED: inactive plugin mutation cleared selected idle status")
            return false
        }
        let blocksBeforeUnrelatedMutation = targetFirstModel.blocks.count
        targetFirstTransport.holdInvoke = true
        targetFirst.invoke(targetFirstKey)
        guard targetFirstModel.loadingMessage != nil,
              targetFirst.presentations.first?.running == true else {
            print("FAILED: unrelated-mutation fixture did not hold generation")
            return false
        }
        targetFirst.pluginConfigurationDidChange(
            changedPluginID: "inactive-plugin"
        )
        guard targetFirstModel.loadingMessage != nil,
              targetFirst.presentations.first?.running == true else {
            print("FAILED: inactive plugin mutation cancelled selected generation")
            return false
        }
        targetFirstTransport.holdInvoke = false
        targetFirstTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, {
            targetFirstModel.blocks.count == blocksBeforeUnrelatedMutation + 1
                && targetFirstModel.loadingMessage == nil
        }) else {
            print("FAILED: selected generation did not survive inactive plugin mutation")
            return false
        }

        // Runtime rotation revokes legacy JSON results too. The old local
        // service may still answer, but its binding can no longer authorize a
        // block minted by the previous instance.
        targetRuntimeIsCurrent = false
        var rotatedDeliveryDecision: ActionPluginDeliveryDecision?
        targetFirst.validateForDelivery(metadata: generatedMetadata,
                                        expectedFocusToken: secondFocus) {
            rotatedDeliveryDecision = $0
        }
        guard runMainLoopUntil(timeout: 1, { rotatedDeliveryDecision != nil }),
              rotatedDeliveryDecision == .rejected(.stale) else {
            print("FAILED: legacy delivery survived runtime rotation")
            return false
        }
        targetRuntimeIsCurrent = true

        // A disable/uninstall notification must revoke a validation that is
        // already waiting on the plugin's status response.
        let validationRoot = root.appendingPathComponent("validation-race", isDirectory: true)
        let validationLoader = ActionPluginLoaderBox([loaded[0]])
        let validationModel = BufferModel()
        let validationBus = InboundBus()
        let validationFocus = ActionPluginFocusBox()
        validationFocus.token = secondFocus
        let validationTransport = ActionPluginTransportStub(status: status,
                                                             response: response)
        let validationHost = ActionPluginHost(
            rootURL: validationRoot,
            client: validationTransport,
            focus: validationFocus.access,
            bufferModel: validationModel,
            inboundBus: validationBus,
            pluginLoader: validationLoader.load,
            runtimeBindingIsCurrent: { _, candidate in
                candidate == validationTransport.defaultBinding
            }
        )
        validationHost.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            validationHost.presentations.first?.canInvoke == true
        }), let validationKey = validationHost.presentations.first?.key else {
            print("FAILED: validation-race host did not become ready")
            return false
        }
        validationHost.invoke(validationKey)
        guard runMainLoopUntil(timeout: 1, { validationModel.blocks.count == 1 }),
              let validationMetadata = validationModel.blocks.first?.pluginMetadata else {
            print("FAILED: validation-race fixture did not stage a bound block")
            return false
        }
        validationTransport.holdStatus = true
        var revokedValidation: ActionPluginDeliveryDecision?
        validationHost.validateForDelivery(metadata: validationMetadata,
                                             expectedFocusToken: secondFocus) {
            revokedValidation = $0
        }
        guard revokedValidation == nil else {
            print("FAILED: held delivery validation completed synchronously")
            return false
        }
        validationLoader.plugins = []
        NotificationCenter.default.post(
            name: ActionPluginManager.didChangeNotification,
            object: nil,
            userInfo: [
                ActionPluginManager.rootPathUserInfoKey:
                    validationRoot.standardizedFileURL.path,
            ]
        )
        validationTransport.completeHeldStatus()
        guard runMainLoopUntil(timeout: 1, { revokedValidation != nil }),
              revokedValidation == .rejected(.stale),
              validationModel.blocks.count == 1 else {
            print("FAILED: disable during held send-validation must reject as stale")
            return false
        }

        func upgradedPlugin(version: String, title: String) -> InstalledActionPlugin {
            let original = loaded[0]
            let originalAction = original.manifest.actions[0]
            let upgradedAction = ActionPluginDefinition(
                id: originalAction.id,
                title: title,
                symbol: originalAction.symbol,
                statusPath: originalAction.statusPath,
                invokePath: originalAction.invokePath,
                modes: originalAction.modes
            )
            let upgradedManifest = ActionPluginManifest(
                schemaVersion: original.manifest.schemaVersion,
                id: original.manifest.id,
                name: original.manifest.name,
                version: version,
                runtimeConfigPaths: original.manifest.runtimeConfigPaths,
                actions: [upgradedAction]
            )
            return InstalledActionPlugin(manifest: upgradedManifest,
                                         directory: original.directory)
        }

        // Keeping plugin/action IDs stable across an upgrade must not let the
        // old generation's invoke callback or final-status callback stage text.
        let upgradeRoot = root.appendingPathComponent("upgrade-race", isDirectory: true)
        let upgradeLoader = ActionPluginLoaderBox([loaded[0]])
        let upgradeModel = BufferModel()
        let upgradeBus = InboundBus()
        let upgradeFocus = ActionPluginFocusBox()
        upgradeFocus.token = secondFocus
        let upgradeTransport = ActionPluginTransportStub(status: status,
                                                          response: response)
        let upgradeHost = ActionPluginHost(
            rootURL: upgradeRoot,
            client: upgradeTransport,
            focus: upgradeFocus.access,
            bufferModel: upgradeModel,
            inboundBus: upgradeBus,
            pluginLoader: upgradeLoader.load,
            runtimeBindingIsCurrent: { _, candidate in
                candidate == upgradeTransport.defaultBinding
            }
        )
        upgradeHost.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            upgradeHost.presentations.first?.canInvoke == true
        }), let upgradeKey = upgradeHost.presentations.first?.key else {
            print("FAILED: upgrade-race host did not become ready")
            return false
        }
        upgradeTransport.holdInvoke = true
        upgradeHost.invoke(upgradeKey)
        guard upgradeTransport.invokeRequestCount == 1,
              upgradeModel.loadingMessage != nil else {
            print("FAILED: upgrade-race invoke was not held")
            return false
        }
        let version2 = upgradedPlugin(version: "2.0.0", title: "生成 v2")
        upgradeLoader.plugins = [version2]
        NotificationCenter.default.post(
            name: ActionPluginManager.didChangeNotification,
            object: nil,
            userInfo: [
                ActionPluginManager.rootPathUserInfoKey:
                    upgradeRoot.standardizedFileURL.path,
                ActionPluginManager.changedPluginIDUserInfoKey:
                    loaded[0].manifest.id,
            ]
        )
        upgradeTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, {
            upgradeHost.presentations.first?.title == "生成 v2"
                && upgradeHost.presentations.first?.canInvoke == true
        }), upgradeModel.loadingMessage == nil,
           upgradeModel.blocks.isEmpty,
           upgradeBus.pendingCount == 0 else {
            print("FAILED: same-key manifest upgrade accepted an old invoke callback")
            return false
        }

        // Also cover the narrower window after invoke succeeded but its final
        // target status is still in flight. Here the management notification is
        // deliberately delayed; the loader read-through must still reject v2.
        upgradeTransport.holdInvoke = false
        upgradeTransport.holdStatus = true
        let statusRequestsBeforeFinalRace = upgradeTransport.statusRequestCount
        upgradeHost.invoke(upgradeKey)
        guard runMainLoopUntil(timeout: 1, {
            upgradeTransport.statusRequestCount > statusRequestsBeforeFinalRace
                && upgradeModel.loadingMessage != nil
        }) else {
            print("FAILED: final-status upgrade race was not held")
            return false
        }
        upgradeLoader.plugins = [upgradedPlugin(version: "3.0.0", title: "生成 v3")]
        upgradeTransport.completeHeldStatus()
        guard runMainLoopUntil(timeout: 1, { upgradeModel.loadingMessage == nil }),
              upgradeModel.blocks.isEmpty,
              upgradeBus.pendingCount == 0 else {
            print("FAILED: same-key upgrade accepted an old final-status callback")
            return false
        }

        // Exercise the real coordinator gate without an IMK client: validation
        // begins for focus A, focus changes to B, then even an "allowed" late
        // callback must not reach the injected delivery closure.
        var deliveryEpochs = FocusEpochState()
        let deliveryFocusA = deliveryEpochs.activate()
        let deliveryFocusB = deliveryEpochs.activate()
        var currentDeliveryFocus: FocusToken? = deliveryFocusA
        var insertedTexts: [String] = []
        var heldDeliveryValidation: ((ActionPluginDeliveryDecision) -> Void)?
        var asyncSendResult: BufferDeliveryCoordinator.SendResult?
        let deliveryCoordinator = BufferDeliveryCoordinator(
            model: targetFirstModel,
            dependencies: .init(
                resolveTarget: { expected in
                    guard let currentDeliveryFocus,
                          expected == nil || expected == currentDeliveryFocus else { return nil }
                    return .init(
                        token: currentDeliveryFocus,
                        compositionActive: false,
                        resolveComposition: {},
                        deliver: { block in
                            insertedTexts.append(block.text)
                            return true
                        }
                    )
                },
                secureInputEnabled: { false },
                validatePlugin: { _, _, completion in
                    heldDeliveryValidation = completion
                },
                refreshUI: {}
            )
        )
        // The isolated block was generated under secondFocus; copy it with the
        // test focus token so the coordinator reaches the asynchronous gate.
        targetFirstModel.discardForPrivacy()
        let deliveryMetadata = BufferModel.PluginMetadata(
            pluginId: generatedMetadata.pluginId,
            actionId: generatedMetadata.actionId,
            requestId: generatedMetadata.requestId,
            contextId: generatedMetadata.contextId,
            focusToken: deliveryFocusA,
            runtimeIdentity: generatedMetadata.runtimeIdentity,
            title: generatedMetadata.title,
            targetSummary: generatedMetadata.targetSummary,
            stale: false
        )
        targetFirstModel.stageExternal("生成的话术",
                                       origin: .plugin(id: generatedMetadata.pluginId),
                                       pluginMetadata: deliveryMetadata)
        let deferredResult = deliveryCoordinator.sendNext(
            expectedToken: deliveryFocusA,
            completion: { asyncSendResult = $0 }
        )
        guard deferredResult.deferred,
              heldDeliveryValidation != nil else {
            print("FAILED: plugin delivery must defer for fresh target validation")
            return false
        }
        currentDeliveryFocus = deliveryFocusB
        heldDeliveryValidation?(.allowed)
        guard insertedTexts.isEmpty,
              targetFirstModel.blocks.count == 1,
              targetFirstModel.blocks[0].pluginMetadata?.stale == true,
              asyncSendResult?.blockedReason == .pluginTargetChanged else {
            print("FAILED: focus A result must never insert after switching to focus B")
            return false
        }

        // If focus changes while generation is in flight, a byte-for-byte
        // matching response still must wait in the inbox for review.
        targetFirstModel.discardForPrivacy()
        targetFirstTransport.holdInvoke = true
        targetFirst.invoke(targetFirstKey)
        var moreFocusEpochs = FocusEpochState()
        let replacementFocus = moreFocusEpochs.activate()
        focusBox.token = replacementFocus
        targetFirst.focusDidChange()
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: stale legacy invocation still occupied the foreground slot")
            return false
        }
        targetFirstTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, { targetFirstBus.pendingCount == 1 }),
              targetFirstModel.blocks.isEmpty,
              targetFirstBus.pending[0].pluginMetadata?.stale == true else {
            print("FAILED: focus-changed result must route to the inbox")
            return false
        }

        // The same revocation applies before a legacy terminal callback is
        // routed. A still-live old endpoint cannot place its late result into
        // either the workbench or the review inbox after runtime rotation.
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: legacy runtime-rotation fixture did not become ready")
            return false
        }
        let inboxCountBeforeRotation = targetFirstBus.pendingCount
        targetFirst.invoke(targetFirstKey)
        targetRuntimeIsCurrent = false
        targetFirstTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, {
            targetFirstModel.loadingMessage == nil
        }), targetFirstModel.blocks.isEmpty,
           targetFirstBus.pendingCount == inboxCountBeforeRotation else {
            print("FAILED: legacy terminal result survived runtime rotation")
            return false
        }
        targetRuntimeIsCurrent = true

        // A full inbox must become a visible workbench notice rather than
        // silently dropping a stale result. Keep a newer foreground request B
        // running while parked A completes, so A cannot reuse or overwrite
        // B's transient-loading ownership.
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: replacement focus did not refresh before inbox-cap test")
            return false
        }
        while targetFirstBus.pendingCount < InboundBus.maxPending {
            _ = targetFirstBus.submit(origin: .mcp(client: "fill"),
                                      text: "占位 \(targetFirstBus.pendingCount)")
        }
        targetFirstTransport.holdInvoke = true
        targetFirst.invoke(targetFirstKey)
        let postCapacityFocus = moreFocusEpochs.activate()
        focusBox.token = postCapacityFocus
        targetFirst.focusDidChange()
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == true
        }) else {
            print("FAILED: full-inbox foreground B did not become ready")
            return false
        }
        targetFirst.invoke(targetFirstKey)
        targetFirstTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.workbenchFailureMessage?.contains("收信箱已满") == true
        }), targetFirstBus.pendingCount == InboundBus.maxPending,
           targetFirstModel.blocks.isEmpty,
           targetFirstModel.transientLoadingActive,
           targetFirstModel.loadingMessage?.contains("收信箱已满") != true else {
            print("FAILED: full inbox notice was lost behind foreground B")
            return false
        }
        targetFirstTransport.completeHeldInvoke()
        guard runMainLoopUntil(timeout: 1, { targetFirstModel.blocks.count == 1 }),
              targetFirst.workbenchFailureMessage?.contains("收信箱已满") == true,
              !targetFirstModel.transientLoadingActive else {
            print("FAILED: foreground B completion erased the background retention notice")
            return false
        }
        targetFirstTransport.holdInvoke = false
        targetFirstModel.discardForPrivacy()
        targetFirst.cancelActiveInvocationForWorkbench()

        // Marine/runtime unavailable disables only this action host; existing
        // Rime buffer state remains intact and no generation starts.
        targetFirstTransport.statusResult = .failure(ActionPluginHTTPError.runtimeUnavailable)
        targetFirst.refreshStatuses(force: true)
        guard runMainLoopUntil(timeout: 1, {
            targetFirst.presentations.first?.canInvoke == false
        }) else {
            print("FAILED: unavailable plugin runtime should disable its action")
            return false
        }

        let bus = InboundBus.shared
        let model = BufferModel.shared
        let oldEnabled = model.enabled
        defer {
            model.discardForPrivacy()
            bus.clear()
            model.enabled = oldEnabled
        }
        model.discardForPrivacy()
        bus.clear()
        let metadata = BufferModel.PluginMetadata(
            pluginId: "example",
            actionId: "example.generate",
            requestId: "req-1",
            contextId: "ctx-1",
            focusToken: secondFocus,
            runtimeIdentity: "instance:stub-instance",
            title: "回复 @用户",
            targetSummary: "原评论",
            stale: true
        )
        let pendingID = bus.submit(origin: .plugin(id: "example"),
                                   text: "迟到结果",
                                   title: "回复 @用户",
                                   pluginMetadata: metadata)
        guard let pendingID,
              bus.pendingCount == 1,
              model.blocks.isEmpty,
              bus.pending[0].pluginMetadata == metadata else {
            print("FAILED: stale plugin result must wait in inbound inbox")
            return false
        }
        bus.accept(pendingID)
        let reviewedMetadata = model.blocks.first?.pluginMetadata
        guard bus.pendingCount == 0,
              model.blocks.count == 1,
              model.blocks[0].origin == .plugin(id: "example"),
              reviewedMetadata?.pluginId == metadata.pluginId,
              reviewedMetadata?.targetSummary == metadata.targetSummary,
              reviewedMetadata?.stale == false,
              reviewedMetadata?.reviewedAsPlainText == true else {
            print("FAILED: accepting a stale plugin result must explicitly downgrade its binding")
            return false
        }
        var reviewedValidationCalled = false
        var reviewedInserted: [String] = []
        let reviewedCoordinator = BufferDeliveryCoordinator(
            model: model,
            dependencies: .init(
                resolveTarget: { expected in
                    guard expected == nil || expected == secondFocus else { return nil }
                    return .init(token: secondFocus,
                                 compositionActive: false,
                                 resolveComposition: {},
                                 deliver: { block in
                                     reviewedInserted.append(block.text)
                                     return true
                                 })
                },
                secureInputEnabled: { false },
                validatePlugin: { _, _, completion in
                    reviewedValidationCalled = true
                    completion(.rejected(.stale))
                },
                refreshUI: {}
            )
        )
        let reviewedSend = reviewedCoordinator.sendNext(expectedToken: secondFocus)
        guard reviewedSend.succeeded,
              reviewedInserted == ["迟到结果"],
              !reviewedValidationCalled,
              model.blocks.isEmpty else {
            print("FAILED: a manually reviewed stale result must send only as ordinary text")
            return false
        }
    } catch {
        print("FAILED: action plugin smoke threw \(error)")
        return false
    }

    print("action plugin smoke OK")
    return true
}

func runOriginSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) origin/echo smoke test ==")

    // Only remote-peer origins are barred from mirroring; every other source
    // (local typing, agent drafts, network inbound) mirrors as before.
    let mirrors: [Origin] = [.rime, .marine, .plugin(id: "example"), .mcp(client: "x"),
                             .http(source: "s"), .sse(feed: "f"), .ssh(host: "h")]
    for o in mirrors where !o.allowsRemoteMirror {
        print("FAILED: \(o.tag) should mirror to remote")
        return false
    }
    guard !Origin.remotePeer(deviceID: "mac-b").allowsRemoteMirror else {
        print("FAILED: remotePeer must NOT mirror back (echo loop)")
        return false
    }

    // Origin identity is by-case AND by-payload, so two peers stay distinct.
    guard Origin.remotePeer(deviceID: "a") != Origin.remotePeer(deviceID: "b"),
          Origin.mcp(client: "a") != Origin.rime else {
        print("FAILED: origin equality is wrong")
        return false
    }

    // Block plumbing: default origin is rime; explicit origin is preserved and
    // readable where the send path reads it.
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    defer { model.discardForPrivacy(); model.enabled = oldEnabled }
    model.enabled = true
    model.discardForPrivacy()
    model.append("你")
    model.append("hi", origin: .mcp(client: "codex"))
    guard model.blocks.count == 2,
          model.blocks[0].origin == .rime,
          model.blocks[1].origin == .mcp(client: "codex") else {
        print("FAILED: append did not carry origin: \(model.blocks.map(\.origin.tag))")
        return false
    }

    print("origin/echo smoke OK")
    return true
}

func runBufferSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) buffer smoke test ==")
    guard RimeKey.fromVirtualKeyCode(22) == 0x36,
          RimeKey.fromVirtualKeyCode(27) == 0x2d,
          RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1e, 0x1f], bundleId: "com.openai.codex", bufferActive: true
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1e], bundleId: "com.apple.Terminal", bufferActive: true
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x1f], bundleId: "com.openai.codex", bufferActive: false
          ),
          !RimeBufferController.shouldConsumeCodexBufferControlText(
              [0x01], bundleId: "com.openai.codex", bufferActive: true
          ),
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x61, mask: RimeKey.controlMask
          ) == .selectAll,
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x61, mask: RimeKey.superMask
          ) == .selectAll,
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x76, mask: RimeKey.controlMask
          ) == .paste,
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x76, mask: RimeKey.superMask
          ) == .paste,
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x61,
            mask: RimeKey.superMask | RimeKey.shiftMask
          ) == nil,
          BufferClipboardShortcutRules.shortcut(
            keycode: 0x76,
            mask: RimeKey.superMask | RimeKey.controlMask
          ) == nil,
          BufferClipboardPhysicalShortcutRules.shortcut(
            aKeyDown: false,
            vKeyDown: true,
            mask: RimeKey.controlMask
          ) == .paste,
          BufferClipboardPhysicalShortcutRules.shortcut(
            aKeyDown: true,
            vKeyDown: false,
            mask: RimeKey.controlMask
          ) == .selectAll,
          BufferClipboardPhysicalShortcutRules.shortcut(
            aKeyDown: true,
            vKeyDown: true,
            mask: RimeKey.controlMask
          ) == nil,
          BufferClipboardPhysicalShortcutRules.shortcut(
            aKeyDown: false,
            vKeyDown: true,
            mask: RimeKey.controlMask | RimeKey.shiftMask
          ) == nil,
          BufferClipboardCommandRules.shortcut(
            selectorName: "pageDown:",
            physicalShortcut: .paste
          ) == .paste,
          BufferClipboardCommandRules.shortcut(
            selectorName: "pageDown:",
            physicalShortcut: nil
          ) == nil,
          BufferClipboardCommandRules.shortcut(
            selectorName: "pageDown:",
            physicalShortcut: .selectAll
          ) == nil,
          BufferClipboardCommandRules.shortcut(
            selectorName: "moveToBeginningOfParagraph:",
            physicalShortcut: .selectAll
          ) == .selectAll,
          BufferClipboardCommandRules.shortcut(
            selectorName: "paste:",
            physicalShortcut: nil
          ) == .paste,
          BufferClipboardTextRules.validated("可粘贴") == "可粘贴",
          BufferClipboardTextRules.validated("") == nil,
          BufferClipboardTextRules.validated("a\0b") == nil,
          BufferPluginKeyboardShortcutRules.direction(
            keycode: RimeKey.up,
            mask: RimeKey.superMask | RimeKey.shiftMask
          ) == -1,
          BufferPluginKeyboardShortcutRules.direction(
            keycode: RimeKey.down,
            mask: RimeKey.superMask | RimeKey.shiftMask
          ) == 1,
          BufferPluginKeyboardShortcutRules.direction(
            keycode: RimeKey.up,
            mask: RimeKey.superMask | RimeKey.shiftMask | RimeKey.controlMask
          ) == nil,
          BufferPluginKeyboardShortcutRules.direction(
            keycode: RimeKey.up, mask: RimeKey.altMask
          ) == nil,
          BufferPluginKeyboardShortcutRules.direction(
            keycode: RimeKey.left,
            mask: RimeKey.superMask | RimeKey.shiftMask
          ) == nil,
          BufferPluginKeyboardShortcutRules.commandDirection(
            selectorName: "moveToBeginningOfDocumentAndModifySelection:",
            physicalDirection: -1
          ) == -1,
          BufferPluginKeyboardShortcutRules.commandDirection(
            selectorName: "moveToEndOfDocumentAndModifySelection:",
            physicalDirection: 1
          ) == 1,
          BufferPluginKeyboardShortcutRules.commandDirection(
            selectorName: "moveDown:",
            physicalDirection: -1
          ) == nil else {
        print("FAILED: buffer control-key escape gate")
        return false
    }
    let printableFlags: NSEvent.ModifierFlags = []
    let blockedPrintableModifiers: [NSEvent.ModifierFlags] = [
        .command, .control, .option, .function,
    ]
    guard BufferUnhandledPrintableRules.capturedText(
              characters: "a Z0 .,!?",
              modifierFlags: printableFlags,
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == "a Z0 .,!?",
          BufferUnhandledPrintableRules.capturedText(
              characters: "A",
              modifierFlags: [.shift, .capsLock],
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == "A",
          BufferUnhandledPrintableRules.capturedText(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: false,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == nil,
          BufferUnhandledPrintableRules.capturedText(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: true,
              exactExternalFocus: false,
              secureInputEnabled: false
          ) == nil,
          BufferUnhandledPrintableRules.capturedText(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: true
          ) == nil,
          BufferUnhandledPrintableRules.capturedText(
              characters: "a",
              modifierFlags: [.command],
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == nil,
          blockedPrintableModifiers.allSatisfy({ flags in
              BufferUnhandledPrintableRules.capturedText(
                  characters: "a",
                  modifierFlags: flags,
                  bufferEnabled: true,
                  exactExternalFocus: true,
                  secureInputEnabled: false
              ) == nil
          }),
          BufferUnhandledPrintableRules.capturedText(
              characters: "é",
              modifierFlags: [],
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == nil,
          BufferUnhandledPrintableRules.capturedText(
              characters: "\t",
              modifierFlags: [],
              bufferEnabled: true,
              exactExternalFocus: true,
              secureInputEnabled: false
          ) == nil,
          BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
              characters: "a Z0 .,! ?",
              modifierFlags: [.shift, .capsLock],
              bufferEnabled: true,
              externalClient: true,
              secureInputEnabled: false
          ),
          !BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: false,
              externalClient: true,
              secureInputEnabled: false
          ),
          !BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: true,
              externalClient: false,
              secureInputEnabled: false
          ),
          !BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
              characters: "a",
              modifierFlags: [],
              bufferEnabled: true,
              externalClient: true,
              secureInputEnabled: true
          ),
          blockedPrintableModifiers.allSatisfy({ flags in
              !BufferUnhandledPrintableRules.shouldConsumeRejectedEvent(
                  characters: "a",
                  modifierFlags: flags,
                  bufferEnabled: true,
                  externalClient: true,
                  secureInputEnabled: false
              )
          }) else {
        print("FAILED: unhandled printable buffer capture gate")
        return false
    }
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldOnChange = model.onChange
    defer {
        model.discardForPrivacy()
        model.enabled = oldEnabled
        model.onChange = oldOnChange
    }

    model.onChange = nil
    model.enabled = true
    model.discardForPrivacy()

    let directOwner = DirectInputRunOwner.testing(1)
    let directText = "Hello world, this is a phrase and more."
    var firstDirectID: UUID?
    for character in directText {
        let id = model.appendDirectInputFragment(String(character), owner: directOwner)
        if firstDirectID == nil { firstDirectID = id }
    }
    guard model.stagedText == directText,
          model.blocks.map(\.text) == [
              "Hello world, ",
              "this is a phrase ",
              "and more.",
          ],
          model.blocks.first?.id == firstDirectID else {
        print("FAILED: direct English phrase capture", model.blocks.map(\.text))
        return false
    }
    let tailID = model.blocks.last?.id
    guard model.deleteBackwardInDirectInput(owner: directOwner),
          model.stagedText == String(directText.dropLast()),
          model.blocks.last?.id == tailID else {
        print("FAILED: direct English character backspace")
        return false
    }
    let remainingTailCount = model.blocks.last?.text.count ?? 0
    for _ in 0..<remainingTailCount {
        guard model.deleteBackwardInDirectInput(owner: directOwner) else {
            print("FAILED: direct input tail removal")
            return false
        }
    }
    let previousTail = model.blocks.last?.text ?? ""
    guard !previousTail.isEmpty,
          model.deleteBackwardInDirectInput(owner: directOwner),
          model.blocks.last?.text == String(previousTail.dropLast()) else {
        print("FAILED: direct input character backspace across block boundary")
        return false
    }
    _ = model.appendDirectInputFragment("!", owner: directOwner)
    let countBeforeFocusChange = model.blocks.count
    _ = model.appendDirectInputFragment("X", owner: .testing(2))
    guard model.blocks.count == countBeforeFocusChange + 1,
          model.blocks.last?.text == "X" else {
        print("FAILED: direct input focus boundary")
        return false
    }
    model.append("中")
    _ = model.appendDirectInputFragment("Y", owner: .testing(2))
    guard model.blocks.suffix(2).map(\.text) == ["中", "Y"] else {
        print("FAILED: Rime commit must end direct input run")
        return false
    }
    model.discardForPrivacy()

    model.append("旧内容")
    let generationBeforeSelection = model.changeCount
    guard model.selectAllContent(),
          model.allContentSelected,
          model.changeCount == generationBeforeSelection,
          model.insertPastedText("New useful words and another phrase."),
          !model.allContentSelected,
          model.stagedText == "New useful words and another phrase.",
          model.blocks.count > 1,
          model.changeCount == generationBeforeSelection + 1 else {
        print("FAILED: select-all paste replacement and semantic segmentation")
        return false
    }
    _ = model.selectAllContent()
    model.append("替换")
    guard model.blocks.map(\.text) == ["替换"],
          !model.allContentSelected else {
        print("FAILED: local typing must replace selected workbench content")
        return false
    }
    _ = model.selectAllContent()
    model.beginTransientLoading(requestId: "selection-heartbeat", message: "处理中")
    model.updateTransientLoading(requestId: "selection-heartbeat", message: "仍在处理")
    guard model.allContentSelected else {
        print("FAILED: plugin status heartbeat must preserve select-all state")
        return false
    }
    model.finishTransientLoading(requestId: "selection-heartbeat")
    model.stageExternal("外部", origin: .mcp(client: "selection-smoke"))
    guard model.blocks.map(\.text) == ["替换", "外部"],
          !model.allContentSelected else {
        print("FAILED: asynchronous external content must invalidate, not replace, selection")
        return false
    }
    _ = model.selectAllContent()
    guard model.removeLastBlock(), model.blocks.isEmpty else {
        print("FAILED: backspace semantics must delete an all-selected buffer")
        return false
    }
    guard model.insertPastedText(" \n "),
          model.stagedText == " \n " else {
        print("FAILED: clipboard paste must preserve whitespace-only text")
        return false
    }
    model.discardForPrivacy()

    // Accepted delivery attempts disappear from the live workbench without
    // retaining a plaintext delivery history.
    model.append("你")
    model.append("好")
    let firstID = model.blocks[0].id
    let secondID = model.blocks[1].id
    model.consumeDelivered(blockIDs: [firstID])
    guard model.blocks.map(\.text) == ["好"],
          model.pendingDeliveryBlocks.map(\.id) == [secondID],
          model.insertionIndex == 1,
          model.enabled else {
        print("FAILED: accepted delivery must consume only the accepted block",
              model.blocks.map(\.text),
              model.insertionIndex,
              model.enabled)
        return false
    }
    model.consumeDelivered(blockIDs: [secondID])
    guard model.blocks.isEmpty,
          model.pendingDeliveryBlocks.isEmpty,
          model.insertionIndex == 0 else {
        print("FAILED: full accepted delivery should empty the live workbench")
        return false
    }

    // Consuming non-adjacent accepted blocks must preserve the order of every
    // unsent block and keep the insertion point valid.
    model.append("甲")
    model.append("乙")
    model.append("丙")
    model.append("丁")
    let originalOrder = model.blocks.map(\.id)
    model.consumeDelivered(blockIDs: [originalOrder[1], originalOrder[3]])
    guard model.blocks.map(\.id) == [originalOrder[0], originalOrder[2]],
          model.pendingDeliveryBlocks.map(\.id) == [originalOrder[0], originalOrder[2]],
          model.insertionIndex == 2 else {
        print("FAILED: non-adjacent delivery consumption order")
        return false
    }

    model.discardForPrivacy()
    model.append("前")
    model.append("后")
    guard model.removeLastBlock(),
          model.blocks.map(\.text) == ["前"] else {
        print("FAILED: removeLastBlock should drop newest block",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    guard model.removeLastBlock(),
          model.blocks.isEmpty,
          model.removeLastBlock() == false else {
        print("FAILED: removeLastBlock empty semantics",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }

    model.discardForPrivacy()
    model.append("一")
    model.append("三")
    guard model.moveInsertionPoint(delta: -1),
          model.insertionIndex == 1 else {
        print("FAILED: moveInsertionPoint should move left",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    model.append("二")
    guard model.blocks.map(\.text) == ["一", "二", "三"],
          model.insertionIndex == 2 else {
        print("FAILED: append should insert at insertion point",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }
    _ = model.moveInsertionPoint(delta: 99)
    guard model.insertionIndex == model.blocks.count else {
        print("FAILED: insertion point should clamp to end",
              "index=\(model.insertionIndex)",
              "blocks=\(model.blocks.map(\.text))")
        return false
    }

    model.beginTransientLoading(requestId: "pause-smoke", message: "处理中")
    model.pauseCapturePreservingContent()
    guard !model.enabled,
          !model.transientEnabled,
          model.loadingMessage == nil,
          !model.blocks.isEmpty else {
        print("FAILED: pause must preserve blocks and clear transient loading state")
        return false
    }

    model.discardForPrivacy()
    guard model.blocks.isEmpty,
          model.loadingMessage == nil,
          !model.transientEnabled else {
        print("FAILED: privacy discard must erase all live state")
        return false
    }

    print("buffer smoke: OK")
    return true
}

private func runWorkbenchShelfAlignmentProbe() -> Bool {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 33))
    let shelf = NSStackView()
    shelf.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(shelf)

    let status = NSTextField(labelWithString: "可发送")
    status.lineBreakMode = .byTruncatingTail
    status.setContentHuggingPriority(.defaultLow, for: .horizontal)
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let selector = NSView()
    selector.translatesAutoresizingMaskIntoConstraints = false
    let selectorWidth = selector.widthAnchor.constraint(equalToConstant: 64)
    selectorWidth.isActive = true
    selector.heightAnchor.constraint(equalToConstant: 18).isActive = true

    let spinner = NSView()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.widthAnchor.constraint(equalToConstant: 12).isActive = true
    spinner.heightAnchor.constraint(equalToConstant: 12).isActive = true
    spinner.isHidden = true

    let actionRow = NSStackView()
    actionRow.orientation = .horizontal
    actionRow.spacing = 2
    actionRow.detachesHiddenViews = false
    actionRow.setContentHuggingPriority(.required, for: .horizontal)
    actionRow.setContentCompressionResistancePriority(.required, for: .horizontal)

    let pluginActions = NSStackView(views: [selector, spinner, actionRow])
    pluginActions.orientation = .horizontal
    pluginActions.alignment = .centerY
    pluginActions.distribution = .fill
    pluginActions.spacing = 4
    pluginActions.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 3)
    pluginActions.detachesHiddenViews = false
    pluginActions.setContentHuggingPriority(.required, for: .horizontal)
    pluginActions.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    let flexibleSpace = NSView()
    let statusIndicators = NSStackView()
    let refresh = NSView()
    let close = NSView()
    for control in [refresh, close] {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 22).isActive = true
        control.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    BufferWorkbenchShelfLayout.configure(
        shelf,
        status: status,
        pluginActions: pluginActions,
        flexibleSpace: flexibleSpace,
        statusIndicators: statusIndicators,
        refresh: refresh,
        close: close
    )
    NSLayoutConstraint.activate([
        shelf.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        shelf.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        shelf.topAnchor.constraint(equalTo: host.topAnchor),
        shelf.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])

    func positions() -> (selector: CGFloat, refresh: CGFloat, close: CGFloat) {
        host.layoutSubtreeIfNeeded()
        return (
            selector.convert(selector.bounds, to: host).minX,
            refresh.convert(refresh.bounds, to: host).minX,
            close.convert(close.bounds, to: host).minX
        )
    }
    let baseline = positions()

    status.stringValue = "可生成 · 发送前点选输入框"
    selectorWidth.constant = 108
    spinner.isHidden = false
    let option = NSView()
    option.translatesAutoresizingMaskIntoConstraints = false
    option.widthAnchor.constraint(equalToConstant: 116).isActive = true
    option.heightAnchor.constraint(equalToConstant: 18).isActive = true
    let action = NSView()
    action.translatesAutoresizingMaskIntoConstraints = false
    action.widthAnchor.constraint(equalToConstant: 80).isActive = true
    action.heightAnchor.constraint(equalToConstant: 18).isActive = true
    actionRow.addArrangedSubview(option)
    actionRow.addArrangedSubview(action)
    let dynamic = positions()

    let epsilon: CGFloat = 0.5
    let stable = abs(baseline.selector - dynamic.selector) <= epsilon
        && abs(baseline.refresh - dynamic.refresh) <= epsilon
        && abs(baseline.close - dynamic.close) <= epsilon
    if !stable {
        print("FAILED: workbench shelf alignment moved",
              "baseline=\(baseline)", "dynamic=\(dynamic)")
    }
    return stable
}

func runBufferWindowSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) buffer window smoke test ==")

    guard InputSourceChangeDiagnosticRules.elapsedMilliseconds(
            previousUptime: 10.0,
            now: 10.025
          ) == 25,
          InputSourceChangeDiagnosticRules.elapsedMilliseconds(
            previousUptime: nil,
            now: 10.0
          ) == nil,
          InputSourceChangeDiagnosticRules.elapsedMilliseconds(
            previousUptime: 10.1,
            now: 10.0
          ) == nil,
          InputSourceChangeDiagnosticRules.controlIsDown([.control, .shift]),
          !InputSourceChangeDiagnosticRules.controlIsDown([.option]) else {
        print("FAILED: input-source transition diagnostics")
        return false
    }

    // Physical flagsChanged events close stream mutual pairing even when the
    // aggregate modifier bitset has no delta (for example, pressing the second
    // Shift/Command/Option/Control key). Ordinary key events are not boundaries.
    guard StreamInputModifierBoundaryRules.closesPairing(
        eventType: .flagsChanged
    ),
    !StreamInputModifierBoundaryRules.closesPairing(
        eventType: .keyDown
    ) else {
        print("FAILED: physical modifier transition stream boundary routing")
        return false
    }

    let candidateMatrix = CandidateWindow.matrixLayoutSnapshotForSmoke(rowCount: 3)
    let candidateLayoutEpsilon: CGFloat = 0.5
    guard candidateMatrix.rowCount == 3,
          candidateMatrix.rowHeights.allSatisfy({
              abs($0 - candidateMatrix.expectedRowHeight) <= candidateLayoutEpsilon
          }),
          abs(candidateMatrix.documentHeight
              - candidateMatrix.expectedDocumentHeight) <= candidateLayoutEpsilon,
          abs(candidateMatrix.scrollHeight
              - candidateMatrix.expectedDocumentHeight) <= candidateLayoutEpsilon,
          abs(candidateMatrix.panelHeight
              - candidateMatrix.expectedPanelHeight) <= candidateLayoutEpsilon,
          !candidateMatrix.documentTranslatesAutoresizingMaskIntoConstraints,
          candidateMatrix.documentAutoresizingMaskConstraintCount == 0 else {
        print("FAILED: three-row candidate matrix geometry",
              "rows=\(candidateMatrix.rowCount)",
              "rowHeights=\(candidateMatrix.rowHeights)",
              "document=\(candidateMatrix.documentHeight)/\(candidateMatrix.expectedDocumentHeight)",
              "scroll=\(candidateMatrix.scrollHeight)",
              "panel=\(candidateMatrix.panelHeight)/\(candidateMatrix.expectedPanelHeight)",
              "translatesMask=\(candidateMatrix.documentTranslatesAutoresizingMaskIntoConstraints)",
              "maskConstraints=\(candidateMatrix.documentAutoresizingMaskConstraintCount)")
        return false
    }

    let workbenchHotKeyID = WorkbenchGlobalHotKeyRouting.identifier
    let unrelatedHotKeyID = EventHotKeyID(
        signature: WorkbenchGlobalHotKeyRouting.signature,
        id: WorkbenchGlobalHotKeyRouting.identifierValue + 1
    )
    guard WorkbenchGlobalHotKeyRouting.keyCode == UInt32(kVK_ANSI_B),
          WorkbenchGlobalHotKeyRouting.modifiers == UInt32(cmdKey | shiftKey),
          WorkbenchGlobalHotKeyRouting.route(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
            identifier: workbenchHotKeyID
          ) == .toggleVisibility,
          WorkbenchGlobalHotKeyRouting.route(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased),
            identifier: workbenchHotKeyID
          ) == .ignore,
          WorkbenchGlobalHotKeyRouting.route(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
            identifier: unrelatedHotKeyID
          ) == .ignore else {
        print("FAILED: Cmd+Shift+B global workbench hotkey routing")
        return false
    }

    let ready = BufferDeliveryCoordinator.Availability.ready
    let readyText = BufferWorkbenchStatusText.text(for: ready, secureInput: false)
    let readyHelp = BufferWorkbenchStatusText.help(for: ready, secureInput: false)
    let contextOnlyNoFocusText = BufferWorkbenchStatusText.text(
        for: .blocked(.noFocusedField),
        secureInput: false,
        canGenerateWithoutFocus: true
    )
    let contextOnlyNoFocusHelp = BufferWorkbenchStatusText.help(
        for: .blocked(.noFocusedField),
        secureInput: false,
        canGenerateWithoutFocus: true
    )
    let standardSourceOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .source, mode: .standard
    )
    let standardTargetOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .target, mode: .standard
    )
    let translationSourceOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .source, mode: .translation
    )
    let translationTargetOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .target, mode: .translation
    )
    let compactDerivedTargetOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .target, mode: .singleDerived
    )
    let streamSourceOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .source, mode: .derived(targetRows: 3)
    )
    let streamTargetOffset = BufferWorkbenchMetrics.mainControlYOffset(
        row: .target, mode: .derived(targetRows: 3)
    )
    guard BufferWorkbenchLayout.mainBar
            == [.bufferRail, .send],
          BufferWorkbenchLayout.toolbar
            == [.status, .pluginActions, .refresh, .close],
          BufferWorkbenchLayout.hoverControls
            == [.send, .pluginActions, .refresh, .close],
          BufferWorkbenchLayout.passiveControls == [.bufferRail, .status],
          BufferWorkbenchLayout.toolbarAlwaysExpanded,
          BufferWorkbenchLayout.toolbarEmptySpaceDraggable,
          BufferWorkbenchToolbarDragRules.disposition(
            hitIsInteractiveControl: false
          ) == .dragWindow,
          BufferWorkbenchToolbarDragRules.disposition(
            hitIsInteractiveControl: true
          ) == .interactWithControl,
          runBufferWorkbenchToolbarHitTestProbe(),
          BufferWorkbenchPointerRules.state(
            enabled: true, hovered: false, pressed: false
          ) == .idle,
          BufferWorkbenchPointerRules.state(
            enabled: true, hovered: true, pressed: false
          ) == .hovered,
          BufferWorkbenchPointerRules.state(
            enabled: true, hovered: true, pressed: true
          ) == .pressed,
          BufferWorkbenchPointerRules.state(
            enabled: false, hovered: true, pressed: true
          ) == .disabled,
          BufferWorkbenchPointerRules.cursor(enabled: true) == .pointingHand,
          BufferWorkbenchPointerRules.cursor(enabled: false) == .arrow,
          BufferWorkbenchMetrics.controlSize == 22,
          ProductIdentity.displayName == "RIMES",
          BufferWorkbenchMetrics.mainSpacing == 3,
          BufferWorkbenchMetrics.shelfSpacing == 4,
          BufferWorkbenchMetrics.shelfStatusWidth == 88,
          BufferWorkbenchShelfLayout.flexiblePriority.rawValue == 1,
          BufferWorkbenchShelfLayout.statusWidthPriority.rawValue == 749,
          runWorkbenchShelfAlignmentProbe(),
          BufferInlineMetrics.blockSpacing == 3,
          BufferInlineMetrics.railHorizontalInset == 5,
          BufferInlineMetrics.chipHorizontalInset == 4,
          BufferInlineMetrics.chipVerticalInset == 1,
          BufferInlineMetrics.chipHeight == 20,
          BufferInlineMetrics.chipCornerRadius == 5,
          BufferInlineMetrics.contentSpacing == 3,
          BufferInlineMetrics.originBadgeSize == 5,
          BufferInlineMetrics.messageHorizontalInset == 5,
          BufferInlineMetrics.packedBlockChromeWidth(
            blockCount: 3,
            badgedBlockCount: 2
          ) == 46,
          standardSourceOffset == 0,
          standardTargetOffset == 0,
          compactDerivedTargetOffset == 0,
          translationSourceOffset == -15.5,
          translationTargetOffset == 15.5,
          translationSourceOffset < 0,
          translationTargetOffset > 0,
          translationSourceOffset == -translationTargetOffset,
          streamSourceOffset == -46.5,
          streamTargetOffset == 46.5,
          streamSourceOffset == -streamTargetOffset,
          !BufferWorkbenchLayout.windowBackgroundDraggable,
          FirstMouseButton(frame: .zero).acceptsFirstMouse(for: nil),
          readyText == "可发送",
          contextOnlyNoFocusText == "可生成 · 发送前点选输入框",
          contextOnlyNoFocusHelp.contains("可以先生成内容"),
          contextOnlyNoFocusHelp.contains("发送前"),
          BufferWorkbenchStatusText.text(
            for: .blocked(.noFocusedField),
            secureInput: false
          ) == "等待输入框",
          BufferWorkbenchStatusText.text(
            for: .blocked(.noFocusedField),
            secureInput: true,
            canGenerateWithoutFocus: true
          ) == "安全输入，内容已隐藏",
          !readyText.contains("ChatGPT"),
          !readyText.contains("→"),
          !readyHelp.contains("ChatGPT"),
          !readyHelp.contains("发送到"),
          BufferWorkbenchStatusText.text(for: ready, secureInput: true)
            == "安全输入，内容已隐藏",
          BufferWorkbenchStatusText.text(
            for: .blocked(.validatingPluginTarget), secureInput: false
          ) == "正在确认目标",
          BufferWorkbenchStatusText.text(
            for: .blocked(.stalePluginResult), secureInput: false
          ) == "插件结果已过期",
          BufferWorkbenchStatusText.text(
            for: .blocked(.pluginTargetChanged), secureInput: false
          ) == "评论目标已变化",
          BufferWorkbenchStatusText.text(
            for: .blocked(.pluginUnavailable), secureInput: false
          ) == "插件暂不可用" else {
        print("FAILED: simplified workbench control/status contract")
        return false
    }

    guard BufferControlRoutingRules.disposition(
            bufferActive: false, ownClient: false, exactFocus: true
          ) == .passThrough,
          BufferControlRoutingRules.disposition(
            bufferActive: true, ownClient: true, exactFocus: true
          ) == .passThrough,
          BufferControlRoutingRules.disposition(
            bufferActive: true, ownClient: false, exactFocus: true
          ) == .executeBufferAction,
          BufferControlRoutingRules.disposition(
            bufferActive: true, ownClient: false, exactFocus: false
          ) == .consumeOnly,
          BufferEnterSecureInputRules.disposition(secureInputEnabled: false)
            == .normal,
          BufferEnterSecureInputRules.disposition(secureInputEnabled: true)
            == .consumeWithoutGuardOrGeneration else {
        print("FAILED: buffer Return/Backspace isolation disposition")
        return false
    }

    guard WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: false,
            hasReadyDelivery: false,
            canGenerate: false
          ) == .disabled,
          WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: false,
            hasReadyDelivery: false,
            canGenerate: true
          ) == .requestGeneration,
          WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: true,
            hasReadyDelivery: true,
            canGenerate: true
          ) == .generating,
          WorkbenchManualGenerationPrimaryActionRules.resolve(
            isGenerating: false,
            hasReadyDelivery: true,
            canGenerate: true
          ) == .deliver,
          !WorkbenchManualGenerationPrimaryAction.disabled.beginsDeliveryGesture,
          !WorkbenchManualGenerationPrimaryAction.requestGeneration.beginsDeliveryGesture,
          !WorkbenchManualGenerationPrimaryAction.generating.beginsDeliveryGesture,
          WorkbenchManualGenerationPrimaryAction.deliver.beginsDeliveryGesture,
          BufferDeliveryCoordinator.Availability.blocked(.composing)
            .blocksManualGenerationRequest,
          !BufferDeliveryCoordinator.Availability.blocked(.nothingPending)
            .blocksManualGenerationRequest,
          !BufferDeliveryCoordinator.Availability.ready
            .blocksManualGenerationRequest else {
        print("FAILED: AI primary action state/Return routing contract")
        return false
    }

    let shortShiftTap = ShiftModifierGesture(
        beganAt: 10,
        rimeKeycode: RimeKey.shiftL,
        session: 7,
        schemaID: "rime_ice"
    )
    let shortRightShiftTap = ShiftModifierGesture(
        beganAt: 10,
        rimeKeycode: RimeKey.shiftR,
        session: 7,
        schemaID: "rime_ice"
    )
    var usedShift = shortShiftTap
    usedShift.noteModifierUse()
    let premodifiedShift = ShiftModifierGesture(
        beganAt: 10,
        rimeKeycode: RimeKey.shiftL,
        session: 7,
        schemaID: "rime_ice",
        beganWithOtherModifier: true
    )
    var overlappingShift = shortShiftTap
    overlappingShift.noteModifierUse()
    var cancelledShift = shortShiftTap
    cancelledShift.cancelForFocusChange()
    guard ShiftModifierGesture.standaloneTapLimit == 0.5,
          shortShiftTap.releaseDecision(
            at: 10.499,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .replayStandaloneTap(rimeKeycode: RimeKey.shiftL),
          shortRightShiftTap.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .replayStandaloneTap(rimeKeycode: RimeKey.shiftR),
          shortShiftTap.releaseDecision(
            at: 10.5,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .discard,
          usedShift.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .discard,
          premodifiedShift.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .discard,
          overlappingShift.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .discard,
          cancelledShift.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "rime_ice"
          ) == .discard,
          usedShift.releaseDecision(
            at: 10.1,
            currentSession: 8,
            currentSchemaID: "rime_ice"
          ) == .discard,
          usedShift.releaseDecision(
            at: 10.1,
            currentSession: 7,
            currentSchemaID: "my_combo"
          ) == .discard else {
        print("FAILED: deferred standalone/modified/held Shift routing")
        return false
    }

    // Host isolation and semantic composition are separate. In particular an
    // idle buffer must keep Chromium in IME-composing mode without making our
    // Return state machine think there is Rime input left to settle.
    guard HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: true,
            capturesRimeCommits: true,
            rimeComposing: false,
            secureInput: false
          ) == .bufferGuard(rimeComposing: false),
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: true,
            capturesRimeCommits: true,
            rimeComposing: true,
            secureInput: false
          ) == .bufferGuard(rimeComposing: true),
          // Transient external blocks own idle Return, but local Rime preedit
          // remains inline because transient mode does not capture typing.
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: true,
            capturesRimeCommits: false,
            rimeComposing: false,
            secureInput: false
          ) == .bufferGuard(rimeComposing: false),
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: true,
            capturesRimeCommits: false,
            rimeComposing: true,
            secureInput: false
          ) == .normalPreedit,
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: false,
            capturesRimeCommits: true,
            rimeComposing: false,
            secureInput: false
          ) == .normalPreedit,
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: false,
            capturesRimeCommits: false,
            rimeComposing: true,
            secureInput: false,
            stagedChordGuardActive: true
          ) == .bufferGuard(rimeComposing: true),
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: false,
            capturesRimeCommits: false,
            rimeComposing: true,
            secureInput: true,
            stagedChordGuardActive: true
          ) == .none,
          HostMarkedTextPresentationRules.presentation(
            bufferControlsActive: true,
            capturesRimeCommits: true,
            rimeComposing: false,
            secureInput: true
          ) == .none,
          HostMarkedTextPresentationRules.shouldRefreshForActiveChange(
            previous: false, current: true
          ),
          !HostMarkedTextPresentationRules.shouldRefreshForActiveChange(
            previous: true, current: true
          ) else {
        print("FAILED: buffer host marked-text isolation presentation")
        return false
    }

    let halfHoldDecision = BufferEnterGestureRules.pollDecision(
        isPhysicalDown: true,
        elapsed: 0.6,
        holdDelay: 1.2
    )
    let halfHoldProgress: Double
    if case let .wait(progress) = halfHoldDecision {
        halfHoldProgress = progress
    } else {
        halfHoldProgress = -1
    }
    guard BufferEnterGestureRules.pollDecision(
            isPhysicalDown: false,
            elapsed: 0.2,
            holdDelay: 1.2
          ) == .sendNext,
          // A delayed poll after a quick release must remain a tap, never an
          // accidental send-all just because wall time crossed the threshold.
          BufferEnterGestureRules.pollDecision(
            isPhysicalDown: false,
            elapsed: 2.0,
            holdDelay: 1.2
          ) == .sendNext,
          abs(halfHoldProgress - 0.5) < 0.000_001,
          BufferEnterGestureRules.pollDecision(
            isPhysicalDown: true,
            elapsed: 1.2,
            holdDelay: 1.2
          ) == .sendAll else {
        print("FAILED: buffer Enter tap/hold poll decision")
        return false
    }

    // Sending the final transient block makes buffer routing pass-through
    // immediately, but the keyUp and newline command from that already-owned
    // physical press must remain consumed independently of model state.
    var lateCommandOwnership = BufferEnterCallbackOwnership()
    lateCommandOwnership.claimPress()
    let inactiveAfterFinalBlock = BufferControlRoutingRules.disposition(
        bufferActive: false,
        ownClient: false,
        exactFocus: true
    )
    guard inactiveAfterFinalBlock == .passThrough,
          lateCommandOwnership.consumeKeyUp() == .consumeOwned,
          lateCommandOwnership.suppressesNewlineCommand,
          lateCommandOwnership.routeNewlineCommand() == .consumeOwned,
          // Duplicate/stale callbacks from the same generation remain hidden;
          // command delivery itself must not consume the protection.
          lateCommandOwnership.routeNewlineCommand() == .consumeOwned,
          lateCommandOwnership.prepareForKeyDown(isRepeat: false) == .routeFresh,
          !lateCommandOwnership.ownsCallbacks else {
        print("FAILED: final-block Enter callbacks must stay owned after buffer deactivation")
        return false
    }

    // Some hosts deliver insertNewline: before keyUp. Consuming the command
    // must retain both keyUp ownership and duplicate-command suppression until
    // a definite fresh press starts.
    var commandFirstOwnership = BufferEnterCallbackOwnership()
    commandFirstOwnership.claimPress()
    guard commandFirstOwnership.routeNewlineCommand() == .consumeOwned,
          commandFirstOwnership.suppressesKeyUp,
          commandFirstOwnership.suppressesNewlineCommand,
          commandFirstOwnership.consumeKeyUp() == .consumeOwned,
          commandFirstOwnership.ownsCallbacks,
          commandFirstOwnership.prepareForKeyDown(isRepeat: false) == .routeFresh,
          !commandFirstOwnership.ownsCallbacks else {
        print("FAILED: command-before-keyUp Enter ownership")
        return false
    }

    // A host may omit didCommand entirely. The next real non-repeat keyDown
    // retires that old debt and routes the same new press immediately. Repeats
    // from a still-owned press remain consumed.
    var nextPressOwnership = BufferEnterCallbackOwnership()
    nextPressOwnership.claimPress()
    _ = nextPressOwnership.consumeKeyUp()
    guard nextPressOwnership.prepareForKeyDown(isRepeat: false) == .routeFresh,
          !nextPressOwnership.ownsCallbacks else {
        print("FAILED: fresh Enter must retire omitted-command debt without press-twice")
        return false
    }
    var repeatOwnership = BufferEnterCallbackOwnership()
    repeatOwnership.claimPress()
    guard repeatOwnership.prepareForKeyDown(isRepeat: true) == .consumeOwned,
          repeatOwnership.suppressesKeyUp,
          repeatOwnership.suppressesNewlineCommand else {
        print("FAILED: Enter auto-repeat must remain attached to owned press")
        return false
    }
    var duplicateKeyUpOwnership = BufferEnterCallbackOwnership()
    duplicateKeyUpOwnership.claimPress()
    guard duplicateKeyUpOwnership.consumeKeyUp() == .consumeOwned,
          duplicateKeyUpOwnership.suppressesKeyUp,
          duplicateKeyUpOwnership.consumeKeyUp() == .consumeOwned,
          duplicateKeyUpOwnership.prepareForKeyDown(isRepeat: false) == .routeFresh,
          !duplicateKeyUpOwnership.ownsCallbacks else {
        print("FAILED: duplicate/late keyUp suppression must survive until fresh press")
        return false
    }

    // A defensive didCommand callback never retires a generation, even if a
    // newer Return is physically down. Only the authoritative NSEvent keyDown
    // may declare and route a fresh press.
    var commandDuringNextPress = BufferEnterCallbackOwnership()
    commandDuringNextPress.claimPress()
    _ = commandDuringNextPress.consumeKeyUp()
    guard commandDuringNextPress.routeNewlineCommand() == .consumeOwned,
          commandDuringNextPress.prepareForKeyDown(isRepeat: false) == .routeFresh,
          !commandDuringNextPress.ownsCallbacks else {
        print("FAILED: didCommand must not retire Enter ownership")
        return false
    }

    guard BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: true,
            isOnActiveSpace: true
          ),
          !BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: true,
            isOnActiveSpace: false
          ),
          !BufferWindowVisibilityRules.isVisibleOnActiveSpace(
            isOrdered: false,
            isOnActiveSpace: true
          ) else {
        print("FAILED: workbench visibility must be scoped to the active Space")
        return false
    }
    guard BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: false,
            secureInput: false,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: false,
            targetScreenMatchesPanel: true
          ),
          BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: false,
            secureInput: false,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: true,
            targetScreenMatchesPanel: false
          ),
          !BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: false,
            secureInput: false,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: true,
            targetScreenMatchesPanel: true
          ),
          !BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: false,
            presentationProtected: false,
            secureInput: false,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: false,
            targetScreenMatchesPanel: true
          ),
          !BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: true,
            secureInput: false,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: false,
            targetScreenMatchesPanel: true
          ),
          !BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: false,
            secureInput: true,
            hasTrustedExternalFocus: true,
            panelVisibleOnActiveSpace: false,
            targetScreenMatchesPanel: true
          ),
          !BufferWindowFocusFollowRules.shouldRelocate(
            bufferEnabled: true,
            presentationProtected: false,
            secureInput: false,
            hasTrustedExternalFocus: false,
            panelVisibleOnActiveSpace: false,
            targetScreenMatchesPanel: true
          ) else {
        print("FAILED: workbench focus-follow visibility policy")
        return false
    }
    let unpinnedBehavior = BufferWindowCollectionBehaviorRules.behavior(
        pinned: false
    )
    let pinnedBehavior = BufferWindowCollectionBehaviorRules.behavior(
        pinned: true
    )
    guard unpinnedBehavior.contains(.moveToActiveSpace),
          unpinnedBehavior.contains(.fullScreenAuxiliary),
          !unpinnedBehavior.contains(.canJoinAllSpaces),
          pinnedBehavior.contains(.canJoinAllSpaces),
          pinnedBehavior.contains(.fullScreenAuxiliary),
          !pinnedBehavior.contains(.moveToActiveSpace) else {
        print("FAILED: workbench Space/full-screen collection behavior")
        return false
    }
    guard BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: true,
            isOnActiveSpace: false,
            pinned: false
          ),
          !BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: true,
            isOnActiveSpace: true,
            pinned: false
          ),
          !BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: false,
            isOnActiveSpace: false,
            pinned: false
          ),
          !BufferWindowOrderingRules.shouldOrderOutBeforeMoving(
            isOrdered: true,
            isOnActiveSpace: false,
            pinned: true
          ) else {
        print("FAILED: workbench old-Space reordering policy")
        return false
    }
    guard CandidatePanelInteractionRules.mayInteract(
            hasLogicalCandidates: true,
            hasInteractionTarget: true,
            panelIsVisible: true,
            panelIsOnActiveSpace: true
          ),
          !CandidatePanelInteractionRules.mayInteract(
            hasLogicalCandidates: true,
            hasInteractionTarget: true,
            panelIsVisible: false,
            panelIsOnActiveSpace: true
          ),
          !CandidatePanelInteractionRules.mayInteract(
            hasLogicalCandidates: true,
            hasInteractionTarget: true,
            panelIsVisible: true,
            panelIsOnActiveSpace: false
          ),
          !CandidatePanelInteractionRules.mayInteract(
            hasLogicalCandidates: true,
            hasInteractionTarget: false,
            panelIsVisible: true,
            panelIsOnActiveSpace: true
          ) else {
        print("FAILED: hidden candidate panel must not capture local interaction")
        return false
    }

    var epochs = FocusEpochState()
    let tokenA = epochs.activate()
    let tokenB = epochs.activate()
    guard tokenA != tokenB,
          !epochs.isCurrent(tokenA),
          epochs.isCurrent(tokenB),
          epochs.deactivate(tokenA) == false,
          epochs.isCurrent(tokenB),
          epochs.deactivate(tokenB),
          epochs.current == nil else {
        print("FAILED: focus epoch must reject stale deactivate")
        return false
    }

    func targetAllowed(tokenIsCurrent: Bool = true,
                       expectedTokenMatches: Bool = true,
                       externalTarget: Bool = true,
                       deliveryTrusted: Bool = true,
                       controllerAlive: Bool = true,
                       clientAlive: Bool = true,
                       clientIdentityMatches: Bool = true,
                       controllerClientIdentityMatches: Bool = true,
                       clientBundleMatches: Bool = true,
                       frontmostApplicationMatches: Bool = true,
                       frontmostProcessMatches: Bool = true) -> Bool {
        FocusTargetRules.allows(
            tokenIsCurrent: tokenIsCurrent,
            expectedTokenMatches: expectedTokenMatches,
            externalTarget: externalTarget,
            deliveryTrusted: deliveryTrusted,
            controllerAlive: controllerAlive,
            clientAlive: clientAlive,
            clientIdentityMatches: clientIdentityMatches,
            controllerClientIdentityMatches: controllerClientIdentityMatches,
            clientBundleMatches: clientBundleMatches,
            frontmostApplicationMatches: frontmostApplicationMatches,
            frontmostProcessMatches: frontmostProcessMatches
        )
    }
    let eligible = targetAllowed()
    let rejectedVariants = [
        targetAllowed(tokenIsCurrent: false),
        targetAllowed(expectedTokenMatches: false),
        targetAllowed(externalTarget: false),
        targetAllowed(deliveryTrusted: false),
        targetAllowed(controllerAlive: false),
        targetAllowed(clientAlive: false),
        targetAllowed(clientIdentityMatches: false),
        targetAllowed(controllerClientIdentityMatches: false),
        targetAllowed(clientBundleMatches: false),
        targetAllowed(frontmostApplicationMatches: false),
        targetAllowed(frontmostProcessMatches: false),
    ]
    guard eligible, rejectedVariants.allSatisfy({ !$0 }) else {
        print("FAILED: live target eligibility gate")
        return false
    }
    guard !FocusTargetRules.shouldPruneExpiredLease(
            controllerAlive: true,
            clientAlive: true
          ),
          FocusTargetRules.shouldPruneExpiredLease(
            controllerAlive: false,
            clientAlive: true
          ),
          FocusTargetRules.shouldPruneExpiredLease(
            controllerAlive: true,
            clientAlive: false
          ),
          FocusTargetRules.requiresNoClientCleanup(
            controllerAlive: true,
            clientAlive: false
          ),
          !FocusTargetRules.requiresNoClientCleanup(
            controllerAlive: false,
            clientAlive: false
          ) else {
        print("FAILED: expired lease must clear a surviving controller session")
        return false
    }

    let ordinaryHost = FocusHostRules.resolveKnownFrontmost(
        incomingBundleID: "app.a",
        frontmostBundleID: "app.a",
        frontmostProcessIdentifier: 101,
        trustedOverlayProcessIdentifier: nil
    )
    let spotlightHost = FocusHostRules.resolveKnownFrontmost(
        incomingBundleID: "com.apple.Spotlight",
        frontmostBundleID: "app.a",
        frontmostProcessIdentifier: 101,
        trustedOverlayProcessIdentifier: 202
    )
    let pasteBundleID = "com.wiheads.paste"
    let pastePath = "/Applications/Paste.app"
    let pasteHost = FocusHostRules.resolveKnownFrontmost(
        incomingBundleID: pasteBundleID,
        frontmostBundleID: "app.a",
        frontmostProcessIdentifier: 101,
        trustedOverlayProcessIdentifier: 303
    )
    let pasteLease = FocusHostResolution(
        kind: .nonactivatingSystemOverlay,
        clientProcessIdentifier: 303,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101
    )
    let savePanelBundleID = "com.apple.appkit.xpc.openAndSavePanelService"
    let savePanelPath =
        "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc"
    let savePanelHost = FocusHostRules.resolveKnownFrontmost(
        incomingBundleID: savePanelBundleID,
        frontmostBundleID: "app.a",
        frontmostProcessIdentifier: 101,
        trustedOverlayProcessIdentifier: nil,
        trustedSystemPanelAvailable: true
    )
    let spotlightLease = FocusHostResolution(
        kind: .nonactivatingSystemOverlay,
        clientProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101
    )
    let savePanelLease = FocusHostResolution(
        kind: .appKitOpenSavePanel,
        clientProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101
    )
    let ordinaryAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .frontmostApplication,
        leaseBundleID: "app.a",
        leaseProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: false
    )
    let ordinaryNilBundleAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .frontmostApplication,
        leaseBundleID: "app.a",
        leaseProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: nil,
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: false
    )
    let ordinaryBundleMismatchAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .frontmostApplication,
        leaseBundleID: "app.a",
        leaseProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.b",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: false
    )
    let ordinaryPIDMismatchAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .frontmostApplication,
        leaseBundleID: "app.a",
        leaseProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 303,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: false
    )
    let spotlightAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: 202,
        trustedSurfaceAuthority: true
    )
    let nilAnchorBundleAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: nil,
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: 202,
        trustedSurfaceAuthority: true
    )
    let changedAnchorBundleAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.b",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: 202,
        trustedSurfaceAuthority: true
    )
    let changedAnchorPIDAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 303,
        currentTrustedOverlayProcessIdentifier: 202,
        trustedSurfaceAuthority: true
    )
    let deadOverlayAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: true
    )
    let restartedOverlayAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: 203,
        trustedSurfaceAuthority: true
    )
    let hiddenOverlayAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .nonactivatingSystemOverlay,
        leaseBundleID: "com.apple.Spotlight",
        leaseProcessIdentifier: 202,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: 202,
        trustedSurfaceAuthority: false
    )
    let savePanelAuthority = FocusHostRules.applicationAuthorityMatches(
        kind: .appKitOpenSavePanel,
        leaseBundleID: savePanelBundleID,
        leaseProcessIdentifier: 101,
        foregroundAnchorBundleID: "app.a",
        foregroundAnchorProcessIdentifier: 101,
        currentFrontmostBundleID: "app.a",
        currentFrontmostProcessIdentifier: 101,
        currentTrustedOverlayProcessIdentifier: nil,
        trustedSurfaceAuthority: true
    )
    let savePanelChangedBundleAuthority =
        FocusHostRules.applicationAuthorityMatches(
            kind: .appKitOpenSavePanel,
            leaseBundleID: savePanelBundleID,
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            currentFrontmostBundleID: "app.b",
            currentFrontmostProcessIdentifier: 101,
            currentTrustedOverlayProcessIdentifier: nil,
            trustedSurfaceAuthority: true
        )
    let savePanelChangedPIDAuthority =
        FocusHostRules.applicationAuthorityMatches(
            kind: .appKitOpenSavePanel,
            leaseBundleID: savePanelBundleID,
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            currentFrontmostBundleID: "app.a",
            currentFrontmostProcessIdentifier: 303,
            currentTrustedOverlayProcessIdentifier: nil,
            trustedSurfaceAuthority: true
        )
    let savePanelMissingSurfaceAuthority =
        FocusHostRules.applicationAuthorityMatches(
            kind: .appKitOpenSavePanel,
            leaseBundleID: savePanelBundleID,
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            currentFrontmostBundleID: "app.a",
            currentFrontmostProcessIdentifier: 101,
            currentTrustedOverlayProcessIdentifier: nil,
            trustedSurfaceAuthority: false
        )
    let orderedPanelWindows = [
        FocusWindowSnapshot(
            windowNumber: 900,
            ownerProcessIdentifier: 303,
            layer: 0,
            alpha: 1
        ),
        FocusWindowSnapshot(
            windowNumber: 42,
            ownerProcessIdentifier: 101,
            layer: 0,
            alpha: 1
        ),
        FocusWindowSnapshot(
            windowNumber: 41,
            ownerProcessIdentifier: 101,
            layer: 0,
            alpha: 1
        ),
    ]
    let frozenPanelWindow = FocusSystemPanelWindowRules.frontmostWindowNumber(
        anchorProcessIdentifier: 101,
        orderedWindows: orderedPanelWindows
    )
    let initialPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: nil,
            frozenWindowRemainsTrusted: false,
            deliverySuspended: true,
            eventCanEstablishTransientSurface: true,
            candidateWindowNumber: 42
        )
    let retainedPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: 42,
            frozenWindowRemainsTrusted: true,
            deliverySuspended: true,
            eventCanEstablishTransientSurface: true,
            candidateWindowNumber: 43
        )
    let vanishedPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: 42,
            frozenWindowRemainsTrusted: false,
            deliverySuspended: true,
            eventCanEstablishTransientSurface: true,
            candidateWindowNumber: 43
        )
    let continuingPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: 42,
            frozenWindowRemainsTrusted: true,
            deliverySuspended: false,
            eventCanEstablishTransientSurface: false,
            candidateWindowNumber: 43
        )
    let freshEpochPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: 42,
            frozenWindowRemainsTrusted: true,
            deliverySuspended: false,
            eventCanEstablishTransientSurface: true,
            candidateWindowNumber: 43
        )
    let nonKeyPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: nil,
            frozenWindowRemainsTrusted: false,
            deliverySuspended: true,
            eventCanEstablishTransientSurface: false,
            candidateWindowNumber: 42
        )
    let unsuspendedPanelWindowAuthority =
        FocusSystemPanelWindowRules.authorityForExistingLease(
            frozenWindowNumber: nil,
            frozenWindowRemainsTrusted: false,
            deliverySuspended: false,
            eventCanEstablishTransientSurface: true,
            candidateWindowNumber: 42
        )
    guard FocusHostRules.isAppKitOpenSavePanelBundle(savePanelBundleID),
          FocusHostRules.isTransientSystemSurfaceBundle(savePanelBundleID),
          FocusHostRules.isTransientSystemSurfaceBundle("com.apple.Spotlight"),
          FocusHostRules.isTransientSystemSurfaceBundle(pasteBundleID),
          !FocusHostRules.isTransientSystemSurfaceBundle("app.a"),
          FocusHostRules.mayUseOrdinaryProcessBoundFallback("app.a"),
          !FocusHostRules.mayUseOrdinaryProcessBoundFallback(
            savePanelBundleID
          ),
          !FocusHostRules.mayUseOrdinaryProcessBoundFallback(
            "com.apple.Spotlight"
          ),
          !FocusHostRules.mayUseOrdinaryProcessBoundFallback(pasteBundleID),
          savePanelHost == savePanelLease,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: savePanelBundleID,
            frontmostBundleID: "app.a",
            frontmostProcessIdentifier: 101,
            trustedOverlayProcessIdentifier: nil,
            trustedSystemPanelAvailable: false
          ) == nil,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: savePanelBundleID,
            frontmostBundleID: savePanelBundleID,
            frontmostProcessIdentifier: 204,
            trustedOverlayProcessIdentifier: nil,
            trustedSystemPanelAvailable: true
          ) == nil,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: "com.apple.Spotlight",
            frontmostBundleID: "com.apple.Spotlight",
            frontmostProcessIdentifier: 202,
            trustedOverlayProcessIdentifier: 202
          ) == nil,
          FocusHostRules.resolutionMatchesLease(
            savePanelLease,
            hostKind: .appKitOpenSavePanel,
            clientProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101
          ),
          savePanelAuthority.bundle,
          savePanelAuthority.process,
          !savePanelChangedBundleAuthority.bundle,
          savePanelChangedBundleAuthority.process,
          savePanelChangedPIDAuthority.bundle,
          !savePanelChangedPIDAuthority.process,
          !savePanelMissingSurfaceAuthority.bundle,
          !savePanelMissingSurfaceAuthority.process,
          frozenPanelWindow == 42,
          FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: orderedPanelWindows
          ),
          !FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: [orderedPanelWindows[2]]
          ),
          !FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: [
                FocusWindowSnapshot(
                    windowNumber: 43,
                    ownerProcessIdentifier: 101,
                    layer: 0,
                    alpha: 1
                ),
                orderedPanelWindows[2],
            ]
          ),
          !FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: [
                FocusWindowSnapshot(
                    windowNumber: 42,
                    ownerProcessIdentifier: 303,
                    layer: 0,
                    alpha: 1
                ),
            ]
          ),
          !FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: [
                FocusWindowSnapshot(
                    windowNumber: 42,
                    ownerProcessIdentifier: 101,
                    layer: 1,
                    alpha: 1
                ),
            ]
          ),
          !FocusSystemPanelWindowRules.windowRemainsTrusted(
            42,
            anchorProcessIdentifier: 101,
            onScreenWindows: [
                FocusWindowSnapshot(
                    windowNumber: 42,
                    ownerProcessIdentifier: 101,
                    layer: 0,
                    alpha: 0
                ),
            ]
          ),
          FocusHostRules.callbackMayUseResolution(
            kind: .appKitOpenSavePanel,
            explicitActivation: true,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: false,
            trustedSurfaceAuthority: false
          ),
          FocusHostRules.callbackMayUseResolution(
            kind: .appKitOpenSavePanel,
            explicitActivation: false,
            eventCanEstablishTransientSurface: true,
            continuesExactLease: false,
            trustedSurfaceAuthority: true
          ),
          !FocusHostRules.callbackMayUseResolution(
            kind: .appKitOpenSavePanel,
            explicitActivation: false,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: false,
            trustedSurfaceAuthority: true
          ),
          FocusHostRules.callbackMayUseResolution(
            kind: .appKitOpenSavePanel,
            explicitActivation: false,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: true,
            trustedSurfaceAuthority: true
          ),
          !FocusHostRules.callbackMayUseResolution(
            kind: .appKitOpenSavePanel,
            explicitActivation: false,
            eventCanEstablishTransientSurface: true,
            continuesExactLease: true,
            trustedSurfaceAuthority: false
          ),
          !FocusHostRules.shouldSuspendNewLease(
            kind: .frontmostApplication,
            explicitActivation: true
          ),
          FocusHostRules.shouldSuspendNewLease(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: true
          ),
          FocusHostRules.shouldSuspendNewLease(
            kind: .appKitOpenSavePanel,
            explicitActivation: true
          ),
          !FocusHostRules.shouldSuspendNewLease(
            kind: .appKitOpenSavePanel,
            explicitActivation: false
          ),
          FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
            kind: .appKitOpenSavePanel,
            reusesExactOwner: true,
            resolutionMatchesOwner: true,
            deliverySuspended: true,
            awaitingKeyDown: true
          ),
          FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
            kind: .nonactivatingSystemOverlay,
            reusesExactOwner: true,
            resolutionMatchesOwner: true,
            deliverySuspended: true,
            awaitingKeyDown: true
          ),
          !FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
            kind: .frontmostApplication,
            reusesExactOwner: true,
            resolutionMatchesOwner: true,
            deliverySuspended: true,
            awaitingKeyDown: true
          ),
          !FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
            kind: .appKitOpenSavePanel,
            reusesExactOwner: true,
            resolutionMatchesOwner: false,
            deliverySuspended: true,
            awaitingKeyDown: true
          ),
          !FocusHostRules.shouldPreservePendingPreheatAfterRejectedCallback(
            kind: .appKitOpenSavePanel,
            reusesExactOwner: true,
            resolutionMatchesOwner: true,
            deliverySuspended: true,
            awaitingKeyDown: false
          ),
          initialPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: true,
            pendingWindowNumber: 42
          ),
          retainedPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: true,
            pendingWindowNumber: 42
          ),
          vanishedPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: false,
            pendingWindowNumber: nil
          ),
          continuingPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: true,
            pendingWindowNumber: nil
          ),
          freshEpochPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: true,
            pendingWindowNumber: 42
          ),
          nonKeyPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: false,
            pendingWindowNumber: nil
          ),
          unsuspendedPanelWindowAuthority == FocusSystemPanelWindowAuthority(
            trusted: false,
            pendingWindowNumber: nil
          ),
          !FocusHostKind.frontmostApplication.requiresTransientSurfaceAuthority,
          FocusHostKind.nonactivatingSystemOverlay.requiresTransientSurfaceAuthority,
          FocusHostKind.appKitOpenSavePanel.requiresTransientSurfaceAuthority,
          FocusHostKind.nonactivatingSystemOverlay.permitsPendingModifierBaselineSync,
          !FocusHostKind.appKitOpenSavePanel.permitsPendingModifierBaselineSync,
          FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: .appKitOpenSavePanel,
            leaseBundleID: savePanelBundleID,
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            activatedBundleID: "app.a",
            activatedProcessIdentifier: 101
          ),
          FocusHostRules.displacedLeaseRequiresNoClientCleanup(
            hostKind: .appKitOpenSavePanel
          ),
          targetAllowed(
            frontmostApplicationMatches: savePanelAuthority.bundle,
            frontmostProcessMatches: savePanelAuthority.process
          ) else {
        print("FAILED: trusted AppKit open/save panel focus gate")
        return false
    }
    let ordinaryUnknownAnchorMatches = ordinaryHost.map {
        FocusHostRules.resolutionMatchesLease(
            $0,
            hostKind: .frontmostApplication,
            clientProcessIdentifier: 101,
            foregroundAnchorBundleID: nil,
            foregroundAnchorProcessIdentifier: 101
        )
    } ?? false
    guard ordinaryHost == FocusHostResolution(
            kind: .frontmostApplication,
            clientProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101
          ),
          spotlightHost == spotlightLease,
          pasteHost == pasteLease,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: pasteBundleID,
            frontmostBundleID: pasteBundleID,
            frontmostProcessIdentifier: 303,
            trustedOverlayProcessIdentifier: 303
          ) == nil,
          savePanelHost == savePanelLease,
          FocusHostRules.isTrustedNonactivatingSystemOverlay(
            bundleID: "com.apple.Spotlight",
            bundlePath: "/System/Library/CoreServices/Spotlight.app"
          ),
          FocusHostRules.isTrustedNonactivatingSystemOverlay(
            bundleID: pasteBundleID,
            bundlePath: pastePath
          ),
          FocusHostRules.isTrustedAppKitOpenSavePanel(
            bundleID: savePanelBundleID,
            bundlePath: savePanelPath
          ),
          !FocusHostRules.isTrustedNonactivatingSystemOverlay(
            bundleID: "com.apple.Spotlight",
            bundlePath: "/Applications/FakeSpotlight.app"
          ),
          !FocusHostRules.isTrustedNonactivatingSystemOverlay(
            bundleID: pasteBundleID,
            bundlePath: "/Applications/FakePaste.app"
          ),
          !FocusHostRules.isTrustedAppKitOpenSavePanel(
            bundleID: savePanelBundleID,
            bundlePath: "/Applications/FakeSavePanel.xpc"
          ),
          !FocusHostRules.isNonactivatingSystemOverlayBundle("com.apple.SearchUI"),
          FocusHostRules.uniqueTrustedOverlayProcessIdentifier(
            bundleID: "com.apple.Spotlight",
            runningCandidates: [
                (202, "/System/Library/CoreServices/Spotlight.app"),
            ]
          ) == 202,
          FocusHostRules.uniqueTrustedOverlayProcessIdentifier(
            bundleID: "com.apple.Spotlight",
            runningCandidates: [
                (202, "/System/Library/CoreServices/Spotlight.app"),
                (203, "/Applications/FakeSpotlight.app"),
            ]
          ) == nil,
          FocusHostRules.uniqueTrustedOverlayProcessIdentifier(
            bundleID: pasteBundleID,
            runningCandidates: [(303, pastePath)]
          ) == 303,
          FocusHostRules.uniqueTrustedOverlayProcessIdentifier(
            bundleID: pasteBundleID,
            runningCandidates: [
                (303, pastePath),
                (304, pastePath),
            ]
          ) == nil,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: pasteBundleID,
            frontmostBundleID: "app.a",
            frontmostProcessIdentifier: 101,
            trustedOverlayProcessIdentifier: nil
          ) == nil,
          FocusHostRules.resolutionMatchesLease(
            pasteLease,
            hostKind: .nonactivatingSystemOverlay,
            clientProcessIdentifier: 303,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101
          ),
          FocusHostRules.allSystemPanelProcessesAreTrusted(
            bundleID: savePanelBundleID,
            runningCandidates: [
                (204, savePanelPath),
            ]
          ),
          FocusHostRules.allSystemPanelProcessesAreTrusted(
            bundleID: savePanelBundleID,
            runningCandidates: [
                (204, savePanelPath),
                (205, savePanelPath),
            ]
          ),
          !FocusHostRules.allSystemPanelProcessesAreTrusted(
            bundleID: savePanelBundleID,
            runningCandidates: []
          ),
          !FocusHostRules.allSystemPanelProcessesAreTrusted(
            bundleID: savePanelBundleID,
            runningCandidates: [
                (204, savePanelPath),
                (205, "/Applications/FakeSavePanel.xpc"),
            ]
          ),
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: "com.apple.Spotlight",
            frontmostBundleID: "app.a",
            frontmostProcessIdentifier: 101,
            trustedOverlayProcessIdentifier: nil
          ) == nil,
          FocusHostRules.resolveKnownFrontmost(
            incomingBundleID: "app.background",
            frontmostBundleID: "app.a",
            frontmostProcessIdentifier: 101,
            trustedOverlayProcessIdentifier: 202
          ) == nil,
          FocusHostRules.resolutionMatchesLease(
            spotlightLease,
            hostKind: .nonactivatingSystemOverlay,
            clientProcessIdentifier: 202,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101
          ),
          !FocusHostRules.resolutionMatchesLease(
            spotlightLease,
            hostKind: .nonactivatingSystemOverlay,
            clientProcessIdentifier: 203,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101
          ),
          !FocusHostRules.resolutionMatchesLease(
            spotlightLease,
            hostKind: .nonactivatingSystemOverlay,
            clientProcessIdentifier: 202,
            foregroundAnchorBundleID: "app.b",
            foregroundAnchorProcessIdentifier: 101
          ),
          !FocusHostRules.resolutionMatchesLease(
            spotlightLease,
            hostKind: .nonactivatingSystemOverlay,
            clientProcessIdentifier: 202,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 303
          ),
          ordinaryUnknownAnchorMatches,
          ordinaryAuthority.bundle,
          ordinaryAuthority.process,
          ordinaryNilBundleAuthority.bundle,
          ordinaryNilBundleAuthority.process,
          !ordinaryBundleMismatchAuthority.bundle,
          ordinaryBundleMismatchAuthority.process,
          ordinaryPIDMismatchAuthority.bundle,
          !ordinaryPIDMismatchAuthority.process,
          spotlightAuthority.bundle,
          spotlightAuthority.process,
          nilAnchorBundleAuthority.bundle,
          nilAnchorBundleAuthority.process,
          !changedAnchorBundleAuthority.bundle,
          changedAnchorBundleAuthority.process,
          changedAnchorPIDAuthority.bundle,
          !changedAnchorPIDAuthority.process,
          !deadOverlayAuthority.bundle,
          !deadOverlayAuthority.process,
          !restartedOverlayAuthority.bundle,
          !restartedOverlayAuthority.process,
          !hiddenOverlayAuthority.bundle,
          !hiddenOverlayAuthority.process,
          FocusHostRules.callbackMayUseResolution(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: true,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: false,
            trustedSurfaceAuthority: false
          ),
          FocusHostRules.callbackMayUseResolution(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: false,
            eventCanEstablishTransientSurface: true,
            continuesExactLease: false,
            trustedSurfaceAuthority: true
          ),
          !FocusHostRules.callbackMayUseResolution(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: false,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: false,
            trustedSurfaceAuthority: true
          ),
          FocusHostRules.callbackMayUseResolution(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: false,
            eventCanEstablishTransientSurface: false,
            continuesExactLease: true,
            trustedSurfaceAuthority: true
          ),
          !FocusHostRules.callbackMayUseResolution(
            kind: .nonactivatingSystemOverlay,
            explicitActivation: false,
            eventCanEstablishTransientSurface: true,
            continuesExactLease: true,
            trustedSurfaceAuthority: false
          ),
          !FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: .frontmostApplication,
            leaseBundleID: "app.a",
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            activatedBundleID: "app.a",
            activatedProcessIdentifier: 101
          ),
          FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: .frontmostApplication,
            leaseBundleID: "app.a",
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            activatedBundleID: "app.b",
            activatedProcessIdentifier: 101
          ),
          FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: .frontmostApplication,
            leaseBundleID: "app.a",
            leaseProcessIdentifier: 101,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            activatedBundleID: "app.a",
            activatedProcessIdentifier: 303
          ),
          FocusHostRules.frontmostChangeInvalidatesLease(
            hostKind: .nonactivatingSystemOverlay,
            leaseBundleID: "com.apple.Spotlight",
            leaseProcessIdentifier: 202,
            foregroundAnchorBundleID: "app.a",
            foregroundAnchorProcessIdentifier: 101,
            activatedBundleID: "app.a",
            activatedProcessIdentifier: 101
          ),
          FocusHostRules.displacedLeaseRequiresNoClientCleanup(
            hostKind: .nonactivatingSystemOverlay
          ),
          !FocusHostRules.displacedLeaseRequiresNoClientCleanup(
            hostKind: .frontmostApplication
          ),
          targetAllowed(
            frontmostApplicationMatches: spotlightAuthority.bundle,
            frontmostProcessMatches: spotlightAuthority.process
          ) else {
        print("FAILED: trusted nonactivating focus overlay gate")
        return false
    }

    guard FocusEventRules.isOrdered(12.0, activationFloor: 11.5, lastAccepted: 11.9),
          !FocusEventRules.isOrdered(11.4, activationFloor: 11.5, lastAccepted: nil),
          !FocusEventRules.isOrdered(9.70, activationFloor: 9.75, lastAccepted: nil),
          !FocusEventRules.isOrdered(11.8, activationFloor: nil, lastAccepted: 11.9),
          FocusEventRules.isFreshNonactivatingOverlayEvent(20.25, now: 20.50),
          !FocusEventRules.isFreshNonactivatingOverlayEvent(19.0, now: 20.50),
          !FocusEventRules.isFreshNonactivatingOverlayEvent(20.75, now: 20.50),
          FocusEventRules.mayTakeOwnership(incomingBundleID: "app.b",
                                           currentOwnerBundleID: "app.a",
                                           frontmostBundleID: "app.b",
                                           incomingHostKind: .frontmostApplication),
          !FocusEventRules.mayTakeOwnership(incomingBundleID: "app.a",
                                            currentOwnerBundleID: "app.b",
                                            frontmostBundleID: "app.b",
                                            incomingHostKind: .frontmostApplication),
          !FocusEventRules.mayTakeOwnership(incomingBundleID: "app.c",
                                            currentOwnerBundleID: "app.a",
                                            frontmostBundleID: "app.b",
                                            incomingHostKind: .frontmostApplication),
          !FocusEventRules.mayTakeOwnership(incomingBundleID: "app.b",
                                            currentOwnerBundleID: "app.a",
                                            frontmostBundleID: nil,
                                            incomingHostKind: .frontmostApplication),
          FocusEventRules.mayTakeOwnership(incomingBundleID: "app.a",
                                           currentOwnerBundleID: "app.a",
                                           frontmostBundleID: nil,
                                           incomingHostKind: .frontmostApplication),
          FocusEventRules.mayTakeOwnership(
            incomingBundleID: "com.apple.Spotlight",
            currentOwnerBundleID: "app.a",
            frontmostBundleID: "app.a",
            incomingHostKind: .nonactivatingSystemOverlay
          ),
          FocusEventRules.mayTakeOwnership(
            incomingBundleID: savePanelBundleID,
            currentOwnerBundleID: "app.a",
            frontmostBundleID: "app.a",
            incomingHostKind: .appKitOpenSavePanel
          ),
          FocusEventRules.mayUseOrdinaryProcessBoundResolution(
            ownerExists: true,
            reusesExactOwner: true,
            frontmostProcessIdentifier: nil,
            knownClientProcessIdentifier: nil
          ),
          FocusEventRules.mayUseOrdinaryProcessBoundResolution(
            ownerExists: false,
            reusesExactOwner: false,
            frontmostProcessIdentifier: 101,
            knownClientProcessIdentifier: nil
          ),
          FocusEventRules.mayUseOrdinaryProcessBoundResolution(
            ownerExists: false,
            reusesExactOwner: false,
            frontmostProcessIdentifier: 101,
            knownClientProcessIdentifier: 101
          ),
          !FocusEventRules.mayUseOrdinaryProcessBoundResolution(
            ownerExists: true,
            reusesExactOwner: false,
            frontmostProcessIdentifier: 101,
            knownClientProcessIdentifier: nil
          ),
          !FocusEventRules.mayUseOrdinaryProcessBoundResolution(
            ownerExists: false,
            reusesExactOwner: false,
            frontmostProcessIdentifier: 101,
            knownClientProcessIdentifier: 202
          ),
          FocusEventRules.mayCacheClientProcess(
            hostKind: .frontmostApplication,
            resolvedIdentityWasVerified: true
          ),
          !FocusEventRules.mayCacheClientProcess(
            hostKind: .frontmostApplication,
            resolvedIdentityWasVerified: false
          ),
          FocusEventRules.mayCacheClientProcess(
            hostKind: .nonactivatingSystemOverlay,
            resolvedIdentityWasVerified: true
          ),
          !FocusEventRules.mayCacheClientProcess(
            hostKind: .appKitOpenSavePanel,
            resolvedIdentityWasVerified: true
          ),
          FocusEventRules.verifiedIdentityRequiresFreshEpoch(
            reusesExactOwner: true,
            ownerProcessIdentityWasVerified: false,
            resolvedIdentityWasVerified: true
          ),
          !FocusEventRules.verifiedIdentityRequiresFreshEpoch(
            reusesExactOwner: true,
            ownerProcessIdentityWasVerified: false,
            resolvedIdentityWasVerified: false
          ),
          !FocusEventRules.verifiedIdentityRequiresFreshEpoch(
            reusesExactOwner: true,
            ownerProcessIdentityWasVerified: true,
            resolvedIdentityWasVerified: true
          ),
          FocusEventRules.mayRebindKnownClientProcess(
            hostKind: .frontmostApplication,
            resolvedIdentityWasVerified: true
          ),
          !FocusEventRules.mayRebindKnownClientProcess(
            hostKind: .frontmostApplication,
            resolvedIdentityWasVerified: false
          ),
          !FocusEventRules.mayRebindKnownClientProcess(
            hostKind: .nonactivatingSystemOverlay,
            resolvedIdentityWasVerified: true
          ) else {
        print("FAILED: focus event ordering/background callback gate")
        return false
    }
    guard FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 0.10
          ),
          !FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 0.30
          ),
          FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 0.75,
            hostKind: .nonactivatingSystemOverlay
          ),
          !FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 2.10,
            hostKind: .nonactivatingSystemOverlay
          ),
          FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 0.75,
            hostKind: .appKitOpenSavePanel
          ),
          !FocusActivationRules.shouldConfirmProvisional(
            isProvisional: true,
            sameControllerAndClient: true,
            age: 2.10,
            hostKind: .appKitOpenSavePanel
          ),
          !FocusActivationRules.lifecycleCallbackMayApply(
            now: 10.05,
            suppressionUntil: 10.10,
            leaseAge: 0.20,
            senderIsExplicit: true,
            clientIdentityWasReused: false
          ),
          FocusActivationRules.lifecycleCallbackMayApply(
            now: 10.20,
            suppressionUntil: 10.10,
            leaseAge: 0.20,
            senderIsExplicit: true,
            clientIdentityWasReused: false
          ),
          !FocusActivationRules.lifecycleCallbackMayApply(
            now: 10.20,
            suppressionUntil: 10.00,
            leaseAge: 0.04,
            senderIsExplicit: false,
            clientIdentityWasReused: false
          ),
          FocusActivationRules.lifecycleCallbackMayApply(
            now: 10.20,
            suppressionUntil: 10.00,
            leaseAge: 0.10,
            senderIsExplicit: false,
            clientIdentityWasReused: false
          ),
          !FocusActivationRules.lifecycleCallbackMayApply(
            now: 99.00,
            suppressionUntil: 10.00,
            leaseAge: 89.00,
            senderIsExplicit: true,
            clientIdentityWasReused: true
          ),
          FocusActivationRules.acceptedEventConfirmsReusedClientLifecycle(
            eventType: .keyDown
          ),
          !FocusActivationRules.acceptedEventConfirmsReusedClientLifecycle(
            eventType: .keyUp
          ),
          !FocusActivationRules.acceptedEventConfirmsReusedClientLifecycle(
            eventType: .flagsChanged
          ),
          abs(FocusActivationRules.suppressionDeadlineAfterConfirmedKeyDown(
            current: 10.25,
            confirmationUptime: 10.05
          ) - 10.55) < 0.000_001,
          FocusActivationRules.suppressionDeadlineAfterConfirmedKeyDown(
            current: 11.0,
            confirmationUptime: 10.05
          ) == 11.0,
          !FocusActivationRules.lifecycleCallbackMayApply(
            now: 10.31,
            suppressionUntil: 10.55,
            leaseAge: 0.31,
            senderIsExplicit: true,
            clientIdentityWasReused: false
          ),
          FocusActivationRules.lifecycleCallbackMayApply(
            now: 99.00,
            suppressionUntil: 10.00,
            leaseAge: 89.00,
            senderIsExplicit: true,
            clientIdentityWasReused: false
          ),
          FocusActivationRules.currentControllerClientMayApply(
            clientExists: true,
            identityMatches: true
          ),
          !FocusActivationRules.currentControllerClientMayApply(
            clientExists: false,
            identityMatches: false
          ),
          !FocusActivationRules.currentControllerClientMayApply(
            clientExists: true,
            identityMatches: false
          ),
          FocusActivationRules.mayContinueExactLeaseWithoutBundle(
            forceNewEpoch: false,
            eventRequiresFreshEpoch: false
          ),
          !FocusActivationRules.mayContinueExactLeaseWithoutBundle(
            forceNewEpoch: true,
            eventRequiresFreshEpoch: false
          ),
          !FocusActivationRules.mayContinueExactLeaseWithoutBundle(
            forceNewEpoch: false,
            eventRequiresFreshEpoch: true
          ),
          FocusActivationRules.eventRevealsFieldChange(
            hasEvent: true,
            reusesExactOwner: true,
            compositionActive: true,
            markedRangeReliable: true,
            markedRangeWasObservable: true,
            markedRangeIsMissing: true
          ),
          !FocusActivationRules.eventRevealsFieldChange(
            hasEvent: true,
            reusesExactOwner: true,
            compositionActive: true,
            markedRangeReliable: true,
            markedRangeWasObservable: false,
            markedRangeIsMissing: true
          ),
          !FocusActivationRules.eventRevealsFieldChange(
            hasEvent: true,
            reusesExactOwner: true,
            compositionActive: true,
            markedRangeReliable: false,
            markedRangeWasObservable: true,
            markedRangeIsMissing: true
          ) else {
        print("FAILED: provisional/lifecycle focus rules")
        return false
    }
    guard FocusTargetRules.identifiesExternalTarget(
            bundleID: "app.external",
            processIdentifier: 101,
            ownBundleID: "ime.own",
            ownProcessIdentifier: 999
          ),
          !FocusTargetRules.identifiesExternalTarget(
            bundleID: "unknown",
            processIdentifier: 999,
            ownBundleID: "ime.own",
            ownProcessIdentifier: 999
          ),
          !FocusTargetRules.identifiesExternalTarget(
            bundleID: "ime.own",
            processIdentifier: 999,
            ownBundleID: "ime.own",
            ownProcessIdentifier: 999
          ) else {
        print("FAILED: own process must never become an external delivery target")
        return false
    }

    let routingGate = ChordClientRoutingGate()
    var callbackRoutingStates: [Bool] = []
    let simulatedChordFlushCallback = {
        callbackRoutingStates.append(routingGate.allowsClientRouting)
    }
    routingGate.withIsolatedClientRouting {
        simulatedChordFlushCallback()
    }
    simulatedChordFlushCallback()
    guard callbackRoutingStates == [false, true],
          routingGate.allowsClientRouting else {
        print("FAILED: suspended focus must isolate pending chord client routing")
        return false
    }

    let appA = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "app.a", processIdentifier: 101,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let appB = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "app.b", processIdentifier: 202,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let relaunchedAppA = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "app.a", processIdentifier: 303,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let recycledAppPID = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "app.c", processIdentifier: 101,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let anonymousProcess = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: nil, processIdentifier: 404,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let sameAnonymousProcess = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: nil, processIdentifier: 404,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let knownAnonymousProcess = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "app.anonymous", processIdentifier: 404,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    let ownWindow = BufferPrivacyTransitionRules.externalIdentity(
        bundleID: "ime.own", processIdentifier: 999,
        ownBundleID: "ime.own", ownProcessIdentifier: 999
    )
    guard let appA, let appB, let relaunchedAppA, let recycledAppPID,
          let anonymousProcess, let sameAnonymousProcess,
          let knownAnonymousProcess,
          ownWindow == nil,
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: nil, activatedExternal: appA,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: appA,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: relaunchedAppA,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: recycledAppPID,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: anonymousProcess,
            activatedExternal: sameAnonymousProcess,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: anonymousProcess,
            activatedExternal: knownAnonymousProcess,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          BufferPrivacyTransitionRules.updatedPrevious(
            anonymousProcess, activatedExternal: knownAnonymousProcess
          ) == knownAnonymousProcess,
          BufferPrivacyTransitionRules.updatedPrevious(
            knownAnonymousProcess, activatedExternal: anonymousProcess
          ) == knownAnonymousProcess,
          BufferPrivacyTransitionRules.updatedPrevious(
            appA, activatedExternal: ownWindow
          ) == appA,
          BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: appB,
            resetOnSwitch: true, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: appB,
            resetOnSwitch: false, holdsExternalContent: false
          ),
          !BufferPrivacyTransitionRules.shouldDiscard(
            previousExternal: appA, activatedExternal: appB,
            resetOnSwitch: true, holdsExternalContent: true
          ) else {
        print("FAILED: external app privacy transition rules")
        return false
    }

    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldOnChange = model.onChange
    model.onChange = nil
    model.discardForPrivacy()
    model.enabled = true
    model.append("shield-smoke")
    let rail = BufferInlineView()
    _ = rail.renderStandardForPreview()
    let renderedBeforeShield = !rail.isHidden && rail.renderedBlockCount == 1
    _ = model.selectAllContent()
    _ = rail.renderStandardForPreview()
    let renderedStandardSelection = rail.renderedSelectedStandardBlockCount == 1
    model.clearAllContentSelection()
    model.failTransientLoading(requestId: "visible-error",
                               message: "收信箱已满，插件结果未保存")
    _ = rail.renderStandardForPreview()
    let renderedErrorBesideContent = rail.renderedTextFragments.contains {
        $0.contains("收信箱已满")
    }
    model.finishTransientLoading(requestId: "visible-error")
    _ = rail.renderStandardForPreview()
    let stableRenderPass = rail.renderPassCount
    let rebuiltUnchangedRail = rail.renderStandardForPreview()
    let skippedUnchangedRail = !rebuiltUnchangedRail && rail.renderPassCount == stableRenderPass
    rail.setEnterHoldProgress(0.6)
    let showedEnterHoldProgress = rail.isEnterHoldProgressVisible
    _ = rail.renderStandardForPreview(shielded: true)
    let scrubbedByShield = rail.isHidden
        && rail.renderedBlockCount == 0
        && !rail.isEnterHoldProgressVisible
    model.enabled = oldEnabled
    model.discardForPrivacy()
    model.onChange = oldOnChange
    guard renderedBeforeShield, renderedStandardSelection, renderedErrorBesideContent,
          skippedUnchangedRail, showedEnterHoldProgress,
          scrubbedByShield else {
        print("FAILED: buffer rail secure-input shielding behavior")
        return false
    }

    let translationRail = BufferInlineView(
        frame: NSRect(
            x: 0,
            y: 0,
            width: 760,
            height: BufferInlineView.translationPreferredHeight(targetRows: 1)
        )
    )
    translationRail.layoutSubtreeIfNeeded()
    let compactMarinePreview = TranslationRailSnapshot(
        sourceText: "",
        showsSourceRail: false,
        outputBlocks: [],
        phase: .idle,
        targetRole: "答",
        targetEmptyText: "等待网页上下文"
    )
    translationRail.setFrameSize(NSSize(
        width: 760,
        height: BufferInlineView.translationPreferredHeight(
            targetRows: 1,
            showsSourceRail: false
        )
    ))
    _ = translationRail.renderTranslationForPreview(compactMarinePreview)
    translationRail.reconcileTranslationDocumentGeometry()
    let compactMarineProbe = translationRail.translationLayoutProbe
    let renderedCompactMarine = translationRail.translationRailCount == 1
        && translationRail.renderedTranslationTargetRowCount == 1
        && translationRail.preferredHeight == BufferInlineView.standardPreferredHeight
        && compactMarineProbe.rails.count == 1
        && translationRail.renderedTextFragments.contains("等待网页上下文")
        && !translationRail.renderedTextFragments.contains("等待原文")
    translationRail.setFrameSize(NSSize(
        width: 760,
        height: BufferInlineView.translationPreferredHeight(targetRows: 1)
    ))
    let sourcePreview = "上方原文缓冲"
    let targetPreviewA = "下方译文"
    let targetPreviewB = "第二块"
    let targetPreviewAID = UUID()
    let targetPreviewBID = UUID()
    let translationPreview = TranslationRailSnapshot(
        sourceText: sourcePreview,
        sourceSelected: true,
        outputBlocks: [
            TranslationOutputBlock(id: targetPreviewAID, text: targetPreviewA),
            TranslationOutputBlock(id: targetPreviewBID, text: targetPreviewB),
        ],
        phase: .ready
    )
    let renderedStackedTranslation = translationRail.renderTranslationForPreview(
        translationPreview
    ) && translationRail.renderedTranslationSourceSelected
    let translationFragments = translationRail.renderedTextFragments
    let sourcePosition = translationFragments.firstIndex(of: sourcePreview)
    let targetPosition = translationFragments.firstIndex(of: targetPreviewA)
    let stableTargetViews = translationRail.renderedTranslationTargetViewIdentities
    let continuedPreview = TranslationRailSnapshot(
        sourceText: "\(sourcePreview)续",
        outputBlocks: [
            TranslationOutputBlock(
                id: targetPreviewAID,
                text: "\(targetPreviewA)续",
                ordinal: 1,
                selected: true,
                retainedTailStart: targetPreviewA.utf16.count
            ),
            TranslationOutputBlock(
                id: targetPreviewBID,
                text: targetPreviewB,
                ordinal: 2
            ),
        ],
        phase: .translating,
        message: "继续全局猜测"
    )
    _ = translationRail.renderTranslationForPreview(continuedPreview)
    let updatedTargetViews = translationRail.renderedTranslationTargetViewIdentities
    let reusedTargetViews = stableTargetViews == updatedTargetViews
        && stableTargetViews.count == 2
        && translationRail.renderedTextFragments.contains(where: {
            $0.contains("\(targetPreviewA)续")
        })
    let multiCandidateAID = UUID()
    let multiCandidateBID = UUID()
    let multiCandidateCID = UUID()
    let multiCandidatePreview = TranslationRailSnapshot(
        sourceText: "fangan",
        outputBlocks: [
            TranslationOutputBlock(id: multiCandidateAID, text: "方案", ordinal: 1,
                                   selected: true),
            TranslationOutputBlock(id: multiCandidateBID, text: "翻案", ordinal: 2),
            TranslationOutputBlock(id: multiCandidateCID, text: "凡干", ordinal: 3),
        ],
        outputRows: [
            TranslationOutputRow(
                key: 0,
                blocks: [TranslationOutputBlock(id: multiCandidateAID, text: "方案",
                                                ordinal: 1, selected: true)]
            ),
            TranslationOutputRow(
                key: 1,
                blocks: [TranslationOutputBlock(id: multiCandidateBID, text: "翻案",
                                                ordinal: 2)]
            ),
            TranslationOutputRow(
                key: 2,
                blocks: [TranslationOutputBlock(id: multiCandidateCID, text: "凡干",
                                                ordinal: 3)]
            ),
        ],
        phase: .ready,
        sourceRole: "拼",
        targetRole: "文"
    )
    // Runtime grows before attaching the third candidate. Exercise the real
    // scroll/document geometry instead of only checking preferredHeight.
    translationRail.setFrameSize(NSSize(
        width: 760,
        height: BufferInlineView.translationPreferredHeight(targetRows: 3)
    ))
    translationRail.layoutSubtreeIfNeeded()
    let renderedMultiCandidateLayout = translationRail.renderTranslationForPreview(
        multiCandidatePreview
    ) && translationRail.renderedTranslationTargetRowCount == 3
        && translationRail.translationRailCount == 4
        && translationRail.preferredHeight
            == BufferInlineView.translationPreferredHeight(targetRows: 3)
    let threeRowProbe = translationRail.translationLayoutProbe
    let threeRowFrames = threeRowProbe.rails
        .map(\.viewportFrame)
        .sorted { $0.minY < $1.minY }
    let renderedThreeRowGeometry = threeRowProbe.boundsHeight == 130
        && threeRowProbe.containerHeight == 120
        && threeRowProbe.rails.count == 4
        && threeRowProbe.rails.allSatisfy {
            abs($0.viewportHeight - 27) < 0.5
                && abs($0.documentHeight - $0.viewportHeight) < 0.5
        }
        && zip(threeRowFrames, threeRowFrames.dropFirst()).allSatisfy {
            $1.minY >= $0.maxY
                && abs(($1.minY - $0.maxY) - 4) < 0.5
        }
    let threeRowIdentities = translationRail.renderedTranslationTargetViewIdentities
    let renderedMultiCandidateRows = renderedMultiCandidateLayout
        && threeRowIdentities.count == 3
    let reorderedCandidateIdentities = threeRowIdentities.count == 3
        ? [threeRowIdentities[2], threeRowIdentities[0]]
        : []
    let retainedCandidateIdentity = threeRowIdentities.count == 3
        ? threeRowIdentities[2]
        : nil
    let twoCandidatePreview = TranslationRailSnapshot(
        sourceText: "fangan",
        outputBlocks: [
            TranslationOutputBlock(id: multiCandidateCID, text: "凡干", ordinal: 1,
                                   selected: true),
            TranslationOutputBlock(id: multiCandidateAID, text: "方案", ordinal: 2),
        ],
        outputRows: [
            TranslationOutputRow(
                key: 2,
                blocks: [TranslationOutputBlock(id: multiCandidateCID, text: "凡干",
                                                ordinal: 1, selected: true)]
            ),
            TranslationOutputRow(
                key: 0,
                blocks: [TranslationOutputBlock(id: multiCandidateAID, text: "方案",
                                                ordinal: 2)]
            ),
        ],
        phase: .ready,
        sourceRole: "拼",
        targetRole: "文"
    )
    let renderedTwoCandidateRowsBeforeShrink = translationRail.renderTranslationForPreview(
        twoCandidatePreview
    ) && translationRail.renderedTranslationTargetRowCount == 2
        && translationRail.translationRailCount == 3
        && !translationRail.renderedTextFragments.contains("翻案")
        && translationRail.renderedTranslationTargetViewIdentities
            == reorderedCandidateIdentities
    translationRail.setFrameSize(NSSize(
        width: 760,
        height: BufferInlineView.translationPreferredHeight(targetRows: 2)
    ))
    translationRail.reconcileTranslationDocumentGeometry()
    let twoRowProbe = translationRail.translationLayoutProbe
    let renderedTwoCandidateRows = renderedTwoCandidateRowsBeforeShrink
        && twoRowProbe.boundsHeight == 99
        && twoRowProbe.containerHeight == 89
        && twoRowProbe.rails.count == 3
        && twoRowProbe.rails.map(\.key) == [nil, 2, 0]
        && twoRowProbe.rails.allSatisfy {
            abs($0.viewportHeight - 27) < 0.5
                && abs($0.documentHeight - $0.viewportHeight) < 0.5
        }
    let retainedChildID = UUID()
    let segmentedOneRowPreview = TranslationRailSnapshot(
        sourceText: "fangan",
        outputBlocks: [
            TranslationOutputBlock(id: multiCandidateCID, text: "修复"),
            TranslationOutputBlock(id: retainedChildID,
                                   text: "一个问题",
                                   retainedTailStart: 0),
        ],
        outputRows: [
            TranslationOutputRow(
                key: 2,
                blocks: [
                    TranslationOutputBlock(id: multiCandidateCID, text: "修复"),
                    TranslationOutputBlock(id: retainedChildID,
                                           text: "一个问题",
                                           retainedTailStart: 0),
                ]
            ),
        ],
        phase: .translating,
        sourceRole: "拼",
        targetRole: "文"
    )
    let renderedSegmentedOneRow = translationRail.renderTranslationForPreview(
        segmentedOneRowPreview
    ) && translationRail.renderedTranslationTargetRowCount == 1
        && translationRail.translationRailCount == 2
        && retainedCandidateIdentity != nil
        && translationRail.renderedTranslationTargetViewIdentities.first
            == retainedCandidateIdentity
        && translationRail.renderedTranslationRetainedTailStarts[retainedChildID] == 0
        && !translationRail.renderedTextFragments.contains("方案")
        && !translationRail.renderedTextFragments.contains("翻案")
    _ = translationRail.refresh(shielded: true)
    let translationShielded = !translationRail.renderedTextFragments.contains(sourcePreview)
        && !translationRail.renderedTextFragments.contains(targetPreviewA)
        && !translationRail.renderedTextFragments.contains("方案")
        && !translationRail.renderedTextFragments.contains("翻案")
        && !translationRail.renderedTextFragments.contains("凡干")
        && !translationRail.renderedTextFragments.contains("修复")
        && !translationRail.renderedTextFragments.contains("一个问题")
    guard renderedStackedTranslation,
          translationRail.translationRailCount == 0,
          sourcePosition != nil,
          targetPosition != nil,
          sourcePosition! < targetPosition!,
          !translationFragments.contains("→"),
          !translationFragments.contains("原"),
          !translationFragments.contains("译"),
          TranslationRailRoleSymbolRules.resolve("原", target: false)
            == .init(name: "text.bubble", accessibilityLabel: "原始内容"),
          TranslationRailRoleSymbolRules.resolve("答", target: true)
            == .init(name: "sparkles", accessibilityLabel: "AI 回答"),
          renderedCompactMarine,
          reusedTargetViews,
          renderedMultiCandidateRows,
          renderedThreeRowGeometry,
          renderedTwoCandidateRows,
          renderedSegmentedOneRow,
          translationShielded else {
        print("FAILED: translation rail must render two stacked, independently shielded buffers",
              "stacked=\(renderedStackedTranslation)",
              "compactMarine=\(renderedCompactMarine)",
              "reused=\(reusedTargetViews)",
              "multi=\(renderedMultiCandidateRows)",
              "threeGeometry=\(renderedThreeRowGeometry)",
              "two=\(renderedTwoCandidateRows)",
              "segmented=\(renderedSegmentedOneRow)",
              "shielded=\(translationShielded)",
              "threeProbe=\(threeRowProbe.boundsHeight)/\(threeRowProbe.containerHeight)",
              "rails=\(threeRowProbe.rails.map { ($0.key, $0.viewportHeight, $0.documentHeight) })")
        return false
    }

    var forwardedCaretIndex: Int?
    let caretIndexProbe = InputCaretGeometryRules.queryAtInlineSessionAnchor { index in
        forwardedCaretIndex = index
        return index
    }
    guard caretIndexProbe == 0, forwardedCaretIndex == 0 else {
        print("FAILED: IMK inline-session caret index contract")
        return false
    }

    var openingEpochs = FocusEpochState()
    let openingToken = openingEpochs.activate()
    let newerToken = openingEpochs.activate()
    guard BufferCandidateSideRules.preferredSide(
            openingSide: .aboveTarget,
            openingToken: openingToken,
            candidateOwner: openingToken
          ) == .above,
          BufferCandidateSideRules.preferredSide(
            openingSide: .aboveTarget,
            openingToken: openingToken,
            candidateOwner: newerToken
          ) == .below,
          BufferCandidateSideRules.preferredSide(
            openingSide: .belowTarget,
            openingToken: openingToken,
            candidateOwner: openingToken
          ) == .below,
          BufferCandidateSideRules.requiresOutwardPlacement(
            openingSide: .belowTarget,
            openingToken: openingToken,
            candidateOwner: openingToken
          ),
          BufferCandidateSideRules.requiresOutwardPlacement(
            openingSide: .aboveTarget,
            openingToken: openingToken,
            candidateOwner: openingToken
          ),
          !BufferCandidateSideRules.requiresOutwardPlacement(
            openingSide: .aboveTarget,
            openingToken: openingToken,
            candidateOwner: newerToken
          ),
          !BufferCandidateSideRules.requiresOutwardPlacement(
            openingSide: .bottomFallback,
            openingToken: nil,
            candidateOwner: nil
          ) else {
        print("FAILED: workbench candidate side focus binding")
        return false
    }

    let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let secondary = NSRect(x: 1440, y: 0, width: 1280, height: 800)
    let leftSecondary = NSRect(x: -1280, y: 0, width: 1280, height: 800)
    let openingFrame = NSRect(x: 200,
                              y: 200,
                              width: 680,
                              height: BufferWindowGeometry.expandedHeight)
    let middleCaret = NSRect(x: 720, y: 500, width: 0, height: 22)
    let belowCaret = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: middleCaret,
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let runtimeHeights = [
        BufferWindowGeometry.expandedHeight,
        BufferWindowGeometry.translationExpandedHeight,
        BufferWindowGeometry.height(expanded: true, mode: .derived(targetRows: 2)),
        BufferWindowGeometry.maximumRuntimeHeight,
        BufferWindowGeometry.expandedHeight,
    ]
    let belowResizes = runtimeHeights.reduce(into: [belowCaret.frame]) { frames, height in
        frames.append(BufferWindowGeometry.resizedOutward(
            frames.last!,
            height: height,
            openingSide: .belowTarget
        ))
    }
    let bottomCaret = NSRect(x: 720, y: 12, width: 0, height: 22)
    let aboveCaret = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: bottomCaret,
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let aboveResizes = runtimeHeights.reduce(into: [aboveCaret.frame]) { frames, height in
        frames.append(BufferWindowGeometry.resizedOutward(
            frames.last!,
            height: height,
            openingSide: .aboveTarget
        ))
    }
    let belowAnchor = BufferWindowGeometry.candidateAnchor(for: belowCaret.frame)
    let belowCandidateSize = NSSize(width: 420, height: 60)
    let belowCandidateOrigin = CandidatePanelGeometry.origin(
        anchor: belowAnchor,
        panelSize: belowCandidateSize,
        visibleFrame: primary,
        preferredSide: .below
    )
    let aboveAnchor = BufferWindowGeometry.candidateAnchor(for: aboveCaret.frame)
    let aboveCandidateSize = NSSize(width: 420, height: 60)
    let aboveCandidateOrigin = CandidatePanelGeometry.origin(
        anchor: aboveAnchor,
        panelSize: aboveCandidateSize,
        visibleFrame: primary,
        preferredSide: .above
    )
    let strictUnavailableAboveCandidate = CandidatePanelGeometry.originIfAvailable(
        anchor: NSRect(x: 200, y: 850, width: 680, height: 40),
        panelSize: NSSize(width: 420, height: 60),
        visibleFrame: primary,
        preferredSide: .above,
        strictPreferredSide: true
    )
    let strictUnavailableBelowCandidate = CandidatePanelGeometry.originIfAvailable(
        anchor: NSRect(x: 200, y: 12, width: 680, height: 40),
        panelSize: NSSize(width: 420, height: 60),
        visibleFrame: primary,
        preferredSide: .below,
        strictPreferredSide: true
    )
    // Current height fits below, but the forecast does not. Choose the roomy
    // upper side immediately, while still keeping the real 78pt frame close.
    let forecastAwareOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: NSRect(x: 720, y: 150, width: 0, height: 22),
        visibleFrames: [primary],
        fallback: primary
    )
    let leftCaret = NSRect(x: -640, y: 520, width: 0, height: 22)
    let leftScreenOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: leftCaret,
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let rightEdgeOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: NSRect(x: 1438, y: 520, width: 0, height: 22),
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let maximumHeightOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: NSRect(
            x: openingFrame.minX,
            y: openingFrame.minY,
            width: openingFrame.width,
            height: BufferWindowGeometry.height(
                expanded: true,
                mode: .derived(targetRows: 3)
            )
        ),
        targetRect: NSRect(x: 720, y: 700, width: 0, height: 22),
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let noTargetOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: nil,
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let invalidTargetOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: NSRect(x: CGFloat.nan, y: 300, width: 0, height: 22),
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let offscreenTargetOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: openingFrame,
        targetRect: NSRect(x: 4000, y: 300, width: 0, height: 22),
        visibleFrames: [primary, secondary, leftSecondary],
        fallback: primary
    )
    let manualOrigin = NSPoint(x: 160, y: 240)
    let transientPersistence = BufferWindowGeometry.canonicalPersistedFrame(
        belowCaret.frame,
        persistedOrigin: manualOrigin,
        transientOpeningOrigin: true
    )
    let userPersistence = BufferWindowGeometry.canonicalPersistedFrame(
        belowCaret.frame,
        persistedOrigin: manualOrigin,
        transientOpeningOrigin: false
    )
    guard BufferWindowGeometry.isPlausibleInputAnchor(
            middleCaret,
            visibleFrames: [primary]
          ),
          !BufferWindowGeometry.isPlausibleInputAnchor(.zero,
                                                       visibleFrames: [primary]),
          !BufferWindowGeometry.isPlausibleInputAnchor(
            NSRect(x: 200, y: 200, width: 0, height: 300),
            visibleFrames: [primary]
          ),
          belowCaret.side == .belowTarget,
          belowCaret.frame.maxY
            == middleCaret.minY - BufferWindowGeometry.inputAnchorGap,
          belowResizes.allSatisfy({
              $0.maxY == middleCaret.minY - BufferWindowGeometry.inputAnchorGap
                  && !$0.intersects(middleCaret)
          }),
          belowCaret.frame.midX == middleCaret.midX,
          aboveCaret.side == .aboveTarget,
          aboveCaret.frame.minY
            == bottomCaret.maxY + BufferWindowGeometry.inputAnchorGap,
          aboveResizes.allSatisfy({
              $0.minY == bottomCaret.maxY + BufferWindowGeometry.inputAnchorGap
                  && !$0.intersects(bottomCaret)
          }),
          belowCandidateOrigin.y + belowCandidateSize.height
            == belowAnchor.minY - 6,
          aboveCandidateOrigin.y == aboveAnchor.maxY + 6,
          strictUnavailableAboveCandidate == nil,
          strictUnavailableBelowCandidate == nil,
          forecastAwareOpening.side == .aboveTarget,
          forecastAwareOpening.frame.minY == 150 + 22
            + BufferWindowGeometry.inputAnchorGap,
          !aboveCaret.frame.intersects(bottomCaret),
          leftScreenOpening.side == .belowTarget,
          leftSecondary.contains(leftScreenOpening.frame),
          rightEdgeOpening.frame.maxX <= primary.maxX
            - BufferWindowGeometry.screenSafetyMargin,
          maximumHeightOpening.side == .belowTarget,
          maximumHeightOpening.frame.height
            == BufferWindowGeometry.height(
                expanded: true,
                mode: .derived(targetRows: 3)
            ),
          noTargetOpening.side == .bottomFallback,
          noTargetOpening.frame.midX == primary.midX,
          noTargetOpening.frame.minY > primary.minY,
          noTargetOpening.frame.midY < primary.midY,
          invalidTargetOpening == noTargetOpening,
          offscreenTargetOpening == noTargetOpening,
          transientPersistence.origin == manualOrigin,
          transientPersistence.width == belowCaret.frame.width,
          transientPersistence.height == BufferWindowGeometry.expandedHeight,
          userPersistence.origin == belowCaret.frame.origin else {
        print("FAILED: focus-aware workbench opening geometry",
              belowCaret, aboveCaret, leftScreenOpening, rightEdgeOpening,
              maximumHeightOpening, noTargetOpening,
              invalidTargetOpening, offscreenTargetOpening)
        return false
    }

    let offscreen = NSRect(x: 4000, y: -900, width: 680, height: 230)
    let restored = BufferWindowGeometry.clampedFrame(
        offscreen,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        visibleFrames: [primary, secondary],
        fallback: primary
    )
    guard primary.contains(restored),
          restored.width >= BufferWindowGeometry.standardMinimumWidth,
          restored.height == BufferWindowGeometry.expandedHeight else {
        print("FAILED: offscreen frame was not restored to fallback screen", restored)
        return false
    }

    let legacyWorkbench = NSRect(x: 120, y: 220, width: 680, height: 340)
    let migrated = BufferWindowGeometry.clampedFrame(
        legacyWorkbench,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        visibleFrames: [primary],
        fallback: primary
    )
    let anchor = BufferWindowGeometry.candidateAnchor(for: migrated)
    let candidateSize = NSSize(width: 420, height: 60)
    let belowBar = CandidatePanelGeometry.origin(anchor: anchor,
                                                  panelSize: candidateSize,
                                                  visibleFrame: primary)
    let bottomPanel = BufferWindowGeometry.clampedFrame(
        NSRect(x: 120, y: 8, width: 600,
               height: BufferWindowGeometry.collapsedHeight),
        expanded: true,
        visibleFrames: [primary],
        fallback: primary
    )
    let bottomAnchor = BufferWindowGeometry.candidateAnchor(for: bottomPanel)
    let flippedAbove = CandidatePanelGeometry.origin(anchor: bottomAnchor,
                                                      panelSize: candidateSize,
                                                      visibleFrame: primary)
    let rightEdgeAnchor = NSRect(x: 1430, y: 400, width: 4, height: 4)
    let clampedCandidate = CandidatePanelGeometry.origin(anchor: rightEdgeAnchor,
                                                         panelSize: candidateSize,
                                                         visibleFrame: primary)
    let oldCompact = NSRect(x: 180, y: 240, width: 680, height: 52)
    let migratedOldCompact = BufferWindowGeometry.clampedFrame(
        oldCompact,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        visibleFrames: [primary],
        fallback: primary
    )
    let legacyCollapsed = BufferWindowGeometry.clampedFrame(
        migratedOldCompact,
        expanded: false,
        visibleFrames: [primary],
        fallback: primary
    )
    let translationExpanded = BufferWindowGeometry.clampedFrame(
        migratedOldCompact,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        mode: .translation,
        visibleFrames: [primary],
        fallback: primary
    )
    let compactDerivedExpanded = BufferWindowGeometry.clampedFrame(
        translationExpanded,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        mode: .singleDerived,
        visibleFrames: [primary],
        fallback: primary
    )
    let streamCandidatesTwoExpanded = BufferWindowGeometry.clampedFrame(
        translationExpanded,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        mode: .derived(targetRows: 2),
        visibleFrames: [primary],
        fallback: primary
    )
    let streamCandidatesExpanded = BufferWindowGeometry.clampedFrame(
        streamCandidatesTwoExpanded,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        mode: .derived(targetRows: 3),
        visibleFrames: [primary],
        fallback: primary
    )
    let standardAfterTranslation = BufferWindowGeometry.clampedFrame(
        translationExpanded,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        mode: .standard,
        visibleFrames: [primary],
        fallback: primary
    )
    let standardCompactAnchor = BufferWindowGeometry.candidateAnchor(for: migratedOldCompact)
    let belowStandardCompact = CandidatePanelGeometry.origin(anchor: standardCompactAnchor,
                                                              panelSize: candidateSize,
                                                              visibleFrame: primary)
    let translatedAnchor = BufferWindowGeometry.candidateAnchor(for: translationExpanded)
    let belowTranslatedBar = CandidatePanelGeometry.origin(anchor: translatedAnchor,
                                                            panelSize: candidateSize,
                                                            visibleFrame: primary)
    let aligned = BufferWindowGeometry.pixelAligned(
        NSRect(x: 10.24, y: 20.26, width: 680.24, height: 44),
        scale: 2
    )
    guard migrated.height == BufferWindowGeometry.expandedHeight,
          migrated.maxY == legacyWorkbench.maxY,
          migratedOldCompact.minY == oldCompact.minY,
          migratedOldCompact.height == BufferWindowGeometry.expandedHeight,
          legacyCollapsed.height == BufferWindowGeometry.collapsedHeight,
          legacyCollapsed.minY == migratedOldCompact.minY,
          translationExpanded.height == BufferWindowGeometry.translationExpandedHeight,
          translationExpanded.minY == migratedOldCompact.minY,
          compactDerivedExpanded.height == BufferWindowGeometry.expandedHeight,
          compactDerivedExpanded.minY == translationExpanded.minY,
          streamCandidatesTwoExpanded.height
            == BufferWindowGeometry.translationExpandedHeight
                + BufferInlineView.additionalTranslationTargetRowHeight,
          streamCandidatesTwoExpanded.minY == translationExpanded.minY,
          streamCandidatesExpanded.height
            == BufferWindowGeometry.translationExpandedHeight
                + BufferInlineView.additionalTranslationTargetRowHeight * 2,
          streamCandidatesExpanded.minY == streamCandidatesTwoExpanded.minY,
          standardAfterTranslation.height == BufferWindowGeometry.expandedHeight,
          standardAfterTranslation.minY == translationExpanded.minY,
          anchor.minY == migrated.minY,
          anchor.maxY == migrated.maxY,
          anchor.minX > migrated.minX,
          anchor.maxX < migrated.maxX,
          belowBar.y + candidateSize.height < anchor.minY,
          belowTranslatedBar.y == belowStandardCompact.y,
          flippedAbove.y > bottomAnchor.maxY,
          clampedCandidate.x + candidateSize.width <= primary.maxX - 6,
          aligned.minX * 2 == (aligned.minX * 2).rounded(),
          aligned.minY * 2 == (aligned.minY * 2).rounded() else {
        print("FAILED: legacy workbench did not migrate to a compact anchored bar", migrated, anchor)
        return false
    }

    let oversized = NSRect(x: 1500, y: 40, width: 3000, height: 2000)
    let fitted = BufferWindowGeometry.clampedFrame(
        oversized,
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        visibleFrames: [primary, secondary],
        fallback: primary
    )
    guard fitted.width <= secondary.width,
          fitted.height == BufferWindowGeometry.expandedHeight,
          secondary.contains(fitted) else {
        print("FAILED: oversized frame was not clamped to its screen", fitted)
        return false
    }

    let tiny = NSRect(x: -480, y: 0, width: 480, height: 160)
    let tinyFitted = BufferWindowGeometry.clampedFrame(
        NSRect(x: -900, y: -500, width: 680, height: 230),
        expanded: BufferWorkbenchLayout.toolbarAlwaysExpanded,
        visibleFrames: [tiny],
        fallback: tiny
    )
    let tinyOpening = BufferWindowGeometry.openingPlacement(
        currentFrame: NSRect(
            x: -400,
            y: 20,
            width: 680,
            height: BufferWindowGeometry.height(
                expanded: true,
                mode: .derived(targetRows: 3)
            )
        ),
        targetRect: NSRect(x: -240, y: 70, width: 0, height: 20),
        visibleFrames: [tiny],
        fallback: tiny
    )
    guard tiny.contains(tinyFitted),
          tinyFitted.width <= tiny.width,
          tinyFitted.height <= tiny.height,
          tiny.contains(tinyOpening.frame),
          tinyOpening.side != .bottomFallback else {
        print("FAILED: tiny visible frame clamp", tinyFitted, tinyOpening)
        return false
    }

    print("buffer window smoke: OK")
    return true
}

func runMarineBridgeSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) Marine bridge smoke test ==")
    let model = BufferModel.shared
    let oldEnabled = model.enabled
    let oldOnChange = model.onChange
    defer {
        model.discardForPrivacy()
        model.enabled = oldEnabled
        model.onChange = oldOnChange
    }

    model.onChange = nil
    model.discardForPrivacy()

    MarineBridge.shared.checkForFocusedIntent()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let block = model.blocks.first {
            let expected = ProcessInfo.processInfo.environment["MARINE_BRIDGE_SMOKE_EXPECTED"]
            if let expected, !expected.isEmpty, block.text != expected {
                print("FAILED: loaded unexpected draft", "got=\(block.text)", "expected=\(expected)")
                return false
            }
            guard model.active, model.loadingMessage == nil else {
                print("FAILED: draft loaded but buffer state is inconsistent",
                      "active=\(model.active)",
                      "loading=\(model.loadingMessage ?? "nil")")
                return false
            }
            print("loaded draft chars:", block.text.count)
            print("marine bridge smoke: OK")
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    print("FAILED: no Marine draft loaded",
          "loading=\(model.loadingMessage ?? "nil")",
          "active=\(model.active)",
          "blocks=\(model.blocks.count)")
    return false
}

// MARK: - Remote-typing transport smoke (crypto + framing + loopback socket)

func runRemoteSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) remote-typing smoke test ==")
    print("identity fp:", RemoteIdentity.fingerprint)   // must be stable across launches (Keychain)

    // 1) ECDH session key: two identities derive the SAME key; and AES-GCM
    //    round-trips only under that key.
    let a = Curve25519.KeyAgreement.PrivateKey()
    let b = Curve25519.KeyAgreement.PrivateKey()
    let nA = RemoteCrypto.randomNonce(), nB = RemoteCrypto.randomNonce()
    func derive(_ priv: Curve25519.KeyAgreement.PrivateKey, _ peer: Curve25519.KeyAgreement.PublicKey) -> SymmetricKey {
        let shared = try! priv.sharedSecretFromKeyAgreement(with: peer)
        let salt = nA.lexicographicallyPrecedes(nB) ? nA + nB : nB + nA
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                              sharedInfo: Data("etinput-remote-session-v1".utf8), outputByteCount: 32)
    }
    let keyA = derive(a, b.publicKey)
    let keyB = derive(b, a.publicKey)
    let wrong = SymmetricKey(size: .bits256)
    let plain = Data("你好 hello".utf8)
    guard keyA.withUnsafeBytes({ Data($0) }) == keyB.withUnsafeBytes({ Data($0) }),
          let sealed = RemoteCrypto.seal(plain, key: keyA),
          RemoteCrypto.open(sealed, key: keyB) == plain,
          RemoteCrypto.open(sealed, key: wrong) == nil else {
        print("FAILED: ECDH key agreement / AES-GCM"); return false
    }
    print("ECDH + crypto: OK")

    // 2) Framing: plaintext hello + sealed message, streaming reassembly.
    let hello = HelloMessage(deviceID: "A", name: "阿 Mac", pubKey: "cHViaw==", nonce: "bm9uYw==")
    guard let hf = RemoteFrame.encodeHello(hello),
          let sf = RemoteFrame.encodeSealed(.init(kind: .text, seq: 7, text: "世界B"), key: keyA) else {
        print("FAILED: frame encode"); return false
    }
    let dec = RemoteFrame.Decoder()
    var helloOK = false, textOK = false
    for byte in (hf + sf) {
        guard let frames = dec.feed(Data([byte])) else { print("FAILED: decoder dropped"); return false }
        for f in frames {
            switch f.type {
            case .hello:
                if let h = try? JSONDecoder().decode(HelloMessage.self, from: f.payload),
                   h.deviceID == "A", h.name == "阿 Mac" { helloOK = true }
            case .sealed:
                if let j = RemoteCrypto.open(f.payload, key: keyB),
                   let m = try? JSONDecoder().decode(SealedMessage.self, from: j),
                   m.kind == .text, m.seq == 7, m.text == "世界B" { textOK = true }
            }
        }
    }
    guard helloOK, textOK else { print("FAILED: framing hello=\(helloOK) text=\(textOK)"); return false }
    print("framing (hello + sealed, streaming): OK")

    // 3) Loopback transport: real NWListener <- NWConnection over 127.0.0.1.
    let q = DispatchQueue(label: "remote-smoke")
    let listener: NWListener
    do { listener = try NWListener(using: .tcp) } catch { print("FAILED: listener \(error)"); return false }
    let ldec = RemoteFrame.Decoder()
    let recvSem = DispatchSemaphore(value: 0)
    var received: String?
    listener.newConnectionHandler = { conn in
        conn.stateUpdateHandler = { st in
            guard case .ready = st else { return }
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
                    if let data, !data.isEmpty, let frames = ldec.feed(data) {
                        for f in frames where f.type == .sealed {
                            if let j = RemoteCrypto.open(f.payload, key: keyA),
                               let m = try? JSONDecoder().decode(SealedMessage.self, from: j) {
                                received = m.text; recvSem.signal()
                            }
                        }
                    }
                    if err == nil && !done { loop() }
                }
            }
            loop()
        }
        conn.start(queue: q)
    }
    let portSem = DispatchSemaphore(value: 0)
    var port: NWEndpoint.Port?
    listener.stateUpdateHandler = { st in
        switch st {
        case .ready: port = listener.port; portSem.signal()
        case .failed: portSem.signal()
        default: break
        }
    }
    listener.start(queue: q)
    guard portSem.wait(timeout: .now() + 5) == .success, let port else {
        print("FAILED: listener did not become ready"); listener.cancel(); return false
    }
    let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    conn.stateUpdateHandler = { st in
        guard case .ready = st else { return }
        if let frame = RemoteFrame.encodeSealed(.init(kind: .text, seq: 1, text: "远程你好"), key: keyA) {
            conn.send(content: frame, completion: .idempotent)
        }
    }
    conn.start(queue: q)
    let ok = recvSem.wait(timeout: .now() + 5) == .success
    conn.cancel(); listener.cancel()
    guard ok, received == "远程你好" else {
        print("FAILED: loopback transport received=\(received ?? "nil")"); return false
    }
    print("loopback transport: OK")

    print("remote smoke: OK")
    return true
}

/// Pins the "unsupported interval" rule behind the candidate-window size controls:
/// a dependent metric (button height, candidate glyph, index label) can only be
/// set as high as its container currently allows, because anything taller is
/// clipped or silently absorbed by the layout. A wrong verdict here means the
/// settings sliders would offer sizes that cannot render faithfully.
func runCandidateMetricsSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) candidate metrics smoke test ==")
    var ok = true
    func check(_ cond: Bool, _ msg: String) {
        if !cond { print("FAILED: \(msg)"); ok = false }
    }

    // The dependency chain must stay strip -> button -> candidate glyph -> label.
    check(CandidateWindowMetric.compactCandidateHeight.containerMetric?.metric == .compactStripHeight,
          "button height should be bounded by strip height")
    check(CandidateWindowMetric.candidateFontSize.containerMetric?.metric == .compactCandidateHeight,
          "candidate glyph should be bounded by button height")
    check(CandidateWindowMetric.labelFontSize.containerMetric?.metric == .candidateFontSize,
          "index label should be bounded by candidate glyph")
    for m in [CandidateWindowMetric.baseWidth, .compactStripHeight, .preeditHeight] {
        check(m.containerMetric == nil, "\(m.rawValue) should be a free container metric")
    }

    func vals(strip: Double, button: Double, glyph: Double, label: Double) -> [CandidateWindowMetric: Double] {
        [.baseWidth: 460, .preeditHeight: 20,
         .compactStripHeight: strip, .compactCandidateHeight: button,
         .candidateFontSize: glyph, .labelFontSize: label]
    }

    // Button ceiling tracks the strip (strip − 2), capped at its own max 44.
    check(CandidateWindowMetric.compactCandidateHeight
        .supportedRange(given: vals(strip: 32, button: 24, glyph: 16, label: 10)).upperBound == 30,
          "strip=32 should cap button height at 30")
    check(CandidateWindowMetric.compactCandidateHeight
        .supportedRange(given: vals(strip: 64, button: 24, glyph: 16, label: 10)).upperBound == 44,
          "strip=64 should allow the full 44 button")

    // Candidate glyph ceiling tracks the button with enough room for AppKit's
    // ascender/descender line box (24pt is roughly 30px tall on the system font).
    check(CandidateWindowMetric.candidateFontSize
        .supportedRange(given: vals(strip: 32, button: 22, glyph: 16, label: 10)).upperBound == 16,
          "button=22 should cap the candidate glyph at 16")
    check(CandidateWindowMetric.candidateFontSize
        .supportedRange(given: vals(strip: 64, button: 44, glyph: 16, label: 10)).upperBound == 24,
          "button=44 should allow the full 24 candidate glyph")

    let resolvedChain = CandidateWindowMetrics.resolvedValues(
        vals(strip: 32, button: 22, glyph: 24, label: 18)
    )
    check(resolvedChain[.compactCandidateHeight] == 22,
          "a supported button height should remain unchanged")
    check(resolvedChain[.candidateFontSize] == 16,
          "the full resolver should clamp candidate glyphs to their button")
    check(resolvedChain[.labelFontSize] == 16,
          "the full resolver should then clamp labels to the candidate glyph")
    check(CandidateLayout.candidateSeparatorRunWidth == 14,
          "preview and live candidate separators should occupy the same width")
    check(CandidateLayout.bufferActionMinWidth == 38,
          "preview and live buffer actions should share the same minimum width")

    // Exercise the real AppKit/CoreText hierarchy at normal, selected, maximum
    // font and extra-tall button sizes. The title view occupies a symmetric
    // content rect and the painted ink must stay centred within the button.
    let rendererCases: [(
        button: CGFloat,
        glyph: CGFloat,
        label: CGFloat,
        highlighted: Bool
    )] = [
        (24, 17, 10, false),
        (24, 17, 10, true),
        (30, 24, 18, true),
        (44, 24, 18, false),
    ]
    for rendererCase in rendererCases {
        let snapshot = CandidateWindow.textRendererSnapshotForSmoke(
            buttonHeight: rendererCase.button,
            candidateFontSize: rendererCase.glyph,
            labelFontSize: rendererCase.label,
            highlighted: rendererCase.highlighted
        )
        let prefix = "renderer \(Int(rendererCase.glyph))pt/\(Int(rendererCase.button))px"
        check(snapshot.nativeButtonTitleIsEmpty && snapshot.nativeAttributedTitleIsEmpty,
              "\(prefix) should not use NSButtonCell for text")
        let inset = CandidateLayout.compactCandidateHorizontalPadding / 2
        check(abs(snapshot.titleViewFrame.minX - inset) < 0.01
                && abs(snapshot.titleViewFrame.maxX
                    - (snapshot.buttonBounds.maxX - inset)) < 0.01
                && abs(snapshot.titleViewFrame.minY - snapshot.buttonBounds.minY) < 0.01
                && abs(snapshot.titleViewFrame.height - snapshot.buttonBounds.height) < 0.01,
              "\(prefix) title view should fill a symmetric button content rect")
        check(snapshot.buttonBounds.height + 0.01 >= ceil(snapshot.requiredLineHeight),
              "\(prefix) button \(snapshot.buttonBounds.height) should contain line box \(snapshot.requiredLineHeight)")
        check(snapshot.baselineCenterDelta < 0.01,
              "\(prefix) label and candidate visual centres should align")
        check(snapshot.titleViewHitTestIsNil,
              "\(prefix) title view should leave clicks to the button")
        check(snapshot.candidateGlyphPixelCount > 0,
              "\(prefix) should paint candidate glyphs")
        check(snapshot.horizontalInkCenterDelta <= 1.25,
              "\(prefix) horizontal ink delta \(snapshot.horizontalInkCenterDelta) should be centred")
        check(snapshot.verticalInkCenterDelta <= 1.25,
              "\(prefix) vertical ink delta \(snapshot.verticalInkCenterDelta) should be centred")
    }

    // Reproduce the live strip's tightest titles at the user's current sizing.
    // Rasterizing the real CoreText hierarchy catches both a missing lone CJK
    // glyph and an off-centre title that the roomy 180px case could conceal.
    let tightSingleGlyphCases: [(
        label: String,
        text: String,
        highlighted: Bool
    )] = [
        ("6", "现", false),
        ("", "现", true),
    ]
    for rendererCase in tightSingleGlyphCases {
        let snapshot = CandidateWindow.textRendererSnapshotForSmoke(
            buttonHeight: 24,
            candidateFontSize: 17,
            labelFontSize: 10,
            candidateText: rendererCase.text,
            label: rendererCase.label,
            usesTightWidth: true,
            highlighted: rendererCase.highlighted
        )
        let prefix = rendererCase.label.isEmpty
            ? "tight single glyph"
            : "tight labeled single glyph"
        check(snapshot.candidateGlyphPixelCount > 0,
              "\(prefix) should render candidate ink at its natural width")
        check(snapshot.horizontalInkCenterDelta <= 1.25,
              "\(prefix) should remain horizontally centred")
        check(snapshot.verticalInkCenterDelta <= 1.25,
              "\(prefix) should remain vertically centred")
    }

    // Index-label ceiling tracks the candidate glyph.
    check(CandidateWindowMetric.labelFontSize
        .supportedRange(given: vals(strip: 34, button: 24, glyph: 12, label: 10)).upperBound == 12,
          "candidate font=12 should cap the index label at 12")
    check(CandidateWindowMetric.labelFontSize
        .supportedRange(given: vals(strip: 34, button: 24, glyph: 24, label: 10)).upperBound == 18,
          "candidate font=24 should allow the index label up to 18")

    // The layout absorbs an over-tall button — the very reason the control forbids it.
    let over = CandidateWindowMetrics(baseWidth: 460, compactStripHeight: 32,
                                      compactCandidateHeight: 44, preeditHeight: 20,
                                      candidateFontSize: 16, labelFontSize: 10)
    check(CandidateLayout.candidateButtonHeight(over) <= 30,
          "an over-tall button must be clamped by the strip during layout")

    if ok { print("candidate metrics smoke: OK") }
    return ok
}

/// Guards the fixed day palette against regressions to dynamic semantic colors
/// or foregrounds that disappear on the small candidate/workbench typography.
func runThemeSmokeTest() -> Bool {
    print("== \(ProductIdentity.displayName) theme contrast smoke test ==")
    var ok = true
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            ok = false
        }
    }

    let day = RimeThemePalettes.day
    let textColors: [(String, UInt32)] = [
        ("primary", day.textPrimary),
        ("secondary", day.textSecondary),
        ("muted", day.textMuted),
    ]
    for (name, color) in textColors {
        let ratio = RimeColorContrast.ratio(
            foreground: color,
            background: day.candidateBackground
        )
        check(ratio >= 4.5, "day \(name) contrast \(ratio) should be >= 4.5")
    }

    let daySelectedTextRatio = RimeColorContrast.ratio(
        foreground: day.selectedCandidateText,
        background: day.selectedCandidateBackground
    )
    check(daySelectedTextRatio >= 4.5,
          "day selected text contrast \(daySelectedTextRatio) should be >= 4.5")
    let daySelectionRatio = RimeColorContrast.ratio(
        foreground: day.selectedCandidateBackground,
        background: day.candidateBackground
    )
    check(daySelectionRatio >= 3,
          "day selected background contrast \(daySelectionRatio) should be >= 3")

    let mutedBufferRatio = RimeColorContrast.ratio(
        foreground: day.textMuted,
        background: day.bufferBackgroundSecondary
    )
    check(mutedBufferRatio >= 4.5,
          "day muted workbench contrast \(mutedBufferRatio) should be >= 4.5")

    let borderRatio = RimeColorContrast.ratio(
        foreground: day.borderStrong,
        background: day.candidateBackground
    )
    check(borderRatio >= 3,
          "day strong border contrast \(borderRatio) should be >= 3")

    let night = RimeThemePalettes.night
    let nightTextColors: [(String, UInt32)] = [
        ("primary", night.textPrimary),
        ("secondary", night.textSecondary),
        ("muted", night.textMuted),
    ]
    for (name, color) in nightTextColors {
        let ratio = RimeColorContrast.ratio(
            foreground: color,
            background: night.candidateBackground
        )
        check(ratio >= 4.5, "night \(name) contrast \(ratio) should be >= 4.5")
    }

    let nightSelectedTextRatio = RimeColorContrast.ratio(
        foreground: night.selectedCandidateText,
        background: night.selectedCandidateBackground
    )
    check(nightSelectedTextRatio >= 4.5,
          "night selected text contrast \(nightSelectedTextRatio) should be >= 4.5")
    check(night.selectedCandidateText == 0xFFFFFF,
          "night selected candidate text should stay white")
    let nightSelectionRatio = RimeColorContrast.ratio(
        foreground: night.selectedCandidateBackground,
        background: night.candidateBackground
    )
    check(nightSelectionRatio >= 3,
          "night selected background contrast \(nightSelectionRatio) should be >= 3")

    let nightWorkbenchStatusRatio = RimeColorContrast.ratio(
        foreground: night.textSecondary,
        background: night.bufferBackground
    )
    check(nightWorkbenchStatusRatio >= 4.5,
          "night workbench status contrast \(nightWorkbenchStatusRatio) should be >= 4.5")

    let nightWorkbenchMutedRatio = RimeColorContrast.ratio(
        foreground: night.textMuted,
        background: night.bufferBackground
    )
    check(nightWorkbenchMutedRatio >= 4.5,
          "night muted workbench contrast \(nightWorkbenchMutedRatio) should be >= 4.5")

    let nightWorkbenchBorderRatio = RimeColorContrast.ratio(
        foreground: night.borderStrong,
        background: night.bufferBackground
    )
    check(nightWorkbenchBorderRatio >= 3,
          "night workbench border contrast \(nightWorkbenchBorderRatio) should be >= 3")

    check(RimeAppearanceMode.day.appKitAppearanceName(increasedContrast: false) == .aqua,
          "day mode should force Aqua")
    check(RimeAppearanceMode.night.appKitAppearanceName(increasedContrast: false) == .darkAqua,
          "night mode should force Dark Aqua")
    check(RimeAppearanceMode.day.appKitAppearanceName(increasedContrast: true)
            == .accessibilityHighContrastAqua,
          "day mode should preserve increased contrast")
    check(RimeAppearanceMode.night.appKitAppearanceName(increasedContrast: true)
            == .accessibilityHighContrastDarkAqua,
          "night mode should preserve increased contrast")

    if ok { print("theme contrast smoke: OK") }
    return ok
}
