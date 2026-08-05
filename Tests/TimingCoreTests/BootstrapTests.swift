import XCTest
@testable import TimingCore

final class BootstrapTests: XCTestCase {
    private func gaussianSeries(n: Int, mean: Double, sd: Double, seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        func u() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }
        return (0..<n).map { _ in
            let u1 = Swift.max(u(), 1e-12), u2 = u()
            return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    func testIntervalBracketsThePointEstimate() {
        let x = gaussianSeries(n: 300, mean: -10, sd: 6, seed: 1)
        let ci = Bootstrap.interval(x, statistic: Bootstrap.meanStat)!
        XCTAssertLessThan(ci.low, ci.point)
        XCTAssertGreaterThan(ci.high, ci.point)
        // The true mean (−10) should sit inside a 95% CI from 300 points.
        XCTAssertLessThan(ci.low, -10)
        XCTAssertGreaterThan(ci.high, -10)
    }

    func testDeterministicForSameData() {
        let x = gaussianSeries(n: 200, mean: 0, sd: 5, seed: 2)
        let a = Bootstrap.interval(x, statistic: Bootstrap.sdStat)!
        let b = Bootstrap.interval(x, statistic: Bootstrap.sdStat)!
        XCTAssertEqual(a, b)
    }

    func testDifferenceDetectsARealShift() {
        let a = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 3)
        let b = gaussianSeries(n: 250, mean: 20, sd: 6, seed: 4)   // clearly different mean
        let diff = Bootstrap.difference(a, b, statistic: Bootstrap.meanStat)!
        XCTAssertTrue(diff.excludesZero, "a 20 ms mean gap should be detected as real")
        XCTAssertLessThan(diff.high, 0)   // mean(a) − mean(b) ≈ −20
    }

    func testDifferenceCallsNoiseNoise() {
        // Two samples from the *same* distribution: the difference CI should straddle zero.
        let a = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 5)
        let b = gaussianSeries(n: 250, mean: 0, sd: 6, seed: 6)
        let diff = Bootstrap.difference(a, b, statistic: Bootstrap.meanStat)!
        XCTAssertFalse(diff.excludesZero, "no real difference should not be flagged as significant")
    }

    func testPooledDifferenceDetectsARealConditionEffect() {
        // Three takes per condition; condition B is 8 ms wider throughout.
        let a = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 12, seed: UInt64(10 + $0)) }
        let b = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 20, seed: UInt64(20 + $0)) }
        let diff = Bootstrap.pooledDifference(b, a, statistic: Bootstrap.sdStat)!
        XCTAssertTrue(diff.excludesZero, "a consistent 8 ms spread difference should be detected")
        XCTAssertGreaterThan(diff.point, 0)
    }

    func testPooledDifferenceCallsNoiseNoise() {
        let a = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 14, seed: UInt64(30 + $0)) }
        let b = (0..<3).map { gaussianSeries(n: 120, mean: 0, sd: 14, seed: UInt64(40 + $0)) }
        let diff = Bootstrap.pooledDifference(a, b, statistic: Bootstrap.sdStat)!
        XCTAssertFalse(diff.excludesZero)
    }

    func testPooledIntervalIgnoresTooShortTakes() {
        let a = gaussianSeries(n: 100, mean: 5, sd: 4, seed: 50)
        let b = gaussianSeries(n: 100, mean: 5, sd: 4, seed: 51)
        let ci = Bootstrap.pooledInterval([a, [1, 2, 3], b], statistic: Bootstrap.meanStat)
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
        let tight = Bootstrap.pooledInterval(agreeing, statistic: Bootstrap.meanStat)!
        let wide = Bootstrap.pooledInterval(disagreeing, statistic: Bootstrap.meanStat)!

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

        let diff = Bootstrap.pooledDifference(a, b, statistic: Bootstrap.meanStat)!
        XCTAssertGreaterThan(diff.point, 3, "the point estimate really is offset by one evening")
        XCTAssertFalse(diff.excludesZero,
                       "one odd evening out of four is between-take noise, not a condition effect")
    }

    func testPooledIntervalRefusesASingleTake() {
        let only = gaussianSeries(n: 200, mean: 5, sd: 4, seed: 100)
        XCTAssertNil(Bootstrap.pooledInterval([only], statistic: Bootstrap.meanStat),
                     "one take cannot support an interval about takes")
        XCTAssertNil(Bootstrap.pooledDifference([only], [only], statistic: Bootstrap.meanStat))
    }

    func testPooledIntervalStillRecoversAPlantedMean() {
        // The fix widens the interval; it must not move the estimate or lose the truth.
        let takes = (0..<5).map { gaussianSeries(n: 150, mean: -12, sd: 7, seed: UInt64(110 + $0)) }
        let ci = Bootstrap.pooledInterval(takes, statistic: Bootstrap.meanStat)!
        XCTAssertEqual(ci.point, Stats.mean(takes.flatMap { $0 }), accuracy: 1e-9)
        XCTAssertLessThan(ci.low, -12)
        XCTAssertGreaterThan(ci.high, -12)
    }

    func testPooledIntervalIsDeterministic() {
        let takes = (0..<3).map { gaussianSeries(n: 120, mean: 2, sd: 5, seed: UInt64(120 + $0)) }
        XCTAssertEqual(Bootstrap.pooledInterval(takes, statistic: Bootstrap.sdStat),
                       Bootstrap.pooledInterval(takes, statistic: Bootstrap.sdStat))
    }

    func testBlockResamplePreservesLength() {
        var rng = SplitMix64(seed: 7)
        let x = Array(0..<100).map(Double.init)
        XCTAssertEqual(Bootstrap.blockResample(x, blockLength: 5, using: &rng).count, 100)
    }
}
