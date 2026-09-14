import Foundation
import NaturalLanguage

/// A sentence-sized source owner, not one of the small, post-translation
/// display chips. Identity survives edits outside its exact source slices.
struct TranslationSourceUnit {
    let id: UUID
    var slices: [BufferSourceSlice]
    var sourceText: String
    let closesSentence: Bool
    let allowsRemoteMirror: Bool
    var output: [TranslationOutputBlock] = []

    /// Once delivery begins, the source is retired atomically and the unsent
    /// translation becomes an independent, immutable pending value.
    var sourceRetired = false
}

enum TranslationSourceUnitBuilder {
    static func build(from blocks: [BufferModel.Block]) -> [TranslationSourceUnit] {
        let text = blocks.map(\.text).joined()
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            // Bound provider fan-out for large pastes. The last range below
            // owns the entire remaining suffix, so nothing is truncated.
            return ranges.count < SemanticBlockSegmenter.maximumWorkbenchSegments
        }
        // Preserve every byte, including whitespace omitted by the tokenizer.
        // The final tail is translated too, but any tail edit replaces its
        // identity/result and therefore restarts its lifetime.
        if ranges.isEmpty {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            ranges = [text.startIndex..<text.endIndex]
        }
        var start = text.startIndex
        var units: [TranslationSourceUnit] = []
        for index in ranges.indices {
            let end = index + 1 < ranges.count
                ? ranges[index + 1].lowerBound : text.endIndex
            let value = String(text[start..<end])
            let range = NSRange(start..<end, in: text)
            if let slices = BufferSourceSlice.capture(range: range, in: blocks) {
                let ids = Set(slices.map(\.blockID))
                units.append(TranslationSourceUnit(
                    id: UUID(), slices: slices, sourceText: value,
                    closesSentence: isSentenceEnd(value),
                    allowsRemoteMirror: blocks.filter { ids.contains($0.id) }
                        .allSatisfy { $0.origin.allowsRemoteMirror }
                ))
            }
            start = end
        }
        return units
    }

    private static func isSentenceEnd(_ text: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"'”’）)]】》」』")
            .union(.whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: closers)
        return body.last.map { "。！？.!?".contains($0) } == true
            || text.contains("\n")
    }

    static func translatedText(_ translation: String,
                               for unit: TranslationSourceUnit,
                               targetLanguageID: String) -> String {
        var result = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        let leading = String(unit.sourceText.prefix(while: \.isWhitespace))
        result = leading + result
        let trailing = String(unit.sourceText.reversed().prefix(while: \.isWhitespace).reversed())
        if !trailing.isEmpty {
            result += trailing
        } else if !["zh", "ja", "th", "lo", "km", "my"].contains(
                    Locale.Language(identifier: targetLanguageID).languageCode?.identifier ?? ""
                  ) {
            result += " "
        }
        return result
    }
}
