import XCTest
@testable import TimingCore
@testable import TrainerKit

/// The arm's instructions are the condition, not a description of it.
///
/// For `steady-vs-melodic` both arms play the same backing at the same tempo for the same
/// length. **The instruction text is the entire independent variable** — text describing the
/// wrong arm would not confuse the player, it would swap the conditions and the experiment
/// would measure nothing while appearing to work.
///
/// Static instructions have already cost this project two takes and a live session (§6.1,
/// §7.17). In both cases the text merely *described* something that had moved. Here it is the
/// thing itself, which is why R3.6 gets its own tests rather than a comment.
final class ArmInstructionTests: XCTestCase {

    func testEachArmGetsItsOwnInstructions() {
        let steady = DrillInstructions.jam(arm: "steady")
        let melodic = DrillInstructions.jam(arm: "melodic")

        XCTAssertNotEqual(steady.steps, melodic.steps)
        XCTAssertTrue(steady.steps.contains { $0.contains("one note per beat") }, "\(steady.steps)")
        XCTAssertTrue(melodic.steps.contains { $0.lowercased().contains("melody") },
                      "\(melodic.steps)")
    }

    /// Each arm has to warn against drifting into the other one, or the two conditions converge
    /// on whatever the player felt like doing.
    func testEachArmWarnsAgainstDriftingIntoTheOther() {
        for arm in ["steady", "melodic", "relaxed", "focused"] {
            let instructions = DrillInstructions.jam(arm: arm)
            XCTAssertTrue(instructions.pitfalls.contains { $0.contains("the other arm") },
                          "\(arm) does not warn against the other arm: \(instructions.pitfalls)")
        }
    }

    /// `slow-vs-fast` is the first design where the text is **not** the condition — the tempo
    /// is, and it differs whatever this says. The text's job is only to stop the player treating
    /// an unfamiliar tempo as a cue to play differently, which would make the take measure two
    /// things at once.
    func testTheTempoArmsHaveTextAndNeitherIsThePlainJam() {
        for arm in ["slow", "fast"] {
            XCTAssertNotEqual(DrillInstructions.jam(arm: arm).steps,
                              DrillInstructions.jam.steps, arm)
        }
        XCTAssertNotEqual(DrillInstructions.jam(arm: "slow").steps,
                          DrillInstructions.jam(arm: "fast").steps)
    }

    /// Note density is `steady-vs-melodic`'s variable. A player who plays busier because the
    /// tempo changed would make the tempo design measure density too, so the text says not to.
    func testBothTempoArmsWarnAgainstChangingHowBusilyTheyPlay() {
        for arm in ["slow", "fast"] {
            XCTAssertTrue(DrillInstructions.jam(arm: arm).pitfalls
                            .contains { $0.contains("busier") },
                          "\(arm): \(DrillInstructions.jam(arm: arm).pitfalls)")
        }
    }

    /// An unknown arm degrades to an ordinary take rather than a mislabelled one.
    func testAnUnknownArmFallsBackToThePlainJam() {
        XCTAssertEqual(DrillInstructions.jam(arm: "retired-arm").steps, DrillInstructions.jam.steps)
        XCTAssertEqual(DrillInstructions.jam(arm: nil).steps, DrillInstructions.jam.steps)
    }

    /// Every arm the library declares must have real instructions. An arm added to a design
    /// without text would run as a plain jam and be recorded as a condition it never was.
    func testEveryDeclaredArmHasItsOwnText() {
        let plain = DrillInstructions.jam.steps
        for design in ExperimentLibrary.all {
            for arm in design.arms {
                XCTAssertNotEqual(DrillInstructions.jam(arm: arm).steps, plain,
                                  "'\(arm)' of \(design.name) has no instructions of its own")
            }
        }
    }

    /// An experiment block shows the arm's instructions, through the mapping both surfaces use.
    ///
    /// This asserted against a `SessionRunner.currentInstructions` accessor until M14 step 4a.
    /// No front end ever called it — both call `DrillInstructions.forBlock(_:)` — so the two
    /// tests below were guarding a copy of the mapping rather than the one that ships. §7.20
    /// step 4 records that same shape as the defect it nearly missed; the fix for it added
    /// `forBlock` and left the accessor and these tests pointing at each other.
    func testAnExperimentBlockShowsTheArmsInstructions() {
        let assignment = ExperimentAssignment(
            experimentId: UUID(), name: "steady-vs-melodic", arm: "melodic", runIndex: 0)
        let block = SessionBlock(role: .experiment,
                                 plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "steady-vs-melodic")),
                                 reason: "the experiment slot", experiment: assignment)

        let shown = DrillInstructions.forBlock(block)
        XCTAssertEqual(shown.steps, DrillInstructions.jam(arm: "melodic").steps)
        XCTAssertNotEqual(shown.steps, DrillInstructions.jam.steps)
    }

    /// A jam that is not part of an experiment still gets the plain text.
    func testAnOrdinaryJamBlockIsUnaffected() {
        let block = SessionBlock(role: .benchmark,
                                 plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "benchmark")),
                                 reason: "the locked slot")
        XCTAssertEqual(DrillInstructions.forBlock(block).steps, DrillInstructions.jam.steps)
    }

    /// Every block a plan can contain has instructions, including the unmeasured warm-up.
    ///
    /// The deleted accessor returned nil for the groove block while `forBlock` returns the
    /// groove text, and the app has always rendered `forBlock` unconditionally — so the two
    /// disagreed about the one block type neither test covered.
    func testEveryBlockKindInAPlannedSessionHasText() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput())
        for block in plan.blocks {
            let text = DrillInstructions.forBlock(block)
            XCTAssertFalse(text.goal.isEmpty, "\(block.plan.drillName) has no goal")
            XCTAssertFalse(text.steps.isEmpty, "\(block.plan.drillName) has no steps")
        }
    }
}
