import Foundation

/// A row from librime's portable export: phrase, space-separated code, commits.
/// The number also includes imported weights; it is not a typing-history count.
struct PersonalLexiconEntry: Codable, Equatable, Identifiable {
    let text: String
    let code: String
    let weight: Int

    var id: String { code + "\t" + text }

    static func draft(text: String, code: String, weight: Int = 1) throws -> Self {
        let normalizedCode = code.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let entry = Self(text: text, code: normalizedCode, weight: weight)
        try entry.validate()
        return entry
    }

    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.hasPrefix("#"),
              text.utf8.count <= 4096, code.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              weight >= 0, weight < Int(Int32.max) else {
            throw UserLexiconServiceError.invalidEntry
        }
    }

    static func parseExport(_ text: String) throws -> [Self] {
        var entries: [Self] = []
        var identities = Set<String>()
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.components(separatedBy: "\t")
            guard columns.count == 3, let weight = Int(columns[2]) else {
                throw UserLexiconServiceError.malformedLine(index + 1)
            }
            let entry = Self(text: columns[0], code: columns[1], weight: weight)
            try entry.validate()
            guard identities.insert(entry.id).inserted else {
                throw UserLexiconServiceError.malformedLine(index + 1)
            }
            entries.append(entry)
        }
        return entries
    }
}

enum PersonalLexiconSort: Int, CaseIterable {
    case weight, text, code

    var title: String {
        switch self {
        case .weight: return "学习权重"
        case .text: return "词条"
        case .code: return "拼音 / 编码"
        }
    }

    func apply(to entries: [PersonalLexiconEntry], query: String) -> [PersonalLexiconEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let compactQuery = query.replacingOccurrences(of: " ", with: "")
        return entries.filter {
            query.isEmpty || $0.text.localizedStandardContains(query)
                || $0.code.localizedStandardContains(query)
                || $0.code.replacingOccurrences(of: " ", with: "")
                    .localizedStandardContains(compactQuery)
        }.sorted { lhs, rhs in
            if self == .weight, lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if self == .code, lhs.code != rhs.code { return lhs.code < rhs.code }
            if lhs.text != rhs.text { return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending }
            return lhs.code < rhs.code
        }
    }
}

struct PersonalLexiconChange: Codable {
    let kind: UserLexiconKind
    let before: [PersonalLexiconEntry]
    let after: [PersonalLexiconEntry]

    var affectedIDs: Set<String> { Set((before + after).map(\.id)) }

    /// Only the touched rows are compared. Unrelated words learned since a
    /// refresh are never overwritten. Re-learning a touched row blocks undo.
    func validateCurrent(_ current: [PersonalLexiconEntry], undo: Bool = false) throws {
        let ids = affectedIDs
        let actual = current.filter { ids.contains($0.id) }
        let expected = undo ? after : before
        guard actual.sorted(by: { $0.id < $1.id }) == expected.sorted(by: { $0.id < $1.id }) else {
            throw UserLexiconServiceError.staleEntries
        }
    }

    func delta(undo: Bool = false) -> String {
        let originals = undo ? after : before
        let replacements = undo ? before : after
        let retainedIDs = Set(replacements.map(\.id))
        // Add the replacement before removing the old spelling. An interrupted
        // import can leave both, but cannot delete the only copy first.
        let rows = replacements.map { "\($0.text)\t\($0.code)\t\(max(1, $0.weight))" }
            + originals.filter { !retainedIDs.contains($0.id) }
                .map { "\($0.text)\t\($0.code)\t-1" }
        return "# RIMES personal dictionary edit\n" + rows.joined(separator: "\n") + "\n"
    }
}
