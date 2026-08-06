import XCTest
@testable import TimingCore
import TestSupport

/// M14 step 3b: which description of spread survives a change of interval?
///
/// §7.23 asserts that scatter grows with the interval it sits inside. Step 3 normalises by the
/// interval on that basis; step 1 derives tempo ceilings that only bind if the opposite is
/// true. The two premises contradict each other, so the analysis must be able to recover
/// either from planted data rather than assuming one.
final class ProducedIntervalTests: XCTestCase {

    /// Build notes at a fixed interval with a planted spread.
    private func planted(intervalMs: Double, sdMs: Double, count: Int,
                         seed: UInt64) -> [ProducedNote] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in
            ProducedNote(gapSteps: 1, intervalMs: intervalMs,
                         asynchronyMs: rng.gaussian(sd: sdMs))
        }
    }

    // MARK: - The two descriptions, planted and recovered

    /// A player whose scatter is a fixed number of milliseconds at every interval.
    func testConstantMillisecondSpreadIsReportedAsTheAbsoluteInvariant() {
        var played: [ProducedNote] = []
        for (i, interval) in [150.0, 300, 600, 1200].enumerated() {
            played += planted(intervalMs: interval, sdMs: 20, count: 400, seed: 90 + UInt64(i))
        }
        let profile = ProducedIntervalAnalysis.analyze(played, windowFraction: 10)

        XCTAssertEqual(profile.invariant, .absolute)
        XCTAssertEqual(profile.absoluteFit?.isReal, false, "milliseconds must come out flat")
        XCTAssertEqual(profile.relativeFit?.isReal, true,
                       "the same player must look like a strong trend in percentage terms")
        for bin in profile.bins {
            XCTAssertEqual(bin.sdMs, 20, accuracy: 3, "\(bin.intervalMs) ms")
        }
    }

    /// A player whose scatter is a fixed *fraction* of the interval. This is the premise §7.23
    /// states as fact, and the analysis has to be able to find it when it is there.
    func testProportionalSpreadIsReportedAsTheRelativeInvariant() {
        var played: [ProducedNote] = []
        for (i, interval) in [150.0, 300, 600, 1200].enumerated() {
            played += planted(intervalMs: interval, sdMs: interval * 0.04, count: 400,
                              seed: 200 + UInt64(i))
        }
        let profile = ProducedIntervalAnalysis.analyze(played, windowFraction: 10)

        XCTAssertEqual(profile.invariant, .relative)
        XCTAssertEqual(profile.relativeFit?.isReal, false, "percentages must come out flat")
        XCTAssertEqual(profile.absoluteFit?.isReal, true)
        for bin in profile.bins {
            XCTAssertEqual(bin.relativeSpreadPercent, 4, accuracy: 0.6, "\(bin.intervalMs) ms")
        }
    }

    // MARK: - The binning key

    /// **The key must be the grid gap, never the measured inter-onset interval** — and what it
    /// would wreck is placement, not spread.
    ///
    /// A measured IOI is `gap × interval + async − asyncOfPrevious`, so a note's own asynchrony
    /// sits inside its own bin key. Conditioning on that difference being `d` leaves the
    /// within-bin spread almost untouched but pins the within-bin *mean* at `d/2` — so the
    /// mistake is invisible in the spread rows and fabricates a placement slope of about +0.5
    /// ms per ms out of a player whose placement never moved once.
    ///
    /// That is the more dangerous failure of the two, because a placement slope against the
    /// interval is exactly the "slow tempos make me rush" claim §7.23 wants to test. A first
    /// version of this test asserted the artefact would show up in spread; it does not, and the
    /// assertion failing is what found the real shape.
    func testBinningOnMeasuredIntervalWouldFabricateAPlacementSlope() throws {
        var rng = SeededRNG(seed: 4242)
        let nominal = 600.0
        let asynchronies = (0..<4000).map { _ in rng.gaussian(sd: 25) }

        // What the analysis does: one grid gap, so one bin, so no slope is even fittable.
        let honest = asynchronies.map {
            ProducedNote(gapSteps: 1, intervalMs: nominal, asynchronyMs: $0)
        }
        let honestProfile = ProducedIntervalAnalysis.analyze(honest, windowFraction: 10)
        XCTAssertEqual(honestProfile.bins.count, 1, "one interval was played, so one bin")
        XCTAssertNil(honestProfile.placementFit, "nothing to fit through a single bin")

        // What binning on the measured gap would do to those very same notes.
        var measured: [ProducedNote] = []
        for (previous, async) in zip(asynchronies, asynchronies.dropFirst()) {
            let ioi = nominal + async - previous
            measured.append(ProducedNote(gapSteps: 1, intervalMs: (ioi / 25).rounded() * 25,
                                         asynchronyMs: async))
        }
        let fake = ProducedIntervalAnalysis.analyze(measured, windowFraction: 10)

        XCTAssertGreaterThanOrEqual(fake.bins.count, ProducedIntervalAnalysis.minimumBins,
                                    "the artefact needs several bins to show up")
        let fabricated = try XCTUnwrap(fake.placementFit)
        XCTAssertTrue(fabricated.isReal,
                      "binning on the measured interval invents a placement slope from a player "
                    + "whose placement is constant")
        XCTAssertEqual(fabricated.slope, 0.5, accuracy: 0.15,
                       "conditioning on the difference pins each bin's mean at half its offset")

        // And it hides in plain sight: the spread rows look perfectly innocent.
        XCTAssertEqual(fake.absoluteFit?.isReal, false,
                       "the spread fit does not notice, which is why this needs its own test")
    }

    // MARK: - Refusals

    func testTooFewDistinctIntervalsIsARefusalRatherThanAFit() {
        let played = planted(intervalMs: 600, sdMs: 20, count: 500, seed: 7)
            + planted(intervalMs: 300, sdMs: 20, count: 500, seed: 8)
        let profile = ProducedIntervalAnalysis.analyze(played, windowFraction: 10)

        guard case .undetermined = profile.invariant else {
            return XCTFail("two intervals is a cluster, not an axis: \(profile.invariant)")
        }
        XCTAssertNil(profile.absoluteFit)
        XCTAssertNil(profile.relativeFit)
    }

    /// A handful of notes at an interval is not a spread estimate, and must not become a point
    /// on a line — one thin bin is all it takes to swing a four-point fit.
    func testThinIntervalsAreExcludedFromTheFitAndNamed() {
        var played = planted(intervalMs: 600, sdMs: 20, count: 400, seed: 11)
        played += planted(intervalMs: 300, sdMs: 20, count: 400, seed: 12)
        played += planted(intervalMs: 1200, sdMs: 20, count: 400, seed: 13)
        played += planted(intervalMs: 450, sdMs: 90, count: 5, seed: 14)

        let profile = ProducedIntervalAnalysis.analyze(played, windowFraction: 10)
        XCTAssertFalse(profile.bins.contains { $0.intervalMs == 450 })
        XCTAssertTrue(profile.notes.contains { $0.contains("450 ms") },
                      "a dropped interval is named, not silently absent: \(profile.notes)")
    }

    // MARK: - Caveats that decide how the numbers are read

    /// Censoring is equal across bins, so the comparison stands — but every SD is a floor and
    /// the report has to say so, or the absolute figures read as estimates.
    func testCensoringByTheMatchingWindowIsStated() {
        var played: [ProducedNote] = []
        for (i, interval) in [150.0, 300, 600].enumerated() {
            played += planted(intervalMs: interval, sdMs: 25, count: 400, seed: 300 + UInt64(i))
        }
        let profile = ProducedIntervalAnalysis.analyze(played)
        XCTAssertTrue(profile.notes.contains { $0.contains("understated") },
                      "the window is 60 ms against a 25 ms spread: \(profile.notes)")
    }

    /// The concentration is the finding people miss: if nearly every note sits at one interval,
    /// "his spread" is a statement about that interval alone.
    func testADominantIntervalIsCalledOut() {
        var played = planted(intervalMs: 600, sdMs: 20, count: 3000, seed: 21)
        played += planted(intervalMs: 300, sdMs: 20, count: 200, seed: 22)
        played += planted(intervalMs: 1200, sdMs: 20, count: 200, seed: 23)

        let profile = ProducedIntervalAnalysis.analyze(played, windowFraction: 10)
        XCTAssertTrue(profile.notes.contains { $0.contains("600 ms") && $0.contains("%") },
                      "\(profile.notes)")
    }

    // MARK: - Deriving notes from a take

    func testGapsComeFromGridIndicesAndSpanOffGridNotes() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)     // 150 ms per point
        let matched = [0, 4, 8, 10].map {
            MatchedTap(tap: Tap(time: grid.time(ofIndex: $0)),
                       gridIndex: $0, asynchronyMs: 0)
        }
        let played = ProducedIntervalAnalysis.notes(from: matched, grid: grid)

        XCTAssertEqual(played.map(\.gapSteps), [4, 4, 2])
        // The span is asked of the grid rather than computed as steps × one spacing, because
        // under a feel there is no one spacing — so it carries float rounding that the old
        // multiplication did not. Bins are keyed on the rounded value, so nothing downstream
        // moves; exact equality here would only be pinning the arithmetic's shape.
        for (actual, expected) in zip(played.map(\.intervalMs), [600.0, 600, 300]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
    }

    /// Two notes on the same grid point cannot happen after matching, but the reduction must not
    /// produce a zero or negative gap if it ever did.
    func testANonPositiveGapIsDropped() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)
        let matched = [4, 4].map {
            MatchedTap(tap: Tap(time: 0),
                       gridIndex: $0, asynchronyMs: 0)
        }
        XCTAssertTrue(ProducedIntervalAnalysis.notes(from: matched, grid: grid).isEmpty)
    }
}
