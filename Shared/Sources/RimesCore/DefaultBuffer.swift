import Foundation

/// Live typing figures for the Default buffer's second line.
///
/// The definitions are the typing test's, so a number seen here means the same
/// thing as the same number after a practice run: speed is committed
/// characters per minute, code length is physical keys per committed
/// character. Nothing here can be borrowed from the test wholesale, because a
/// test measures against a known article — accuracy has no meaning in free
/// typing, and is deliberately absent rather than approximated.
public struct BufferLiveTypingMetrics: Equatable {
    /// Free typing has no start or finish, so a burst is delimited by silence.
    /// Without this the figures would average over lunch breaks and read as a
    /// slow typist rather than an idle one.
    public init() {}
    static let burstIdleTimeout: TimeInterval = 6

    public private(set) var keyCount = 0
    public private(set) var committedCharacterCount = 0
    public private(set) var backspaceCount = 0
    public private(set) var firstEventAt: TimeInterval?
    public private(set) var lastEventAt: TimeInterval?

    public var elapsedSeconds: TimeInterval {
        guard let firstEventAt, let lastEventAt else { return 0 }
        return max(0, lastEventAt - firstEventAt)
    }

    /// Committed characters per minute. Matches `TypingTestMetrics.rawCPM`:
    /// what actually reached the document, not what was attempted.
    public var charactersPerMinute: Double? {
        guard elapsedSeconds >= 1, committedCharacterCount > 0 else { return nil }
        return Double(committedCharacterCount) * 60 / elapsedSeconds
    }

    /// Physical keys per committed character — the number a Chinese IME user
    /// actually optimises. Undefined until something has been committed.
    public var codeLength: Double? {
        guard committedCharacterCount > 0 else { return nil }
        return Double(keyCount) / Double(committedCharacterCount)
    }

    public var keysPerSecond: Double? {
        guard elapsedSeconds >= 1, keyCount > 0 else { return nil }
        return Double(keyCount) / elapsedSeconds
    }

    public var isEmpty: Bool { keyCount == 0 && committedCharacterCount == 0 }

    public mutating func reset() { self = BufferLiveTypingMetrics() }

    /// Rolls the burst over when the gap since the last event exceeds the
    /// timeout, so the figures always describe the stretch being typed now.
    private mutating func rollIfIdle(at timestamp: TimeInterval) {
        if let lastEventAt,
           timestamp - lastEventAt > Self.burstIdleTimeout {
            reset()
        }
        if firstEventAt == nil { firstEventAt = timestamp }
        lastEventAt = max(timestamp, lastEventAt ?? timestamp)
    }

    public mutating func noteKey(at timestamp: TimeInterval,
                          isRepeat: Bool,
                          isBackspace: Bool) {
        // A held key repeating is one intent, and counting each repeat would
        // inflate both the key count and the code length.
        guard !isRepeat else { return }
        rollIfIdle(at: timestamp)
        keyCount += 1
        if isBackspace { backspaceCount += 1 }
    }

    public mutating func noteCommit(characterCount: Int, at timestamp: TimeInterval) {
        guard characterCount > 0 else { return }
        rollIfIdle(at: timestamp)
        committedCharacterCount += characterCount
    }
}

/// Renders the second line. Every figure is omitted until it can be stated
/// truthfully — a code length of 0.0 before the first commit, or a speed
/// extrapolated from a fraction of a second, would be worse than a shorter
/// line.
public enum BufferLiveTypingMetricsFormatter {
    /// Shown before the first figure can be stated, so the permanent row reads
    /// as waiting rather than as empty space.
    public static let idleLine = "— 字/分  ·  码长 —  ·  击键 —/秒"

    public static func line(for metrics: BufferLiveTypingMetrics) -> String? {
        var parts: [String] = []
        if let cpm = metrics.charactersPerMinute {
            parts.append("\(Int(cpm.rounded())) 字/分")
        }
        if let codeLength = metrics.codeLength {
            parts.append(String(format: "码长 %.2f", codeLength))
        }
        if let keys = metrics.keysPerSecond {
            parts.append(String(format: "击键 %.1f/秒", keys))
        }
        if metrics.backspaceCount > 0 {
            parts.append("回删 \(metrics.backspaceCount)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}


/// Ordered blocks age independently; edited blocks restart, unchanged prefixes
/// keep their elapsed time. Consumption must be acknowledged only after delivery.
public struct DefaultBufferClock {
    private struct Entry { var text: String; var age: TimeInterval = 0; var last: TimeInterval? }
    private var entries: [Entry] = []
    public init() {}
    public var headAge: TimeInterval { entries.first?.age ?? 0 }
    public mutating func reset() { self = .init() }
    public mutating func pause() { for i in entries.indices { entries[i].last = nil } }
    public mutating func synchronize(_ blocks: [String]) {
        entries = blocks.enumerated().map { index, text in
            index < entries.count && entries[index].text == text ? entries[index] : Entry(text: text)
        }
    }
    public mutating func consumed(all: Bool) {
        if all { entries = [] } else if !entries.isEmpty { entries.removeFirst() }
        pause()
    }
    public mutating func tick(at now: TimeInterval, lifetime: TimeInterval, canAge: Bool) -> Bool {
        guard canAge, now.isFinite, lifetime > 0 else { pause(); return false }
        for index in entries.indices {
            let elapsed = entries[index].last.map { max(0, min(now - $0, lifetime)) } ?? 0
            entries[index].age = min(lifetime, entries[index].age + elapsed)
            entries[index].last = now
        }
        return !entries.isEmpty && headAge >= lifetime
    }
}
