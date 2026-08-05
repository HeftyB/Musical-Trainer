import XCTest
@testable import TimingCore

final class TrendAnalysisTests: XCTestCase {

    /// An unscorable take leaves a gap in the axis; it does not close it
    /// (PLAN.md §7.20 finding 4).
    ///
    /// Filtering the non-finite values and then numbering `0..<count` slides every later take
    /// one place earlier, so the slope becomes per *usable* take while every label, unit string
    /// and doc comment says per take.
    func testAnUnscorableTakeLeavesAGapInTheAxisRatherThanClosingIt() {
        // y = 10 − takeNumber, with take 1 unscorable. The truth is −1.00 per take.
        let values: [Double] = [10, .nan, 8, 7, 6]
        guard let fit = TrendAnalysis.fit(values, lowerIsBetter: true) else {
            return XCTFail("four usable points is enough to fit")
        }
        // Renumbering gives −1.30: the remaining points land at 0, 1, 2, 3 instead of 0, 2, 3, 4.
        XCTAssertEqual(fit.slope, -1.0, accuracy: 1e-9,
                       "the axis is take number, not position among the scorable takes")
        XCTAssertEqual(fit.pointCount, 4)
    }

    /// The convenience wrapper is the path every caller actually uses, so it has to hand the
    /// fit the original series. Passing it the filtered one restores the defect one level up.
    func testRowFitsAgainstTheOriginalTakeNumbers() {
        let row = TrendAnalysis.row("spread", [10, .nan, 8, 7, 6], lowerIsBetter: true)
        XCTAssertEqual(row.fit?.slope ?? .nan, -1.0, accuracy: 1e-9)
        // The chart still plots only the points that exist.
        XCTAssertEqual(row.values.count, 4)
    }


    /// A series with a known slope plus a little noise.
    private func ramp(_ n: Int, start: Double, per: Double, noise: Double, seed: UInt64) -> [Double] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { i in
            let u = Double(rng.next() >> 11) / Double(1 << 53)   // 0..1
            return start + per * Double(i) + (u - 0.5) * 2 * noise
        }
    }

    func testFallingSpreadReadsAsImproving() {
        // Spread coming down 1 ms per take over 10 takes, noise well under the effect.
        let fit = TrendAnalysis.fit(ramp(10, start: 25, per: -1, noise: 0.6, seed: 1),
                                    lowerIsBetter: true)!
        XCTAssertEqual(fit.verdict, .improving)
        XCTAssertTrue(fit.isReal)
        XCTAssertLessThan(fit.slope, 0)
        XCTAssertLessThan(fit.high, 0, "the interval should sit entirely below zero")
    }

    func testRisingSpreadReadsAsWorsening() {
        let fit = TrendAnalysis.fit(ramp(10, start: 12, per: 1, noise: 0.6, seed: 2),
                                    lowerIsBetter: true)!
        XCTAssertEqual(fit.verdict, .worsening)
        XCTAssertGreaterThan(fit.low, 0)
    }

    /// The same rising series is *progress* for a metric where higher is better, and the
    /// verdict has to follow the metric rather than the sign. Getting this backwards would
    /// report an improving on-form rate as a decline.
    func testDirectionFollowsTheMetric() {
        let rising = ramp(10, start: 0.4, per: 0.04, noise: 0.02, seed: 3)
        XCTAssertEqual(TrendAnalysis.fit(rising, lowerIsBetter: false)!.verdict, .improving)
        XCTAssertEqual(TrendAnalysis.fit(rising, lowerIsBetter: true)!.verdict, .worsening)
    }

    func testNoiseIsCalledFlat() {
        // No underlying slope at all: the interval must straddle zero rather than find a line.
        let fit = TrendAnalysis.fit(ramp(9, start: 20, per: 0, noise: 4, seed: 4),
                                    lowerIsBetter: true)!
        XCTAssertEqual(fit.verdict, .flat)
        XCTAssertFalse(fit.isReal)
        XCTAssertLessThan(fit.low, 0)
        XCTAssertGreaterThan(fit.high, 0)
    }

    func testTwoTakesCannotSupportATrend() {
        XCTAssertNil(TrendAnalysis.fit([20, 18], lowerIsBetter: true))
        XCTAssertNotNil(TrendAnalysis.fit([20, 19, 18], lowerIsBetter: true))
    }

    /// A drill whose split came out unreliable contributes no number. Letting NaN through
    /// would poison the whole fit, so those points are dropped and the count reflects it.
    func testNonFiniteValuesAreDroppedNotPropagated() {
        let fit = TrendAnalysis.fit([25, .nan, 22, 20, .infinity, 18], lowerIsBetter: true)!
        XCTAssertEqual(fit.pointCount, 4)
        XCTAssertTrue(fit.slope.isFinite)

        // Too few survivors is a nil fit, not a fit computed on one point.
        XCTAssertNil(TrendAnalysis.fit([25, .nan, .nan, .nan], lowerIsBetter: true))
    }

    /// An interval that moved between runs would make "real change" a coin flip.
    func testIntervalIsDeterministic() {
        let values = ramp(8, start: 18, per: -0.5, noise: 1.5, seed: 5)
        XCTAssertEqual(TrendAnalysis.fit(values, lowerIsBetter: true),
                       TrendAnalysis.fit(values, lowerIsBetter: true))
    }

    func testRowKeepsOnlyFiniteValuesForPlotting() {
        let row = TrendAnalysis.row("spread (SD)", [20, .nan, 18], lowerIsBetter: true)
        XCTAssertEqual(row.values, [20, 18])
        XCTAssertNil(row.fit, "two usable points is not a trend")
        XCTAssertTrue(row.lowerIsBetter)
    }

    func testDistinctExposesAConfoundedGroup() {
        XCTAssertEqual(TrendAnalysis.distinct(["jamBacking", "basicRock", "jamBacking"]),
                       ["basicRock", "jamBacking"])
        XCTAssertEqual(TrendAnalysis.distinct([100.0, 100.0]).count, 1)
    }
}
