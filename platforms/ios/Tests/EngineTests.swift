import XCTest
@testable import RIMES
import RimesCore

@MainActor final class EngineTests: XCTestCase {
    func testBundledChineseEngines() throws {
        let engine = MobileEngine()
        XCTAssertTrue(engine.available)
        for (schema,code,expected) in [("rimes_pinyin","nihao","你好"),("rimes_ziranma","nihk","你好"),("rimes_wubi","wq","你")] {
            XCTAssertTrue(engine.select(schema:schema),schema)
            var state = EngineSnapshot()
            for c in code.unicodeScalars { state = engine.process(key:Int32(c.value)) }
            let index = try XCTUnwrap(state.candidates.firstIndex(of:expected),"\(schema): \(state.candidates)")
            XCTAssertEqual(engine.candidate(index).commit,expected)
            engine.clear()
        }
    }
    func testSwitchingSchemaRetiresComposition() {
        let engine = MobileEngine(); XCTAssertTrue(engine.select(schema:"rimes_pinyin"))
        _ = engine.process(key:110); _ = engine.process(key:105)
        XCTAssertTrue(engine.select(schema:"rimes_wubi"))
        let state = engine.process(key:119)
        XCTAssertFalse(state.preedit.contains("ni"))
    }
    func testKeychainRoundTripAndNoKeyInConfig() throws {
        let store = KeychainStore(), id = UUID()
        defer { try? store.delete(id) }
        try store.save("test-only-local-key",id:id)
        XCTAssertEqual(try store.read(id),"test-only-local-key")
        try store.delete(id); XCTAssertEqual(try store.read(id),"")
        XCTAssertFalse(String(data:try JSONEncoder().encode(AppConfiguration()),encoding:.utf8)!.contains("test-only-local-key"))
    }
}
