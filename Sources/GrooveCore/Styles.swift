import Foundation

/// The authored styles. Two for now; the format is what step 3 is proving.
///
/// **Nothing here is scheduled by anything yet.** These are heard through `render` and judged by
/// ear before they go near a take, which is §7.23's rule — do not promote a player onto something
/// nobody has listened to — applied to music rather than to a rung.
public enum StyleLibrary {

    /// Everything authored, heard or not.
    public static let all: [Style] = [driving, pocket, syncopated, halfTime]

    /// The styles the planner may schedule: the ones that have been listened to.
    ///
    /// Empty is the correct answer for a library nobody has approved yet, and the planner has to
    /// cope with that rather than reaching past it (§7.29 step 5).
    public static var auditioned: [Style] { all.filter(\.auditioned) }

    // MARK: - The kits

    /// **Derived from each style's own description, not from a genre.** These four are named for what
    /// they *do* — §7.33 renamed three of them precisely because a genre name promises what the
    /// synthesis cannot deliver — so the kits deliver what the names actually claim, which is a feel
    /// rather than a record.
    ///
    /// Every number is a multiplier on the standard kit (`KitSpec`), so they read as intent and the
    /// untuned default stays exact. Conservative on purpose: these are a first pass from convention,
    /// and §7.68 records that an ear has not judged them yet.

    /// Close-miked and forward. Tight, cracking, and drier than the house room.
    ///
    /// Its own entry says *"straight eighths, hat-led"* and it was heard as *"a Nine Inch Nails
    /// vibe"* — so the kit gets out of the way of the eighths: a snare that snaps rather than rings,
    /// tight hats so the eighths articulate, and less room than anything else here.
    static let drivingKit = KitSpec(name: "driving",
                                    snareTuning: 1.12, snareDecay: 0.80, snareRattle: 1.15,
                                    kickTuning: 1.10, kickDecay: 0.85,
                                    cymbalDecay: 0.85, roomAmount: 0.60)

    /// Warm, fat and roomy. The one that sits back.
    ///
    /// *"Sits in a steady pocket"*, with a clap on the backbeat and a walking bass. A pocket is a
    /// feel of things arriving slightly unhurried, so the drums are lower, longer and further away:
    /// a snare with body rather than crack, and the most air after `half-time`.
    static let pocketKit = KitSpec(name: "pocket",
                                   snareTuning: 0.90, snareDecay: 1.20, snareRattle: 0.90,
                                   kickTuning: 0.92, kickDecay: 1.15,
                                   cymbalDecay: 1.10, roomAmount: 1.35)

    /// High, tight and dry, because **the ghost notes have to read**.
    ///
    /// Its entry names *"a kick that lands off the beat as often as on it, ghost snares, sixteenths
    /// on the hat"* — the busiest thing in the library. Everything here serves articulation: a
    /// high-tuned snare with the wires up so a ghost is audible as a ghost rather than as a smudge,
    /// the shortest decays, and the driest room, so sixteenths do not run into each other.
    ///
    /// **The wires came up on a listening verdict of "not quite ghosty enough"** (§7.69). A ghost
    /// note is quiet but not dull: what makes it read is the wires rattling, and the velocity layer
    /// it plays on is darkened as well as attenuated (§7.64), so the wire content is exactly what a
    /// soft hit has least of. More rattle in the kit is more of it left after the darkening.
    static let syncopatedKit = KitSpec(name: "syncopated",
                                       snareTuning: 1.25, snareDecay: 0.60, snareRattle: 1.60,
                                       kickTuning: 1.05, kickDecay: 0.75,
                                       cymbalDecay: 0.75, roomAmount: 0.50)

    /// Deep, long and wet. The opposite pole from `syncopated`.
    ///
    /// *"One snare, on beat three, and a great deal of air."* With one backbeat every other bar's
    /// worth of time, each hit has to fill the space it is given rather than get out of the way — so
    /// this is the lowest, longest kit here, and still the wettest.
    ///
    /// **Pulled back from washy** (§7.69). The first pass read as *"washy"* rather than airy, which
    /// is the failure mode §7.65 warned about when the room went in: a wash softens the attack, and
    /// this is the one style where the backbeat is scarce enough that blurring it costs the most.
    /// Air comes from the room being *present*, not from it being large.
    static let halfTimeKit = KitSpec(name: "half-time",
                                     snareTuning: 0.82, snareDecay: 1.30, snareRattle: 1.10,
                                     kickTuning: 0.88, kickDecay: 1.35,
                                     cymbalDecay: 1.10, roomAmount: 1.25)

    public static func named(_ name: String) -> Style? {
        all.first { $0.name == name }
    }

    // MARK: - Driving

    /// Straight eighths, hat-led, room to spare. The reference point: if a style cannot be
    /// compared to this one it is probably not doing anything.
    ///
    /// **Called `driving` rather than `rock` because it is not rock**, and a genre name is a
    /// promise (§7.30). Heard as *"a Nine Inch Nails vibe"* at intensity 0 and *"the start of a
    /// fire beat"* at 1 — good, and not the thing the old name claimed.
    ///
    /// The bass sits on the root with the kick and answers on the fifth, which is the whole idea
    /// of M19's rhythmic-only bass — a contour to remember without a key to reason about (M25).
    public static let driving = Style(
        name: "driving",
        layers: [
            // Skeleton: kick and backbeat. This alone is a usable click with a pulse.
            Layer(Pattern.make([.kick: [0, 10], .snare: [4, 12]]), entersAt: 0),
            // Eighths on the hat — what makes it rock rather than a metronome.
            // Accented, not uniform: leaning on the beat and easing off between is the whole
            // difference between a groove and a click track.
            Layer(Pattern.line(.closedHat, [0, 2, 4, 6, 8, 10, 12, 14],
                               velocities: [84, 54, 68, 54]), entersAt: 1),
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
        density: .medium,
        // Played over twice on 8 August — 32 bars, then 128. The longer take is where the
        // intensity arc first repeated, and the verdict was that it alternated subtly enough to
        // stay interesting without pulling the player off it (§7.29 step 5).
        // **Heard and approved on the §7.69 listening pass.** `auditioned` is set by the person who
        // has to play over it, and he did.
        auditioned: true, kit: drivingKit)

    // MARK: - Pocket

    /// Eighths on the tambourine, backbeat on the clap, and a bass that walks rather than
    /// answers.
    ///
    /// Named for what it does — sits in a steady pocket — rather than for Motown, which it was
    /// heard not to be (§7.30). Busier than rock on purpose — the format has to hold a style that fills the bar,
    /// or "more styles" would only ever mean more of the same one.
    ///
    /// Marked `busy` because that is the honest reading for a vocal drill later: a tambourine on
    /// every sixteenth is lovely to play over and hard to hear a voice through (M24).
    public static let pocket = Style(
        name: "pocket",
        layers: [
            // Quieter than rock's skeleton by design: the clap below lands on the same two
            // steps as the snare, and stacking voices is what makes a style clip rather than
            // any one of them being loud.
            Layer(Pattern.make([.kick: [0, 6, 10], .snare: [4, 12]], velocity: 76), entersAt: 0),
            // The clap doubles the backbeat rather than replacing it — that stacking is the
            // sound, and it is why the style reads as motown and not as rock with a clap.
            Layer(Pattern.make([.clap: [4, 12]], velocity: 54), entersAt: 1),
            // **The signature, and its absence was why this never read as Motown.** Eighths on
            // the tambourine, leaning on the backbeat — the sound sits on that, not on a hat.
            Layer(Pattern.line(.tambourine, [0, 2, 4, 6, 8, 10, 12, 14],
                               velocities: [52, 40, 66, 40]), entersAt: 1),
            Layer(bars: [
                Pattern.bass([(step: 0, note: 41), (step: 4, note: 41), (step: 8, note: 48),
                              (step: 12, note: 41)], velocity: 80),
                Pattern.bass([(step: 0, note: 41), (step: 4, note: 48), (step: 8, note: 36),
                              (step: 12, note: 41)], velocity: 80),
            ], entersAt: 1),
            // Sixteenths, quietly. The reason this style is `busy`.
            // A sidestick answering the backbeat rather than a second timekeeper. The hat and
            // the ride that used to live here were both keeping time alongside the tambourine —
            // three drummers, which is what an ear heard as "a bell with the hats going".
            Layer(Pattern.make([.sidestick: [7, 15]], velocity: 48), entersAt: 2),
            Layer(Pattern.make([.cowbell: [0, 8]], velocity: 44), entersAt: 3),
        ],
        fills: [
            Pattern.make([.snare: [12, 13, 14, 15], .crash: [0]], velocity: 84),
            Pattern.make([.tom: [10, 12, 14], .clap: [8], .crash: [0]], velocity: 84),
        ],
        playerVoices: [.kick, .snare, .clap, .tambourine, .sidestick, .cowbell, .crash, .tom],
        density: .busy,
        // **Listened to, not played over.** Approved on the renders — every intensity and the
        // seeded piece — rather than on a take. That is a weaker basis than `driving`'s and it is
        // recorded as such in §7.33 rather than smoothed over.
        // **Heard and approved on the §7.69 listening pass.** `auditioned` is set by the person who
        // has to play over it, and he did.
        auditioned: true, kit: pocketKit)

    // MARK: - Syncopated

    /// A kick that lands off the beat as often as on it, ghost snares, sixteenths on the hat.
    ///
    /// Named for the mechanism rather than for funk, which it was heard not to be (§7.30). The
    /// busiest thing here and the one that most rewards playing *around* rather than *on* —
    /// which is the point of having it: a player who only ever practises over a straight
    /// backbeat is practising one skill.
    public static let syncopated = Style(
        name: "syncopated",
        layers: [
            // The kick lands off the beat as often as on it, which is the whole character —
            // without it this is a straight groove with more hats.
            Layer(Pattern.make([.kick: [0, 3, 10], .snare: [4, 12]], velocity: 82), entersAt: 0),
            // Sixteenths with the beat leaning: unaccented sixteenths are the most metronomic
            // thing a kit can do, and this style lives entirely in the accents.
            Layer(Pattern.line(.closedHat, Array(0..<16),
                               velocities: [58, 30, 40, 30]), entersAt: 1),
            Layer(bars: [
                Pattern.bass([(step: 0, note: 33), (step: 3, note: 33), (step: 7, note: 40),
                              (step: 10, note: 33)], velocity: 82),
                Pattern.bass([(step: 0, note: 33), (step: 6, note: 40), (step: 10, note: 45),
                              (step: 14, note: 40)], velocity: 82),
            ], entersAt: 1),
            // Ghosts fill the space between the backbeats. Quiet enough to be felt rather than
            // counted, which is the whole idea.
            Layer(Pattern.make([.snare: [2, 7, 10, 15]], velocity: 34), entersAt: 2),
            Layer(Pattern.make([.openHat: [6, 14]], velocity: 56), entersAt: 3),
        ],
        fills: [
            Pattern.make([.snare: [10, 11, 12, 14], .crash: [0]], velocity: 80),
            Pattern.make([.tom: [8, 11, 13], .snare: [15], .crash: [0]], velocity: 80),
        ],
        playerVoices: [.kick, .snare, .closedHat, .openHat, .crash, .tom],
        density: .busy,
        // Listened to, not played over — see `pocket`.
        // **The audition is withdrawn because the kit changed** (§7.68). `auditioned` means a person
        // has heard this style and said yes, and what they said yes to was a different set of drums.
        // §7.29 step 5's rule is that nothing promotes a player onto music nobody has heard; a style
        // whose kit was swapped under a `true` would be that rule failing quietly.
        auditioned: false, kit: syncopatedKit)

    // MARK: - Half-time

    /// One snare, on beat three, and a great deal of air. **The one name kept**, because
    /// half-time is a description of a rhythm rather than a claim about a genre. The slowest-feeling thing here at any
    /// tempo, and the only `sparse` style — which is what M24's vocal drills will need, since a
    /// busy backing under an open microphone is unusable.
    ///
    /// It is also the hardest to sit inside: with a backbeat every other bar's worth of time,
    /// there is nothing to lean on between the landmarks.
    public static let halfTime = Style(
        name: "half-time",
        layers: [
            Layer(Pattern.make([.kick: [0, 10], .snare: [8]], velocity: 92), entersAt: 0),
            // Quarters, not eighths. Doubling the hat here would throw away the space that is
            // the entire character of the style.
            Layer(Pattern.line(.closedHat, [0, 4, 8, 12], velocities: [70, 50, 60, 50]),
                  entersAt: 1),
            Layer(bars: [
                Pattern.bass([(step: 0, note: 38), (step: 8, note: 38)], velocity: 86),
                Pattern.bass([(step: 0, note: 38), (step: 8, note: 45)], velocity: 86),
            ], entersAt: 1),
            // Was a ride on the *same four steps* as the hat above — the same rhythm in two
            // timbres, which is the clearest form of the two-timekeeper mistake. A shaker
            // filling the gaps is a texture rather than a second pulse.
            Layer(Pattern.make([.shaker: [2, 6, 10, 14]], velocity: 38), entersAt: 2),
            Layer(Pattern.make([.kick: [6]], velocity: 74), entersAt: 3),
        ],
        fills: [
            Pattern.make([.snare: [12, 14], .crash: [0]], velocity: 88),
            Pattern.make([.tom: [8, 12], .snare: [14], .crash: [0]], velocity: 88),
        ],
        playerVoices: [.kick, .snare, .closedHat, .shaker, .crash, .tom],
        density: .sparse,
        // Played over once, 128 bars on 8 August, and rated lowest of the two played — which is
        // what §7.29 step 5 predicted for the sparsest style: with a backbeat every other bar's
        // worth of time there is nothing to lean on between the landmarks. Approved as a style
        // worth practising over, not as an easy one.
        // **The audition is withdrawn because the kit changed** (§7.68). `auditioned` means a person
        // has heard this style and said yes, and what they said yes to was a different set of drums.
        // §7.29 step 5's rule is that nothing promotes a player onto music nobody has heard; a style
        // whose kit was swapped under a `true` would be that rule failing quietly.
        auditioned: false, kit: halfTimeKit)
}
