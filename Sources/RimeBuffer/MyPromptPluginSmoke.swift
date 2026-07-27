import Foundation

private final class MyPromptSmokeBackgroundQueue {
    private(set) var operations: [() -> Void] = []

    func enqueue(_ operation: @escaping () -> Void) {
        operations.append(operation)
    }

    @discardableResult
    func runNext() -> Bool {
        guard !operations.isEmpty else { return false }
        operations.removeFirst()()
        return true
    }
}

private final class MyPromptSmokeCancellation: AITextCancellable {
    func cancel() {}
}

private final class MyPromptSmokeGitRunner: AITextCLIProcessRunning {
    let repositoryURL: URL
    private(set) var specs: [AITextCLIProcessSpec] = []

    init(repositoryURL: URL) {
        self.repositoryURL = repositoryURL
    }

    @discardableResult
    func run(
        _ spec: AITextCLIProcessSpec,
        onStandardOutput: @escaping (Data) -> Void,
        completion: @escaping (AITextCLIProcessResult) -> Void
    ) -> any AITextCancellable {
        specs.append(spec)
        var status: Int32 = 0
        var output = Data()
        let arguments = spec.arguments

        if arguments.first == "clone", let incomingPath = arguments.last {
            do {
                try FileManager.default.createDirectory(
                    at: URL(
                        fileURLWithPath: incomingPath,
                        isDirectory: true
                    ),
                    withIntermediateDirectories: false
                )
            } catch {
                status = 1
            }
        } else if Array(arguments.suffix(3))
                    == ["remote", "get-url", "origin"] {
            output = Data(
                (repositoryURL.absoluteString + "\n").utf8
            )
        } else if arguments.contains("fetch") {
            status = 0
        } else if Array(arguments.suffix(3))
                    == ["reset", "--hard", "FETCH_HEAD"] {
            status = 0
        } else {
            status = 1
        }

        completion(
            AITextCLIProcessResult(
                terminationStatus: status,
                standardOutput: output,
                timedOut: false,
                cancelled: false,
                outputTooLarge: false
            )
        )
        return MyPromptSmokeCancellation()
    }
}

private func configureMyPromptSmoke(
    defaults: UserDefaults,
    resultLimit: Int = 3,
    includeUserPrompt: Bool = true
) throws {
    let model = try PluginConfigurationCatalog.makeMyPromptModel(
        defaults: defaults,
        notificationCenter: NotificationCenter()
    )
    var snapshot = try model.load()
    snapshot[MyPromptPluginConfigurationFieldID.resultLimit] = .number(
        Double(resultLimit)
    )
    snapshot[MyPromptPluginConfigurationFieldID.includeUserPrompt] = .bool(
        includeUserPrompt
    )
    snapshot[MyPromptPluginConfigurationFieldID.syncRemoteOnStart] = .bool(
        false
    )
    _ = try model.save(snapshot)
}

private func myPromptSmokeCandidates() -> [MyPromptWorkspace.Candidate] {
    [
        .init(
            recordID: "fabric:paper-review",
            title: "科研论文综述",
            snippet: "归纳研究问题、方法和结论",
            systemPrompt: "系统提示 A",
            userPrompt: "用户模板 A"
        ),
        .init(
            recordID: "obsidian:experiment",
            title: "实验设计审查",
            snippet: "检查变量、样本与可重复性",
            systemPrompt: "系统提示 B",
            userPrompt: "用户模板 B"
        ),
        .init(
            recordID: "aggregate:citation",
            title: "引用核验",
            snippet: "核对引文与来源",
            systemPrompt: "系统提示 C",
            userPrompt: nil
        ),
        .init(
            recordID: "markdown:fourth",
            title: "第四条不可见结果",
            snippet: "不得进入选择或投递集合",
            systemPrompt: "系统提示 D",
            userPrompt: nil
        ),
    ]
}

private func writeMyPromptSmokeText(
    _ text: String,
    to url: URL
) throws {
    guard let data = text.data(using: .utf8) else {
        throw MyPromptSmokeError.fixtureEncoding
    }
    try data.write(to: url, options: .atomic)
}

private func runMyPromptDataSmoke(
    fail: (String) -> Bool
) -> Bool {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "rimebuffer-my-prompt-smoke-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
    } catch {
        return fail("temporary fixture root")
    }
    defer { try? fileManager.removeItem(at: root) }

    do {
        let importer = MyPromptImporter()

        let emptyLibrary = root.appendingPathComponent(
            "empty-library",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: emptyLibrary,
            withIntermediateDirectories: false
        )
        let emptyResult = try importer.scan(rootURL: emptyLibrary)
        guard emptyResult.records.isEmpty else {
            return fail("empty library must import zero records")
        }

        // A Fabric checkout is authoritative when data/patterns exists. README
        // and repository docs outside that subtree must not become prompts.
        let fabricRoot = root.appendingPathComponent(
            "fabric",
            isDirectory: true
        )
        let fabricPattern = fabricRoot
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("patterns", isDirectory: true)
            .appendingPathComponent("paper_review", isDirectory: true)
        try fileManager.createDirectory(
            at: fabricPattern,
            withIntermediateDirectories: true
        )
        try writeMyPromptSmokeText(
            "你是科研论文综述助手。请归纳研究问题、方法和结论。",
            to: fabricPattern.appendingPathComponent("system.md")
        )
        try writeMyPromptSmokeText(
            "请分析这篇论文：{{input}}",
            to: fabricPattern.appendingPathComponent("user.md")
        )
        try writeMyPromptSmokeText(
            "仓库说明不应被单独导入。",
            to: fabricRoot.appendingPathComponent("README.md")
        )
        let canonicalMetadataRoot = fabricRoot
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(
                "pattern_descriptions",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: canonicalMetadataRoot,
            withIntermediateDirectories: true
        )
        try writeMyPromptSmokeText(
            """
            {
              "patterns": [
                {
                  "patternName": "paper_review",
                  "description": "归纳问题、方法与结论",
                  "tags": ["科研", "论文"]
                }
              ]
            }
            """,
            to: canonicalMetadataRoot.appendingPathComponent(
                "pattern_descriptions.json"
            )
        )
        let fabricResult = try importer.scan(rootURL: fabricRoot)
        guard fabricResult.records.count == 1,
              fabricResult.records[0].sourceKey == "paper_review",
              fabricResult.records[0].title == "paper review",
              fabricResult.records[0].summary == "归纳问题、方法与结论",
              fabricResult.records[0].tags == ["科研", "论文"],
              fabricResult.records[0].systemPrompt.contains("研究问题"),
              fabricResult.records[0].userPrompt
                == "请分析这篇论文：{{input}}" else {
            return fail("Fabric system/user/metadata import")
        }
        let remoteSource = MyPromptSource(
            id: "git:smoke",
            kind: .remoteSnapshot,
            displayName: "Remote smoke",
            location: "https://example.com/prompts.git"
        )
        let remoteFabric = try importer.scan(
            rootURL: fabricRoot,
            source: remoteSource
        )
        guard remoteFabric.source.kind == .remoteSnapshot,
              remoteFabric.source.id == remoteSource.id,
              remoteFabric.records.count == 1,
              remoteFabric.records[0].sourceID == remoteSource.id else {
            return fail("remote Fabric source identity")
        }

        // Without a Fabric patterns root, recursively import ordinary Obsidian
        // Markdown plus a root-level heading/fence collection.
        let markdownRoot = root.appendingPathComponent(
            "markdown-library",
            isDirectory: true
        )
        let notesRoot = markdownRoot.appendingPathComponent(
            "notes",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: notesRoot,
            withIntermediateDirectories: true
        )
        try writeMyPromptSmokeText(
            """
            ---
            title: 实验设计审查
            description: 检查变量、样本与可重复性
            tags: [科研, 方法]
            favorite: true
            ---
            你是一名实验设计审查员，请指出混杂变量与样本偏差。
            """,
            to: notesRoot.appendingPathComponent("实验设计.md")
        )
        try writeMyPromptSmokeText(
            """
            ---
            title: 完整研究笔记
            tags: [笔记, 模板]
            ---
            ## 正文中的内部标题

            ```text
            这段 fenced 内容属于整篇笔记，不能被拆成 aggregate 记录。
            ```
            """,
            to: notesRoot.appendingPathComponent("frontmatter-fenced.md")
        )
        try writeMyPromptSmokeText(
            """
            # 科研提示词合集

            ## 论文总结
            提炼论文的核心贡献。

            ```text
            阅读论文并给出研究问题、方法、证据和局限。
            ```

            ### 引用核验
            核对引用是否准确。

            ~~~text
            逐条核对引文、作者、年份和原始来源。
            ~~~
            """,
            to: markdownRoot.appendingPathComponent("PROMPTS.md")
        )
        try writeMyPromptSmokeText(
            """
            # Academic Research Prompts

            ## Academic Review
            Two independent prompts share this heading.

            ```text
            FIRST ACADEMIC PROMPT: review methods and evidence.
            ```

            ```text
            SECOND ACADEMIC PROMPT: review novelty and limitations.
            ```
            """,
            to: markdownRoot.appendingPathComponent("README.md")
        )
        let markdownResult = try importer.scan(rootURL: markdownRoot)
        let markdownKeys = Set(markdownResult.records.map(\.sourceKey))
        let academicRecords = markdownResult.records.filter {
            $0.title.hasPrefix("Academic Review ")
        }
        guard markdownResult.records.count == 6,
              markdownKeys.isSuperset(of: Set([
                  "notes/实验设计.md",
                  "notes/frontmatter-fenced.md",
              ])),
              markdownResult.records.contains(where: {
                  $0.title == "实验设计审查"
                      && $0.tags == ["科研", "方法"]
                      && $0.favorite
                      && $0.systemPrompt.contains("混杂变量")
              }),
              markdownResult.records.contains(where: {
                  $0.title == "论文总结"
                      && $0.sourceKey.hasPrefix("PROMPTS.md#论文总结-")
                      && $0.systemPrompt.contains("研究问题")
              }),
              markdownResult.records.contains(where: {
                  $0.title == "引用核验"
                      && $0.sourceKey.hasPrefix("PROMPTS.md#引用核验-")
                      && $0.tags == ["论文总结"]
                      && $0.systemPrompt.contains("原始来源")
              }),
              markdownResult.records.contains(where: {
                  $0.sourceKey == "notes/frontmatter-fenced.md"
                      && $0.title == "完整研究笔记"
                      && $0.systemPrompt.contains("## 正文中的内部标题")
                      && $0.systemPrompt.contains("```text")
              }),
              academicRecords.count == 2,
              Set(academicRecords.map(\.title)) == Set([
                  "Academic Review 1",
                  "Academic Review 2",
              ]),
              Set(academicRecords.map(\.sourceKey)).count == 2,
              academicRecords.allSatisfy({
                  $0.sourceKey.hasPrefix("README.md#academic-review")
              }),
              Set(academicRecords.map(\.systemPrompt)) == Set([
                  "FIRST ACADEMIC PROMPT: review methods and evidence.",
                  "SECOND ACADEMIC PROMPT: review novelty and limitations.",
              ]),
              academicRecords.allSatisfy({
                  !($0.systemPrompt.contains("FIRST ACADEMIC")
                      && $0.systemPrompt.contains("SECOND ACADEMIC"))
              }) else {
            return fail("recursive Obsidian and aggregate import")
        }
        let repeatedMarkdown = try importer.scan(rootURL: markdownRoot)
        guard repeatedMarkdown.records.map(\.sourceKey)
                == markdownResult.records.map(\.sourceKey),
              repeatedMarkdown.records.map(\.id)
                == markdownResult.records.map(\.id),
              repeatedMarkdown.records.allSatisfy({
                  !$0.sourceKey.hasPrefix("/")
              }) else {
            return fail("stable relative Markdown identities")
        }

        let symlink = root.appendingPathComponent("linked-library")
        try fileManager.createSymbolicLink(
            at: symlink,
            withDestinationURL: markdownRoot
        )
        do {
            _ = try importer.scan(rootURL: symlink)
            return fail("symlink source accepted")
        } catch MyPromptImporterError.sourceIsSymbolicLink {
            // Expected.
        }

        let nulFile = root.appendingPathComponent("nul.md")
        var nulData = Data("# Invalid\n".utf8)
        nulData.append(0)
        nulData.append(contentsOf: Data("hidden".utf8))
        try nulData.write(to: nulFile)
        do {
            _ = try importer.scan(rootURL: nulFile)
            return fail("NUL Markdown accepted")
        } catch MyPromptImporterError.containsNUL {
            // Expected.
        }

        let oversized = root.appendingPathComponent("oversized.md")
        try Data(
            repeating: 0x61,
            count: MyPromptImporter.maximumFileBytes + 1
        ).write(to: oversized)
        do {
            _ = try importer.scan(rootURL: oversized)
            return fail("oversized Markdown accepted")
        } catch MyPromptImporterError.oversizedFile {
            // Expected.
        }

        let storeRoot = root.appendingPathComponent(
            "store",
            isDirectory: true
        )
        let store = try MyPromptStore(rootDirectory: storeRoot)
        guard try store.replaceSource(with: emptyResult) == 0,
              try store.replaceSource(with: fabricResult) == 1,
              try store.replaceSource(with: markdownResult) == 6,
              try store.promptCount() == 7 else {
            return fail("SQLite source replacement")
        }

        let pinyinNoiseSource = MyPromptSource(
            id: "pinyin-noise",
            kind: .obsidianMarkdown,
            displayName: "Pinyin noise",
            location: "/smoke/pinyin-noise.md"
        )
        let pinyinNoise = MyPromptRecord(
            sourceID: pinyinNoiseSource.id,
            sourceKey: "可延期安排.md",
            title: "可延期安排",
            systemPrompt: "这是一条与目标术语完全无关的日程提醒。"
        )
        let embeddedPinyin = MyPromptRecord(
            sourceID: pinyinNoiseSource.id,
            sourceKey: "中国科研写作.md",
            title: "中国科研写作",
            systemPrompt: "帮助中文科研人员组织论文结构。"
        )
        let researcher = MyPromptRecord(
            sourceID: pinyinNoiseSource.id,
            sourceKey: "研究员访谈.md",
            title: "研究员访谈",
            systemPrompt: "整理研究员访谈提纲。"
        )
        let researchMethod = MyPromptRecord(
            sourceID: pinyinNoiseSource.id,
            sourceKey: "研究方法.md",
            title: "研究方法",
            systemPrompt: "比较定量与定性研究方法。"
        )
        guard try store.replaceSource(
            pinyinNoiseSource,
            records: [
                pinyinNoise,
                embeddedPinyin,
                researcher,
                researchMethod,
            ]
        ) == 4 else {
            return fail("pinyin noise fixture")
        }
        let chinese = try store.search("科研", limit: 10)
        let pinyin = try store.search("keyan", limit: 10)
        let pinyinInitials = try store.search("ky", limit: 10)
        let singleCharacter = try store.search("文", limit: 10)
        let exactCJKCoverage = try store.search("研究员", limit: 10)
        let capped = try store.search("", limit: 3)
        guard chinese.contains(where: {
                  $0.record.sourceKey == "paper_review"
              }),
              chinese.contains(where: {
                  $0.record.title == "实验设计审查"
              }),
              pinyin.contains(where: {
                  $0.record.sourceKey == "paper_review"
              }),
              pinyin.contains(where: {
                  $0.record.title == "实验设计审查"
              }),
              pinyin.contains(where: {
                  $0.record.title == "中国科研写作"
              }),
              pinyinInitials.contains(where: {
                  $0.record.title == "中国科研写作"
              }),
              singleCharacter.contains(where: {
                  $0.record.title == "中国科研写作"
              }),
              exactCJKCoverage.contains(where: {
                  $0.record.title == "研究员访谈"
              }),
              !exactCJKCoverage.contains(where: {
                  $0.record.title == "研究方法"
              }),
              !chinese.contains(where: {
                  $0.record.title == "可延期安排"
              }),
              capped.count == 3 else {
            return fail("Chinese, pinyin, and bounded SQLite search")
        }
        try store.removeSource(id: pinyinNoiseSource.id)

        guard let fabricPrompt = fabricResult.records.first else {
            return fail("Fabric record identity")
        }
        try store.setFavorite(promptID: fabricPrompt.id, isFavorite: true)
        try store.markUsed(
            promptID: fabricPrompt.id,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        guard try store.replaceSource(with: fabricResult) == 1,
              let preserved = try store.prompt(id: fabricPrompt.id),
              preserved.favorite,
              preserved.useCount == 1,
              preserved.lastUsedAt == Date(
                timeIntervalSince1970: 1_700_000_000
              ) else {
            return fail("source replacement must preserve usage metadata")
        }

        var reducedMarkdown = markdownResult
        reducedMarkdown.records.removeLast()
        guard try store.replaceSource(with: reducedMarkdown) == 5,
              try store.promptCount(sourceID: markdownResult.source.id) == 5,
              try store.replaceSource(with: markdownResult) == 6 else {
            return fail("source replacement must delete absent records")
        }
        try store.removeSource(id: markdownResult.source.id)
        guard try store.promptCount() == 1,
              try store.promptCount(
                sourceID: markdownResult.source.id
              ) == 0,
              !(try store.sources()).contains(where: {
                  $0.id == markdownResult.source.id
              }) else {
            return fail("source deletion cascade")
        }

        let rootMode = try fileManager.attributesOfItem(
            atPath: store.rootDirectory.path
        )[.posixPermissions] as? NSNumber
        let databaseMode = try fileManager.attributesOfItem(
            atPath: store.databaseURL.path
        )[.posixPermissions] as? NSNumber
        guard rootMode?.intValue == 0o700,
              databaseMode?.intValue == 0o600 else {
            return fail("private SQLite permissions")
        }

        let repositoryURL = URL(
            string: "https://github.com/example/research-prompts.git"
        )!
        let gitRunner = MyPromptSmokeGitRunner(
            repositoryURL: repositoryURL
        )
        let remoteSynchronizer = MyPromptRemoteRepositorySynchronizer(
            runner: gitRunner,
            inheritedEnvironment: [
                "PATH": "/usr/bin:/bin",
                "GIT_DIR": "/tmp/hostile-repository/.git",
                "GIT_WORK_TREE": "/tmp/hostile-worktree",
                "GIT_EXEC_PATH": "/tmp/hostile-git-exec",
                "GIT_SSL_NO_VERIFY": "1",
                "GIT_CONFIG_KEY_7": "protocol.ext.allow",
                "GIT_CONFIG_VALUE_7": "always",
                "SSH_ASKPASS": "/tmp/hostile-askpass",
                "SSH_AUTH_SOCK": "/tmp/hostile-agent.sock",
            ]
        )
        let checkoutsRoot = root
            .appendingPathComponent("remote-data", isDirectory: true)
            .appendingPathComponent("repositories", isDirectory: true)
        let firstSync = remoteSynchronizer.synchronize(
            repositories: [repositoryURL],
            checkoutsRoot: checkoutsRoot
        )
        let secondSync = remoteSynchronizer.synchronize(
            repositories: [repositoryURL],
            checkoutsRoot: checkoutsRoot
        )
        let commands = gitRunner.specs.map(\.arguments)
        guard firstSync.failedCount == 0,
              secondSync.failedCount == 0,
              firstSync.snapshots.count == 1,
              secondSync.snapshots.count == 1,
              firstSync.snapshots[0].sourceID
                == secondSync.snapshots[0].sourceID,
              firstSync.snapshots[0].checkoutURL
                == secondSync.snapshots[0].checkoutURL,
              fileManager.fileExists(
                atPath: firstSync.snapshots[0].checkoutURL.path
              ),
              commands.count == 4,
              commands[0].first == "clone",
              Array(commands[1].suffix(3))
                == ["remote", "get-url", "origin"],
              commands[2].contains("fetch"),
              Array(commands[3].suffix(3))
                == ["reset", "--hard", "FETCH_HEAD"],
              !commands.contains(where: { $0.contains("merge") }),
              gitRunner.specs.allSatisfy({
                  $0.executableURL.path == "/usr/bin/git"
                      && $0.standardInput.isEmpty
                      && $0.environment["GIT_TERMINAL_PROMPT"] == "0"
                      && $0.environment["GIT_CONFIG_VALUE_0"] == "never"
                      && $0.environment["GIT_CONFIG_VALUE_1"] == "never"
                      && $0.environment["GIT_CONFIG_KEY_2"]
                        == "core.hooksPath"
                      && $0.environment["GIT_CONFIG_VALUE_2"]
                        == "/dev/null"
                      && $0.environment["GIT_ASKPASS"] == nil
                      && $0.environment["SSH_ASKPASS"] == nil
                      && $0.environment["SSH_AUTH_SOCK"] == nil
                      && $0.environment["GIT_SSH_COMMAND"] == nil
                      && $0.environment["GIT_DIR"] == nil
                      && $0.environment["GIT_WORK_TREE"] == nil
                      && $0.environment["GIT_EXEC_PATH"] == nil
                      && $0.environment["GIT_SSL_NO_VERIFY"] == nil
                      && $0.environment["GIT_CONFIG_KEY_7"] == nil
                      && $0.environment["GIT_CONFIG_VALUE_7"] == nil
              }) else {
            return fail("offline remote clone/fetch/reset contract")
        }
        let unsafeRepository = URL(
            string: "https://token@example.com/private.git"
        )!
        let commandCountBeforeUnsafeSync = gitRunner.specs.count
        let unsafeSync = remoteSynchronizer.synchronize(
            repositories: [unsafeRepository],
            checkoutsRoot: checkoutsRoot
        )
        guard unsafeSync.snapshots.isEmpty,
              unsafeSync.failedCount == 1,
              gitRunner.specs.count == commandCountBeforeUnsafeSync else {
            return fail("credential-bearing remote URL reached git")
        }
    } catch {
        print("FAILED: My Prompt data smoke error=\(error)")
        return false
    }
    return true
}

private func runMyPromptWorkspaceSmoke(
    defaults: UserDefaults,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    source.stageExternal("科研", origin: .rime)

    var searchCalls: [(query: String, limit: Int)] = []
    var markedUsed: [String] = []
    let candidates = myPromptSmokeCandidates()
    let dependencies = MyPromptWorkspace.Dependencies(
        search: { query, limit in
            searchCalls.append((query, limit))
            return candidates
        },
        refresh: { _, synchronizeRemote in
            guard !synchronizeRemote else {
                throw MyPromptSmokeError.unexpectedRemoteSync
            }
            return .init(importedCount: candidates.count, failedSourceCount: 0)
        },
        markUsed: { markedUsed.append($0) },
        performBackground: { $0() }
    )
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: dependencies
    )
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
    }
    workspace.fireSearchDebounceForTesting()

    let initialRows = workspace.railSnapshot.outputRows
    guard workspace.phase == .ready,
          searchCalls.count == 1,
          searchCalls[0].query == "科研",
          searchCalls[0].limit == 3,
          initialRows.count == 3,
          workspace.railSnapshot.targetRowCount == 3,
          workspace.railSnapshot.sourceText == "科研",
          workspace.railSnapshot.sourceRole == "搜",
          workspace.railSnapshot.targetRole == "词",
          initialRows.flatMap(\.blocks).filter(\.selected).count == 1,
          !workspace.railSnapshot.outputBlocks.contains(where: {
              $0.text.contains("系统提示")
                  || $0.text.contains("用户模板")
                  || $0.text.contains("第四条")
          }),
          workspace.deliveryPendingBlocks.map(\.text)
            == ["系统提示 A\n\n用户模板 A"],
          workspace.deliveryPendingBlocks.first?.origin.allowsRemoteMirror
            == true,
          !workspace.deliveryPendingBlocks.contains(where: {
              $0.text.contains("科研")
          }) else {
        return fail("top-three presentation and query isolation")
    }

    let unconfirmedGeneration = workspace.deliveryGeneration
    guard let unconfirmedID = workspace.deliveryPendingBlocks.first?.id,
          workspace.deliveryBlock(
            id: unconfirmedID,
            generation: unconfirmedGeneration
          ) == nil else {
        return fail("unconfirmed result bypassed delivery preflight")
    }

    guard workspace.moveResultSelection(delta: 1),
          workspace.deliveryGeneration != unconfirmedGeneration,
          workspace.railSnapshot.outputRows[1].blocks.first?.selected == true,
          workspace.deliveryPendingBlocks.map(\.text)
            == ["系统提示 B\n\n用户模板 B"] else {
        return fail("result navigation and generation")
    }
    let selectedID = workspace.deliveryPendingBlocks[0].id
    let generationBeforePrepare = workspace.deliveryGeneration

    var epochs = FocusEpochState()
    let focus = epochs.activate()
    var inserted: [String] = []
    var secureInput = true
    var rejectDelivery = true
    let coordinator = BufferDeliveryCoordinator(
        model: BufferModel(),
        dependencies: .init(
            resolveTarget: { expected in
                guard expected == nil || expected == focus else { return nil }
                return .init(
                    token: focus,
                    compositionActive: false,
                    resolveComposition: {},
                    deliver: { block in
                        if rejectDelivery { return false }
                        inserted.append(block.text)
                        return true
                    }
                )
            },
            secureInputEnabled: { secureInput },
            validatePlugin: { _, _, completion in completion(.allowed) },
            refreshUI: {}
        ),
        contentSourceResolver: { workspace }
    )

    let secureBlocked = coordinator.sendAll(expectedToken: focus)
    guard secureBlocked.sentCount == 0,
          secureBlocked.blockedReason == .secureInput,
          workspace.deliveryGeneration == generationBeforePrepare,
          workspace.railSnapshot.outputRows.count == 3,
          source.stagedText == "科研",
          inserted.isEmpty else {
        return fail("secure input must block before result preflight")
    }

    secureInput = false
    let rejected = coordinator.sendAll(expectedToken: focus)
    let frozenGeneration = workspace.deliveryGeneration
    guard rejected.sentCount == 0,
          rejected.blockedReason == .deliveryRejected,
          frozenGeneration != generationBeforePrepare,
          workspace.railSnapshot.outputRows.count == 1,
          workspace.deliveryPendingBlocks.map(\.id) == [selectedID],
          workspace.deliveryBlock(
            id: selectedID,
            generation: frozenGeneration
          )?.text == "系统提示 B\n\n用户模板 B",
          workspace.moveResultSelection(delta: -1),
          workspace.deliveryGeneration == frozenGeneration,
          workspace.deliveryPendingBlocks.map(\.id) == [selectedID],
          source.stagedText == "科研",
          markedUsed.isEmpty,
          inserted.isEmpty else {
        return fail("failed delivery must retain frozen result and query")
    }

    rejectDelivery = false
    let delivered = coordinator.sendAll(expectedToken: focus)
    guard delivered.succeeded,
          delivered.sentCount == 1,
          inserted == ["系统提示 B\n\n用户模板 B"],
          !inserted.contains("科研"),
          source.stagedText.isEmpty,
          workspace.deliveryPendingBlocks.isEmpty,
          workspace.railSnapshot.outputRows.count == 1,
          markedUsed == ["obsidian:experiment"] else {
        return fail("successful prompt-only delivery consumption")
    }
    return true
}

private func runMyPromptRemoteMirrorSmoke(
    defaults: UserDefaults,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    source.stageExternal(
        "来自配对设备的查询",
        origin: .remotePeer(deviceID: "my-prompt-smoke-peer")
    )
    let candidate = MyPromptWorkspace.Candidate(
        recordID: "remote-mirror-guard",
        title: "远端回声保护",
        snippet: "结果必须继承查询来源的镜像权限",
        systemPrompt: "只投递这一条提示词",
        userPrompt: nil
    )
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { _, _ in [candidate] },
            refresh: { _, _ in
                .init(importedCount: 1, failedSourceCount: 0)
            },
            markUsed: { _ in },
            performBackground: { $0() }
        )
    )
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
    }
    workspace.fireSearchDebounceForTesting()

    guard workspace.phase == .ready,
          let pending = workspace.deliveryPendingBlocks.first,
          !pending.origin.allowsRemoteMirror,
          workspace.prepareForDelivery(),
          let frozen = workspace.deliveryBlock(
              id: pending.id,
              generation: workspace.deliveryGeneration
          ),
          !frozen.origin.allowsRemoteMirror else {
        return fail("remote-peer query mirror inheritance")
    }
    return true
}

private func runMyPromptConfigurationRoutingSmoke(
    defaults: UserDefaults,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    source.stageExternal("科研", origin: .rime)
    var refreshCalls: [MyPromptPluginSettings] = []
    var remoteSyncCalls: [Bool] = []
    var searchCalls: [(String, Int)] = []
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { query, limit in
                searchCalls.append((query, limit))
                return myPromptSmokeCandidates()
            },
            refresh: { settings, synchronizeRemote in
                refreshCalls.append(settings)
                remoteSyncCalls.append(synchronizeRemote)
                return .init(importedCount: 4, failedSourceCount: 0)
            },
            markUsed: { _ in },
            performBackground: { $0() }
        )
    )

    let model: PluginConfigurationModel
    let original: PluginConfigurationSnapshot
    do {
        model = try PluginConfigurationCatalog.makeMyPromptModel(
            defaults: defaults
        )
        original = try model.load()
    } catch {
        return fail("configuration routing setup")
    }
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
        if let silentModel = try? PluginConfigurationCatalog.makeMyPromptModel(
            defaults: defaults,
            notificationCenter: NotificationCenter()
        ) {
            _ = try? silentModel.save(original)
        }
    }
    workspace.fireSearchDebounceForTesting()
    guard workspace.phase == .ready,
          refreshCalls.count == 1,
          remoteSyncCalls == [false],
          searchCalls.count == 1,
          searchCalls[0].0 == "科研",
          searchCalls[0].1 == 3,
          workspace.deliveryPendingBlocks.map(\.text)
            == ["系统提示 A\n\n用户模板 A"] else {
        return fail("configuration routing initial state")
    }

    do {
        var snapshot = try model.load()
        snapshot[MyPromptPluginConfigurationFieldID.resultLimit] = .number(1)
        _ = try model.save(snapshot)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        workspace.fireSearchDebounceForTesting()
    } catch {
        return fail("result limit configuration update")
    }
    guard refreshCalls.count == 1,
          searchCalls.count == 2,
          searchCalls.map({ $0.0 }) == ["科研", "科研"],
          searchCalls.map({ $0.1 }) == [3, 1],
          workspace.railSnapshot.targetRowCount == 1 else {
        return fail("result limit must re-search without reindex")
    }

    let generationBeforeTemplateChange = workspace.deliveryGeneration
    do {
        var snapshot = try model.load()
        snapshot[
            MyPromptPluginConfigurationFieldID.includeUserPrompt
        ] = .bool(false)
        _ = try model.save(snapshot)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    } catch {
        return fail("user prompt configuration update")
    }
    guard refreshCalls.count == 1,
          searchCalls.count == 2,
          workspace.deliveryGeneration != generationBeforeTemplateChange,
          workspace.deliveryPendingBlocks.map(\.text) == ["系统提示 A"] else {
        return fail("user prompt toggle must only rebuild delivery")
    }

    let generationBeforeStartupToggle = workspace.deliveryGeneration
    do {
        var snapshot = try model.load()
        snapshot[
            MyPromptPluginConfigurationFieldID.syncRemoteOnStart
        ] = .bool(true)
        _ = try model.save(snapshot)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    } catch {
        return fail("startup sync configuration update")
    }
    guard refreshCalls.count == 1,
          searchCalls.count == 2,
          workspace.deliveryGeneration == generationBeforeStartupToggle else {
        return fail("startup-only toggle triggered live work")
    }

    do {
        var snapshot = try model.load()
        snapshot[
            MyPromptPluginConfigurationFieldID.libraryDirectory
        ] = .string(
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "my-prompt-config-routing",
                    isDirectory: true
                )
                .path
        )
        _ = try model.save(snapshot)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    } catch {
        return fail("library configuration update")
    }
    guard refreshCalls.count == 2,
          remoteSyncCalls == [false, false],
          searchCalls.count == 2,
          workspace.phase == .waiting else {
        return fail("library change must refresh index exactly once")
    }
    workspace.fireSearchDebounceForTesting()
    guard searchCalls.count == 3,
          searchCalls.map({ $0.0 }) == ["科研", "科研", "科研"],
          searchCalls.map({ $0.1 }) == [3, 1, 1],
          workspace.phase == .ready else {
        return fail("library refresh latest-query search")
    }

    do {
        var snapshot = try model.load()
        snapshot[
            MyPromptPluginConfigurationFieldID.remoteRepositories
        ] = .string(
            "https://github.com/example/research-prompts.git"
        )
        _ = try model.save(snapshot)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    } catch {
        return fail("remote repository configuration update")
    }
    guard refreshCalls.count == 3,
          remoteSyncCalls == [false, false, true],
          searchCalls.count == 3,
          workspace.phase == .waiting else {
        return fail("remote repository change must synchronize once")
    }
    workspace.fireSearchDebounceForTesting()
    guard searchCalls.count == 4,
          searchCalls.last?.0 == "科研",
          searchCalls.last?.1 == 1,
          workspace.phase == .ready else {
        return fail("remote refresh latest-query search")
    }
    return true
}

private func runMyPromptRefreshGateSmoke(
    defaults: UserDefaults,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    let background = MyPromptSmokeBackgroundQueue()
    var searchedQueries: [String] = []
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { query, _ in
                searchedQueries.append(query)
                return myPromptSmokeCandidates()
            },
            refresh: { _, _ in
                .init(importedCount: 4, failedSourceCount: 0)
            },
            markUsed: { _ in },
            performBackground: { background.enqueue($0) }
        )
    )
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
    }
    source.stageExternal("刷新期间的新查询", origin: .rime)
    workspace.fireSearchDebounceForTesting()
    guard workspace.phase == .refreshing,
          background.operations.count == 1,
          searchedQueries.isEmpty else {
        return fail("refresh must gate stale-index search")
    }

    guard background.runNext(),
          workspace.phase == .waiting else {
        return fail("refresh completion must schedule latest query")
    }
    workspace.fireSearchDebounceForTesting()
    guard background.operations.count == 1,
          background.runNext(),
          workspace.phase == .ready,
          searchedQueries == ["刷新期间的新查询"],
          workspace.railSnapshot.sourceText == "刷新期间的新查询" else {
        return fail("refresh completion latest-query search")
    }
    return true
}

private func runMyPromptPrivacyDiscardSmoke(
    defaults: UserDefaults,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    let previouslyEnabled = source.enabled
    source.enabled = true
    source.stageExternal("初始查询", origin: .rime)
    let background = MyPromptSmokeBackgroundQueue()
    var searchedQueries: [String] = []
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { query, _ in
                searchedQueries.append(query)
                return myPromptSmokeCandidates()
            },
            refresh: { _, _ in
                .init(importedCount: 4, failedSourceCount: 0)
            },
            markUsed: { _ in },
            performBackground: { background.enqueue($0) }
        )
    )
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
        source.enabled = previouslyEnabled
    }
    guard background.runNext(), workspace.phase == .waiting else {
        return fail("privacy discard refresh setup")
    }
    workspace.fireSearchDebounceForTesting()
    guard background.runNext(),
          workspace.phase == .ready,
          searchedQueries == ["初始查询"] else {
        return fail("privacy discard ready setup")
    }

    source.stageExternal("迟到检索", origin: .rime)
    workspace.fireSearchDebounceForTesting()
    guard workspace.phase == .searching,
          background.operations.count == 1 else {
        return fail("privacy discard stale-search setup")
    }
    workspace.workbenchWillPause()
    source.discardForPrivacy()
    workspace.fireSearchDebounceForTesting()
    guard background.operations.count == 1,
          background.runNext(),
          workspace.phase == .idle,
          workspace.railSnapshot.outputBlocks.isEmpty,
          workspace.deliveryPendingBlocks.isEmpty,
          source.stagedText.isEmpty,
          searchedQueries == ["初始查询", "初始查询迟到检索"] else {
        return fail("privacy discard must not resurrect recent prompts")
    }
    return true
}

private func runMyPromptLateCompletionSmoke(
    defaults: UserDefaults,
    protected: Bool,
    fail: (String) -> Bool
) -> Bool {
    let source = BufferModel()
    source.stageExternal(
        protected ? "保护态迟到" : "暂停迟到",
        origin: .rime
    )
    let background = MyPromptSmokeBackgroundQueue()
    let candidates = myPromptSmokeCandidates()
    var searchCount = 0
    let workspace = MyPromptWorkspace(
        defaults: defaults,
        sourceModel: source,
        selected: { true },
        dependencies: .init(
            search: { _, _ in
                searchCount += 1
                return candidates
            },
            refresh: { _, _ in
                .init(importedCount: candidates.count, failedSourceCount: 0)
            },
            markUsed: { _ in },
            performBackground: { background.enqueue($0) }
        )
    )
    workspace.start()
    defer {
        workspace.stop()
        source.discardForPrivacy()
    }

    guard background.runNext(), workspace.phase == .waiting else {
        return fail("late-completion refresh setup")
    }
    workspace.fireSearchDebounceForTesting()
    guard workspace.phase == .searching,
          background.operations.count == 1 else {
        return fail("late-completion search setup")
    }

    if protected {
        workspace.setProtected(true)
    } else {
        workspace.workbenchWillPause()
    }
    let tombstoneGeneration = workspace.deliveryGeneration
    guard background.runNext(),
          searchCount == 1,
          workspace.phase == .idle,
          workspace.railSnapshot.outputBlocks.isEmpty,
          workspace.deliveryPendingBlocks.isEmpty,
          workspace.deliveryGeneration == tombstoneGeneration,
          source.stagedText == (protected ? "保护态迟到" : "暂停迟到") else {
        return fail(
            protected
                ? "protected late search completion"
                : "paused late search completion"
        )
    }
    return true
}

private enum MyPromptSmokeError: Error {
    case unexpectedRemoteSync
    case fixtureEncoding
}

func runMyPromptPluginSmokeTest() -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))

    func fail(_ message: String) -> Bool {
        print("FAILED: My Prompt \(message)")
        return false
    }

    let suiteName = "RimeBuffer.MyPromptSmoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return fail("defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    do {
        try configureMyPromptSmoke(defaults: defaults)
    } catch {
        return fail("configuration setup")
    }

    guard runMyPromptDataSmoke(fail: fail),
          runMyPromptWorkspaceSmoke(defaults: defaults, fail: fail),
          runMyPromptRemoteMirrorSmoke(defaults: defaults, fail: fail),
          runMyPromptConfigurationRoutingSmoke(
              defaults: defaults,
              fail: fail
          ),
          runMyPromptRefreshGateSmoke(defaults: defaults, fail: fail),
          runMyPromptPrivacyDiscardSmoke(
              defaults: defaults,
              fail: fail
          ),
          runMyPromptLateCompletionSmoke(
            defaults: defaults,
            protected: false,
            fail: fail
          ),
          runMyPromptLateCompletionSmoke(
            defaults: defaults,
            protected: true,
            fail: fail
          ),
          TranslationRailRoleSymbolRules.resolve("搜", target: false)
            == .init(
                name: "magnifyingglass",
                accessibilityLabel: "提示词查询"
            ),
          TranslationRailRoleSymbolRules.resolve("词", target: true)
            == .init(
                name: "doc.text.magnifyingglass",
                accessibilityLabel: "提示词结果"
            ) else {
        return false
    }

    print("PASS: My Prompt plugin smoke")
    return true
}
