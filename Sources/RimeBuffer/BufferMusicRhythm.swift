import Foundation

enum BufferMusicGroove: String, CaseIterable {
    case rock = "Rock", funk = "Funk", shuffle = "Shuffle", halfTime = "Half-time"
}

struct BufferMusicDrumHit: Equatable {
    let beat: Double // quarter notes relative to the start of the measure
    let drum: BufferMusicDrum
    let velocity: UInt8
    var isFill = false
}

/// Original patterns inspired by the documented BeatBuddy *control model*,
/// not its copyrighted song/MIDI library. Timing is musical, never wall-clock
/// random jitter: ghost notes, alternating hands, flams and triplet phrasing.
enum BufferMusicPatterns {
    static let fillNames = ["幽灵切分", "军鼓双击", "通鼓下行", "三连推进", "底鼓对答", "镲片点缀", "反拍重音", "渐强收束"]
    static func groove(_ style: BufferMusicGroove, meter: BufferMusicMeter, section: Int) -> [BufferMusicDrumHit] {
        let length = meter.quarterNotesPerBar
        var hits: [BufferMusicDrumHit] = []
        func add(_ beat: Double, _ drum: BufferMusicDrum, _ velocity: Int) {
            guard beat >= 0, beat < length else { return }
            hits.append(.init(beat: beat, drum: drum, velocity: UInt8(velocity)))
        }
        let subdivisions = Int(length * 2)
        for n in 0..<subdivisions {
            var beat = Double(n) / 2
            if style == .shuffle, n % 2 == 1 { beat += 1.0/6 }
            let isEnd = n == subdivisions - 1
            let cymbal: BufferMusicDrum = section % 2 == 1 ? (n % 4 == 0 ? .rideBell : .ride) : (isEnd ? .openHat : .closedHat)
            add(beat, cymbal, n % 2 == 0 ? 82 : 51)
        }
        add(0, .kick, 115)
        if meter == .sixEight {
            add(1.5, .snare, 108)
            add(2.5, .kick, 87)
            if style == .funk { add(1.25, .snareEdge, 34); add(2.25, .kick, 76) }
        } else if style == .halfTime {
            add(length >= 4 ? 2 : 1.5, .snare, 108)
            add(length - 0.5, .kick, 88)
            add(1.75, .snareEdge, 32)
        } else {
            for b in stride(from: 1.0, to: length, by: 2) { add(b, .snare, 107) }
            if length >= 4 { add(2, .kick, 101) }
            if style == .funk {
                add(0.75, .kick, 83); add(1.75, .kick, 96)
                add(0.875, .snareEdge, 30); add(2.75, .snareEdge, 41)
                add(length - 0.25, .snareEdge, 33)
            } else if style == .shuffle {
                add(2.0/3, .kick, 70); add(length - 1.0/3, .snareEdge, 39)
            } else if section % 2 == 1 { add(length - 0.5, .kick, 88) }
        }
        return hits.sorted { $0.beat < $1.beat }
    }

    static func fill(_ variant: Int, meter: BufferMusicMeter, transition: Bool, cycle: Int = 0) -> [BufferMusicDrumHit] {
        let v = (variant % 8 + 8) % 8
        let length = meter.quarterNotesPerBar
        var hits: [BufferMusicDrumHit] = []
        func add(_ beat: Double, _ drum: BufferMusicDrum, _ velocity: Int) {
            guard beat >= 0, beat < length else { return }
            hits.append(.init(beat: beat, drum: drum, velocity: UInt8(min(124, max(1, velocity)))))
        }
        add(0, .kick, 108)
        // Preserve forward motion; avoid replacing a fill with arbitrary noise.
        for b in stride(from: 0.0, to: length, by: 1) { add(b, .pedalHat, 47) }
        let spacing = v == 3 ? 1.0/3 : 0.25
        let count = Int((length / spacing).rounded())
        for i in 0..<count {
            let beat = Double(i) * spacing
            let lastHalf = beat >= length / 2
            let accent = i % (v == 3 ? 3 : 4) == 0
            var velocity = accent ? 107 : (i % 2 == 0 ? 76 : 43)
            let drum: BufferMusicDrum
            switch v {
            case 0:
                guard lastHalf || i % 4 == 0 || i % 4 == 3 else { continue }
                drum = accent ? .snare : .snareEdge
            case 1:
                drum = .snare
                if i % 4 == 0 { add(max(0, beat - 0.0625), .snareEdge, 29) }
                velocity = i % 2 == 0 ? 100 : 61
            case 2:
                drum = beat < length / 3 ? .snare : (beat < length * 2/3 ? .highTom : .lowTom)
            case 3:
                drum = [.snare, .highTom, .lowTom][i % 3]
                velocity = i % 3 == 0 ? 108 : 66
            case 4:
                drum = i % 4 == 2 ? .kick : (i % 4 == 3 ? .lowTom : .snare)
            case 5:
                drum = i % 4 == 0 ? .splash : (lastHalf ? .highTom : .sideStick)
            case 6:
                drum = i % 4 == 3 ? .snare : (i % 2 == 0 ? .kick : .snareEdge)
                velocity = i % 4 == 3 ? 111 : 48
            default:
                drum = lastHalf ? (i % 2 == 0 ? .highTom : .lowTom) : .snare
                velocity = 37 + Int(73 * beat / length)
            }
            if transition {
                velocity = min(119, velocity + min(12, cycle * 3))
                if lastHalf, i % 2 == 0 { add(beat + 0.125, .snareEdge, 33 + min(22, cycle * 3)) }
            }
            add(beat, drum, velocity)
        }
        return hits.sorted { $0.beat < $1.beat }
    }
}

/// Quarter-note clock shared with the loop transport. Late ticks drop obsolete
/// drum events rather than burst. A fill replaces the groove only in its own
/// span; one downbeat accent bridges back without a double kick/crash.
struct BufferMusicDrumPerformance {
    struct Fill {
        var start: Double
        var end: Double
        var variant: Int
        var transition: Bool
    }
    var meter: BufferMusicMeter = .fourFour
    var style: BufferMusicGroove = .rock
    var enabled = false
    private(set) var section = 0
    private(set) var fill: Fill?
    private var cursor: Double = -0.000_01
    private var nextVariant = 0
    private var lastAccent: Double = -.infinity
    var hasScheduledWork: Bool { enabled || fill != nil }
    var fillTitle: String {
        guard let fill else { return "" }
        return (fill.transition ? "过渡 · " : "加花 · ") + BufferMusicPatterns.fillNames[fill.variant]
    }

    mutating func reset(at beat: Double = 0) {
        cursor = beat - 0.000_01
        fill = nil
        section = 0
        lastAccent = -.infinity
    }
    mutating func setEnabled(_ value: Bool, at beat: Double) {
        enabled = value
        if !value { fill = nil }
        cursor = max(cursor, beat - 0.000_01)
    }
    mutating func requestFill(at beat: Double) {
        let bar = meter.quarterNotesPerBar
        let startBar = floor(beat / bar) * bar
        let fraction = (beat - startBar) / bar
        let start = fraction >= 0.75 ? startBar + bar : min(startBar + bar, (floor(beat * 4) + 1) / 4)
        let end = (floor(start / bar) + 1) * bar
        fill = Fill(start: start, end: end, variant: nextVariant, transition: false)
        // Coprime stride visits all eight authored variations before repeating.
        nextVariant = (nextVariant + 3) % 8
    }
    mutating func beginTransition(at beat: Double) {
        if fill == nil { requestFill(at: beat) }
        fill?.transition = true
        fill?.end = .infinity
    }
    mutating func releaseTransition(at beat: Double) {
        guard let current = fill, current.transition else { return }
        let bar = meter.quarterNotesPerBar
        fill?.end = (floor(max(beat, current.start) / bar) + 1) * bar
    }
    mutating func advance(to beat: Double, secondsPerQuarter: Double) -> [BufferMusicDrumHit] {
        guard beat >= cursor else { return [] }
        let earliest = max(cursor, beat - 0.06 / secondsPerQuarter)
        let bar = meter.quarterNotesPerBar
        var result: [BufferMusicDrumHit] = []
        let currentFill = fill
        let firstBar = Int(max(0, floor(earliest / bar)))
        let lastBar = Int(max(0, floor(beat / bar)))
        for index in firstBar...lastBar {
            let origin = Double(index) * bar
            let nextSection = currentFill.map { $0.transition && origin >= $0.end } ?? false
            let main = BufferMusicPatterns.groove(style, meter: meter, section: nextSection ? (section + 1) % 2 : section)
            let fills = currentFill.map { BufferMusicPatterns.fill($0.variant, meter: meter, transition: $0.transition, cycle: max(0, index - Int($0.start / bar))) } ?? []
            func append(_ hits: [BufferMusicDrumHit], isFill: Bool) {
                for hit in hits {
                    let time = origin + hit.beat
                    guard time > earliest, time <= beat + 0.000_001 else { continue }
                    let inFill = currentFill.map { time >= $0.start && time < $0.end } ?? false
                    guard isFill ? inFill : (enabled && !inFill) else { continue }
                    if let end = currentFill?.end, abs(time - end) < 0.000_001,
                       hit.drum == .kick || hit.drum == .crash { continue }
                    result.append(.init(beat: time, drum: hit.drum, velocity: hit.velocity, isFill: isFill))
                }
            }
            append(main, isFill: false)
            append(fills, isFill: true)
        }
        if let currentFill, beat >= currentFill.end {
            if currentFill.end > earliest, currentFill.end != lastAccent {
                result.append(.init(beat: currentFill.end, drum: .crash, velocity: 110, isFill: true))
                result.append(.init(beat: currentFill.end, drum: .kick, velocity: 116, isFill: true))
                lastAccent = currentFill.end
            }
            if currentFill.transition { section = (section + 1) % 2 }
            fill = nil
        }
        cursor = beat
        return result.sorted { $0.beat < $1.beat }
    }
}
