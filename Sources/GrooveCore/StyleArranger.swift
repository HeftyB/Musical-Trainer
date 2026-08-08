import Foundation

/// Turns a style into a piece of music of a given length, from a seed.
///
/// **This is what makes "lack of depth will never become an issue again" a statement about the
/// design rather than a hope.** A style is bounded authoring; the music it can produce is not,
/// because the arrangement — how the intensity moves, which fill lands where, how long the
/// phrases are — is chosen from a seed rather than written out.
///
/// The seed is stored on the take, in `grooveName`, as `style@seed`. That is what makes this
/// permissible rather than reckless: R1.2.2 says a result that cannot be reproduced from stored
/// data is not a result, and without the seed a take's own backing would be unreconstructible
/// the moment the generator changed. With it, `render` can reproduce any take's music exactly,
/// and `TakeAxis` still sees two seeds of one style as honestly different music (§7.29 step 4).
public enum StyleArranger {

    /// Phrase length in bars. A parameter rather than a constant because M16's span ladder grows
    /// it to 16 and 32, and the generator should not have to change when it does.
    public static let defaultPhraseBars = 8

    /// How the intensity moves across a piece, as a repeating shape.
    ///
    /// **Chosen from a small set rather than sampled per phrase, and that is a musical decision
    /// with a reason.** Independent random intensity sounds like somebody fiddling with a fader:
    /// there is no arrival, nothing is built to, and the listener cannot tell a section from an
    /// accident. A shape gives a piece somewhere to go, which is what a thirty-minute session
    /// needs to be worth playing.
    static let arcs: [[Int]] = [
        [1, 2, 3, 2],       // build and settle
        [1, 1, 2, 3],       // slow burn
        [2, 3, 2, 1],       // open strong, wind down
        [1, 3, 1, 3],       // call and response between loud and quiet
        [2, 2, 3, 3],       // two gears
    ]

    /// Phrases before an intensity arc repeats.
    ///
    /// Derived from `arcs` rather than written as `4`, so adding a five-phrase shape lengthens
    /// what an audition has to render instead of silently truncating one — `LESSONS.md` shape 9,
    /// two places holding the same value for different reasons.
    public static let arcPhrases = arcs.map(\.count).max() ?? 1

    /// The shortest piece that contains a whole intensity arc.
    ///
    /// **A piece shorter than this is one intensity and nothing else**, which is what made
    /// `render`'s seeded audition useless: it generated at 32 bars and wrote the command's 8, so
    /// the arc — the part of this milestone a step list cannot judge, and the reason intensity
    /// moves along a shape rather than being sampled per phrase — was never in the file anybody
    /// listened to (§7.31 finding 3).
    public static func barsForAFullArc(phraseBars: Int = defaultPhraseBars) -> Int {
        phraseBars * arcPhrases
    }

    /// A piece of `bars` bars in `style`, reproducible from `seed`.
    ///
    /// One `Section` per bar, because a style's layers cycle at their own lengths and a section
    /// that held one pattern for eight bars would flatten exactly the variation the layers exist
    /// to create.
    public static func arrangement(style: Style, seed: UInt64, bars: Int,
                                   phraseBars: Int = defaultPhraseBars) -> Arrangement {
        precondition(bars >= 1, "a piece needs at least one bar")
        precondition(phraseBars >= 1, "a phrase needs at least one bar")

        var rng = GrooveRandom(seed: seed)
        let arc = arcs[Int(rng.next() % UInt64(arcs.count))]
        // Drawn once, before the loop, so the number of random draws does not depend on the
        // length: two pieces from one seed then share their opening, which is what makes a
        // sitting sound like one evening rather than a shuffle (§7.29's persist-the-seed rule).
        let fillChoices = (0..<32).map { _ in Int(rng.next() % UInt64(max(style.fills.count, 1))) }

        var sections: [Section] = []
        sections.reserveCapacity(bars)

        for bar in 0..<bars {
            let phrase = bar / phraseBars
            let intensity = clamp(arc[phrase % arc.count])
            let isPhraseEnd = (bar % phraseBars) == phraseBars - 1

            let body = style.pattern(atBar: bar, intensity: intensity)
            var fill: Pattern?
            if isPhraseEnd, !style.fills.isEmpty {
                fill = style.fills[fillChoices[phrase % fillChoices.count]]
            }
            sections.append(Section(name: "\(style.name) p\(phrase) i\(intensity)",
                                    pattern: body, bars: 1, fill: fill))
        }
        return Arrangement(sections: sections, loop: true)
    }

    private static func clamp(_ intensity: Int) -> Int {
        min(max(intensity, Style.intensityRange.lowerBound), Style.intensityRange.upperBound)
    }
}

/// How a generated backing is named on a take, and read back from one.
///
/// `grooveName` is already stored on every take and already treated as a confound axis by
/// `TakeAxis` and the trend grouping, so carrying the seed inside it needs **no schema change**
/// and every take on record keeps decoding. A take whose backing was generated says
/// `motown@000000008f3a21c4`; one that was not says `jamBacking`, exactly as it always has.
public struct BackingIdentity: Equatable {
    public let style: String
    public let seed: UInt64

    public init(style: String, seed: UInt64) {
        self.style = style
        self.seed = seed
    }

    /// Fixed width and lower case, so two takes of one seed sort together and a name written
    /// today still parses in a year.
    public var name: String { String(format: "%@@%016llx", style, seed) }

    /// `nil` for a name that is not a generated backing, which is every take recorded before
    /// M19 — the distinction has to survive, because those takes really did play fixed music.
    public static func parse(_ name: String) -> BackingIdentity? {
        let parts = name.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              let seed = UInt64(parts[1], radix: 16) else { return nil }
        return BackingIdentity(style: String(parts[0]), seed: seed)
    }
}
