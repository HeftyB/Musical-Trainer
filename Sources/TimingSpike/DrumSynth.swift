import Foundation
import GrooveCore

/// Procedurally synthesised drum voices, rendered once to sample buffers at startup.
///
/// Synthesis, not sampled recordings: nothing to license or download, sample-accurate, and
/// tempo-agile (resolves PLAN.md open question #4 by removing it). Each voice is a short
/// one-shot; the player mixes copies of these buffers at scheduled positions, so the render
/// thread never synthesises anything — it only adds pre-rendered samples.
struct DrumKit {
    let sampleRate: Double
    private(set) var buffers: [DrumVoice: [Float]] = [:]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for voice in DrumVoice.allCases {
            buffers[voice] = DrumSynth.render(voice, sampleRate: sampleRate)
        }
    }

    func buffer(for voice: DrumVoice) -> [Float] { buffers[voice] ?? [] }
    var maxVoiceLength: Int { buffers.values.map(\.count).max() ?? 0 }
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

    /// Soft saturation — adds harmonics and density, i.e. punch, while bounding the level.
    private static func saturate(_ x: Float, drive: Float) -> Float {
        tanh(x * drive) / tanh(drive)
    }

    static func render(_ voice: DrumVoice, sampleRate fs: Double) -> [Float] {
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
