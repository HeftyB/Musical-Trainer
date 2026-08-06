import Foundation

/// Where within the beat a subdivision is *expected* to land.
///
/// Everything the app measured before M15 assumed a note aims at an even division of the beat.
/// In swing it aims at roughly two thirds of the way through, and matching that against an even
/// grid reports **style as error** — the same class of mistake as §5.3's sign inversion and far
/// more insidious, because the numbers stay entirely plausible. So the grid gains a feel and
/// the expected phase moves with it.
///
/// **One number, and straight is not a special case.** A feel is the long-to-short ratio of the
/// divided beat, and a ratio of 1 *is* straight — long and short are equal. That falls out of
/// the arithmetic rather than being handled separately, which means every straight take stays
/// bit-for-bit what it was and no code path needs an `if straight` in it.
///
/// **Swing applies to the finest binary division and nothing else.** Swung eighths delay the
/// off-eighth; swung sixteenths delay the second sixteenth of each pair while the eighths stay
/// put. Triplets are already the division swing borrows from, so a triplet rung is always
/// straight — asking for "swung triplets" is asking for a division of a division nobody plays.
///
/// Ska and reggae are deliberately **not** feels. They put the emphasis on the offbeat but the
/// offbeat is still at half the beat, so the grid is straight and what changes is which points
/// the player is asked to hit and what the band plays under them. That is a drill, not a grid.
public struct Feel: Equatable {

    /// Long-to-short ratio of the divided beat. 1 is straight; 2 is the triplet-based swing
    /// most players mean by "swung"; 1.5 is the shallower feel common at faster tempos.
    public let swingRatio: Double

    /// For the constants below, whose ratios are literals in this file and cannot fail. R4.7
    /// forbids proving that with a `!`, and a validating initialiser cannot validate itself.
    private init(unchecked ratio: Double) { swingRatio = ratio }

    /// Fails rather than repairing a ratio that describes nothing playable. Below 1 would mean
    /// the *offbeat* comes early, which is a different musical idea (and not one this measures);
    /// above 4 the short note is inside a fifth of the division and stops being a note value.
    public init?(swingRatio: Double) {
        guard swingRatio.isFinite, (1.0...4.0).contains(swingRatio) else { return nil }
        self.init(unchecked: swingRatio)
    }

    /// The identity. Every take recorded before M15 is this, which is why a missing feel can be
    /// read as straight without inventing anything — unlike a missing rung, which is not
    /// quarters (§7.23 step 4b).
    public static let straight = Feel(unchecked: 1)

    /// The triplet-based swing, where the divided beat is 2:1.
    public static let swung = Feel(unchecked: 2)

    public var isStraight: Bool { swingRatio == 1 }

    public var label: String {
        if isStraight { return "straight" }
        if swingRatio == 2 { return "swung (2:1)" }
        return String(format: "swung (%.2g:1)", swingRatio)
    }

    // MARK: - Where the notes go

    /// Fraction of the beat the offbeat of a *pair* sits at. Straight is 0.5.
    ///
    /// This is the quantity everything else derives from, and it is also the one the analysis
    /// should report on: `r = φ/(1−φ)` is steeply non-linear near the useful range, so the same
    /// physical steadiness reads as a wildly different ratio spread depending on how hard the
    /// player is swinging. Phase is linear in what the hands do; ratio is not.
    public var offbeatPhase: Double { swingRatio / (1 + swingRatio) }

    /// Where each subdivision of the beat is expected, as a fraction of the beat.
    ///
    /// Index 0 is always the downbeat at 0. Straight gives `k/n`. Swing delays the second half
    /// of each *binary* pair, leaving everything coarser where it was — so swung sixteenths keep
    /// their eighths on 0 and 0.5 and move only the notes between them.
    ///
    /// - Parameter subdivisions: notes per beat — the rung, not the pattern's step resolution.
    public func phases(subdivisions: Int) -> [Double] {
        guard subdivisions > 1 else { return [0] }
        let straightPhases = (0..<subdivisions).map { Double($0) / Double(subdivisions) }
        guard !isStraight, isBinary(subdivisions) else { return straightPhases }

        // The pair is the finest division; swing shifts its second member within its own span.
        let pairSpan = 1.0 / Double(subdivisions / 2)
        return straightPhases.enumerated().map { index, phase in
            index % 2 == 0 ? phase : phase - pairSpan / 2 + pairSpan * offbeatPhase
        }
    }

    /// Whether this feel has any effect at a given rung. Triplets and undivided beats do not.
    public func applies(toSubdivisions subdivisions: Int) -> Bool {
        !isStraight && isBinary(subdivisions)
    }

    private func isBinary(_ subdivisions: Int) -> Bool {
        subdivisions > 1 && subdivisions & (subdivisions - 1) == 0
    }

    // MARK: - The ceiling

    /// Seconds between the two closest expected notes at this feel, rung and tempo.
    ///
    /// Swing makes the beat's division uneven, so the *short* note is what the matcher has to
    /// resolve. At 2:1 the short half of an eighth pair is a third of the beat rather than a
    /// half, which is the same 200 ms a triplet rung produces — and that correspondence is what
    /// says the two derivations agree rather than merely coexist.
    public func shortestGapSeconds(subdivisions: Int, atBpm bpm: Double) -> Double {
        guard bpm > 0, subdivisions > 0 else { return .nan }
        let beat = 60.0 / bpm
        let points = phases(subdivisions: subdivisions) + [1.0]
        return zip(points, points.dropFirst()).map { ($1 - $0) * beat }.min() ?? beat
    }

    /// The fastest tempo at which this feel and rung still score what the player aimed at.
    ///
    /// Derived exactly as `IntervalRung.maximumBpm` is, from the shortest gap rather than from
    /// an even one. At a ratio of 1 it reproduces the rung's own ceiling, because at a ratio of
    /// 1 it *is* the rung.
    public func maximumBpm(subdivisions: Int, forSpreadMs spreadMs: Double) -> Double {
        guard spreadMs > 0, subdivisions > 0 else { return .infinity }
        let gapAtOneBpm = shortestGapSeconds(subdivisions: subdivisions, atBpm: 1)
        return gapAtOneBpm * Matching.defaultWindowFraction
            / (IntervalRung.minimumWindowInSpreads * spreadMs / 1000)
    }
}
