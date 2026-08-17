import Foundation

/// Cymbals, built the way a cymbal actually makes sound.
///
/// ## What a cymbal is, physically
///
/// A cymbal is a thin metal plate. Hit it and the whole plate flexes in a great many patterns at
/// once — a ring near the edge, a ring further in, radial creases, and hundreds of combinations of
/// those. Each pattern has a frequency it prefers to vibrate at. Those are its **modes**, and the
/// sound you hear is all of them ringing together and dying away at different rates.
///
/// Three facts about those modes are what make metal sound like metal, and the old synthesis had
/// none of them.
///
/// ### 1. The modes are inharmonic, and there are hundreds
///
/// A guitar string is *harmonic*: its modes sit at 1×, 2×, 3× the fundamental. Your ear fuses a
/// harmonic series into one pitch — that is what a musical note *is*. A plate's modes sit at
/// irregular, non-integer ratios, so nothing fuses and you hear **a sound rather than a note**.
///
/// Density matters as much as irregularity. Five inharmonic partials is a *chime* — you can pick
/// out the individual pitches. Thirty is a *shimmer*, because they are packed closer than your ear
/// can separate. The old hat and ride had five each, which is why they read as tuned metal objects
/// rather than as cymbals.
///
/// **Listen for:** with too few modes you can hum along with the hat. With enough you cannot.
///
/// ### 2. High modes die faster, so a cymbal *darkens* as it rings
///
/// A vibrating plate loses energy to the air, and it loses high frequencies fastest — small, fast
/// ripples radiate and dissipate more readily than slow, whole-plate flexing. So the attack is
/// bright and the tail is dark, and the change is continuous.
///
/// This is the single biggest thing missing before. The old crash was noise times one exponential:
/// **the same colour from beginning to end**, which is precisely what a noise burst sounds like and
/// precisely what a cymbal does not.
///
/// **Listen for:** does the tail sound like the attack turned down, or like a different, darker
/// sound? A real cymbal's last half-second is much duller than its first fifty milliseconds.
///
/// ### 3. Hit harder and it gets brighter, not just louder
///
/// Strike a plate hard enough and it stops behaving linearly: energy pumps from the low modes into
/// higher ones as it rings, which is why a hard crash *blooms* — it gets brighter for a moment
/// **after** the stick has left. A quiet tap has almost none of this.
///
/// Modelling the real nonlinearity is out of scope. What is here instead is honest and gets most of
/// the way: **a harder strike puts more energy into the high modes at the moment of the strike**,
/// through the spectrum of the excitation rather than through mode coupling. So a hard hit is
/// brighter from the start rather than brightening as it goes. §7.70 records that as an
/// approximation rather than a model.
///
/// ## How it is built
///
/// **A bank of resonators excited by a short burst of noise**, which is how the physics reads: the
/// stick delivers a broadband impulse, and the plate rings at the frequencies it prefers.
///
/// That is the opposite of the old approach, which summed `sin()` at chosen frequencies. Summing
/// sines is cheap for five partials and hopeless for forty — and it produces a mathematically pure
/// tone bank rather than something struck. Resonators fed by noise give the grit and the slight
/// irregularity of a real strike for free, because the excitation itself is irregular.
///
/// A resonator here is the standard two-pole recursion:
///
/// ```
/// y[n] = 2·r·cos(ω)·y[n−1] − r²·y[n−2] + x[n]
/// ```
///
/// `ω` is the mode's frequency in radians per sample and `r` is how much of its amplitude survives
/// each sample. `r` just below 1 rings for a long time; `r` further below 1 dies quickly. Four
/// multiplies and two adds per mode per sample, which is what makes forty modes affordable where
/// forty `sin()` calls would not be.
enum CymbalSynth {

    /// One vibrating pattern of the plate.
    struct Mode {
        /// Where it sits, in Hz.
        let frequency: Double
        /// Seconds to fall 60 dB — i.e. to become inaudible under anything else.
        let decaySeconds: Double
        /// How much of the strike's energy goes into this mode.
        let amplitude: Double
    }

    /// How the modes of one cymbal are laid out.
    ///
    /// Every field here is a thing you can hear, and the doc on each says what to listen for. These
    /// are absolute values rather than multipliers — a cymbal is described from scratch — and
    /// `KitSpec`'s cymbal knobs scale them per style.
    struct Plate {
        /// The lowest mode, in Hz. **Roughly "how big is this cymbal."**
        ///
        /// A 14-inch hi-hat's lowest modes sit around 400–700 Hz; a 20-inch ride sits lower, around
        /// 200–350; a big crash lower still. Physically it is stiffness against mass: a larger, thinner
        /// plate flexes more slowly.
        ///
        /// **Listen for:** the *weight* of the sound rather than its brightness. Lowering this makes
        /// the cymbal feel bigger without making it duller.
        let lowestModeHz: Double

        /// How many modes are synthesised.
        ///
        /// **Listen for:** whether you can pick out individual pitches. Below about a dozen you hear
        /// separate ringing tones — a chime, a bell, a triangle. Above about twenty-five they blur
        /// into a wash and your ear stops trying to name them. This is the difference between "that
        /// is a metal object" and "that is a cymbal".
        ///
        /// The cost is linear: each mode is a two-pole filter run over the whole buffer.
        let modeCount: Int

        /// How quickly the modes spread out as you go up.
        ///
        /// Mode *i* sits near `lowestModeHz · i^stretch`. At 1.0 they are evenly spaced in frequency;
        /// above 1.0 they spread apart as they climb.
        ///
        /// **1.0 is roughly what a thin plate does, and the first version of this had it wrong.** The
        /// number of modes below a given frequency grows about *linearly* with frequency in a plate —
        /// unlike a room, where it grows with the cube — so the spacing stays about constant and the
        /// modes get denser relative to how the ear hears pitch. Values above 1 thin the mid and top
        /// out, leaving audible gaps between individual ringing partials.
        ///
        /// **Listen for:** *hollowness*. Gaps between modes read as a tin can, a pipe, or a pitched
        /// drum — a small resonant object with a few strong frequencies rather than a plate. That was
        /// the verdict on the first attempt at 1.10–1.22 (§7.71).
        let stretch: Double

        /// How far each mode is nudged off its ideal position, as a fraction.
        ///
        /// **This is what stops it sounding like an instrument.** A perfectly regular series — even an
        /// inharmonic one — still has a pattern your ear can latch onto. Real plates are irregular:
        /// hammering, lathing and the bell all move modes around unpredictably.
        ///
        /// **Listen for:** at zero you may hear a faint pitch centre or a metallic "ringing note". Turn
        /// it up and that dissolves into noise-like shimmer.
        ///
        /// Deterministic, from a hash of the mode index — R1.2.2 means the same cymbal every launch.
        let inharmonicity: Double

        /// How long the lowest mode rings, in seconds.
        ///
        /// **Listen for:** the obvious one — total length. A closed hat is under a tenth of a second;
        /// a ride rings for a second or more; a crash for several.
        let lowestModeDecaySeconds: Double

        /// How much faster the high modes die than the low ones.
        ///
        /// A mode at frequency *f* decays in `lowestModeDecaySeconds · (f / lowestModeHz)^(−damping)`.
        /// At 0 every mode rings equally long and the sound keeps its colour to the end — which is
        /// what the old crash did, and why it sounded like a noise burst. At 1 the high end is gone in
        /// a fraction of the time the low end takes.
        ///
        /// **Listen for:** the tail's *colour*, not its length. Play the sound and ignore the first
        /// tenth of a second: is what remains bright and hissy, or dark and hollow? Real cymbals go
        /// distinctly dark. This is the knob for that, and it is the one that most separates "metal"
        /// from "noise".
        let damping: Double

        /// How the strike's energy is distributed across the modes, as a tilt.
        ///
        /// At 0 every mode gets the same energy. Positive numbers favour the low modes, which is what
        /// a soft strike with a large contact area does — a mallet, or the shoulder of a stick on the
        /// bow of a ride. Negative favours the high modes: a hard tip strike near the edge.
        ///
        /// **Listen for:** the brightness *of the attack*, distinct from the brightness of the tail.
        /// Two cymbals can start equally bright and end quite differently, and this is the first half
        /// of that pair while `damping` is the second.
        let excitationTilt: Double

        /// How long the strike itself lasts, in seconds.
        ///
        /// The stick is in contact for a very short time and delivers a broadband push. Longer here is
        /// a softer, less defined attack — a brush or a mallet rather than a tip.
        ///
        /// **Listen for:** the click at the very start. Short is a distinct "tick" before the ring;
        /// long smears it into the body of the sound.
        let strikeSeconds: Double

        /// The peak this cymbal is normalised to, 0…1.
        ///
        /// **Loudness is set here rather than falling out of the synthesis**, because a modal bank's
        /// raw output depends on how many modes it has and how long they ring — neither of which is a
        /// statement about how loud a cymbal is. Without this, `modeCount` and `cymbalDecay` would
        /// double as volume controls.
        ///
        /// The values match what each voice peaked at before the rewrite, so the balance between the
        /// cymbals and the drums is unchanged and only their *character* moved.
        let level: Double

        /// The level of a dense noise band standing in for the modes too high to model one at a time.
        ///
        /// **A real cymbal has hundreds of modes and this is how the top of them get in.** Above
        /// roughly 3 kHz they are packed closer than the ear can separate, so resolving them
        /// individually costs a resonator each and buys nothing you could hear: what a listener gets
        /// from that region is a *texture*, not a set of pitches. Band-limited noise is that texture
        /// for the price of one filter.
        ///
        /// The old voices used only this, with no modes underneath — which is why they read as noise
        /// bursts. The modes give it a body to sit on; without the shimmer the body sounds hollow,
        /// because the gaps between the modelled modes have nothing filling them.
        ///
        /// **Listen for:** air and sizzle. Too little and the cymbal is a pitched object; too much
        /// and it is a hiss with a thud at the front.
        let shimmerLevel: Double

        /// How long the shimmer lasts relative to the lowest mode.
        ///
        /// Below 1 the sizzle goes before the body does, which is what a cymbal does — those very
        /// high modes are the fastest to give their energy up. This is the same darkening `damping`
        /// applies to the modelled modes, for the part that is not modelled.
        ///
        /// **Listen for:** whether the sound gets *duller* as it rings or merely quieter.
        let shimmerDecayFraction: Double

        /// Where the shimmer band starts, in Hz.
        ///
        /// **Listen for:** the seam. Too low and the shimmer covers modes you wanted to hear as
        /// distinct metal; too high and there is an audible hole between the top mode and the sizzle.
        let shimmerFromHz: Double

        /// How much unresonated strike noise is mixed in alongside the modes.
        ///
        /// Real cymbals have a component that is not modal at all: the stick's own noise, and the very
        /// high, dense modes that are too closely packed to model individually. A little of this glues
        /// the attack together.
        ///
        /// **Listen for:** at zero the attack can sound synthetic and "pure", as if the sound begins
        /// already ringing. A touch of it puts the stick back in the room.
        let strikeNoise: Double
    }

    /// Deterministic noise for the strike and the inharmonicity, matching `DrumSynth.Noise` so the
    /// two behave identically and neither drifts from the other.
    private struct Noise {
        var state: UInt64 = 0x243F6A8885A308D3
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int32(truncatingIfNeeded: state >> 32)) / Double(Int32.max)
        }
    }

    /// A mode's nudge off its ideal frequency: deterministic, in −1…1, and different per mode.
    ///
    /// SplitMix64's finaliser rather than a running generator, so mode *i*'s offset does not depend
    /// on how many modes came before it — adding a mode must not move the ones already there, for the
    /// same reason `Variation` keys on the hit index rather than advancing a stream (§7.66).
    static func offset(forMode index: Int) -> Double {
        var z = UInt64(index) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)
        return Double(z >> 11) * (2.0 / 9_007_199_254_740_992.0) - 1
    }

    /// The modes a plate is made of.
    ///
    /// Split out from the rendering so a test can read the layout directly — the frequencies, the
    /// decays and the tilt are the whole design, and checking them through a rendered buffer would be
    /// checking them through a spectrum analyser (`LESSONS.md` shape 1's lesson applied to synthesis).
    static func modes(of plate: Plate) -> [Mode] {
        (0..<plate.modeCount).map { i in
            // Modes climb as a power law: mode 0 is the lowest, and `stretch` says how quickly the
            // rest spread out above it. Then each is nudged off that ideal by `inharmonicity`, so no
            // two cymbals — and no two modes — fall into a pattern the ear can name.
            let ideal = plate.lowestModeHz * pow(Double(i + 1), plate.stretch)
            let frequency = ideal * (1 + plate.inharmonicity * offset(forMode: i))
            let ratio = max(frequency / plate.lowestModeHz, 1)

            // Higher modes radiate their energy away faster. This is the darkening, and it is a power
            // law because damping in a plate rises with frequency rather than jumping at some corner.
            let decay = plate.lowestModeDecaySeconds * pow(ratio, -plate.damping)

            // The strike spreads its energy across the modes with a tilt: positive favours the low
            // ones (a soft, broad contact), negative the high ones (a hard tip).
            let amplitude = pow(ratio, -plate.excitationTilt)
            return Mode(frequency: frequency, decaySeconds: decay, amplitude: amplitude)
        }
    }

    /// Render one strike.
    ///
    /// - Parameter seconds: how long a buffer to produce. Anything still ringing at the end is faded
    ///   by the caller, exactly as the drum voices are.
    static func render(_ plate: Plate, seconds: Double, sampleRate fs: Double) -> [Float] {
        let count = max(Int(seconds * fs), 1)
        let strikeSamples = max(Int(plate.strikeSeconds * fs), 1)
        var out = [Float](repeating: 0, count: count)

        // The strike: a short burst of noise, shaped so it starts instantly and stops smoothly. A
        // burst that stopped abruptly would itself be a click, and a click is broadband — it would
        // excite every mode equally and wash out the tilt below.
        var noise = Noise()
        var excitation = [Double](repeating: 0, count: count)
        for i in 0..<strikeSamples {
            let t = Double(i) / Double(strikeSamples)
            excitation[i] = noise.next() * (1 - t) * (1 - t)
        }

        let modes = modes(of: plate)
        let total = modes.reduce(0.0) { $0 + $1.amplitude }
        guard total > 0 else { return out }

        out.withUnsafeMutableBufferPointer { out in
            excitation.withUnsafeBufferPointer { excitation in
                for mode in modes {
                    guard mode.frequency > 20, mode.frequency < fs / 2 - 100 else { continue }

                    // The two-pole resonator. `r` is how much amplitude survives one sample, set so
                    // the mode reaches −60 dB after its own decay time; `omega` is its frequency in
                    // radians per sample. The recursion below is the whole filter.
                    let omega = 2 * Double.pi * mode.frequency / fs
                    let r = pow(10, -3 / (mode.decaySeconds * fs))
                    let a1 = 2 * r * cos(omega)
                    let a2 = -r * r

                    // **Normalising a resonator is not one number, and picking the wrong one is a
                    // trap worth naming.**
                    //
                    // A two-pole resonator amplifies a *continuous* tone at its own frequency by
                    // about `1 / (1 - r)` — so the obvious correction is to multiply by `1 - r`. That
                    // is right for a resonator being driven, and wrong here: a struck plate is fed a
                    // very short burst and then rings on its own, which is an impulse response rather
                    // than a steady state. Its peak goes as `1 / sin(ω)`, not `1 / (1 - r)`.
                    //
                    // Using `1 - r` collapsed every cymbal: a mode ringing for two seconds has `r`
                    // within a hair of 1, so `1 - r` is around 2 × 10⁻⁵, and the modal content
                    // vanished under the strike noise. What came out was a 50-millisecond tick with a
                    // ghost of a ring behind it, for a plate asked to sustain a second and a half
                    // (§7.70).
                    //
                    // `sin(ω)` normalises the impulse peak across frequency, which is what makes
                    // `Mode.amplitude` mean "how much of the strike this mode takes" regardless of
                    // where it sits or how long it rings.
                    let gain = mode.amplitude / total * sin(omega)

                    // **Stop each mode once it is inaudible rather than running it to the end of the
                    // buffer.** `decaySeconds` is the time to −60 dB, so 1.4× that is about −84 dB —
                    // below anything else in the mix, and below the fade the caller applies.
                    //
                    // This is most of what makes forty modes affordable. High modes are damped
                    // hardest, so in a crash whose lowest mode rings 1.6 s the top ones are done in a
                    // tenth of that, and running them over the whole buffer was multiplying nothing
                    // by 44,100 samples a second. Kit build 43 s → 27 s (§7.70).
                    let ringing = min(count, Int(mode.decaySeconds * 1.4 * fs) + strikeSamples)

                    var y1 = 0.0, y2 = 0.0
                    for i in 0..<ringing {
                        let y = a1 * y1 + a2 * y2 + excitation[i]
                        y2 = y1
                        y1 = y
                        out[i] += Float(y * gain)
                    }
                }

                // A little raw strike noise alongside the modes: the stick's own sound.
                if plate.strikeNoise > 0 {
                    for i in 0..<count {
                        out[i] += Float(excitation[i] * plate.strikeNoise)
                    }
                }
            }
        }

        // The shimmer: the modes above `shimmerFromHz`, as a band of noise rather than as hundreds of
        // resonators. High-passed by subtracting a low-pass, and decaying faster than the body, which
        // is what makes the sound darken rather than merely fade.
        if plate.shimmerLevel > 0 {
            var noise = Noise()
            var lowA = 0.0, lowB = 0.0
            let a = 1 - exp(-2 * Double.pi * plate.shimmerFromHz / fs)
            let decay = max(plate.lowestModeDecaySeconds * plate.shimmerDecayFraction, 0.002)
            for i in 0..<count {
                let white = noise.next()
                lowA += a * (white - lowA)
                lowB += a * (lowA - lowB)
                let high = white - lowB
                let envelope = exp(-3 * Double(i) / (decay * fs))
                out[i] += Float(high * envelope * plate.shimmerLevel)
            }
        }

        // Normalise to unit peak, then to the level the caller asked for.
        //
        // A modal bank's absolute output depends on how many modes there are and how long they ring,
        // neither of which is a statement about how loud a cymbal should be — so leaving it
        // unnormalised would make `modeCount` and `cymbalDecay` double as volume controls, and a
        // style that wanted a washier ride would get a louder one as well.
        let peak = out.map(abs).max() ?? 0
        guard peak > 0 else { return out }
        let scale = Float(plate.level) / peak
        for i in 0..<out.count { out[i] *= scale }
        return out
    }
}
