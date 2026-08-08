import XCTest
import TestSupport
@testable import TimingCore

final class BootstrapTests: XCTestCase {
    /// The shared generator, so a change to how synthetic players are built reaches every
    /// suite rather than this file alone.
    private func gaussianSeries(n: Int, mean: Double, sd: Double, seed: UInt64) -> [Double] {
        Generators.series(n: n, mean: mean, sd: sd, seed: seed)
    }

    func testIntervalBracketsThePointEstimate() {
        let x = gaussianSeries(n: 300, mean: -10, sd: 6, seed: 1)
        let ci = Bootstrap.interval(x, statistic: .mean)!
        XCTAssertLessThan(ci.low, ci.point)
        XCTAssertGreaterThan(ci.high, ci.point)
        // The true mean (−10) should sit inside a 95% CI from 300 points.
        XCTAssertLessThan(ci.low, -10)
        XCTAssertGreaterThan(ci.high, -10)
    }

    func testDeterministicForSameData() {
        let x = gaussianSeries(n: 200, mean: 0, sd: 5, seed: 2)
        let a = Bootstrap.interval(x, statistic: .sd)!
        let b = Bootstrap.interval(x, statistic: .sd)!
        XCTAssertEqual(a, b)
    }

    func testDifferenceDetectsARealShift() {
        let a = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 3)
        let b = gaussianSeries(n: 250, mean: 20, sd: 6, seed: 4)   // clearly different mean
        let diff = Bootstrap.difference(a, b, statistic: .mean)!
        XCTAssertTrue(diff.excludesZero, "a 20 ms mean gap should be detected as real")
        XCTAssertLessThan(diff.high, 0)   // mean(a) − mean(b) ≈ −20
    }

    func testDifferenceCallsNoiseNoise() {
        // Two samples from the *same* distribution: the difference CI should straddle zero.
        let a = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 5)
        let b = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 6)
        let diff = Bootstrap.difference(a, b, statistic: .mean)!
        XCTAssertFalse(diff.excludesZero, "no real difference should not be flagged as significant")
    }

    func testPooledDifferenceDetectsARealConditionEffect() {
        // Three takes per condition; condition B is 8 ms wider throughout.
        let a = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 12, seed: UInt64(10 + $0)) }
        let b = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 20, seed: UInt64(20 + $0)) }
        let diff = Bootstrap.pooledDifference(b, a, statistic: .sd)!
        XCTAssertTrue(diff.excludesZero, "a consistent 8 ms spread difference should be detected")
        XCTAssertGreaterThan(diff.point, 0)
    }

    /// Six takes per condition, not three, and the reason is the finding.
    ///
    /// At three the outer stage has three distinct clusters to draw from, so its interval is a
    /// handful of steps rather than a curve and a chance difference between the two triples can
    /// come out "real". This test asserted that at three takes and passed only on the seeds it
    /// happened to use; the shared generator changed them and it failed. That is what
    /// `Bootstrap.stableIntervalTakes` is for, and why `review conditions` says a group below it
    /// is coarsely estimated.
    func testPooledDifferenceCallsNoiseNoise() {
        let takes = Bootstrap.stableIntervalTakes + 2
        let a = (0..<takes).map { gaussianSeries(n: 120, mean: 0, sd: 14, seed: UInt64(30 + $0)) }
        let b = (0..<takes).map { gaussianSeries(n: 120, mean: 0, sd: 14, seed: UInt64(40 + $0)) }
        let diff = Bootstrap.pooledDifference(a, b, statistic: .sd)!
        XCTAssertFalse(diff.excludesZero)
    }

    func testPooledIntervalIgnoresTooShortTakes() {
        let a = gaussianSeries(n: 100, mean: 5, sd: 4, seed: 50)
        let b = gaussianSeries(n: 100, mean: 5, sd: 4, seed: 51)
        let ci = Bootstrap.pooledInterval([a, [1, 2, 3], b], statistic: .mean)
        XCTAssertNotNil(ci)
        // The 3-point take is discarded, so the estimate reflects only the two usable ones.
        XCTAssertEqual(ci!.point, Stats.mean(a + b), accuracy: 1e-9)
    }

    // MARK: - The two-stage (cluster) resample
    //
    // These are the tests for the defect in PLAN.md §7.20 finding 1: the pooled bootstrap used
    // to resample blocks *within* takes and never resample the takes themselves, so every
    // iteration carried each take's own fixed mean and the interval could not see between-take
    // variation at all.

    func testPooledIntervalWidensWhenTakesDisagreeWithEachOther() {
        // Same within-take spread on both sides; only the take-to-take agreement differs.
        let agreeing = (0..<4).map { gaussianSeries(n: 120, mean: 0, sd: 6, seed: UInt64(60 + $0)) }
        let disagreeing = (0..<4).map { i -> [Double] in
            let offsets = [-20.0, -6, 6, 20]
            return gaussianSeries(n: 120, mean: offsets[i], sd: 6, seed: UInt64(70 + i))
        }
        let tight = Bootstrap.pooledInterval(agreeing, statistic: .mean)!
        let wide = Bootstrap.pooledInterval(disagreeing, statistic: .mean)!

        // Under the old within-take-only resample these two came out at almost the same width,
        // because the take means were frozen across iterations either way.
        XCTAssertGreaterThan(wide.margin, tight.margin * 3,
                             "takes that disagree must produce a much wider pooled interval")
    }

    func testPooledDifferenceDoesNotCallOneOddEveningARealChange() {
        // Both conditions are drawn from the same underlying distribution. A alone happens to
        // contain one evening 24 ms adrift — the kind of shift §7.19 measured between two
        // benchmark jams a day apart, with nothing varying but the player.
        //
        // The grand means differ by ~6 ms, which the old bootstrap reported as a real change
        // with an interval well clear of zero: with take means frozen, its only uncertainty
        // came from resampling ~480 events, and that is a fraction of a millisecond.
        let a = [0.0, 0, 0, 24].enumerated().map {
            gaussianSeries(n: 120, mean: $0.element, sd: 6, seed: UInt64(80 + $0.offset))
        }
        let b = (0..<4).map { gaussianSeries(n: 120, mean: 0, sd: 6, seed: UInt64(90 + $0)) }

        let diff = Bootstrap.pooledDifference(a, b, statistic: .mean)!
        XCTAssertGreaterThan(diff.point, 3, "the point estimate really is offset by one evening")
        XCTAssertFalse(diff.excludesZero,
                       "one odd evening out of four is between-take noise, not a condition effect")
    }

    func testPooledIntervalRefusesASingleTake() {
        let only = gaussianSeries(n: 200, mean: 5, sd: 4, seed: 100)
        XCTAssertNil(Bootstrap.pooledInterval([only], statistic: .mean),
                     "one take cannot support an interval about takes")
        XCTAssertNil(Bootstrap.pooledDifference([only], [only], statistic: .mean))
    }

    func testPooledIntervalStillRecoversAPlantedMean() {
        // The fix widens the interval; it must not move the estimate or lose the truth.
        let takes = (0..<5).map { gaussianSeries(n: 150, mean: -12, sd: 7, seed: UInt64(110 + $0)) }
        let ci = Bootstrap.pooledInterval(takes, statistic: .mean)!
        XCTAssertEqual(ci.point, Stats.mean(takes.flatMap { $0 }), accuracy: 1e-9)
        XCTAssertLessThan(ci.low, -12)
        XCTAssertGreaterThan(ci.high, -12)
    }

    func testPooledIntervalIsDeterministic() {
        let takes = (0..<3).map { gaussianSeries(n: 120, mean: 2, sd: 5, seed: UInt64(120 + $0)) }
        XCTAssertEqual(Bootstrap.pooledInterval(takes, statistic: .sd),
                       Bootstrap.pooledInterval(takes, statistic: .sd))
    }

    func testBlockResamplePreservesLength() {
        var rng = SplitMix64(seed: 7)
        let x = Array(0..<100).map(Double.init)
        XCTAssertEqual(Bootstrap.blockResample(x, blockLength: 5, using: &rng).count, 100)
    }
}
