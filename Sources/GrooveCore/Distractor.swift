import Foundation

/// Deterministic RNG, so a given seed always produces the same distractor.
///
/// Duplicated from `TimingCore` rather than shared: GrooveCore deliberately depends on
/// nothing, and a dozen lines of well-known arithmetic is a smaller price than a dependency
/// between the two pure modules.
struct GrooveRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func inRange(_ low: Double, _ high: Double) -> Double {
        low + unit() * (high - low)
    }
}

/// Sound to fill a retention interval **without handing the tempo back**.
///
/// This is the load-bearing piece of the tempo-memory drill, and the obvious implementation
/// is wrong. Anything built from `Pattern` lands on the 16-step grid, which means every onset
/// falls exactly on a sixteenth of the tempo the player is trying to remember — so the
/// "distractor" would quietly *rehearse* the period for them, and the drill would measure
/// nothing at all. A distractor has to be scheduled off-grid, at sample positions that carry
/// no relation to the beat, which is why it produces `ScheduledHit` directly instead.
///
/// Two properties are enforced and tested:
///
/// 1. **No onset lands near a beat.** A hit on the beat is a metronome tick.
/// 2. **Beat-phase is spread, not concentrated.** Intervals are drawn from a range wider than
///    one beat, so phase diffuses rather than locking. The test measures this as circular
///    concentration: on-grid onsets score ≈ 1, these score near 0.
public enum Distractor {

    /// Inter-onset intervals, as a fraction of the beat being remembered. The range is wider
    /// than a whole beat on purpose — that is what makes the phase random-walk instead of
    /// settling into a relationship with the pulse.
    static let minIntervalBeats = 0.30
    static let maxIntervalBeats = 1.40

    /// How close to a beat an onset is allowed to fall, as a fraction of the beat.
    static let beatGuard = 0.10

    /// Voices that read as texture rather than as a pulse. No kick and no crash: both are
    /// downbeat sounds, and either would be heard as a bar line even placed off-grid.
    static let voices: [DrumVoice] = [.closedHat, .rimshot, .tom, .clap]

    /// Fill `[startSample, endSample)` with aperiodic hits.
    ///
    /// - Parameters:
    ///   - beatSeconds: the period being remembered — used only to *avoid* it.
    ///   - gridOriginSample: where beat 0 sits, so "near a beat" can be evaluated.
    public static func hits(from startSample: Int64, to endSample: Int64,
                            sampleRate: Double, beatSeconds: Double,
                            gridOriginSample: Int64 = 0,
                            seed: UInt64 = 0x0D15) -> [ScheduledHit] {
        guard endSample > startSample, sampleRate > 0, beatSeconds > 0 else { return [] }
        let beatSamples = beatSeconds * sampleRate
        var rng = GrooveRandom(seed: seed)

        var hits: [ScheduledHit] = []
        // Start a little way in, so the silence after the groove stops is audible as a break.
        var cursor = Double(startSample) + beatSamples * rng.inRange(0.3, 0.8)

        while cursor < Double(endSample) {
            let sample = Int64(cursor.rounded())
            if sample >= startSample, sample < endSample, !isNearBeat(sample) {
                hits.append(ScheduledHit(voice: voices[Int(rng.next() % UInt64(voices.count))],
                                         sample: sample,
                                         velocity: Int(rng.inRange(55, 85))))
            }
            cursor += beatSamples * rng.inRange(minIntervalBeats, maxIntervalBeats)
        }
        return hits

        func isNearBeat(_ sample: Int64) -> Bool {
            let phase = beatPhase(sample: sample, gridOriginSample: gridOriginSample,
                                  beatSamples: beatSamples)
            return phase < beatGuard || phase > 1 - beatGuard
        }
    }

    /// Position of a sample within its beat, in 0..<1. Exposed so tests can measure how the
    /// onsets are distributed rather than trusting the generator.
    public static func beatPhase(sample: Int64, gridOriginSample: Int64,
                                 beatSamples: Double) -> Double {
        let offset = Double(sample - gridOriginSample) / beatSamples
        return offset - offset.rounded(.down)
    }
}
