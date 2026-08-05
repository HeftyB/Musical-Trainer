import XCTest
@testable import TimingCore

/// M13 step 4: the planner's half — a locked block in a fixed slot, carrying an assigned arm.
final class ExperimentPlanningTests: XCTestCase {

    private func plan(_ experiments: [PlannerInput.Experiment] = [],
                      minutes: Int = 30) -> SessionPlan {
        SessionPlanner.plan(targetMinutes: minutes,
                            from: PlannerInput(experiments: experiments))
    }

    private var noHistory: [PlannerInput.Experiment] {
        ExperimentLibrary.all.map { PlannerInput.Experiment(name: $0.name, completedArms: []) }
    }

    private func experimentBlock(_ p: SessionPlan) -> SessionBlock? {
        p.blocks.first { $0.role == .experiment }
    }

    func testASessionCarriesOneExperimentTakeWithAnArm() throws {
        let block = try XCTUnwrap(experimentBlock(plan(noHistory)))
        let assigned = try XCTUnwrap(block.experiment)
        XCTAssertEqual(assigned.name, ExperimentLibrary.steadyVsMelodic?.name)
        XCTAssertTrue(["steady", "melodic"].contains(assigned.arm))
        XCTAssertEqual(assigned.runIndex, 0)
        XCTAssertEqual(plan(noHistory).blocks.filter { $0.role == .experiment }.count, 1,
                       "two experiment takes in one evening would be two arms of one condition")
    }

    /// R3.5. An experiment whose tempo or length moved between arms would compare those.
    func testTheExperimentTakeRunsAtTheBenchmarksLockedSettings() throws {
        for minutes in [20, 30, 45] {
            let block = try XCTUnwrap(experimentBlock(plan(noHistory, minutes: minutes)))
            guard case .jam(let p) = block.plan else {
                return XCTFail("the experiment take should be a jam")
            }
            XCTAssertEqual(p.bpm, SessionPlanner.referenceBpm)
            XCTAssertEqual(p.bars, SessionPlanner.benchmarkBars)
        }
    }

    /// A fixed slot, so the arm never correlates with how far into the evening it ran.
    func testTheExperimentTakeSitsInTheSameSlotEverySession() {
        let positions = [
            plan(noHistory),
            plan([PlannerInput.Experiment(name: "steady-vs-melodic", completedArms: ["steady"])]),
            plan([PlannerInput.Experiment(name: "steady-vs-melodic",
                                          completedArms: ["steady", "melodic", "steady"])]),
        ].map { p in p.blocks.firstIndex { $0.role == .experiment } }

        XCTAssertEqual(Set(positions).count, 1, "the slot moved: \(positions)")
        XCTAssertNotNil(positions.first ?? nil)
    }

    /// It follows the benchmark, which is warm but not yet tired.
    func testTheExperimentTakeFollowsTheBenchmark() throws {
        let p = plan(noHistory)
        let benchmark = try XCTUnwrap(p.blocks.firstIndex { $0.role == .benchmark })
        let experiment = try XCTUnwrap(p.blocks.firstIndex { $0.role == .experiment })
        XCTAssertEqual(experiment, benchmark + 1)
    }

    func testTheArmAlternatesAsTakesAccumulate() {
        var completed: [String] = []
        var seen: [String] = []
        for _ in 0..<6 {
            let history = [PlannerInput.Experiment(name: "steady-vs-melodic",
                                                   completedArms: completed)]
            guard let arm = experimentBlock(plan(history))?.experiment?.arm else {
                return XCTFail("no arm assigned at \(completed.count) takes")
            }
            seen.append(arm)
            completed.append(arm)
        }
        let counts = ["steady", "melodic"].map { a in seen.filter { $0 == a }.count }
        XCTAssertEqual(counts, [3, 3], "six takes should split evenly: \(seen)")
    }

    /// A finished experiment hands over to the next one rather than collecting forever.
    func testAFinishedExperimentGivesWayToTheNext() throws {
        let done = ExperimentLibrary.steadyVsMelodic.map { d in
            (0..<(d.takesPerArm * 2)).map { d.arms[$0 % d.arms.count] }
        }
        let history = [PlannerInput.Experiment(name: "steady-vs-melodic",
                                               completedArms: try XCTUnwrap(done))]
        let block = try XCTUnwrap(experimentBlock(plan(history)))
        XCTAssertEqual(block.experiment?.name, ExperimentLibrary.relaxedVsFocused?.name)
    }

    func testNoExperimentBlockWhenEveryExperimentIsFinished() {
        let history = ExperimentLibrary.all.map { d in
            PlannerInput.Experiment(name: d.name,
                                    completedArms: (0..<(d.takesPerArm * d.arms.count))
                                        .map { d.arms[$0 % d.arms.count] })
        }
        XCTAssertNil(experimentBlock(plan(history)))
    }

    /// The library decides which experiments exist; `input.experiments` only supplies history.
    ///
    /// So an input carrying no history is a player who has run none yet, not a player with no
    /// experiments — and the first take is scheduled at run 0. Asserting the opposite was the
    /// pre-M13 behaviour, and keeping it would have meant an experiment that could never start
    /// on a fresh install.
    func testAbsentHistoryMeansNoTakesYetRatherThanNoExperiment() throws {
        let block = try XCTUnwrap(experimentBlock(
            SessionPlanner.plan(targetMinutes: 30, from: PlannerInput())))
        XCTAssertEqual(block.experiment?.runIndex, 0)
        XCTAssertEqual(block.experiment?.name, ExperimentLibrary.steadyVsMelodic?.name)
    }

    /// Only the experiment block carries an arm. A benchmark or closing take stamped with one
    /// would be counted into the comparison without ever having been assigned to it.
    func testNoOtherBlockCarriesAnArm() {
        let p = plan(noHistory)
        for block in p.blocks where block.role != .experiment {
            XCTAssertNil(block.experiment, "\(block.role) must not carry an arm")
        }
    }

    /// The block still has to be runnable — a plan that fails partway through an evening is
    /// worse than one that never offered the take.
    func testTheExperimentBlockIsWithinTheEnginesLimits() throws {
        let block = try XCTUnwrap(experimentBlock(plan(noHistory)))
        guard case .jam(let p) = block.plan else { return XCTFail("expected a jam") }
        XCTAssertTrue((40...260).contains(p.bpm))
        XCTAssertTrue((4...512).contains(p.bars))
    }
}
