import AppKit
import Foundation

/// The second line states numbers a user will compare against their practice
/// results, so the definitions have to agree with the typing test's and the
/// figures have to be withheld until they are true.
func runBufferLiveTypingMetricsSmokeTest() -> Bool {
    print("== RIMES buffer live typing metrics smoke ==")

    var metrics = BufferLiveTypingMetrics()
    guard metrics.isEmpty,
          metrics.charactersPerMinute == nil,
          metrics.codeLength == nil,
          metrics.keysPerSecond == nil,
          BufferLiveTypingMetricsFormatter.line(for: metrics) == nil else {
        return liveMetricsFail("an untouched recorder must state nothing")
    }

    // Ten keys over ten seconds producing five characters: 30 字/分,
    // code length 2.0, one key per second. Same definitions as the test —
    // committed characters over elapsed minutes, physical keys per character.
    for index in 0..<10 {
        metrics.noteKey(at: Double(index), isRepeat: false, isBackspace: false)
    }
    metrics.noteCommit(characterCount: 5, at: 10)
    guard let cpm = metrics.charactersPerMinute,
          abs(cpm - 30) < 0.001,
          let codeLength = metrics.codeLength,
          abs(codeLength - 2) < 0.001,
          let keys = metrics.keysPerSecond,
          abs(keys - 1) < 0.001 else {
        return liveMetricsFail("rate arithmetic: \(metrics)")
    }
    guard let line = BufferLiveTypingMetricsFormatter.line(for: metrics),
          line.contains("30 字/分"), line.contains("码长 2.00"),
          line.contains("击键 1.0/秒"), !line.contains("回删") else {
        return liveMetricsFail("line text: \(BufferLiveTypingMetricsFormatter.line(for: metrics) ?? "nil")")
    }

    // A held key is one intent. Counting repeats would inflate both the key
    // count and the code length, making a schema look worse than it is.
    var repeated = BufferLiveTypingMetrics()
    repeated.noteKey(at: 0, isRepeat: false, isBackspace: false)
    for index in 1..<20 {
        repeated.noteKey(at: Double(index) * 0.05, isRepeat: true,
                         isBackspace: false)
    }
    repeated.noteCommit(characterCount: 1, at: 1)
    guard repeated.keyCount == 1, repeated.codeLength == 1 else {
        return liveMetricsFail("key repeats must not be counted")
    }

    // Free typing has no start or finish. Without a burst boundary the
    // figures would average over a lunch break and report a fast typist as a
    // slow one.
    var idle = BufferLiveTypingMetrics()
    idle.noteKey(at: 0, isRepeat: false, isBackspace: false)
    idle.noteCommit(characterCount: 4, at: 1)
    let resumeAt = 1 + BufferLiveTypingMetrics.burstIdleTimeout + 1
    idle.noteKey(at: resumeAt, isRepeat: false, isBackspace: false)
    guard idle.keyCount == 1, idle.committedCharacterCount == 0,
          idle.charactersPerMinute == nil else {
        return liveMetricsFail("an idle gap must start a new burst")
    }
    // A gap inside the timeout continues the same burst.
    var continuous = BufferLiveTypingMetrics()
    continuous.noteKey(at: 0, isRepeat: false, isBackspace: false)
    continuous.noteKey(at: BufferLiveTypingMetrics.burstIdleTimeout - 0.5,
                       isRepeat: false, isBackspace: false)
    guard continuous.keyCount == 2 else {
        return liveMetricsFail("a short pause must not reset the burst")
    }

    // Nothing is extrapolated from a fraction of a second, and code length is
    // undefined before the first commit rather than reported as zero.
    var brief = BufferLiveTypingMetrics()
    brief.noteKey(at: 0, isRepeat: false, isBackspace: false)
    brief.noteCommit(characterCount: 2, at: 0.2)
    guard brief.charactersPerMinute == nil, brief.keysPerSecond == nil,
          brief.codeLength != nil else {
        return liveMetricsFail("sub-second bursts must not be extrapolated")
    }
    var uncommitted = BufferLiveTypingMetrics()
    for index in 0..<5 {
        uncommitted.noteKey(at: Double(index), isRepeat: false,
                            isBackspace: false)
    }
    guard uncommitted.codeLength == nil,
          uncommitted.charactersPerMinute == nil,
          BufferLiveTypingMetricsFormatter.line(for: uncommitted)?
            .contains("击键") == true else {
        return liveMetricsFail("code length must wait for a commit")
    }

    // Corrections are counted only when they happen.
    var corrected = BufferLiveTypingMetrics()
    corrected.noteKey(at: 0, isRepeat: false, isBackspace: false)
    corrected.noteKey(at: 1, isRepeat: false, isBackspace: true)
    corrected.noteCommit(characterCount: 1, at: 2)
    guard corrected.backspaceCount == 1,
          BufferLiveTypingMetricsFormatter.line(for: corrected)?
            .contains("回删 1") == true else {
        return liveMetricsFail("backspace accounting")
    }
    guard BufferLiveTypingKeyRules.isBackspace("Backspace"),
          BufferLiveTypingKeyRules.isBackspace("ForwardDelete"),
          !BufferLiveTypingKeyRules.isBackspace("KeyA"),
          !BufferLiveTypingKeyRules.isBackspace("Enter") else {
        return liveMetricsFail("backspace key identity")
    }

    // The row sits under the input box, not inside it: the box keeps one
    // height, and only the panel grows by the row — in Default mode only,
    // and never while the rail is folded away.
    guard BufferWorkbenchMetrics.railHeight(for: .standard)
            == BufferInlineView.standardPreferredHeight,
          BufferWindowGeometry.height(expanded: false, mode: .standard,
                                      showsLiveMetrics: true)
            == BufferWindowGeometry.height(expanded: false, mode: .standard)
                + BufferWorkbenchMetrics.liveMetricsRowHeight,
          BufferWindowGeometry.height(expanded: true, mode: .standard,
                                      showsLiveMetrics: true)
            == BufferWindowGeometry.height(expanded: true, mode: .standard)
                + BufferWorkbenchMetrics.liveMetricsRowHeight,
          BufferWindowGeometry.height(expanded: false,
                                      mode: .derived(targetRows: 1),
                                      showsLiveMetrics: true)
            == BufferWindowGeometry.height(expanded: false,
                                           mode: .derived(targetRows: 1)),
          BufferWindowGeometry.height(expanded: true, mode: .standard,
                                      showsLiveMetrics: true, railFolded: true)
            == BufferWindowGeometry.toolbarOnlyHeight else {
        return liveMetricsFail("only the panel grows, only in Default, never when folded")
    }
    guard BufferLiveTypingMetricsFormatter.idleLine.contains("字/分"),
          BufferLiveTypingMetricsFormatter.idleLine.contains("码长"),
          BufferLiveTypingMetricsFormatter.idleLine.contains("击键") else {
        return liveMetricsFail("the idle row must name the figures it will show")
    }

    print("buffer live typing metrics smoke: OK")
    return true
}

private func liveMetricsFail(_ message: String) -> Bool {
    print("FAILED: \(message)")
    return false
}
