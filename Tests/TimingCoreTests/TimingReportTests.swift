import XCTest
import TestSupport
@testable import TimingCore

final class TimingReportTests: XCTestCase {
    func testRecoversBiasAndSpread() {
        var rng = SeededRNG(seed: 1)
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)
        let taps = Generators.tapsOnGrid(grid: grid, beats: 400,
                                         biasMs: -8, jitterMs: 6, rng: &rng)
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)

        XCTAssertEqual(report.matchedCount, 400)
        XCTAssertEqual(report.meanAsynchronyMs, -8, accuracy: 1.0)
        XCTAssertEqual(report.sdAsynchronyMs, 6, accuracy: 1.0)
    }

    func testDetectsChasingViaNegativeLag1() {
        var rng = SeededRNG(seed: 2)
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)
        // Over-correction: each error is answered by an opposite one next beat.
        let taps = (0..<200).map { k -> Tap in
            let alternating = (k % 2 == 0 ? 12.0 : -12.0) + rng.gaussian(sd: 2)
            return Tap(time: grid.time(ofIndex: k) + alternating / 1000)
        }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)

        XCTAssertNotNil(report.lag1Autocorrelation)
        XCTAssertLessThan(report.lag1Autocorrelation!, -0.3)
        XCTAssertTrue(report.headline.lowercased().contains("chasing"),
                      "expected a chasing headline, got: \(report.headline)")
    }

    func testDriftYieldsTempoError() {
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)   // 500 ms beats
        // +5 ms of lateness per beat — a steady slowing.
        let taps = (0..<20).map { Tap(time: grid.time(ofIndex: $0) + Double($0) * 0.005) }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)

        XCTAssertNotNil(report.driftMsPerBeat)
        XCTAssertEqual(report.driftMsPerBeat!, 5, accuracy: 0.2)
        // Slower than the grid ⇒ negative tempo error, ≈ 60000/505 − 120.
        XCTAssertNotNil(report.effectiveBpmError)
        XCTAssertEqual(report.effectiveBpmError!, 60_000 / 505 - 120, accuracy: 0.3)
        XCTAssertLessThan(report.effectiveBpmError!, 0)
    }

    func testSubdivisionConditionalSpread() {
        var rng = SeededRNG(seed: 3)
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 4)   // sixteenths
        // Solid on downbeats, sloppy on the "e"/"and"/"a".
        let taps = (0..<160).map { k -> Tap in
            let jitter = grid.phase(ofIndex: k) == 0 ? 4.0 : 18.0
            return Tap(time: grid.time(ofIndex: k) + rng.gaussian(sd: jitter) / 1000)
        }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)

        let byPhase = Dictionary(uniqueKeysWithValues:
            report.subdivisionStats.map { ($0.subdivision, $0.sdAsynchronyMs) })
        XCTAssertNotNil(byPhase[0]); XCTAssertNotNil(byPhase[2])
        XCTAssertLessThan(byPhase[0]!, byPhase[2]!,
                          "downbeats should be tighter than offbeats")
    }

    func testVelocityTimingCoupling() {
        var rng = SeededRNG(seed: 4)
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)
        // Harder notes land later: asynchrony grows with velocity.
        let taps = (0..<200).map { k -> Tap in
            let velocity = Int(rng.uniform() * 100) + 20      // 20…120
            let async = 0.3 * Double(velocity - 64) + rng.gaussian(sd: 3)
            return Tap(time: grid.time(ofIndex: k) + async / 1000, velocity: velocity)
        }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)

        XCTAssertNotNil(report.velocityTimingCorrelation)
        XCTAssertGreaterThan(report.velocityTimingCorrelation!, 0.7)
    }

    func testSparseInputGivesHonestHeadline() {
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)
        let taps = (0..<3).map { Tap(time: grid.time(ofIndex: $0)) }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid)
        XCTAssertTrue(report.headline.lowercased().contains("not enough"))
    }
}
