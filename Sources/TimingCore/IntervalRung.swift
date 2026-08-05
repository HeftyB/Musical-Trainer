import Foundation

/// One rung of the interval ladder: how finely the beat is divided.
///
/// **Subdivision and tempo are one axis, not two.** Both move the inter-onset interval, and the
/// hands do not know which produced it — eighths at 100 BPM and quarters at 200 BPM are the same
/// 300 ms task. Everything here is therefore expressed in terms of that interval, so two rungs
/// of equal difficulty cannot be reported as unrelated conditions. See PLAN.md §7.23.
///
/// Straight time only. A rung divides the beat evenly; where a note is *expected* to sit within
/// the division is M15's problem, and mixing the two would report style as error.
public enum IntervalRung: String, Codable, Equatable, CaseIterable {
    case quarters
    case eighths
    /// Three to the beat. Not a phase offset on straight eighths — a different division, which
    /// is why it needs its own grid rather than a shared one.
    case tripletEighths
    case sixteenths

    /// Grid points per beat. This is exactly `Grid.subdivisions`.
    public var subdivisions: Int {
        switch self {
        case .quarters:       return 1
        case .eighths:        return 2
        case .tripletEighths: return 3
        case .sixteenths:     return 4
        }
    }

    public var label: String {
        switch self {
        case .quarters:       return "quarter notes"
        case .eighths:        return "eighths"
        case .tripletEighths: return "triplet eighths"
        case .sixteenths:     return "sixteenths"
        }
    }

    /// Rungs ordered easiest first, which is longest interval first at any fixed tempo.
    public static var ladder: [IntervalRung] { [.quarters, .eighths, .tripletEighths, .sixteenths] }

    // MARK: - The interval

    /// Seconds between adjacent notes at this rung and tempo. The quantity the whole ladder is
    /// really about.
    public func intervalSeconds(atBpm bpm: Double) -> Double {
        guard bpm > 0 else { return .nan }
        return 60.0 / bpm / Double(subdivisions)
    }

    /// Half-width of the matching window, in seconds. A note further than this from its grid
    /// point is not scored as late — it is discarded as off-grid (§5.3).
    public func windowSeconds(atBpm bpm: Double) -> Double {
        intervalSeconds(atBpm: bpm) * Matching.defaultWindowFraction
    }

    /// The matching window expressed in the player's own spread. Below about 3 this rung starts
    /// discarding notes the player aimed correctly.
    public func windowInSpreads(atBpm bpm: Double, spreadMs: Double) -> Double {
        guard spreadMs > 0 else { return .infinity }
        return windowSeconds(atBpm: bpm) * 1000 / spreadMs
    }

    // MARK: - The ceiling

    /// How many of the player's own spreads the matching window must be worth.
    ///
    /// At three, a note a full 3 SD from where it was aimed still scores; roughly 0.3% of
    /// correctly aimed notes fall outside. At two it is 4.6%, and the off-grid rate has become a
    /// property of the rung rather than of the player — which is §7.18's censoring trap arriving
    /// through the ladder. Off-grid rate is already reported next to spread, so the effect would
    /// be visible, but a threshold that keeps it small is better than a caveat that explains it.
    public static let minimumWindowInSpreads = 3.0

    /// The fastest tempo at which this rung still scores what the player aimed at.
    ///
    /// Derived, not chosen: the window is `0.4 × 60 / (bpm × subdivisions)`, and requiring it to
    /// be at least `minimumWindowInSpreads × spread` rearranges to this. It therefore moves as
    /// the player gets tighter — a ceiling that is a fact about them and the arithmetic, rather
    /// than a number somebody picked.
    ///
    /// At the ~20 ms spread this player currently shows: quarters 400 BPM, eighths 200,
    /// triplet eighths 133, sixteenths 100. The engine's own limit is 260, so only the top two
    /// rungs are constrained by this in practice — and sixteenths are already at the ceiling at
    /// the reference tempo.
    public func maximumBpm(forSpreadMs spreadMs: Double) -> Double {
        guard spreadMs > 0 else { return .infinity }
        let spreadSeconds = spreadMs / 1000
        return 60.0 * Matching.defaultWindowFraction
            / (Double(subdivisions) * Self.minimumWindowInSpreads * spreadSeconds)
    }

    /// Whether this rung can be scored honestly at this tempo, for a player of this spread.
    public func isScorable(atBpm bpm: Double, spreadMs: Double) -> Bool {
        bpm <= maximumBpm(forSpreadMs: spreadMs)
    }

    /// Every rung that can be scored honestly at this tempo, easiest first.
    public static func scorable(atBpm bpm: Double, spreadMs: Double) -> [IntervalRung] {
        ladder.filter { $0.isScorable(atBpm: bpm, spreadMs: spreadMs) }
    }

    /// The next rung up, or nil at the top.
    public var harder: IntervalRung? {
        guard let index = Self.ladder.firstIndex(of: self),
              index + 1 < Self.ladder.count else { return nil }
        return Self.ladder[index + 1]
    }

    /// The rung below, or nil at the bottom.
    public var easier: IntervalRung? {
        guard let index = Self.ladder.firstIndex(of: self), index > 0 else { return nil }
        return Self.ladder[index - 1]
    }
}
