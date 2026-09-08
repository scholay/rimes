import Foundation

enum BufferMusicMode: String, CaseIterable {
    case major = "大调", minor = "小调"
    var intervals: [Int] { self == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10] }
}

enum BufferMusicTheory {
    static let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
    static func pitchClass(_ value: Int) -> Int { (value % 12 + 12) % 12 }
    static func noteName(_ note: Int) -> String { names[pitchClass(note)] }
    static func solfege(note: UInt8, tonic: Int, mode: BufferMusicMode) -> String {
        let syllables = mode == .major
            ? ["Do", "Di", "Re", "Ri", "Mi", "Fa", "Fi", "Sol", "Si", "La", "Li", "Ti"]
            : ["Do", "Ra", "Re", "Me", "Mi", "Fa", "Se", "Sol", "Le", "La", "Te", "Ti"]
        return syllables[pitchClass(Int(note) - tonic)]
    }

    /// Exact pitch-class templates only: an arbitrary cluster is not a chord.
    /// Inversions retain the bass note; ambiguous sixth/seventh voicings prefer
    /// the bass as root, then a root belonging to the selected mode.
    static func chord(notes: [UInt8], tonic: Int, mode: BufferMusicMode) -> String {
        let sorted = notes.sorted()
        guard let bassNote = sorted.first else { return "—" }
        let bass = Int(bassNote) % 12
        let pcs = Set(sorted.map { Int($0) % 12 })
        let templates: [(String, [Int])] = [
            ("", [0,4,7]), ("m", [0,3,7]), ("dim", [0,3,6]), ("aug", [0,4,8]),
            ("sus2", [0,2,7]), ("sus4", [0,5,7]), ("maj7", [0,4,7,11]),
            ("7", [0,4,7,10]), ("m7", [0,3,7,10]), ("m(maj7)", [0,3,7,11]),
            ("m7♭5", [0,3,6,10]), ("dim7", [0,3,6,9]), ("6", [0,4,7,9]),
            ("m6", [0,3,7,9]), ("add9", [0,2,4,7]), ("m(add9)", [0,2,3,7]),
            ("9", [0,2,4,7,10]), ("maj9", [0,2,4,7,11]), ("m9", [0,2,3,7,10]),
            ("5", [0,7])
        ]
        let roots = pcs.sorted {
            func rank(_ n: Int) -> Int {
                (n == bass ? 0 : 20) + (mode.intervals.contains(pitchClass(n - tonic)) ? 0 : 10) + n
            }
            return rank($0) < rank($1)
        }
        for root in roots {
            for (suffix, intervals) in templates where Set(intervals.map { (root + $0) % 12 }) == pcs {
                let name = noteName(root) + suffix + (root == bass ? "" : "/" + noteName(bass))
                let relative = pitchClass(root - tonic)
                guard let degree = mode.intervals.firstIndex(of: relative) else { return name + " · 借用" }
                let romans = ["I", "II", "III", "IV", "V", "VI", "VII"]
                let lower = suffix.hasPrefix("m") && !suffix.hasPrefix("maj") || suffix.hasPrefix("dim")
                let numeral = lower ? romans[degree].lowercased() : romans[degree]
                return name + " · " + numeral
            }
        }
        return "—"
    }
}
