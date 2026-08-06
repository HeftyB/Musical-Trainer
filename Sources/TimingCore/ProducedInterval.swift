import Foundation

/// One matched note, keyed by how far it sat from the note before it.
///
/// The key is the gap in **grid steps**, an integer, converted to milliseconds by the grid.
/// That is load-bearing and it is the reason this type exists rather than a tuple of times.
/// A measured inter-onset interval is `gapSteps × interval + async − asyncOfPrevious`, so the
/// note's own asynchrony sits inside its own bin key: binning on it correlates the key with
/// the value and manufactures a slope out of nothing. The integer carries no asynchrony at all.
public struct ProducedNote: Equatable {
    /// Grid points since the previous matched note. Always ≥ 1.
    public let gapSteps: Int
    /// The gap in milliseconds, from the grid alone. Nominal, never measured.
    public let intervalMs: Double
    public let asynchronyMs: Double

    public init(gapSteps: Int, intervalMs: Double, asynchronyMs: Double) {
        self.gapSteps = gapSteps; self.intervalMs = intervalMs; self.asynchronyMs = asynchronyMs
    }
}

/// Every note played at one interval.
public struct ProducedIntervalBin: Equatable {
    public let intervalMs: Double
    public let notes: Int
    /// This bin's share of all matched notes, 0–1. How much of the ladder he actually visits.
    public let shareOfNotes: Double
    public let sdMs: Double
    public let meanMs: Double
    /// Spread as a percentage of the interval it sits inside.
    public var relativeSpreadPercent: Double { intervalMs > 0 ? sdMs / intervalMs * 100 : .nan }
}

/// Which description of this player's spread survives a change of interval.
///
/// The two are mutually exclusive and the difference decides real things: whether a rung's
/// tempo ceiling means anything, and whether raw milliseconds may be compared across takes
/// that were played at different note densities.
public enum SpreadInvariant: Equatable {
    /// Absolute spread does not move with the interval. Milliseconds are the comparable unit,
    /// and a matching window fixed in *fractions of the interval* really does tighten as the
    /// rung climbs — so tempo ceilings bind.
    case absolute
    /// Spread tracks the interval. Percentages are the comparable unit and the window is a
    /// constant number of spreads at every rung, so no ceiling ever binds.
    case relative
    /// Both slopes are separable from zero, or neither description fits.
    case neither
    /// Not enough distinct intervals, or not enough notes at them, to tell the two apart.
    case undetermined(reason: String)
}

public struct ProducedIntervalProfile: Equatable {
    public let bins: [ProducedIntervalBin]
    public let totalNotes: Int
    /// Absolute SD against interval, ms of spread per ms of interval. Flat ⇒ `.absolute`.
    public let absoluteFit: TrendFit?
    /// Relative SD against interval, points per ms of interval. Flat ⇒ `.relative`.
    public let relativeFit: TrendFit?
    /// Mean asynchrony against interval — "the longer the gap, the further ahead I sit".
    ///
    /// The note-level form of §7.23's rushing claim, and the reason the bin key must be the grid
    /// gap: binning on a measured inter-onset interval conditions on `async − asyncOfPrevious`,
    /// which pins each bin's mean at half its own offset and fabricates a slope of about +0.5
    /// out of a player whose placement never moved. Spread survives that mistake; placement does
    /// not, so this is the row it would have destroyed.
    public let placementFit: TrendFit?
    public let invariant: SpreadInvariant
    public let headline: String
    public let notes: [String]
}

/// What intervals does this player actually produce, and does his spread move with them?
///
/// This is the question underneath both of M14's open decisions, and until it was measured both
/// were being argued from an assumption. §7.23 asserts that scatter grows with the interval it
/// sits inside — the premise for normalising spread by the interval (step 3) and the premise
/// this player's tempo ceilings deny (step 1). They cannot both be right, and the takes on disk
/// can say which.
///
/// **The unit here is the note, not the take**, which is the opposite of `ExperimentAnalysis`
/// and deliberately so. The question is about a property *within* a performance — does a note
/// played 300 ms after the last one scatter differently from one played 600 ms after — and
/// every take contains both. Aggregating to per-take values first would throw away exactly the
/// contrast being measured.
public enum ProducedIntervalAnalysis {

    /// A bin with fewer notes than this is not a spread estimate, it is a handful of notes.
    public static let minimumNotesPerBin = 30
    /// Below this many usable bins there is no axis, only a cluster.
    public static let minimumBins = 3

    /// Turn one take's matched notes into interval-keyed observations.
    ///
    /// Consecutive *matched* notes, so an off-grid note does not split a run — it is absent
    /// from the series entirely, and the gap spans it. That is the honest reading: the analysis
    /// never saw where it was aimed.
    public static func notes(from matched: [MatchedTap], grid: Grid) -> [ProducedNote] {
        let ordered = matched.sorted { $0.gridIndex < $1.gridIndex }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, note in
            let gap = note.gridIndex - previous.gridIndex
            guard gap >= 1 else { return nil }
            // The distance between the two grid points, asked of the grid rather than computed
            // as steps × a single spacing. Under a feel there is no single spacing, and the gap
            // between a downbeat and a swung offbeat is not the gap between that offbeat and
            // the next downbeat — this is one of the two places that assumption was buried.
            let spanMs = (grid.time(ofIndex: note.gridIndex)
                        - grid.time(ofIndex: previous.gridIndex)) * 1000
            return ProducedNote(gapSteps: gap, intervalMs: spanMs,
                                asynchronyMs: note.asynchronyMs)
        }
    }

    public static func analyze(_ played: [ProducedNote],
                               windowFraction: Double = Matching.defaultWindowFraction,
                               iterations: Int = 2000,
                               seed: UInt64 = 0x1A7E) -> ProducedIntervalProfile {
        let usable = played.filter { $0.intervalMs.isFinite && $0.asynchronyMs.isFinite }
        let total = usable.count
        let grouped = Dictionary(grouping: usable) { $0.intervalMs.rounded() }

        let bins = grouped.keys.sorted().compactMap { interval -> ProducedIntervalBin? in
            let values = (grouped[interval] ?? []).map(\.asynchronyMs)
            guard values.count >= minimumNotesPerBin else { return nil }
            return ProducedIntervalBin(
                intervalMs: interval, notes: values.count,
                shareOfNotes: total > 0 ? Double(values.count) / Double(total) : 0,
                sdMs: Stats.sd(values), meanMs: Stats.mean(values))
        }

        var notes = caveats(bins: bins, total: total, grouped: grouped,
                            windowFraction: windowFraction)

        guard bins.count >= minimumBins else {
            let reason = "\(minimumBins) intervals with at least \(minimumNotesPerBin) notes "
                       + "each are needed; there are \(bins.count)."
            return ProducedIntervalProfile(
                bins: bins, totalNotes: total, absoluteFit: nil, relativeFit: nil,
                placementFit: nil, invariant: .undetermined(reason: reason),
                headline: "Not enough spread in the intervals played to say which description "
                        + "of spread survives a change of interval. \(reason)",
                notes: notes)
        }

        let x = bins.map(\.intervalMs)
        // `lowerIsBetter` is meaningless for both fits — neither slope has a good direction,
        // and only `isReal` is read. Passed as true because the parameter is not optional.
        let absolute = TrendAnalysis.fit(x: x, y: bins.map(\.sdMs), lowerIsBetter: true,
                                         iterations: iterations, seed: seed)
        let relative = TrendAnalysis.fit(x: x, y: bins.map(\.relativeSpreadPercent),
                                         lowerIsBetter: true, iterations: iterations, seed: seed)
        let placement = TrendAnalysis.fit(x: x, y: bins.map(\.meanMs), lowerIsBetter: true,
                                          iterations: iterations, seed: seed)

        let invariant = verdict(absolute: absolute, relative: relative)
        if case .neither = invariant {
            notes.append("Neither description held, which usually means the bins disagree for a "
                       + "reason other than the interval — different passages, different "
                       + "material — rather than that both slopes are real.")
        }
        if let placement, placement.isReal {
            notes.append(String(format: "Placement moves with the interval too: %+.2f ms per "
                              + "100 ms of gap, %@ the beat as the notes spread out. That is "
                              + "the note-level form of \"slow tempos make me rush\", and it is "
                              + "within one take rather than across tempos.",
                                placement.slope * 100,
                                placement.slope < 0 ? "further ahead of" : "later against"))
        }
        return ProducedIntervalProfile(
            bins: bins, totalNotes: total, absoluteFit: absolute, relativeFit: relative,
            placementFit: placement, invariant: invariant,
            headline: headline(invariant: invariant, bins: bins, absolute: absolute),
            notes: notes)
    }

    // MARK: - Which description survives

    /// Flat in absolute terms and sloped in relative terms means milliseconds are the invariant,
    /// and the reverse means percentages are. Both flat is a power problem, not a finding.
    private static func verdict(absolute: TrendFit?, relative: TrendFit?) -> SpreadInvariant {
        guard let absolute, let relative else {
            return .undetermined(reason: "Not enough bins to fit either description.")
        }
        switch (absolute.isReal, relative.isReal) {
        case (false, true):  return .absolute
        case (true, false):  return .relative
        case (false, false):
            return .undetermined(reason: "Neither slope is separable from zero, so the two "
                                       + "descriptions cannot be told apart at this sample size.")
        case (true, true):   return .neither
        }
    }

    private static func caveats(bins: [ProducedIntervalBin], total: Int,
                                grouped: [Double: [ProducedNote]],
                                windowFraction: Double) -> [String] {
        var notes: [String] = []

        // Every bin is censored at the same matching window, so the *comparison* is fair — but
        // every SD is understated, and saying how badly is the difference between a caveat and
        // a footnote. Censoring compresses; it cannot invert an ordering, which is why a flat
        // result survives it and a scaling one would still show as scaling.
        if let widest = bins.map(\.sdMs).max(), widest > 0,
           let smallest = bins.map(\.intervalMs).min() {
            let windowMs = smallest * windowFraction
            let inSpreads = windowMs / widest
            if inSpreads < IntervalRung.minimumWindowInSpreads {
                notes.append(String(format: "Every spread here is understated: the matching "
                                  + "window at the shortest interval is %.0f ms, only %.1f of "
                                  + "the widest bin's spread, so the tails are cut off. It cuts "
                                  + "every bin the same way, so the comparison stands — but the "
                                  + "absolute figures are floors, not estimates.",
                                    windowMs, inSpreads))
            }
        }

        // A bin dropped for thinness is not the same as an interval never played, and the
        // difference matters when the question is which rungs he has ever visited.
        let dropped = grouped.filter { $0.value.count < minimumNotesPerBin }
        if !dropped.isEmpty {
            let sample = dropped.keys.sorted().prefix(6)
                .map { String(format: "%.0f ms", $0) }.joined(separator: ", ")
            notes.append("\(dropped.count) interval(s) had fewer than \(minimumNotesPerBin) "
                       + "notes and are not fitted (\(sample)). They are intervals he touches "
                       + "rather than plays.")
        }

        // Each bin is one point in the fit however many notes it holds, so a bin scraping past
        // the threshold has the same leverage as one with a hundred times the notes. Stated
        // rather than fixed with weights: the lever is `minimumNotesPerBin`, and a reader who
        // knows a thin bin is pulling the line can raise it and look again.
        if let fattest = bins.map(\.notes).max(), let thinnest = bins.map(\.notes).min(),
           thinnest > 0, fattest >= thinnest * 10 {
            notes.append("The bins are very unequal — \(thinnest) notes in the smallest against "
                       + "\(fattest) in the largest — and each is one point in the fit whatever "
                       + "it holds. A thin bin pulls the line as hard as a fat one.")
        }

        // The concentration itself is the finding people miss.
        if let dominant = bins.max(by: { $0.shareOfNotes < $1.shareOfNotes }),
           dominant.shareOfNotes >= 0.6 {
            notes.append(String(format: "%.0f%% of all matched notes sit at one interval "
                              + "(%.0f ms). Every figure this project quotes as \"his spread\" "
                              + "is therefore about that interval and not about playing in "
                              + "general.", dominant.shareOfNotes * 100, dominant.intervalMs))
        }
        return notes
    }

    private static func headline(invariant: SpreadInvariant, bins: [ProducedIntervalBin],
                                 absolute: TrendFit?) -> String {
        switch invariant {
        case .absolute:
            let range = bins.map(\.intervalMs)
            return String(format: "Your spread does not move with the interval — about the same "
                        + "milliseconds whether the notes are %.0f ms apart or %.0f ms apart. "
                        + "Milliseconds are the unit that compares; percentages are not.",
                          range.min() ?? 0, range.max() ?? 0)
        case .relative:
            return "Your spread tracks the interval: the wider the gap, the wider the scatter, "
                 + "in proportion. Percentages of the interval are the unit that compares."
        case .neither:
            return "Spread moves with the interval, but not in proportion to it — neither "
                 + "milliseconds nor percentages describe it on their own."
        case .undetermined(let reason):
            return "Not enough spread in the intervals played to say. \(reason)"
        }
    }
}
