import Foundation

/// A drum hit placed at an absolute output-sample position.
public struct ScheduledHit: Equatable {
    public let voice: DrumVoice
    /// Absolute sample index on the output timeline.
    public let sample: Int64
    public let velocity: Int

    public init(voice: DrumVoice, sample: Int64, velocity: Int) {
        self.voice = voice
        self.sample = sample
        self.velocity = velocity
    }
}

/// Turns patterns into sample-accurate hits.
///
/// Every position is computed from a single global step index, never by adding an interval
/// bar after bar. Accumulation would drift by fractions of a sample every step and audibly
/// smear over a long jam; index arithmetic lands every hit on an exact sample no matter how
/// many bars have gone by. This is the same discipline the audio clock and `Grid` use.
public struct Sequencer {
    public let bpm: Double
    public let sampleRate: Double

    public init(bpm: Double, sampleRate: Double) {
        precondition(bpm > 0 && sampleRate > 0, "bpm and sampleRate must be positive")
        self.bpm = bpm
        self.sampleRate = sampleRate
    }

    /// Absolute sample for a global step index (bars already flattened into steps).
    public func sample(globalStep: Int, stepsPerBeat: Int) -> Int64 {
        let secondsPerStep = 60.0 / bpm / Double(stepsPerBeat)
        return Int64((Double(globalStep) * secondsPerStep * sampleRate).rounded())
    }

    /// Sample at which a given bar begins.
    public func barStartSample(bar: Int, pattern: Pattern) -> Int64 {
        sample(globalStep: bar * pattern.stepsPerBar, stepsPerBeat: pattern.stepsPerBeat)
    }

    /// Schedule the hits of a single bar's pattern at their absolute sample positions.
    public func schedule(pattern: Pattern, bar: Int) -> [ScheduledHit] {
        pattern.hits.map { hit in
            let globalStep = bar * pattern.stepsPerBar + hit.step
            return ScheduledHit(voice: hit.voice,
                                sample: sample(globalStep: globalStep, stepsPerBeat: pattern.stepsPerBeat),
                                velocity: hit.velocity)
        }
    }

    /// Schedule every bar in a range of an arrangement, sorted by sample position so the
    /// audio side can walk them with a single cursor.
    public func schedule(arrangement: Arrangement, bars: Range<Int>) -> [ScheduledHit] {
        var out: [ScheduledHit] = []
        for bar in bars {
            out.append(contentsOf: schedule(pattern: arrangement.pattern(atBar: bar), bar: bar))
        }
        return out.sorted { $0.sample < $1.sample }
    }
}
