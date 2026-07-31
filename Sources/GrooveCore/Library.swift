import Foundation

/// A few stock grooves and fills to play against. All on the default 16-step / 4-per-beat
/// grid, so they share an arrangement freely.
public enum GrooveLibrary {
    /// Steady eighth-note hats, kick on 1 and 3, snare on 2 and 4 — the default rock feel.
    public static let basicRock = Pattern.make([
        .closedHat: [0, 2, 4, 6, 8, 10, 12, 14],
        .kick:      [0, 8],
        .snare:     [4, 12],
    ])

    /// Four-on-the-floor: kick every beat, offbeat open hats, backbeat snare.
    public static let fourOnFloor = Pattern.make([
        .kick:     [0, 4, 8, 12],
        .openHat:  [2, 6, 10, 14],
        .snare:    [4, 12],
    ])

    /// Half-time feel: snare on 3 only, sparse kick, sixteenth hats.
    public static let halfTime = Pattern.make([
        .closedHat: [0, 2, 4, 6, 8, 10, 12, 14],
        .kick:      [0, 10],
        .snare:     [8],
    ])

    /// Busier variation with syncopated kick and a ride pattern.
    public static let drivingRide = Pattern.make([
        .ride:  [0, 2, 4, 6, 8, 10, 12, 14],
        .kick:  [0, 6, 8, 14],
        .snare: [4, 12],
    ])

    // Fills ADD to the groove rather than replacing it, and carry no crash.
    //
    // Both details are load-bearing. A fill that replaces the pattern leaves a hole where the
    // pulse should be, and a player who loses the pulse through the turn has to re-find it
    // afterwards — the exact opposite of the skill a form drill trains. And a crash inside
    // the fill bar is a false landmark: it is the loudest event in earshot, one bar before
    // the downbeat it appears to announce. The crash belongs on the *arrival*, so it is added
    // to the first bar of the new phrase instead (see `accented`).

    /// A one-bar tom fill: the groove keeps running underneath, toms build over the second half.
    public static let tomFill = Pattern.make([
        .closedHat: [0, 2, 4, 6],
        .kick:      [0],
        .snare:     [4],
        .tom:       [8, 10, 12, 14],
    ])

    /// A one-bar snare-roll fill, pulse intact underneath.
    public static let snareFill = Pattern.make([
        .closedHat: [0, 2, 4, 6],
        .kick:      [0],
        .snare:     [8, 10, 12, 13, 14, 15],
    ])

    /// A crash on the downbeat — the arrival accent that marks the top of a new phrase.
    public static func accented(_ pattern: Pattern, velocity: Int = 110) -> Pattern {
        pattern.adding([Hit(voice: .crash, step: 0, velocity: velocity)])
    }

    /// A demonstration arrangement: two contrasting sections, each capped with a fill.
    public static let demo = Arrangement(sections: [
        Section(name: "A — basic rock", pattern: basicRock, bars: 8, fill: snareFill),
        Section(name: "B — driving",    pattern: drivingRide, bars: 8, fill: tomFill),
    ], loop: true)

    /// The backing for recorded takes: 8-bar sections alternating hat and ride, each capped
    /// with a fill.
    ///
    /// Two purposes at once. Sonic variety keeps a long take from going hypnotic, and the
    /// fills are *landmarks* — a fill every 8 bars is what lets a player feel where they are
    /// in the form without counting. Both sections keep the same rhythmic skeleton (eighths,
    /// kick on 1 and 3, backbeat), so the timing demand is constant across the take and only
    /// the colour changes.
    public static let jamBacking = Arrangement(sections: [
        Section(name: "A — hat",  pattern: basicRock,   bars: 8, fill: snareFill),
        Section(name: "B — ride", pattern: drivingRide, bars: 8, fill: tomFill),
    ], loop: true)
}
