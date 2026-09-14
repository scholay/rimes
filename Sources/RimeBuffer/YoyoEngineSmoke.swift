import Foundation
import CRimeBridge

/// Activates each bundled 呦呦音形 preset through the real keymap activation
/// path in the disposable engine-smoke tree, then plays physical chords the
/// way a keyboard delivers them. librime's chord_composer settles a chord on
/// its last release, the yoyo popping processor commits, and the result is
/// compared with the codes the scheme publishes.
func runYoyoEngineSmokeTest() -> Bool {
    func fail(_ message: String) -> Bool {
        print("yoyo-engine-smoke: FAIL \(message)")
        return false
    }

    struct Expectation {
        let chords: [String]
        let commit: String
        let firstCandidate: String?
    }
    // Fingerings from yoyo's zigen_table/fingering-{yx,hm}.json. The right
    // hand is the left-hand mirror each fingering declares in yoyo.yaml:
    // 折梅 q↔[ a↔; 4↔9 …, 寒梅 q↔p a↔; z↔/ ….
    let cases: [(ChordKeymapProfile, [Expectation])] = [
        (NativeChordSchemeCatalog.yoyoZhemei, [
            .init(chords: ["q"], commit: "吃", firstCandidate: nil),
            .init(chords: ["["], commit: "没有", firstCandidate: nil),
            .init(chords: ["q "], commit: "每天", firstCandidate: nil),
            .init(chords: ["[ "], commit: "模型", firstCandidate: nil),
            .init(chords: ["rta "], commit: "中国", firstCandidate: nil),
            .init(chords: ["qejn"], commit: "", firstCandidate: "世界"),
            .init(chords: ["qwkn "], commit: "", firstCandidate: "鸣"),
            .init(chords: ["asd9p", "qefljn"], commit: "", firstCandidate: "动物园"),
        ]),
        (NativeChordSchemeCatalog.yoyoHanmei, [
            .init(chords: ["q"], commit: "吃", firstCandidate: nil),
            .init(chords: ["p"], commit: "没有", firstCandidate: nil),
            .init(chords: ["q "], commit: "每天", firstCandidate: nil),
            .init(chords: ["p "], commit: "模型", firstCandidate: nil),
            .init(chords: ["ac "], commit: "中国", firstCandidate: nil),
            .init(chords: ["ex,m"], commit: "", firstCandidate: "世界"),
            .init(chords: ["qf;m "], commit: "", firstCandidate: "鸣"),
            .init(chords: ["wdfoi", "sfl,m"], commit: "", firstCandidate: "动物园"),
        ]),
    ]

    let root = ChordKeymapRuntimeFiles.userRoot
    let files = ChordKeymapRuntimeFiles(root: root)
    let engine = RimeEngine()
    func keysym(_ character: Character) -> Int32 {
        Int32(character.unicodeScalars.first!.value)
    }

    var failures: [String] = []
    var started = false
    for (preset, expectations) in cases {
        let deployStart = Date()
        do {
            _ = try files.prepare(preset)
        } catch {
            return fail("prepare \(preset.name): \(error.localizedDescription)")
        }
        let deployed = started ? BBRimeDeploy() : engine.start()
        started = true
        guard deployed, ChordKeymapActivationCoordinator.verify(preset, engine: engine) else {
            return fail("\(preset.name) did not deploy or select")
        }
        print("yoyo-engine-smoke: \(preset.name) deployed in \(String(format: "%.1f", Date().timeIntervalSince(deployStart)))s")

        let session = engine.createSession()
        guard session != 0, engine.selectSchema(preset.schemaID, session: session) else {
            return fail("no \(preset.schemaID) session")
        }
        defer { engine.destroySession(session) }
        engine.setOption("ascii_mode", false, session: session)

        func chord(_ keys: String) -> String {
            let codes = keys.map(keysym)
            for code in codes { _ = engine.processKey(code, session: session) }
            for code in codes.reversed() {
                _ = engine.processKey(code, mask: RimeKey.releaseMask, session: session)
            }
            return engine.takeCommit(session: session) ?? ""
        }

        for expectation in expectations {
            engine.clearComposition(session: session)
            let committed = expectation.chords.map(chord).joined()
            let context = engine.getContext(session: session)
            let shown = "\(preset.schemaID) [\(expectation.chords.joined(separator: " + "))]"
            if committed != expectation.commit {
                failures.append("\(shown) committed \(committed.isEmpty ? "nothing" : committed), expected \(expectation.commit.isEmpty ? "nothing" : expectation.commit)")
            }
            if let first = expectation.firstCandidate, context.candidates.first?.text != first {
                failures.append("\(shown) first candidate \(context.candidates.first?.text ?? "none"), expected \(first)")
            }
        }

        // A chord settles only when its last key is released: releasing one
        // key of 车 (_qF) must commit nothing yet.
        engine.clearComposition(session: session)
        let first: Character = "q"
        let second: Character = preset == NativeChordSchemeCatalog.yoyoZhemei ? "w" : "f"
        _ = engine.processKey(keysym(first), session: session)
        _ = engine.processKey(keysym(second), session: session)
        _ = engine.processKey(keysym(first), mask: RimeKey.releaseMask, session: session)
        let early = engine.takeCommit(session: session) ?? ""
        _ = engine.processKey(keysym(second), mask: RimeKey.releaseMask, session: session)
        let settled = engine.takeCommit(session: session) ?? ""
        if !early.isEmpty || settled != "车" {
            failures.append("\(preset.schemaID) partial release committed \(early.isEmpty ? "nothing" : early), last release \(settled.isEmpty ? "nothing" : settled); expected nothing then 车")
        }
        engine.clearComposition(session: session)
    }

    guard failures.isEmpty else { return fail(failures.joined(separator: "; ")) }
    print("yoyo-engine-smoke: PASS 折梅 and 寒梅 activate, 16 published chords, settle on last release")
    return true
}
