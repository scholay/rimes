import Foundation

/// Records are transcribed from real rollouts under `~/.codex/sessions`
/// (12 item types observed across 40 sessions), not invented, because the
/// point of this parser is to survive what codex actually writes.
func runCodexSessionSmokeTest() -> Bool {
    print("== RIMES codex session smoke ==")

    let header = Data("""
    {"type":"session_meta","ordinal":0,"timestamp":"2026-09-03T07:59:05Z",
     "payload":{"id":"019febc7-9994-7253-96a8-68c0b209f108",
                "session_id":"019febc7-9994-7253-96a8-68c0b209f108",
                "cwd":"/Users/isaac/Documents/example",
                "cli_version":"0.52.0","model_provider":"openai"}}
    """.utf8)
    guard let parsed = CodexRolloutParser.header(from: header),
          parsed.sessionID == "019febc7-9994-7253-96a8-68c0b209f108",
          parsed.cwd == "/Users/isaac/Documents/example",
          parsed.cliVersion == "0.52.0" else {
        return codexFail("session header")
    }

    // The raw `response_item` stream carries developer instructions and
    // encrypted reasoning. A pane the user reads must take the high-level
    // item stream instead, so these have to parse to nothing.
    let developerTurn = Data("""
    {"type":"response_item","payload":{"type":"message","role":"developer",
     "content":[{"type":"input_text","text":"<environment_context><cwd>/x</cwd></environment_context>"}]}}
    """.utf8)
    let encryptedReasoning = Data("""
    {"type":"response_item","payload":{"type":"reasoning","summary":[],
     "content":null,"encrypted_content":"gAAAAABpcuQmdySVWaq5VAnz"}}
    """.utf8)
    guard CodexRolloutParser.event(from: developerTurn) == nil,
          CodexRolloutParser.event(from: encryptedReasoning) == nil else {
        return codexFail("raw response_item records must not reach the pane")
    }

    func item(_ json: String) -> CodexRolloutItem? {
        CodexRolloutParser.event(from: Data("""
        {"type":"event_msg","ordinal":7,"timestamp":"2026-09-03T08:00:00Z",
         "payload":{"type":"item_completed","turn_id":"rollout-3","item":\(json)}}
        """.utf8))?.item
    }

    guard item("""
    {"type":"AgentMessage","id":"msg_1","phase":"commentary",
     "content":[{"type":"Text","text":"我会先做一次只读映射。"}]}
    """) == .agentMessage(text: "我会先做一次只读映射。", phase: "commentary") else {
        return codexFail("AgentMessage")
    }
    guard item("""
    {"type":"Reasoning","id":"rs_1",
     "summary_text":[{"type":"summary_text","text":"**Preparing response**"}],
     "raw_content":[]}
    """) == .reasoning(summary: "**Preparing response**") else {
        return codexFail("Reasoning summary")
    }
    // An empty reasoning record is extremely common and carries nothing.
    guard item("""
    {"type":"Reasoning","id":"rs_2","summary_text":[],"raw_content":[]}
    """) == nil else {
        return codexFail("empty Reasoning must not become a blank row")
    }
    guard item("""
    {"type":"CommandExecution","id":"exec-1","process_id":"35621",
     "command":["/bin/zsh","-lc","git status --short"],
     "cwd":"/Users/isaac/x","exit_code":0,"status":"completed"}
    """) == .commandExecution(command: "/bin/zsh -lc git status --short",
                              cwd: "/Users/isaac/x",
                              exitCode: 0,
                              status: "completed") else {
        return codexFail("CommandExecution")
    }
    guard item("""
    {"type":"FileChange","id":"exec-2","status":"completed",
     "changes":{"/Users/isaac/b.md":{"type":"update","unified_diff":"@@"},
                "/Users/isaac/a.md":{"type":"add","unified_diff":"@@"}}}
    """) == .fileChange(paths: ["/Users/isaac/a.md", "/Users/isaac/b.md"],
                        status: "completed") else {
        return codexFail("FileChange")
    }
    guard item("""
    {"type":"McpToolCall","id":"call_1","server":"cua_repl","tool":"js",
     "status":"completed","arguments":{"code":"await cua.getState()"}}
    """) == .toolCall(server: "cua_repl", tool: "js", status: "completed") else {
        return codexFail("McpToolCall")
    }
    guard item("""
    {"type":"Plan","id":"p1","text":"# 计划\\n\\n- 第一步"}
    """) == .plan(text: "# 计划\n\n- 第一步") else {
        return codexFail("Plan")
    }
    // Codex adds item types over time. An unknown one is recorded, not
    // dropped, and must never abort the stream.
    for unknown in ["SubAgentActivity", "ImageView", "ContextCompaction",
                    "Extension", "SomethingShippedNextYear"] {
        guard item("{\"type\":\"\(unknown)\",\"id\":\"z\"}")
                == .other(kind: unknown) else {
            return codexFail("unknown item \(unknown)")
        }
    }

    // Translation policy: prose only. A translated command is a command that
    // no longer runs, and a translated diff no longer applies.
    let translatable: [CodexRolloutItem] = [
        .agentMessage(text: "Mapping the repository first.", phase: nil),
        .reasoning(summary: "**Preparing**"),
        .plan(text: "# Plan"),
    ]
    let verbatim: [CodexRolloutItem] = [
        .commandExecution(command: "git status --short", cwd: nil,
                          exitCode: 0, status: "completed"),
        .fileChange(paths: ["/Users/isaac/a.md"], status: "completed"),
        .toolCall(server: "cua_repl", tool: "js", status: "completed"),
        .userMessage(text: "hi"),
        .other(kind: "ImageView"),
    ]
    guard translatable.allSatisfy(CodexEventTranslationRules.isTranslatable),
          verbatim.allSatisfy({ !CodexEventTranslationRules.isTranslatable($0) })
    else {
        return codexFail("translation eligibility")
    }
    guard CodexEventTranslationRules.translatableText(
            in: .agentMessage(text: "Hello", phase: "commentary")) == "Hello",
          CodexEventTranslationRules.translatableText(
            in: .commandExecution(command: "rm -rf build", cwd: nil,
                                  exitCode: nil, status: nil)) == nil else {
        return codexFail("translatable text extraction")
    }

    // A rollout is appended to while it is read, so chunk boundaries land
    // mid-record as a matter of course. A split line must be completed by the
    // next read, never dropped and never parsed as two.
    var buffer = Data()
    let full = """
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m1","content":[{"type":"Text","text":"first"}]}}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m2","content":[{"type":"Text","text":"second"}]}}}

    """
    let bytes = Array(full.utf8)
    let split = bytes.count / 2
    buffer.append(contentsOf: bytes[0..<split])
    let firstBatch = CodexRolloutWatcher.drain(&buffer)
    buffer.append(contentsOf: bytes[split...])
    let secondBatch = CodexRolloutWatcher.drain(&buffer)
    let texts = (firstBatch + secondBatch).compactMap { event -> String? in
        guard case let .agentMessage(text, _) = event.item else { return nil }
        return text
    }
    guard texts == ["first", "second"], buffer.isEmpty else {
        return codexFail("split-line tailing produced \(texts)")
    }
    // Malformed lines are skipped without stopping the stream around them.
    var noisy = Data("""
    not json at all
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"m3","content":[{"type":"Text","text":"survived"}]}}}

    """.utf8)
    let recovered = CodexRolloutWatcher.drain(&noisy)
    guard recovered.count == 1,
          recovered[0].item == .agentMessage(text: "survived", phase: nil) else {
        return codexFail("malformed line must not stop the stream")
    }

    // Structural rows are shown as themselves; only the framing is ours.
    guard CodexSessionRowFormatter.summary(
            for: .commandExecution(command: "git status --short",
                                   cwd: nil, exitCode: 0, status: "completed"))
            == "$ git status --short → 0",
          CodexSessionRowFormatter.summary(
            for: .fileChange(paths: ["/Users/isaac/docs/a.md"], status: nil))
            == "± a.md",
          CodexSessionRowFormatter.summary(
            for: .toolCall(server: "cua_repl", tool: "js", status: "completed"))
            == "⚙ cua_repl/js · completed",
          CodexSessionRowFormatter.summary(
            for: .agentMessage(text: "Mapping first.", phase: nil))
            == "Mapping first." else {
        return codexFail("row formatting")
    }

    // A remembered workspace that no longer exists must not be launched into.
    let defaults = UserDefaults(suiteName: "codex-session-smoke-\(UUID().uuidString)")!
    defer { defaults.removeSuite(named: defaults.description) }
    guard CodexSessionWorkspaceRules.preferredWorkspace(defaults: defaults)
            == FileManager.default.homeDirectoryForCurrentUser else {
        return codexFail("empty workspace preference")
    }
    defaults.set("/nonexistent/path/\(UUID().uuidString)",
                 forKey: CodexSessionWorkspaceRules.lastWorkspaceKey)
    guard CodexSessionWorkspaceRules.preferredWorkspace(defaults: defaults)
            == FileManager.default.homeDirectoryForCurrentUser else {
        return codexFail("stale workspace must fall back")
    }
    let real = FileManager.default.temporaryDirectory
    CodexSessionWorkspaceRules.remember(real, defaults: defaults)
    guard CodexSessionWorkspaceRules.preferredWorkspace(defaults: defaults)
            .standardizedFileURL == real.standardizedFileURL else {
        return codexFail("workspace round trip")
    }

    print("codex session smoke: OK")
    return true
}

private func codexFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
