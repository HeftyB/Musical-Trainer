import XCTest
import TestSupport
@testable import TimingCore

final class WingKristoffersonTests: XCTestCase {
    /// The central claim: from a synthetic process with known clock and motor variances,
    /// the decomposition recovers both. Uses a long sequence so the sampling error is
    /// small enough for a tight tolerance.
    func testRecoversKnownClockAndMotorVariance() {
        var rng = SeededRNG(seed: 42)
        let clockSD = 12.0, motorSD = 7.0
        let times = Generators.wkTapTimes(count: 20_000, beatMs: 500,
                                          clockSD: clockSD, motorSD: motorSD, rng: &rng)

        let result = WingKristofferson.decompose(tapTimes: times)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.modelHolds)

        // Statistical recovery: within 8% of the planted standard deviations.
        XCTAssertEqual(result!.clockSDms, clockSD, accuracy: clockSD * 0.08)
        XCTAssertEqual(result!.motorSDms, motorSD, accuracy: motorSD * 0.08)
    }

    /// The whole point of the metric: two performers with the same total variance but the
    /// noise in different places must be told apart.
    func testDistinguishesClockNoiseFromMotorNoise() {
        var rng = SeededRNG(seed: 7)
        let clockHeavy = WingKristofferson.decompose(
            tapTimes: Generators.wkTapTimes(count: 20_000, beatMs: 500,
                                            clockSD: 15, motorSD: 3, rng: &rng))!
        let motorHeavy = WingKristofferson.decompose(
            tapTimes: Generators.wkTapTimes(count: 20_000, beatMs: 500,
                                            clockSD: 3, motorSD: 15, rng: &rng))!

        XCTAssertGreaterThan(clockHeavy.clockSDms, clockHeavy.motorSDms)
        XCTAssertGreaterThan(motorHeavy.motorSDms, motorHeavy.clockSDms)
    }

    /// A drifting (accelerating) sequence violates the model's stationarity assumption:
    /// lag-1 autocovariance goes positive and the split must flag itself as unreliable.
    func testDriftingSequenceFailsModelCheck() {
        // Intervals shrinking steadily — a monotonic accelerando, positive γ₁.
        let intervals = (0..<200).map { 500.0 - Double($0) * 0.5 }
        let result = WingKristofferson.decompose(intervalsMs: intervals)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.modelHolds)
    }

    func testTooFewIntervalsReturnsNil() {
        XCTAssertNil(WingKristofferson.decompose(intervalsMs: [500, 500]))
    }
}
