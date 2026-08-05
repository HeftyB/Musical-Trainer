import Foundation

/// Is a metric actually moving, or is the eye finding a line in noise?
///
/// This used to live in the console command that printed it, where it could not be tested —
/// and a slope with a hand-rolled interval is exactly the kind of arithmetic that is wrong
/// silently. It is also needed in two places now: the console prints it and the app plots it,
/// and a trend that disagreed between the two surfaces would be worse than none.
public enum TrendVerdict: Equatable {
    /// The interval excludes zero and the slope points the right way.
    case improving
    /// The interval excludes zero and the slope points the wrong way.
    case worsening
    /// The interval includes zero. With a handful of takes this is usually the honest
    /// answer, not a disappointing one.
    case flat
}

public struct TrendFit: Equatable {
    public let slope: Double
    public let low: Double
    public let high: Double
    public let pointCount: Int
    public let verdict: TrendVerdict

    /// True when the 95% interval excludes zero, i.e. the direction is supported.
    public var isReal: Bool { verdict != .flat }
}

/// One metric tracked across takes, with the values kept so a caller can plot them.
public struct TrendRow: Equatable {
    public let label: String
    /// In take order, non-finite entries already removed.
    public let values: [Double]
    /// nil when there were too few usable points to fit.
    public let fit: TrendFit?
    /// Which direction counts as progress — spread down, on-form rate up.
    public let lowerIsBetter: Bool

    public init(label: String, values: [Double], fit: TrendFit?, lowerIsBetter: Bool) {
        self.label = label; self.values = values; self.fit = fit; self.lowerIsBetter = lowerIsBetter
    }
}

/// A set of takes comparable enough to fit a line through, plus any reason they might not be.
public struct TrendSeries: Equatable {
    public let title: String
    public let takeCount: Int
    /// Confounds inside this group — a changed backing or a changed difficulty level moves
    /// the numbers on its own, and a trend across the change measures the change.
    public let warnings: [String]
    public let rows: [TrendRow]

    public init(title: String, takeCount: Int, warnings: [String], rows: [TrendRow]) {
        self.title = title; self.takeCount = takeCount; self.warnings = warnings; self.rows = rows
    }
}

public enum TrendAnalysis {
    /// Below this a slope is meaningless — two points always fit a line perfectly.
    public static let minimumPoints = 3

    /// Fit a metric against take number and put an interval on the slope.
    ///
    /// The interval comes from resampling (take index, value) pairs. With a handful of takes
    /// it comes out wide, and that width *is* the answer: the alternative is reporting a
    /// point slope that reads as a finding.
    ///
    /// - Parameter lowerIsBetter: spread and error go down as you improve; on-form rate goes up.
    /// - Returns: nil when fewer than `minimumPoints` finite values remain.
    public static func fit(_ values: [Double],
                           lowerIsBetter: Bool,
                           iterations: Int = 2000,
                           seed: UInt64 = 0xA11CE) -> TrendFit? {
        // The x-axis is each take's own position in the series, not its position among the
        // takes that happened to be scorable.
        //
        // Filtering first and numbering afterwards does not leave a gap where an unusable take
        // was — it closes it, sliding every later take one place earlier. The slope is then per
        // *usable* take while the unit string, the labels and this doc comment all say per
        // take. Over `[10, nan, 8, 7, 6]` that is −1.3 against a true −1.0.
        let points = values.enumerated().filter { $0.element.isFinite }
        guard points.count >= minimumPoints else { return nil }
        let x = points.map { Double($0.offset) }
        let clean = points.map(\.element)
        guard let observed = Stats.linearFit(x: x, y: clean) else { return nil }

        // A resample that happens to draw the same index every time has no x-variance and no
        // slope; `linearFit` returns nil and the draw is skipped. That is rare except at the
        // very smallest sample sizes, where the interval is already too wide to conclude
        // anything — so it costs precision only where precision was never available.
        var rng = SplitMix64(seed: seed)
        var slopes: [Double] = []
        slopes.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var rx: [Double] = [], ry: [Double] = []
            rx.reserveCapacity(clean.count); ry.reserveCapacity(clean.count)
            for _ in 0..<clean.count {
                let i = Int(rng.next() % UInt64(clean.count))
                rx.append(x[i]); ry.append(clean[i])
            }
            if let f = Stats.linearFit(x: rx, y: ry) { slopes.append(f.slope) }
        }
        guard !slopes.isEmpty else { return nil }

        let low = Stats.percentile(slopes, 0.025)
        let high = Stats.percentile(slopes, 0.975)
        let real = (low > 0 && high > 0) || (low < 0 && high < 0)
        let improving = lowerIsBetter ? observed.slope < 0 : observed.slope > 0
        return TrendFit(slope: observed.slope, low: low, high: high, pointCount: clean.count,
                        verdict: !real ? .flat : improving ? .improving : .worsening)
    }

    /// Convenience: a row ready to render.
    ///
    /// `values` carries only the usable points, because that is what a chart plots. The fit
    /// gets the **original** series, gaps included — handing it the filtered one would restore
    /// the renumbering defect at the call site every caller actually uses.
    public static func row(_ label: String, _ values: [Double], lowerIsBetter: Bool) -> TrendRow {
        TrendRow(label: label, values: values.filter { $0.isFinite },
                 fit: fit(values, lowerIsBetter: lowerIsBetter),
                 lowerIsBetter: lowerIsBetter)
    }

    /// The distinct values an attribute takes across a group, sorted. More than one entry
    /// means the group is confounded on that attribute and the caller should say so.
    public static func distinct<T: Hashable & Comparable>(_ values: [T]) -> [T] {
        Set(values).sorted()
    }
}
