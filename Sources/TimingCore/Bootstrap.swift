import Foundation

public struct ConfidenceInterval: Equatable {
    public let point: Double
    public let low: Double
    public let high: Double
    public let level: Double

    public var margin: Double { (high - low) / 2 }
    /// True when the interval excludes zero — for a difference, "the change is real."
    public var excludesZero: Bool { (low > 0 && high > 0) || (low < 0 && high < 0) }
}

/// Deterministic RNG so a given take always yields the same interval — a bootstrap that
/// jittered run to run would undermine the whole point of measuring uncertainty.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Confidence intervals by the moving-block bootstrap.
///
/// A plain resample-the-points bootstrap assumes independence, but timing asynchronies are
/// serially correlated — that correlation *is* the r₁ we report. Resampling single points
/// would destroy it and badly understate the uncertainty of the mean (and make an r₁
/// interval meaningless). Resampling contiguous blocks preserves short-range structure, so
/// the intervals stay honest for the mean, the SD, and r₁ alike.
public enum Bootstrap {
    public static let defaultIterations = 2000

    /// Block length ≈ n^(1/3), the standard rule of thumb, floored at 2.
    public static func defaultBlockLength(_ n: Int) -> Int {
        max(2, Int(Foundation.pow(Double(n), 1.0 / 3.0).rounded()))
    }

    /// One circular moving-block resample of the same length as the input.
    public static func blockResample(_ x: [Double], blockLength: Int,
                                     using rng: inout SplitMix64) -> [Double] {
        let n = x.count
        var out = [Double]()
        out.reserveCapacity(n)
        while out.count < n {
            let start = Int(rng.next() % UInt64(n))
            var j = 0
            while j < blockLength && out.count < n {
                out.append(x[(start + j) % n])
                j += 1
            }
        }
        return out
    }

    /// Percentile confidence interval for a statistic of one sample.
    public static func interval(_ x: [Double],
                                statistic: ([Double]) -> Double,
                                iterations: Int = defaultIterations,
                                level: Double = 0.95,
                                seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        guard x.count >= 8 else { return nil }
        let L = defaultBlockLength(x.count)
        var rng = SplitMix64(seed: seed)
        var stats = [Double](); stats.reserveCapacity(iterations)
        for _ in 0..<iterations {
            stats.append(statistic(blockResample(x, blockLength: L, using: &rng)))
        }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(point: statistic(x),
                                  low: Stats.percentile(stats, alpha),
                                  high: Stats.percentile(stats, 1 - alpha),
                                  level: level)
    }

    /// Percentile interval for the *difference* of a statistic between two samples,
    /// `statistic(a) − statistic(b)`. If it excludes zero, the two takes really differ on
    /// that statistic at the given level.
    public static func difference(_ a: [Double], _ b: [Double],
                                  statistic: ([Double]) -> Double,
                                  iterations: Int = defaultIterations,
                                  level: Double = 0.95,
                                  seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        guard a.count >= 8, b.count >= 8 else { return nil }
        let la = defaultBlockLength(a.count)
        let lb = defaultBlockLength(b.count)
        var rng = SplitMix64(seed: seed)
        var deltas = [Double](); deltas.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let sa = statistic(blockResample(a, blockLength: la, using: &rng))
            let sb = statistic(blockResample(b, blockLength: lb, using: &rng))
            deltas.append(sa - sb)
        }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(point: statistic(a) - statistic(b),
                                  low: Stats.percentile(deltas, alpha),
                                  high: Stats.percentile(deltas, 1 - alpha),
                                  level: level)
    }

    /// Fewer takes than this in a group and no pooled interval is produced at all.
    ///
    /// One take cannot support a statement about takes. The only variation available inside it
    /// is within-take variation, and presenting that as a condition's uncertainty is exactly
    /// the defect the two-stage resample below exists to remove — so a single take gets a gap
    /// rather than a narrow, wrong interval.
    public static let minimumTakes = 2

    /// Below this the interval is honest but coarsely estimated: the outer stage has very few
    /// distinct takes to draw from, so its tails are a handful of steps rather than a curve.
    /// Callers say so; they do not suppress the number.
    public static let stableIntervalTakes = 4

    /// Interval for a statistic over several takes pooled together.
    ///
    /// **Two-stage (cluster) resample: takes with replacement, then blocks within each take
    /// that was drawn.** Both stages are load-bearing and for different reasons.
    ///
    /// The outer stage is the one this got wrong for three milestones. Resampling only
    /// *within* takes leaves each take contributing its own fixed mean to every iteration, so
    /// the interval describes variation inside takes and is blind to variation between them —
    /// while the quantity being compared varies mostly between them. This dataset says so
    /// plainly: the two `benchmark` jams sit at −5.9 and −22.6 ms mean asynchrony (§7.19), and
    /// the old pooled interval over exactly those two takes was 6 ms wide. It was narrower
    /// than the gap between the two numbers it pooled, and `review conditions` was allowed to
    /// call a difference "real change" on that basis.
    ///
    /// The inner stage stays as it was, and blocks still never span a take boundary — that
    /// would invent a correlation between the end of one take and the start of another, which
    /// cannot exist.
    ///
    /// `WarmUpAnalysis.withinSessionFit` has resampled whole sittings from the day it was
    /// written, for this reason. The pooled path simply never got the same treatment.
    public static func pooledInterval(_ groups: [[Double]],
                                      statistic: ([Double]) -> Double,
                                      iterations: Int = defaultIterations,
                                      level: Double = 0.95,
                                      seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        let usable = groups.filter { $0.count >= 8 }
        guard usable.count >= minimumTakes else { return nil }
        var rng = SplitMix64(seed: seed)
        var stats = [Double](); stats.reserveCapacity(iterations)
        for _ in 0..<iterations {
            stats.append(statistic(resamplePool(usable, using: &rng)))
        }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(point: statistic(usable.flatMap { $0 }),
                                  low: Stats.percentile(stats, alpha),
                                  high: Stats.percentile(stats, 1 - alpha),
                                  level: level)
    }

    /// Interval for the difference of a pooled statistic between two sets of takes,
    /// `statistic(a) − statistic(b)`. Excluding zero means the conditions really differ.
    ///
    /// Two-stage on both sides, for the reason in `pooledInterval`. This is the readout M13's
    /// experiment runner is built on, so it is the one place in the project where a too-narrow
    /// interval would not merely mislead a reader but drive the app's own decision to stop
    /// collecting.
    public static func pooledDifference(_ a: [[Double]], _ b: [[Double]],
                                        statistic: ([Double]) -> Double,
                                        iterations: Int = defaultIterations,
                                        level: Double = 0.95,
                                        seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        let ua = a.filter { $0.count >= 8 }, ub = b.filter { $0.count >= 8 }
        guard ua.count >= minimumTakes, ub.count >= minimumTakes else { return nil }
        var rng = SplitMix64(seed: seed)
        var deltas = [Double](); deltas.reserveCapacity(iterations)
        for _ in 0..<iterations {
            deltas.append(statistic(resamplePool(ua, using: &rng)) - statistic(resamplePool(ub, using: &rng)))
        }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(point: statistic(ua.flatMap { $0 }) - statistic(ub.flatMap { $0 }),
                                  low: Stats.percentile(deltas, alpha),
                                  high: Stats.percentile(deltas, 1 - alpha),
                                  level: level)
    }

    /// One two-stage resample: `groups.count` takes drawn **with replacement**, then a
    /// moving-block resample inside each take that was drawn.
    ///
    /// Drawing with replacement is the whole point — an iteration that happens to draw one
    /// take three times and another none is what carries the between-take variation into the
    /// interval. Replacing this loop with `for g in groups` restores the old defect exactly,
    /// and `testPooledDifferenceDoesNotCallOneOddEveningARealChange` fails if it is.
    /// Percentile interval for the difference of means between two sets of **independent
    /// values**, `mean(a) − mean(b)`.
    ///
    /// A plain resample, not the moving-block one above: these are one number per take or per
    /// round, minutes or days apart, not a serially correlated stream. There is no short-range
    /// structure for blocks to preserve, and using the block version would be the wrong
    /// bootstrap for the data (R3.2).
    ///
    /// This is also the right tool for comparing conditions when the unit of analysis is the
    /// take — see `ExperimentAnalysis`, which is what settled that question.
    public static func plainDifference(_ a: [Double], _ b: [Double],
                                       iterations: Int = defaultIterations,
                                       level: Double = 0.95,
                                       seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var rng = SplitMix64(seed: seed)
        var deltas: [Double] = []
        deltas.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var sa = 0.0, sb = 0.0
            for _ in a.indices { sa += a[Int(rng.next() % UInt64(a.count))] }
            for _ in b.indices { sb += b[Int(rng.next() % UInt64(b.count))] }
            deltas.append(sa / Double(a.count) - sb / Double(b.count))
        }
        let alpha = (1 - level) / 2
        return ConfidenceInterval(point: Stats.mean(a) - Stats.mean(b),
                                  low: Stats.percentile(deltas, alpha),
                                  high: Stats.percentile(deltas, 1 - alpha),
                                  level: level)
    }

    private static func resamplePool(_ groups: [[Double]], using rng: inout SplitMix64) -> [Double] {
        var sample: [Double] = []
        sample.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for _ in groups.indices {
            let g = groups[Int(rng.next() % UInt64(groups.count))]
            sample.append(contentsOf: blockResample(g, blockLength: defaultBlockLength(g.count), using: &rng))
        }
        return sample
    }

    /// Interval for a lag-1 autocorrelation, which the block bootstrap **cannot** provide.
    ///
    /// Resampling contiguous blocks preserves short-range structure, which is why it is right for
    /// the mean and the SD. For r₁ it is self-defeating: every join between two blocks is a pair
    /// that was never adjacent, so a fraction ≈ `1/L` of the products are spurious and the
    /// resampled statistic is attenuated by about that much. The interval then sits below the
    /// point estimate, by more the larger the correlation is — and this file's own doc comment
    /// claimed the intervals "stay honest for the mean, the SD, and r₁ alike", which was wrong.
    ///
    /// Measured against AR(1) series with the correlation planted by construction, a nominal 95%
    /// interval covered the truth:
    ///
    /// | true r₁ | n | block bootstrap | this |
    /// |---|---|---|---|
    /// | 0.15 | 122 | 94% | 94% |
    /// | 0.40 | 492 | **72%** | 95% |
    /// | 0.64 | 122 | **25%** | 93% |
    ///
    /// It went unnoticed for thirty takes because this player's r₁ had never left 0.13–0.50, and
    /// the failure is invisible at the bottom of that range. The take that exposed it reported
    /// `r₁ = +0.64` with an interval of `[+0.36, +0.63]` — excluding its own point estimate.
    ///
    /// The replacement is the large-sample standard error, `√((1 − r²) / n)`, with `n` the pairs
    /// actually summed — which for a series with rests is not the note count (§7.32).
    ///
    /// - Returns: `nil` when there is no r₁ to bound, rather than an interval around nothing.
    public static func lag1Interval(r: Double?, pairs: Int,
                                    level: Double = 0.95) -> ConfidenceInterval? {
        guard let r, pairs >= 8, abs(r) < 1 else { return nil }
        // 1.96 for the conventional 95%; the level is a parameter for symmetry with the other
        // intervals here, and anything else is not used today.
        let z = level >= 0.99 ? 2.576 : (level >= 0.95 ? 1.96 : 1.645)
        let se = ((1 - r * r) / Double(pairs)).squareRoot()
        return ConfidenceInterval(point: r,
                                  low: Swift.max(-1, r - z * se),
                                  high: Swift.min(1, r + z * se),
                                  level: level)
    }

    // Common statistics, ready to pass in.
    public static let meanStat: ([Double]) -> Double = { Stats.mean($0) }
    public static let sdStat: ([Double]) -> Double = { Stats.sd($0) }
    public static let lag1Stat: ([Double]) -> Double = { Stats.autocorrelation($0, lag: 1) ?? 0 }
}
