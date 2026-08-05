import XCTest
@testable import TimingCore

/// M14 step 5: the tempo question, preregistered.
///
/// The first design in the library where the arms differ in **tempo** rather than in what the
/// player is told. That inverts the relationship the earlier two rest on: for
/// `steady-vs-melodic` the instruction text *is* the independent variable, so wrong text swaps
/// the conditions silently; here the tempo differs whatever the text says. The machinery has to
/// know which kind a design is, and these hold that line.
final class SlowVsFastTests: XCTestCase {

    private var design: ExperimentDesign {
        // Force-unwrapping is fine in a test and loud if the design ever fails to build.
        ExperimentLibrary.slowVsFast!
    }

    // MARK: The design itself

    func testTheDesignIsDeclaredAndVariesTempo() {
        XCTAssertTrue(design.variesTempo)
        XCTAssertEqual(design.bpm(forArm: "slow"), 80)
        XCTAssertEqual(design.bpm(forArm: "fast"), 140)
        XCTAssertEqual(design.metric, .bias)
    }

    /// Bias is reported and never scored (§2). An experiment that could rank one arm "better" on
    /// placement would be a machine for teaching that playing ahead of the beat is a fault.
    func testPlacementHasNoBetterDirection() {
        XCTAssertNil(design.metric.lowerIsBetter)
    }

    /// The id is what the arm schedule is seeded from. A fresh one each launch would reshuffle
    /// an experiment already half collected (§7.20 step 2).
    func testTheIdIsFixedAcrossBuilds() {
        XCTAssertEqual(design.id.uuidString, "E0000003-0000-4000-8000-000000000003")
    }

    /// Queued behind the two already collecting, so it does not start until they finish — two
    /// experiments at once would put two conditions on the same evening.
    func testItIsLastInThePriorityOrder() {
        XCTAssertEqual(ExperimentLibrary.all.last?.name, "slow-vs-fast")

        let noneFinished = ExperimentLibrary.active(progressByName: [:])
        XCTAssertEqual(noneFinished?.name, "steady-vs-melodic")

        let twoFinished = ExperimentLibrary.active(
            progressByName: ["steady-vs-melodic": true, "relaxed-vs-focused": true])
        XCTAssertEqual(twoFinished?.name, "slow-vs-fast")
    }

    // MARK: A per-arm tempo that cannot silently degrade

    /// A tempo map missing an arm would run that arm at the reference and turn a two-tempo
    /// comparison into a one-tempo one while still reporting two conditions.
    func testADesignWhoseTempoMapMissesAnArmIsRefused() {
        XCTAssertNil(ExperimentDesign(name: "half-mapped", question: "?",
                                      arms: ["slow", "fast"], metric: .bias, takesPerArm: 4,
                                      bpmByArm: ["slow": 80]))
    }

    /// And one where both arms map to the same tempo is not a tempo experiment at all.
    func testADesignWhoseArmsShareATempoIsRefused() {
        XCTAssertNil(ExperimentDesign(name: "same-tempo", question: "?",
                                      arms: ["slow", "fast"], metric: .bias, takesPerArm: 4,
                                      bpmByArm: ["slow": 100, "fast": 100]))
    }

    func testATempoOutsideTheEnginesRangeIsRefused() {
        XCTAssertNil(ExperimentDesign(name: "impossible", question: "?",
                                      arms: ["slow", "fast"], metric: .bias, takesPerArm: 4,
                                      bpmByArm: ["slow": 20, "fast": 400]))
    }

    /// An instruction-only design must keep working with no tempo map at all.
    func testAnInstructionOnlyDesignDoesNotVaryTempo() {
        let steady = ExperimentLibrary.steadyVsMelodic
        XCTAssertEqual(steady?.variesTempo, false)
        XCTAssertNil(steady?.bpm(forArm: "steady"))
    }

    // MARK: The planner runs the arm's tempo

    private func inputWithBothFinished() -> PlannerInput {
        let finished = { (name: String, arms: [String], n: Int) -> PlannerInput.Experiment in
            PlannerInput.Experiment(
                name: name,
                completedArms: (0..<(n * 2)).map { arms[$0 % 2] })
        }
        return PlannerInput(experiments: [
            finished("steady-vs-melodic", ["steady", "melodic"], 5),
            finished("relaxed-vs-focused", ["relaxed", "focused"], 5),
        ])
    }

    func testTheExperimentBlockRunsAtTheArmsOwnTempo() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: inputWithBothFinished())
        guard let block = plan.blocks.first(where: { $0.role == .experiment }),
              case .jam(let p) = block.plan, let arm = block.experiment?.arm else {
            return XCTFail("no experiment block: \(plan.blocks.map(\.role))")
        }
        XCTAssertEqual(block.experiment?.name, "slow-vs-fast")
        XCTAssertEqual(p.bpm, design.bpm(forArm: arm), "the block must run the arm's tempo")
        XCTAssertNotEqual(p.bpm, SessionPlanner.referenceBpm)
    }

    /// Everything except the tempo stays locked, or the experiment is comparing more than one
    /// thing (R3.5).
    func testOnlyTheTempoDiffersFromTheBenchmark() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: inputWithBothFinished())
        guard case .jam(let experiment)? = plan.blocks
                .first(where: { $0.role == .experiment })?.plan,
              case .jam(let benchmark)? = plan.blocks
                .first(where: { $0.role == .benchmark })?.plan else {
            return XCTFail("missing a block")
        }
        XCTAssertEqual(experiment.bars, benchmark.bars)
        XCTAssertNil(experiment.rung, "free playing, exactly as the benchmark is")
        XCTAssertNil(benchmark.rung)
    }

    /// The reason shown before the session has to name the tempo, since that is the condition —
    /// a player who does not know the tempo moved cannot tell the arms apart.
    func testThePreviewNamesTheTempoWhenTempoIsTheCondition() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: inputWithBothFinished())
        guard let block = plan.blocks.first(where: { $0.role == .experiment }) else {
            return XCTFail("no experiment block")
        }
        XCTAssertTrue(block.reason.contains("BPM"), block.reason)
        XCTAssertTrue(block.reason.contains("tempo is the one thing that changes"), block.reason)
    }

    /// While an instruction-only design is running, the block stays at the reference tempo.
    func testAnInstructionOnlyExperimentStillRunsAtTheReferenceTempo() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput())
        guard case .jam(let p)? = plan.blocks.first(where: { $0.role == .experiment })?.plan else {
            return XCTFail("no experiment block")
        }
        XCTAssertEqual(p.bpm, SessionPlanner.referenceBpm)
    }

    // MARK: What the readout must say about it

    /// Comparing milliseconds across tempos is only sound because §7.23 step 3b measured this
    /// player's scatter to be interval-invariant. That premise has to travel with the result.
    func testTheReadoutStatesWhatTheCrossTempoComparisonRestsOn() {
        let takes = (0..<12).map { i in
            ExperimentTake(arm: i % 2 == 0 ? "slow" : "fast",
                           value: -15 + Double(i), elapsedMinutes: 8,
                           sittingId: UUID())
        }
        let result = ExperimentAnalysis.analyze(design: design, takes: takes)
        XCTAssertTrue(result.notes.contains { $0.contains("step 3b") }, result.notes.description)
        XCTAssertTrue(result.notes.contains { $0.contains("no better direction") },
                      result.notes.description)
    }

    /// Power is stated up front, because the honest thing about this design is its limit: the
    /// between-take spread on placement is large, so a small tempo effect will come back as
    /// "no difference found" and that is a real outcome rather than a failure.
    func testAMinimumDetectableEffectIsReportedBeforeAnyVerdict() {
        let takes = (0..<4).map { i in
            ExperimentTake(arm: i % 2 == 0 ? "slow" : "fast", value: -15 + Double(i))
        }
        let result = ExperimentAnalysis.analyze(design: design, takes: takes)
        guard case .collecting = result.verdict else {
            return XCTFail("four takes is below target: \(result.verdict)")
        }
        XCTAssertNotNil(result.minimumDetectableEffect)
    }
}
