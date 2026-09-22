import Foundation
import RimesCore

final class MobileEngine: InputEngine {
    private var bridge: RimeMobile?
    private(set) var available = false
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
    func select(schema: String) -> Bool { available = bridge?.selectSchema(schema) ?? false; return available }
    func process(key: Int32) -> EngineSnapshot { snapshot(bridge?.processKey(key)) }
    func handledKey(_ key: Int32) -> (EngineSnapshot, Bool) {
        let value = bridge?.processKey(key); return (snapshot(value), value?["handled"] as? Bool ?? false)
    }
    func candidate(_ index: Int) -> EngineSnapshot { snapshot(bridge?.selectCandidate(UInt(index))) }
    func clear() { bridge?.clear() }
    private func snapshot(_ value: [AnyHashable: Any]?) -> EngineSnapshot {
        .init(preedit: value?["preedit"] as? String ?? "", candidates: value?["candidates"] as? [String] ?? [], commit: value?["commit"] as? String ?? "")
    }
}
