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
        let good = gaussianSeries(n: 100, mean: 5, sd: 4, seed: 50)
        let ci = Bootstrap.pooledInterval([good, [1, 2, 3]], statistic: Bootstrap.meanStat)
        XCTAssertNotNil(ci)
        // The 3-point take is discarded, so the estimate reflects only the usable one.
        XCTAssertEqual(ci!.point, Stats.mean(good), accuracy: 1e-9)
    }

    func testBlockResamplePreservesLength() {
        var rng = SplitMix64(seed: 7)
        let x = Array(0..<100).map(Double.init)
        XCTAssertEqual(Bootstrap.blockResample(x, blockLength: 5, using: &rng).count, 100)
    }
}
