import Foundation

extension Notification.Name {
    static let bufferMusicDidChange = Notification.Name("bufferMusicDidChange")
}

enum BufferMusicMeter: String, CaseIterable {
    case threeFour = "3/4"
    case fourFour = "4/4"
    case sixEight = "6/8"

    var beatsPerBar: Int { self == .sixEight ? 6 : (self == .threeFour ? 3 : 4) }
    var quarterNotesPerBeat: Double { self == .sixEight ? 0.5 : 1 }
    var quarterNotesPerBar: Double { Double(beatsPerBar) * quarterNotesPerBeat }
}

struct BufferMusicLoopSnapshot: Equatable {
    var id: Int
    var bars: Int
    var recording: Bool
    var queued: Bool
    var muted: Bool
    var progress: Double
    var activity: [Int]
}

struct BufferMusicSnapshot: Equatable {
    var isActive = false
    var isReady = false
    var isRecording = false
    var isLooping = false
    var isDrumsEnabled = false
    var isTransitioning = false
    var bpm = 110
    var meter = BufferMusicMeter.fourFour
    var mode = BufferMusicMode.major
    var groove = BufferMusicGroove.rock
    var grooveSection = 0
    var fillTitle = ""
    var pressedKeys: [UInt16: UInt8] = [:]
    var loops: [BufferMusicLoopSnapshot] = []
    var transpose = 0
    var octaveShift = 0
    var rootName = "C"
    var octave = 4
    var beat = 1
    var loopBars = 0
    var activeNotes: [UInt8] = []
    var errorMessage: String?

    var chordName: String { BufferMusicTheory.chord(notes: Array(pressedKeys.values), tonic: 60 + transpose + octaveShift * 12, mode: mode) }
    var canAddLoop: Bool { loops.count < 2 || isRecording }
    var canChangeTiming: Bool { !isRecording && !isLooping }
    var statusText: String {
        if let errorMessage { return errorMessage }
        if !isReady { return isActive ? "正在准备音色" : "演奏已暂停" }
        if isRecording { return "录制中 · TAB 完成" }
        if isLooping { return "循环播放 · \(loopBars) 小节" }
        return "电音 · 即按即响"
    }
}

/// All voices and deadlines belong to one serial queue, independent of AppKit's
/// event loop. Deadlines use monotonic absolute time; a late tick never shifts
/// the origin of subsequent beats.
final class BufferMusicSession {
    static let shared = BufferMusicSession(audio: BufferMusicAudio())

    static let maximumTracks = 2
    static let maximumLoopBars = 16
    static let maximumRecordedEvents = 8_192
    static let transitionHoldDuration: TimeInterval = 0.35

    // Physical ANSI rows, high string first. Each first key is an open string;
    // moving right adds a fret. All four rows have exactly ten keys.
    static let stringKeys: [[UInt16]] = [
        [18, 19, 20, 21, 23, 22, 26, 28, 25, 29], // 1: G2
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35], // 2: D2
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41],      // 3: A1
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]     // 4: E1
    ]
    static let openStringNotes = [43, 38, 33, 28]
    static let noteKeys = stringKeys.flatMap { $0 }
    static let baseNotes = Dictionary(uniqueKeysWithValues: stringKeys.enumerated().flatMap { row, keys in
        keys.enumerated().map { fret, code in (code, openStringNotes[row] + fret) }
    })
    private static let controlKeys: Set<UInt16> = [48, 49, 53, 36, 76]

    private enum EventKind {
        case on(note: UInt8, voice: UInt64)
        case off(voice: UInt64)
        case drum(BufferMusicDrum, UInt8)
    }

    private struct RecordedEvent {
        let beat: Double
        let kind: EventKind
    }

    private struct HeldNote {
        let note: UInt8
        let voice: UInt64
    }

    private let audio: BufferMusicAudioOutput
    private let queue = DispatchQueue(label: "com.isaac.rimebuffer.music", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let snapshotLock = NSLock()
    private var cachedSnapshot = BufferMusicSnapshot()
    private var requestedActive = false
    private var activationGeneration: UInt64 = 0
    private let clock: () -> TimeInterval
    private let usesTimer: Bool
    private var timer: DispatchSourceTimer?
    private var state = BufferMusicSnapshot()
    private var lastPublished = BufferMusicSnapshot()
    private var voiceSequence: UInt64 = 0
    private var heldKeys: [UInt16: HeldNote] = [:]
    private var heldControls: Set<UInt16> = []
    private var voices: [UInt8: Set<UInt64>] = [:]
    private var recordingVoices: Set<UInt64> = []
    private var events: [RecordedEvent] = []
    private var recordOrigin: TimeInterval = 0
    private struct Track {
        var id: Int
        var events: [RecordedEvent]
        var origin: TimeInterval
        var length: Double
        var activity: [Int]
        var muted = false
        var cycle = 0
        var index = 0
        var voices: [UInt64: HeldNote] = [:]
    }
    private var tracks: [Track] = []
    private var nextTrackID = 1
    private var recordingStarted = false
    private var recordingActivityKey: (count: Int, length: Double)?
    private var recordingActivity: [Int] = []
    private var rhythmOrigin: TimeInterval = 0
    private var rhythm = BufferMusicDrumPerformance()
    private var spaceDownAt: TimeInterval?
    private var spaceBecameTransition = false
    private var audioReadyAt: TimeInterval = 0

    init(audio: BufferMusicAudioOutput,
         clock: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
         usesTimer: Bool = true) {
        self.audio = audio
        self.clock = clock
        self.usesTimer = usesTimer
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { timer?.cancel(); audio.stop() }

    var snapshot: BufferMusicSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return cachedSnapshot
    }

    /// The caller grants/revokes keyboard ownership when its music surface gains
    /// or loses focus. Revocation releases everything, including a held Space.
    func setActive(_ active: Bool) {
        snapshotLock.lock()
        guard requestedActive != active else { snapshotLock.unlock(); return }
        requestedActive = active
        activationGeneration &+= 1
        let generation = activationGeneration
        snapshotLock.unlock()
        queue.async { [self] in
            // A brief focus loss must release its old voices even if focus has
            // already returned by the time this queue handles the request.
            guard !active || isCurrentActivation(generation) else { return }
            state.isActive = active
            if active {
                state.isReady = false
                state.errorMessage = nil
                publish()
                do {
                    try audio.start()
                    guard isCurrentActivation(generation) else {
                        stopInternal()
                        audio.stop()
                        state.isActive = false
                        state.isReady = false
                        return
                    }
                    state.isReady = true
                    state.errorMessage = nil
                    audioReadyAt = clock()
                    rhythmOrigin = audioReadyAt
                } catch {
                    state.isReady = false
                    state.errorMessage = "音频启动失败：\(error.localizedDescription)"
                }
            } else {
                stopInternal()
                timer?.cancel()
                timer = nil
                audio.stop()
                state.isReady = false
            }
            publish()
        }
    }

    @discardableResult
    func handleKey(code: UInt16, isDown: Bool, isRepeat: Bool = false) -> Bool {
        let arrival = clock()
        snapshotLock.lock()
        let active = requestedActive
        let generation = activationGeneration
        snapshotLock.unlock()
        guard active, Self.baseNotes[code] != nil || Self.controlKeys.contains(code) else { return false }
        queue.async { [self] in
            guard isCurrentActivation(generation) else { return }
            _ = handleKeyInternal(code: code, isDown: isDown, isRepeat: isRepeat, arrival: arrival)
        }
        return true
    }

    private func handleKeyInternal(code: UInt16, isDown: Bool, isRepeat: Bool, arrival: TimeInterval) -> Bool {
        return synchronized {
            guard state.isActive,
                  Self.baseNotes[code] != nil || Self.controlKeys.contains(code) else { return false }
            guard state.isReady else { return true }
            // Keys pressed during sound-bank loading are owned by this surface,
            // but must not be replayed as a burst once the device is finally ready.
            guard arrival >= audioReadyAt else { return true }
            advanceInternal(to: arrival)
            if let baseNote = Self.baseNotes[code] {
                if isDown {
                    guard !isRepeat, heldKeys[code] == nil else { return true }
                    let midi = baseNote + state.transpose + state.octaveShift * 12
                    guard (0...127).contains(midi) else { return true }
                    let held = HeldNote(note: UInt8(midi), voice: newVoice())
                    heldKeys[code] = held
                    beginVoice(held)
                    if state.isRecording, recordingStarted {
                        recordingVoices.insert(held.voice)
                        append(.on(note: held.note, voice: held.voice), at: arrival)
                    }
                } else if let held = heldKeys.removeValue(forKey: code) {
                    endVoice(held)
                    if state.isRecording, recordingStarted, recordingVoices.remove(held.voice) != nil {
                        append(.off(voice: held.voice), at: arrival)
                    }
                }
            } else if isDown {
                guard !isRepeat, heldControls.insert(code).inserted else { return true }
                switch code {
                case 48: toggleRecording(at: arrival)
                case 49: beginFill(at: arrival)
                case 53: stopInternal()
                case 36, 76: toggleDrumsInternal(at: arrival)
                default: break
                }
            } else {
                heldControls.remove(code)
                if code == 49 { finishFill(at: arrival) }
            }
            finishIfAtEventLimit(at: arrival)
            publish()
            return true
        }
    }

    func setBPM(_ bpm: Int) {
        queue.async { [self] in
            guard state.canChangeTiming else { return }
            state.bpm = min(240, max(40, bpm))
            resetRhythm(at: clock())
            publish()
        }
    }

    func setMeter(_ meter: BufferMusicMeter) {
        queue.async { [self] in
            guard state.canChangeTiming else { return }
            state.meter = meter
            resetRhythm(at: clock())
            publish()
        }
    }

    func setMode(_ mode: BufferMusicMode) {
        queue.async { [self] in state.mode = mode; publish() }
    }
    func setGroove(_ groove: BufferMusicGroove) {
        queue.async { [self] in state.groove = groove; rhythm.style = groove; publish() }
    }
    func toggleTrackMute(_ id: Int) {
        queue.async { [self] in
            guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
            tracks[index].muted.toggle()
            if tracks[index].muted { releasePlayback(at: index) }
            else { tracks[index].index = 0 }
            publish()
        }
    }
    func removeTrack(_ id: Int) {
        queue.async { [self] in
            guard !state.isRecording, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
            releasePlayback(at: index)
            tracks.remove(at: index)
            state.isLooping = !tracks.isEmpty
            publish()
        }
    }

    func toggleDrums() {
        queue.async { [self] in
            guard state.isActive, state.isReady else { return }
            toggleDrumsInternal(at: clock())
            publish()
        }
    }

    func toggleLoopRecording() {
        queue.async { [self] in
            guard state.isActive, state.isReady else { return }
            let now = clock()
            advanceInternal(to: now)
            toggleRecording(at: now)
            publish()
        }
    }

    func stop() { queue.async { [self] in stopInternal(); publish() } }

    /// A deterministic entry point for the smoke test; live execution uses the
    /// same scheduler from its dispatch source.
    func advance(to uptime: TimeInterval) { queue.async { [self] in advanceInternal(to: uptime); publish() } }

    /// Tests only: production event handling and snapshot reads never wait for
    /// an audio start, device reconfiguration or the transport queue.
    func waitUntilIdleForTesting() { queue.sync {} }

    private func isCurrentActivation(_ generation: UInt64) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return generation == activationGeneration
    }

    private var secondsPerQuarter: Double { 60 / Double(state.bpm) }
    private var secondsPerBar: Double { secondsPerQuarter * state.meter.quarterNotesPerBar }

    func setTranspose(_ semitones: Int) {
        queue.async { [self] in
            let shift = semitones + state.octaveShift * 12
            guard Self.baseNotes.values.allSatisfy({ (0...127).contains($0 + shift) }) else { publish(); return }
            state.transpose = semitones
            publish()
        }
    }

    func setOctaveShift(_ octaves: Int) {
        queue.async { [self] in
            let shift = state.transpose + octaves * 12
            guard Self.baseNotes.values.allSatisfy({ (0...127).contains($0 + shift) }) else { publish(); return }
            state.octaveShift = octaves
            publish()
        }
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    private func startTimer() {
        guard usesTimer, timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(3), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.advanceInternal(to: self.clock())
            self.publish()
        }
        timer = source
        source.resume()
    }

    private func reconcileTimer() {
        let hasScheduledWork = state.isRecording || state.isLooping || rhythm.hasScheduledWork || spaceDownAt != nil
        if state.isActive && state.isReady && hasScheduledWork {
            startTimer()
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    private func newVoice() -> UInt64 { voiceSequence &+= 1; return voiceSequence }

    private func beginVoice(_ held: HeldNote) {
        let wasSilent = voices[held.note]?.isEmpty ?? true
        voices[held.note, default: []].insert(held.voice)
        if wasSilent { audio.noteOn(held.note, velocity: 96) }
    }

    private func endVoice(_ held: HeldNote) {
        guard var owners = voices[held.note], owners.remove(held.voice) != nil else { return }
        if owners.isEmpty {
            voices.removeValue(forKey: held.note)
            audio.noteOff(held.note)
        } else {
            voices[held.note] = owners
        }
    }

    private func releasePlayback(at index: Int) {
        for held in tracks[index].voices.values { endVoice(held) }
        tracks[index].voices.removeAll()
    }

    private func toggleRecording(at now: TimeInterval) {
        if state.isRecording {
            if recordingStarted { finishRecording(at: now) }
            else { state.isRecording = false; events.removeAll(); recordingVoices.removeAll() }
            return
        }
        guard tracks.count < Self.maximumTracks else { return }
        events.removeAll(keepingCapacity: true)
        recordingActivityKey = nil
        recordingVoices.removeAll()
        state.isRecording = true
        recordingStarted = false
        if let master = tracks.first {
            let length = master.length * secondsPerQuarter
            let cycle = max(0, ceil((now - master.origin) / length - 0.000_001))
            recordOrigin = master.origin + cycle * length
        } else {
            recordOrigin = now
            resetRhythm(at: now)
        }
        if now >= recordOrigin { startRecordingVoices() }
    }

    private func startRecordingVoices() {
        guard state.isRecording, !recordingStarted else { return }
        recordingStarted = true
        for held in heldKeys.values.sorted(by: { $0.voice < $1.voice }) {
            recordingVoices.insert(held.voice)
            append(.on(note: held.note, voice: held.voice), at: recordOrigin)
        }
    }

    private func append(_ kind: EventKind, at now: TimeInterval) {
        guard state.isRecording, recordingStarted, now >= recordOrigin else { return }
        events.append(RecordedEvent(beat: max(0, (now - recordOrigin) / secondsPerQuarter), kind: kind))
    }

    private func finishRecording(at now: TimeInterval) {
        guard recordingStarted else { return }
        let elapsed = max(0, now - recordOrigin)
        for voice in recordingVoices.sorted() { append(.off(voice: voice), at: now) }
        recordingVoices.removeAll()
        events = events.enumerated().sorted {
            if $0.element.beat == $1.element.beat { return $0.offset < $1.offset }
            return $0.element.beat < $1.element.beat
        }.map(\.element)
        let bars = tracks.first.map { Int(($0.length / state.meter.quarterNotesPerBar).rounded()) }
            ?? min(Self.maximumLoopBars, max(1, Int(ceil(elapsed / secondsPerBar - 0.000_001))))
        let length = Double(bars) * state.meter.quarterNotesPerBar
        if !events.isEmpty {
            tracks.append(Track(id: nextTrackID, events: events,
                                origin: recordOrigin + length * secondsPerQuarter, length: length,
                                activity: Self.activity(events, length: length)))
            nextTrackID += 1
        }
        events.removeAll(keepingCapacity: true)
        state.isRecording = false
        recordingStarted = false
        state.isLooping = !tracks.isEmpty
    }

    private func finishIfAtEventLimit(at now: TimeInterval) {
        if state.isRecording, recordingStarted, events.count >= Self.maximumRecordedEvents - Self.noteKeys.count {
            finishRecording(at: now)
        }
    }

    private func advanceInternal(to now: TimeInterval) {
        guard state.isActive, state.isReady else { return }
        if state.isRecording, now >= recordOrigin {
            startRecordingVoices()
            let duration = tracks.first.map { $0.length * secondsPerQuarter }
                ?? Double(Self.maximumLoopBars) * secondsPerBar
            if now >= recordOrigin + duration { finishRecording(at: recordOrigin + duration) }
        }
        advancePlayback(to: now)
        advanceFill(to: now)
        finishIfAtEventLimit(at: now)
        if rhythm.hasScheduledWork || state.isRecording || state.isLooping {
            let beatLength = secondsPerQuarter * state.meter.quarterNotesPerBeat
            state.beat = Int(max(0, now - rhythmOrigin) / beatLength) % state.meter.beatsPerBar + 1
        }
    }

    private func advancePlayback(to now: TimeInterval) {
        for index in tracks.indices {
            let origin = tracks[index].origin, length = tracks[index].length
            guard now >= origin, length > 0 else { continue }
            let beatNow = (now - origin) / secondsPerQuarter
            let cycle = Int(beatNow / length)
            if cycle > tracks[index].cycle {
                releasePlayback(at: index)
                tracks[index].cycle = cycle
                tracks[index].index = 0
            }
            let within = beatNow - Double(cycle) * length
            var desired = tracks[index].voices.mapValues(\.note)
            while tracks[index].index < tracks[index].events.count {
                let event = tracks[index].events[tracks[index].index]
                guard event.beat <= within + 0.000_001 else { break }
                tracks[index].index += 1
                switch event.kind {
                case let .on(note, voice): desired[voice] = note
                case let .off(voice): desired.removeValue(forKey: voice)
                case let .drum(hit, velocity):
                    if state.isDrumsEnabled, !tracks[index].muted, (within - event.beat) * secondsPerQuarter <= 0.06 {
                        audio.drum(hit, velocity: velocity)
                    }
                }
            }
            if tracks[index].muted { continue }
            for (voice, held) in tracks[index].voices where desired[voice] == nil {
                endVoice(held); tracks[index].voices.removeValue(forKey: voice)
            }
            for (voice, note) in desired where tracks[index].voices[voice] == nil {
                let held = HeldNote(note: note, voice: newVoice())
                tracks[index].voices[voice] = held
                beginVoice(held)
            }
        }
    }

    private func toggleDrumsInternal(at now: TimeInterval) {
        if !state.isDrumsEnabled, !state.isRecording, tracks.isEmpty, !rhythm.hasScheduledWork {
            resetRhythm(at: now)
        }
        state.isDrumsEnabled.toggle()
        rhythm.setEnabled(state.isDrumsEnabled, at: max(0, (now - rhythmOrigin) / secondsPerQuarter))
        if !state.isDrumsEnabled {
            spaceDownAt = nil
            spaceBecameTransition = false
            audio.silenceDrums()
        }
        advanceFill(to: now)
    }

    private func resetRhythm(at now: TimeInterval) {
        rhythmOrigin = now
        rhythm.meter = state.meter
        rhythm.style = state.groove
        rhythm.reset()
        state.beat = 1
    }

    private func beginFill(at now: TimeInterval) {
        // A fresh explicit Space gesture resumes the drummer visibly. Merely
        // keeping Space held after Enter turned it off must never restart it.
        if !state.isDrumsEnabled { toggleDrumsInternal(at: now) }
        if !rhythm.hasScheduledWork, !state.isRecording, tracks.isEmpty { resetRhythm(at: now) }
        spaceDownAt = now
        spaceBecameTransition = false
        rhythm.requestFill(at: max(0, (now - rhythmOrigin) / secondsPerQuarter))
    }

    private func finishFill(at now: TimeInterval) {
        if spaceBecameTransition {
            rhythm.releaseTransition(at: max(0, (now - rhythmOrigin) / secondsPerQuarter))
        }
        spaceDownAt = nil
    }

    private func advanceFill(to now: TimeInterval) {
        let beat = max(0, (now - rhythmOrigin) / secondsPerQuarter)
        if let down = spaceDownAt, now >= down + Self.transitionHoldDuration, !spaceBecameTransition {
            spaceBecameTransition = true
            rhythm.beginTransition(at: beat)
        }
        for hit in rhythm.advance(to: beat, secondsPerQuarter: secondsPerQuarter) {
            audio.drum(hit.drum, velocity: hit.velocity)
            // The backing groove is generated separately; only user-requested
            // fills are recorded so ordinary overdubs never double the drummer.
            if state.isRecording, hit.isFill {
                append(.drum(hit.drum, hit.velocity), at: rhythmOrigin + hit.beat * secondsPerQuarter)
            }
        }
        state.isTransitioning = rhythm.fill?.transition == true
        state.fillTitle = rhythm.fillTitle
        state.grooveSection = rhythm.section
    }

    private func stopInternal() {
        audio.silence()
        heldKeys.removeAll()
        heldControls.removeAll()
        voices.removeAll()
        recordingVoices.removeAll()
        tracks.removeAll()
        recordingStarted = false
        events.removeAll(keepingCapacity: true)
        state.isRecording = false
        state.isLooping = false
        state.isDrumsEnabled = false
        state.isTransitioning = false
        state.loopBars = 0
        state.beat = 1
        spaceDownAt = nil
        spaceBecameTransition = false
        rhythm.enabled = false
        rhythm.reset()
        state.fillTitle = ""
    }

    private func publish() {
        reconcileTimer()
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let root = 60 + state.transpose + state.octaveShift * 12
        state.rootName = names[(root % 12 + 12) % 12]
        state.octave = root / 12 - 1
        state.activeNotes = voices.keys.sorted()
        state.pressedKeys = heldKeys.mapValues(\.note)
        let now = clock()
        state.loops = tracks.map { track in
            let beat = max(0, (now - track.origin) / secondsPerQuarter)
            let progress = floor((beat.truncatingRemainder(dividingBy: track.length) / track.length) * 64) / 64
            return BufferMusicLoopSnapshot(id: track.id, bars: Int((track.length / state.meter.quarterNotesPerBar).rounded()),
                recording: false, queued: now < track.origin, muted: track.muted,
                progress: progress, activity: track.activity)
        }
        if state.isRecording {
            let length = tracks.first?.length ?? max(state.meter.quarterNotesPerBar, ceil(max(0, now - recordOrigin) / secondsPerBar) * state.meter.quarterNotesPerBar)
            if recordingActivityKey?.count != events.count || recordingActivityKey?.length != length {
                recordingActivity = Self.activity(events, length: length)
                recordingActivityKey = (events.count, length)
            }
            state.loops.append(.init(id: nextTrackID, bars: Int((length / state.meter.quarterNotesPerBar).rounded()),
                recording: true, queued: !recordingStarted, muted: false,
                progress: floor(min(1, max(0, now - recordOrigin) / secondsPerQuarter / length) * 64) / 64,
                activity: recordingActivity))
        }
        state.loopBars = state.loops.first?.bars ?? 0
        snapshotLock.lock()
        cachedSnapshot = state
        snapshotLock.unlock()
        guard state != lastPublished else { return }
        lastPublished = state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .bufferMusicDidChange, object: self)
        }
    }

    private static func activity(_ events: [RecordedEvent], length: Double) -> [Int] {
        var bins = [Int](repeating: 0, count: 32)
        for event in events {
            switch event.kind {
            case .on, .drum: bins[min(31, max(0, Int(event.beat / max(1, length) * 32)))] += 1
            case .off: break
            }
        }
        return bins
    }
}
