import XCTest
@testable import RIMES

final class TextClipboardStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    func testVerbatimRoundTripDeduplicationDeletionAndClear() throws {
        let store = TextClipboardStore(root: root)
        let text = " \n中😀e\u{301}\n "
        let first = try XCTUnwrap(store.collect(text).first)
        _ = try store.collect("second"); _ = try store.collect(text)
        XCTAssertEqual(TextClipboardStore(root: root).load().map(\.text), [text, "second"])
        XCTAssertEqual(store.load().first?.id, first.id)
        XCTAssertEqual(try store.remove(first.id).map(\.text), ["second"])
        try store.clear(); XCTAssertTrue(store.load().isEmpty)
    }
    func testEntryAndTotalByteLimitsAreAtomicAndEvictOldest() throws {
        let store = TextClipboardStore(root: root)
        _ = try store.collect("keep")
        XCTAssertThrowsError(try store.collect(""))
        XCTAssertThrowsError(try store.collect(String(repeating: "字", count: 6000)))
        XCTAssertEqual(store.load().map(\.text), ["keep"])
        for i in 0..<12 { _ = try store.collect("\(i)" + String(repeating: "x", count: 16380)) }
        XCTAssertLessThanOrEqual(store.load().reduce(0, { $0 + $1.text.utf8.count }), TextClipboardStore.maximumBytes)
        XCTAssertTrue(store.load().first!.text.hasPrefix("11"))
        XCTAssertFalse(store.load().contains { $0.text == "keep" })
    }
    func testCanonicallyEquivalentTextPreservesEachExactUTF8Sequence() throws {
        let store = TextClipboardStore(root: root)
        let composed = "\u{E9}", decomposed = "e\u{301}"
        _ = try store.collect(composed); _ = try store.collect(decomposed)
        XCTAssertEqual(store.load().map { Array($0.text.utf8) }, [Array(decomposed.utf8), Array(composed.utf8)])
        _ = try store.collect(composed)
        XCTAssertEqual(TextClipboardStore(root: root).load().map { Array($0.text.utf8) }, [Array(composed.utf8), Array(decomposed.utf8)])
    }
    func testCountLimitAndCorruptArchivesFailClosed() throws {
        let store = TextClipboardStore(root: root)
        for i in 0..<60 { _ = try store.collect("item \(i)") }
        XCTAssertEqual(store.load().count, 40)
        let file = root.appendingPathComponent("history-v1.json")
        try Data("{\"version\":2,\"entries\":[]}".utf8).write(to: file)
        XCTAssertTrue(store.load().isEmpty)
        try Data("not json".utf8).write(to: file); XCTAssertTrue(store.load().isEmpty)
    }
    func testHistoryIsPrivateExcludedFromBackupAndRejectsSymlinks() throws {
        let store = TextClipboardStore(root: root)
        _ = try store.collect("local")
        let file = root.appendingPathComponent("history-v1.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let outside = root.appendingPathComponent("outside.json")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertTrue(store.load().isEmpty); XCTAssertThrowsError(try store.collect("new"))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }
}
