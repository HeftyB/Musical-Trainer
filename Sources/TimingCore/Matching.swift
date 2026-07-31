import Foundation

public enum Matching {
    /// Align taps to grid points.
    ///
    /// - Parameter windowFraction: half-width of a grid point's capture window, as a
    ///   fraction of the subdivision interval. Must be < 0.5 so adjacent windows do not
    ///   overlap. This is what defeats the sign-inversion trap of PLAN.md §5.3: a note 60%
    ///   of a subdivision late is outside every window and is recorded as an extra, rather
    ///   than snapping to the next grid point and being reported — wrongly — as early.
    public static func match(taps: [Tap], to grid: Grid, windowFraction: Double = 0.4) -> MatchResult {
        precondition(windowFraction > 0 && windowFraction < 0.5,
                     "windowFraction must be in (0, 0.5) to keep windows disjoint")
        let windowSec = windowFraction * grid.interval

        struct Candidate { let tap: Tap; let index: Int; let offsetSec: Double }
        var candidates: [Candidate] = []
        var extras: [Tap] = []

        for tap in taps {
            let index = grid.nearestIndex(to: tap.time)
            let offset = tap.time - grid.time(ofIndex: index)
            if abs(offset) <= windowSec {
                candidates.append(Candidate(tap: tap, index: index, offsetSec: offset))
            } else {
                extras.append(tap)
            }
        }

        // Resolve collisions: at most one tap per grid point. The closest wins; the rest
        // are extras. A single grid point with two note-ons is a double-trigger or a
        // grace note, not two beats, and averaging them would smear the measurement.
        var bestByIndex: [Int: Candidate] = [:]
        for candidate in candidates {
            if let existing = bestByIndex[candidate.index] {
                if abs(candidate.offsetSec) < abs(existing.offsetSec) {
                    bestByIndex[candidate.index] = candidate
                    extras.append(existing.tap)
                } else {
                    extras.append(candidate.tap)
                }
            } else {
                bestByIndex[candidate.index] = candidate
            }
        }

        let matched = bestByIndex.values
            .sorted { $0.index < $1.index }
            .map { MatchedTap(tap: $0.tap, gridIndex: $0.index, asynchronyMs: $0.offsetSec * 1000) }

        // Missed notes only count within the played span — grid points before the first
        // or after the last matched tap are simply outside the performance.
        var missed: [Int] = []
        if let lo = matched.first?.gridIndex, let hi = matched.last?.gridIndex {
            let present = Set(matched.map(\.gridIndex))
            missed = (lo...hi).filter { !present.contains($0) }
        }

        return MatchResult(matched: matched,
                           extraTaps: extras.sorted { $0.time < $1.time },
                           missedIndices: missed)
    }
}
