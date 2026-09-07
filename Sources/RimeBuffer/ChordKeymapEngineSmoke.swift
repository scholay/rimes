import Cocoa
import CRimeBridge

/// Runs only after main.swift has configured a disposable Vendor+rime-data
/// tree. Exercises actual librime compilation, not a Swift regex substitute.
func runChordKeymapEngineSmokeTest() -> Bool {
    do {
        let root = ChordKeymapRuntimeFiles.userRoot
        let files = ChordKeymapRuntimeFiles(root: root)
        var custom = ChordKeymapProfile.newProfile(name: "并击引擎测试")
        custom.leftKeys = "abcdq"
        custom.rightKeys = "efgkm,."
        custom.mappings = [
            .init(keys: "ab", output: "cd", kind: .fragment),
            .init(keys: "cd", output: "ni", kind: .syllable),
            .init(keys: "ae", output: "hao", kind: .syllable),
            .init(keys: "ac", output: "n", kind: .fragment),
            .init(keys: "ef", output: "ong", kind: .fragment),
            .init(keys: "acef", output: "nong", kind: .syllable),
            .init(keys: "qkm", output: "qiong", kind: .syllable),
            .init(keys: "b,", output: "lve", kind: .syllable),
        ]
        custom = try custom.validated()
        let originalList = try Data(contentsOf: root.appendingPathComponent("default.custom.yaml"))
        let snapshot = try files.prepare(custom)
        let engine = RimeEngine()
        guard engine.start(), ChordKeymapActivationCoordinator.verify(custom, engine: engine) else {
            print("FAIL: generated schema did not compile or mapping mismatch")
            return false
        }
        var session = engine.createSession()
        defer { engine.destroySession(session) }
        guard engine.selectSchema(custom.schemaID, session: session) else { return false }
        engine.setOption("ascii_mode", false, session: session)
        func stroke(_ keys: String, boundary: Bool = false) -> String {
            let keycodes = keys.unicodeScalars.map { Int32($0.value) }
            let before = engine.getContext(session: session)
            let plan = ChordKeymapBoundaryRules.plan(for: before, profile: custom)
            let delim = boundary && ChordKeymapBoundaryRules.shouldInsert(keys: keycodes, profile: custom)
            if delim && plan.before { _ = engine.processKey(0x27, session: session) }
            for key in keycodes { _ = engine.processKey(key, session: session) }
            for key in keycodes { _ = engine.processKey(key, mask: RimeKey.releaseMask, session: session) }
            if delim && plan.after { _ = engine.processKey(0x27, session: session) }
            return engine.getContext(session: session).input
        }
        for entry in custom.mappings {
            engine.clearComposition(session: session)
            guard stroke(String(entry.keys.reversed())) == entry.output else {
                print("FAIL: reversed mapping", entry.keys)
                return false
            }
        }
        engine.clearComposition(session: session)
        guard stroke("dba") == "abd" else { print("FAIL: unknown chord fallback"); return false }
        engine.clearComposition(session: session)
        guard stroke("db,.") == "bd" else { print("FAIL: unknown punctuation fallback"); return false }
        engine.clearComposition(session: session)
        guard stroke(",.").isEmpty else { print("FAIL: punctuation-only unknown chord"); return false }
        engine.clearComposition(session: session)
        guard stroke("c") == "c", stroke("a") == "ca" else { return false }
        engine.clearComposition(session: session)
        guard stroke("cd", boundary: true) == "ni'",
              stroke("ae", boundary: true) == "ni'hao'",
              engine.getContext(session: session).candidates.contains(where: { $0.text == "你好" }) else {
            print("FAIL: full-syllable boundaries/candidates", engine.getContext(session: session).input)
            return false
        }
        engine.clearComposition(session: session)
        guard stroke("ac", boundary: true) == "n", stroke("ef", boundary: true) == "nong" else {
            print("FAIL: fragments were separated")
            return false
        }
        engine.destroySession(session)
        session = 0

        // A same-ID edit must replace compiled data; restoring exact source
        // bytes must restore the prior behavior too.
        custom.mappings[1].output = "wo"
        try files.writeSchema(for: custom)
        guard BBRimeDeploy(), ChordKeymapActivationCoordinator.verify(custom, engine: engine) else {
            print("FAIL: same-ID deployment retained stale map")
            return false
        }
        let fly = ChordKeymapProfile.builtIn(from: try FlyChordSchemaParser.loadDefault())
        let copy = fly.duplicated(name: "飞耀生成一致性")
        let empty = RimeContextModel()
        guard copy.boundaryPolicy == .legacyBatches,
              ChordKeymapBoundaryRules.shouldInsert(keys: [100, 118], profile: copy),
              !ChordKeymapBoundaryRules.plan(for: empty, profile: copy).after,
              !ChordKeymapBoundaryRules.mayAwaitComplement(keys: [99, 100], profile: custom),
              ChordKeymapBoundaryRules.mayAwaitComplement(keys: [97, 99], profile: custom),
              ChordKeymapBoundaryRules.mayCombine(keys: [97, 99, 101, 102], profile: custom),
              !ChordKeymapBoundaryRules.mayCombine(keys: [97, 99, 107], profile: custom) else {
            print("FAIL: legacy preset/custom explicit boundary policy")
            return false
        }
        _ = try files.prepare(copy)
        guard BBRimeDeploy(), ChordKeymapActivationCoordinator.verify(copy, engine: engine) else {
            print("FAIL: generated FlyYao preset differs from canonical mappings")
            return false
        }
        try files.restore(snapshot)
        guard try Data(contentsOf: snapshot.listURL) == originalList,
              !FileManager.default.fileExists(atPath: root.appendingPathComponent(custom.schemaID + ".schema.yaml").path),
              BBRimeDeploy(), ChordKeymapActivationCoordinator.verify(fly, engine: engine) else {
            print("FAIL: deployment rollback did not restore FlyYao")
            return false
        }
        print("PASS: custom schema, reversed chords, collisions, full/fragment boundaries, Chinese candidates, same-ID edit, \(copy.mappings.count) FlyYao mappings and rollback")
        return true
    } catch {
        print("FAIL: chord-keymap engine smoke", error.localizedDescription)
        return false
    }
}
