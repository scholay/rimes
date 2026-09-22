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
        // Keep the persisted identity for existing selections, while migrating its public name.
        if id == "builtin.flyyao" { name = "默认并击" }
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
    // Explicit directional shortcuts, separate from unordered two-hand mappings.
    private static let slides = [("ty", "ting"), ("tyu", "tu"), ("gh", "gang"),
                                 ("ghj", "gan"), ("bn", "bin"), ("bnm", "bian"),
                                 ("bh", "bang"), ("th", "tang"), ("gy", "guai")]
    private var slide: (path: String, pinyin: String)?
    public func resolution(in profile: ChordProfile) -> ChordResolution? {
        if let slide, !cancelled {
            let entry = ChordEntry(keys: slide.path, output: slide.pinyin, kind: .syllable)
            guard let code = profile.encoded(entry) else { return nil }
            return .init(keys: slide.path, preview: slide.pinyin,
                         input: code + (profile.outputEncoding == .fullPinyin ? "'" : ""))
        }
        return keys.flatMap(profile.resolve)
    }
    public private(set) var cancelled = false
    public init() {}
    public var active: Bool { !down.isEmpty }
    public var keys: Set<Character>? {
        guard !cancelled, !contacts.isEmpty else { return nil }
        if let slide { return Set(slide.path) }
        var result = Set<Character>()
        for c in contacts.values { guard let end = c.end else { return nil }; result.insert(c.start); result.insert(end) }
        return result
    }
    /// Endpoints reachable from immutable starts; released hands stay frozen.
    public func availableKeys(in index: ChordReachability) -> Set<Character> {
        guard active, !cancelled else { return active ? [] : index.allKeys }
        var available = Set<Character>()
        if index.supportsDirectionalSlides, contacts.count == 1, let contact = contacts.values.first, !contact.released {
            for (path, _) in Self.slides where path.first == contact.start {
                available.formUnion(path)
            }
        }
        for keys in index.combinations {
            var valid = true
            for contact in contacts.values {
                let side = keys.intersection(index.keys(for: contact.hand))
                if !side.contains(contact.start) { valid = false; break }
                if contact.released && side != Set([contact.start, contact.end].compactMap { $0 }) { valid = false; break }
            }
            if valid { available.formUnion(keys) }
        }
        return available
    }
    public mutating func begin(id: Int, key: Character?, profile: ChordProfile) {
        if down.isEmpty { reset() }
        down.insert(id)
        if slide != nil { cancel(); return }
        guard !cancelled, let key, let hand = profile.hand(for: key), contacts.values.allSatisfy({ $0.hand != hand }) else { cancel(); return }
        contacts[id] = Contact(hand: hand, start: key, end: key)
    }
    public mutating func move(id: Int, key: Character?, profile: ChordProfile) {
        guard !cancelled, var c = contacts[id], !c.released else { return }
        if profile.id == "builtin.flyyao", contacts.count == 1, let key {
            if key == c.start { slide = nil }
            else if let route = Self.slides.first(where: { $0.0.first == c.start && $0.0.last == key }) {
                // The intermediate key is known from the row: fast movement may
                // skip its touch sample, but still traverses that same route.
                slide = (route.0, route.1); return
            } else if slide != nil { return }
        }
        // Empty space (including the other hand's region) is not a new endpoint.
        // Keep the last endpoint until this finger reaches another key of its hand.
        guard let key, profile.hand(for: key) == c.hand else { return }
        let previous = c
        let previousKeys = keys
        c.end = key
        contacts[id] = c
        // Returning to the start explicitly collapses this hand to a single key.
        // Otherwise an unmapped endpoint cannot erase an already valid chord.
        let previousHand = Set([previous.start, previous.end].compactMap { $0 })
        let nextHand = Set([c.start, key])
        let hadCombination = previousKeys.map { $0.count > 1 && profile.resolve($0) != nil } == true
        let hadHandCombination = previousHand.count > 1 && profile.resolve(previousHand) != nil
        if key != c.start, keys.flatMap(profile.resolve) == nil,
           hadCombination || (hadHandCombination && profile.resolve(nextHand) == nil) {
            contacts[id] = previous
        }
    }
    public mutating func end(id: Int, key: Character?, profile: ChordProfile) -> ChordResolution? {
        guard down.contains(id) else { return nil }
        move(id: id, key: key, profile: profile)
        if contacts[id]?.end == nil { cancel() }
        contacts[id]?.released = true
        down.remove(id)
        guard down.isEmpty else { return nil }
        let resolution = resolution(in: profile)
        reset()
        return resolution
    }
    public mutating func cancel() { cancelled = true }
    public mutating func reset() { contacts.removeAll(); down.removeAll(); slide = nil; cancelled = false }
}

/// Compile once per profile, never scan all mappings on every drawing frame.
public struct ChordReachability {
    let supportsDirectionalSlides: Bool
    public let allKeys: Set<Character>
    public let combinations: [Set<Character>]
    private let left: Set<Character>, right: Set<Character>
    public func keys(for hand: Hand) -> Set<Character> { hand == .left ? left : right }
    public init(profile: ChordProfile) {
        supportsDirectionalSlides = profile.id == "builtin.flyyao"
        left = Set(profile.leftKeys); right = Set(profile.rightKeys); allKeys = left.union(right)
        var sets = Set<Set<Character>>(allKeys.map { Set([$0]) })
        for entry in profile.mappings where profile.encoded(entry) != nil { sets.insert(Set(entry.keys)) }
        func fragments(_ side: Set<Character>) -> [(Set<Character>, String)] {
            var values = side.map { (Set([$0]), String($0)) }
            values += profile.mappings.filter { $0.kind == .fragment && Set($0.keys).isSubset(of: side) }.map { (Set($0.keys), $0.output) }
            return values
        }
        for (l, a) in fragments(left) {
            for (r, b) in fragments(right) where ZiranmaShuangpin.syllables.contains(a + b) {
                let set = l.union(r)
                if profile.resolve(set) != nil { sets.insert(set) }
            }
        }
        combinations = Array(sets)
    }
}
