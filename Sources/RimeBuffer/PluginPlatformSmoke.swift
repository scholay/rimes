import AppKit
import Foundation

private final class PluginRegistrySmokeBuiltIn: InternalPlugin {
    let descriptor: PluginDescriptor
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(rawID: String,
         capabilities: Set<PluginCapability> = [.settingsPage, .localStorage],
         contributesSettings: Bool = true) {
        descriptor = PluginDescriptor(
            key: PluginKey(domain: .builtIn, rawID: rawID),
            wireID: nil,
            name: "Smoke Built-in",
            symbolName: "puzzlepiece",
            version: "1",
            summary: "fixture",
            source: .builtIn,
            capabilities: capabilities,
            settings: contributesSettings ? PluginSettingsContribution(
                id: "smoke",
                title: "Smoke",
                symbolName: "puzzlepiece",
                subpages: [PluginSettingsSubpage(id: "overview", title: "Overview")]
            ) : nil,
            canUninstall: false
        )
    }

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func makeSettingsViewController(subpageID: String) -> NSViewController? { nil }
}

func runPluginPlatformSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: plugin platform \(message)")
        return false
    }

    let fileManager = FileManager.default
    let shippedBufferPluginIDs = Set(
        BuiltInPlugins.makeAll()
            .map(\.descriptor)
            .filter { $0.capabilities.contains(.bufferAction) }
            .map { $0.key.rawID }
    )
    guard shippedBufferPluginIDs == Set([
        BuiltInPluginID.appleTranslation,
        BuiltInPluginID.remarkable,
        BuiltInPluginID.streamInput,
        BuiltInPluginID.aiText,
    ]) else {
        return fail("shipped buffer plugin registry")
    }
    let shippedDescriptors = BuiltInPlugins.makeAll().map(\.descriptor)
    guard shippedDescriptors.allSatisfy({
        PluginVisualIdentity.resolvedSymbolName($0.symbolName) == $0.symbolName
    }) else {
        return fail("shipped plugin visual identity")
    }
    let fallbackSymbol = PluginVisualIdentity.resolvedSymbolName(nil)
    guard fallbackSymbol == PluginVisualIdentity.fallbackSymbolName,
          PluginVisualIdentity.resolvedSymbolName("   ") == fallbackSymbol,
          PluginVisualIdentity.resolvedSymbolName(
            "rimes.symbol.that.does.not.exist"
          ) == fallbackSymbol,
          let fallbackImage = PluginVisualIdentity.image(
            symbolName: "rimes.symbol.that.does.not.exist",
            accessibilityDescription: "Fallback",
            pointSize: 12
          ),
          fallbackImage.isTemplate,
          let defaultImage = PluginVisualIdentity.image(
            symbolName: PluginVisualIdentity.defaultWorkbenchSymbolName,
            accessibilityDescription: "Default",
            pointSize: 10
          ),
          defaultImage.isTemplate else {
        return fail("plugin symbol fallback")
    }
    let shippedAIPlugins = BuiltInPlugins.makeAll().filter {
        $0.descriptor.key.rawID == BuiltInPluginID.aiText
    }
    guard shippedAIPlugins.count == 1,
          shippedAIPlugins[0].descriptor.capabilities == [.bufferAction] else {
        return fail("unified AI buffer plugin")
    }
    let streamInputPlugins = BuiltInPlugins.makeAll().filter {
        $0.descriptor.key.rawID == BuiltInPluginID.streamInput
    }
    guard streamInputPlugins.count == 1,
          streamInputPlugins[0].descriptor.capabilities == [.bufferAction],
          streamInputPlugins[0].descriptor.canUninstall == false else {
        return fail("built-in stream input plugin")
    }
    let remarkablePlugins = BuiltInPlugins.makeAll().filter {
        $0.descriptor.key.rawID == BuiltInPluginID.remarkable
    }
    guard remarkablePlugins.count == 1,
          remarkablePlugins[0].descriptor.capabilities == [.bufferAction],
          remarkablePlugins[0].descriptor.canUninstall == false else {
        return fail("built-in Remarkable plugin")
    }

    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-plugin-platform-\(UUID().uuidString)", isDirectory: true
    )
    let defaultsName = "RimeBuffer.PluginPlatformSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: defaultsName) else {
        return fail("defaults suite")
    }
    defer {
        try? fileManager.removeItem(at: root)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    do {
        let externalRawID = "same-id"
        let externalDirectory = root.appendingPathComponent(externalRawID,
                                                            isDirectory: true)
        try fileManager.createDirectory(at: externalDirectory,
                                        withIntermediateDirectories: true)
        let manifest = """
        {
          "schemaVersion": 1,
          "id": "\(externalRawID)",
          "name": "Smoke External",
          "version": "1.0",
          "runtimeConfigPaths": ["~/Library/RimeBuffer/smoke.json"],
          "actions": [{
            "id": "run",
            "title": "Run",
            "symbol": "play",
            "statusPath": "/status",
            "invokePath": "/invoke",
            "modes": ["smoke"]
          }]
        }
        """
        try Data(manifest.utf8).write(
            to: externalDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let manager = ActionPluginManager(
            rootURL: root,
            stateURL: root.appendingPathComponent(".state.json")
        )
        let builtIn = PluginRegistrySmokeBuiltIn(rawID: externalRawID)
        let bufferBuiltIn = PluginRegistrySmokeBuiltIn(
            rawID: "translation-smoke",
            capabilities: [.bufferAction, .settingsPage],
            contributesSettings: true
        )
        let selection = BufferPluginSelectionStore(defaults: defaults)
        let registry = PluginRegistry(internalPlugins: [builtIn, bufferBuiltIn],
                                      defaults: defaults,
                                      externalManager: manager,
                                      bufferPluginSelection: selection)

        let externalKey = PluginKey(domain: .externalActionV1, rawID: externalRawID)
        let bufferBuiltInKey = PluginKey(domain: .builtIn,
                                         rawID: "translation-smoke")
        let nonBufferBuiltInKey = PluginKey(domain: .builtIn, rawID: externalRawID)
        let snapshot = registry.allPlugins()
        guard snapshot.count == 3,
              Set(snapshot.map(\.id)) == Set([
                PluginKey(domain: .builtIn, rawID: externalRawID),
                PluginKey(domain: .builtIn, rawID: "translation-smoke"),
                PluginKey(domain: .externalActionV1, rawID: externalRawID),
              ]),
              snapshot.first(where: { $0.id.domain == .externalActionV1 })?
                .descriptor.wireID == externalRawID,
              snapshot.first(where: { $0.id == externalKey })?
                .descriptor.symbolName == "play",
              builtIn.startCount == 1 else {
            return fail("namespaced discovery")
        }

        let menuEntries = BufferPluginMenuCatalog.entries(from: snapshot)
        guard menuEntries.first == BufferPluginMenuEntry(
                key: nil,
                title: "Default",
                symbolName: PluginVisualIdentity.defaultWorkbenchSymbolName
              ),
              Set(menuEntries.compactMap(\.key))
                == Set([bufferBuiltInKey, externalKey]),
              menuEntries.count == 3 else {
            return fail("enabled workbench menu catalog")
        }
        let disabledExternalSnapshot = snapshot.map { plugin in
            plugin.id == externalKey
                ? RegisteredPlugin(descriptor: plugin.descriptor, isEnabled: false)
                : plugin
        }
        guard BufferPluginMenuCatalog.entries(from: disabledExternalSnapshot)
                .compactMap(\.key) == [bufferBuiltInKey] else {
            return fail("disabled workbench plugin filtering")
        }

        selection.migrateDefaultIfNeeded(from: snapshot)
        guard selection.activeKey == externalKey,
              !selection.select(nonBufferBuiltInKey, among: snapshot) else {
            return fail("exclusive buffer plugin selection")
        }

        selection.reconcile(with: snapshot.filter { $0.descriptor.key != externalKey })
        guard selection.activeKey == externalKey else {
            return fail("temporarily missing external owner was forgotten")
        }

        let lateDefaultsName = "RimeBuffer.PluginPlatformLateSmoke.\(UUID().uuidString)"
        guard let lateDefaults = UserDefaults(suiteName: lateDefaultsName) else {
            return fail("late external defaults")
        }
        defer { lateDefaults.removePersistentDomain(forName: lateDefaultsName) }
        lateDefaults.removePersistentDomain(forName: lateDefaultsName)
        // The first selection implementation could leave this false sentinel
        // when Rime launched before Marine had installed its manifest.
        lateDefaults.set(false, forKey: "plugins.buffer.active.hasValue.v1")
        let lateSelection = BufferPluginSelectionStore(defaults: lateDefaults)
        let lateRoot = root.appendingPathComponent("late-plugins", isDirectory: true)
        let lateManager = ActionPluginManager(
            rootURL: lateRoot,
            stateURL: lateRoot.appendingPathComponent(".state.json")
        )
        let lateRegistry = PluginRegistry(
            internalPlugins: [],
            defaults: lateDefaults,
            externalManager: lateManager,
            bufferPluginSelection: lateSelection
        )
        lateSelection.migrateDefaultIfNeeded(from: lateRegistry.allPlugins())
        guard lateSelection.activeKey == nil,
              lateDefaults.bool(forKey: "plugins.buffer.active.semantics.v2") else {
            return fail("startup did not establish Default ownership")
        }
        let lateDirectory = lateRoot.appendingPathComponent("external-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: lateDirectory,
                                                withIntermediateDirectories: true)
        try Data(manifest.utf8).write(
            to: lateDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        NotificationCenter.default.post(
            name: .externalActionManifestSetDidChange,
            object: nil,
            userInfo: [ActionPluginManager.rootPathUserInfoKey: lateRoot.path]
        )
        guard lateSelection.activeKey == nil,
              lateRegistry.isEnabled(externalKey),
              lateSelection.select(externalKey, among: lateRegistry.allPlugins()),
              lateSelection.activeKey == externalKey else {
            return fail("late plugin install changed owner or could not be selected")
        }
        lateSelection.clear()
        lateSelection.migrateDefaultIfNeeded(from: snapshot)
        guard lateSelection.activeKey == nil else {
            return fail("explicit no-plugin choice was overwritten")
        }

        let explicitDefaultsName = "RimeBuffer.PluginPlatformExplicitNoneSmoke.\(UUID().uuidString)"
        guard let explicitDefaults = UserDefaults(suiteName: explicitDefaultsName) else {
            return fail("explicit-none defaults")
        }
        defer { explicitDefaults.removePersistentDomain(forName: explicitDefaultsName) }
        explicitDefaults.removePersistentDomain(forName: explicitDefaultsName)
        explicitDefaults.set(false, forKey: "plugins.buffer.active.hasValue.v1")
        let explicitSelection = BufferPluginSelectionStore(defaults: explicitDefaults)
        explicitSelection.clear()
        explicitSelection.migrateDefaultIfNeeded(from: snapshot)
        guard explicitSelection.activeKey == nil else {
            return fail("new explicit no-plugin choice did not block legacy repair")
        }

        do {
            try registry.setBufferPluginActive(true, for: bufferBuiltInKey)
            guard selection.activeKey == bufferBuiltInKey,
                  registry.isEnabled(externalKey),
                  registry.isEnabled(bufferBuiltInKey) else {
                return fail("switch to built-in owner")
            }

            try registry.setEnabled(false, for: externalKey)
            guard selection.activeKey == bufferBuiltInKey,
                  !registry.isEnabled(externalKey),
                  BufferPluginMenuCatalog.entries(from: registry.allPlugins())
                    .compactMap(\.key) == [bufferBuiltInKey] else {
                return fail("disabling inactive plugin changed owner")
            }
            try registry.setEnabled(true, for: externalKey)
            guard selection.activeKey == bufferBuiltInKey,
                  registry.isEnabled(externalKey),
                  Set(BufferPluginMenuCatalog.entries(from: registry.allPlugins())
                    .compactMap(\.key)) == Set([bufferBuiltInKey, externalKey]) else {
                return fail("re-enabling inactive plugin changed owner")
            }

            try registry.setBufferPluginActive(true, for: externalKey)
            guard selection.activeKey == externalKey,
                  registry.isEnabled(bufferBuiltInKey),
                  BufferPluginSelectionStore(defaults: defaults).activeKey == externalKey else {
                return fail("switch keeps previous plugin enabled")
            }

            try registry.setBufferPluginActive(false, for: externalKey)
            guard selection.activeKey == nil,
                  registry.isEnabled(externalKey) else {
                return fail("active switch off")
            }

            try registry.setEnabled(false, for: bufferBuiltInKey)
            guard !registry.isEnabled(bufferBuiltInKey) else {
                return fail("disabled built-in setup")
            }
            do {
                try registry.setBufferPluginActive(true, for: bufferBuiltInKey)
                return fail("disabled workbench plugin was selected")
            } catch BufferPluginActivationError.unavailable {
                guard selection.activeKey == nil,
                      !registry.isEnabled(bufferBuiltInKey) else {
                    return fail("stale selection changed enablement or owner")
                }
            }
            try registry.setEnabled(true, for: bufferBuiltInKey)
            guard registry.isEnabled(bufferBuiltInKey),
                  selection.activeKey == nil else {
                return fail("settings enablement changed active owner")
            }
            try registry.setBufferPluginActive(true, for: bufferBuiltInKey)
            guard selection.activeKey == bufferBuiltInKey else {
                return fail("enabled built-in owner selection")
            }

            try registry.setBufferPluginActive(false, for: externalKey)
            guard selection.activeKey == bufferBuiltInKey else {
                return fail("stale off preserves owner")
            }

            do {
                try registry.setBufferPluginActive(true,
                                                   for: nonBufferBuiltInKey)
                return fail("non-buffer activation accepted")
            } catch BufferPluginActivationError.unavailable {
                guard selection.activeKey == bufferBuiltInKey else {
                    return fail("failed activation changed owner")
                }
            }

            try registry.setEnabled(false, for: bufferBuiltInKey)
            guard selection.activeKey == nil,
                  !registry.isEnabled(bufferBuiltInKey),
                  !BufferPluginMenuCatalog.entries(from: registry.allPlugins())
                    .compactMap(\.key).contains(bufferBuiltInKey) else {
                return fail("disabling active built-in did not select Default")
            }
            try registry.setEnabled(true, for: bufferBuiltInKey)
            guard selection.activeKey == nil,
                  registry.isEnabled(bufferBuiltInKey) else {
                return fail("re-enabling built-in changed Default owner")
            }

            try registry.setBufferPluginActive(true, for: externalKey)
        } catch {
            return fail("buffer switch threw \(error.localizedDescription)")
        }

        let builtInKey = PluginKey(domain: .builtIn, rawID: externalRawID)
        try registry.setEnabled(false, for: builtInKey)
        guard !registry.isEnabled(builtInKey),
              builtIn.stopCount == 1,
              manager.isEnabled(pluginID: externalRawID),
              registry.enabledSettingsContributions().isEmpty else {
            return fail("built-in disable isolation")
        }

        try registry.setEnabled(false, for: externalKey)
        selection.reconcile(with: registry.allPlugins())
        guard !registry.isEnabled(externalKey),
              !manager.isEnabled(pluginID: externalRawID),
              selection.activeKey == nil,
              builtIn.stopCount == 1 else {
            return fail("external manager delegation")
        }

        try registry.setEnabled(true, for: builtInKey)
        guard registry.isEnabled(builtInKey),
              builtIn.startCount == 2,
              registry.enabledSettingsContributions().count == 1,
              registry.enabledSettingsContributions().allSatisfy({
                  $0.pluginKey != bufferBuiltInKey
              }),
              Set(registry.plugins(capability: .settingsPage).map(\.id))
                == Set([builtInKey, bufferBuiltInKey]) else {
            return fail("built-in re-enable")
        }

        let routes = try SettingsRouteCatalog(
            pluginContributions: registry.enabledSettingsContributions()
        )
        guard routes.extensionRoutes.map(\.id.rawValue) == ["extension.smoke"] else {
            return fail("settings contribution adapter")
        }

        print("plugin platform smoke OK")
        return true
    } catch {
        return fail("threw \(error.localizedDescription)")
    }
}
