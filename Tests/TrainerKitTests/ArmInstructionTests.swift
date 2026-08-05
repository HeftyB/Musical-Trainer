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

    /// The runner shows the instructions for the block it is about to run, arm included.
    func testTheRunnerShowsTheArmsInstructions() throws {
        let assignment = ExperimentAssignment(
            experimentId: UUID(), name: "steady-vs-melodic", arm: "melodic", runIndex: 0)
        let block = SessionBlock(role: .experiment,
                                 plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "steady-vs-melodic")),
                                 reason: "the experiment slot", experiment: assignment)
        let runner = SessionRunner(plan: SessionPlan(targetMinutes: 30, blocks: [block], notes: []))

        let shown = try XCTUnwrap(runner.currentInstructions)
        XCTAssertEqual(shown.steps, DrillInstructions.jam(arm: "melodic").steps)
        XCTAssertNotEqual(shown.steps, DrillInstructions.jam.steps)
    }

    /// A jam that is not part of an experiment still gets the plain text.
    func testAnOrdinaryJamBlockIsUnaffected() throws {
        let block = SessionBlock(role: .benchmark,
                                 plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "benchmark")),
                                 reason: "the locked slot")
        let runner = SessionRunner(plan: SessionPlan(targetMinutes: 30, blocks: [block], notes: []))
        XCTAssertEqual(try XCTUnwrap(runner.currentInstructions).steps, DrillInstructions.jam.steps)
    }
}
