import XCTest
@testable import TimingCore
@testable import TrainerKit

/// M13 step 5: the readout both surfaces share.
final class ExperimentReadoutTests: StoreBackedTestCase {

    /// Every design in the library must use a metric a jam can actually produce.
    ///
    /// An experiment declared on `interferenceCost` or `tempoError` would collect takes forever
    /// while reporting "still collecting", because the readout can derive no value for them yet.
    /// That is the most expensive quiet failure available here — evenings spent on an experiment
    /// that cannot finish — so it is a test rather than a comment.
    func testEveryDeclaredExperimentUsesAJamDerivableMetric() {
        for design in ExperimentLibrary.all {
            XCTAssertTrue([.spread, .bias, .correctionGain].contains(design.metric),
                          "\(design.name) uses \(design.metric.label), which no jam produces")
        }
    }

    func testTheReadoutCountsTakesIntoTheirArms() throws {
        assertStoreIsRedirected()
        let design = try XCTUnwrap(ExperimentLibrary.steadyVsMelodic)
        for (index, arm) in ["steady", "melodic", "steady"].enumerated() {
            try SessionStore.save(TakeFactory.jam(
                experiment: ExperimentAssignment(experimentId: design.id, name: design.name,
                                                 arm: arm, runIndex: index)))
        }

        let result = try XCTUnwrap(
            TrainerEngine.experimentResults().first { $0.design.name == design.name })
        XCTAssertEqual(result.arms.first { $0.arm == "steady" }?.scored, 2)
        XCTAssertEqual(result.arms.first { $0.arm == "melodic" }?.scored, 1)
        XCTAssertEqual(result.verdict, .collecting(takesRemaining: design.takesPerArm * 2 - 3))
    }

    /// A take belonging to no experiment must not be counted into one.
    func testUnassignedTakesAreIgnored() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(tag: "benchmark"))
        try SessionStore.save(TakeFactory.jam(tag: "closing"))

        for result in TrainerEngine.experimentResults() {
            XCTAssertTrue(result.arms.allSatisfy { $0.assigned == 0 }, result.design.name)
        }
    }

    /// The metric comes from the recomputed report, never the stored summary (R3.1).
    ///
    /// It matters more here than anywhere: an experiment's arms may be weeks apart, so an
    /// analysis fix landing between them would otherwise compare a take under the old analysis
    /// with one under the new.
    func testTheMetricIsRecomputedRatherThanReadFromTheStoredSummary() throws {
        assertStoreIsRedirected()
        let design = try XCTUnwrap(ExperimentLibrary.steadyVsMelodic)
        let take = TakeFactory.jam(
            experiment: ExperimentAssignment(experimentId: design.id, name: design.name,
                                             arm: "steady", runIndex: 0))
        try SessionStore.save(take)

        let result = try XCTUnwrap(
            TrainerEngine.experimentResults().first { $0.design.name == design.name })
        let arm = try XCTUnwrap(result.arms.first { $0.arm == "steady" })
        XCTAssertEqual(try XCTUnwrap(arm.mean), take.report().sdAsynchronyMs, accuracy: 1e-9)
    }

    /// Below target the readout carries no comparison at all — on either surface.
    func testNoComparisonIsOfferedWhileCollecting() throws {
        assertStoreIsRedirected()
        let design = try XCTUnwrap(ExperimentLibrary.steadyVsMelodic)
        try SessionStore.save(TakeFactory.jam(
            experiment: ExperimentAssignment(experimentId: design.id, name: design.name,
                                             arm: "steady", runIndex: 0)))

        let result = try XCTUnwrap(
            TrainerEngine.experimentResults().first { $0.design.name == design.name })
        XCTAssertNil(result.difference)
        XCTAssertNil(result.minimumDetectableEffect, "one take supports no spread estimate")
    }
}
