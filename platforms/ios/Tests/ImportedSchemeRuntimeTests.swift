import XCTest
import UIKit
import ZIPFoundation
import RimesCore
@testable import RIMES

@MainActor final class ImportedSchemeRuntimeTests: XCTestCase {
    /// Optional pinned-artifact acceptance. Provision only the task-owned simulator's Documents folder.
    func testPinnedWanxiangDeliveryPackageUsesQwertyWithNineKeyPreference() async throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let archive = documents.appendingPathComponent("wanxiang-layout-acceptance.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip("Pinned Wanxiang ZIP not provisioned; synthetic import/layout regressions run independently.")
        }
        let review = try RimeSchemeImportService.inspect(url: archive)
        guard review.archiveSHA256 == "91041724bfca27080184abad84506a423a5dc751759e5cc734e7d5f8c7ae08be" else {
            XCTFail("Acceptance fixture differs from the pinned delivery ZIP.")
            return
        }
        let main = try XCTUnwrap(review.schemes.first { $0.id == "wanxiang" })
        XCTAssertTrue(main.blockingIssues.isEmpty)
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await RimeSchemeInstaller.install(review: review, selectedSchemaIDs: ["wanxiang"], store: store) { _ in }
        defer { removeUserData(for: package) }
        let (window, controller) = host()
        defer { controller.developmentChoose(.pinyin); window.isHidden = true }
        controller.developmentOrdinaryAppearance(layout: .nineKey)
        XCTAssertEqual(controller.layoutViews.keys.standardMode, .nineKey)
        let selection = RimeSchemeSelection(packageID: package.id, schemaID: "wanxiang")
        controller.developmentChooseImported(selection, store: store)
        controller.viewWillAppear(false); window.layoutIfNeeded()
        XCTAssertEqual(controller.developmentImportedSelection, selection, "Real Wanxiang resources loaded without falling back to built-in Pinyin.")
        XCTAssertEqual(controller.layoutViews.keys.standardMode, .qwerty)
        XCTAssertEqual(controller.layoutViews.keys.developmentKeyFrames.count, 26)
        let menu = try XCTUnwrap(controller.layoutViews.settings.menu)
        let layout = try XCTUnwrap(menu.children.compactMap { $0 as? UIMenu }.first { menu in
            menu.children.contains { ($0 as? UIAction)?.title == "26 键 · QWERTY" }
        })
        let actions = layout.children.compactMap { $0 as? UIAction }
        let qwerty = try XCTUnwrap(actions.first { $0.title == "26 键 · QWERTY" })
        let nine = try XCTUnwrap(actions.first { $0.title == "9 键 · 全拼" })
        XCTAssertEqual(qwerty.state, .on); XCTAssertFalse(qwerty.attributes.contains(.disabled))
        XCTAssertEqual(nine.state, .off); XCTAssertTrue(nine.attributes.contains(.disabled))
        controller.developmentType("nihao")
        XCTAssertEqual(controller.developmentRaw, "nihao")
        XCTAssertTrue(descendants(controller.layoutViews.candidates).contains { $0.accessibilityLabel == "你好" })
        controller.developmentSpaceKey.sendActions(for: .touchUpInside)
        await controller.developmentWaitForDelivery()
        XCTAssertEqual(controller.layoutProxy.native.text, "你好")
        XCTAssertEqual(controller.developmentImportedSelection, selection)
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "wanxiang-imported-qwerty"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: documents.appendingPathComponent("wanxiang-imported-qwerty.png"))
    }

    func testInstalledDictionaryProducesCandidatesWithoutActivatingIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await installFixture(schema: "fixture_starcat", word: "星猫", store: store)
        defer { removeUserData(for: package) }
        XCTAssertNil(store.load().active, "Import and deployment must not select a scheme.")
        let selection = RimeSchemeSelection(packageID: package.id, schemaID: "fixture_starcat")
        let engine = MobileEngine()
        XCTAssertTrue(engine.selectImported(selection, store: store))
        let result = engine.process(key: 97)
        let index = try XCTUnwrap(result.candidates.firstIndex(of: "星猫"), "Actual Rime candidates: \(result.candidates)")
        XCTAssertEqual(engine.candidate(index).commit, "星猫")
        XCTAssertNil(store.load().active)
        engine.clear()

        XCTAssertTrue(engine.select(schema: "rimes_pinyin"))
        var builtin = EngineSnapshot()
        for key in "nihao".unicodeScalars { builtin = engine.process(key: Int32(key.value)) }
        XCTAssertTrue(builtin.candidates.contains("你好"))
        engine.clear()
    }

    func testEngineGenerationSwitchesBetweenIsolatedPackagesAndBuiltIn() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let first = try await installFixture(schema: "fixture_first", word: "甲", store: store)
        defer { removeUserData(for: first) }
        let second = try await installFixture(schema: "fixture_second", word: "乙", store: store)
        defer { removeUserData(for: second) }
        let engineA = MobileEngine(), engineB = MobileEngine()
        XCTAssertTrue(engineA.selectImported(.init(packageID: first.id, schemaID: "fixture_first"), store: store))
        XCTAssertTrue(engineA.process(key: 97).candidates.contains("甲"))
        XCTAssertTrue(engineB.selectImported(.init(packageID: second.id, schemaID: "fixture_second"), store: store))
        XCTAssertTrue(engineB.process(key: 97).candidates.contains("乙"))
        // Calling the retired instance must recreate its own schema session, never use B's schema.
        let resumed = engineA.process(key: 97)
        XCTAssertTrue(resumed.candidates.contains("甲"), "\(resumed.candidates)")
        XCTAssertFalse(resumed.candidates.contains("乙"))
        // Clearing a retired B cannot switch the active package back or erase A's composition.
        engineB.clear()
        XCTAssertEqual(engineA.rawInput, "a")
        engineA.clear()
        XCTAssertTrue(engineB.select(schema: "rimes_pinyin"))
        var state = EngineSnapshot()
        for scalar in "nihao".unicodeScalars { state = engineB.process(key: Int32(scalar.value)) }
        XCTAssertTrue(state.candidates.contains("你好"))
        engineB.clear()
    }

    func testExplicitImportedChoiceUsesOrdinaryInputAndReturningRestoresChord() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await installFixture(schema: "fixture_controller", word: "星猫", store: store)
        defer { removeUserData(for: package) }
        let (window, controller) = host()
        defer { window.isHidden = true }
        controller.developmentChoose(.chord)
        controller.developmentSetLayout(.splitOrthogonal)
        window.layoutIfNeeded()
        let chordFrames = controller.layoutViews.keys.developmentKeyFrames
        let chordArea = controller.layoutViews.keys.frame
        let selection = RimeSchemeSelection(packageID: package.id, schemaID: "fixture_controller")

        controller.developmentChooseImported(selection, store: store)
        // Appearance reloads must keep this explicit fixture rather than consult
        // whichever package happens to be active in the simulator's real app.
        controller.viewWillAppear(false)
        window.layoutIfNeeded()
        XCTAssertEqual(controller.developmentImportedSelection, selection)
        XCTAssertFalse(controller.layoutViews.keys.chordMode)
        XCTAssertFalse(controller.layoutViews.keys.resolvesChords)
        controller.developmentType("a")
        XCTAssertTrue(descendants(controller.layoutViews.candidates).contains { $0.accessibilityLabel == "星猫" })
        XCTAssertNil(store.load().active, "A keyboard-local test choice does not activate the app's default.")

        controller.developmentChoose(.chord)
        window.layoutIfNeeded()
        XCTAssertNil(controller.developmentImportedSelection)
        XCTAssertTrue(controller.layoutViews.keys.resolvesChords)
        XCTAssertEqual(controller.layoutViews.keys.chordLayout, .splitOrthogonal)
        XCTAssertEqual(controller.layoutViews.keys.developmentKeyFrames, chordFrames)
        XCTAssertEqual(controller.layoutViews.keys.frame, chordArea)
    }

    func testImportedSpaceAndReturnRunLuaProcessorsBeforeCommitting() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await installFixture(schema: "fixture_function_keys", word: "默认候选", store: store, luaFunctionKeys: true)
        defer { removeUserData(for: package) }
        let (window, controller) = host()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 80_000_000)
        controller.developmentChooseImported(.init(packageID: package.id, schemaID: "fixture_function_keys"), store: store)
        controller.developmentType("a")
        XCTAssertTrue(descendants(controller.layoutViews.candidates).contains { $0.accessibilityLabel == "默认候选" })

        controller.developmentSpace()
        XCTAssertEqual(controller.layoutProxy.native.text, "空格经过Lua", "Space must reach the imported processor, not directly commit candidate zero.")
        controller.developmentType("a")
        controller.developmentEnter()
        await controller.developmentWaitForDelivery()
        XCTAssertEqual(controller.layoutProxy.native.text, "空格经过Lua回车经过Lua", "Return must use the imported processor while composing.")
        XCTAssertNil(store.load().active)
    }

    func testDeletingImportedChoiceRestoresPreviousChordOnNextPresentation() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await installFixture(schema: "fixture_delete", word: "星猫", store: store)
        defer { removeUserData(for: package) }
        let (window, controller) = host(); defer { window.isHidden = true }
        controller.developmentChoose(.chord); controller.developmentSetLayout(.splitOrthogonal)
        let selection = RimeSchemeSelection(packageID: package.id, schemaID: "fixture_delete")
        try store.activate(selection)
        controller.developmentChooseImported(selection, store: store)
        controller.developmentType("a")
        XCTAssertFalse(controller.layoutViews.keys.chordMode)

        controller.viewWillDisappear(false)
        try store.remove(packageID: package.id)
        controller.viewWillAppear(false); window.layoutIfNeeded()

        XCTAssertNil(controller.developmentImportedSelection)
        XCTAssertTrue(controller.layoutViews.keys.resolvesChords)
        XCTAssertEqual(controller.layoutViews.keys.chordLayout, .splitOrthogonal)
        XCTAssertNil(store.load().active)
        XCTAssertTrue(controller.developmentRaw.isEmpty)
    }

    func testImportedTopUpCommitsPreviousWordAndKeepsNewCompositionInHostAndBuffer() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let package = try await installFixture(schema: "fixture_top_up", word: "你好", store: store, luaTopUp: true)
        defer { removeUserData(for: package) }
        for buffered in [false, true] {
            let (window, controller) = host()
            defer { window.isHidden = true }
            try await Task.sleep(nanoseconds: 80_000_000)
            controller.developmentChooseImported(.init(packageID: package.id, schemaID: "fixture_top_up"), store: store)
            let proxy = controller.layoutProxy
            if buffered {
                controller.developmentBuffer("前😀后"); controller.developmentBufferCursor(2)
            } else {
                proxy.native.text = "前😀后"; proxy.native.selectedRange = NSRange(location: 3, length: 0)
            }
            controller.developmentType("nkhz")
            XCTAssertTrue(descendants(controller.layoutViews.candidates).contains { $0.accessibilityLabel == "你好" })
            controller.developmentType("n")
            await controller.developmentWaitForDelivery()
            XCTAssertEqual(controller.developmentRaw, "n", "The same key starts the next composition after committing the old word.")
            if buffered {
                XCTAssertEqual(controller.developmentBufferSource.text, "前😀你好后")
                XCTAssertEqual(controller.layoutViews.source.text, "前😀你好n后")
                XCTAssertTrue(proxy.native.text.isEmpty)
                XCTAssertTrue(proxy.insertions.isEmpty)
            } else {
                XCTAssertEqual(proxy.native.text, "前😀你好n后")
                let range = try XCTUnwrap(proxy.native.markedTextRange)
                XCTAssertEqual(proxy.native.text(in: range), "n")
                XCTAssertEqual(proxy.native.selectedRange, NSRange(location: 6, length: 0), "The caret must follow the new preedit, after the committed word.")
            }
            controller.developmentBackspace()
            XCTAssertTrue(controller.developmentRaw.isEmpty)
            XCTAssertEqual(buffered ? controller.developmentBufferSource.text : proxy.native.text, "前😀你好后")
            if !buffered { XCTAssertNil(proxy.native.markedTextRange) }
        }
    }

    func testSelectingOnlyPrimaryCompilesItsAuxiliarySchemaAndDictionary() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RimeSchemeStore(root: root)
        let review = try dependencyReview([
            ("fixture_primary", ["fixture_auxiliary"]), ("fixture_auxiliary", [])
        ])
        let package = try await RimeSchemeInstaller.install(review: review, selectedSchemaIDs: ["fixture_primary"], store: store) { _ in }
        defer { removeUserData(for: package) }
        XCTAssertEqual(package.schemas.map(\.id), ["fixture_primary"], "Dependency compilation must not add unsolicited selectable schemes.")
        let build = store.packageURL(id: package.id).appendingPathComponent("build")
        for filename in ["fixture_primary.schema.yaml", "fixture_auxiliary.schema.yaml", "fixture_auxiliary.table.bin", "fixture_auxiliary.prism.bin"] {
            let file = build.appendingPathComponent(filename)
            XCTAssertEqual(try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true, filename)
        }
        XCTAssertNil(store.load().active)
    }

    func testMissingOrCyclicSchemaDependenciesCannotPublishPackage() async throws {
        for definitions: [(String, [String])] in [
            [("fixture_primary", ["missing_auxiliary"])],
            [("fixture_primary", ["fixture_auxiliary"]), ("fixture_auxiliary", ["fixture_primary"])]
        ] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = RimeSchemeStore(root: root)
            let review = try dependencyReview(definitions)
            do {
                _ = try await RimeSchemeInstaller.install(review: review, selectedSchemaIDs: ["fixture_primary"], store: store) { _ in }
                XCTFail("Missing or cyclic dependencies must fail before publication.")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("依赖") || error.localizedDescription.contains("循环"), error.localizedDescription)
            }
            XCTAssertTrue(store.load().packages.isEmpty)
            XCTAssertNil(store.load().active)
            let staging = (try? FileManager.default.contentsOfDirectory(atPath: store.stagingRoot.path)) ?? []
            XCTAssertTrue(staging.isEmpty, "Failed deployments must not leave staged packages.")
        }
    }

    func testInvalidImportedSelectionFallsBackToOriginalChordGeometry() {
        let choiceKey = "imported-rime-choice-v1"
        let previousChoice = UserDefaults.standard.object(forKey: choiceKey)
        defer {
            if let previousChoice { UserDefaults.standard.set(previousChoice, forKey: choiceKey) }
            else { UserDefaults.standard.removeObject(forKey: choiceKey) }
        }
        let (window, controller) = host()
        defer { window.isHidden = true }
        controller.developmentChoose(.chord)
        controller.developmentSetLayout(.splitOrthogonal)
        window.layoutIfNeeded()
        let before = controller.layoutViews.keys.developmentKeyFrames
        let oldFrame = controller.layoutViews.keys.convert(controller.layoutViews.keys.bounds, to: window)
        XCTAssertTrue(controller.layoutViews.keys.chordMode)

        controller.developmentChooseImported(.init(packageID: UUID().uuidString, schemaID: "missing_schema"))
        window.layoutIfNeeded()

        XCTAssertNil(controller.developmentImportedSelection)
        XCTAssertTrue(controller.layoutViews.keys.chordMode)
        XCTAssertEqual(controller.layoutViews.keys.chordLayout, .splitOrthogonal)
        XCTAssertEqual(controller.layoutViews.keys.developmentKeyFrames, before)
        XCTAssertEqual(controller.layoutViews.keys.convert(controller.layoutViews.keys.bounds, to: window), oldFrame)
        XCTAssertFalse(controller.developmentStatus.isEmpty, "A fallback must explain why the imported scheme did not load.")
        XCTAssertTrue(controller.layoutViews.keys.resolvesChords)
    }

    private func installFixture(schema: String, word: String, store: RimeSchemeStore, luaFunctionKeys: Bool = false, luaTopUp: Bool = false) async throws -> RimeSchemePackage {
        let schemaText = """
        schema:
          schema_id: \(schema)
          name: Runtime fixture
          version: '1.0'
        switches:
          - name: ascii_mode
            reset: 0
            states: [中文, English]
        engine:
          processors: [\(luaFunctionKeys ? "lua_processor@*fixture_space, " : "")\(luaTopUp ? "lua_processor@*fixture_top_up, " : "")speller, selector, navigator, express_editor]
          segmentors: [abc_segmentor]
          translators: [table_translator]
        speller:
          alphabet: abcdefghijklmnopqrstuvwxyz
          max_code_length: 4
        translator:
          dictionary: \(schema)
          enable_completion: false
          enable_sentence: false
          enable_user_dict: false
        menu:
          page_size: 5
        """
        let dictionary = """
        ---
        name: \(schema)
        version: '1.0'
        sort: original
        use_preset_vocabulary: false
        ...
        \(word)\t\(luaTopUp ? "nkhz" : "a")\t100

        """
        let archive = try Archive(data: Data(), accessMode: .create)
        var files = [("\(schema).schema.yaml", schemaText), ("\(schema).dict.yaml", dictionary)]
        if luaFunctionKeys {
            files.append(("lua/fixture_space.lua", """
            return function(key, env)
              if key.keycode == 0x20 then
                env.engine:commit_text("空格经过Lua")
                env.engine.context:clear()
                return 1
              elseif key.keycode == 0xff0d then
                env.engine:commit_text("回车经过Lua")
                env.engine.context:clear()
                return 1
              end
              return 2
            end
            """))
        }
        if luaTopUp {
            files.append(("lua/fixture_top_up.lua", """
            return function(key, env)
              local context = env.engine.context
              if key.keycode == 0x6e and context.input == "nkhz" then
                context:commit()
                context:push_input("n")
                return 1
              end
              return 2
            end
            """))
        }
        for (path, text) in files {
            let data = Data(text.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        let data = try XCTUnwrap(archive.data)
        let review = try RimeSchemeImportService.inspect(data: data, sourceName: "Runtime fixture")
        XCTAssertTrue(try XCTUnwrap(review.schemes.first).blockingIssues.isEmpty)
        return try await RimeSchemeInstaller.install(review: review, selectedSchemaIDs: [schema], store: store) { _ in }
    }
    private func dependencyReview(_ definitions: [(String, [String])]) throws -> RimeSchemeImportReview {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (schema, dependencies) in definitions {
            let source = """
            schema:
              schema_id: \(schema)
              name: \(schema)
              version: '1.0'
              dependencies: [\(dependencies.joined(separator: ", "))]
            engine:
              processors: [speller, selector, express_editor]
              segmentors: [abc_segmentor]
              translators: [table_translator]
            speller:
              alphabet: abcdefghijklmnopqrstuvwxyz
            translator:
              dictionary: \(schema)
              enable_user_dict: false
            """
            let dictionary = """
            ---
            name: \(schema)
            version: '1.0'
            sort: original
            use_preset_vocabulary: false
            ...
            测试\ta\t100

            """
            for (path, text) in [("\(schema).schema.yaml", source), ("\(schema).dict.yaml", dictionary)] {
                let data = Data(text.utf8)
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                    data.subdata(in: Int(position)..<(Int(position) + size))
                }
            }
        }
        return try RimeSchemeImportService.inspect(data: XCTUnwrap(archive.data), sourceName: "Dependency fixture")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ImportedSchemeRuntimeTests-" + UUID().uuidString, isDirectory: true)
    }
    private func removeUserData(for package: RimeSchemePackage) {
        let user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RimeImported/\(package.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: user)
    }
    private func host() -> (UIWindow, KeyboardViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 900))
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        let controller = KeyboardViewController(); controller.layoutNeedsInputModeSwitchKey = false
        parent.addChild(controller); parent.view.addSubview(controller.view); controller.didMove(toParent: parent)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)
        ])
        controller.developmentResetPreferences(); controller.developmentSetCustomLayout(nil)
        controller.developmentContent(); controller.developmentBuffer(nil); window.layoutIfNeeded()
        return (window, controller)
    }
}
