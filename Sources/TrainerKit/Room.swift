import Foundation

/// The space the kit is played in.
///
/// **Dryness is most of what reads as "electronic"** (§7.30 item 3), and the kit had none: every
/// voice stopped dead at the end of its own decay, in a room with no walls. Early reflections and a
/// short tail *"would do more for believability than any amount of spectral work on the voices
/// themselves"*.
///
/// ### Why this can be baked into the one-shots
///
/// The render callback may not synthesise anything (R2.3), so a reverb *in the mix* is unavailable —
/// there is nowhere to run it. Baking the room into each voice at startup is not a compromise for
/// that: **a room is a linear time-invariant filter, and filtering each voice then summing is
/// identical to summing then filtering.** Every voice goes through the same room, so the result is
/// the same signal a shared reverb would produce, computed once instead of per sample.
///
/// That equivalence is what makes it legitimate, and it holds only while the filter is the same for
/// every voice and does not change over time. A per-voice room, or one that reacted to what was
/// playing, would not be bakeable — and would not be a room.
///
/// ### Why a recursive network rather than an impulse response
///
/// Convolving a 0.32 s kick with a 0.35 s tail is 200 million multiply-adds, and there are 52
/// buffers to do it for — several minutes of startup for a result a Schroeder network gives in
/// milliseconds. Nothing here is on an audio path; it runs once per launch, and a launch that takes
/// a minute is a launch nobody waits through.
enum Room {

    /// Comb delays in milliseconds.
    ///
    /// **Mutually incommensurate on purpose.** Delays at simple ratios reinforce each other at their
    /// common period and the tail rings at a pitch — the "metallic" sound of a cheap reverb — instead
    /// of building a smooth density of echoes. These are the classic Schroeder spread, which shares
    /// no small factors.
    static let combDelaysMs: [Double] = [29.7, 37.1, 41.1, 43.7]

    /// Allpass delays, short and in series after the combs. They smear the echo density without
    /// colouring the magnitude response, which is what turns four discrete echo trains into a tail.
    static let allpassDelaysMs: [Double] = [5.0, 1.7]

    /// How long the tail takes to fall 60 dB.
    ///
    /// **A drum room, not a hall.** Long enough to say the kit is somewhere, short enough that a
    /// sixteenth at 160 BPM — 94 ms — is not still sounding when the next three have arrived. The
    /// backing is the ruler, and a ruler that blurs is worse than a dry one.
    static let reverbTimeSeconds = 0.34

    /// How much of the wet signal reaches the output.
    ///
    /// Low, and deliberately. What is wanted is the *cue* that a room exists, not an audible effect:
    /// past roughly a third the kit starts to sound washed rather than placed, and the transient the
    /// whole project measures against starts to soften.
    static let mix: Float = 0.20

    /// Early reflections: (delay in ms, gain).
    ///
    /// **These do most of the perceptual work**, and they are what a bare comb network lacks. The
    /// first arrivals off a floor and two walls are what an ear uses to size a space; the diffuse
    /// tail only says one is there. Times and gains are fixed rather than seeded — a room does not
    /// move between hits, and R1.2.2 wants the kit identical every launch.
    static let earlyReflections: [(delayMs: Double, gain: Float)] = [
        (11.0, 0.42), (17.5, 0.31), (23.0, 0.26), (31.5, 0.19), (43.0, 0.13),
    ]

    /// Damping applied inside each comb's feedback path, in Hz.
    ///
    /// Air and soft surfaces absorb highs faster than lows, so a real tail darkens as it decays.
    /// Without this the network returns the input's own brightness for the whole tail, which is the
    /// other half of what makes a cheap reverb sound like metal rather than a room.
    static let dampingHz = 3_600.0

    /// A one-pole low-pass, matching `DrumSynth`'s own so the two behave identically.
    private struct Damper {
        var y: Float = 0
        let a: Float
        init(cutoff: Double, fs: Double) { a = Float(1 - exp(-2 * .pi * cutoff / fs)) }
        mutating func process(_ x: Float) -> Float { y += a * (x - y); return y }
    }

    /// A feedback comb with damping in the loop.
    private struct Comb {
        var line: [Float]
        var index = 0
        let feedback: Float
        var damper: Damper

        init(delaySamples: Int, feedback: Float, damping: Double, fs: Double) {
            line = [Float](repeating: 0, count: max(delaySamples, 1))
            self.feedback = feedback
            damper = Damper(cutoff: damping, fs: fs)
        }

        mutating func process(_ x: Float) -> Float {
            let out = line[index]
            line[index] = x + damper.process(out) * feedback
            index = (index + 1) % line.count
            return out
        }
    }

    /// A Schroeder allpass. Flat magnitude, dispersive phase — it moves energy around in time
    /// without changing the colour, which is exactly what diffusion is.
    private struct Allpass {
        var line: [Float]
        var index = 0
        let gain: Float

        init(delaySamples: Int, gain: Float) {
            line = [Float](repeating: 0, count: max(delaySamples, 1))
            self.gain = gain
        }

        mutating func process(_ x: Float) -> Float {
            let stored = line[index]
            let out = stored - x
            line[index] = x + stored * gain
            index = (index + 1) % line.count
            return out
        }
    }

    /// The tail's length in samples: where it has fallen far enough to be inaudible under anything.
    static func tailSamples(sampleRate fs: Double) -> Int {
        Int(reverbTimeSeconds * 1.4 * fs)
    }

    /// Put a voice in the room.
    ///
    /// The buffer is extended by the tail before filtering, because the reverb has to keep sounding
    /// after the dry voice has stopped — which is the entire point. Callers fade the result, so the
    /// tail does not truncate into a step (§7.31 finding 1's defect, one level further out).
    static func applied(to buffer: [Float], sampleRate fs: Double) -> [Float] {
        guard !buffer.isEmpty, mix > 0 else { return buffer }

        let total = buffer.count + tailSamples(sampleRate: fs)

        // **Voice by voice rather than sample by sample across all of them.** The per-sample form
        // reads more like the signal flow and costs an order of magnitude more: mutating a struct
        // held in an array goes through exclusivity checking on every access, and this is called
        // once per voice per layer at launch. Each comb is independent, so running the whole signal
        // through one at a time is the same arithmetic in a shape the optimiser can keep in cache.
        var early = [Float](repeating: 0, count: total)
        for (delayMs, gain) in earlyReflections {
            let delay = Int(delayMs / 1000 * fs)
            for i in 0..<buffer.count where i + delay < total {
                early[i + delay] += buffer[i] * gain
            }
        }

        var excitation = [Float](repeating: 0, count: total)
        for i in 0..<total {
            excitation[i] = (i < buffer.count ? buffer[i] : 0) + early[i]
        }

        var wet = [Float](repeating: 0, count: total)
        for ms in combDelaysMs {
            // Feedback is set from each comb's own delay so they all reach −60 dB at the same
            // moment. One feedback figure across different delays gives the short combs a much
            // shorter tail, and the decay audibly arrives in stages.
            var comb = Comb(delaySamples: Int(ms / 1000 * fs),
                            feedback: Float(pow(10, -3 * (ms / 1000) / reverbTimeSeconds)),
                            damping: dampingHz, fs: fs)
            for i in 0..<total { wet[i] += comb.process(excitation[i]) }
        }
        let scale = 1 / Float(combDelaysMs.count)
        for i in 0..<total { wet[i] *= scale }

        for ms in allpassDelaysMs {
            var allpass = Allpass(delaySamples: Int(ms / 1000 * fs), gain: 0.7)
            for i in 0..<total { wet[i] = allpass.process(wet[i]) }
        }

        var out = [Float](repeating: 0, count: total)
        for i in 0..<total {
            out[i] = (i < buffer.count ? buffer[i] : 0) + (early[i] + wet[i]) * mix
        }
        return out
    }
}
