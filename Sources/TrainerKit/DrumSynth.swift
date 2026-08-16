import Foundation
import GrooveCore

/// Every voice the band plays, rendered once to sample buffers at startup.
///
/// `DrumSynth` is the drum half and keeps its name because that is what it does; the kit is
/// named for the band because it holds whatever the band needs, which from M19 includes pitch.
///
/// Synthesis, not sampled recordings: nothing to license or download, sample-accurate, and
/// tempo-agile (resolves PLAN.md open question #4 by removing it). Each voice is a short
/// one-shot; the player mixes copies of these buffers at scheduled positions, so the render
/// thread never synthesises anything — it only adds pre-rendered samples.
struct BackingKit {
    let sampleRate: Double
    private(set) var buffers: [BackingVoice: [Float]] = [:]
    /// One buffer per bass note. Pre-rendered for the same reason the drums are: the render
    /// callback may not allocate or synthesise (R2.3), so every sound it can be asked for has
    /// to exist before it starts.
    private(set) var bassBuffers: [Int: [Float]] = [:]
    /// One buffer per organ note, for the same reason as the bass.
    private(set) var organBuffers: [Int: [Float]] = [:]

    /// The bass range, E1 to E3. Wide enough for a root and a fifth in any key, and small
    /// enough that pre-rendering it costs a couple of megabytes and a few milliseconds.
    static let bassNotes = 28...52

    /// The organ range, E3 to E5 — two octaves sitting **above** the bass rather than beside it,
    /// which is where a bubble is played and what keeps the two from masking each other.
    static let organNotes = 52...76

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for voice in BackingVoice.allCases where !voice.isPitched {
            buffers[voice] = DrumSynth.render(voice, sampleRate: sampleRate)
        }
        for note in Self.bassNotes {
            bassBuffers[note] = BassSynth.render(note: note, sampleRate: sampleRate)
        }
        for note in Self.organNotes {
            organBuffers[note] = OrganSynth.render(note: note, sampleRate: sampleRate)
        }
    }

    /// The buffer a hit sounds. A pitched voice outside the rendered range is silent rather
    /// than wrong: a note nobody rendered is a programming error, and playing the nearest
    /// pitch instead would put a wrong note in the music without saying so.
    ///
    /// **Switched on the voice, not on `isPitched` alone.** With one pitched voice those were the
    /// same question; with two they are not, and the version that asked only whether a voice was
    /// pitched would have sounded every organ note as a bass note — `LESSONS.md` shape 9, two
    /// quantities equal until the day they are not.
    func buffer(for voice: BackingVoice, note: Int? = nil) -> [Float] {
        guard voice.isPitched else { return buffers[voice] ?? [] }
        guard let note else { return [] }
        switch voice {
        case .bass:  return bassBuffers[note] ?? []
        case .organ: return organBuffers[note] ?? []
        default:     return []
        }
    }

    var maxVoiceLength: Int {
        max(buffers.values.map(\.count).max() ?? 0,
            bassBuffers.values.map(\.count).max() ?? 0,
            organBuffers.values.map(\.count).max() ?? 0)
    }

    // MARK: - Which kit this is

    /// The sample rate the fingerprint is taken at, which is **not** the rate anything is played
    /// at.
    ///
    /// A fingerprint over the buffers the device happens to render would change with the output
    /// device, and two takes played on headphones and speakers would read as two different kits.
    /// Rendering once at a fixed rate makes it a property of the synthesis, which is the question
    /// being asked.
    static let fingerprintSampleRate: Double = 44_100

    /// A short digest of every sound the band can make.
    ///
    /// **The take records which kit it heard**, because a kit change is a backing change and a
    /// backing change is a task change — §7.28's list, and the invariant in `AGENT.md` that a
    /// changed backing once produced a "real" 8 ms spread move that was partly just different
    /// music. Nothing keyed on the kit before this, so the sounds could change under a series
    /// while every take in it kept the same groove name (§7.61).
    ///
    /// **Derived rather than declared**, and that is the whole point. A hand-bumped version number
    /// is a rule nobody is stopped from breaking — `LESSONS.md` shape 21, which this project has
    /// now collected five instances of. A digest over the rendered samples cannot be forgotten:
    /// change a decay constant and it changes, leave the kit alone and it does not.
    ///
    /// **What it does not cover:** the patterns. This answers *"did the sounds change"*, not *"did
    /// the music change"* — a style's steps and velocities are `GrooveCore`'s and are keyed by name
    /// and seed already. The fixed backing's patterns are keyed by neither, which is a gap this
    /// does not close and §7.61 records.
    ///
    /// Computed once per process and only when something asks, since the only caller is `save`.
    static let fingerprint: String = {
        let kit = BackingKit(sampleRate: fingerprintSampleRate)
        var voices: [[Float]] = BackingVoice.allCases
            .sorted { $0.rawValue < $1.rawValue }
            .compactMap { kit.buffers[$0] }
        voices += kit.bassBuffers.keys.sorted().compactMap { kit.bassBuffers[$0] }
        voices += kit.organBuffers.keys.sorted().compactMap { kit.organBuffers[$0] }
        return digest(voices)
    }()

    /// FNV-1a over the raw sample bits, as 12 hex characters.
    ///
    /// Written out rather than reaching for `Hasher`, which is seeded per process: it would give a
    /// different answer every launch, so every take would record a kit nobody else had heard.
    /// Bit patterns rather than rounded values, because the question is whether the synthesis
    /// changed at all and a rounding tolerance would be a judgement about how much change matters.
    static func digest(_ voices: [[Float]]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        for voice in voices {
            // The length is mixed in as well, so a truncated voice and a faded one differ even if
            // every sample they share is identical.
            withUnsafeBytes(of: UInt64(voice.count).littleEndian) { $0.forEach(mix) }
            for sample in voice {
                withUnsafeBytes(of: sample.bitPattern.littleEndian) { $0.forEach(mix) }
            }
        }
        return String(format: "%012llx", hash & 0xffff_ffff_ffff)
    }
}

enum DrumSynth {
    /// Small deterministic noise source so a kit sounds identical every launch.
    private struct Noise {
        var state: UInt64 = 0x243F6A8885A308D3
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }

    /// One-pole low-pass. `y += a·(x − y)`, with `a` set from a cutoff frequency.
    private struct OnePole {
        var y: Float = 0
        let a: Float
        init(cutoff: Double, fs: Double) { a = Float(1 - exp(-2 * .pi * cutoff / fs)) }
        mutating func lowpass(_ x: Float) -> Float { y += a * (x - y); return y }
    }

    /// Band-passed noise: low-pass at `high`, then remove everything below `low`. Gives the
    /// airy metallic hiss of a real cymbal instead of full-spectrum "static."
    private struct BandNoise {
        var noise = Noise()
        var lp: OnePole
        var hp: OnePole
        init(low: Double, high: Double, fs: Double) {
            lp = OnePole(cutoff: high, fs: fs)
            hp = OnePole(cutoff: low, fs: fs)
        }
        mutating func next() -> Float {
            let low = lp.lowpass(noise.next())
            return low - hp.lowpass(low)
        }
    }

    /// Soft saturation for the bass: gentler drive than a drum wants, because the harmonics it
    /// adds are what make a low fundamental audible on a speaker that cannot reproduce it.
    static func saturateBass(_ x: Float) -> Float { saturate(x, drive: 1.8) }

    /// Soft saturation — adds harmonics and density, i.e. punch, while bounding the level.
    private static func saturate(_ x: Float, drive: Float) -> Float {
        tanh(x * drive) / tanh(drive)
    }

    /// Jingles: a dense band of high noise with a fast attack and a rattling tail.
    ///
    /// Distinguished from a closed hat by *length* rather than by brightness — a hat stops dead
    /// and a tambourine keeps ringing for a fifth of a second, which is what makes eighth notes
    /// on it read as a groove rather than as a click.
    private static func tambourine(fs: Double) -> [Float] {
        let count = Int(0.22 * fs)
        var out = [Float](repeating: 0, count: count)
        var band = BandNoise(low: 4_500, high: 11_000, fs: fs)
        for i in 0..<count {
            let t = Double(i) / fs
            // Two decays: the strike, then the jingles settling.
            let env = Float(exp(-t / 0.012) * 0.7 + exp(-t / 0.10) * 0.5)
            out[i] = band.next() * env * 0.75
        }
        return out
    }

    /// A softer, longer rattle with no strike — the sound that fills space without marking it.
    ///
    /// Deliberately *unaccented*: a shaker that could be accented would become a second snare,
    /// and its job is to be the surface a groove sits on.
    private static func shaker(fs: Double) -> [Float] {
        let count = Int(0.13 * fs)
        var out = [Float](repeating: 0, count: count)
        var band = BandNoise(low: 5_000, high: 9_000, fs: fs)
        for i in 0..<count {
            let t = Double(i) / fs
            // Slow attack, so it swells rather than hits. This is the whole character.
            let attack = Float(min(t / 0.012, 1))
            let env = attack * Float(exp(-t / 0.045))
            out[i] = band.next() * env * 0.55
        }
        return out
    }

    /// Two inharmonic partials, hard attack, medium ring. Pitched enough to be a landmark and
    /// clangy enough not to be mistaken for a note.
    private static func cowbell(fs: Double) -> [Float] {
        let count = Int(0.30 * fs)
        var out = [Float](repeating: 0, count: count)
        var p1 = 0.0, p2 = 0.0
        let f1 = 540.0, f2 = 800.0
        for i in 0..<count {
            let t = Double(i) / fs
            let env = exp(-t / 0.09)
            var sample = sin(p1) * 0.6 + sin(p2) * 0.4
            p1 += 2 * .pi * f1 / fs
            p2 += 2 * .pi * f2 / fs
            sample = tanh(sample * 1.6) / tanh(1.6)
            out[i] = Float(sample * env) * 0.5
        }
        return out
    }

    /// The stick on the rim: a short wooden knock with no snare rattle behind it.
    ///
    /// What a drummer plays instead of a backbeat when the music wants quiet, so a style can have
    /// a two and four without the snare dominating everything above it.
    private static func sidestick(fs: Double) -> [Float] {
        let count = Int(0.09 * fs)
        var out = [Float](repeating: 0, count: count)
        var noise = Noise()
        var lp = OnePole(cutoff: 3_200, fs: fs)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / fs
            let env = Float(exp(-t / 0.011))
            let wood = sin(phase) * 0.5
            phase += 2 * .pi * 1_700 / fs
            let click = Double(lp.lowpass(noise.next())) * 0.6
            out[i] = Float(wood + click) * env * 0.6
        }
        return out
    }

    /// Seconds of fade at the end of every one-shot.
    ///
    /// **Two cycles of the lowest note the band can sound**, which is E1 at 41.2 Hz — a period of
    /// 24.3 ms. Shorter and the fade acts inside a fraction of a cycle of the bass fundamental,
    /// which leaves most of the step it exists to remove. The number therefore comes from
    /// `BackingKit.bassNotes.lowerBound` rather than from taste, and it has to move if that does.
    static let fadeSeconds = 0.05
    /// A voice shorter than four fades keeps its character instead: the rimshot is 50 ms long
    /// altogether and truncates at 0.2% of peak, so it needs no help and would be gutted by one.
    static let maximumFadeFraction = 0.25

    /// Every voice, with the last few milliseconds faded out.
    ///
    /// **The buffer used to stop mid-decay and the signal stepped to zero from whatever value it
    /// happened to hold.** A step discontinuity is a broadband impulse, and it landed at a fixed
    /// offset after every hit: the kick at −31.8 dBFS 0.320 s later, which at 100 BPM is 0.53 of a
    /// beat — an audible click sitting just past the offbeat, in every take recorded since M3. The
    /// bass was five times worse still and nobody had measured it, because `render` wrote no file
    /// for a pitched voice. See PLAN.md §7.29 step 6b and §7.31 finding 1.
    ///
    /// Fading rather than lengthening the buffer, because an exponential never reaches zero: the
    /// bass would need 2.4 s to decay to −60 dB, and `BassSynth` wants a note that is over inside
    /// a beat so it reads as a pulse rather than a pad. Making it long enough to stop honestly
    /// would change the music, which is the one thing a fix here may not do.
    ///
    /// **Raised cosine, not linear.** A linear fade leaves a corner in the first derivative where
    /// it begins — a weaker discontinuity than the one being removed, but the same kind. This one
    /// is flat at both ends, so nothing steps anywhere.
    static func fadedOut(_ buffer: [Float], sampleRate fs: Double) -> [Float] {
        let fade = min(Int(fadeSeconds * fs), Int(Double(buffer.count) * maximumFadeFraction))
        guard fade > 1 else { return buffer }
        var out = buffer
        let first = buffer.count - fade
        for i in first..<buffer.count {
            let t = Double(i - first) / Double(fade - 1)
            out[i] *= Float(0.5 * (1 + cos(.pi * t)))
        }
        return out
    }

    static func render(_ voice: BackingVoice, sampleRate fs: Double) -> [Float] {
        fadedOut(raw(voice, sampleRate: fs), sampleRate: fs)
    }

    /// The voice before its release fade. Private, so there is no way to obtain a buffer that
    /// still truncates — the defect this file exists to have fixed was one call site away from
    /// coming back the moment somebody added a synthesiser.
    private static func raw(_ voice: BackingVoice, sampleRate fs: Double) -> [Float] {
        switch voice {
        case .kick:      return kick(fs: fs)
        case .snare:     return snare(fs: fs)
        case .closedHat: return hat(fs: fs, decay: 0.045)
        case .openHat:   return hat(fs: fs, decay: 0.30)
        case .clap:      return clap(fs: fs)
        case .rimshot:   return rimshot(fs: fs)
        case .tom:       return tom(fs: fs)
        case .crash:     return crash(fs: fs)
        case .ride:      return ride(fs: fs)
        case .tambourine: return tambourine(fs: fs)
        case .shaker:    return shaker(fs: fs)
        case .cowbell:   return cowbell(fs: fs)
        case .sidestick: return sidestick(fs: fs)
        // Pitched, so they have no single buffer — `BackingKit` renders one per note through
        // `BassSynth` and `OrganSynth`. Returning empty here rather than trapping keeps a stray
        // pitched voice in a drum-only context silent instead of fatal.
        case .bass, .organ: return []
        }
    }

    // MARK: - Voices

    /// Pitch-swept sine body, a short click transient for attack, and soft saturation for
    /// density — the three ingredients of a punchy kick. The click gives the beater's
    /// snap, the faster sweep gives the "thump," and saturation thickens the whole thing.
    private static func kick(fs: Double) -> [Float] {
        let n = Int(0.32 * fs)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        var clickNoise = Noise()
        var clickHP = OnePole(cutoff: 1500, fs: fs)
        for i in 0..<n {
            let t = Double(i) / fs
            let freq = 45 + 140 * exp(-t / 0.024)          // snappier sweep, 185 → 45 Hz
            phase += 2 * .pi * freq / fs
            let body = Float(sin(phase) * exp(-t / 0.10))

            // A few ms of high-passed noise: the beater attack that reads as punch.
            let raw = clickNoise.next()
            let click = (raw - clickHP.lowpass(raw)) * Float(exp(-t / 0.0025))

            out[i] = saturate(body * 0.95 + click * 0.6, drive: 1.5) * 0.85
        }
        return out
    }

    /// Two tonal partials plus a decaying noise burst — the snare body and its snares.
    private static func snare(fs: Double) -> [Float] {
        let n = Int(0.20 * fs)
        var out = [Float](repeating: 0, count: n)
        var noise = Noise()
        for i in 0..<n {
            let t = Double(i) / fs
            let tone = (sin(2 * .pi * 180 * t) + 0.6 * sin(2 * .pi * 330 * t)) * exp(-t / 0.06)
            let hiss = Double(noise.next()) * exp(-t / 0.09)
            out[i] = Float(0.45 * tone + 0.6 * hiss) * 0.7
        }
        return out
    }

    /// A bank of inharmonic high partials plus band-passed noise — the 808-style metallic
    /// "tss," which reads as a hi-hat rather than the radio static a plain high-passed
    /// noise burst gives. Closed vs open is just the decay time.
    private static func hat(fs: Double, decay: Double) -> [Float] {
        let n = Int((decay * 4) * fs)
        var out = [Float](repeating: 0, count: n)
        // Inharmonic ratios keep the tone bank metallic instead of pitched.
        let partials = [6200.0, 7300, 8600, 9700, 11400]
        var band = BandNoise(low: 6000, high: 12000, fs: fs)
        for i in 0..<n {
            let t = Double(i) / fs
            var tone = 0.0
            for f in partials { tone += sin(2 * .pi * f * t) }
            tone /= Double(partials.count)
            let env = Float(exp(-t / decay))
            out[i] = (Float(tone) * 0.6 + band.next() * 0.5) * env * 0.7
        }
        return out
    }

    private static func clap(fs: Double) -> [Float] {
        let n = Int(0.18 * fs)
        var out = [Float](repeating: 0, count: n)
        var noise = Noise()
        var prev: Float = 0
        // Three quick bursts then a short tail — the classic clap smear.
        let bursts = [0.0, 0.010, 0.020]
        for i in 0..<n {
            let t = Double(i) / fs
            var env = exp(-max(0, t - 0.030) / 0.05)
            for b in bursts where t >= b && t < b + 0.008 { env = max(env, 1.0) }
            let white = noise.next()
            let hp = white - prev; prev = white
            out[i] = hp * Float(env) * 0.5
        }
        return out
    }

    private static func rimshot(fs: Double) -> [Float] {
        let n = Int(0.05 * fs)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let tone = sin(2 * .pi * 1700 * t) + 0.5 * sin(2 * .pi * 500 * t)
            out[i] = Float(tone * exp(-t / 0.008)) * 0.6
        }
        return out
    }

    private static func tom(fs: Double) -> [Float] {
        let n = Int(0.30 * fs)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            let freq = 120 + 90 * exp(-t / 0.05)
            phase += 2 * .pi * freq / fs
            out[i] = Float(sin(phase) * exp(-t / 0.14)) * 0.7
        }
        return out
    }

    private static func crash(fs: Double) -> [Float] {
        let n = Int(1.4 * fs)
        var out = [Float](repeating: 0, count: n)
        var noise = Noise()
        var prev: Float = 0
        for i in 0..<n {
            let t = Double(i) / fs
            let white = noise.next()
            let hp = white - 0.5 * prev; prev = white
            out[i] = hp * Float(exp(-t / 0.6)) * 0.4
        }
        return out
    }

    /// A bright metallic "ting": a stick-click attack, a bank of bright inharmonic partials,
    /// and only a touch of quickly-decaying shimmer.
    ///
    /// Two earlier versions missed in opposite directions — pure sines with a long ring
    /// (a bell), then a low-partial noise wash (wooden, and it piled up into static when
    /// played as 8th notes because each wash outlasted the gap to the next hit). This keeps
    /// the tonal ping in charge but bright and inharmonic so it reads as a cymbal, and keeps
    /// every decay shorter than an eighth note so a ride pattern stays articulate.
    private static func ride(fs: Double) -> [Float] {
        let n = Int(0.4 * fs)
        var out = [Float](repeating: 0, count: n)
        // Bright, inharmonic — a metallic ting, not a low knock and not a single pitch.
        let partials = [2760.0, 3700, 4560, 5800, 7300]
        var shimmer = BandNoise(low: 5000, high: 11000, fs: fs)
        var stick = Noise()
        var stickHP = OnePole(cutoff: 3000, fs: fs)
        for i in 0..<n {
            let t = Double(i) / fs
            var ping = 0.0
            for f in partials { ping += sin(2 * .pi * f * t) }
            ping = ping / Double(partials.count) * exp(-t / 0.13)

            let raw = stick.next()
            let click = (raw - stickHP.lowpass(raw)) * Float(exp(-t / 0.003))  // stick attack
            let wash = shimmer.next() * Float(exp(-t / 0.09))                  // short, subtle

            out[i] = (Float(ping) * 0.55 + click * 0.2 + wash * 0.22) * 0.5
        }
        return out
    }
}
