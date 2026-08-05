import Foundation

/// Backings for the interval ladder: one per subdivision, each making its own division audible.
///
/// A rung is only trainable if the groove *implies* it. Asked to play sixteenths over a backing
/// that only marks beats, the player has nothing to lock the subdivision to and is really being
/// asked to subdivide from memory — a different and much harder task than the one the rung
/// names. So the hats carry the division and everything else stays constant: kick on 1 and 3,
/// backbeat on 2 and 4, across every rung. Only the density changes, which is the point.
///
/// Keyed by an `Int` rather than by `IntervalRung`, because `GrooveCore` depends on nothing —
/// not even `TimingCore` (R1.1.3). The pairing of rung to backing lives in `TrainerKit`, which
/// imports both. That `Int` is the **rung's** subdivision throughout this file, named
/// `notesPerBeat` so it cannot be confused with a `Pattern`'s `stepsPerBeat`.
///
/// **The pattern's step resolution is not the analysis grid.** They coincide today at 4, which
/// is why `jamBacking` scores takes on a sixteenth-note grid, but they answer different
/// questions: the step grid is how finely the drums can be programmed, and the analysis grid is
/// what the player is scored against. M14 step 4 separates them at the call site. See §7.23.
public enum LadderBackings {

    /// Quarter notes: the hat marks the beat and nothing subdivides it.
    ///
    /// The sparsest rung and, for this player, not the easiest — an unsubdivided beat leaves the
    /// longest gap to bridge, and PLAN §7.23 records his own report that slow, sparse material
    /// is where he rushes.
    public static let quarters = Pattern.make([
        .closedHat: [0, 4, 8, 12],
        .kick:      [0, 8],
        .snare:     [4, 12],
    ])

    /// Eighths — the same skeleton as `basicRock`, which is what every take so far has played
    /// over.
    public static let eighths = Pattern.make([
        .closedHat: [0, 2, 4, 6, 8, 10, 12, 14],
        .kick:      [0, 8],
        .snare:     [4, 12],
    ])

    /// Triplet eighths: twelve steps to the bar, three to the beat.
    ///
    /// A different division of the beat, not a phase offset on the straight grid, which is why
    /// it needs its own step resolution rather than an approximation on sixteenths. Nothing in
    /// a take may mix this with the straight rungs — there is no grid that carries both, and
    /// scoring one against the other would report the division as error.
    public static let tripletEighths = Pattern.make(stepsPerBar: 12, stepsPerBeat: 3, [
        .closedHat: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
        .kick:      [0, 6],
        .snare:     [3, 9],
    ])

    /// Sixteenths: the hat carries all four, so the division is audible rather than implied.
    public static let sixteenths = Pattern.make([
        .closedHat: Array(0..<16),
        .kick:      [0, 8],
        .snare:     [4, 12],
    ])

    /// A one-bar fill at the rung's own resolution, so the fill never contradicts the division
    /// it interrupts. Adds to the groove rather than replacing it — a fill that leaves a hole
    /// where the pulse should be is the opposite of what a landmark is for (§6.1).
    ///
    /// - Parameter notesPerBeat: the **rung's** subdivision, not the pattern's step resolution.
    public static func fill(notesPerBeat: Int) -> Pattern {
        let base = pattern(notesPerBeat: notesPerBeat)
        let bar = base.stepsPerBar
        let secondHalf = Array((bar / 2)..<bar)
        // `base.stepsPerBeat`, not `notesPerBeat`. The first is the pattern's step resolution
        // and the second is the rung's subdivision, and they are only equal for triplets and
        // sixteenths — the very distinction this file's header sets out, got wrong here first
        // time and caught by the test that asserts a fill keeps its groove's resolution.
        return Pattern(stepsPerBar: bar, stepsPerBeat: base.stepsPerBeat,
                       hits: base.hits.filter { $0.step < bar / 2 }
                           + secondHalf.map { Hit(voice: .tom, step: $0, velocity: 100) })
    }

    /// The groove for a rung. Anything unrecognised falls back to eighths, which is what every
    /// take before the ladder played over.
    ///
    /// - Parameter notesPerBeat: the **rung's** subdivision — 1 quarters, 2 eighths, 3 triplet
    ///   eighths, 4 sixteenths. Not the returned pattern's `stepsPerBeat`, which is 4 for all
    ///   three straight rungs: quarters are programmed on a sixteenth step grid that only fires
    ///   on the beat. Passing a pattern's own resolution back in here would silently promote
    ///   quarters to sixteenths, and the parameter used to be named so that it invited exactly
    ///   that (M14 step 4a).
    public static func pattern(notesPerBeat: Int) -> Pattern {
        switch notesPerBeat {
        case 1:  return quarters
        case 2:  return eighths
        case 3:  return tripletEighths
        case 4:  return sixteenths
        default: return eighths
        }
    }

    /// A full backing for a rung: two eight-bar sections capped with a fill, so a long take has
    /// landmarks and does not go hypnotic (PLAN §6).
    ///
    /// Both sections keep the same rhythmic skeleton, exactly as `jamBacking` does — the timing
    /// demand has to be constant across a take or the rung is not the only thing being measured.
    ///
    /// - Parameter notesPerBeat: the **rung's** subdivision. See `pattern(notesPerBeat:)`.
    public static func backing(notesPerBeat: Int) -> Arrangement {
        let groove = pattern(notesPerBeat: notesPerBeat)
        let capped = fill(notesPerBeat: notesPerBeat)
        return Arrangement(sections: [
            Section(name: "A", pattern: groove, bars: 8, fill: capped),
            Section(name: "B", pattern: groove, bars: 8, fill: capped),
        ], loop: true)
    }
}
