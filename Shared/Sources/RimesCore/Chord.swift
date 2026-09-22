import Foundation

public enum ChordMappingKind: String, Codable { case fragment, syllable }
public enum ChordBoundaryPolicy: String, Codable { case legacyBatches, explicitSyllables }
public enum Hand: String, CaseIterable { case left, right }
public struct ChordEntry: Codable, Equatable {
    public var keys: String
    public var output: String
    public var kind: ChordMappingKind
    public init(keys: String, output: String, kind: ChordMappingKind) { self.keys = keys; self.output = output; self.kind = kind }
}
public struct ChordProfile: Codable, Identifiable, Equatable {
    public var formatVersion = 1
    public var id: String
    public var name: String
    public var leftKeys: String
    public var rightKeys: String
    public var mappings: [ChordEntry]
    public var boundaryPolicy: ChordBoundaryPolicy = .legacyBatches
    public var outputEncoding: ChordOutputEncoding = .fullPinyin
    public var nativeSchemeID: String?
    private enum CodingKeys: String, CodingKey { case formatVersion, id, name, leftKeys, rightKeys, mappings, boundaryPolicy, outputEncoding, nativeSchemeID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        leftKeys = try c.decode(String.self, forKey: .leftKeys); rightKeys = try c.decode(String.self, forKey: .rightKeys)
        mappings = try c.decode([ChordEntry].self, forKey: .mappings)
        boundaryPolicy = try c.decodeIfPresent(ChordBoundaryPolicy.self, forKey: .boundaryPolicy) ?? .explicitSyllables
        outputEncoding = try c.decodeIfPresent(ChordOutputEncoding.self, forKey: .outputEncoding) ?? .fullPinyin
        nativeSchemeID = try c.decodeIfPresent(String.self, forKey: .nativeSchemeID)
    }
    public static var builtIn: ChordProfile {
        // Invalid bundled data is a build defect, never silently replaced with empty mappings.
        try! JSONDecoder().decode(Self.self, from: Data(contentsOf: Bundle.module.url(forResource: "flyyao", withExtension: "json")!)).validated()
    }
    public func copy() -> Self { var p = self; p.id = UUID().uuidString; p.name += " copy"; return p }
    public func hand(for key: Character) -> Hand? { leftKeys.contains(key) ? .left : rightKeys.contains(key) ? .right : nil }
    public func canonical(_ keys: Set<Character>) -> String { String((leftKeys + rightKeys).filter(keys.contains)) }
    public func validated() throws -> Self {
        let all = leftKeys + rightKeys
        guard formatVersion == 1, nativeSchemeID == nil,
              id == "builtin.flyyao" || UUID(uuidString: id) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !leftKeys.isEmpty, !rightKeys.isEmpty, leftKeys.count <= 15, rightKeys.count <= 15, Set(all).count == all.count,
              Set(all).isSubset(of: Set("abcdefghijklmnopqrstuvwxyz,.")),
              !mappings.isEmpty, mappings.count <= 4096,
              id != "builtin.flyyao" || outputEncoding == .fullPinyin else { throw CoreError.invalidProfile }
        var seen = Set<String>()
        for m in mappings {
            let keys = Set(m.keys)
            guard keys.count >= 2, keys.count == m.keys.count, keys.isSubset(of: Set(all)),
                  keys.intersection(Set(leftKeys)).count <= 2, keys.intersection(Set(rightKeys)).count <= 2,
                  seen.insert(canonical(keys)).inserted,
                  m.output.utf8.allSatisfy({ (97...122).contains($0) }), !m.output.isEmpty, m.output.count <= 32,
                  encoded(m) != nil else { throw CoreError.invalidProfile }
        }
        return self
    }
    public static func imported(_ data: Data) throws -> Self {
        guard data.count <= 2 * 1024 * 1024 else { throw CoreError.invalidProfile }
        var p = try JSONDecoder().decode(Self.self, from: data)
        p.id = UUID().uuidString
        return try p.validated()
    }
    public func encoded(_ entry: ChordEntry) -> String? {
        if outputEncoding == .fullPinyin { return entry.output }
        return entry.kind == .syllable ? ZiranmaShuangpin.syllableCode(entry.output) : ZiranmaShuangpin.fragmentCode(entry.output)
    }
    /// Preview and commit use exactly the same resolver. Unknown multi-key sets fail closed.
    public func resolve(_ keys: Set<Character>) -> ChordResolution? {
        guard !keys.isEmpty, keys.isSubset(of: Set(leftKeys + rightKeys)) else { return nil }
        if keys.count == 1 { return .init(keys: canonical(keys), preview: canonical(keys), input: canonical(keys)) }
        func find(_ set: Set<Character>) -> ChordEntry? { mappings.first { Set($0.keys) == set } }
        func result(_ m: ChordEntry) -> ChordResolution? {
            guard let code = encoded(m) else { return nil }
            let boundary = outputEncoding == .fullPinyin && (boundaryPolicy == .legacyBatches || m.kind == .syllable)
            return .init(keys: canonical(keys), preview: m.output, input: code + (boundary ? "'" : ""))
        }
        if let m = find(keys) { return result(m) }
        let l = keys.intersection(Set(leftKeys)), r = keys.intersection(Set(rightKeys))
        guard !l.isEmpty, !r.isEmpty else { return nil }
        func fragment(_ set: Set<Character>) -> String? {
            if set.count == 1 { return String(set.first!) }
            guard let m = find(set), m.kind == .fragment else { return nil }
            return m.output
        }
        guard let a = fragment(l), let b = fragment(r), ZiranmaShuangpin.syllables.contains(a + b) else { return nil }
        return result(.init(keys: canonical(keys), output: a + b, kind: .syllable))
    }
}
public struct ChordResolution: Equatable {
    public let keys: String
    public let preview: String
    public let input: String
}
public enum CoreError: Error, LocalizedError {
    case invalidProfile, invalidEndpoint, noConsent, response(Int), incomplete, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "Invalid or unreachable chord mapping / 并击方案无效或无法触达"
        case .invalidEndpoint: return "Use an HTTPS endpoint without credentials, query or fragment / 请填写有效 HTTPS 地址"
        case .noConsent: return "Confirm the receiving service before sending / 请先确认接收服务"
        case .response(let code): return "AI request failed (HTTP \(code))"
        case .incomplete: return "Incomplete response. Source text is preserved. / 响应未完成，原文已保留"
        case .tooLarge: return "Text or response exceeds the limit / 内容超过长度限制"
        }
    }
}

/// A cancelled gesture is quarantined until every participating finger has lifted.
public struct ChordGesture {
    private struct Contact { let hand: Hand; let start: Character; var end: Character?; var released = false }
    private var contacts: [Int: Contact] = [:]
    private var down = Set<Int>()
    public private(set) var cancelled = false
    public init() {}
    public var active: Bool { !down.isEmpty }
    public var keys: Set<Character>? {
        guard !cancelled, !contacts.isEmpty else { return nil }
        var result = Set<Character>()
        for c in contacts.values { guard let end = c.end else { return nil }; result.insert(c.start); result.insert(end) }
        return result
    }
    public mutating func begin(id: Int, key: Character?, profile: ChordProfile) {
        if down.isEmpty { reset() }
        down.insert(id)
        guard !cancelled, let key, let hand = profile.hand(for: key), contacts.values.allSatisfy({ $0.hand != hand }) else { cancel(); return }
        contacts[id] = Contact(hand: hand, start: key, end: key)
    }
    public mutating func move(id: Int, key: Character?, profile: ChordProfile) {
        guard !cancelled, var c = contacts[id], !c.released else { return }
        c.end = key.flatMap { profile.hand(for: $0) == c.hand ? $0 : nil }
        contacts[id] = c
    }
    public mutating func end(id: Int, key: Character?, profile: ChordProfile) -> ChordResolution? {
        guard down.contains(id) else { return nil }
        move(id: id, key: key, profile: profile)
        if contacts[id]?.end == nil { cancel() }
        contacts[id]?.released = true
        down.remove(id)
        guard down.isEmpty else { return nil }
        let resolution = keys.flatMap(profile.resolve)
        reset()
        return resolution
    }
    public mutating func cancel() { cancelled = true }
    public mutating func reset() { contacts.removeAll(); down.removeAll(); cancelled = false }
}
