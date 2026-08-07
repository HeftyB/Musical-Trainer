import Foundation

/// One backing hit placed at an absolute output-sample position.
public struct ScheduledHit: Equatable {
    public let voice: BackingVoice
    /// Carried through from the `Hit`. `nil` for every drum.
    public let note: Int?
    /// Absolute sample index on the output timeline.
    public let sample: Int64
    public let velocity: Int

    public init(voice: BackingVoice, sample: Int64, velocity: Int, note: Int? = nil) {
        self.voice = voice
        self.sample = sample
        self.velocity = velocity
        self.note = note
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
    /// How the beat is divided. `.none` leaves every position exactly where it was.
    public let swing: Swing

    public init(bpm: Double, sampleRate: Double, swing: Swing = .none) {
        precondition(bpm > 0 && sampleRate > 0, "bpm and sampleRate must be positive")
        self.bpm = bpm
        self.sampleRate = sampleRate
        self.swing = swing
    }

    /// Absolute sample for a global step index (bars already flattened into steps).
    ///
    /// Still index arithmetic (R2.2): the beat and the step within it come from integer
    /// division of the global step, so nothing accumulates however long a take runs. The swing
    /// warps the *fraction* of the beat, which leaves every beat and bar line exactly where it
    /// was — the count-in boundary and the analysis window depend on that.
    public func sample(globalStep: Int, stepsPerBeat: Int) -> Int64 {
        let beatSeconds = 60.0 / bpm
        guard swing.isActive else {
            let secondsPerStep = beatSeconds / Double(stepsPerBeat)
            return Int64((Double(globalStep) * secondsPerStep * sampleRate).rounded())
        }
        let beat = Int(floor(Double(globalStep) / Double(stepsPerBeat)))
        let stepInBeat = globalStep - beat * stepsPerBeat
        let phase = swing.warp(Double(stepInBeat) / Double(stepsPerBeat))
        return Int64(((Double(beat) + phase) * beatSeconds * sampleRate).rounded())
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
                                velocity: hit.velocity, note: hit.note)
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
