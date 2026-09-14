import Foundation

/// Chord schemes whose Rime schema already defines chording end to end:
/// librime's chord_composer settles each chord and the schema's own processors
/// and dictionary decide what it means. RIMES keeps no keymap table for them;
/// it delivers every physical press and release, and presents them as
/// read-only presets beside 飞耀.
///
/// 呦呦音形 (麓鸣输入法 · 音形分支) by Rayalizing, bundled from
/// github.com/Rayalizing/yoyo at 2f9dcc8. 寒梅 changes only the fingering
/// algebra (no number row or - = [, adds /) and shares the dictionaries.
enum NativeChordSchemeCatalog {
    static let yoyoZhemei = ChordKeymapProfile(
        id: "builtin.yoyo-yx",
        name: "呦呦音形 · 折梅",
        leftKeys: "123456qwertasdfgzxcvb",
        rightKeys: "7890-=uiop[hjkl;ynm,.",
        mappings: [],
        boundaryPolicy: .legacyBatches,
        nativeSchemeID: "yoyo-yx"
    )

    static let yoyoHanmei = ChordKeymapProfile(
        id: "builtin.yoyo-yx-hm",
        name: "呦呦音形 · 寒梅",
        leftKeys: "123456qwertasdfgzxcvb",
        rightKeys: "7890-=uiop[hjkl;ynm,./",
        mappings: [],
        boundaryPolicy: .legacyBatches,
        nativeSchemeID: "yoyo-yx-hm"
    )

    static let all = [yoyoZhemei, yoyoHanmei]

    static func profile(id: String) -> ChordKeymapProfile? {
        all.first { $0.id == id }
    }

    static func isNativeSchema(_ schemaID: String) -> Bool {
        all.contains { $0.nativeSchemeID == schemaID }
    }

    /// Exactly the schema's `chord_composer/alphabet`: both halves and Space.
    static func alphabet(of profile: ChordKeymapProfile) -> String {
        profile.leftKeys + " " + profile.rightKeys
    }
}

enum NativeChordRoutingRules {
    /// A native chord key is an unmodified press or release of a character in
    /// the scheme's alphabet, while that scheme is the live Chinese schema.
    /// Shift yields a different character, and Control/Option/Command make a
    /// shortcut; both keep their ordinary routes.
    static func isChordKey(keycode: Int32,
                           mask: Int32,
                           profile: ChordKeymapProfile,
                           schemaID: String,
                           asciiMode: Bool,
                           extensionEnabled: Bool) -> Bool {
        guard extensionEnabled, !asciiMode,
              let nativeSchemeID = profile.nativeSchemeID,
              nativeSchemeID == schemaID else { return false }
        let modifiers = RimeKey.shiftMask | RimeKey.controlMask
            | RimeKey.altMask | RimeKey.superMask
        guard mask & modifiers == 0,
              let scalar = UnicodeScalar(UInt32(keycode)) else { return false }
        return NativeChordSchemeCatalog.alphabet(of: profile)
            .unicodeScalars.contains(scalar)
    }
}
