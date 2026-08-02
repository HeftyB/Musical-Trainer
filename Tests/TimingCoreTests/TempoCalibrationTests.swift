import XCTest
@testable import TimingCore

final class TempoCalibrationTests: XCTestCase {

    /// Rounds of `holdBeats` notes each, produced at `producedBpm` against a `targetBpm` click.
    private func session(targetBpm: Double, producedBpm: [Double],
                         holdBeats: Int = 16, gap: Double = 10) -> ([Tap], [TempoRound]) {
        var taps: [Tap] = []
        var rounds: [TempoRound] = []
        var cursor = 0.0
        for (i, bpm) in producedBpm.enumerated() {
            let start = cursor
            let period = 60.0 / bpm
            for k in 0..<holdBeats { taps.append(Tap(time: start + Double(k) * period)) }
            let end = start + Double(holdBeats) * period
            rounds.append(TempoRound(index: i, targetBpm: targetBpm,
                                     holdStart: start - 0.01, holdEnd: end + 0.01))
            cursor = end + gap
        }
        return (taps, rounds)
    }

    func testRecoversProducedTempo() {
        let (taps, rounds) = session(targetBpm: 100, producedBpm: [95, 95, 95])
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertEqual(report.usableCount, 3)
        for round in report.rounds {
            XCTAssertEqual(round.producedBpm!, 95, accuracy: 0.5)
            XCTAssertEqual(round.errorBpm!, -5, accuracy: 0.5)
        }
        XCTAssertEqual(report.meanErrorPercent!, -5, accuracy: 0.5)
        XCTAssertTrue(report.headline.lowercased().contains("slow"),
                      "expected a slow bias, got: \(report.headline)")
    }

    func testDetectsImprovementAcrossRounds() {
        // Error shrinking 8% → 1% as the session goes on.
        let (taps, rounds) = session(targetBpm: 100, producedBpm: [92, 94, 96, 98, 99])
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertNotNil(report.improvementPerRound)
        XCTAssertLessThan(report.improvementPerRound!, -0.3)
        XCTAssertTrue(report.headline.lowercased().contains("tightened"),
                      "expected improvement to be called out, got: \(report.headline)")
    }

    func testAccurateSessionSaysSo() {
        let (taps, rounds) = session(targetBpm: 120, producedBpm: [120, 119.5, 120.5])
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertLessThan(abs(report.meanErrorPercent!), 1)
        XCTAssertTrue(report.headline.lowercased().contains("accurate"))
    }

    /// Steady subdividing is a legitimate way to hold a tempo; it must not read as double.
    func testConsistentSubdivisionIsNormalised() {
        var taps: [Tap] = []
        let period = 60.0 / 100 / 2                      // eighth notes at 100 BPM
        for k in 0..<32 { taps.append(Tap(time: Double(k) * period)) }
        let rounds = [TempoRound(index: 0, targetBpm: 100, holdStart: -0.01,
                                 holdEnd: 32 * period + 0.01)]
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertTrue(report.rounds[0].isUsable)
        XCTAssertEqual(report.rounds[0].producedBpm!, 100, accuracy: 2)
    }

    func testMixedNoteValuesCannotBeScored() {
        var taps: [Tap] = []
        var t = 0.0
        var half = false
        for _ in 0..<20 { taps.append(Tap(time: t)); t += half ? 0.3 : 0.6; half.toggle() }
        let rounds = [TempoRound(index: 0, targetBpm: 100, holdStart: -0.01, holdEnd: t + 0.01)]
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertFalse(report.rounds[0].isUsable)
        XCTAssertEqual(report.rounds[0].unusableReason, "not one note per beat")
    }

    func testTooFewNotesCannotBeScored() {
        let taps = [Tap(time: 0), Tap(time: 0.6), Tap(time: 1.2)]
        let rounds = [TempoRound(index: 0, targetBpm: 100, holdStart: -0.01, holdEnd: 2)]
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertFalse(report.rounds[0].isUsable)
        XCTAssertEqual(report.usableCount, 0)
        XCTAssertTrue(report.headline.lowercased().contains("no round"))
    }

    /// Rotating the target is the point of the drill — a clock calibrated at one tempo is a
    /// lookup table, not a mapping.
    func testHandlesRotatingTargets() {
        var taps: [Tap] = []
        var rounds: [TempoRound] = []
        var cursor = 0.0
        for (i, target) in [76.0, 100.0, 132.0].enumerated() {
            let produced = target * 0.95            // consistently 5% slow at every tempo
            let period = 60.0 / produced
            for k in 0..<16 { taps.append(Tap(time: cursor + Double(k) * period)) }
            let end = cursor + 16 * period
            rounds.append(TempoRound(index: i, targetBpm: target,
                                     holdStart: cursor - 0.01, holdEnd: end + 0.01))
            cursor = end + 5
        }
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)
        XCTAssertEqual(report.usableCount, 3)
        // The bias is proportional, so it should read as ~5% at every target.
        for round in report.rounds { XCTAssertEqual(round.errorPercent!, -5, accuracy: 0.6) }
    }
}
