import Foundation

/// Tracks only separators inserted by the chord resolver, never guesses from preedit.
public struct RawInputProvenance {
    private var text = [Character]()
    private var generated = Set<Int>()
    public init() {}
    public var literal: String { String(text.enumerated().compactMap { generated.contains($0.offset) ? nil : $0.element }) }
    public mutating func reset() { text = []; generated = [] }
    public mutating func update(_ raw: String, generatedSeparatorAt index: Int? = nil) {
        let next = Array(raw)
        var prefix = 0
        while prefix < min(text.count, next.count), text[prefix] == next[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(text.count - prefix, next.count - prefix), text[text.count - 1 - suffix] == next[next.count - 1 - suffix] { suffix += 1 }
        generated = Set(generated.compactMap { position in
            if position < prefix { return position }
            if position >= text.count - suffix { return position + next.count - text.count }
            return nil
        })
        if let index, next.indices.contains(index), next[index] == "'" { generated.insert(index) }
        text = next
    }
}
