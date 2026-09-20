import Foundation

public enum InputScheme: String, Codable, CaseIterable, Identifiable {
    case pinyin, ziranma, wubi86, english, chord
    public var id: String { rawValue }
    public var title: String { switch self { case .pinyin: return "全拼 · Pinyin"; case .ziranma: return "自然码 · Ziranma"; case .wubi86: return "五笔 86 · Wubi"; case .english: return "English"; case .chord: return "并击 · Chord" } }
    public var schemaID: String { switch self { case .pinyin, .chord: return "rimes_pinyin"; case .ziranma: return "rimes_ziranma"; case .wubi86: return "rimes_wubi"; case .english: return "" } }
}
public struct EngineSnapshot {
    public var preedit: String
    public var candidates: [String]
    public var commit: String
    public init(preedit: String = "", candidates: [String] = [], commit: String = "") { self.preedit = preedit; self.candidates = candidates; self.commit = commit }
}
public protocol InputEngine: AnyObject {
    func select(schema: String) -> Bool
    func process(key: Int32) -> EngineSnapshot
    func candidate(_ index: Int) -> EngineSnapshot
    func clear()
}
public enum TextBlocks {
    /// Preserve every original character, including inter-sentence whitespace.
    public static func split(_ text: String) -> [String] {
        var blocks: [String] = [], current = ""
        for c in text {
            current.append(c)
            if "。！？!?\n".contains(c) || current.count >= 160 { blocks.append(current); current = "" }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }
}
public struct BufferSession {
    public private(set) var source = ""
    public private(set) var sourceRevision = UUID()
    public private(set) var generation: UUID?
    public private(set) var preview = ""
    public private(set) var result: [String]?
    public private(set) var cursor = 0 // Character offset, not UTF-16.
    public private(set) var requestSourceRevision: UUID?
    public init() {}
    public var generating: Bool { generation != nil }
    public mutating func edit(_ text: String, cursor: Int? = nil) {
        source = text; self.cursor = min(max(0, cursor ?? text.count), text.count)
        sourceRevision = UUID(); cancel(); result = nil; preview = ""
    }
    public mutating func moveCursor(_ offset: Int) { cursor = min(max(0, cursor + offset), source.count) }
    public mutating func insert(_ text: String) {
        let i = source.index(source.startIndex, offsetBy: cursor)
        var new = source; new.insert(contentsOf: text, at: i); edit(new, cursor: cursor + text.count)
    }
    public mutating func backspace() {
        guard cursor > 0 else { return }
        var new = source; new.remove(at: new.index(new.startIndex, offsetBy: cursor - 1)); edit(new, cursor: cursor - 1)
    }
    public mutating func begin() -> UUID {
        let id = UUID(); generation = id; requestSourceRevision = sourceRevision; preview = ""; result = nil; return id
    }
    public mutating func receive(_ text: String, id: UUID) {
        guard generation == id, requestSourceRevision == sourceRevision else { return }; preview = text
    }
    public mutating func finish(_ text: String, id: UUID) {
        guard generation == id, requestSourceRevision == sourceRevision else { return }
        result = TextBlocks.split(text); preview = text; generation = nil
    }
    public mutating func cancel() { generation = nil; requestSourceRevision = nil; preview = "" }
    public var pending: [String] { result ?? TextBlocks.split(source) }
    /// Called only after one explicit foreground proxy insertion. Never retries automatically.
    public mutating func consumed(all: Bool) {
        guard !generating else { return }
        if var blocks = result { if all { blocks = [] } else if !blocks.isEmpty { blocks.removeFirst() }; result = blocks; if blocks.isEmpty { edit("") } }
        else { let remainder = all ? "" : TextBlocks.split(source).dropFirst().joined(); edit(remainder) }
    }
}
