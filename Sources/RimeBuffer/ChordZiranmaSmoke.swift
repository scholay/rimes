import Foundation
import CRimeBridge

/// Converter, profile-format, validation and compiler coverage for the 自然码
/// chord encoding. Expected codes are the published 自然码 layout, written out
/// independently of the ported speller algebra.
func runChordZiranmaSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("chord-ziranma-smoke: FAIL \(message)")
        return false
    }

    let syllables: [String: String] = [
        "a": "aa", "o": "oo", "e": "ee", "ai": "ai", "ei": "ei", "ao": "ao", "ou": "ou",
        "an": "an", "en": "en", "ang": "ah", "eng": "eg", "er": "er",
        "zhi": "vi", "chi": "ii", "shi": "ui", "zhang": "vh", "chang": "ih", "shang": "uh",
        "shui": "uv", "zhuai": "vy", "chuang": "id", "shuang": "ud", "zhua": "vw",
        "qiu": "qq", "diu": "dq", "jia": "jw", "hua": "hw", "lia": "lw",
        "juan": "jr", "guan": "gr", "zhuan": "vr", "yuan": "yr",
        "jue": "jt", "lve": "lt", "lue": "lt", "nve": "nt", "yue": "yt",
        "ying": "yy", "ping": "py", "guai": "gy", "kuai": "ky",
        "guo": "go", "zhuo": "vo", "wo": "wo", "bo": "bo", "yo": "yo",
        "jun": "jp", "lun": "lp", "yun": "yp", "zhun": "vp",
        "zhong": "vs", "xiong": "xs", "yong": "ys", "cong": "cs",
        "jiang": "jd", "niang": "nd", "kuang": "kd", "biang": "bd",
        "zhen": "vf", "wen": "wf", "ren": "rf",
        "zheng": "vg", "weng": "wg", "sheng": "ug",
        "tang": "th", "yang": "yh", "bian": "bm", "tian": "tm", "yan": "yj", "shan": "uj",
        "biao": "bc", "bao": "bk", "yao": "yk", "bai": "bl", "wai": "wl",
        "bei": "bz", "shei": "uz", "wei": "wz", "cei": "cz",
        "bie": "bx", "ye": "ye", "gui": "gv", "zhui": "vv",
        "zhou": "vb", "you": "yb", "bin": "bn", "yin": "yn",
        "lv": "lv", "nv": "nv", "ju": "ju", "yu": "yu", "ri": "ri", "zi": "zi",
        "xian": "xm", "xiang": "xd", "qiong": "qs", "ya": "ya", "wa": "wa",
    ]
    for (pinyin, code) in syllables where ZiranmaShuangpin.syllableCode(pinyin) != code {
        return fail("\(pinyin) encoded \(ZiranmaShuangpin.syllableCode(pinyin) ?? "nil"), expected \(code)")
    }
    let fragments: [String: String] = [
        "zh": "v", "ch": "i", "sh": "u", "y": "y", "w": "w", "b": "b", "q": "q",
        "iu": "q", "uan": "r", "ue": "t", "ong": "s", "uang": "d", "iang": "d",
        "en": "f", "eng": "g", "ei": "z", "ie": "x", "iao": "c", "ui": "v", "ou": "b",
        "ia": "w", "ua": "w", "ing": "y", "uai": "y", "un": "p", "uo": "o", "ian": "m",
        "an": "j", "ang": "h", "ao": "k", "ai": "l", "in": "n", "a": "a", "e": "e", "o": "o",
    ]
    for (pinyin, code) in fragments where ZiranmaShuangpin.fragmentCode(pinyin) != code {
        return fail("fragment \(pinyin) encoded \(ZiranmaShuangpin.fragmentCode(pinyin) ?? "nil"), expected \(code)")
    }
    for invalid in ["zhx", "gi", "bue", "ng", ""] where ZiranmaShuangpin.syllableCode(invalid) != nil {
        return fail("accepted non-syllable \(invalid)")
    }
    // ü has two spellings, and 自然码 itself gives 咯 lo and luo one key
    // (o doubles as uo). Every other syllable owns its two keys.
    var owners: [String: String] = [:]
    func identity(_ syllable: String) -> String {
        syllable == "lo" ? "luo" : syllable.replacingOccurrences(of: "ue", with: "ve")
    }
    for syllable in ZiranmaShuangpin.syllables.sorted() {
        guard let code = ZiranmaShuangpin.syllableCode(syllable) else {
            return fail("inventory syllable \(syllable) has no code")
        }
        if let owner = owners[code], identity(owner) != identity(syllable) {
            return fail("\(syllable) and \(owner) share \(code)")
        }
        owners[code] = syllable
    }

    do {
        let fly = ChordKeymapProfile.builtIn(from: try FlyChordSchemaParser.loadDefault())
        var isaac = fly.duplicated(name: "Isaac2026")
        isaac.outputEncoding = .ziranma
        isaac = try isaac.validated()
        for entry in isaac.mappings where isaac.engineOutput(for: entry) == nil {
            return fail("FlyYao mapping \(entry.keys)→\(entry.output) does not encode")
        }
        let data = try JSONEncoder().encode(isaac)
        guard try JSONDecoder().decode(ChordKeymapProfile.self, from: data) == isaac else {
            return fail("ziranma profile JSON round trip")
        }
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "outputEncoding")
        let legacyProfile = try JSONDecoder().decode(
            ChordKeymapProfile.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        guard legacyProfile.outputEncoding == .fullPinyin else {
            return fail("a profile without outputEncoding must stay full pinyin")
        }

        var broken = isaac
        broken.mappings[0] = ChordKeymapEntry(keys: broken.mappings[0].keys, output: "zhx", kind: .syllable)
        guard (try? broken.validated()) == nil else { return fail("ziranma accepted a non-syllable output") }
        var builtInZiranma = fly
        builtInZiranma.outputEncoding = .ziranma
        guard (try? builtInZiranma.validated()) == nil else { return fail("built-in accepted ziranma") }

        let yaml = try ChordKeymapCompiler.schemaYAML(for: isaac)
        let zhangIndex = isaac.mappings.firstIndex { $0.output == "zhang" }!
        let fullYAML = try ChordKeymapCompiler.schemaYAML(for: fly.duplicated(name: "Isaac2025"))
        guard yaml.contains("prism: rimes_chord_ziranma"),
              yaml.contains("'xform/^~\(zhangIndex)~$/vh/'"),
              yaml.contains("'xlit/ⓆⓌⓇⓉⓎⓊⒾⓄⓅⓈⒹⒻⒼⒽⓂⒿⒸⓀⓁⓏⓍⓋⒷⓃ/qwrtyuiopsdfghmjcklzxvbn/'"),
              yaml.contains("'xform/(^|[ ''])v/$1zh/'"),
              yaml.contains("user_dict: en_dicts/cn_en_double_pinyin"),
              yaml.contains("timestamp: timestamp"),
              yaml.contains("lunar: lunar"),
              !yaml.contains("pin_cand_filter:"),
              !yaml.contains("abbrev"),
              fullYAML.contains("prism: rime_ice"),
              fullYAML.contains("__include: rime_ice.schema:/speller"),
              fullYAML.contains("'xform/^~\(zhangIndex)~$/zhang/'"),
              !fullYAML.contains("rimes_chord_ziranma") else {
            return fail("compiled schema YAML")
        }
        let preview = try ChordKeymapEditorViewController.preview(profile: isaac, keys: "hv")
        guard preview.contains("zhang（自然码 vh）") else { return fail("editor preview \(preview)") }
        print("chord-ziranma-smoke: PASS \(syllables.count) syllable codes, \(fragments.count) fragment codes, \(owners.count) unique inventory codes, \(isaac.mappings.count) FlyYao mappings encode")
        return true
    } catch {
        return fail(error.localizedDescription)
    }
}

/// Deploys Isaac2025 (full pinyin) and Isaac2026 (自然码) from the FlyYao
/// table inside the disposable engine-smoke tree and compares every mapping:
/// raw input, pinyin preedit and first-page candidates. With a report
/// directory it also writes both profile snapshots and the per-mapping table.
func runChordZiranmaEngineSmokeTest(reportDirectory: URL?) -> Bool {
    func fail(_ message: String) -> Bool {
        print("chord-ziranma-engine-smoke: FAIL \(message)")
        return false
    }
    struct Observation {
        var input = ""
        var preedit = ""
        var candidates: [String] = []
    }
    func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    /// Consecutive chords with no apostrophe between them. Full pinyin can
    /// read these several ways; two-key codes cannot. The word must reach the
    /// first page; rime_ice's pin filter may still lift a pinned single
    /// character (激昂 letters spell the pin key jiang, so 及 rises).
    let unmarkedPairs: [(keys: [String], word: String)] = [
        (["xi", "an"], "西安"), (["fh", "an"], "方案"), (["djk", "an"], "答案"),
        (["dh", "an"], "档案"), (["wry", "an"], "平安"), (["qi", "eij"], "企鹅"),
        (["cvi", "ah"], "激昂"), (["xcl", "xvu"], "海鸥"), (["tm", "an"], "天安"),
    ]

    do {
        let root = ChordKeymapRuntimeFiles.userRoot
        let files = ChordKeymapRuntimeFiles(root: root)
        let fly = ChordKeymapProfile.builtIn(from: try FlyChordSchemaParser.loadDefault())
        let isaac2025 = try fly.duplicated(name: "Isaac2025").validated()
        var draft2026 = fly.duplicated(name: "Isaac2026")
        draft2026.outputEncoding = .ziranma
        let isaac2026 = try draft2026.validated()

        let engine = RimeEngine()
        /// The live replay's apostrophe plan, driven the way RIMESController
        /// drives it: boundaries come from the context before each chord.
        func boundedInput(_ profile: ChordKeymapProfile, _ chords: [String]) -> String? {
            let session = engine.createSession()
            guard session != 0 else { return nil }
            defer { engine.destroySession(session) }
            guard engine.selectSchema(profile.schemaID, session: session) else { return nil }
            engine.setOption("ascii_mode", false, session: session)
            for chord in chords {
                let codes = chord.unicodeScalars.map { Int32($0.value) }
                let plan = ChordKeymapBoundaryRules.plan(for: engine.getContext(session: session),
                                                         profile: profile)
                let delimit = ChordKeymapBoundaryRules.shouldInsert(keys: codes, profile: profile)
                if delimit && plan.before { _ = engine.processKey(0x27, session: session) }
                for key in codes { _ = engine.processKey(key, session: session) }
                for key in codes { _ = engine.processKey(key, mask: RimeKey.releaseMask, session: session) }
                if delimit && plan.after { _ = engine.processKey(0x27, session: session) }
            }
            return engine.getContext(session: session).input
        }
        func observe(_ profile: ChordKeymapProfile)
            -> (mappings: [String: Observation], pairs: [String: Observation])? {
            let session = engine.createSession()
            guard session != 0 else { return nil }
            defer { engine.destroySession(session) }
            guard engine.selectSchema(profile.schemaID, session: session) else { return nil }
            engine.setOption("ascii_mode", false, session: session)
            func stroke(_ keys: String) {
                let codes = keys.unicodeScalars.map { Int32($0.value) }
                for key in codes { _ = engine.processKey(key, session: session) }
                for key in codes { _ = engine.processKey(key, mask: RimeKey.releaseMask, session: session) }
            }
            func snapshot() -> Observation {
                let context = engine.getContext(session: session)
                return Observation(input: context.input, preedit: context.preedit,
                                   candidates: context.candidates.map(\.text))
            }
            var mappings: [String: Observation] = [:]
            for entry in profile.mappings {
                engine.clearComposition(session: session)
                stroke(entry.keys)
                mappings[entry.keys] = snapshot()
            }
            var pairs: [String: Observation] = [:]
            for pair in unmarkedPairs {
                engine.clearComposition(session: session)
                pair.keys.forEach(stroke)
                pairs[pair.word] = snapshot()
            }
            engine.clearComposition(session: session)
            return (mappings, pairs)
        }

        let snapshot2026 = try files.prepare(isaac2026)
        guard engine.start(), ChordKeymapActivationCoordinator.verify(isaac2026, engine: engine),
              let observed2026 = observe(isaac2026) else {
            return fail("Isaac2026 did not compile or a chord did not produce its 自然码 code")
        }
        let boundaryCases: [(chords: [String], input: String)] = [
            (["ajk", "hv", "an"], "aa'vh'an"), (["eij", "eij", "xvo"], "ee'ee'oo"),
            (["xi", "an"], "xi'an"), (["efi", "jk"], "ui'a"),
        ]
        for boundary in boundaryCases {
            let input = boundedInput(isaac2026, boundary.chords)
            guard input == boundary.input else {
                return fail("delimiter plan \(boundary.chords) produced \(input ?? "nil"), expected \(boundary.input)")
            }
        }
        let snapshot2025 = try files.prepare(isaac2025)
        guard BBRimeDeploy(), ChordKeymapActivationCoordinator.verify(isaac2025, engine: engine),
              let observed2025 = observe(isaac2025) else {
            return fail("Isaac2025 did not compile or a chord did not produce its pinyin")
        }
        try files.restore(snapshot2025)
        try files.restore(snapshot2026)

        // rime_ice has no sei reading; full pinyin reached Han only through
        // initials-only abbreviations, which 自然码 deliberately drops.
        let withoutDictionaryReading: Set<String> = ["sei"]
        var rows = ["keys\tkind\tpinyin\tziranma\tinput2025\tinput2026\tpreedit2026\ttop2025\ttop2026\tstatus"]
        var failures: [String] = []
        var sameTop = 0
        var syllableCount = 0
        for entry in isaac2026.mappings {
            let code = isaac2026.engineOutput(for: entry) ?? ""
            let old = observed2025.mappings[entry.keys] ?? Observation()
            let new = observed2026.mappings[entry.keys] ?? Observation()
            var status: [String] = []
            if old.input != entry.output { status.append("2025-input") }
            if new.input != code { status.append("2026-input") }
            if entry.kind == .syllable {
                syllableCount += 1
                let spelling = { (text: String) in
                    text.replacingOccurrences(of: "ue", with: "ve")
                        .replacingOccurrences(of: "ü", with: "v")
                }
                if spelling(new.preedit) != spelling(entry.output),
                   !withoutDictionaryReading.contains(entry.output) { status.append("preedit") }
                let oldTop = old.candidates.first { hasHan($0) }
                let newTop = new.candidates.first { hasHan($0) }
                if oldTop != nil, oldTop == newTop { sameTop += 1 }
                if !withoutDictionaryReading.contains(entry.output) {
                    if let oldTop, !new.candidates.contains(oldTop) { status.append("2025-top-missing") }
                    if oldTop != nil, newTop == nil { status.append("no-han") }
                }
            }
            if !status.isEmpty { failures.append("\(entry.keys)→\(entry.output)[\(status.joined(separator: ","))]") }
            let fields = [entry.keys, entry.kind.rawValue, entry.output, code,
                          old.input, new.input, new.preedit,
                          old.candidates.first ?? "", new.candidates.first ?? "",
                          status.isEmpty ? "ok" : status.joined(separator: ",")]
            rows.append(fields.joined(separator: "\t"))
        }

        var pairRows = ["word\tchords\tinput2025\ttop2025\tinput2026\ttop2026"]
        var pairsFirst2025 = 0
        var pairsFirst2026 = 0
        var pairsMissing2026: [String] = []
        for pair in unmarkedPairs {
            let old = observed2025.pairs[pair.word] ?? Observation()
            let new = observed2026.pairs[pair.word] ?? Observation()
            if old.candidates.first == pair.word { pairsFirst2025 += 1 }
            if new.candidates.first == pair.word { pairsFirst2026 += 1 }
            if !new.candidates.contains(pair.word) { pairsMissing2026.append(pair.word) }
            pairRows.append([pair.word, pair.keys.joined(separator: "+"), old.input,
                             old.candidates.first ?? "", new.input,
                             new.candidates.first ?? ""].joined(separator: "\t"))
        }

        if let reportDirectory {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            let store = ChordKeymapStore(rootURL: reportDirectory)
            try store.exportData(isaac2025).write(to: reportDirectory.appendingPathComponent("Isaac2025.json"))
            try store.exportData(isaac2026).write(to: reportDirectory.appendingPathComponent("Isaac2026.json"))
            try (rows.joined(separator: "\n") + "\n")
                .write(to: reportDirectory.appendingPathComponent("isaac2026-mappings.tsv"),
                       atomically: true, encoding: .utf8)
            try (pairRows.joined(separator: "\n") + "\n")
                .write(to: reportDirectory.appendingPathComponent("isaac2026-unmarked-pairs.tsv"),
                       atomically: true, encoding: .utf8)
        }
        print("chord-ziranma-engine-smoke: \(isaac2026.mappings.count) mappings, \(syllableCount) syllables, same first candidate \(sameTop)/\(syllableCount), unmarked pairs first candidate 全拼 \(pairsFirst2025)/\(unmarkedPairs.count) vs 自然码 \(pairsFirst2026)/\(unmarkedPairs.count)")
        guard failures.isEmpty else {
            return fail("\(failures.count) mappings: \(failures.prefix(40).joined(separator: " "))")
        }
        guard pairsMissing2026.isEmpty else {
            return fail("自然码 lost unmarked pairs \(pairsMissing2026): \(pairRows.dropFirst().joined(separator: " | "))")
        }
        print("chord-ziranma-engine-smoke: PASS every chord's code, pinyin preedit and first-page candidates")
        return true
    } catch {
        return fail(error.localizedDescription)
    }
}
