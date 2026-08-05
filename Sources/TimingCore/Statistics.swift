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
}
