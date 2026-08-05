import Foundation

/// One take reduced to the numbers the interval question needs.
public struct IntervalObservation: Equatable {
    public let bpm: Double
    /// Notes per beat the player was **asked to produce**, not the grid the take was scored on.
    ///
    /// These are different quantities and conflating them was the first version of this file.
    /// Every jam so far is free playing scored on a sixteenth-note grid, so scoring resolution
    /// would say the task was a 150 ms one at 100 BPM — an interval nobody performed. Until a
    /// rung is prescribed the task is the beat, so this is 1; from M14 step 4 it is the rung.
    public let subdivisions: Int
    public let spreadMs: Double?
    /// Signed: negative is ahead of the beat. The rushing claim lives here.
    public let biasMs: Double?
    public let sittingId: UUID?

    public init(bpm: Double, subdivisions: Int, spreadMs: Double?, biasMs: Double?,
                sittingId: UUID? = nil) {
        self.bpm = bpm; self.subdivisions = subdivisions
        self.spreadMs = spreadMs; self.biasMs = biasMs; self.sittingId = sittingId
    }

    /// Milliseconds between the notes this take was asked for. The axis.
    public var intervalMs: Double {
        guard bpm > 0, subdivisions > 0 else { return .nan }
        return 60_000 / bpm / Double(subdivisions)
    }
}

/// Every take that shared an interval.
public struct IntervalBucket: Equatable {
    public let intervalMs: Double
    public let bpm: Double
    public let subdivisions: Int
    public let takes: Int
    public let sittings: Int
    public let meanSpreadMs: Double?
    public let meanBiasMs: Double?
    /// Spread as a percentage of the interval it sits inside.
    ///
    /// **The only form comparable across tempos.** Scatter grows with the interval, so raw
    /// milliseconds fall at faster tempos almost mechanically; comparing them would report
    /// "faster is tighter" as arithmetic. This is what the precision claim has to be tested on.
    public let relativeSpreadPercent: Double?
    /// Bias as a percentage of the interval, for the same reason.
    public let relativeBiasPercent: Double?
}

public enum IntervalVerdict: Equatable {
    /// Not enough spread in the interval to ask anything. Says what is missing.
    case notEnoughRange(reason: String)
    /// Enough to fit, and neither slope is separable from zero.
    case noResponseFound
    /// At least one slope is real.
    case responds
}

public struct IntervalResponseReport: Equatable {
    public let buckets: [IntervalBucket]
    /// Relative spread against interval. Negative means tighter *relative to the interval* as
    /// the interval lengthens.
    public let relativeSpreadVsInterval: TrendFit?
    /// Absolute spread against interval, in ms of spread per ms of interval.
    ///
    /// Reported **beside** the relative fit rather than instead of it, because which of the two
    /// is the invariant is an open question about this player and not a thing the analysis is
    /// entitled to decide. This file used to normalise and report only the relative form, on
    /// §7.23's premise that scatter grows with the interval. `ProducedIntervalAnalysis` measured
    /// that premise on the takes already recorded and it did not hold — so an analysis that
    /// divides by the interval and reports one number is asserting the answer, not testing it.
    /// Exactly one of these two should be flat; which one is the finding.
    public let absoluteSpreadVsInterval: TrendFit?
    /// Signed asynchrony against interval. Negative means further ahead of the beat as the
    /// interval lengthens — the "slow tempos make me rush" claim.
    public let biasVsInterval: TrendFit?
    public let verdict: IntervalVerdict
    public let headline: String
    public let notes: [String]
}

/// Does tempo change how you play — and if so, which way?
///
/// **Subdivision and tempo are one axis**, so this fits against the inter-onset interval rather
/// than against either separately. Eighths at 100 BPM and quarters at 200 are the same 300 ms
/// task, and reporting them as unrelated conditions would throw away half the evidence.
///
/// Two claims, tested apart because they need different handling (PLAN.md §7.23):
///
/// - **"Slow tempos make me rush."** A claim about signed asynchrony growing more negative as
///   the interval lengthens. Nothing forces it mechanically, so a slope here is a real finding.
/// - **"Faster is easier, to a point."** A claim about precision, which raw spread cannot test:
///   scatter grows with the interval, so milliseconds fall at faster tempos on their own.
///   Normalising by the interval is what makes the question answerable at all, and "to a point"
///   is a claim about an optimum, which needs more distinct intervals than a line does.
///
/// Until tempo has actually been varied this reports what is missing rather than a slope through
/// a cluster — which, on the takes recorded so far, is the whole of what it can honestly say.
public enum IntervalResponseAnalysis {

    /// Fewer distinct intervals than this and there is no axis, only a cluster.
    public static let minimumIntervals = 3
    /// One take at an interval carries no between-take variation, so it cannot anchor a slope
    /// (the same reasoning as `Bootstrap.minimumTakes`).
    public static let minimumTakesPerInterval = 2

    public static func analyze(_ observations: [IntervalObservation],
                               iterations: Int = 2000,
                               seed: UInt64 = 0x1017) -> IntervalResponseReport {
        let usable = observations.filter { $0.intervalMs.isFinite }
        let grouped = Dictionary(grouping: usable) { round($0.intervalMs * 100) / 100 }

        let buckets = grouped.keys.sorted().map { interval -> IntervalBucket in
            let takes = grouped[interval] ?? []
            let spreads = takes.compactMap(\.spreadMs).filter(\.isFinite)
            let biases = takes.compactMap(\.biasMs).filter(\.isFinite)
            let meanSpread = spreads.isEmpty ? nil : Stats.mean(spreads)
            let meanBias = biases.isEmpty ? nil : Stats.mean(biases)
            return IntervalBucket(
                intervalMs: interval,
                bpm: takes.first?.bpm ?? .nan,
                subdivisions: takes.first?.subdivisions ?? 0,
                takes: takes.count,
                sittings: Set(takes.compactMap(\.sittingId)).count,
                meanSpreadMs: meanSpread, meanBiasMs: meanBias,
                relativeSpreadPercent: meanSpread.map { $0 / interval * 100 },
                relativeBiasPercent: meanBias.map { $0 / interval * 100 })
        }

        var notes = caveats(buckets: buckets, observations: usable)

        // The refusal comes before any fit. A slope through two clustered tempos is not a weak
        // answer to the question, it is an answer to a different one.
        if let reason = whyNotEnoughRange(buckets: buckets) {
            return IntervalResponseReport(
                buckets: buckets, relativeSpreadVsInterval: nil,
                absoluteSpreadVsInterval: nil, biasVsInterval: nil,
                verdict: .notEnoughRange(reason: reason),
                headline: "Tempo has not been varied enough to ask the question. \(reason)",
                notes: notes)
        }

        // Fitted per take, not per bucket: a bucket mean hides how much its takes disagreed, and
        // that disagreement is most of the uncertainty (§7.20 finding 1).
        let spreadPoints = usable.compactMap { o -> (Double, Double)? in
            guard let spread = o.spreadMs, spread.isFinite, o.intervalMs > 0 else { return nil }
            return (o.intervalMs, spread / o.intervalMs * 100)
        }
        let biasPoints = usable.compactMap { o -> (Double, Double)? in
            guard let bias = o.biasMs, bias.isFinite else { return nil }
            return (o.intervalMs, bias)
        }

        let absolutePoints = usable.compactMap { o -> (Double, Double)? in
            guard let spread = o.spreadMs, spread.isFinite, o.intervalMs > 0 else { return nil }
            return (o.intervalMs, spread)
        }

        let spreadFit = TrendAnalysis.fit(x: spreadPoints.map(\.0), y: spreadPoints.map(\.1),
                                          lowerIsBetter: true, iterations: iterations, seed: seed)
        let absoluteFit = TrendAnalysis.fit(x: absolutePoints.map(\.0), y: absolutePoints.map(\.1),
                                            lowerIsBetter: true, iterations: iterations, seed: seed)
        let biasFit = TrendAnalysis.fit(x: biasPoints.map(\.0), y: biasPoints.map(\.1),
                                        lowerIsBetter: true, iterations: iterations, seed: seed)

        let responds = spreadFit?.isReal == true || biasFit?.isReal == true
        notes.append(invariantNote(relative: spreadFit, absolute: absoluteFit))
        notes.append("\"Easier to a point\" is a claim about an optimum, and a straight line "
                   + "cannot carry it. Reading a curve needs more distinct intervals than a "
                   + "slope does — \(buckets.count) so far.")

        return IntervalResponseReport(
            buckets: buckets, relativeSpreadVsInterval: spreadFit,
            absoluteSpreadVsInterval: absoluteFit, biasVsInterval: biasFit,
            verdict: responds ? .responds : .noResponseFound,
            headline: headline(spread: spreadFit, bias: biasFit), notes: notes)
    }

    // MARK: - What the data cannot support

    private static func whyNotEnoughRange(buckets: [IntervalBucket]) -> String? {
        let anchored = buckets.filter { $0.takes >= minimumTakesPerInterval }
        if anchored.count < minimumIntervals {
            let have = buckets.map { String(format: "%.0f ms×%d", $0.intervalMs, $0.takes) }
            return "\(minimumIntervals) intervals with at least "
                 + "\(minimumTakesPerInterval) takes each are needed; there are "
                 + "\(anchored.count) (\(have.joined(separator: ", "))). One take per tempo per "
                 + "sitting, rotated, gets there faster than several at one tempo."
        }
        return nil
    }

    private static func caveats(buckets: [IntervalBucket],
                                observations: [IntervalObservation]) -> [String] {
        var notes: [String] = []

        // An interval played only on one evening carries that evening with it. This is the
        // single-sitting confound from `ExperimentAnalysis`, arriving on a different axis.
        for bucket in buckets where bucket.takes > 1 && bucket.sittings == 1 {
            notes.append(String(format: "Every take at %.0f ms (%.0f BPM) comes from one sitting, "
                              + "so that interval carries whatever else was true of that evening "
                              + "— fatigue, the day, the room.",
                                bucket.intervalMs, bucket.bpm))
        }

        // Both forms are shown because which one is comparable is the open question, not a
        // settled premise. Reporting only one is how an assumption becomes a result.
        if buckets.count > 1 {
            notes.append("Spread is shown in milliseconds and as a percentage of the interval. "
                       + "If scatter grows with the interval, only the percentage compares "
                       + "across tempos; if it does not, only the milliseconds do. The intervals "
                       + "you actually produced, below, fit that question on notes rather than "
                       + "on takes and have far more of them to work with.")
        }
        return notes
    }

    /// Name which description of spread is flat, since exactly one of them should be.
    private static func invariantNote(relative: TrendFit?, absolute: TrendFit?) -> String {
        switch (absolute?.isReal, relative?.isReal) {
        case (false, true):
            return "Across these takes the millisecond spread is flat while the percentage "
                 + "moves, so milliseconds are what compares across tempos here."
        case (true, false):
            return "Across these takes the percentage is flat while the millisecond spread "
                 + "moves, so spread scales with the interval and percentages are what compare."
        case (true, true):
            return "Both the millisecond spread and the percentage move with the interval, so "
                 + "neither is a clean unit — something other than the interval is varying."
        default:
            return "Neither the millisecond spread nor the percentage is separable from noise "
                 + "across these takes, so this cannot yet say which unit compares."
        }
    }

    private static func headline(spread: TrendFit?, bias: TrendFit?) -> String {
        var parts: [String] = []
        if let spread, spread.isReal {
            parts.append(String(format: "relative spread %@ by %.2f points per 100 ms of interval",
                                spread.slope > 0 ? "grows" : "falls", abs(spread.slope) * 100))
        }
        if let bias, bias.isReal {
            parts.append(String(format: "placement moves %@ by %.1f ms per 100 ms of interval",
                                bias.slope < 0 ? "further ahead of the beat" : "later",
                                abs(bias.slope) * 100))
        }
        guard !parts.isEmpty else {
            return "Across the tempos played, neither precision nor placement moves with the "
                 + "interval by more than noise."
        }
        return "Tempo changes how you play: " + parts.joined(separator: ", and ") + "."
    }
}
