import UIKit
import RimesCore

struct KeyboardGeometry {
    var keys: [(String, CGRect)] = []
    var emoji: CGRect?
    var language: CGRect?
    static func height(layout: ChordLayout, chord: Bool, numeric: Bool, emoji: Bool, landscape: Bool,
                       width: CGFloat = 383, profile: ChordProfile = .builtIn) -> CGFloat {
        guard chord && !numeric && !emoji else { return landscape ? 108 : 150 }
        let columns = columnCount(profile)
        let gap: CGFloat = layout == .splitOrthogonal ? 12 : 0
        return 3 * max(1, (min(width, 480) - gap) / (2 * columns) - 1)
    }
    private static func columnCount(_ profile: ChordProfile) -> CGFloat {
        let hands = [profile.leftKeys, profile.rightKeys].map { keys in
            ["qwertyuiop", "asdfghjkl", "zxcvbnm,."] .map { $0.filter { keys.contains($0) }.count }
        }
        return CGFloat(max(5, hands.flatMap { $0 }.max() ?? 0, hands[1][1] + 1, hands[1][2] + 1))
    }
    static func make(size: CGSize, profile: ChordProfile, chord: Bool, numeric: Bool,
                     layout: ChordLayout) -> Self {
        var result = Self()
        func frame(_ column: CGFloat, _ row: Int, pitch: CGFloat, height: CGFloat, origin: CGFloat = 0) -> CGRect {
            let dx: CGFloat = chord && !numeric ? 1 : 2
            let dy: CGFloat = chord && !numeric ? 0.5 : 3
            return CGRect(x: origin + column * pitch + dx, y: CGFloat(row) * height + dy,
                          width: max(1, pitch - 2 * dx), height: max(1, height - 2 * dy))
        }
        let hands = [profile.leftKeys, profile.rightKeys].map { keys in
            ["qwertyuiop", "asdfghjkl", "zxcvbnm,."] .map { $0.filter { keys.contains($0) }.map(String.init) }
        }
        if chord && !numeric {
            let gap: CGFloat = layout == .splitOrthogonal ? 12 : 0
            let gridWidth = min(size.width, 480)
            let gridOrigin = (size.width - gridWidth) / 2
            let half = (gridWidth - gap) / 2
            let columns = CGFloat(max(5, hands.flatMap { $0 }.map(\.count).max() ?? 0, hands[1][1].count + 1, hands[1][2].count + 1))
            for (side, rows) in hands.enumerated() {
                for (r, row) in rows.enumerated() {
                    for (c, key) in row.enumerated() {
                        result.keys.append((key, frame(CGFloat(c), r, pitch: half / columns, height: size.height / 3, origin: gridOrigin + CGFloat(side) * (half + gap))))
                    }
                }
            }
            result.emoji = frame(CGFloat(hands[1][1].count), 1, pitch: half / columns, height: size.height / 3, origin: gridOrigin + half + gap)
            result.language = frame(CGFloat(hands[1][2].count), 2, pitch: half / columns, height: size.height / 3, origin: gridOrigin + half + gap)
        } else {
            let rows = numeric ? ["1234567890", "-/:;()$&@\"", ".,?!'[]#%"] : ["qwertyuiop", "asdfghjkl", "zxcvbnm,."]
            let pitch = size.width / 10
            for (r, row) in rows.enumerated() {
                // Distinct row offsets preserve familiar QWERTY stagger without shrinking caps.
                let offset: CGFloat = numeric ? (10 - CGFloat(row.count)) / 2 : [0, 0.5, 1][r]
                for (c, key) in row.enumerated() where !chord || numeric || (profile.leftKeys + profile.rightKeys).contains(key) {
                    result.keys.append((String(key), frame(offset + CGFloat(c), r, pitch: pitch, height: size.height / 3)))
                }
            }
        }
        return result
    }
}
