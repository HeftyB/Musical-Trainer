import XCTest
@testable import TimingCore

/// M14 step 4e: the two drills that estimate a produced tempo stop guessing the note value.
///
/// Both computed `notesPerBeat` by dividing the target beat by the median interval and rounding,
/// with no check on how far the rounding moved. That is fine when the player is near a whole
/// subdivision and **inverts the sign** when they are not: a period 1.4× the target rounds to
/// one note per beat and is reported as 14% *slow* by a player who was 40% *fast*. A confident
/// number pointing the wrong way is the failure §3 of STANDARDS exists for.
final class PrescribedNoteValueTests: XCTestCase {

    // MARK: Helpers

    /// Notes at a fixed period through one hold.
    private func hold(periodMs: Double, count: Int, start: Double = 10) -> [Tap] {
        (0..<count).map { Tap(time: start + Double($0) * periodMs / 1000) }
    }

    private func round(targetBpm: Double = 100, start: Double = 10, seconds: Double = 12)
        -> TempoRound {
        TempoRound(index: 0, targetBpm: targetBpm, holdStart: start, holdEnd: start + seconds)
    }

    /// One silence, bracketed by paced sections so re-entry has something to measure.
    private func silence(periodMs: Double, count: Int, bpm: Double = 100)
        -> (taps: [Tap], grid: Grid, sections: [DropoutSection]) {
        let grid = Grid(startTime: 0, bpm: bpm, subdivisions: 1)
        let start = 4.0
        let taps = (0..<count).map { Tap(time: start + Double($0) * periodMs / 1000) }
        let sections = [
            DropoutSection(startTime: 0, endTime: start, isPaced: true),
            DropoutSection(startTime: start, endTime: start + 40, isPaced: false),
            DropoutSection(startTime: start + 40, endTime: start + 50, isPaced: true),
        ]
        return (taps, grid, sections)
    }

    // MARK: The inversion, in the tempo drill

    /// Halfway between one note per beat and two, the same playing supports two tempos that
    /// disagree about the *direction* of the error. Rounding picks one and reports it as a fact.
    func testAHoldBetweenNoteValuesIsRefusedRatherThanSnapped() {
        // 1.45 notes per beat: not quarters, not eighths, and no single tempo describes it.
        let taps = hold(periodMs: 600 / 1.45, count: 20)
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()])

        XCTAssertEqual(report.usableCount, 0, "a hold between note values is not scorable")
        XCTAssertEqual(report.rounds.first?.producedBpm, nil)
        XCTAssertTrue(report.rounds.first?.unusableReason?.contains("between note values") == true,
                      "\(report.rounds.first?.unusableReason ?? "nil")")
    }

    /// And the snap it replaced would have reported a confident number. This is the arithmetic
    /// the refusal exists to prevent, computed here so the size of the error is on the record.
    func testTheSnapItReplacedWouldHaveReportedTheWrongDirection() {
        let period = 600 / 1.45                       // ms, i.e. 1.45 notes per beat
        let snappedToOne = 60_000 / (period * 1)      // what rounding down would report
        let snappedToTwo = 60_000 / (period * 2)      // what rounding up would report

        XCTAssertEqual(snappedToOne, 145, accuracy: 1, "reads as 45% fast")
        XCTAssertEqual(snappedToTwo, 72.5, accuracy: 1, "reads as 27% slow")
        // Same playing, same target, opposite verdicts — which is why neither may be reported.
    }

    /// Near a whole number the estimate is sound and must still be given, or the refusal has
    /// eaten the drill.
    func testAHoldNearAWholeNoteValueIsStillScored() {
        for (notes, period) in [(1.0, 600.0), (2.0, 300.0), (4.0, 150.0)] {
            let taps = hold(periodMs: period, count: 20)
            let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()])
            XCTAssertEqual(report.rounds.first?.producedBpm ?? 0, 100, accuracy: 1,
                           "\(notes) notes per beat should read 100 BPM")
        }
    }

    // MARK: Prescribing removes the question

    func testAPrescribedNoteValueIsUsedInsteadOfInferred() {
        let taps = hold(periodMs: 300, count: 20)     // eighths at 100 BPM
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()],
                                                      notesPerBeat: 2)
        XCTAssertEqual(report.rounds.first?.producedBpm ?? 0, 100, accuracy: 1)
    }

    /// Asked for eighths and played in quarters, the round did not perform the task. Scoring it
    /// against quarters would report a tempo for a drill that was not run.
    func testARoundThatDidNotProduceTheAskedNoteValueIsRefused() {
        let taps = hold(periodMs: 600, count: 20)     // quarters
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()],
                                                      notesPerBeat: 2)
        XCTAssertEqual(report.usableCount, 0)
        XCTAssertTrue(report.rounds.first?.unusableReason?.contains("asked for 2") == true,
                      "\(report.rounds.first?.unusableReason ?? "nil")")
    }

    /// Prescribing must not become a new way to be wrong: a player at the right note value but
    /// the wrong *tempo* is still scored, because that is the thing the drill measures.
    func testAPrescribedRoundStillReportsATempoError() {
        let taps = hold(periodMs: 330, count: 20)     // eighths, but slow
        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()],
                                                      notesPerBeat: 2)
        XCTAssertEqual(report.rounds.first?.producedBpm ?? 0, 90.9, accuracy: 0.5)
        XCTAssertLessThan(report.rounds.first?.errorPercent ?? 0, -5)
    }

    // MARK: The same two properties in the continuation drill

    func testTheContinuationTempoIsWithheldBetweenNoteValues() {
        let (taps, grid, sections) = silence(periodMs: 600 / 1.45, count: 40)
        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)

        XCTAssertNil(report.playedBpm, "no single tempo describes 1.45 notes per beat")
        XCTAssertNil(report.tempoBiasBpm)
        XCTAssertNotNil(report.tempoUnreadableReason)
        XCTAssertTrue(report.headline.contains("can't be read"), report.headline)
    }

    func testTheContinuationTempoIsStillReadNearAWholeNoteValue() {
        let (taps, grid, sections) = silence(periodMs: 620, count: 40)
        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)

        XCTAssertEqual(report.playedBpm ?? 0, 96.8, accuracy: 1)
        XCTAssertNil(report.tempoUnreadableReason)
    }

    func testAPrescribedNoteValueIsUsedByTheContinuationDrill() {
        let (taps, grid, sections) = silence(periodMs: 300, count: 60)
        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections,
                                             notesPerBeat: 2)
        XCTAssertEqual(report.playedBpm ?? 0, 100, accuracy: 1)
    }

    func testTheContinuationDrillSaysSoWhenTheAskedNoteValueWasNotPlayed() {
        let (taps, grid, sections) = silence(periodMs: 600, count: 40)
        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections,
                                             notesPerBeat: 2)
        XCTAssertNil(report.playedBpm)
        XCTAssertTrue(report.tempoUnreadableReason?.contains("asked for 2") == true,
                      "\(report.tempoUnreadableReason ?? "nil")")
    }

    // MARK: Takes recorded before any of this

    /// Every take on disk has no rung, so the inference has to keep working exactly as it did
    /// for anything near a whole note value — otherwise a fix aimed at the future rewrites the
    /// past (R3.1 cuts both ways).
    func testNoPrescriptionKeepsTheOldBehaviourWhereItWasSound() {
        let taps = hold(periodMs: 640, count: 20)     // 0.94 notes per beat: plainly quarters
        let inferred = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()])
        let told = TempoCalibrationAnalysis.analyze(taps: taps, rounds: [round()],
                                                    notesPerBeat: 1)
        XCTAssertEqual(inferred.rounds.first?.producedBpm ?? 0,
                       told.rounds.first?.producedBpm ?? 0, accuracy: 0.001)
    }
}
