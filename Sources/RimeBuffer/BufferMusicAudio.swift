import AudioKit
import AVFoundation
import Foundation

enum BufferMusicDrum: String, CaseIterable {
    case kick, sideStick, snare, clap, snareEdge, lowTom, closedHat, floorTomEdge
    case pedalHat, highTom, openHat, tomEdge, swishHat, crash, crashChoke
    case ride, rideChoke, rideBell, tambourine, splash, cowbell, crashRight
    case crashRightChoke, rideShank, crashLarge, maracas

    /// AVL's documented map differs from General MIDI for the toms/cymbals.
    var midiNote: UInt8 { UInt8(36 + Self.allCases.firstIndex(of: self)!) }
    var chokeGroup: Int? {
        switch self {
        case .closedHat, .pedalHat, .openHat, .swishHat: return 1
        case .crash, .crashChoke: return 2
        case .ride, .rideChoke, .rideShank: return 3
        case .crashRight, .crashRightChoke: return 4
        default: return nil
        }
    }
}

enum BufferMusicDrumKit {
    static let fileName = "Black_Pearl_4_LV2.sf2"
    static func url() throws -> URL {
        // SwiftPM executable bundles and a signed .app have different roots.
        if let resources = Bundle.main.resourceURL {
            let installed = resources.appendingPathComponent("RimeBuffer_RimeBuffer.bundle/Music/" + fileName)
            if FileManager.default.fileExists(atPath: installed.path) { return installed }
        }
        if let bundled = Bundle.module.url(forResource: "Black_Pearl_4_LV2", withExtension: "sf2", subdirectory: "Music") {
            return bundled
        }
        throw NSError(domain: "RIMES.Music", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "缺少 Black Pearl 架子鼓音源，请重新安装 RIMES"])
    }
}

/// All calls belong to the music transport's serial queue, never the IMK or audio render callback.
protocol BufferMusicAudioOutput: AnyObject {
    func start() throws
    func noteOn(_ note: UInt8, velocity: UInt8)
    func noteOff(_ note: UInt8)
    func drum(_ hit: BufferMusicDrum, velocity: UInt8)
    func silenceDrums()
    func silence()
    func stop()
}

/// AudioKit owns the graph, MIDI samplers, mixing, and room effect. The small sound bank is
/// synthesized once for the electronic voice; drums load the bundled, attributed AVL acoustic samples.
final class BufferMusicAudio: BufferMusicAudioOutput {
    // The session can be observed by UI before Music is selected. Allocate audio units
    // only on its first explicit start, on the transport queue, not at IME launch.
    private lazy var engine = AudioKit.AudioEngine()
    private lazy var synths = [AppleSampler(), AppleSampler()]
    private lazy var percussion = AppleSampler()
    private var output: Mixer?
    private var room: Reverb?
    private var limiter: PeakLimiter?
    private var prepared = false
    private var melodyBankURL: URL?
    private var started = false
    private var nextAge: UInt64 = 0
    private struct Voice {
        var note: UInt8?
        var active = false
        var age: UInt64 = 0
    }
    // Each slot owns one MIDI channel. Reusing it first sends All Sound Off, so bursts
    // and long release tails cannot create unbounded sampler voices.
    private var voices = Array(repeating: Voice(), count: 32)
    private var drumVoices = Array<BufferMusicDrum?>(repeating: nil, count: 16)
    private var nextDrumVoice = 0

    func start() throws {
        try prepare()
        guard !engine.avEngine.isRunning else { started = true; return }
        try engine.start()
        // AVAudioEngine stop/start reallocates the sampler's resources. Restore
        // the selected instruments after restart, not just the graph connection.
        try loadInstruments()
        started = true
    }

    deinit {
        if let folder = melodyBankURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
    }

    func noteOn(_ note: UInt8, velocity: UInt8) {
        guard note < 128, velocity > 0, resumeAfterDeviceChangeIfNeeded() else { return }
        if let existing = voices.firstIndex(where: { $0.active && $0.note == note }) {
            releaseVoice(existing)
        }
        let slot = voices.indices.min {
            let lhs = voices[$0], rhs = voices[$1]
            if (lhs.note == nil) != (rhs.note == nil) { return lhs.note == nil }
            if lhs.active != rhs.active { return !lhs.active }
            return lhs.age < rhs.age
        } ?? 0
        let sampler = synths[slot / 16]
        let channel = UInt8(slot % 16)
        sampler.samplerUnit.sendController(120, withValue: 0, onChannel: channel)
        output?.volume = 0.74
        nextAge &+= 1
        voices[slot] = Voice(note: note, active: true, age: nextAge)
        sampler.play(noteNumber: note, velocity: min(127, velocity), channel: channel)
    }

    func noteOff(_ note: UInt8) {
        for slot in voices.indices where voices[slot].active && voices[slot].note == note {
            releaseVoice(slot)
        }
    }

    func drum(_ hit: BufferMusicDrum, velocity: UInt8) {
        guard velocity > 0, resumeAfterDeviceChangeIfNeeded() else { return }
        if let group = hit.chokeGroup {
            for slot in drumVoices.indices where drumVoices[slot]?.chokeGroup == group {
                percussion.samplerUnit.sendController(120, withValue: 0, onChannel: UInt8(slot))
                drumVoices[slot] = nil
            }
        }
        let slot = nextDrumVoice
        nextDrumVoice = (slot + 1) % drumVoices.count
        let channel = UInt8(slot)
        percussion.samplerUnit.sendController(120, withValue: 0, onChannel: channel)
        output?.volume = 0.74
        percussion.amplitude = -7
        drumVoices[slot] = hit
        percussion.play(noteNumber: hit.midiNote, velocity: min(127, velocity), channel: channel)
    }

    func silenceDrums() {
        guard prepared else { return }
        percussion.amplitude = -90
        for channel in UInt8(0)..<UInt8(16) {
            percussion.samplerUnit.sendController(120, withValue: 0, onChannel: channel)
        }
        drumVoices = Array(repeating: nil, count: drumVoices.count)
    }

    /// Escape and focus loss stop all sound, including pending reverb. Key-up uses the
    /// instrument's envelope instead, preserving a short, click-free musical release.
    func silence() {
        guard prepared else { return }
        output?.volume = 0
        for sampler in synths + [percussion] {
            for channel in UInt8(0)..<UInt8(16) {
                sampler.samplerUnit.sendController(120, withValue: 0, onChannel: channel)
            }
            sampler.resetSampler()
        }
        room?.avAudioNode.reset()
        limiter?.avAudioNode.reset()
        voices = Array(repeating: Voice(), count: voices.count)
        drumVoices = Array(repeating: nil, count: drumVoices.count)
    }

    func stop() {
        started = false
        guard prepared else { return }
        silence()
        engine.stop()
    }

    private func releaseVoice(_ slot: Int) {
        guard let note = voices[slot].note else { return }
        synths[slot / 16].stop(noteNumber: note, channel: UInt8(slot % 16))
        voices[slot].active = false
    }

    private func resumeAfterDeviceChangeIfNeeded() -> Bool {
        guard started else { return false }
        // AVAudioEngine may stop after an output-device change. Do not reload the bank
        // or rebuild the graph on a note; just resume the already prepared engine.
        if !engine.avEngine.isRunning {
            do { try engine.start(); try loadInstruments() }
            catch { engine.stop(); return false }
        }
        return engine.avEngine.isRunning
    }

    private func prepare() throws {
        guard !prepared else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimes-music-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let bank = folder.appendingPathComponent("NeonCircuit.sf2")
        try BufferMusicSoundBank.make().write(to: bank, options: .atomic)
        melodyBankURL = bank

        let melody = Mixer(synths[0], synths[1])
        let room = Reverb(melody, dryWetMix: 0.13)
        room.loadFactoryPreset(.mediumRoom)
        room.dryWetMix = 0.13
        // Drums stay dry: a firm kick and clear transient remain audible in dense loops.
        let master = Mixer(room, percussion)
        master.volume = 0.74
        let limiter = PeakLimiter(master, attackTime: 0.001, decayTime: 0.025, preGain: 0)
        engine.output = limiter
        self.room = room
        self.limiter = limiter
        output = master
        try loadInstruments()
        prepared = true
    }

    private func loadInstruments() throws {
        guard let bank = melodyBankURL else { return }
        for sampler in synths {
            try sampler.samplerUnit.loadSoundBankInstrument(at: bank, program: 0,
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
            sampler.amplitude = -3
        }
        try percussion.samplerUnit.loadSoundBankInstrument(at: BufferMusicDrumKit.url(), program: 0,
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
        percussion.amplitude = -7
    }

    fileprivate func offlineSmoke() throws -> Bool {
        try prepare()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else { return false }
        try engine.avEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        started = true
        defer { stop(); engine.avEngine.disableManualRenderingMode() }

        func render(_ seconds: Double) throws -> (rms: Double, peak: Double) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512) else { return (0, 0) }
            var remaining = Int(seconds * format.sampleRate)
            var sum = 0.0, peak = 0.0, count = 0, stalled = 0
            while remaining > 0 {
                let frames = AVAudioFrameCount(min(remaining, 512))
                let status = try engine.avEngine.renderOffline(frames, to: buffer)
                guard status == .success else {
                    stalled += 1
                    if stalled > 16 { return (Double.nan, Double.nan) }
                    continue
                }
                guard let samples = buffer.floatChannelData, buffer.frameLength > 0 else { return (.nan, .nan) }
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<Int(buffer.frameLength) {
                        let value = Double(samples[channel][index])
                        guard value.isFinite else { return (.nan, .nan) }
                        sum += value * value
                        peak = max(peak, abs(value))
                        count += 1
                    }
                }
                remaining -= Int(buffer.frameLength)
            }
            return (sqrt(sum / Double(max(1, count))), peak)
        }

        drum(.kick, velocity: 110)
        let originalKick = try render(0.25)
        silence()
        _ = try render(0.25)
        drum(.kick, velocity: 110)
        let resumedKick = try render(0.25)
        print("Kick before/after stop: RMS \(originalKick.rms) / \(resumedKick.rms), peak \(originalKick.peak) / \(resumedKick.peak)")
        guard abs(originalKick.rms - resumedKick.rms) < originalKick.rms * 0.15 else {
            print("FAILED: stopping/restarting changed the loaded drum instrument")
            return false
        }
        for channelPass in 0..<32 {
            silence()
            _ = try render(0.25)
            drum(.kick, velocity: 110)
            let result = try render(0.25)
            guard abs(result.rms - originalKick.rms) < originalKick.rms * 0.15 else {
                print("FAILED: rotating drum channel changed timbre at hit \(channelPass), RMS \(result.rms)")
                return false
            }
        }
        for restart in 0..<3 {
            stop()
            try start()
            _ = try render(0.25)
            drum(.kick, velocity: 110)
            let result = try render(0.25)
            guard abs(result.rms - originalKick.rms) < originalKick.rms * 0.15 else {
                print("FAILED: audio restart changed timbre at \(restart), RMS \(result.rms)")
                return false
            }
        }
        silence()
        noteOn(60, velocity: 96)
        noteOn(64, velocity: 88)
        noteOn(67, velocity: 92)
        let chord = try render(0.25)
        noteOff(60); noteOff(64); noteOff(67)
        _ = try render(1.8)
        let release = try render(0.1)
        guard chord.rms > 0.0001, chord.peak < 1.0,
              release.rms.isFinite, release.rms < chord.rms * 0.08 else { return false }
        for hit in BufferMusicDrum.allCases {
            // Exercise all five real sample layers, including quiet ghost notes.
            for velocity: UInt8 in [20, 40, 65, 90, 115] {
                silence()
                drum(hit, velocity: velocity)
                let result = try render(0.18)
                guard result.rms > 0.0000001, result.peak.isFinite, result.peak < 1.0 else {
                    print("Drum render failed: \(hit), velocity \(velocity), RMS \(result.rms)")
                    return false
                }
            }
        }
        silence()
        drum(.crash, velocity: 115)
        _ = try render(0.05)
        silenceDrums()
        _ = try render(0.03)
        let mutedDrum = try render(0.1)
        guard mutedDrum.rms < 0.00001 else {
            print("FAILED: disabled drummer still has a sounding tail")
            return false
        }
        noteOn(28, velocity: 96)
        drum(.openHat, velocity: 110)
        _ = try render(0.05)
        silenceDrums()
        let bassWithDrumsOff = try render(0.2)
        guard bassWithDrumsOff.rms > 0.0001 else {
            print("FAILED: disabling drums cut the independent electronic bass")
            return false
        }
        noteOff(28)
        silence()
        for note in UInt8(48)..<UInt8(96) { noteOn(note, velocity: 127) }
        for _ in 0..<8 {
            for hit in BufferMusicDrum.allCases { drum(hit, velocity: 127) }
        }
        let dense = try render(0.18)
        guard voices.filter(\.active).count == 32, dense.rms > 0.0001,
              dense.peak.isFinite, dense.peak <= 1.001 else { return false }
        silence()
        _ = try render(0.1)
        let stopped = try render(0.1)
        return stopped.rms.isFinite && stopped.rms < 0.00001
    }
}

/// This test uses AVAudioEngine's offline rendering mode and never plays through speakers.
func runBufferMusicAudioSmokeTest() -> Bool {
    do {
        let passed = try BufferMusicAudio().offlineSmoke()
        print("Music AudioKit offline smoke: \(passed ? "OK" : "FAIL") (26 drum articulations × 5 velocity zones; electronic lead, release, limiter, stop)")
        return passed
    }
    catch { print("Buffer Music audio smoke failed: \(error.localizedDescription)"); return false }
}

/// Minimal original SF2 bank. Periodic band-limited harmonic samples provide a rounded
/// electronic pluck with a sustaining body; MIDI envelopes shape every press and release.
/// The electronic lead is synthesized locally; the drum path never uses this bank.
private enum BufferMusicSoundBank {
    private struct Sample {
        var name: String
        var pcm: [Int16]
        var rate: UInt32 = 44_100
        var root: UInt8
        var loopStart = 0
        var loopEnd = 0
    }
    private struct Zone {
        var generators: [(UInt16, UInt16)]
    }

    static func make() -> Data {
        var samples: [Sample] = []
        var synthZones: [Zone] = []
        let roots = Array(stride(from: 24, through: 108, by: 12))
        for (index, root) in roots.enumerated() {
            let frequency = 440 * pow(2, Double(root - 69) / 12)
            let cycle = max(8, Int((44_100 / frequency).rounded()))
            let rate = UInt32((frequency * Double(cycle)).rounded())
            let harmonics = max(1, min(28, Int(Double(rate) * 0.28 / frequency)))
            var wave = [Double](repeating: 0, count: cycle * 8)
            for i in wave.indices {
                let phase = 2 * Double.pi * Double(i % cycle) / Double(cycle)
                var value = 0.0
                for partial in 1...harmonics {
                    let harmonic = Double(partial)
                    let color = partial.isMultiple(of: 2) ? 0.55 : 1.0
                    value += sin(phase * harmonic) * color * exp(-harmonic * 0.095) / harmonic
                }
                wave[i] = value
            }
            let peak = wave.map(abs).max() ?? 1
            let pcm = wave.map { Int16(($0 / max(peak, 0.001) * 23_000).rounded()) }
            samples.append(Sample(name: "Neon \(root)", pcm: pcm, rate: rate, root: UInt8(root),
                                  loopStart: cycle * 2, loopEnd: cycle * 6))
            let low = index == 0 ? 0 : root - 6
            let high = index == roots.count - 1 ? 127 : root + 5
            synthZones.append(Zone(generators: [
                (43, UInt16(low | (high << 8))), // key range must precede other generators
                (8, 9_200), (9, 25), (11, 3_300), // filter and modulation-envelope depth
                (26, signed(-9_000)), (28, signed(-1_400)), (29, 850), (30, signed(-2_900)),
                (34, signed(-8_800)), (36, signed(-1_800)), (37, 105), (38, signed(-2_800)),
                (54, 1), (58, UInt16(root)), (53, UInt16(index)),
            ]))
        }
        return encode(samples: samples, synth: synthZones)
    }

    private static func signed(_ value: Int16) -> UInt16 { UInt16(bitPattern: value) }

    private static func encode(samples: [Sample], synth: [Zone]) -> Data {
        var smpl = Data(), shdr = Data()
        for sample in samples {
            let start = UInt32(smpl.count / 2)
            for value in sample.pcm { smpl.word(UInt16(bitPattern: value)) }
            let end = UInt32(smpl.count / 2)
            // The SF2 format requires at least 46 zero-valued guard sample points.
            smpl.append(Data(repeating: 0, count: 92))
            shdr.fixedName(sample.name)
            shdr.dword(start); shdr.dword(end)
            shdr.dword(start + UInt32(sample.loopEnd == 0 ? 8 : sample.loopStart))
            shdr.dword(sample.loopEnd == 0 ? end - 8 : start + UInt32(sample.loopEnd))
            shdr.dword(sample.rate)
            shdr.append(sample.root); shdr.append(0)
            shdr.word(0); shdr.word(1) // mono sample
        }
        shdr.fixedName("EOS"); shdr.append(Data(repeating: 0, count: 26))

        var phdr = Data()
        for (name, program, bag) in [("Neon Circuit", UInt16(0), UInt16(0)),
                                      ("EOP", UInt16(0), UInt16(1))] {
            phdr.fixedName(name); phdr.word(program); phdr.word(0); phdr.word(bag)
            phdr.append(Data(repeating: 0, count: 12))
        }
        var pbag = Data(), pgen = Data()
        for index in 0...1 { pbag.word(UInt16(index)); pbag.word(0) }
        pgen.word(41); pgen.word(0)
        pgen.word(0); pgen.word(0)

        var inst = Data()
        inst.fixedName("Neon"); inst.word(0)
        inst.fixedName("EOI"); inst.word(UInt16(synth.count))
        var ibag = Data(), igen = Data()
        for zone in synth {
            ibag.word(UInt16(igen.count / 4)); ibag.word(0)
            for (opcode, amount) in zone.generators { igen.word(opcode); igen.word(amount) }
        }
        ibag.word(UInt16(igen.count / 4)); ibag.word(0)
        igen.word(0); igen.word(0)

        var version = Data(); version.word(2); version.word(1)
        let info = list("INFO", [chunk("ifil", version), chunk("isng", Data("EMU8000\0".utf8)),
                                  // SF2 INFO strings require an even chunk size, including NULs.
                                  // Apple's sampler rejects an odd-size INAM despite RIFF padding.
                                  chunk("INAM", Data("RIMES Neon Circuit\0\0".utf8)),
                                  chunk("ICOP", Data("Original synthesized waveforms, RIMES MIT license\0".utf8))])
        let data = list("sdta", [chunk("smpl", smpl)])
        let presets = list("pdta", [chunk("phdr", phdr), chunk("pbag", pbag),
            chunk("pmod", Data(repeating: 0, count: 10)), chunk("pgen", pgen),
            chunk("inst", inst), chunk("ibag", ibag), chunk("imod", Data(repeating: 0, count: 10)),
            chunk("igen", igen), chunk("shdr", shdr)])
        return chunk("RIFF", Data("sfbk".utf8) + info + data + presets)
    }

    private static func chunk(_ id: String, _ body: Data) -> Data {
        var result = Data(id.utf8)
        result.dword(UInt32(body.count)); result.append(body)
        if !body.count.isMultiple(of: 2) { result.append(0) }
        return result
    }

    private static func list(_ kind: String, _ chunks: [Data]) -> Data {
        chunk("LIST", chunks.reduce(Data(kind.utf8), +))
    }
}

private extension Data {
    mutating func word(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func dword(_ value: UInt32) {
        word(UInt16(truncatingIfNeeded: value)); word(UInt16(truncatingIfNeeded: value >> 16))
    }
    mutating func fixedName(_ text: String) {
        let bytes = Array(text.utf8.prefix(19))
        append(contentsOf: bytes); append(Data(repeating: 0, count: 20 - bytes.count))
    }
}
