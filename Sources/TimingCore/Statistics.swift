import Foundation

public struct Regression: Equatable {
    public let slope: Double
    public let intercept: Double
    /// Pearson correlation coefficient of the fit.
    public let r: Double

    public init(slope: Double, intercept: Double, r: Double) {
        self.slope = slope
        self.intercept = intercept
        self.r = r
    }
}

public enum Stats {
    /// `nil` when the value is NaN or infinite, otherwise the value.
    ///
    /// Every non-finite number that reaches storage goes through here, and it is not a
    /// nicety. The statistics below return `.nan` for "not computable from this input" — an
    /// empty series, a single point — and `JSONEncoder` refuses to encode a non-finite Double,
    /// throwing `NSCocoaErrorDomain 4866`, "The data couldn't be written because it isn't in
    /// the correct format".
    ///
    /// That destroyed a whole form take in the live session of 5 Aug 2026: the drill ran, the
    /// analysis completed, the save threw, and the session recorded the block as skipped. The
    /// inversion is what makes it serious — a take is lost exactly when it went *badly*, since
    /// that is when marks, usable trials or matched notes are too few to compute a summary. The
    /// most diagnostic takes were the ones being thrown away.
    public static func finite(_ x: Double?) -> Double? {
        guard let x, x.isFinite else { return nil }
        return x
    }

    public static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    /// Sample standard deviation (n-1 denominator).
    public static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return .nan }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    /// Population variance (n denominator). The natural form for the Wing–Kristofferson
    /// decomposition, which is defined in terms of population moments.
    public static func populationVariance(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let m = mean(x)
        return x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count)
    }

    /// Linear-interpolated percentile, `p` in 0...1.
    public static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        if s.count == 1 { return s[0] }
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, s.count - 1)
        return s[lo] + (pos - Double(lo)) * (s[hi] - s[lo])
    }

    public static func median(_ x: [Double]) -> Double { percentile(x, 0.5) }
    public static func iqr(_ x: [Double]) -> Double { percentile(x, 0.75) - percentile(x, 0.25) }

    public static func linearFit(x: [Double], y: [Double]) -> Regression? {
        guard x.count == y.count, x.count > 1 else { return nil }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let denom = (sxx * syy).squareRoot()
        return Regression(slope: slope,
                          intercept: my - slope * mx,
                          r: denom > 0 ? sxy / denom : 0)
    }

    /// Pearson correlation between two equal-length series. Returns nil if either has no
    /// variance (a flat series has no defined correlation).
    public static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1 else { return nil }
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Autocovariance at the given lag, using the population mean and an n denominator.
    /// `γ(k) = (1/n) Σ (x[i]−x̄)(x[i+k]−x̄)`.
    public static func autocovariance(_ x: [Double], lag k: Int) -> Double {
        guard k >= 0, x.count > k else { return .nan }
        let m = mean(x)
        var sum = 0.0
        for i in 0..<(x.count - k) {
            sum += (x[i] - m) * (x[i + k] - m)
        }
        return sum / Double(x.count)
    }

    /// Autocorrelation at the given lag: `γ(k) / γ(0)`, in −1...1.
    public static func autocorrelation(_ x: [Double], lag k: Int) -> Double? {
        let g0 = autocovariance(x, lag: 0)
        guard g0 > 0 else { return nil }
        return autocovariance(x, lag: k) / g0
    }

    /// Notes a run needs before it may contribute.
    ///
    /// **Chosen from the bias, not from taste.** Centring a run on its own mean costs roughly
    /// `1/n` of downward bias, and that bias points *toward* r₁ ≈ 0 — which §10 of `PLAN.md`
    /// defines as success. A method that drifts toward its own success criterion is the dangerous
    /// direction, so the threshold is where the drift stops mattering: simulated at a 23 ms spread,
    /// runs of 10 read −0.11 against a true 0, runs of 25 read −0.04, and runs of 60 read −0.01.
    /// Thirty is the knee.
    public static let minimumRunLength = 30

    /// What `gappyLag1` found. `r` is `nil` when no run was long enough to answer from — and the
    /// counts are still reported, because *why* a number is missing is the point (R3.3).
    public struct GappyLag1: Equatable {
        public let r: Double?
        /// Adjacencies the estimate was summed over.
        public let pairs: Int
        /// Adjacencies dropped because the two elements were not consecutive.
        public let dropped: Int
    }

    /// Lag-1 autocorrelation over a series with holes in it.
    ///
    /// **A plain autocorrelation pairs element *n* with element *n+1* and asks nothing about what
    /// sat between them.** For a stream of notes that is exactly right; across a rest it is not,
    /// because the question r₁ answers — *did the last error predict this one* — presumes the two
    /// notes are close enough for the second to be a response to the first. Two notes either side
    /// of four beats of silence get paired as though they were adjacent (PLAN.md §7.32).
    ///
    /// Same shape as `DropoutAnalysis.continuationRuns`, and for the same reason: §7.25 found a
    /// gap breaking the x-axis a slope was fitted against, and this is a gap breaking the
    /// adjacency a covariance is summed over.
    ///
    /// Runs are **not** concatenated before the sum. Joining them would reintroduce exactly the
    /// spurious adjacency being removed — the mistake the moving-block bootstrap makes.
    ///
    /// **Each run is centred on its own mean**, which is not a detail. Centring globally lets a
    /// *level* difference between runs masquerade as correlation: if the player sits 20 ms ahead
    /// before a rest and 20 ms behind after it, every product in both runs is large and positive
    /// against a global mean sitting between them, and r₁ reads near 1 for a player who corrected
    /// nothing. `WingKristofferson.decompose(trials:)` centres per trial for the same reason
    /// (§7.25). Slow drift is `driftMsPerBeat`'s job; r₁'s is note-to-note correction.
    ///
    /// The alternative — one global mean, products only within runs — was built first and measured
    /// against it. It is unbiased when placement does not move, and it **invents correction from a
    /// player who did none** as soon as it does: at a 15 ms shift across each rest it reads +0.27
    /// against a true 0, because every note in a run sits the same side of a mean lying between
    /// the runs. Since take-to-take bias in this project already ranges −7.6 to −24.8 ms, a shift
    /// of that size across a rest is ordinary rather than pathological.
    ///
    /// Runs shorter than `minimumRunLength` are dropped rather than contributing, and a take with
    /// no run that long reports no r₁ at all. A run of two is the extreme case: it has one pair,
    /// and against its own mean that product is `−(x−x̄)²`, **negative by construction** whatever
    /// the player did.
    ///
    /// - Parameter isAdjacent: whether elements `i` and `i+1` are consecutive in the stream.
    /// - Returns: the correlation, the pairs it was summed over, and how many adjacencies were
    ///   dropped. `nil` when nothing usable survives — R3.3.1, withhold at source rather than
    ///   return a number beside a caveat nobody reads.
    public static func gappyLag1(_ x: [Double],
                                 isAdjacent: (Int) -> Bool) -> GappyLag1? {
        guard x.count >= 2 else { return nil }

        // Split into runs of consecutive elements.
        var runs: [[Double]] = []
        var current: [Double] = [x[0]]
        var dropped = 0
        for i in 0..<(x.count - 1) {
            if isAdjacent(i) {
                current.append(x[i + 1])
            } else {
                dropped += 1
                runs.append(current)
                current = [x[i + 1]]
            }
        }
        runs.append(current)

        var products = 0.0
        var squares = 0.0
        var pairs = 0
        var used = 0
        for run in runs where run.count >= minimumRunLength {
            let m = mean(run)
            for i in 0..<(run.count - 1) {
                products += (run[i] - m) * (run[i + 1] - m)
                pairs += 1
            }
            for v in run { squares += (v - m) * (v - m) }
            used += run.count
        }
        guard pairs > 0, used > 0, squares > 0 else {
            return GappyLag1(r: nil, pairs: 0, dropped: dropped)
        }
        // Both halves are per-element averages, so dropping adjacencies cannot shrink the
        // estimate in proportion to how many went — which is the attenuation the moving-block
        // bootstrap suffers from and the thing this must not reproduce.
        return GappyLag1(r: (products / Double(pairs)) / (squares / Double(used)),
                         pairs: pairs, dropped: dropped)
    }
}
