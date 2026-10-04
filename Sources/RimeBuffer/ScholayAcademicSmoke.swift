import AppKit
import Foundation
import CryptoKit

private final class AcademicSmokeCancellation: AITextCancellable {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func cancel() { let callback = action; action = nil; callback?() }
}

private final class AcademicSmokeProvider: AITextProvider {
    let kind: AITextProviderKind = .codexCLI
    let availability: AITextProviderAvailability = .ready
    private(set) var request: AITextProviderRequest?
    private(set) var cancellationCount = 0
    private var completion:
        ((Result<[AITextProviderBlock], AITextProviderError>) -> Void)?

    func generate(
        _ request: AITextProviderRequest,
        onEvent: @escaping (AITextProviderEvent) -> Void,
        completion: @escaping (Result<[AITextProviderBlock], AITextProviderError>) -> Void
    ) -> any AITextCancellable {
        self.request = request
        self.completion = completion
        return AcademicSmokeCancellation { [weak self] in self?.cancellationCount += 1 }
    }

    func finish(_ text: String) {
        completion?(.success([
            AITextProviderBlock(index: 0, text: text, title: nil),
        ]))
    }
}

private final class AcademicPackageDownloader: ActionPluginManifestDownloading {
    let data: Data
    init(_ data: Data) { self.data = data }
    func downloadManifest(from url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(.success(data))
    }
}

private final class AcademicPackageRuntime: InternalPlugin {
    let workspace: ScholayAcademicWorkspace
    let descriptor: PluginDescriptor
    init(_ workspace: ScholayAcademicWorkspace, entry: PresetBufferPluginCatalogEntry) {
        self.workspace = workspace
        descriptor = PluginDescriptor(key: .init(domain: .builtIn, rawID: entry.id),
            wireID: nil, name: entry.nameZH, symbolName: "wand.and.stars",
            version: entry.version, summary: entry.summaryZH, source: .builtIn,
            capabilities: [.bufferAction], settings: nil, canUninstall: true)
    }
    func start() { workspace.start() }
    func stop() { workspace.stop() }
    func makeSettingsViewController(subpageID: String) -> NSViewController? { nil }
}

func runAcademicPackageLifecycleSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: academic package lifecycle \(message)")
        return false
    }
    let suite = "AcademicPackageLifecycle.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite),
          let stock = PresetBufferPluginCatalog.entry(id: BuiltInPluginID.polisher),
          let packaged = PresetBufferPluginInstallationStore.bundledPackageData(id: stock.id) else {
        return fail("package fixture unavailable")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    do {
        var object = try JSONSerialization.jsonObject(with: packaged) as! [String: Any]
        // The sentinel exists only in downloaded bytes, proving the runtime is
        // reading package content rather than a compiled prompt or ID-only grant.
        object["contribution"] = ["type": "ai.prompt.v1", "instructions": ["default": "PACKAGE_SENTINEL: preserve the user's meaning."]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = PresetBufferPluginCatalogEntry(id: stock.id, nameZH: stock.nameZH,
            nameEN: stock.nameEN, version: stock.version, summaryZH: stock.summaryZH,
            summaryEN: stock.summaryEN, producerID: stock.producerID,
            defaultInstalled: false, defaultEnabled: false,
            downloadAssetName: stock.downloadAssetName, sha256: digest)
        let store = PresetBufferPluginInstallationStore(defaults: defaults,
            rootURL: root.appendingPathComponent("packages"), downloader: AcademicPackageDownloader(data),
            completionQueue: .main, hostVersion: "1.1.0", bundledPackageDataProvider: { _ in data },
            catalogEntries: [entry])
        store.bootstrap(hadLegacyEnablement: false, legacyDisabledIDs: [])
        func install() throws {
            var result: Result<PresetBufferPluginCatalogEntry, Error>?
            store.install(id: entry.id) { result = $0 }
            let deadline = Date().addingTimeInterval(10)
            while result == nil, Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            guard let result else { throw CocoaError(.fileReadUnknown) }
            _ = try result.get()
        }
        try install()
        guard store.isInstalled(id: entry.id), !store.isOptionalEnabled(id: entry.id),
              (try? store.instruction(id: entry.id)) == nil else { return fail("new install must remain off") }

        let model = BufferModel()
        model.append("Original academic text.")
        let provider = AcademicSmokeProvider()
        let selection = BufferPluginSelectionStore(defaults: defaults)
        let key = PluginKey(domain: .builtIn, rawID: entry.id)
        let workspace = ScholayAcademicWorkspace(kind: .polisher, sourceModel: model,
            connectors: AITextConnectorRegistry(providers: [provider]),
            options: ScholayAcademicOptions(defaults: defaults),
            isSelected: { selection.isSelected(key) },
            instructionResolver: { _, _ in try? store.instruction(id: entry.id) },
            selectionResolver: { kind in
                AITextGenerationSelection(connectorKind: kind, modelID: nil, mode: .direct,
                                          destination: .inline, format: .plain)
            })
        let runtime = AcademicPackageRuntime(workspace, entry: entry)
        let registry = PluginRegistry(internalPlugins: [runtime], defaults: defaults,
            externalManager: ActionPluginManager(rootURL: root.appendingPathComponent("external"),
                                                  stateURL: root.appendingPathComponent("external-state.json")),
            bufferPluginSelection: selection, presetInstallationStore: store)
        defer { workspace.stop() }
        defaults.set("retained", forKey: "user.plugin.preference")
        try registry.setEnabled(true, for: key)
        guard selection.activeKey == nil else { return fail("enablement selected the plugin implicitly") }
        try registry.setBufferPluginActive(true, for: key)
        guard workspace.generate(),
              provider.request?.preparedPrompt?.contains("PACKAGE_SENTINEL") == true,
              provider.request?.preparedPrompt?.contains(model.stagedText) == true else {
            return fail("downloaded instruction did not enter the real generation path")
        }
        provider.finish("Polished result.")
        guard workspace.deliveryPendingBlocks.first?.text == "Polished result." else { return fail("result unavailable") }
        try registry.setEnabled(false, for: key)
        guard selection.activeKey == nil, workspace.deliveryPendingBlocks.isEmpty,
              (try? store.instruction(id: entry.id)) == nil else { return fail("disable did not revoke execution") }

        try registry.setEnabled(true, for: key)
        try registry.setBufferPluginActive(true, for: key)
        guard workspace.generate() else { return fail("restart request") }
        try registry.uninstallInternalPlugin(key)
        provider.finish("Late result after uninstall.")
        guard !store.isInstalled(id: entry.id), !registry.isEnabled(key),
              provider.cancellationCount > 0, workspace.deliveryPendingBlocks.isEmpty,
              model.stagedText == "Original academic text.",
              defaults.string(forKey: "user.plugin.preference") == "retained" else {
            return fail("uninstall failed to cancel, reject late output, or preserve user data")
        }
        try install()
        guard store.isInstalled(id: entry.id), !registry.isEnabled(key),
              !store.isOptionalEnabled(id: entry.id) else { return fail("reinstall reused revoked authorization") }
        try registry.setEnabled(true, for: key)
        let path = root.appendingPathComponent("packages/\(entry.id)/manifest.json")
        try Data("corrupt".utf8).write(to: path)
        guard !store.isInstalled(id: entry.id), (try? store.instruction(id: entry.id)) == nil else {
            return fail("corrupt installed content was executed")
        }

        let legacySuite = suite + ".legacy"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else { return fail("legacy defaults") }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        legacyDefaults.set(true, forKey: "plugins.internal.presetDistribution.migrated.v1")
        let legacyStore = PresetBufferPluginInstallationStore(defaults: legacyDefaults,
            rootURL: root.appendingPathComponent("legacy"), hostVersion: "1.1.0",
            bundledPackageDataProvider: { _ in data }, catalogEntries: [entry])
        legacyStore.bootstrap(hadLegacyEnablement: true, legacyDisabledIDs: [])
        guard legacyStore.isOptionalEnabled(id: entry.id),
              try legacyStore.instruction(id: entry.id).contains("PACKAGE_SENTINEL") else {
            return fail("1.0 profile lost its installed plugin during migration")
        }
        try legacyStore.uninstall(id: entry.id)
        legacyStore.bootstrap(hadLegacyEnablement: true, legacyDisabledIDs: [])
        guard !legacyStore.isInstalled(id: entry.id) else { return fail("migration undid explicit uninstall") }
    } catch { return fail("\(error)") }
    print("academic package lifecycle: OK")
    return true
}

func runScholayAcademicSmokeTest() -> Bool {
    func fail(_ reason: String) -> Bool {
        print("FAILED: academic plugins \(reason)")
        return false
    }
    let entries = BuiltInPlugins.makeAll().map(\.descriptor)
    for (id, name) in [
        (BuiltInPluginID.codexCLI, "OpenAI"),
        (BuiltInPluginID.claudeCodeCLI, "Anthropic"),
        (BuiltInPluginID.scholay, "Scholay"),
        (BuiltInPluginID.polisher, "Scholay"),
        (BuiltInPluginID.latex, "Scholay"),
    ] {
        guard entries.first(where: { $0.key.rawID == id })?.producerName
            == name else { return fail("producer \(id)") }
    }

    let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
    )!
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(
        "ScholayAcademicSmoke.\(UUID())"
    ))
    pasteboard.declareTypes([.png], owner: nil)
    guard pasteboard.setData(png, forType: .png),
          BufferImagePasteboard.read(pasteboard) != nil else {
        return fail("PNG clipboard decode")
    }
    let model = BufferModel()
    let attachment = BufferModel.ImageAttachment(
        pngData: png, pixelWidth: 1, pixelHeight: 1
    )
    guard model.insertPastedImage(attachment) != nil,
          model.stagedText.isEmpty,
          model.pendingDeliveryBlocks.isEmpty,
          !AITextSourcePolicy.accepts(model.blocks),
          AITextSourcePolicy.accepts(model.blocks, allowImages: true) else {
        return fail("image remains non-text and cannot be delivered")
    }

    let request: URLRequest
    do {
        request = try AITextOpenAIRequestBuilder.makeRequest(
            configuration: OpenAICompatibleConfiguration(
                baseURL: "https://example.org/v1", model: "vision",
                apiKey: "test-key"
            ),
            sourceText: "", preparedPrompt: "Transcribe formula",
            imageInputs: [AITextImageInput(pngData: png)]
        )
    } catch { return fail("vision request: \(error)") }
    guard let body = request.httpBody,
          let envelope = try? JSONSerialization.jsonObject(with: body)
            as? [String: Any],
          let messages = envelope["messages"] as? [[String: Any]],
          let content = messages.last?["content"] as? [[String: Any]],
          content.contains(where: { $0["type"] as? String == "image_url" })
    else { return fail("image transport envelope") }

    let suite = "ScholayAcademicSmoke.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else {
        return fail("defaults")
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let options = ScholayAcademicOptions(defaults: defaults)
    options.selectLatexMode(.png)
    let provider = AcademicSmokeProvider()
    let connectors = AITextConnectorRegistry(providers: [provider])
    let workspace = ScholayAcademicWorkspace(
        kind: .latex, sourceModel: model, connectors: connectors,
        options: options, isSelected: { true },
        instructionResolver: { _, _ in "Transcribe the image into LaTeX." },
        selectionResolver: { kind in
            AITextGenerationSelection(
                connectorKind: kind, modelID: nil, mode: .direct,
                destination: .inline, format: .plain
            )
        }
    )
    workspace.start()
    defer { workspace.stop() }
    var protectionNotifications = 0
    let protectionObserver = NotificationCenter.default.addObserver(
        forName: .derivedBufferWorkspaceDidChange,
        object: workspace, queue: nil
    ) { _ in protectionNotifications += 1 }
    defer { NotificationCenter.default.removeObserver(protectionObserver) }
    workspace.setProtected(false)
    guard protectionNotifications == 0 else {
        return fail("unchanged protection retriggered refresh")
    }
    workspace.setProtected(true)
    workspace.setProtected(true)
    guard protectionNotifications == 1, !workspace.canGenerate else {
        return fail("protection notification repeated")
    }
    workspace.setProtected(false)
    guard protectionNotifications == 2 else {
        return fail("protection release notification")
    }
    guard workspace.canGenerate, workspace.generate(),
          provider.request?.imageInputs == [AITextImageInput(pngData: png)]
    else { return fail("PNG generation request") }
    provider.finish("x^2 + y^2 = z^2")
    guard workspace.deliveryPendingBlocks.first?.text == "x^2 + y^2 = z^2"
    else { return fail("LaTeX result delivery") }
    guard model.removeLastCharacter(), model.blocks.isEmpty,
          workspace.deliveryPendingBlocks.isEmpty else {
        return fail("backspace removes image card and invalidates result")
    }
    print("scholay academic smoke: OK")
    return runAcademicPackageLifecycleSmokeTest()
}
