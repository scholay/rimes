import AppKit

private final class PersonalLexiconFixtureEngine: UserLexiconEngine {
    var isHealthy = true
    var dictionaries: [String: [String: PersonalLexiconEntry]] = [:]
    var partialImport = false
    var exportCalls = 0
    func hasUserDictionary(named name: String) -> Bool { dictionaries[name] != nil }
    func exportUserDictionary(named name: String, to fileURL: URL) -> Int {
        exportCalls += 1
        let entries = Array((dictionaries[name] ?? [:]).values)
        let rows = entries.map { "\($0.text)\t\($0.code)\t\($0.weight)" }
        do {
            try ("# Rime user dictionary export\n" + rows.joined(separator: "\n") + "\n")
                .write(to: fileURL, atomically: true, encoding: .utf8)
            return entries.count
        } catch { return -1 }
    }
    func importUserDictionary(named name: String, from fileURL: URL) -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return -1 }
        var count = 0
        for line in text.components(separatedBy: .newlines) where !line.isEmpty && !line.hasPrefix("#") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 3, let weight = Int(fields[2]) else { return -1 }
            let id = fields[1] + "\t" + fields[0]
            if weight < 0 { dictionaries[name, default: [:]].removeValue(forKey: id) }
            else {
                let previous = dictionaries[name]?[id]?.weight ?? 0
                dictionaries[name, default: [:]][id] = .init(text: fields[0], code: fields[1], weight: max(previous, weight))
            }
            count += 1
            if partialImport { return -1 }
        }
        return count
    }
    func restoreUserDictionarySnapshot(from fileURL: URL) -> Bool { false }
}

func runPersonalLexiconSmokeTest() -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rimes-personal-lexicon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let engine = PersonalLexiconFixtureEngine()
        let service = UserLexiconService(engine: engine, temporaryDirectory: root.appendingPathComponent("tmp/lexicon"))
        guard try service.personalEntries(.chinese).isEmpty else { return false }
        engine.dictionaries["rime_ice"] = [:]
        guard try service.personalEntries(.chinese).isEmpty else { return false }

        let word = try PersonalLexiconEntry.draft(text: "星河词库", code: "xing he ci ku")
        let unrelated = PersonalLexiconEntry(text: "日常输入", code: "ri chang shu ru", weight: 7)
        engine.dictionaries["rime_ice"]?[unrelated.id] = unrelated
        var entries = try service.savePersonalEntry(word, replacing: nil, kind: .chinese)
        guard entries.contains(word), entries.contains(unrelated) else { return false }
        do {
            _ = try service.savePersonalEntry(word, replacing: nil, kind: .chinese)
            return false
        } catch UserLexiconServiceError.duplicateEntry {}

        let edited = try PersonalLexiconEntry.draft(text: "星河新词", code: "xing he xin ci")
        entries = try service.savePersonalEntry(edited, replacing: word, kind: .chinese)
        guard !entries.contains(word), entries.contains(edited), entries.contains(unrelated) else { return false }
        entries = try service.undoPersonalChange()
        guard entries.contains(word), !entries.contains(edited), entries.contains(unrelated) else { return false }

        _ = try service.deletePersonalEntries([word], kind: .chinese)
        // A word learned after deletion must survive undo.
        let later = PersonalLexiconEntry(text: "后来词条", code: "hou lai ci tiao", weight: 2)
        engine.dictionaries["rime_ice"]?[later.id] = later
        entries = try service.undoPersonalChange()
        guard entries.contains(word), entries.contains(later), entries.contains(unrelated) else { return false }

        _ = try service.deletePersonalEntries([word], kind: .chinese)
        engine.dictionaries["rime_ice"]?[word.id] = .init(text: word.text, code: word.code, weight: 5)
        do {
            _ = try service.undoPersonalChange()
            return false
        } catch UserLexiconServiceError.staleEntries {}
        do {
            _ = try service.deletePersonalEntries([word], kind: .chinese)
            return false
        } catch UserLexiconServiceError.staleEntries {}

        for (text, code) in [("坏\n词", "huai ci"), ("#metadata", "code"), ("正常", "a\tb"), ("", "code")] {
            do { _ = try PersonalLexiconEntry.draft(text: text, code: code); return false }
            catch UserLexiconServiceError.invalidEntry {}
        }
        let exported = try PersonalLexiconEntry.parseExport("# Rime user dictionary export\n候选\thou xuan\t0\n")
        guard exported.first?.text == "候选", exported.first?.code == "hou xuan" else { return false }
        guard PersonalLexiconSort.weight.apply(to: entries, query: "xinghe").map(\.id) == [word.id] else { return false }

        let current = PersonalLexiconEntry(text: word.text, code: word.code, weight: 5)
        engine.partialImport = true
        do {
            _ = try service.savePersonalEntry(edited, replacing: current, kind: .chinese)
            return false
        } catch UserLexiconServiceError.editFailed {}
        engine.partialImport = false
        entries = try service.undoPersonalChange()
        guard entries.contains(current), !entries.contains(where: { $0.id == edited.id }), entries.contains(later) else { return false }
        let backup = service.personalBackupDirectory.appendingPathComponent("rime_ice-before-edit.tsv")
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return false }

        let batch = (0..<256).map {
            PersonalLexiconEntry(text: "Batch fixture \($0)", code: "batch\($0)", weight: 3)
        }
        for entry in batch { engine.dictionaries["rime_ice"]?[entry.id] = entry }
        let otherDictionary = PersonalLexiconEntry(text: "Other dictionary", code: "other", weight: 9)
        engine.dictionaries["english"] = [otherDictionary.id: otherDictionary]
        let batchIDs = Set(batch.map(\.id))
        entries = try service.deletePersonalEntries(batch, kind: .chinese)
        guard !entries.contains(where: { batchIDs.contains($0.id) }),
              entries.contains(current), entries.contains(later),
              engine.dictionaries["english"]?[otherDictionary.id] == otherDictionary else {
            print("personal-lexicon-smoke: batch deletion crossed record/dictionary boundaries")
            return false
        }
        entries = try service.undoPersonalChange()
        guard entries.filter({ batchIDs.contains($0.id) }).count == batch.count,
              entries.contains(current), entries.contains(later) else {
            print("personal-lexicon-smoke: batch undo failed to preserve records")
            return false
        }

        _ = NSApplication.shared
        let page = PersonalLexiconViewController(service: service, loadsOnOpen: false, permitsInteraction: { true })
        page.loadPreviewEntries(entries)
        let reads = engine.exportCalls
        guard page.searchForSmoke("xinghe") == 1,
              page.searchForSmoke("不存在") == 0,
              engine.exportCalls == reads else { return false }
        print("personal-lexicon-smoke: PASS CRUD, batch delete/undo, stale learning, partial import recovery, local search")
        return true
    } catch {
        print("personal-lexicon-smoke: FAIL \(error.localizedDescription)")
        return false
    }
}

func runPersonalLexiconBridgeSmokeTest() -> Bool {
    guard let isolatedPath = ProcessInfo.processInfo.environment["RIMEBUFFER_USER_DIR"],
          !isolatedPath.isEmpty else {
        print("personal-lexicon-bridge-smoke: REFUSED (set isolated RIMEBUFFER_USER_DIR)")
        return false
    }
    let root = URL(fileURLWithPath: isolatedPath)
    do {
        guard rimeEngine.start(), rimeEngine.isHealthy else { return false }
        let service = UserLexiconService(engine: rimeEngine, temporaryDirectory: root.appendingPathComponent("tmp/lexicon"))
        let word = try PersonalLexiconEntry.draft(text: "星河词库试验", code: "xing he ci ku shi yan")
        let revision = try PersonalLexiconEntry.draft(text: "星河词库实验", code: word.code)
        let before = try service.personalEntries(.chinese)
        var rows = try service.savePersonalEntry(word, replacing: nil, kind: .chinese)
        guard rows.contains(word) else { return false }

        // Prove the actual decoder can recall the imported word, not just a
        // mock or TSV round trip. Do not commit it and change its weight.
        let session = rimeEngine.createSession()
        guard session != 0, rimeEngine.selectSchema("rime_ice", session: session) else { return false }
        rimeEngine.setOption("ascii_mode", false, session: session)
        for key in "xinghecikushiyan".utf8 { _ = rimeEngine.processKey(Int32(key), session: session) }
        let recalled = rimeEngine.getContext(session: session).candidates.contains { $0.text == word.text }
        rimeEngine.clearComposition(session: session)
        rimeEngine.destroySession(session)
        guard recalled else {
            print("personal-lexicon-bridge-smoke: imported phrase not recalled")
            return false
        }
        rows = try service.savePersonalEntry(revision, replacing: word, kind: .chinese)
        guard rows.contains(revision), !rows.contains(word) else { return false }
        rows = try service.undoPersonalChange()
        guard rows.contains(word), !rows.contains(revision) else { return false }
        rows = try service.deletePersonalEntries([word], kind: .chinese)
        guard rows.sorted(by: { $0.id < $1.id }) == before.sorted(by: { $0.id < $1.id }) else { return false }
        rows = try service.undoPersonalChange()
        guard rows.contains(word) else { return false }
        _ = try service.deletePersonalEntries([word], kind: .chinese)
        let fresh = rimeEngine.createSession()
        guard fresh != 0, rimeEngine.sessionExists(fresh) else { return false }
        rimeEngine.destroySession(fresh)
        print("personal-lexicon-bridge-smoke: PASS real librime CRUD, candidate recall, undo, preservation")
        return true
    } catch {
        print("personal-lexicon-bridge-smoke: FAIL \(error.localizedDescription)")
        return false
    }
}

func renderPersonalLexiconPreview(to path: String) -> Bool {
    _ = NSApplication.shared
    let page = PersonalLexiconViewController(loadsOnOpen: false)
    page.loadPreviewEntries([
        .init(text: "嘉立创", code: "jia li chuang", weight: 128),
        .init(text: "雾凇拼音", code: "wu song pin yin", weight: 86),
        .init(text: "个人词库", code: "ge ren ci ku", weight: 42),
        .init(text: "离线输入", code: "li xian shu ru", weight: 35),
        .init(text: "自定义短语", code: "zi ding yi duan yu", weight: 19),
        .init(text: "词频调整", code: "ci pin tiao zheng", weight: 8),
    ])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "RIMES · 个人词库"
    window.contentView = page.view
    window.appearance = RimeUI.appKitAppearance
    window.contentView?.layoutSubtreeIfNeeded()
    guard let bitmap = page.view.bitmapImageRepForCachingDisplay(in: page.view.bounds) else { return false }
    page.view.cacheDisplay(in: page.view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
    do { try data.write(to: URL(fileURLWithPath: path)); return true }
    catch { return false }
}
