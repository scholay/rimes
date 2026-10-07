import Foundation

/// Exercises catalog membership and persisted schema identity without opening
/// the real user's engine, defaults domain, or scheme files.
func runExternalSchemaSmokeTest() -> Bool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("rimes-external-schema-\(UUID().uuidString)")
    let suite = "RIMES.ExternalSchemaSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return false }
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    do {
        let catalog = InputSchemaCatalog.options(deployedSchemas: [
            ("flypy", "小鹤音形"), ("flypy", "重复"),
            ("melt_eng", "依赖"), ("radical_pinyin", "反查"),
            ("rimes_chord_stale", "过期并击"), ("../escape", "越界"),
        ])
        guard catalog.filter({ $0.id == "flypy" }).count == 1,
              catalog.first(where: { $0.id == "flypy" })?.name == "小鹤音形",
              catalog.contains(where: { $0.id == "double_pinyin_flypy" && $0.name == "小鹤双拼" }),
              !catalog.contains(where: { ["melt_eng", "radical_pinyin", "rimes_chord_stale", "../escape"].contains($0.id) }) else {
            print("FAILED: external schema names, membership or dependency gate")
            return false
        }

        let custom = RuntimeInputProfile(configuration: .defaultValue,
                                        schemaID: "flypy", lexiconFamily: .chinese)
        var externalAvailable = true
        let lookup: (String) -> RuntimeInputProfile? = { id in
            id == "flypy" ? (externalAvailable ? custom : nil)
                : InputConfigurationResolver.profile(schemaID: id)
        }
        let chord = ChordExtensionStore(defaults: defaults)
        let selection = InputConfigurationStore(defaults: defaults,
            chordExtensionStore: chord, schemaProfile: lookup)
        guard selection.select(schemaID: "flypy"),
              selection.selectedSchemaID == "flypy",
              selection.runtimeProfile.schemaID == "flypy",
              selection.configuration.keyingMode == .sequential,
              defaults.string(forKey: "preferredSchema") == "flypy",
              !chord.isEnabled else {
            print("FAILED: external schema selection or concrete runtime identity")
            return false
        }
        let relaunched = InputConfigurationStore(defaults: defaults,
            chordExtensionStore: chord, schemaProfile: lookup)
        guard relaunched.selectedSchemaID == "flypy",
              relaunched.lastOrdinarySchemaID == "flypy",
              relaunched.adoptRuntimeSchema("flypy"),
              relaunched.select(schemaID: ChordExtensionStore.schemaID),
              relaunched.fallBackFromChordScheme(),
              relaunched.selectedSchemaID == "flypy" else {
            print("FAILED: external schema restart, F4 adoption or chord fallback")
            return false
        }
        externalAvailable = false
        guard relaunched.selectedSchemaID == "rime_ice",
              !relaunched.select(schemaID: "flypy") else {
            print("FAILED: removed external schema remained selectable")
            return false
        }

        let config = root.appendingPathComponent("default.custom.yaml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "schema:\n  schema_id: flypy\n  name: 小鹤音形\n".write(
            to: root.appendingPathComponent("flypy.schema.yaml"), atomically: true, encoding: .utf8)
        try "patch:\n  schema_list:\n    - schema: flypy\n    - schema: ../escape\n    - schema: melt_eng\n    - schema: missing\n    - schema: my_combo\n  menu:\n    page_size: 7\n".write(to: config, atomically: true, encoding: .utf8)
        guard InputSchemaCatalog.preservedExternalIDs(in: root) == ["flypy"] else {
            print("FAILED: startup retained undeployed, dependency or unsafe IDs")
            return false
        }
        for enabled in [false, true, false] {
            let ids = InputSchemaCatalog.enabledIDs(chordExtensionEnabled: enabled,
                                                    userDirectory: root)
            try SchemaListStore.writeEnabledIDs(ids, to: config)
            let written = try String(contentsOf: config, encoding: .utf8)
            guard SchemaListStore.enabledIDs(at: config).contains("flypy"),
                  written.contains("- schema: flypy"),
                  written.contains("page_size: 7"),
                  written.contains("- schema: my_combo") == enabled,
                  !written.contains("../escape"), !written.contains("melt_eng"),
                  !written.contains("missing") else {
                print("FAILED: startup/deploy erased external scheme or changed unrelated settings")
                return false
            }
        }
        // Selecting built-in schemes or deploying the extension must not remove
        // a separately configured external scheme from F4.
        try SchemaListStore.writeEnabledIDs(["rime_ice"], to: config)
        guard SchemaListStore.enabledIDs(at: config) == ["rime_ice", "flypy"] else {
            print("FAILED: narrow deployment rewrite lost configured external scheme")
            return false
        }
        print("external schema smoke: OK catalog, selection, restart, F4, fallback, schema-list preservation")
        return true
    } catch {
        print("FAILED: external schema smoke", error)
        return false
    }
}

/// A real librime integration probe. The fixture is an ordinary, renamed
/// built-in schema in the disposable smoke tree, never third-party user data.
func runExternalSchemaEngineSmokeTest() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let rootPath = environment["RIMEBUFFER_USER_DIR"],
          let sharedPath = environment["RIMEBUFFER_SHARED_DIR"] else { return false }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let shared = URL(fileURLWithPath: sharedPath, isDirectory: true)
    let schemaID = "community_external_smoke"
    let suite = "RIMES.ExternalSchemaEngineSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return false }
    defer { defaults.removePersistentDomain(forName: suite) }
    do {
        var source = try String(contentsOf: shared.appendingPathComponent("rime_ice.schema.yaml"), encoding: .utf8)
        source = source.replacingOccurrences(of: "  schema_id: rime_ice", with: "  schema_id: \(schemaID)")
            .replacingOccurrences(of: "  name: 雾凇拼音", with: "  name: 社区外部方案")
        try source.write(to: root.appendingPathComponent(schemaID + ".schema.yaml"), atomically: true, encoding: .utf8)
        let config = root.appendingPathComponent("default.custom.yaml")
        try "patch:\n  schema_list:\n    - schema: rime_ice\n    - schema: \(schemaID)\n".write(to: config, atomically: true, encoding: .utf8)
        InputSchemaCatalog.prepareStartup(in: root)
        let coldStore = InputConfigurationStore(defaults: defaults)
        guard coldStore.select(schemaID: schemaID), coldStore.runtimeProfile.schemaID == schemaID else {
            print("FAILED: external identity lost before cold engine startup")
            return false
        }
        let engine = RimeEngine()
        guard engine.start(), engine.isHealthy,
              engine.schemaList().contains(where: { $0.id == schemaID && $0.name == "社区外部方案" }),
              InputSchemaCatalog.options.contains(where: { $0.id == schemaID && $0.name == "社区外部方案" }),
              InputConfigurationStore(defaults: defaults).selectedSchemaID == schemaID else {
            print("FAILED: external schema did not deploy or preserve authoritative name/selection")
            return false
        }
        let session = engine.createSession()
        defer { engine.destroySession(session) }
        guard session != 0, engine.selectSchema(schemaID, session: session),
              engine.getStatus(session: session).schemaId == schemaID else { return false }
        engine.setOption("ascii_mode", false, session: session)
        for scalar in "nihao".unicodeScalars {
            _ = engine.processKey(Int32(scalar.value), session: session)
        }
        let context = engine.getContext(session: session)
        guard context.candidates.contains(where: { $0.text == "你好" }) else {
            print("FAILED: deployed external scheme cannot produce candidates")
            return false
        }
        guard let index = context.candidates.firstIndex(where: { $0.text == "你好" }),
              engine.selectCandidate(onPage: index, session: session),
              engine.takeCommit(session: session) == "你好" else {
            print("FAILED: deployed external scheme candidate commit")
            return false
        }
        try SchemaListStore.writeEnabledIDs(InputSchemaCatalog.defaultEnabledIDs, to: config)
        guard SchemaListStore.enabledIDs(at: config).contains(schemaID),
              InputConfigurationStore(defaults: defaults).adoptRuntimeSchema(schemaID) else {
            print("FAILED: external F4 selection lost after ordinary deploy rewrite")
            return false
        }
        print("external schema engine smoke: OK cold selection, deployed name, private session, candidates, commit, F4 persistence")
        return true
    } catch {
        print("FAILED: external schema engine smoke", error)
        return false
    }
}
