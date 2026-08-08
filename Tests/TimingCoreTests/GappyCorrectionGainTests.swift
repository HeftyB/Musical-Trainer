import XCTest
import TestSupport
@testable import TimingCore

/// r₁ pairs notes that follow one another, not notes that happen to be next in a list.
///
/// The correction gain asks *did the last error predict this one*, which presumes the second note
/// is close enough to be a response to the first. A plain autocorrelation pairs element *n* with
/// *n+1* and asks nothing about what sat between them — so two notes either side of four beats of
/// silence were treated as adjacent. The free jam now invites exactly that playing: mixed note
/// values and deliberate breaks.
///
/// Same shape as §7.25, where a gap broke the x-axis a slope was fitted against, and the same fix
/// — split at the gap, and report what was dropped. See PLAN.md §7.32.
final class GappyCorrectionGainTests: XCTestCase {

    /// A series whose lag-1 correlation is planted by construction: each value carries `rho` of
    /// the one before it plus independent noise.
    private func ar1(_ n: Int, rho: Double, seed: UInt64 = 7) -> [Double] {
        var rng = SplitMix64(seed: seed)
        func gauss() -> Double {
            // Box–Muller from the project's own seeded generator, so the fixture is deterministic
            // (R5.4) rather than pulled from the system RNG.
            let u1 = Double(rng.next() % 1_000_000 + 1) / 1_000_001
            let u2 = Double(rng.next() % 1_000_000) / 1_000_000
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
        var out: [Double] = []
        var v = gauss()
        for _ in 0..<n {
            v = rho * v + (1 - rho * rho).squareRoot() * gauss()
            out.append(v)
        }
        return out
    }

    /// Contiguous input must give what it always gave, or this is a different statistic wearing
    /// the same name.
    func testAContiguousSeriesMatchesThePlainAutocorrelation() throws {
        let x = ar1(400, rho: 0.5)
        let plain = try XCTUnwrap(Stats.autocorrelation(x, lag: 1))
        let gappy = try XCTUnwrap(Stats.gappyLag1(x) { _ in true })
        XCTAssertEqual(try XCTUnwrap(gappy.r), plain, accuracy: 0.02)
        XCTAssertEqual(gappy.pairs, x.count - 1)
        XCTAssertEqual(gappy.dropped, 0)
    }

    /// **The defect, planted.** Twenty runs of ten notes, each with *no* within-run correlation at
    /// all but its own placement offset — a player who re-enters after each rest sitting somewhere
    /// slightly different, and corrects nothing in between.
    ///
    /// The naive figure reads that block structure as correction. The honest one reports what the
    /// player actually did between consecutive notes, which is nothing.
    ///
    /// A single seam in four hundred notes would move nothing and testing one would prove nothing;
    /// what makes the defect bite is many runs, or a level difference across them, and this is
    /// both.
    func testRunsAtDifferentPlacementsAreNotCorrection() throws {
        var rng = SplitMix64(seed: 4242)
        var spliced: [Double] = []
        var seams: Set<Int> = []
        for run in 0..<8 {
            // Alternating offsets: ahead of the beat, then behind it, then ahead again.
            let offset = run % 2 == 0 ? -18.0 : 18.0
            for _ in 0..<50 {
                spliced.append(offset + Double(rng.next() % 1000) / 1000 * 6 - 3)
            }
            if run < 7 { seams.insert(spliced.count - 1) }
        }

        let naive = try XCTUnwrap(Stats.autocorrelation(spliced, lag: 1))
        let honest = try XCTUnwrap(Stats.gappyLag1(spliced) { !seams.contains($0) })

        XCTAssertEqual(honest.dropped, 7)
        XCTAssertGreaterThan(naive, 0.7,
                             "the block structure alone should read as strong correction: \(naive)")
        XCTAssertEqual(try XCTUnwrap(honest.r), 0.0, accuracy: 0.08,
                       "within a run the player corrected nothing, and that is what r₁ must say; "
                     + "got \(honest.r)")
    }

    /// Centring per run is what makes the case above work, so it gets its own assertion: two runs
    /// that are each internally steady but sit at different placements are not one correlated
    /// series. Against a global mean this reads near +1.
    func testALevelShiftBetweenRunsIsNotCorrelation() throws {
        let ahead = (0..<40).map { $0 % 2 == 0 ? -21.0 : -19.0 }
        let behind = (0..<40).map { $0 % 2 == 0 ? 21.0 : 19.0 }
        let spliced = ahead + behind
        let seam = ahead.count - 1

        let naive = try XCTUnwrap(Stats.autocorrelation(spliced, lag: 1))
        let honest = try XCTUnwrap(Stats.gappyLag1(spliced) { $0 != seam })

        XCTAssertGreaterThan(naive, 0.8, "a global mean turns the step into correlation: \(naive)")
        XCTAssertLessThan(try XCTUnwrap(honest.r), 0.0,
                          "each run alternates about its own mean, which is anticorrelation, not "
                        + "the +1 a global centre invents: \(honest.r)")
    }

    /// Dropping adjacencies must not shrink the estimate in proportion to how many were dropped —
    /// which is what dividing by `n` instead of by the surviving pair count would do, and is the
    /// same attenuation the moving-block bootstrap suffers from.
    func testDroppingPairsDoesNotAttenuateTheEstimate() throws {
        let x = ar1(600, rho: 0.55)
        let all = try XCTUnwrap(Stats.gappyLag1(x) { _ in true })
        // Five seams, so six runs of a hundred: the products drop, the estimate must not.
        let thinned = try XCTUnwrap(Stats.gappyLag1(x) { ($0 + 1) % 100 != 0 })
        XCTAssertEqual(thinned.dropped, 5)
        XCTAssertEqual(try XCTUnwrap(thinned.r), try XCTUnwrap(all.r), accuracy: 0.05,
                       "all \(all.r) against thinned \(thinned.r)")
    }

    func testAFlatOrTooShortSeriesWithholdsRatherThanReturningZero() {
        XCTAssertNil(Stats.gappyLag1([]) { _ in true })
        XCTAssertNil(Stats.gappyLag1([1.0]) { _ in true })
        XCTAssertNil(Stats.gappyLag1([2.0, 2.0, 2.0]) { _ in true }?.r, "a flat series has no r₁")
        XCTAssertNil(Stats.gappyLag1([1.0, 2.0, 3.0]) { _ in false }?.r,
                     "nothing adjacent means nothing to report — R3.3.1, withhold at source")
    }

    /// **A take played in short bursts reports no correction gain at all**, which is the honest
    /// answer rather than a number biased toward the very thing §10 calls success. Centring a run
    /// on its own mean costs about `1/n`, and that bias points at r₁ ≈ 0.
    func testNoRunLongEnoughMeansNoNumber() throws {
        let x = ar1(200, rho: 0.5)
        // Every tenth adjacency broken: twenty runs of ten, all under the floor.
        XCTAssertNil(Stats.gappyLag1(x) { ($0 + 1) % 10 != 0 }?.r,
                     "runs of ten carry roughly −0.11 of bias; a number is worse than a gap")
        // One long run among them is enough to answer from.
        let mixed = try XCTUnwrap(Stats.gappyLag1(x) { $0 != 40 && ($0 < 60 || ($0 + 1) % 10 != 0) })
        XCTAssertGreaterThan(mixed.pairs, 30)
    }

    // MARK: - Through the report

    /// A beat is the threshold, because the beat is the pulse being tracked and 78.4% of every
    /// matched note in a free jam sits one beat from the last. Eighths and sixteenths are a
    /// stream and pair normally; a bar of rest is not.
    func testTheReportPairsAcrossSubdivisionsButNotAcrossARest() throws {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)

        // Sixteenths, eighths and quarters in one stream: every gap is at most a beat.
        let dense = [0, 1, 2, 3, 4, 6, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44]
        let denseTaps = dense.map { Tap(time: grid.time(ofIndex: $0) + 0.004) }
        let denseReport = TimingAnalysis.analyze(taps: denseTaps, grid: grid)
        XCTAssertEqual(denseReport.lag1DroppedPairs, 0,
                       "mixed note values are one stream, not a series of gaps")

        // The same playing with two bars of silence in the middle of it.
        let withRest = [0, 1, 2, 3, 4, 6, 8, 12] + [64, 68, 72, 76, 80, 84, 88, 92]
        let restTaps = withRest.map { Tap(time: grid.time(ofIndex: $0) + 0.004) }
        let restReport = TimingAnalysis.analyze(taps: restTaps, grid: grid)
        XCTAssertEqual(restReport.lag1DroppedPairs, 1, "exactly one adjacency spans the rest")
        XCTAssertNil(restReport.lag1Autocorrelation,
                     "and neither run is long enough to answer from, so nothing is claimed")
    }
}
