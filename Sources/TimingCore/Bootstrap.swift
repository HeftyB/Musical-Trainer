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

    /// Interval for a statistic over several takes pooled together.
    ///
    /// Blocks are resampled *within* each take and then concatenated, so a block never spans
    /// a session boundary — that would invent a correlation between the end of one take and
    /// the start of another, which cannot exist.
    public static func pooledInterval(_ groups: [[Double]],
                                      statistic: ([Double]) -> Double,
                                      iterations: Int = defaultIterations,
                                      level: Double = 0.95,
                                      seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        let usable = groups.filter { $0.count >= 8 }
        guard !usable.isEmpty else { return nil }
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
    public static func pooledDifference(_ a: [[Double]], _ b: [[Double]],
                                        statistic: ([Double]) -> Double,
                                        iterations: Int = defaultIterations,
                                        level: Double = 0.95,
                                        seed: UInt64 = 0xC0FFEE) -> ConfidenceInterval? {
        let ua = a.filter { $0.count >= 8 }, ub = b.filter { $0.count >= 8 }
        guard !ua.isEmpty, !ub.isEmpty else { return nil }
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

    private static func resamplePool(_ groups: [[Double]], using rng: inout SplitMix64) -> [Double] {
        var sample: [Double] = []
        sample.reserveCapacity(groups.reduce(0) { $0 + $1.count })
        for g in groups {
            sample.append(contentsOf: blockResample(g, blockLength: defaultBlockLength(g.count), using: &rng))
        }
        return sample
    }

    // Common statistics, ready to pass in.
    public static let meanStat: ([Double]) -> Double = { Stats.mean($0) }
    public static let sdStat: ([Double]) -> Double = { Stats.sd($0) }
    public static let lag1Stat: ([Double]) -> Double = { Stats.autocorrelation($0, lag: 1) ?? 0 }
}
