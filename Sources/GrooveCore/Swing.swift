import Foundation

/// How a groove divides the beat unevenly, applied when steps become samples.
///
/// **A warp of time within the beat, not a property of individual hits.** A swung pattern is the
/// same pattern: the hits keep their integer step positions and the sequencer moves *when those
/// steps happen*. That keeps `Pattern` on a uniform grid, keeps bar boundaries exactly where they
/// were, and means a sixteenth ornament inside a swung eighth pair moves with the pair rather
/// than needing its own rule.
///
/// **Keyed by an `Int` and a `Double`, not by `Feel`.** `GrooveCore` depends on nothing, not even
/// `TimingCore` (R1.1.3), so the type that describes a feel to the *analysis* cannot be shared
/// with the one that describes it to the *band*. That is a real hazard rather than a tidiness
/// problem: a groove swinging at one ratio while the grid scores at another would teach one thing
/// and measure another, silently, which is §7.23 step 4b's defect with the whole take inside it.
///
/// Since they cannot share code they are pinned together by a test instead — `TrainerKit` owns
/// the pairing, and asserts that a scheduled hat lands exactly where `Grid` expects that
/// subdivision to the sample.
public struct Swing: Equatable {
    /// Long-to-short ratio of the divided unit. 1 is straight.
    public let ratio: Double
    /// Notes per beat being divided — the rung, **not** a pattern's `stepsPerBeat`.
    public let notesPerBeat: Int

    public init(ratio: Double, notesPerBeat: Int) {
        self.ratio = ratio
        self.notesPerBeat = notesPerBeat
    }

    /// The identity: an even beat, whatever the pattern's resolution.
    public static let none = Swing(ratio: 1, notesPerBeat: 1)

    /// True when this actually moves anything. Triplets and undivided beats have no binary pair.
    public var isActive: Bool {
        ratio != 1 && notesPerBeat > 1 && notesPerBeat & (notesPerBeat - 1) == 0
    }

    /// Where the swung member of a pair sits within it. 0.5 is even.
    public var offbeatPhase: Double { ratio / (1 + ratio) }

    /// Move a position within the beat to where the swing puts it.
    ///
    /// Piecewise linear inside each pair: the first half stretches to fill `offbeatPhase` of the
    /// pair and the second half takes what is left. Continuous, monotonic, and fixes 0, every
    /// pair boundary, and 1 — which is why bar lines and beat lines do not move.
    ///
    /// - Parameter phaseInBeat: 0 at the downbeat, approaching 1 at the next.
    public func warp(_ phaseInBeat: Double) -> Double {
        guard isActive else { return phaseInBeat }
        let pairs = Double(notesPerBeat / 2)
        let scaled = phaseInBeat * pairs
        let pair = scaled.rounded(.down)
        let within = scaled - pair                      // 0 ..< 1 inside this pair

        let moved = within < 0.5
            ? within * 2 * offbeatPhase
            : offbeatPhase + (within - 0.5) * 2 * (1 - offbeatPhase)
        return (pair + moved) / pairs
    }
}
