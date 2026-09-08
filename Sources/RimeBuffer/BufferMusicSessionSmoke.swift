import Foundation

private final class MusicProbeClock {
    var now: TimeInterval = 100
}

private final class MusicProbeAudio: BufferMusicAudioOutput {
    enum Call: Equatable {
        case start, on(UInt8), off(UInt8), drum(BufferMusicDrum, UInt8), silence, drumsSilenced, stop
    }
    var calls: [Call] = []
    var shouldFail = false
    var onStart: (() -> Void)?
    func start() throws {
        if shouldFail { throw NSError(domain: "MusicProbe", code: 1) }
        calls.append(.start)
        onStart?()
    }
    func noteOn(_ note: UInt8, velocity: UInt8) { calls.append(.on(note)) }
    func noteOff(_ note: UInt8) { calls.append(.off(note)) }
    func drum(_ hit: BufferMusicDrum, velocity: UInt8) { calls.append(.drum(hit, velocity)) }
    func silence() { calls.append(.silence) }
    func silenceDrums() { calls.append(.drumsSilenced) }
    func stop() { calls.append(.stop) }
}

/// Production transport, two simultaneous loop layers, and deterministic drum
/// gestures. Synthetic time stays independent of the UI/audio-device thread.
func runBufferMusicSessionSmokeTest() -> Bool {
    let audio = MusicProbeAudio(), clock = MusicProbeClock()
    let session = BufferMusicSession(audio: audio, clock: { clock.now }, usesTimer: false)
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        session.waitUntilIdleForTesting()
        if !condition() { failures.append(message) }
    }
    func key(_ code: UInt16, down: Bool = true, repeatKey: Bool = false) {
        _ = session.handleKey(code: code, isDown: down, isRepeat: repeatKey)
        session.waitUntilIdleForTesting()
    }
    func tap(_ code: UInt16) { key(code); key(code, down: false) }
    func advance(_ seconds: Double) { clock.now += seconds; session.advance(to: clock.now); session.waitUntilIdleForTesting() }
    func stop() { session.stop(); session.waitUntilIdleForTesting() }

    expect(!session.handleKey(code: 18, isDown: true), "inactive instrument owns no key")
    session.setActive(true)
    expect(session.snapshot.isReady, "audio preparation")
    session.setBPM(120)
    let bassRows: [[UInt16]] = [[18,19,20,21,23,22,26,28,25,29],
        [12,13,14,15,17,16,32,34,31,35], [0,1,2,3,5,4,38,40,37,41],
        [6,7,8,9,11,45,46,43,47,44]]
    for (row, keys) in bassRows.enumerated() {
        for (fret, code) in keys.enumerated() {
            let note = UInt8([43,38,33,28][row] + fret)
            key(code)
            expect(session.snapshot.activeNotes == [note], "bass string \(row + 1), fret \(fret)")
            expect(session.snapshot.pressedKeys[code] == note, "physical key-state projection")
            key(code, down: false)
            expect(session.snapshot.activeNotes.isEmpty, "physical note release")
        }
    }
    for code: UInt16 in [27,24,33,30,39,60] {
        expect(!session.handleKey(code: code, isDown: true), "excluded eleventh/twelfth keys")
    }
    key(18); key(16) // G2: string 1 open and string 2 fret 5.
    key(18, down: false)
    expect(session.snapshot.activeNotes == [43] && session.snapshot.pressedKeys[16] == 43,
           "same pitch on separate strings has independent release ownership")
    key(16, down: false)
    expect(session.snapshot.activeNotes.isEmpty, "last unison key releases the note")
    key(18); key(18, repeatKey: true)
    for code: UInt16 in [123, 124, 125, 126] { expect(!session.handleKey(code: code, isDown: true), "arrow keys never change musical pitch") }
    expect(session.snapshot.transpose == 0, "plain arrows must not transpose")
    session.setTranspose(1); session.setOctaveShift(1)
    expect(session.snapshot.rootName == "C♯" && session.snapshot.octaveShift == 1, "stepper transposition")
    key(18, down: false)
    expect(session.snapshot.activeNotes.isEmpty, "transpose while holding releases original pitch")
    session.setTranspose(0); session.setOctaveShift(0)
    expect(BufferMusicTheory.chord(notes: [60,64,67], tonic: 60, mode: .major) == "C · I", "major chord")
    expect(BufferMusicTheory.chord(notes: [64,67,72], tonic: 60, mode: .major) == "C/E · I", "inversion")
    expect(BufferMusicTheory.chord(notes: [57,60,64,67], tonic: 57, mode: .minor) == "Am7 · i", "minor seventh in selected mode")
    expect(BufferMusicTheory.chord(notes: [60,61,62], tonic: 60, mode: .major) == "—", "cluster is not a named chord")
    expect(BufferMusicTheory.solfege(note: 64, tonic: 61, mode: .minor) == "Me", "chromatic movable-do")

    // First take is a one-bar G2; the overdub B2 has exactly the same period.
    tap(48); key(18); advance(0.6); key(18, down: false); tap(48)
    expect(session.snapshot.loops.count == 1 && session.snapshot.loopBars == 1, "first take creates one track")
    advance(1.4)
    expect(session.snapshot.activeNotes == [43], "first loop begins at whole-bar boundary")
    tap(48); key(23); advance(0.2); key(23, down: false); tap(48)
    expect(session.snapshot.loops.count == 2 && session.snapshot.isLooping, "second take adds, never replaces")
    advance(1.8)
    expect(session.snapshot.activeNotes == [43,47], "two layers sound simultaneously at aligned boundary")
    let IDs = session.snapshot.loops.map(\.id)
    tap(48)
    expect(session.snapshot.loops.map(\.id) == IDs && !session.snapshot.isRecording, "third layer blocked without destroying takes")
    key(18); key(18, down: false)
    expect(session.snapshot.activeNotes.contains(43), "live keyup cannot stop loop's same pitch")
    session.toggleTrackMute(IDs[1])
    expect(session.snapshot.activeNotes == [43], "mute releases only the addressed track")
    session.toggleTrackMute(IDs[1])
    advance(0.01)
    expect(session.snapshot.activeNotes == [43,47], "unmute reconstructs sustained note")
    session.removeTrack(IDs[0])
    expect(session.snapshot.loops.count == 1 && session.snapshot.activeNotes == [47], "remove preserves other layer")
    stop()
    expect(session.snapshot.loops.isEmpty && session.snapshot.activeNotes.isEmpty, "Escape clears all voices/tracks")

    // Overdub requested between boundaries waits; it auto-completes one master
    // period and disallows a mid-record tempo/meter change.
    tap(48); key(18); advance(0.15); key(18, down: false); tap(48)
    advance(2.1); tap(48)
    expect(session.snapshot.loops.count == 2 && session.snapshot.loops.last?.queued == true, "overdub armed at next master boundary")
    session.setBPM(90); session.setMeter(.threeFour)
    expect(session.snapshot.bpm == 120 && session.snapshot.meter == .fourFour, "shared timing frozen while looping")
    advance(1.75); key(23); advance(0.2); key(23, down: false); advance(1.8)
    expect(!session.snapshot.isRecording && session.snapshot.loops.count == 2, "overdub auto-completes matching master period")
    stop()

    session.setMeter(.sixEight); tap(48); key(18); advance(0.1); key(18, down: false); tap(48); advance(1.4)
    expect(session.snapshot.activeNotes == [43] && session.snapshot.loopBars == 1, "6/8 is six eighth notes")
    audio.calls.removeAll(); advance(3.3)
    expect(session.snapshot.activeNotes.isEmpty && !audio.calls.contains(.on(43)), "stalled scheduler drops expired notes")
    stop(); session.setMeter(.fourFour)
    tap(48); key(21); advance(32)
    expect(!session.snapshot.isRecording && session.snapshot.loopBars == 16, "first take limited to 16 bars")
    key(21, down: false); stop()
    tap(48)
    for _ in 0..<4_100 {
        if !session.snapshot.isRecording { break }
        tap(18); clock.now += 0.0001
    }
    expect(!session.snapshot.isRecording && session.snapshot.isLooping, "bounded event storage finishes take")
    stop()

    // Test the actual drum performance planner at sub-beat resolution.
    var drummer = BufferMusicDrumPerformance()
    drummer.setEnabled(true, at: 0)
    expect(drummer.advance(to: 0, secondsPerQuarter: 0.5).contains { $0.drum == .kick }, "sampled kick on initial downbeat")
    drummer.requestFill(at: 3.4)
    expect(drummer.fill?.start == 4 && drummer.fill?.end == 8, "late-bar fill queues next measure")
    drummer.beginTransition(at: 4.4); drummer.releaseTransition(at: 5.2)
    expect(drummer.fill?.end == 8 && drummer.fill?.transition == true, "transition release waits for measure boundary")
    var hits: [BufferMusicDrumHit] = []
    for step in 1...128 { hits += drummer.advance(to: Double(step) / 16, secondsPerQuarter: 0.5) }
    expect(drummer.fill == nil && drummer.section == 1, "transition returns to groove's next section")
    expect(hits.filter { $0.beat == 8 && $0.drum == .kick }.count == 1, "boundary has a single kick, not fill plus main double hit")
    var variations = Set<Int>()
    for i in 0..<8 { drummer.requestFill(at: Double(i * 8)); variations.insert(drummer.fill!.variant) }
    expect(variations.count == 8, "all eight fill variations before repeat")
    for meter in BufferMusicMeter.allCases {
        let patterns = (0..<8).map { BufferMusicPatterns.fill($0, meter: meter, transition: false) }
        expect(Set(patterns.map { String(describing: $0) }).count == 8, "distinct fills for \(meter)")
        expect(patterns.flatMap { $0 }.allSatisfy { $0.beat >= 0 && $0.beat < meter.quarterNotesPerBar && $0.velocity > 0 }, "bounded fill positions")
        expect(patterns.flatMap { $0 }.contains { $0.velocity < 45 }, "ghost-note dynamics")
    }
    tap(36)
    expect(session.snapshot.isDrumsEnabled, "Enter enables sampled drum groove")
    key(49); advance(0.36)
    expect(session.snapshot.isTransitioning, "long Space starts transition")
    key(49, down: false)
    expect(session.snapshot.isTransitioning, "release does not cut transition abruptly")
    tap(53); let stoppedCount = audio.calls.count; advance(2)
    expect(audio.calls.count == stoppedCount && session.snapshot.loops.isEmpty && !session.snapshot.isDrumsEnabled, "Escape leaves no scheduled hits")
    // Enter cancels even a held-space transition and its sampler tail.
    key(49); advance(0.36)
    expect(session.snapshot.isDrumsEnabled && session.snapshot.isTransitioning, "Space visibly resumes drummer")
    tap(36)
    expect(!session.snapshot.isDrumsEnabled && !session.snapshot.isTransitioning && session.snapshot.fillTitle.isEmpty,
           "drummer off cancels the current transition")
    expect(audio.calls.last == .drumsSilenced, "drummer off clears the sounding sampler voices")
    let noDrums = audio.calls.count
    advance(2)
    expect(audio.calls.count == noDrums, "held Space cannot restart disabled drums")
    key(49, down: false)
    stop()
    // Recorded fill hits obey the same off switch; melodic loop ownership stays.
    tap(48); key(18); key(49); advance(0.13); key(49, down: false)
    advance(0.1); key(18, down: false); tap(48); advance(1.77)
    expect(session.snapshot.isLooping && session.snapshot.activeNotes == [43], "melodic and drum take playing")
    tap(36)
    expect(session.snapshot.activeNotes == [43] && session.snapshot.loops.count == 1,
           "drummer off preserves the melodic loop")
    audio.calls.removeAll()
    for _ in 0..<90 { advance(0.05) }
    expect(!audio.calls.contains { if case .drum = $0 { return true }; return false },
           "recorded fill cannot bypass the drummer off switch")
    tap(36); audio.calls.removeAll()
    for _ in 0..<20 { advance(0.05) }
    expect(audio.calls.contains { if case .drum = $0 { return true }; return false }, "drummer can resume normally")
    stop()
    session.setActive(false)
    expect(!session.snapshot.isActive && !session.snapshot.isReady, "focus revocation")
    let loadingAudio = MusicProbeAudio()
    let enteredStart = DispatchSemaphore(value: 0)
    let releaseStart = DispatchSemaphore(value: 0)
    loadingAudio.onStart = { enteredStart.signal(); _ = releaseStart.wait(timeout: .now() + 2) }
    let loading = BufferMusicSession(audio: loadingAudio, usesTimer: false)
    loading.setActive(true)
    expect(enteredStart.wait(timeout: .now() + 1) == .success, "async audio startup did not execute")
    let snapshotDuringLoad = loading.snapshot // Must return while start() is blocked.
    expect(!snapshotDuringLoad.isReady, "loading snapshot incorrectly reported ready")
    expect(loading.handleKey(code: 18, isDown: true), "activation did not reserve mapped key ownership while loading")
    loading.setActive(false)
    releaseStart.signal()
    loading.waitUntilIdleForTesting()
    expect(!loading.snapshot.isActive && !loadingAudio.calls.contains(.on(43)),
           "focus loss during audio loading emitted a queued stale note")

    loadingAudio.onStart = nil
    loading.setActive(true)
    loading.waitUntilIdleForTesting()
    _ = loading.handleKey(code: 18, isDown: true)
    loading.waitUntilIdleForTesting()
    loading.setActive(false)
    loading.setActive(true)
    loading.waitUntilIdleForTesting()
    expect(loading.snapshot.isReady && loading.snapshot.activeNotes.isEmpty,
           "brief focus loss/reactivation preserved an orphaned voice")
    loading.setActive(false)
    loading.waitUntilIdleForTesting()
    if failures.isEmpty {
        print("PASS: music mapping, repeat suppression, transposition, loop timing, voice ownership, limits, drums and lifecycle")
        return true
    }
    for failure in failures { print("FAILED: \(failure)") }
    return false
}
