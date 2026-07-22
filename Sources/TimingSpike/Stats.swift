import Foundation

struct Regression {
    let slope: Double
    let intercept: Double
    /// Pearson correlation coefficient of the fit.
    let r: Double
}

enum Stats {
    static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }

    /// Sample standard deviation (n-1 denominator).
    static func sd(_ x: [Double]) -> Double {
        guard x.count > 1 else { return .nan }
        let m = mean(x)
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    /// Linear-interpolated percentile, `p` in 0...1.
    static func percentile(_ x: [Double], _ p: Double) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        if s.count == 1 { return s[0] }
        let pos = p * Double(s.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, s.count - 1)
        return s[lo] + (pos - Double(lo)) * (s[hi] - s[lo])
    }

    static func median(_ x: [Double]) -> Double { percentile(x, 0.5) }
    static func iqr(_ x: [Double]) -> Double { percentile(x, 0.75) - percentile(x, 0.25) }

    static func linearFit(x: [Double], y: [Double]) -> Regression? {
        guard x.count == y.count, x.count > 1 else { return nil }
        let n = Double(x.count)
        let mx = mean(x), my = mean(y)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let denom = (sxx * syy).squareRoot()
        _ = n
        return Regression(slope: slope,
                          intercept: my - slope * mx,
                          r: denom > 0 ? sxy / denom : 0)
    }
}
