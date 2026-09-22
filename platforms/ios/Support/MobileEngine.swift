import Foundation
import RimesCore

final class MobileEngine: InputEngine {
    private var bridge: RimeMobile?
    private var rawSnapshot = EngineSnapshot()
    private var provenance = RawInputProvenance()
    var rawInput: String { bridge?.rawInput ?? "" }
    var literalInput: String { provenance.literal }
    var traditional = false
    private(set) var available = false
    /// Refresh presentation without consuming Rime state or replaying a commit.
    var currentSnapshot: EngineSnapshot {
        .init(preedit: rawSnapshot.preedit, candidates: rawSnapshot.candidates.map(output))
    }
    init() {
        guard let resources = Bundle.main.url(forResource: "EngineData", withExtension: nil),
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("build/rimes_pinyin.schema.yaml").path) else { return }
        var user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RimeUser", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try user.setResourceValues(values)
            bridge = RimeMobile(resources: resources.path, userDirectory: user.path)
            available = bridge != nil
        } catch { available = false }
    }
    func select(schema: String) -> Bool { rawSnapshot = .init(); provenance.reset(); available = bridge?.selectSchema(schema) ?? false; return available }
    func process(key: Int32) -> EngineSnapshot { snapshot(bridge?.processKey(key)) }
    func handledKey(_ key: Int32, generatedSeparator: Bool = false) -> (EngineSnapshot, Bool) {
        let before = rawInput, caret = Int(bridge?.inputCaret ?? 0)
        let value = bridge?.processKey(key)
        let state = snapshot(value)
        if generatedSeparator, key == 39, caret <= before.utf8.count {
            let expected = String(before.prefix(caret)) + "'" + String(before.dropFirst(caret))
            if rawInput == expected { provenance.update(rawInput, generatedSeparatorAt: caret) }
        }
        return (state, value?["handled"] as? Bool ?? false)
    }
    func candidate(_ index: Int) -> EngineSnapshot { snapshot(bridge?.selectCandidate(UInt(index))) }
    func clear() { bridge?.clear(); rawSnapshot = .init(); provenance.reset() }
    private func snapshot(_ value: [AnyHashable: Any]?) -> EngineSnapshot {
        provenance.update(rawInput)
        rawSnapshot = .init(preedit: value?["preedit"] as? String ?? "", candidates: value?["candidates"] as? [String] ?? [], commit: value?["commit"] as? String ?? "")
        return .init(preedit: rawSnapshot.preedit, candidates: rawSnapshot.candidates.map(output), commit: output(rawSnapshot.commit))
    }
    private func output(_ text: String) -> String {
        // Keep native candidate indices and learning intact. Foundation's local
        // ICU transform projects both the candidates and their committed text.
        guard traditional, !text.isEmpty else { return text }
        return text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }
}
