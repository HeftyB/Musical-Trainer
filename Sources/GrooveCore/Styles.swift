import Foundation

/// The authored styles. Two for now; the format is what step 3 is proving.
///
/// **Nothing here is scheduled by anything yet.** These are heard through `render` and judged by
/// ear before they go near a take, which is §7.23's rule — do not promote a player onto something
/// nobody has listened to — applied to music rather than to a rung.
public enum StyleLibrary {

    public static let all: [Style] = [rock, motown]

    public static func named(_ name: String) -> Style? {
        all.first { $0.name == name }
    }

    // MARK: - Rock

    /// Straight eighths, hat-led, room to spare. The reference point: if a style cannot be
    /// compared to this one it is probably not doing anything.
    ///
    /// The bass sits on the root with the kick and answers on the fifth, which is the whole idea
    /// of M19's rhythmic-only bass — a contour to remember without a key to reason about (M25).
    public static let rock = Style(
        name: "rock",
        layers: [
            // Skeleton: kick and backbeat. This alone is a usable click with a pulse.
            Layer(Pattern.make([.kick: [0, 10], .snare: [4, 12]]), entersAt: 0),
            // Eighths on the hat — what makes it rock rather than a metronome.
            Layer(Pattern.make([.closedHat: [0, 2, 4, 6, 8, 10, 12, 14]], velocity: 78),
                  entersAt: 1),
            // The bass arrives with the drive, over two bars so it is a figure and not a pulse.
            Layer(bars: [
                Pattern.bass([(step: 0, note: 40), (step: 6, note: 40), (step: 10, note: 47)]),
                Pattern.bass([(step: 0, note: 40), (step: 6, note: 47), (step: 10, note: 40),
                              (step: 14, note: 35)]),
            ], entersAt: 1),
            // Loud: the hat opens on the "and" of four, which is the oldest trick there is for
            // making a bar want the next one.
            Layer(Pattern.make([.openHat: [14]], velocity: 92), entersAt: 2),
            // Loudest: ghost snares filling the second half of the bar.
            Layer(Pattern.make([.snare: [7, 15]], velocity: 42), entersAt: 3),
        ],
        fills: [
            Pattern.make([.snare: [8, 10, 12, 14], .crash: [0]], velocity: 96),
            Pattern.make([.tom: [8, 10, 12], .snare: [14], .crash: [0]], velocity: 96),
        ],
        // A drummer sitting in would take the kit and leave the bass alone (M20).
        playerVoices: [.kick, .snare, .closedHat, .openHat, .crash, .tom],
        density: .medium)

    // MARK: - Motown

    /// Sixteenths on the tambourine, backbeat on the clap, and a bass that walks rather than
    /// answers. Busier than rock on purpose — the format has to hold a style that fills the bar,
    /// or "more styles" would only ever mean more of the same one.
    ///
    /// Marked `busy` because that is the honest reading for a vocal drill later: a tambourine on
    /// every sixteenth is lovely to play over and hard to hear a voice through (M24).
    public static let motown = Style(
        name: "motown",
        layers: [
            // Quieter than rock's skeleton by design: the clap below lands on the same two
            // steps as the snare, and stacking voices is what makes a style clip rather than
            // any one of them being loud.
            Layer(Pattern.make([.kick: [0, 6, 10], .snare: [4, 12]], velocity: 76), entersAt: 0),
            // The clap doubles the backbeat rather than replacing it — that stacking is the
            // sound, and it is why the style reads as motown and not as rock with a clap.
            Layer(Pattern.make([.clap: [4, 12]], velocity: 54), entersAt: 1),
            Layer(bars: [
                Pattern.bass([(step: 0, note: 41), (step: 4, note: 41), (step: 8, note: 48),
                              (step: 12, note: 41)], velocity: 80),
                Pattern.bass([(step: 0, note: 41), (step: 4, note: 48), (step: 8, note: 36),
                              (step: 12, note: 41)], velocity: 80),
            ], entersAt: 1),
            // Sixteenths, quietly. The reason this style is `busy`.
            // Quiet, and quieter than it looks like it should be: sixteenths at 160 BPM are
            // 93 ms apart, so their tails overlap and the mix stacks where a listener hears one
            // steady shimmer. The number came from the headroom test at the top of the tempo
            // range, not from how it looks at 100.
            Layer(Pattern.make([.closedHat: Array(0..<16)], velocity: 46), entersAt: 2),
            Layer(Pattern.make([.ride: [0, 4, 8, 12]], velocity: 70), entersAt: 3),
        ],
        fills: [
            Pattern.make([.snare: [12, 13, 14, 15], .crash: [0]], velocity: 84),
            Pattern.make([.tom: [10, 12, 14], .clap: [8], .crash: [0]], velocity: 84),
        ],
        playerVoices: [.kick, .snare, .closedHat, .clap, .ride, .crash, .tom],
        density: .busy)
}
