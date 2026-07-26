import Foundation

/// Executable coverage for the pure 飞耀互击 learning model. `main.swift` may
/// wire this to the `fly-chord-learning-smoke` argument without the model layer
/// importing or touching any input-controller/UI type.
func runFlyChordLearningSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("FAILED: fly chord learning \(message)")
        return false
    }

    let fileManager = FileManager.default
    let sandbox = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-fly-chord-learning-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )

    do {
        try fileManager.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sandbox) }

        let fixture = #"""
        schema:
          schema_id: my_combo
          name: 不应成为产品名
        chord_composer:
          alphabet: 'abcd.'
          algebra:
            - 'xform/^ab$/alpha/'
            - 'xform/^a\.$/dot/'
            - 'xform/^a.$/wildcard-must-be-skipped/'
            - 'xform/^([ab])$/$1/'
            - 'xform/^cd$/m*id/'
            - 'xform/^m\*id$/done/'
            - 'xform/^bc$/replacement-$1-must-be-skipped/'
        speller:
          algebra:
            - 'xform/^not-in-chord-section$/ignored/'
        """#
        let fixtureURL = sandbox.appendingPathComponent("fixture.schema.yaml")
        let parsed = try FlyChordSchemaParser.parse(fixture, sourceURL: fixtureURL)
        let fixtureMap = Dictionary(uniqueKeysWithValues: parsed.mappings.map {
            ($0.chord, $0.output)
        })
        guard parsed.schemaID == "my_combo",
              parsed.displayName == "飞耀互击",
              parsed.literalRules.map(\.input) == ["ab", "a.", "cd", "m*id"],
              fixtureMap == ["ab": "alpha", "a.": "dot", "cd": "done"],
              fixtureMap["a."] != "wildcard-must-be-skipped",
              fixtureMap["not-in-chord-section"] == nil else {
            return fail("literal xform filtering")
        }
        let fixtureStreamMapping = StreamInputChordMapping(schema: parsed)
        guard fixtureStreamMapping.decode([
            FlyChordKeyEvent(keycode: 0x62, mask: 0),
            FlyChordKeyEvent(keycode: 0x61, mask: 0),
        ]) == .init(text: "alpha",
                    insertsAutomaticSyllableSpace: false,
                    usedMappedOutput: true),
        fixtureStreamMapping.decode([
            FlyChordKeyEvent(keycode: 0x2e, mask: 0),
            FlyChordKeyEvent(keycode: 0x61, mask: 0),
        ]) == .init(text: "dot",
                    insertsAutomaticSyllableSpace: true,
                    usedMappedOutput: true) else {
            return fail("stream mapping must use order-independent parsed rules")
        }

        let fakeShared = sandbox.appendingPathComponent("SharedSupport", isDirectory: true)
        try fileManager.createDirectory(at: fakeShared, withIntermediateDirectories: true)
        let fakeSchemaURL = fakeShared.appendingPathComponent(
            FlyChordLearningIdentity.schemaFileName
        )
        try Data(fixture.utf8).write(to: fakeSchemaURL, options: .atomic)
        let located = try FlyChordSchemaLocator.locate(
            additionalSearchRoots: [fakeShared],
            environment: [:],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        guard located == fakeSchemaURL.standardizedFileURL else {
            return fail("SharedSupport schema location")
        }

        // A live profile may customize my_combo independently of the bundled
        // fallback. Learning must follow that current user schema, while
        // refusing unsafe/oversized profile paths.
        let userRoot = sandbox.appendingPathComponent("UserRime", isDirectory: true)
        try fileManager.createDirectory(at: userRoot, withIntermediateDirectories: true)
        let userBuildRoot = userRoot.appendingPathComponent("build", isDirectory: true)
        try fileManager.createDirectory(at: userBuildRoot, withIntermediateDirectories: true)
        let userSchemaURL = userRoot.appendingPathComponent(
            FlyChordLearningIdentity.schemaFileName
        )
        let customizedFixture = fixture.replacingOccurrences(
            of: "xform/^ab$/alpha/",
            with: "xform/^ab$/user-alpha/"
        )
        try Data(customizedFixture.utf8).write(to: userSchemaURL, options: .atomic)
        let deployedSchemaURL = userBuildRoot.appendingPathComponent(
            FlyChordLearningIdentity.schemaFileName
        )
        let deployedFixture = fixture.replacingOccurrences(
            of: "xform/^ab$/alpha/",
            with: "xform/^ab$/deployed-alpha/"
        )
        try Data(deployedFixture.utf8).write(to: deployedSchemaURL, options: .atomic)
        let locatedUserSchema = try FlyChordSchemaLocator.locate(
            environment: [
                "RIMEBUFFER_USER_DIR": userRoot.path,
                "RIMEBUFFER_SHARED_DIR": fakeShared.path,
            ],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        let customizedSchema = try FlyChordSchemaParser.load(from: locatedUserSchema)
        guard locatedUserSchema == deployedSchemaURL.standardizedFileURL,
              customizedSchema.mappings.first(where: { $0.chord == "ab" })?.output
                == "deployed-alpha" else {
            return fail("deployed user schema priority")
        }

        // Unsafe deployment output is skipped without hiding a safe root
        // schema. This also proves the build candidate receives the same file
        // hardening as every other source.
        let unsafeBuildRoot = sandbox.appendingPathComponent("UnsafeBuildUserRime",
                                                             isDirectory: true)
        let unsafeBuildDirectory = unsafeBuildRoot.appendingPathComponent("build",
                                                                          isDirectory: true)
        try fileManager.createDirectory(at: unsafeBuildDirectory,
                                        withIntermediateDirectories: true)
        let unsafeBaseURL = unsafeBuildRoot.appendingPathComponent(
            FlyChordLearningIdentity.schemaFileName
        )
        try Data(customizedFixture.utf8).write(to: unsafeBaseURL, options: .atomic)
        try fileManager.createSymbolicLink(
            at: unsafeBuildDirectory.appendingPathComponent(
                FlyChordLearningIdentity.schemaFileName
            ),
            withDestinationURL: deployedSchemaURL
        )
        let unsafeBuildFallback = try FlyChordSchemaLocator.locate(
            environment: [
                "RIMEBUFFER_USER_DIR": unsafeBuildRoot.path,
                "RIMEBUFFER_SHARED_DIR": fakeShared.path,
            ],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        guard unsafeBuildFallback == unsafeBaseURL.standardizedFileURL else {
            return fail("deployed schema symlink fallback")
        }

        let linkedRoot = sandbox.appendingPathComponent("LinkedUserRime", isDirectory: true)
        try fileManager.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkedRoot.appendingPathComponent(FlyChordLearningIdentity.schemaFileName),
            withDestinationURL: userSchemaURL
        )
        let symlinkFallback = try FlyChordSchemaLocator.locate(
            environment: [
                "RIMEBUFFER_USER_DIR": linkedRoot.path,
                "RIMEBUFFER_SHARED_DIR": fakeShared.path,
            ],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        guard symlinkFallback == fakeSchemaURL.standardizedFileURL else {
            return fail("user schema symlink rejection")
        }

        let oversizedRoot = sandbox.appendingPathComponent("OversizedUserRime",
                                                           isDirectory: true)
        try fileManager.createDirectory(at: oversizedRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x20,
                 count: FlyChordLearningIdentity.maximumSchemaBytes + 1).write(
                    to: oversizedRoot.appendingPathComponent(
                        FlyChordLearningIdentity.schemaFileName
                    )
                 )
        let oversizedFallback = try FlyChordSchemaLocator.locate(
            environment: [
                "RIMEBUFFER_USER_DIR": oversizedRoot.path,
                "RIMEBUFFER_SHARED_DIR": fakeShared.path,
            ],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        guard oversizedFallback == fakeSchemaURL.standardizedFileURL else {
            return fail("oversized user schema rejection")
        }

        let sourceFile = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let realSchemaURL = try FlyChordSchemaLocator.locate(
            additionalSearchRoots: [
                projectRoot.appendingPathComponent("rime-data", isDirectory: true),
            ],
            environment: [:],
            currentDirectory: sandbox,
            fileManager: fileManager
        )
        let schema = try FlyChordSchemaParser.load(from: realSchemaURL)
        let mappingByChord = Dictionary(uniqueKeysWithValues: schema.mappings.map {
            ($0.chord, $0.output)
        })
        guard schema.schemaID == "my_combo",
              schema.displayName == "飞耀互击",
              schema.literalRules.count > 100,
              schema.mappings.count > 100,
              mappingByChord["qy"] == "qing",
              mappingByChord["dfy"] == "ying",
              mappingByChord["wio"] == "wen",
              mappingByChord["go"] == "guo",
              mappingByChord["qm."] == "que",
              mappingByChord["dk."] == "dia",
              mappingByChord["dfm."] == "yue",
              mappingByChord["sdk."] == "lia",
              mappingByChord["eui"] == "er",
              mappingByChord["dv"] == "n",
              mappingByChord["ef"] == "sh",
              mappingByChord["km"] == "ong",
              mappingByChord["y"] == nil,
              mappingByChord["o"] == nil,
              mappingByChord["v"] == nil,
              schema.mappings.allSatisfy({ !$0.output.contains("*") }) else {
            return fail("real my_combo mapping extraction")
        }
        let streamMapping = StreamInputChordMapping(schema: schema)
        guard streamMapping.decode([
            FlyChordKeyEvent(keycode: 0x79, mask: 0),
            FlyChordKeyEvent(keycode: 0x71, mask: 0),
        ]) == .init(text: "qing",
                    insertsAutomaticSyllableSpace: true,
                    usedMappedOutput: true),
        streamMapping.decode([
            FlyChordKeyEvent(keycode: 0x76, mask: 0),
            FlyChordKeyEvent(keycode: 0x64, mask: 0),
        ]) == .init(text: "n",
                    insertsAutomaticSyllableSpace: false,
                    usedMappedOutput: true),
        streamMapping.decode([
            FlyChordKeyEvent(keycode: 0x69, mask: 0),
            FlyChordKeyEvent(keycode: 0x76, mask: 0),
            FlyChordKeyEvent(keycode: 0x64, mask: 0),
        ])?.text == "ni",
        streamMapping.decode([
            FlyChordKeyEvent(keycode: 0x2e, mask: 0),
            FlyChordKeyEvent(keycode: 0x6d, mask: 0),
            FlyChordKeyEvent(keycode: 0x71, mask: 0),
        ])?.text == "que" else {
            return fail("real stream mapping must follow effective FlyYao algebra")
        }
        guard FlyChordAnswerMatcher.matches(captured: "ydf", expected: "dfy"),
              FlyChordAnswerMatcher.matches(captured: "dfy", expected: "dfy"),
              !FlyChordAnswerMatcher.matches(captured: "dy", expected: "dfy"),
              !FlyChordAnswerMatcher.matches(captured: "dgy", expected: "dfy") else {
            return fail("physical key-set answer matching")
        }

        let curriculum = FlyChordCurriculum(schema: schema)
        guard curriculum.schemaID == "my_combo",
              curriculum.displayName == "飞耀互击",
              curriculum.alphabet == schema.alphabet,
              !curriculum.courses.isEmpty,
              curriculum.courses.map(\.keyCount) == curriculum.courses.map(\.keyCount).sorted(),
              curriculum.courses.allSatisfy({ $0.id.hasPrefix("my_combo.keys.") }),
              curriculum.mappings.count == schema.mappings.count,
              let practiceCourse = curriculum.courses.first(where: { $0.mappings.count > 2 }) else {
            return fail("course grouping")
        }

        let firstSample = FlyChordExerciseSampler.sample(from: practiceCourse,
                                                         limit: 8,
                                                         seed: 42)
        let secondSample = FlyChordExerciseSampler.sample(from: practiceCourse,
                                                          limit: 8,
                                                          seed: 42)
        guard firstSample == secondSample,
              firstSample.count == min(8, practiceCourse.mappings.count),
              Set(firstSample.map(\.mappingID)).count == firstSample.count,
              firstSample.allSatisfy({ $0.courseID == practiceCourse.id }) else {
            return fail("deterministic exercise sampling")
        }

        let progressRoot = sandbox.appendingPathComponent("progress", isDirectory: true)
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try FlyChordProgressStore(storageRoot: progressRoot,
                                              dateProvider: { clock })
        let masteredMapping = practiceCourse.mappings[0]
        for _ in 0..<FlyChordItemProgress.masteryStreak {
            _ = try store.recordAttempt(mappingID: masteredMapping.id, correct: true)
            clock = clock.addingTimeInterval(1)
        }
        _ = try store.recordAttempt(mappingID: masteredMapping.id, correct: false)

        let snapshot = store.snapshot
        guard let item = snapshot.items[masteredMapping.id],
              item.attempts == FlyChordItemProgress.masteryStreak + 1,
              item.correctAttempts == FlyChordItemProgress.masteryStreak,
              item.currentStreak == 0,
              item.bestStreak == FlyChordItemProgress.masteryStreak,
              item.isMastered,
              snapshot.progress(for: practiceCourse).masteredItems == 1 else {
            return fail("progress accounting")
        }

        let reloaded = try FlyChordProgressStore(storageRoot: progressRoot)
        guard reloaded.snapshot == snapshot else {
            return fail("progress reload")
        }
        let persistedJSON = try String(contentsOf: store.storageURL, encoding: .utf8)
        // Substring checks against JSON metadata would false-positive (for
        // example `m` occurs in `schemaID`). Assert the storage shape does not
        // persist either plaintext field instead.
        guard !persistedJSON.contains("\"chord\""),
              !persistedJSON.contains("\"output\""),
              !persistedJSON.localizedCaseInsensitiveContains("focus"),
              !persistedJSON.localizedCaseInsensitiveContains("text") else {
            return fail("progress privacy boundary")
        }
        let progressDirectoryPermissions = (try fileManager.attributesOfItem(
            atPath: store.storageURL.deletingLastPathComponent().path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let progressFilePermissions = (try fileManager.attributesOfItem(
            atPath: store.storageURL.path
        )[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard progressDirectoryPermissions & 0o777 == 0o700,
              progressFilePermissions & 0o777 == 0o600 else {
            return fail("progress storage permissions")
        }

        let prioritized = FlyChordExerciseSampler.sample(from: practiceCourse,
                                                         limit: 1,
                                                         progress: snapshot,
                                                         seed: 42)
        guard prioritized.first?.mappingID != masteredMapping.id else {
            return fail("unmastered exercise priority")
        }

        // A syntactically valid but previously unseen ID must not grow an
        // already-full progress dictionary past the same bound enforced at
        // load time.
        let capacityRoot = sandbox.appendingPathComponent("capacity", isDirectory: true)
        let capacityURL = capacityRoot.appendingPathComponent(
            "learning/my_combo_progress.json"
        )
        try fileManager.createDirectory(at: capacityURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        var fullItems: [String: Any] = [:]
        for index in 0..<FlyChordProgressStore.maximumItems {
            fullItems[String(format: "my_combo.rule.%016llx", UInt64(index))] = [
                "attempts": 0,
                "correctAttempts": 0,
                "currentStreak": 0,
                "bestStreak": 0,
                "updatedAt": 1,
            ]
        }
        let capacityData = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "schemaID": "my_combo",
            "items": fullItems,
            "updatedAt": 1,
        ])
        try capacityData.write(to: capacityURL, options: .atomic)
        let fullStore = try FlyChordProgressStore(storageRoot: capacityRoot)
        do {
            _ = try fullStore.recordAttempt(
                mappingID: "my_combo.rule.ffffffffffffffff",
                correct: true
            )
            return fail("progress item cap was exceeded")
        } catch FlyChordProgressStoreError.invalidProgressFile {
        }

        try Data("not-json".utf8).write(to: store.storageURL, options: .atomic)
        do {
            _ = try FlyChordProgressStore(storageRoot: progressRoot)
            return fail("corrupt progress accepted")
        } catch FlyChordProgressStoreError.invalidProgressFile {
        }

        print("fly chord learning smoke OK")
        return true
    } catch {
        return fail("threw \(error.localizedDescription)")
    }
}
