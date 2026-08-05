import XCTest
@testable import TimingCore
@testable import TrainerKit

/// M13 step 1: the arm is stored before anything reads it.
///
/// The third time this project has added a field ahead of the analysis that needs it, and for
/// the same reason each time (R6.3). A take recorded without its arm cannot be recovered into
/// the comparison afterwards — which is why this lands before the experiment runner rather than
/// with it.
///
/// It is also the first schema change since T1, so it is the first one arriving with a
/// round-trip property already waiting for it.
final class ExperimentStorageTests: StoreBackedTestCase {

    func testAnArmSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let assigned = TakeFactory.assignment(arm: "melodic", runIndex: 3)
        try SessionStore.save(TakeFactory.jam(experiment: assigned))

        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        XCTAssertEqual(loaded.experiment, assigned)
        XCTAssertEqual(loaded.experiment?.arm, "melodic")
        XCTAssertEqual(loaded.experiment?.runIndex, 3)
        // The placement still stands beside it: the arm says which condition, the placement
        // says where in the evening. Checking one against the other is how M13 detects an arm
        // that drifted toward the tired end of a sitting.
        XCTAssertEqual(loaded.placement?.role, "benchmark")
    }

    /// R6.1: the field is additive, so a take played outside an experiment still decodes.
    func testATakeWithNoExperimentStillDecodes() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam())

        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        XCTAssertNil(loaded.experiment)
        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
    }

    /// The real compatibility question: a file written *before* the field existed.
    ///
    /// Every take on disk today is one of these, and R6.1 says all of them must keep decoding.
    /// Deleting the key from encoded JSON is the closest a test can get to a take from 4 August.
    func testATakeWrittenBeforeTheFieldExistedStillDecodes() throws {
        assertStoreIsRedirected()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(TakeFactory.jam(experiment: TakeFactory.assignment(arm: "steady")))
        ) as? [String: Any])
        json.removeValue(forKey: "experiment")
        XCTAssertNil(json["experiment"])

        try JSONSerialization.data(withJSONObject: json)
            .write(to: storeURL.appendingPathComponent("jam-20260804-014315.json"))

        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty,
                      "a take from before the field existed must not become unreadable")
        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        XCTAssertNil(loaded.experiment)
        XCTAssertFalse(loaded.report().asynchroniesMs.isEmpty, "and it must still analyse")
    }

    /// The arm comes from the plan, so a take is stamped with the condition the plan said it
    /// would run under rather than one decided at save time.
    func testTheRunnerCarriesTheArmFromTheBlock() {
        let assigned = TakeFactory.assignment(arm: "steady", runIndex: 1)
        let block = SessionBlock(role: .benchmark,
                                 plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "benchmark")),
                                 reason: "the locked slot", experiment: assigned)
        let runner = SessionRunner(plan: SessionPlan(targetMinutes: 20, blocks: [block], notes: []))

        XCTAssertEqual(runner.currentBlock?.experiment, assigned)
    }

    /// The planner now assigns arms, and everything downstream of that exists.
    ///
    /// This test was written in step 1 asserting the *opposite* — that no block carried an arm —
    /// as a tripwire that would fail the moment step 4 started assigning them, which is when the
    /// analysis had to exist to receive them. It fired on schedule. What it guards now is the
    /// whole chain: the planner assigns, the block carries, the runner would stamp, and step 3's
    /// readout is there to read it.
    func testThePlannerAssignsAnArmAndTheChainCarriesIt() throws {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
            let assigned = plan.blocks.compactMap(\.experiment)
            XCTAssertEqual(assigned.count, 1, "\(minutes) min: exactly one arm per session")

            let runner = SessionRunner(plan: plan)
            let block = try XCTUnwrap(plan.blocks.first { $0.experiment != nil })
            XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                           DrillInstructions.jam(arm: block.experiment?.arm).steps,
                           "the arm's own instructions, not the generic jam text")
            XCTAssertFalse(runner.isFinished)
        }
    }
}
