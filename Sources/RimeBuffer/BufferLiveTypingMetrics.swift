import Foundation

/// Live typing figures for the Default buffer's second line.
///
/// The definitions are the typing test's, so a number seen here means the same
/// thing as the same number after a practice run: speed is committed
/// characters per minute, code length is physical keys per committed
/// character. Nothing here can be borrowed from the test wholesale, because a
/// test measures against a known article — accuracy has no meaning in free
/// typing, and is deliberately absent rather than approximated.
struct BufferLiveTypingMetrics: Equatable {
    /// Free typing has no start or finish, so a burst is delimited by silence.
    /// Without this the figures would average over lunch breaks and read as a
    /// slow typist rather than an idle one.
    static let burstIdleTimeout: TimeInterval = 6

    private(set) var keyCount = 0
    private(set) var committedCharacterCount = 0
    private(set) var backspaceCount = 0
    private(set) var firstEventAt: TimeInterval?
    private(set) var lastEventAt: TimeInterval?

    var elapsedSeconds: TimeInterval {
        guard let firstEventAt, let lastEventAt else { return 0 }
        return max(0, lastEventAt - firstEventAt)
    }

    /// Committed characters per minute. Matches `TypingTestMetrics.rawCPM`:
    /// what actually reached the document, not what was attempted.
    var charactersPerMinute: Double? {
        guard elapsedSeconds >= 1, committedCharacterCount > 0 else { return nil }
        return Double(committedCharacterCount) * 60 / elapsedSeconds
    }

    /// Physical keys per committed character — the number a Chinese IME user
    /// actually optimises. Undefined until something has been committed.
    var codeLength: Double? {
        guard committedCharacterCount > 0 else { return nil }
        return Double(keyCount) / Double(committedCharacterCount)
    }

    var keysPerSecond: Double? {
        guard elapsedSeconds >= 1, keyCount > 0 else { return nil }
        return Double(keyCount) / elapsedSeconds
    }

    var isEmpty: Bool { keyCount == 0 && committedCharacterCount == 0 }

    mutating func reset() { self = BufferLiveTypingMetrics() }

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

    mutating func noteKey(at timestamp: TimeInterval,
                          isRepeat: Bool,
                          isBackspace: Bool) {
        // A held key repeating is one intent, and counting each repeat would
        // inflate both the key count and the code length.
        guard !isRepeat else { return }
        rollIfIdle(at: timestamp)
        keyCount += 1
        if isBackspace { backspaceCount += 1 }
    }

    mutating func noteCommit(characterCount: Int, at timestamp: TimeInterval) {
        guard characterCount > 0 else { return }
        rollIfIdle(at: timestamp)
        committedCharacterCount += characterCount
    }
}

/// Renders the second line. Every figure is omitted until it can be stated
/// truthfully — a code length of 0.0 before the first commit, or a speed
/// extrapolated from a fraction of a second, would be worse than a shorter
/// line.
enum BufferLiveTypingMetricsFormatter {
    static func line(for metrics: BufferLiveTypingMetrics) -> String? {
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

/// Subscribes to the sanitized telemetry channel and keeps one burst's worth
/// of figures. It observes; it can never alter what the key path does.
final class BufferLiveTypingMetricsRecorder {
    static let shared = BufferLiveTypingMetricsRecorder()

    private(set) var metrics = BufferLiveTypingMetrics()
    private var observation: InputTelemetryObservation?
    var onChange: (() -> Void)?

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard observation == nil else { return }
        observation = InputTelemetryBus.shared.observe { [weak self] event in
            self?.consume(event)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        observation?.cancel()
        observation = nil
        metrics.reset()
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        metrics.reset()
        onChange?()
    }

    private func consume(_ event: InputTelemetryEvent) {
        switch event {
        case let .key(key):
            metrics.noteKey(
                at: key.timestamp,
                isRepeat: key.isRepeat,
                isBackspace: BufferLiveTypingKeyRules.isBackspace(key.keyID)
            )
        case let .commit(commit):
            metrics.noteCommit(characterCount: commit.characterCount,
                               at: commit.timestamp)
        case .chord:
            // Chord presses already arrive as key events; counting the batch
            // again would halve the apparent code length of a chord schema.
            return
        }
        onChange?()
    }
}

enum BufferLiveTypingKeyRules {
    /// The telemetry channel carries a layout key identity rather than a
    /// keycode, so the name is matched instead of a virtual key.
    static func isBackspace(_ keyID: String) -> Bool {
        // The layout names exactly two: Backspace and ForwardDelete.
        let normalized = keyID.lowercased()
        return normalized == "backspace" || normalized == "forwarddelete"
    }
}
