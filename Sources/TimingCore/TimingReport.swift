import Foundation

/// Per-subdivision breakdown — e.g. solid on quarter notes, falling apart on the "e" and
/// "a" of sixteenths.
public struct SubdivisionStats: Equatable {
    /// Position within the beat, 0 = downbeat.
    public let subdivision: Int
    public let count: Int
    public let meanAsynchronyMs: Double
    public let sdAsynchronyMs: Double
}

/// Everything the app learns from one stretch of playing against a grid.
///
/// Deliberately post-hoc: nothing here is meant to be shown while playing. A number on
/// screen mid-take recruits the analytical loop this whole project exists to quiet.
public struct TimingReport: Equatable {
    public let matchedCount: Int
    public let extraCount: Int
    public let missedCount: Int

    /// The matched signed asynchronies in ms, in time order. Kept so callers can bootstrap
    /// confidence intervals and so the M5 review can plot the series.
    public let asynchroniesMs: [Double]

    /// The matched taps themselves, grid index included.
    ///
    /// Carried so nothing downstream has to re-run the matcher to ask a question the grid index
    /// answers — `ProducedIntervalAnalysis` needs the gap between consecutive notes, and a
    /// second matching pass with its own clustering window would be a second implementation of
    /// the thing R1.1.2 says has exactly one.
    public let matched: [MatchedTap]

    public let meanAsynchronyMs: Double     // + drag, − rush
    public let sdAsynchronyMs: Double
    public let medianAsynchronyMs: Double

    /// Lag-1 autocorrelation of the asynchrony series — the correction-gain diagnostic
    /// (PLAN.md §5.1). ≈0 is an autonomous timekeeper (flow); strongly negative is chasing
    /// the click; positive is uncorrected drift. nil when the series is too short or flat.
    public let lag1Autocorrelation: Double?

    /// Slope of asynchrony against beat position, in ms per beat. Positive = progressively
    /// later (slowing). nil when there are too few points to fit.
    public let driftMsPerBeat: Double?
    /// Tempo the drift implies, minus the grid tempo. Negative = playing slower than the
    /// grid. nil whenever `driftMsPerBeat` is.
    public let effectiveBpmError: Double?

    public let subdivisionStats: [SubdivisionStats]

    /// Pearson correlation between velocity and asynchrony. Positive = harder notes land
    /// later; a common, rarely-noticed coupling. nil when velocities are absent or flat.
    public let velocityTimingCorrelation: Double?

    /// One-line, non-numeric summary of the single most salient finding.
    public let headline: String
}

public enum TimingAnalysis {
    /// - Parameter chordWindowMs: near-simultaneous taps within this window are collapsed to
    ///   one rhythmic event before matching, so chords count once. 0 disables clustering
    ///   (e.g. when the caller has already clustered).
    public static func analyze(taps: [Tap], grid: Grid,
                               windowFraction: Double = Matching.defaultWindowFraction,
                               chordWindowMs: Double = 35) -> TimingReport {
        let events = chordWindowMs > 0
            ? TapClustering.collapse(taps, windowSeconds: chordWindowMs / 1000)
            : taps
        return make(match: Matching.match(taps: events, to: grid, windowFraction: windowFraction), grid: grid)
    }

    public static func make(match: MatchResult, grid: Grid) -> TimingReport {
        let asynchronies = match.asynchroniesMs
        let mean = Stats.mean(asynchronies)
        let sd = Stats.sd(asynchronies)
        let median = Stats.median(asynchronies)
        let lag1 = Stats.autocorrelation(asynchronies, lag: 1)

        // Drift: regress asynchrony on beat position (grid index in beats).
        var driftMsPerBeat: Double?
        var bpmError: Double?
        let beatPositions = match.matched.map { Double($0.gridIndex) / Double(grid.subdivisions) }
        if let fit = Stats.linearFit(x: beatPositions, y: asynchronies) {
            driftMsPerBeat = fit.slope
            // Each beat the player accrues `slope` ms of lateness, so their beat interval
            // is the grid's plus that. Convert the changed interval back to a tempo.
            let playerInterval = grid.beatInterval * 1000 + fit.slope
            if playerInterval > 0 {
                bpmError = 60_000 / playerInterval - grid.bpm
            }
        }

        let subdivisionStats = Self.subdivisionStats(match: match, grid: grid)
        let velocityCorrelation = Self.velocityCorrelation(match: match)

        let headline = Self.headline(
            matchedCount: match.matchedCount, mean: mean, sd: sd, lag1: lag1,
            driftMsPerBeat: driftMsPerBeat, missed: match.missedIndices.count,
            extras: match.extraTaps.count)

        return TimingReport(
            matchedCount: match.matchedCount,
            extraCount: match.extraTaps.count,
            missedCount: match.missedIndices.count,
            asynchroniesMs: asynchronies,
            matched: match.matched,
            meanAsynchronyMs: mean,
            sdAsynchronyMs: sd,
            medianAsynchronyMs: median,
            lag1Autocorrelation: lag1,
            driftMsPerBeat: driftMsPerBeat,
            effectiveBpmError: bpmError,
            subdivisionStats: subdivisionStats,
            velocityTimingCorrelation: velocityCorrelation,
            headline: headline)
    }

    private static func subdivisionStats(match: MatchResult, grid: Grid) -> [SubdivisionStats] {
        guard grid.subdivisions > 1 else { return [] }
        var byPhase: [Int: [Double]] = [:]
        for tap in match.matched {
            byPhase[grid.phase(ofIndex: tap.gridIndex), default: []].append(tap.asynchronyMs)
        }
        return byPhase.sorted { $0.key < $1.key }.map { phase, values in
            return SubdivisionStats(subdivision: phase,
                                    count: values.count,
                                    meanAsynchronyMs: Stats.mean(values),
                                    sdAsynchronyMs: Stats.sd(values))
        }
    }

    private static func velocityCorrelation(match: MatchResult) -> Double? {
        let withVelocity = match.matched.compactMap { m -> (Double, Double)? in
            guard let v = m.tap.velocity else { return nil }
            return (Double(v), m.asynchronyMs)
        }
        guard withVelocity.count == match.matched.count, withVelocity.count > 2 else { return nil }
        return Stats.correlation(withVelocity.map(\.0), withVelocity.map(\.1))
    }

    /// Pick the single most useful thing to say. Ordered by what most needs attention, and
    /// phrased to inform rather than scold — negative mean asynchrony is normal, not a
    /// fault, and the copy reflects that.
    private static func headline(matchedCount: Int, mean: Double, sd: Double,
                                 lag1: Double?, driftMsPerBeat: Double?,
                                 missed: Int, extras: Int) -> String {
        guard matchedCount >= 8 else {
            return "Not enough notes yet to say anything reliable — keep playing."
        }
        // Chasing the click is the finding that most directly matches the complaint, so it
        // leads when present.
        if let r = lag1, r < -0.3 {
            return "You're chasing the click — reacting to each beat and over-correcting "
                 + "instead of running your own pulse. This is what 'focusing harder' does."
        }
        if let drift = driftMsPerBeat, abs(drift) > 3 {
            return drift > 0
                ? "You drift slower as you go — the pulse sags over time."
                : "You drift faster as you go — the pulse creeps up over time."
        }
        if sd < 8 {
            return "Tight and even. Your pulse is holding on its own."
        }
        if abs(mean) > 15 {
            return mean < 0
                ? "You sit consistently ahead of the beat — steady, just early."
                : "You sit consistently behind the beat — steady, just late."
        }
        return "Your timing is loose but not biased — the pulse is there, it just wobbles."
    }
}
