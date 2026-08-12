import XCTest
@testable import TimingCore
@testable import TrainerKit

/// The form drill has to say how long a phrase is, because nothing else does.
///
/// The first step was hardcoded to *"8 bars each by default"* while the take ran whatever it was
/// configured with, so a 16-bar phrase was announced as 8. R3.6 is the rule it broke — instructions
/// come from the configuration that will actually run — and the drill makes it worse than usual:
/// **8 and 16 bars of the same groove are audibly identical**, so at level 2 the words were the
/// only source of the number (PLAN.md §7.42).
final class FormInstructionsSayThePhraseLengthTests: XCTestCase {

    private func steps(level: Int, phraseBars: Int) -> String {
        DrillInstructions.form(level: level, phraseBars: phraseBars).steps.joined(separator: " ")
    }

    /// The defect: the configured length appears, at every length the app offers.
    func testEveryPhraseLengthIsStatedInTheInstructions() {
        for bars in [4, 8, 16, 32] {
            for level in 0...3 {
                XCTAssertTrue(steps(level: level, phraseBars: bars).contains("\(bars) bars"),
                              "level \(level) at \(bars) bars never says \(bars)")
            }
        }
    }

    /// And no other length is asserted alongside it. The old text said "8 bars each by default"
    /// whatever was running, so a 16-bar take carried both numbers and the wrong one first.
    func testAPhraseLengthIsNeverContradictedByAnotherNumber() {
        let sixteen = steps(level: 2, phraseBars: 16)
        XCTAssertFalse(sixteen.contains("8 bars each"),
                       "the hardcoded default must not survive beside the real length")
        let four = steps(level: 0, phraseBars: 4)
        XCTAssertFalse(four.contains("8 bars"), "a 4-bar take must not mention 8 bars")
    }

    /// Level 2 is the one level with no fills, no accent and no silence — nothing in the music
    /// distinguishes one phrase length from another for the whole take. It has to say so, or the
    /// player has no way to know the number mattered.
    func testLevelTwoSaysTheMusicWillNotTellYou() {
        let text = steps(level: 2, phraseBars: 16).lowercased()
        XCTAssertTrue(text.contains("nothing in the music"),
                      "level 2 must warn that the number is the only cue it will get")
    }

    /// A planned block carries its own phrase length, and `forBlock` is the one mapping from a
    /// plan to its instructions — it had the `FormPlan` in hand and dropped the field.
    func testAPlannedBlockCarriesItsPhraseLengthIntoTheInstructions() {
        let plan = FormPlan(bpm: 100, bars: 96, phraseBars: 16, level: 2)
        let block = SessionBlock(role: .training, plan: .form(plan), reason: "")
        XCTAssertTrue(DrillInstructions.forBlock(block).steps.joined().contains("16 bars"),
                      "a planned 16-bar phrase must not be described as 8")
    }
}
