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

    /// A one-bar tom fill to cap a section.
    public static let tomFill = Pattern.make([
        .snare: [0, 1],
        .tom:   [4, 6, 8, 10],
        .crash: [12],
        .kick:  [12],
    ])

    /// A simple snare-roll fill.
    public static let snareFill = Pattern.make([
        .snare: [8, 10, 12, 13, 14, 15],
        .crash: [0],
    ])

    /// A demonstration arrangement: two contrasting sections, each capped with a fill.
    public static let demo = Arrangement(sections: [
        Section(name: "A — basic rock", pattern: basicRock, bars: 8, fill: snareFill),
        Section(name: "B — driving",    pattern: drivingRide, bars: 8, fill: tomFill),
    ], loop: true)
}
