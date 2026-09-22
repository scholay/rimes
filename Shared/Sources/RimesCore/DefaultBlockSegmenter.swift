import Foundation

/// Stable identity for one host-created child of an upstream logical block.
/// Keeping the provider index separate from the child index prevents a growing
/// early stream block from stealing the UUID of a later provider block.
struct SemanticBlockKey: Hashable {
    let sourceIndex: Int
    let childIndex: Int
}

struct SemanticLogicalBlock {
    let sourceIndex: Int
    let text: String
    let title: String?
}

struct SemanticBlockFragment {
    let key: SemanticBlockKey
    let text: String
    let title: String?
}

/// Deterministic, grapheme-safe segmentation used at every workbench plugin
/// boundary. Upstream blocks remain hard containers; inside each container we
/// prefer sentences/clauses, then short English phrases, and finally a bounded
/// character fallback for punctuation-free CJK text.
public enum DefaultBlockSegmenter {
    static let preferredLatinWordCount = 4
    static let preferredCharacterCount = 48
    static let protectedCharacterCount = 160
    static let maximumWorkbenchSegments = 200

    private static let boundaryCharacters = Set<Character>(
        ["。", "！", "？", "!", "?", "；", ";", "，", ",", "：", ":", "."]
    )
    private static let closingCharacters = Set<Character>(
        ["”", "’", "\"", "'", "）", ")", "】", "]", "》", "〉", "」", "』"]
    )
    private static let URLTerminatingCharacters = Set<Character>(
        ["。", "！", "？", "；", "，", "：", "”", "’", "\"", "'", "）", "】", "》", "〉", "」", "』"]
    )
    private static let quotePairs: [Character: Character] = [
        "“": "”", "‘": "’", "「": "」", "『": "』", "《": "》", "〈": "〉",
        "\"": "\"", "'": "'",
    ]

    static func refine(_ logicalBlocks: [SemanticLogicalBlock],
                       maximumSegments: Int) -> [SemanticBlockFragment] {
        guard maximumSegments > 0 else { return [] }
        var fragments: [SemanticBlockFragment] = []
        for block in logicalBlocks.sorted(by: { $0.sourceIndex < $1.sourceIndex }) {
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            for (childIndex, text) in segments(from: block.text).enumerated() {
                fragments.append(SemanticBlockFragment(
                    key: SemanticBlockKey(sourceIndex: block.sourceIndex,
                                          childIndex: childIndex),
                    text: text,
                    title: childIndex == 0 ? block.title : nil
                ))
            }
        }
        guard fragments.count > maximumSegments else { return fragments }
        return compact(fragments, maximumSegments: maximumSegments)
    }

    /// Exact-text splitter shared by `refine` and incremental direct input.
    /// Leading/trailing whitespace is preserved and can be reconstructed by
    /// joining every returned segment.
    public static func segments(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var currentCount = 0
        var latinWordCount = 0
        var insideLatinWord = false
        var pendingBoundary = false
        var codeDelimiterLength: Int?
        var quoteClosers: [Character] = []
        var currentToken = ""
        var isInsideURL = false

        func flush() {
            guard !current.isEmpty else { return }
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if result.isEmpty {
                    // Preserve leading whitespace with the first semantic
                    // unit instead of manufacturing a whitespace-only block.
                    return
                }
                result[result.count - 1] += current
            } else {
                result.append(current)
            }
            current = ""
            currentCount = 0
            latinWordCount = 0
            insideLatinWord = false
            pendingBoundary = false
            currentToken = ""
            isInsideURL = false
        }

        let characters = Array(text)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            let previous = position > 0 ? characters[position - 1] : nil
            let next = position + 1 < characters.count ? characters[position + 1] : nil

            if character == "`" {
                var runLength = 1
                while position + runLength < characters.count,
                      characters[position + runLength] == "`" {
                    runLength += 1
                }
                let protected = codeDelimiterLength != nil
                    || !quoteClosers.isEmpty
                    || isInsideURL
                if pendingBoundary, !protected { flush() }
                if currentCount >= preferredCharacterCount,
                   !current.isEmpty,
                   !protected {
                    flush()
                }
                current += String(repeating: "`", count: runLength)
                currentCount += runLength
                currentToken = ""
                isInsideURL = false
                insideLatinWord = false
                if codeDelimiterLength == nil {
                    codeDelimiterLength = runLength
                } else if codeDelimiterLength == runLength {
                    codeDelimiterLength = nil
                }
                position += runLength
                continue
            }

            let terminatesURL = isInsideURL
                && (character.isWhitespace
                    || URLTerminatingCharacters.contains(character))
            if terminatesURL {
                isInsideURL = false
                currentToken = ""
            }
            let protected = codeDelimiterLength != nil
                || !quoteClosers.isEmpty
                || isInsideURL
            let whitespace = character.isWhitespace
            if pendingBoundary,
               !whitespace,
               !closingCharacters.contains(character),
               !protected {
                flush()
            }

            let latinBody = isASCIILatinWordBody(character)
            let latinJoiner = isLatinWordJoiner(
                character,
                previous: previous,
                next: next
            )
            let continuesLatinWord = latinBody || latinJoiner
            let characterLimit = protected
                ? protectedCharacterCount
                : preferredCharacterCount
            let attachesToPrevious = boundaryCharacters.contains(character)
                || closingCharacters.contains(character)
                || terminatesURL
            if currentCount >= characterLimit,
               !current.isEmpty,
               !attachesToPrevious,
               (!isInsideURL || currentCount >= protectedCharacterCount),
               (!(insideLatinWord && continuesLatinWord)
                    || currentCount >= protectedCharacterCount) {
                flush()
            }

            if latinBody, !insideLatinWord { latinWordCount += 1 }
            insideLatinWord = continuesLatinWord
            current.append(character)
            currentCount += 1

            if whitespace {
                currentToken = ""
                isInsideURL = false
                insideLatinWord = false
            } else {
                currentToken.append(character)
                let lowercaseToken = currentToken.lowercased()
                if lowercaseToken.contains("https://")
                    || lowercaseToken.contains("http://")
                    || lowercaseToken.contains("www.") {
                    isInsideURL = true
                }
            }

            if codeDelimiterLength == nil, !isInsideURL {
                if quoteClosers.last == character {
                    quoteClosers.removeLast()
                } else if let closer = quotePairs[character],
                          !isWordApostrophe(character,
                                            previous: previous,
                                            next: next) {
                    quoteClosers.append(closer)
                }
            }

            if character == "\n" {
                flush()
            } else if !protected,
                      isBoundary(character,
                                 previous: previous,
                                 next: next,
                                 tokenBeforeBoundary: String(currentToken.dropLast())) {
                pendingBoundary = true
            } else if pendingBoundary, whitespace {
                flush()
            } else if whitespace,
                      latinWordCount >= preferredLatinWordCount,
                      codeDelimiterLength == nil,
                      quoteClosers.isEmpty,
                      !isInsideURL {
                flush()
            }
            position += 1
        }
        flush()
        if result.isEmpty, !current.isEmpty {
            // Direct incremental input may consist solely of whitespace. The
            // generic `refine` entry point filters whitespace-only logical
            // blocks, but the exact splitter must never drop typed text.
            result.append(current)
        }
        return result
    }

    /// Extremely large results use balanced groups instead of placing every
    /// excess unit into one giant tail block. Compaction never crosses an
    /// upstream/provider block boundary.
    private static func compact(_ fragments: [SemanticBlockFragment],
                                maximumSegments: Int) -> [SemanticBlockFragment] {
        let grouped = Dictionary(grouping: fragments, by: { $0.key.sourceIndex })
        let sourceOrder = grouped.keys.sorted()
        guard sourceOrder.count <= maximumSegments else {
            return fragments
        }

        var allocations = Dictionary(uniqueKeysWithValues: sourceOrder.map { ($0, 1) })
        var remaining = maximumSegments - sourceOrder.count
        while remaining > 0 {
            guard let source = sourceOrder
                .filter({ (allocations[$0] ?? 1) < (grouped[$0]?.count ?? 0) })
                .max(by: { lhs, rhs in
                    let left = Double(grouped[lhs]?.count ?? 0)
                        / Double(allocations[lhs] ?? 1)
                    let right = Double(grouped[rhs]?.count ?? 0)
                        / Double(allocations[rhs] ?? 1)
                    return left < right
                }) else { break }
            allocations[source, default: 1] += 1
            remaining -= 1
        }

        var result: [SemanticBlockFragment] = []
        for source in sourceOrder {
            guard let units = grouped[source], !units.isEmpty else { continue }
            let targetCount = min(allocations[source] ?? 1, units.count)
            var cursor = 0
            for childIndex in 0..<targetCount {
                let unitsLeft = units.count - cursor
                let groupsLeft = targetCount - childIndex
                let take = Int(ceil(Double(unitsLeft) / Double(groupsLeft)))
                let end = min(cursor + take, units.count)
                let slice = units[cursor..<end]
                result.append(SemanticBlockFragment(
                    // Reuse the first original unit's identity. When a 201st
                    // unit forces compaction, each surviving group remains
                    // anchored to its first unit instead of dense child
                    // indices suddenly referring to unrelated text.
                    key: slice.first?.key
                        ?? SemanticBlockKey(sourceIndex: source,
                                            childIndex: childIndex),
                    text: slice.map(\.text).joined(),
                    title: childIndex == 0 ? slice.first?.title : nil
                ))
                cursor = end
            }
        }
        return result
    }

    private static func isBoundary(_ character: Character,
                                   previous: Character?,
                                   next: Character?,
                                   tokenBeforeBoundary: String) -> Bool {
        guard boundaryCharacters.contains(character) else { return false }
        if (character == "," || character == "."),
           previous?.wholeNumberValue != nil,
           next?.wholeNumberValue != nil {
            return false
        }
        if (character == "，" || character == "："),
           previous?.wholeNumberValue != nil,
           next?.wholeNumberValue != nil {
            return false
        }
        if character == "." {
            // A dot is sentence punctuation only at a lexical boundary. This
            // protects domains, versions and abbreviations while still making
            // ordinary English full stops useful block boundaries.
            if let next, !next.isWhitespace, !closingCharacters.contains(next) {
                return false
            }
            let lexicalToken = tokenBeforeBoundary.lowercased()
            let commonAbbreviations: Set<String> = [
                "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "st", "vs",
            ]
            if commonAbbreviations.contains(lexicalToken)
                || lexicalToken.allSatisfy(\.isNumber) {
                return false
            }
        }
        if character == ":" {
            if previous?.wholeNumberValue != nil,
               next?.wholeNumberValue != nil {
                return false
            }
            let scheme = tokenBeforeBoundary.lowercased()
            if (scheme.hasSuffix("http") || scheme.hasSuffix("https")), next == "/" {
                return false
            }
        }
        return true
    }

    private static func isASCIILatinWordBody(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }

    private static func isLatinWordJoiner(_ character: Character,
                                          previous: Character?,
                                          next: Character?) -> Bool {
        guard character == "'" || character == "’" || character == "-",
              let previous,
              let next else { return false }
        return isASCIILatinWordBody(previous) && isASCIILatinWordBody(next)
    }

    private static func isWordApostrophe(_ character: Character,
                                         previous: Character?,
                                         next: Character?) -> Bool {
        guard character == "'" || character == "’",
              let previous else { return false }
        return previous.isLetter || previous.isNumber
    }
}
