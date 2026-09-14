import Foundation

/// What a chord mapping writes into Rime. Profiles are always authored in
/// full pinyin; the encoding only changes the compiled chord outputs, speller
/// and prism, so learning, the stream plugin and the editor keep reading
/// pinyin.
enum ChordOutputEncoding: String, Codable, CaseIterable, Equatable, Hashable {
    case fullPinyin
    /// 自然码双拼: every complete syllable becomes exactly two keys, so
    /// syllable boundaries follow from position instead of apostrophes.
    case ziranma

    var title: String {
        switch self {
        case .fullPinyin: return "全拼"
        case .ziranma: return "自然码双拼"
        }
    }
}

/// Full pinyin → 自然码 codes. `syllableAlgebra` is the canonical speller
/// algebra of `double_pinyin.schema.yaml`; `syllableCode` runs the same
/// ordered rewrite so a compiled chord output always names the spelling the
/// prism was built from. Derived alternates (`jv`, `aai`) stay speller-only.
enum ZiranmaShuangpin {
    /// Emitted verbatim as `speller/algebra` of generated 自然码 chord schemas.
    static let syllableAlgebra: [String] = [
        "erase/^xx$/",
        "derive/^([jqxy])u$/$1v/",
        "derive/^([aoe])([ioun])$/$1$1$2/",
    ] + canonicalRules.map(\.rime) + [
        "xlit/ⓆⓌⓇⓉⓎⓊⒾⓄⓅⓈⒹⒻⒼⒽⓂⒿⒸⓀⓁⓏⓍⓋⒷⓃ/qwrtyuiopsdfghmjcklzxvbn/",
    ]

    /// Mirrors `double_pinyin.schema.yaml` translator/preedit_format, so the
    /// inline preedit keeps showing full pinyin while Rime holds codes.
    static let preeditFormat: [String] = [
        "xform/(^|[ '])aa/$1a/",
        "xform/(^|[ '])ee/$1e/",
        "xform/(^|[ '])oo/$1o/",
        "xform/([bpmnljqxy])n/$1in/",
        "xform/(\\w)g/$1eng/",
        "xform/(\\w)q/$1iu/",
        "xform/([gkhvuirzcs])w/$1ua/",
        "xform/(\\w)w/$1ia/",
        "xform/([dtnlgkhjqxyvuirzcs])r/$1uan/",
        "xform/(\\w)t/$1ve/",
        "xform/([gkhvuirzcs])y/$1uai/",
        "xform/(\\w)y/$1ing/",
        "xform/([dtnlgkhvuirzcs])o/$1uo/",
        "xform/(\\w)p/$1un/",
        "xform/([jqx])s/$1iong/",
        "xform/(\\w)s/$1ong/",
        "xform/([jqxnlb])d/$1iang/",
        "xform/(\\w)d/$1uang/",
        "xform/(\\w)f/$1en/",
        "xform/(\\w)h/$1ang/",
        "xform/(\\w)j/$1an/",
        "xform/(\\w)k/$1ao/",
        "xform/(\\w)l/$1ai/",
        "xform/(\\w)z/$1ei/",
        "xform/(\\w)x/$1ie/",
        "xform/(\\w)c/$1iao/",
        "xform/([dtgkhvuirzcs])v/$1ui/",
        "xform/(\\w)b/$1ou/",
        "xform/(\\w)m/$1ian/",
        "xform/([aoe])\\1(\\w)/$1$2/",
        "xform/(^|[ '])v/$1zh/",
        "xform/(^|[ '])i/$1ch/",
        "xform/(^|[ '])u/$1sh/",
        "xform/([jqxy])v/$1u/",
        "xform/([nl])v/$1ü/",
        "xform/ü/v/",
    ]

    private struct Rule {
        let pattern: String
        let template: String
        let regex: NSRegularExpression
        var rime: String { "xform/\(pattern)/\(template)/" }

        init(_ pattern: String, _ template: String) {
            self.pattern = pattern
            self.template = template
            regex = try! NSRegularExpression(pattern: pattern)
        }
    }

    private static let canonicalRules: [Rule] = [
        Rule("^([aoe])(ng)?$", "$1$1$2"),
        Rule("iu$", "Ⓠ"),
        Rule("[iu]a$", "Ⓦ"),
        Rule("[uv]an$", "Ⓡ"),
        Rule("[uv]e$", "Ⓣ"),
        Rule("ing$|uai$", "Ⓨ"),
        Rule("^sh", "Ⓤ"),
        Rule("^ch", "Ⓘ"),
        Rule("^zh", "Ⓥ"),
        Rule("uo$", "Ⓞ"),
        Rule("[uv]n$", "Ⓟ"),
        Rule("(.)i?ong$", "$1Ⓢ"),
        Rule("[iu]ang$", "Ⓓ"),
        Rule("(.)en$", "$1Ⓕ"),
        Rule("(.)eng$", "$1Ⓖ"),
        Rule("(.)ang$", "$1Ⓗ"),
        Rule("ian$", "Ⓜ"),
        Rule("(.)an$", "$1Ⓙ"),
        Rule("iao$", "Ⓒ"),
        Rule("(.)ao$", "$1Ⓚ"),
        Rule("(.)ai$", "$1Ⓛ"),
        Rule("(.)ei$", "$1Ⓩ"),
        Rule("ie$", "Ⓧ"),
        Rule("ui$", "Ⓥ"),
        Rule("(.)ou$", "$1Ⓑ"),
        Rule("in$", "Ⓝ"),
    ]

    private static let transliteration: [Character: Character] = Dictionary(
        uniqueKeysWithValues: zip("ⓆⓌⓇⓉⓎⓊⒾⓄⓅⓈⒹⒻⒼⒽⓂⒿⒸⓀⓁⓏⓍⓋⒷⓃ",
                                  "qwrtyuiopsdfghmjcklzxvbn")
    )

    static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l",
                           "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]

    private static let finals = [
        "a", "o", "e", "i", "u", "v", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng",
        "ong", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong",
        "ua", "uo", "uai", "ui", "uan", "un", "uang", "ue", "ve", "van", "vn",
    ]

    /// Complete syllables: an initial (or none) plus a final, with the
    /// orthographic spellings pinyin actually uses. `ue`/`ve` both name ü.
    static let syllables: Set<String> = {
        var result = Set(["a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "er"])
        let valid: [String: [String]] = [
            "b": ["a", "o", "ai", "ei", "ao", "an", "en", "ang", "eng", "i", "ie", "iao", "ian", "iang", "in", "ing", "u"],
            "p": ["a", "o", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "i", "ie", "iao", "ian", "in", "ing", "u"],
            "m": ["a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "i", "ie", "iao", "iu", "ian", "in", "ing", "u"],
            "f": ["a", "o", "ei", "ou", "an", "en", "ang", "eng", "u", "iao"],
            "d": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "i", "ia", "ie", "iao", "iu", "ian", "ing", "u", "uo", "ui", "uan", "un"],
            "t": ["a", "e", "ai", "ei", "ao", "ou", "an", "ang", "eng", "ong", "i", "ie", "iao", "ian", "ing", "u", "uo", "ui", "uan", "un"],
            "n": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "i", "ie", "iao", "iu", "ian", "in", "iang", "ing", "u", "uo", "uan", "un", "v", "ve", "ue"],
            "l": ["a", "o", "e", "ai", "ei", "ao", "ou", "an", "ang", "eng", "ong", "i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "u", "uo", "uan", "un", "v", "ve", "ue"],
            "g": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "k": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "h": ["a", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "j": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
            "q": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
            "x": ["i", "ia", "ie", "iao", "iu", "ian", "in", "iang", "ing", "iong", "u", "ue", "uan", "un"],
            "zh": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "ch": ["a", "e", "i", "ai", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "sh": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang"],
            "r": ["e", "i", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "ua", "uo", "ui", "uan", "un"],
            "z": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uo", "ui", "uan", "un"],
            "c": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uo", "ui", "uan", "un"],
            "s": ["a", "e", "i", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "u", "uo", "ui", "uan", "un"],
            "y": ["a", "o", "e", "ao", "ou", "an", "ang", "i", "in", "ing", "ong", "u", "ue", "uan", "un"],
            "w": ["a", "o", "ai", "ei", "an", "en", "ang", "eng", "u"],
        ]
        for (initial, spellings) in valid {
            for final in spellings { result.insert(initial + final) }
        }
        return result
    }()

    /// Two keys for a complete syllable, following the speller algebra.
    static func syllableCode(_ pinyin: String) -> String? {
        guard syllables.contains(pinyin) else { return nil }
        var text = pinyin
        for rule in canonicalRules {
            let range = NSRange(text.startIndex..., in: text)
            text = rule.regex.stringByReplacingMatches(in: text, range: range,
                                                       withTemplate: rule.template)
        }
        let code = String(text.map { transliteration[$0] ?? $0 })
        return code.count == 2 ? code : nil
    }

    /// One key for a pinyin building block. An initial keeps its 自然码 key
    /// (zh/ch/sh → v/i/u); a final names the key that completes a syllable.
    /// Vowel-first fragments that open a zero-initial syllable (`o` before
    /// `u` in `ou`) are the first key of that syllable's code.
    static func fragmentCode(_ pinyin: String) -> String? {
        switch pinyin {
        case "zh": return "v"
        case "ch": return "i"
        case "sh": return "u"
        default: break
        }
        if initials.contains(pinyin) { return pinyin }
        guard finals.contains(pinyin) else { return nil }
        if pinyin.count == 1 { return pinyin }
        let finalKeys: [String: String] = [
            "ai": "l", "ei": "z", "ao": "k", "ou": "b", "an": "j", "en": "f",
            "ang": "h", "eng": "g", "ong": "s", "ia": "w", "ie": "x",
            "iao": "c", "iu": "q", "ian": "m", "in": "n", "iang": "d", "ing": "y",
            "iong": "s", "ua": "w", "uo": "o", "uai": "y", "ui": "v", "uan": "r",
            "un": "p", "uang": "d", "ue": "t", "ve": "t", "van": "r", "vn": "p",
        ]
        return finalKeys[pinyin]
    }
}

extension ChordKeymapProfile {
    /// The exact raw input Rime holds after this mapping's chord settles.
    func engineOutput(for entry: ChordKeymapEntry) -> String? {
        switch outputEncoding {
        case .fullPinyin:
            return entry.output
        case .ziranma:
            return entry.kind == .syllable
                ? ZiranmaShuangpin.syllableCode(entry.output)
                : ZiranmaShuangpin.fragmentCode(entry.output)
        }
    }
}
