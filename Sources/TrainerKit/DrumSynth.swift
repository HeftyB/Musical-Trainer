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

    /// Which kit this is, as numbers. `.standard` is the one every take on record heard.
    let spec: KitSpec

    /// Every unpitched voice at every velocity layer, softest first.
    ///
    /// **A drum hit harder is not the same sound louder** (§7.30 item 1, §7.63). One buffer scaled
    /// by gain is why a ghost snare and a backbeat read as one instrument at two fader positions.
    private(set) var layered: [BackingVoice: [[Float]]] = [:]

    /// The nominal layer of each voice — the sound this kit has always made.
    var buffers: [BackingVoice: [Float]] { layered.mapValues { $0[Self.nominalLayer] } }
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

    /// How hard each layer is struck, softest first.
    ///
    /// **The boundaries come from what the styles actually write**, not from a tidy split. The
    /// patterns use velocities from 40 to 108, clustered hard at 100 — 40–60 for ghost notes and
    /// quiet timekeeper steps, 80–100 for everything that marks the beat. Four layers cover that
    /// spread with the ghosts genuinely on their own; three would have put 40 and 76 together, and
    /// the gap between those two is the whole point of the milestone.
    static let layerStrengths: [Double] = [0.30, 0.55, DrumSynth.nominalStrength, 1.0]

    /// The highest velocity each layer covers.
    ///
    /// **Velocity 100 lands on the nominal layer**, which is what keeps a backbeat sounding exactly
    /// as it has for thirty takes: same buffer, same gain, same sample.
    static let layerCeilings: [Int] = [55, 79, 103, 127]

    /// The layer whose buffer is the one this kit has always rendered.
    static let nominalLayer = 2

    /// Which layer a velocity plays on. Out-of-range velocities clamp rather than trap.
    static func layer(forVelocity velocity: Int) -> Int {
        layerCeilings.firstIndex { velocity <= $0 } ?? layerCeilings.count - 1
    }

    init(sampleRate: Double, spec: KitSpec = .standard) {
        self.sampleRate = sampleRate
        self.spec = spec
        for voice in BackingVoice.allCases where !voice.isPitched {
            layered[voice] = DrumSynth.renderLayers(voice, sampleRate: sampleRate,
                                                    strengths: Self.layerStrengths, spec: spec)
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
    /// - Parameter velocity: how hard the hit is, which selects the layer. A pitched voice ignores
    ///   it — the bass and organ are not layered, and §7.63 says why that is a gap rather than a
    ///   decision.
    func buffer(for voice: BackingVoice, note: Int? = nil, velocity: Int = 100) -> [Float] {
        guard voice.isPitched else {
            return layered[voice]?[Self.layer(forVelocity: velocity)] ?? []
        }
        guard let note else { return [] }
        switch voice {
        case .bass:  return bassBuffers[note] ?? []
        case .organ: return organBuffers[note] ?? []
        default:     return []
        }
    }

    var maxVoiceLength: Int {
        max(layered.values.flatMap { $0 }.map(\.count).max() ?? 0,
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
    static let fingerprint: String = fingerprint(of: .standard)

    /// The digest of a kit built to this spec.
    ///
    /// **Per spec, because a style may now carry its own kit** (§7.67). A take records the
    /// fingerprint of the kit it actually heard, so two styles with different drums group apart on
    /// the kit axis as well as the backing one — and a style given its own kit later cannot silently
    /// pool with the takes played before it had one.
    ///
    /// Cached, since a session plays one style at a time and `save` asks once per take.
    static func fingerprint(of spec: KitSpec) -> String {
        if let hit = fingerprintCache[spec] { return hit }
        let value = computeFingerprint(of: spec)
        fingerprintCache[spec] = value
        return value
    }

    private static var fingerprintCache: [KitSpec: String] = [:]

    private static func computeFingerprint(of spec: KitSpec) -> String {
        let kit = BackingKit(sampleRate: fingerprintSampleRate, spec: spec)
        // **Every layer, not just the nominal one.** They are all sounds the band can make, so a
        // kit whose ghost layer changed while its backbeat did not is still a different kit.
        var voices: [[Float]] = BackingVoice.allCases
            .sorted { $0.rawValue < $1.rawValue }
            .flatMap { kit.layered[$0] ?? [] }
        voices += kit.bassBuffers.keys.sorted().compactMap { kit.bassBuffers[$0] }
        voices += kit.organBuffers.keys.sorted().compactMap { kit.organBuffers[$0] }
        return digest(voices)
    }

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
    /// Strength moves the strike against the jingles: hit hard it is a crack that then rattles,
    /// played softly it is nearly all rattle.
    private static func tambourine(fs: Double, strength: Double) -> [Float] {
        let strike = tilt(strength, soft: 0.45, hard: 1.35)
        let count = Int(0.22 * fs)
        var out = [Float](repeating: 0, count: count)
        var band = BandNoise(low: 4_500, high: 11_000, fs: fs)
        for i in 0..<count {
            let t = Double(i) / fs
            // Two decays: the strike, then the jingles settling.
            let env = Float(exp(-t / 0.012) * 0.7 * strike + exp(-t / 0.10) * 0.5)
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
    /// Harder is louder and more clangorous — the saturation opens up and it rings longer.
    private static func cowbell(fs: Double, strength: Double) -> [Float] {
        // Kept in `Double` and written out rather than routed through `saturate`, which works in
        // `Float`: the round trip moved the nominal buffer and the kit fingerprint with it.
        let drive = 1.6 * tilt(strength, soft: 0.75, hard: 1.30)
        let ring = tilt(strength, soft: 0.70, hard: 1.15)
        let count = Int(0.30 * fs)
        var out = [Float](repeating: 0, count: count)
        var p1 = 0.0, p2 = 0.0
        let f1 = 540.0, f2 = 800.0
        for i in 0..<count {
            let t = Double(i) / fs
            let env = exp(-t / (0.09 * ring))
            var sample = sin(p1) * 0.6 + sin(p2) * 0.4
            p1 += 2 * .pi * f1 / fs
            p2 += 2 * .pi * f2 / fs
            sample = tanh(sample * drive) / tanh(drive)
            out[i] = Float(sample * env) * 0.5
        }
        return out
    }

    /// The stick on the rim: a short wooden knock with no snare rattle behind it.
    ///
    /// What a drummer plays instead of a backbeat when the music wants quiet, so a style can have
    /// a two and four without the snare dominating everything above it.
    /// The quiet articulation, so its range is narrow by design: a sidestick played hard is a
    /// rimshot, and the style picks that voice instead.
    private static func sidestick(fs: Double, strength: Double) -> [Float] {
        let ring = tilt(strength, soft: 0.75, hard: 1.15)
        let count = Int(0.09 * fs)
        var out = [Float](repeating: 0, count: count)
        var noise = Noise()
        var lp = OnePole(cutoff: 3_200, fs: fs)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / fs
            let env = Float(exp(-t / (0.011 * ring)))
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
    /// for a pitched voice. See JOURNAL.md §7.29 step 6b and §7.31 finding 1.
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


    // MARK: - How hard the hit is

    /// The strength a hit is rendered at, 0…1.
    ///
    /// **A drum hit harder is not the same sound louder** — the spectrum shifts, the attack
    /// sharpens, the decay lengthens. One buffer scaled by gain is why a ghost snare at velocity 34
    /// and a backbeat at 100 read as the same instrument at two fader positions, which §7.30 calls
    /// the single largest gap between this kit and a genre.
    ///
    /// **`nominal` renders every buffer this kit has always rendered, sample for sample.** Every
    /// strength-dependent term goes through `tilt`, which is exactly 1 there, so the layer a
    /// backbeat plays on is the sound the project has thirty takes over. What changes is what
    /// happens above and below it.
    /// Voices that do not respond to strength at all.
    ///
    /// **One place says so, and both halves read it.** `raw` ignored strength for the shaker while
    /// `render` darkened it anyway, so the voice documented as unaccentable was the one whose timbre
    /// moved most per unit of velocity — measured at 0.51 of its own centroid (§7.64). A rule
    /// spelled in one of two places is `LESSONS.md` shape 21 again, inside a single file this time.
    ///
    /// The shaker's own comment carries the argument: *"a shaker that could be accented would become
    /// a second snare"*. Its job is to be the surface a groove sits on.
    static let unaccented: Set<BackingVoice> = [.shaker]

    static let nominalStrength = 0.75

    /// A multiplier that is exactly 1 at `nominalStrength`, `soft` at 0 and `hard` at 1.
    ///
    /// Piecewise-linear through the nominal point rather than a single ramp, because the nominal
    /// buffer has to come out bit-identical and a ramp fitted to the endpoints would miss it by a
    /// rounding error — which would change every take's backing for no reason anybody chose.
    static func tilt(_ strength: Double, soft: Double, hard: Double) -> Double {
        let n = nominalStrength
        // **Exactly 1 at nominal, by returning it rather than computing it.** The algebra says
        // `soft + (1 - soft) · 1` is 1, and in binary floating point it is not: at `soft = 0.3`
        // it comes out 0.9999999999999999, which would move every nominal sample by a hair and
        // with it the kit fingerprint — re-scoring the backing of 104 takes to no purpose.
        if strength == n { return 1 }
        if strength < n { return soft + (1 - soft) * (strength / n) }
        return 1 + (hard - 1) * ((strength - n) / (1 - n))
    }

    /// Total energy in a buffer — how much sound is actually there, as opposed to how loud its
    /// loudest sample is. Two layers peak-matched by `matchingPeak` still differ by this.
    static func energy(of buffer: [Float]) -> Double {
        buffer.reduce(0) { $0 + Double($1) * Double($1) }
    }

    /// Spectral centroid in Hz — where the energy sits, which is what an ear calls brightness.
    ///
    /// **The quantity a velocity layer is supposed to move**, and the one nothing measured until
    /// §7.64: the first pass varied balances and decays, asserted the buffers differed, and shipped
    /// a difference too small to hear. A test that a value *changed* cannot protect a value changing
    /// *enough* (`LESSONS.md` shape 18's family).
    ///
    /// Goertzel over a coarse log-spaced band set rather than a full FFT: this runs in tests and in
    /// no audio path, and the question is a ratio between two layers rather than a spectrum.
    ///
    /// **It is not trustworthy for narrowband content, and that matters here.** The probes are spaced
    /// 1.25× apart with no window, so a pure sine landing between two of them reads far weaker than
    /// the same sine landing on one. Fine for the noise-bearing voices this compares, wrong for a
    /// tonal one: §7.67 measured the snare's centroid *fall* threefold when its partials were tuned
    /// **up**, because they moved nearer a probe. Use `power(of:atHz:)` when the frequency is known.
    ///
    /// `darkened` reads this to set its corner, and that is acceptable for the same reason: it needs
    /// the voice's rough register, not its spectrum, and whatever it reads it reads consistently.
    static func centroid(of buffer: [Float], sampleRate fs: Double) -> Double {
        guard !buffer.isEmpty else { return 0 }
        var weighted = 0.0, total = 0.0
        var f = 100.0
        while f < min(16_000, fs / 2) {
            let w = 2 * Double.pi * f / fs
            let coeff = 2 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for sample in buffer {
                let s0 = Double(sample) + coeff * s1 - s2
                s2 = s1
                s1 = s0
            }
            let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
            weighted += f * power
            total += power
            f *= 1.25
        }
        return total > 0 ? weighted / total : 0
    }

    /// Power at one known frequency, by Goertzel.
    ///
    /// **Reliable where `centroid` is not.** A single-bin evaluation is exact for a component you
    /// already know the frequency of, and misleading for one you do not: `centroid` probes a
    /// log-spaced ladder and a pure sine landing between two probes reads far weaker than one landing
    /// on a probe. That is why raising the snare's tuning appeared to *lower* its centroid by a
    /// factor of three (§7.67) — the partials moved nearer a probe, not lower.
    ///
    /// So a test asking "did the tonal partials move" asks here, where the answer does not depend on
    /// where the ladder happens to fall.
    static func power(of buffer: [Float], atHz frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * frequency / fs
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for sample in buffer {
            let s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2
    }

    /// The share of a buffer's energy sitting above `hz`, 0…1.
    ///
    /// **The measure to reach for with modal content**, where `centroid` is unreliable: a bank of
    /// discrete modes may fall between its probe frequencies and read far darker than it is (§7.67,
    /// §7.70). A filter does not care where the energy sits inside the band, only how much of it
    /// there is, so it answers "is this bright" without needing to know where the modes are.
    ///
    /// Two one-pole sections, which is a gentle 12 dB/octave slope rather than a brick wall — good
    /// enough to compare two versions of the same voice, and not a spectrum analyser.
    static func energyAbove(_ hz: Double, of buffer: [Float], sampleRate fs: Double) -> Double {
        guard !buffer.isEmpty else { return 0 }
        var lowA = OnePole(cutoff: hz, fs: fs)
        var lowB = OnePole(cutoff: hz, fs: fs)
        var high = 0.0, all = 0.0
        for sample in buffer {
            // Subtracting a low-pass from the signal leaves the high-pass.
            let low = lowB.lowpass(lowA.lowpass(sample))
            let above = Double(sample - low)
            high += above * above
            all += Double(sample) * Double(sample)
        }
        return all > 0 ? high / all : 0
    }

    /// How long the voice stays within 20 dB of its own peak, in seconds — its audible length.
    static func durationSeconds(of buffer: [Float], sampleRate fs: Double) -> Double {
        guard let peak = buffer.map(abs).max(), peak > 0 else { return 0 }
        let floor = peak * 0.1
        let last = buffer.lastIndex { abs($0) >= floor } ?? 0
        return Double(last) / fs
    }

    /// Darken a layer struck softer than nominal.
    ///
    /// **The missing ingredient, and why the first pass was inaudible** (§7.64). A softer strike
    /// excites fewer high modes — most of what an ear calls a soft hit — and shifting the balance
    /// between components that are *already there* cannot express that. Measured, the first pass
    /// moved the closed hat's spectral centroid by 2% and the ride's by 2%, and the hat's in the
    /// wrong direction. Reasoned to and wrong: `LESSONS.md` shape 11.
    ///
    /// **Cutoff is relative to the voice's own centroid**, not absolute. One absolute corner cannot
    /// serve a kick sitting at 128 Hz and a hat at 6.4 kHz: it annihilates one or misses the other.
    /// Scaling by where the voice already lives darkens each by the same proportion of its own
    /// spectrum.
    ///
    /// Two poles rather than one, because 6 dB/octave is barely audible as a timbre change at these
    /// ratios. Nominal is skipped outright rather than filtered at Nyquist, so the layer 104 takes
    /// were played over stays bit-identical.
    static func darkened(_ buffer: [Float], strength: Double, sampleRate fs: Double) -> [Float] {
        guard strength < nominalStrength, !buffer.isEmpty else { return buffer }
        let centre = centroid(of: buffer, sampleRate: fs)
        guard centre > 0 else { return buffer }

        let cutoff = min(centre * tilt(strength, soft: 0.35, hard: 1), fs / 2 - 1)
        var a = OnePole(cutoff: cutoff, fs: fs)
        var b = OnePole(cutoff: cutoff, fs: fs)
        return buffer.map { b.lowpass(a.lowpass($0)) }
    }

    /// Cap a layer at the nominal layer's peak — never lift it to meet one.
    ///
    /// **Matching was wrong and the measurement said so.** Darkening a soft layer lowers its peak,
    /// and scaling it back up returned *more* total energy than the backbeat had: the ghost snare
    /// measured 198 against the nominal 209, and the ghost kick 1508 against 1349. A quiet stroke
    /// that carries more energy than a loud one is not a quiet stroke.
    ///
    /// Capping keeps the whole reason matching existed — `selftest` checks the mix stays off the
    /// rails, and nothing here is ever hotter than what already shipped — while letting a soft layer
    /// be naturally quieter, which is what makes the velocity gain and the timbre pull in the same
    /// direction instead of against each other.
    static func peakCapped(_ layer: [Float], to reference: [Float]) -> [Float] {
        let peak = layer.map(abs).max() ?? 0
        let ceiling = reference.map(abs).max() ?? 0
        guard peak > ceiling, ceiling > 0 else { return layer }
        return layer.map { $0 * (ceiling / peak) }
    }

    /// One voice at one strength: struck, coloured, put in the room, faded, and capped against the
    /// nominal layer.
    ///
    /// **The order is not arbitrary.** Darkening is a property of the *strike* and belongs on the dry
    /// voice, before it reaches the walls — filtering the room's return instead would darken the
    /// reflections of a hard hit as though the room itself changed with velocity. The fade comes
    /// after the room, because the room is now what ends last and a tail that truncates is the same
    /// step discontinuity §7.31 removed from the voices, one level further out.
    static func render(_ voice: BackingVoice, sampleRate fs: Double,
                       strength: Double = nominalStrength,
                       spec: KitSpec = .standard) -> [Float] {
        renderLayers(voice, sampleRate: fs, strengths: [strength], spec: spec)[0]
    }

    /// Every requested layer of one voice, with the nominal reference built once.
    ///
    /// **Rendering a layer used to build its own reference**, which meant the nominal voice — room,
    /// filters and all — was synthesised again for every layer of every voice. Harmless while the
    /// chain was cheap; once the room arrived it took `swift test` from 145 seconds to 421, because
    /// the gate constructs a kit in a dozen tests. Same output, half the work.
    static func renderLayers(_ voice: BackingVoice, sampleRate fs: Double,
                             strengths: [Double], spec: KitSpec = .standard) -> [[Float]] {
        let reference = voiced(voice, sampleRate: fs, strength: nominalStrength, spec: spec)

        // **A kit's tuning must not change how loud it is**, which is the same rule as strength
        // carrying timbre while loudness stays velocity's job (§7.64). Tuning a kick tighter raises
        // its peak for the same energy, so a tuned kit mixed hotter than the one that shipped: at
        // `driving`'s first numbers the mix reached 0.96 of full scale (§7.68). Capping every kit
        // against the *standard* kit's peaks makes headroom a property of the mix rather than of
        // whatever numbers a style happens to carry.
        //
        // For `.standard` the ceiling is the reference itself, so nothing is scaled and the kit 104
        // takes heard stays bit-identical.
        let ceiling = spec == .standard
            ? reference
            : voiced(voice, sampleRate: fs, strength: nominalStrength, spec: .standard)

        return strengths.map { strength in
            let force = unaccented.contains(voice) ? nominalStrength : strength
            let layer = force == nominalStrength
                ? reference
                : voiced(voice, sampleRate: fs, strength: force, spec: spec)
            return peakCapped(layer, to: ceiling)
        }
    }

    /// The whole chain bar the cap. One function, because the cap compares a layer against the
    /// nominal one and the two have to have travelled the same path — a reference computed without
    /// the room would cap every layer against a quieter signal than it is actually being compared to.
    private static func voiced(_ voice: BackingVoice, sampleRate fs: Double,
                               strength: Double, spec: KitSpec) -> [Float] {
        let struck = darkened(raw(voice, sampleRate: fs, strength: strength, spec: spec),
                              strength: strength, sampleRate: fs)
        return fadedOut(Room.applied(to: struck, sampleRate: fs, amount: spec.roomAmount),
                        sampleRate: fs)
    }

    /// The voice before its release fade. Private, so there is no way to obtain a buffer that
    /// still truncates — the defect this file exists to have fixed was one call site away from
    /// coming back the moment somebody added a synthesiser.
    private static func raw(_ voice: BackingVoice, sampleRate fs: Double,
                            strength v: Double, spec: KitSpec = .standard) -> [Float] {
        switch voice {
        case .kick:      return kick(fs: fs, strength: v, spec: spec)
        case .snare:     return snare(fs: fs, strength: v, spec: spec)
        case .closedHat: return hat(fs: fs, decay: 0.045, strength: v, spec: spec)
        case .openHat:   return hat(fs: fs, decay: 0.30, strength: v, spec: spec)
        case .clap:      return clap(fs: fs, strength: v)
        case .rimshot:   return rimshot(fs: fs, strength: v)
        case .tom:       return tom(fs: fs, strength: v)
        case .crash:     return crash(fs: fs, strength: v, spec: spec)
        case .ride:      return ride(fs: fs, strength: v, spec: spec)
        case .tambourine: return tambourine(fs: fs, strength: v)
        // Strength never reaches here for it — see `unaccented`.
        case .shaker:    return shaker(fs: fs)
        case .cowbell:   return cowbell(fs: fs, strength: v)
        case .sidestick: return sidestick(fs: fs, strength: v)
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
    ///
    /// **Strength moves the beater, the sweep and the length.** A hard kick is mostly beater —
    /// the click is what a listener hears as attack, and it grows far faster than the body does.
    /// The pitch sweep starts higher, and the body rings longer.
    private static func kick(fs: Double, strength: Double, spec: KitSpec) -> [Float] {
        let n = Int(0.32 * fs)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        var clickNoise = Noise()
        var clickHP = OnePole(cutoff: 1500, fs: fs)
        let click = tilt(strength, soft: 0.08, hard: 1.80)
        let sweep = tilt(strength, soft: 0.40, hard: 1.30)
        let ring = tilt(strength, soft: 0.45, hard: 1.25)
        for i in 0..<n {
            let t = Double(i) / fs
            // `spec` multiplies by exactly 1 for the standard kit, and a Double times 1 is exact —
            // which is what keeps the kit 104 takes heard bit-identical without a branch.
            let freq = (45 + 140 * sweep * exp(-t / 0.024)) * spec.kickTuning
            phase += 2 * .pi * freq / fs
            let body = Float(sin(phase) * exp(-t / (0.10 * ring * spec.kickDecay)))

            // A few ms of high-passed noise: the beater attack that reads as punch.
            let raw = clickNoise.next()
            let beater = (raw - clickHP.lowpass(raw)) * Float(exp(-t / 0.0025))

            out[i] = saturate(body * 0.95 + beater * Float(0.6 * click), drive: 1.5) * 0.85
        }
        return out
    }

    /// Two tonal partials plus a decaying noise burst — the snare body and its snares.
    ///
    /// **This is the voice §7.30 names**: *"a ghost snare at velocity 34 and a backbeat at 100 are
    /// different instruments"*. Strength moves the balance between them. A hard hit throws the
    /// snares hard and the rattle dominates; a ghost note barely engages them and what is left is
    /// the head — more tone, less hiss, and over much sooner.
    private static func snare(fs: Double, strength: Double, spec: KitSpec) -> [Float] {
        let n = Int(0.20 * fs)
        var out = [Float](repeating: 0, count: n)
        var noise = Noise()
        let rattle = tilt(strength, soft: 0.45, hard: 1.30)
        let head = tilt(strength, soft: 1.35, hard: 0.88)
        let ring = tilt(strength, soft: 0.3, hard: 1.3)
        for i in 0..<n {
            let t = Double(i) / fs
            let tone = (sin(2 * .pi * 180 * spec.snareTuning * t)
                        + 0.6 * sin(2 * .pi * 330 * spec.snareTuning * t))
                     * exp(-t / (0.06 * ring * spec.snareDecay))
            let hiss = Double(noise.next()) * spec.snareRattle * exp(-t / (0.09 * ring * spec.snareDecay))
            out[i] = Float(0.45 * head * tone + 0.6 * rattle * hiss) * 0.7
        }
        return out
    }

    /// The hi-hat, as a small stiff plate. See `CymbalSynth` for what every number here does and
    /// what to listen for.
    ///
    /// **Closed and open are one cymbal with two decay times**, which is exactly what they are: the
    /// same pair of plates, held together or let go. Everything else about them is identical.
    ///
    /// Small and stiff, so its lowest mode is high — a 14-inch hat sits far above a 20-inch ride —
    /// and it is struck with the tip, so the strike favours the high modes (`excitationTilt` below
    /// zero). `damping` is high because a hat's tail is very short and goes dull almost at once.
    private static func hat(fs: Double, decay: Double, strength: Double, spec: KitSpec) -> [Float] {
        let plate = cymbal(lowestModeHz: 180, modeCount: 60, stretch: 1.0, inharmonicity: 0.32,
                           decaySeconds: decay * 2.2, damping: 0.50, baseTilt: -0.10,
                           strikeSeconds: 0.0012, strikeNoise: 0.06, level: 0.62,
                           shimmerLevel: 0.42, shimmerDecayFraction: 0.35, shimmerFromHz: 2_600,
                           shimmerRiseSeconds: 0,
                           ping: (hz: 0, level: 0, decayFraction: 0),
                           strength: strength, spec: spec)
        return CymbalSynth.render(plate, seconds: max(decay * 6, 0.20), sampleRate: fs)
    }

    /// The ride, as a large plate struck on the bow.
    ///
    /// **The ping is the point.** A ride has to give a clear articulation on every stroke or a
    /// pattern on it turns to soup, and that comes from a few strong low modes rather than from a
    /// bright attack — so its `excitationTilt` is *positive*, favouring the low end, where the hat's
    /// is negative. It rings far longer than a hat and darkens more slowly.
    ///
    /// Two earlier versions missed in opposite directions: pure sines with a long ring (a bell), then
    /// a low-partial noise wash (wooden, and it piled into static as eighth notes). Modal synthesis
    /// gets both halves at once, because the ping and the wash are the same modes at different rates.
    /// The ride's lowest mode, in Hz.
    ///
    /// **Exposed so a test can ask about it rather than hardcode it.** Every listening pass moved
    /// this number — 285, 175, 90, 150 — and a test naming the frequency went stale three times in
    /// two days (§7.73). A guard that has to be edited whenever the thing it guards is legitimately
    /// tuned stops being read and starts being updated reflexively.
    static let rideLowestModeHz = 150.0

    private static func ride(fs: Double, strength: Double, spec: KitSpec) -> [Float] {
        let plate = cymbal(lowestModeHz: rideLowestModeHz, modeCount: 92, stretch: 1.0,
                           inharmonicity: 0.30,
                           decaySeconds: 3.4, damping: 0.44, baseTilt: 0.06,
                           strikeSeconds: 0.0016, strikeNoise: 0.03, level: 0.42,
                           // **A ride is a ping with a wash behind it, not a small crash.** Raising
                           // the shimmer and giving it a bloom last pass made it "a diet crash…
                           // missing the 'ting' and too much 'tshhh'" (§7.74). The wash comes back
                           // down and gets out of the way; the ping goes up and is allowed to ring
                           // long enough to be an articulation you can follow.
                           shimmerLevel: 0.14, shimmerDecayFraction: 0.13, shimmerFromHz: 3_000,
                           // No bloom: a ride's brightest instant is the stick on the bow. Blooming
                           // is what a crash does, and it is what made this one sound like one.
                           shimmerRiseSeconds: 0,
                           // Higher and longer on the verdict: a ride's ting sits well above where
                           // this started, and it has to hang on rather than tick. 1,800 Hz for
                           // 0.75 s — still three detuned resonators, which is what keeps it a ting
                           // and not the cowbell a single pure tone made at 620 Hz (§7.72).
                           ping: (hz: 1_800, level: 0.62, decayFraction: 0.22),
                           strength: strength, spec: spec)
        return CymbalSynth.render(plate, seconds: 2.6, sampleRate: fs)
    }

    /// The crash: the largest plate, the longest ring, the densest wash.
    ///
    /// **This was the crudest voice in the kit** — high-passed noise times one exponential, with no
    /// modes at all, asked to sound like the biggest piece of metal on the stand (§7.69). The player
    /// named the cymbals as the weakest thing he heard, and this is why.
    ///
    /// Low, dense and slow to darken: `damping` is the lowest here, so the wash sustains its colour
    /// rather than collapsing to a dull hum, and `modeCount` is the highest so nothing in it is
    /// separable by ear.
    private static func crash(fs: Double, strength: Double, spec: KitSpec) -> [Float] {
        let plate = cymbal(lowestModeHz: 48, modeCount: 130, stretch: 1.0, inharmonicity: 0.36,
                           decaySeconds: 4.2, damping: 0.34, baseTilt: -0.22,
                           strikeSeconds: 0.0035, strikeNoise: 0.04, level: 0.55,
                           shimmerLevel: 0.78, shimmerDecayFraction: 0.55, shimmerFromHz: 800,
                           shimmerRiseSeconds: 0.130,
                           ping: (hz: 0, level: 0, decayFraction: 0),
                           strength: strength, spec: spec)
        return CymbalSynth.render(plate, seconds: 3.8, sampleRate: fs)
    }

    /// One place where a cymbal's written description, the player's strength and the style's kit are
    /// combined into a plate.
    ///
    /// **Strength reaches the plate rather than the finished buffer**, which is the point of building
    /// them this way. A harder strike genuinely excites the high modes more — fact 3 in
    /// `CymbalSynth` — so tilting the excitation is the same operation the physics performs, where
    /// §7.64's low-pass on a rendered buffer was an approximation of it from outside.
    private static func cymbal(lowestModeHz: Double, modeCount: Int, stretch: Double,
                               inharmonicity: Double, decaySeconds: Double, damping: Double,
                               baseTilt: Double, strikeSeconds: Double, strikeNoise: Double,
                               level: Double, shimmerLevel: Double, shimmerDecayFraction: Double,
                               shimmerFromHz: Double, shimmerRiseSeconds: Double,
                               ping: (hz: Double, level: Double, decayFraction: Double),
                               strength: Double, spec: KitSpec) -> CymbalSynth.Plate {
        // Harder is brighter and longer. `tilt` falls as strength rises, which moves the strike's
        // energy up into the high modes; the ring lengthens a little as well, since a harder strike
        // puts in more energy for the same damping to remove.
        let strikeBrightness = baseTilt - (tilt(strength, soft: 0.45, hard: 1.55) - 1) * 0.55
        let ring = tilt(strength, soft: 0.45, hard: 1.25)

        return CymbalSynth.Plate(
            lowestModeHz: lowestModeHz * spec.cymbalTuning,
            modeCount: max(4, Int((Double(modeCount) * spec.cymbalDensity).rounded())),
            stretch: stretch,
            inharmonicity: inharmonicity,
            lowestModeDecaySeconds: decaySeconds * ring * spec.cymbalDecay,
            damping: damping * spec.cymbalDarkening,
            excitationTilt: strikeBrightness - spec.cymbalBrightness,
            strikeSeconds: strikeSeconds,
            level: level,
            // The shimmer brightens with the strike for the same reason the modes do, and `spec`
            // moves it with the rest of the cymbal's colour.
            shimmerLevel: shimmerLevel * max(0, 1 + spec.cymbalBrightness)
                        * tilt(strength, soft: 0.35, hard: 1.4),
            shimmerDecayFraction: shimmerDecayFraction / max(spec.cymbalDarkening, 0.05),
            shimmerFromHz: shimmerFromHz * spec.cymbalTuning,
            // A harder strike blooms longer and further: more energy for the plate to move upward.
            shimmerRiseSeconds: shimmerRiseSeconds * tilt(strength, soft: 0.5, hard: 1.3),
            // The ping moves with the plate: a bigger cymbal's bow mode is lower.
            pingHz: ping.hz * spec.cymbalTuning,
            pingLevel: ping.level,
            pingDecayFraction: ping.decayFraction,
            strikeNoise: strikeNoise)
    }

    private static func clap(fs: Double, strength: Double) -> [Float] {
        let ring = tilt(strength, soft: 0.4, hard: 1.25)
        let n = Int(0.18 * fs)
        var out = [Float](repeating: 0, count: n)
        var noise = Noise()
        var prev: Float = 0
        // Three quick bursts then a short tail — the classic clap smear.
        let bursts = [0.0, 0.010, 0.020]
        for i in 0..<n {
            let t = Double(i) / fs
            var env = exp(-max(0, t - 0.030) / (0.05 * ring))
            for b in bursts where t >= b && t < b + 0.008 { env = max(env, 1.0) }
            let white = noise.next()
            let hp = white - prev; prev = white
            out[i] = hp * Float(env) * 0.5
        }
        return out
    }

    /// Barely moves: a rimshot is a rimshot. The 50 ms decay shifts a little and nothing else.
    private static func rimshot(fs: Double, strength: Double) -> [Float] {
        let ring = tilt(strength, soft: 0.65, hard: 1.15)
        let n = Int(0.05 * fs)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / fs
            let tone = sin(2 * .pi * 1700 * t) + 0.5 * sin(2 * .pi * 500 * t)
            out[i] = Float(tone * exp(-t / (0.008 * ring))) * 0.6
        }
        return out
    }

    /// A hard tom bends further and rings longer — the head is driven past its resting pitch.
    private static func tom(fs: Double, strength: Double) -> [Float] {
        let bend = tilt(strength, soft: 0.60, hard: 1.25)
        let ring = tilt(strength, soft: 0.45, hard: 1.25)
        let n = Int(0.30 * fs)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / fs
            let freq = 120 + 90 * bend * exp(-t / 0.05)
            phase += 2 * .pi * freq / fs
            out[i] = Float(sin(phase) * exp(-t / (0.14 * ring))) * 0.7
        }
        return out
    }
}
