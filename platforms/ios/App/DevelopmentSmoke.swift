#if DEBUG
import Foundation
import UIKit
import RimesCore

/// Explicit development diagnostic using the shipped engine and data. No customer content.
@MainActor enum DevelopmentSmoke {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--engine-smoke") else { return }
        var checks: [[String:Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        let engine = MobileEngine()
        let coldMs = (ProcessInfo.processInfo.systemUptime-start)*1000
        for (schema,code,expected) in [("rimes_pinyin","nihao","你好"),("rimes_ziranma","nihk","你好"),("rimes_wubi","wq","你")] {
            let selected = engine.select(schema:schema)
            var state = EngineSnapshot(), times = [Double]()
            for c in code.unicodeScalars {
                let t = ProcessInfo.processInfo.systemUptime; state = engine.process(key:Int32(c.value)); times.append((ProcessInfo.processInfo.systemUptime-t)*1000)
            }
            let index = state.candidates.firstIndex(of:expected)
            let committed = index.map { engine.candidate($0).commit } ?? ""
            checks.append(["schema":schema,"passed":selected && committed == expected,"keyMilliseconds":times])
            engine.clear()
        }
        let id = UUID(), keychain = KeychainStore()
        do { try keychain.save("development-only",id:id); let good = try keychain.read(id)=="development-only"; try keychain.delete(id); checks.append(["keychain":true,"passed":good]) }
        catch { checks.append(["keychain":true,"passed":false,"osStatus":(error as NSError).code]) }
        #if targetEnvironment(simulator)
        let environment = "iOS simulator, not physical-device acceptance"
        #else
        let environment = "iOS device engine smoke, not full keyboard acceptance"
        #endif
        let report: [String:Any] = ["checks":checks,"engineInitializationMilliseconds":coldMs,"environment":environment,"osVersion":UIDevice.current.systemVersion,"deviceModel":UIDevice.current.model,"allPassed":checks.allSatisfy { $0["passed"] as? Bool == true }]
        do {
            let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("development-smoke.json")
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        } catch { assertionFailure("Could not write smoke report") }
    }
}
#endif
