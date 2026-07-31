import XCTest
@testable import TimingCore

final class StatisticsTests: XCTestCase {
    func testMeanAndSD() {
        XCTAssertEqual(Stats.mean([2, 4, 6]), 4, accuracy: 1e-12)
        // [2,4,4,4,5,5,7,9]: population SD is 2.0, sample SD (n−1) is √(32/7) ≈ 2.138.
        // `sd` is the sample form, so it must return the larger value.
        XCTAssertEqual(Stats.sd([2, 4, 4, 4, 5, 5, 7, 9]), (32.0 / 7.0).squareRoot(), accuracy: 1e-12)
    }

    func testPopulationVarianceDiffersFromSample() {
        let x = [2.0, 4, 4, 4, 5, 5, 7, 9]
        XCTAssertEqual(Stats.populationVariance(x), 4.0, accuracy: 1e-12)   // n denominator
        XCTAssertEqual(Stats.sd(x) * Stats.sd(x), 32.0 / 7.0, accuracy: 1e-12)  // n-1
    }

    func testPercentileAndMedian() {
        XCTAssertEqual(Stats.median([1, 2, 3, 4, 5]), 3, accuracy: 1e-12)
        XCTAssertEqual(Stats.median([1, 2, 3, 4]), 2.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.iqr([1, 2, 3, 4, 5, 6, 7, 8, 9]), 4, accuracy: 1e-12)
    }

    func testLinearFitRecoversKnownLine() {
        let x = (0..<100).map(Double.init)
        let y = x.map { -2.5 * $0 + 7 }
        let fit = Stats.linearFit(x: x, y: y)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.slope, -2.5, accuracy: 1e-9)
        XCTAssertEqual(fit!.intercept, 7, accuracy: 1e-9)
        XCTAssertEqual(abs(fit!.r), 1, accuracy: 1e-9)
    }

    func testCorrelation() {
        let x = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(Stats.correlation(x, x.map { 3 * $0 })!, 1, accuracy: 1e-12)
        XCTAssertEqual(Stats.correlation(x, x.map { -3 * $0 })!, -1, accuracy: 1e-12)
        XCTAssertNil(Stats.correlation(x, [1, 1, 1, 1, 1]))   // flat: undefined
    }

    func testAutocorrelationOfAlternatingSeriesIsNegative() {
        let x = (0..<200).map { $0 % 2 == 0 ? 1.0 : -1.0 }
        let r1 = Stats.autocorrelation(x, lag: 1)
        XCTAssertNotNil(r1)
        XCTAssertEqual(r1!, -1, accuracy: 0.02)
    }

    func testAutocorrelationOfConstantIsNil() {
        XCTAssertNil(Stats.autocorrelation([5, 5, 5, 5], lag: 1))  // zero variance
    }
}
