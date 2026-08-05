import XCTest
import TestSupport
@testable import TimingCore

/// M13 step 3: the readout, and what it refuses to say.
final class ExperimentAnalysisTests: XCTestCase {

    private let sitting = UUID()

    private func design(takesPerArm: Int = 4,
                        arms: [String] = ["steady", "melodic"],
                        metric: ExperimentMetric = .spread) -> ExperimentDesign {
        guard let d = ExperimentDesign(name: "steady-vs-melodic", question: "q",
                                       arms: arms, metric: metric,
                                       takesPerArm: takesPerArm) else {
            preconditionFailure("fixture must be valid")
        }
        return d
    }

    /// `count` takes for one arm, each a per-take value drawn around `mean`.
    private func takes(_ arm: String, _ values: [Double],
                       elapsed: Double = 12, sitting: UUID? = nil) -> [ExperimentTake] {
        values.map { ExperimentTake(arm: arm, value: $0, elapsedMinutes: elapsed,
                                    sittingId: sitting ?? self.sitting) }
    }

    // MARK: - The stopping rule comes first

    func testNothingIsComparedBelowTheTarget() {
        let d = design(takesPerArm: 4)
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [20, 21, 22]) + takes("melodic", [18, 19, 20]))

        XCTAssertEqual(r.verdict, .collecting(takesRemaining: 2))
        XCTAssertNil(r.difference, "no interval may exist below target, not even unshown")
        for word in ["real", "no difference", "lower", "wins"] {
            XCTAssertFalse(r.headline.lowercased().contains(word), r.headline)
        }
    }

    /// A take that could not be scored does not count toward the target.
    func testAnUnscorableTakeDoesNotCountTowardTheTarget() {
        let d = design(takesPerArm: 2)
        let unscorable = [ExperimentTake(arm: "steady", value: nil, elapsedMinutes: 12,
                                         sittingId: sitting)]
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [20]) + unscorable + takes("melodic", [18, 19]))
        XCTAssertEqual(r.verdict, .collecting(takesRemaining: 1))
    }

    // MARK: - The comparison

    func testAConsistentDifferenceIsFound() {
        let d = design(takesPerArm: 5)
        // Melodic is ~6 ms tighter in every take, with realistic take-to-take wobble.
        let r = ExperimentAnalysis.analyze(
            design: d,
            takes: takes("steady", [24.0, 22.5, 25.5, 23.0, 24.5])
                 + takes("melodic", [18.0, 17.0, 19.5, 17.5, 18.5]))

        XCTAssertEqual(r.verdict, .difference(lowerArm: "melodic"))
        XCTAssertTrue(try XCTUnwrap(r.difference).excludesZero)
        XCTAssertTrue(r.headline.contains("melodic"), r.headline)
    }

    /// The between-take spread this project actually shows is large. Two arms drawn from it must
    /// not be called different — that is §7.20 finding 1 arriving as an experiment.
    func testTakeToTakeWobbleIsNotCalledAConditionEffect() {
        let d = design(takesPerArm: 5)
        // Both arms drawn around 21 ms with the ±4 ms spread the benchmark jams actually show.
        let r = ExperimentAnalysis.analyze(
            design: d,
            takes: takes("steady", [24.1, 17.4, 22.0, 20.2, 19.9])
                 + takes("melodic", [22.6, 18.9, 23.4, 19.1, 21.0]))

        XCTAssertEqual(r.verdict, .noDifferenceFound)
        XCTAssertFalse(try XCTUnwrap(r.difference).excludesZero)
    }

    func testTheArmSummariesAreTheTakeLevelFigures() throws {
        let d = design(takesPerArm: 2)
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [20, 30]) + takes("melodic", [10, 20]))

        let steady = try XCTUnwrap(r.arms.first { $0.arm == "steady" })
        XCTAssertEqual(try XCTUnwrap(steady.mean), 25, accuracy: 1e-9)
        XCTAssertEqual(steady.scored, 2)
        XCTAssertEqual(steady.assigned, 2)
        // Between-take SD is what the interval rests on, so it is reported, not hidden.
        XCTAssertEqual(try XCTUnwrap(steady.betweenTakeSD), Stats.sd([20, 30]), accuracy: 1e-9)
    }

    // MARK: - What makes the arms non-comparable

    /// The same rule as the recall drill's retention conditions: an arm that lost more takes is
    /// scored on a self-selected set.
    func testUnequalAttritionBlocksTheComparison() {
        let d = design(takesPerArm: 2)
        let dropped = (0..<3).map { _ in
            ExperimentTake(arm: "steady", value: nil, elapsedMinutes: 12, sittingId: sitting)
        }
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [20, 21]) + dropped + takes("melodic", [18, 19]))

        guard case .unusable(let reason) = r.verdict else {
            return XCTFail("expected unusable, got \(r.verdict)")
        }
        XCTAssertTrue(reason.contains("self-selected"), reason)
        XCTAssertNil(r.difference)
    }

    /// Arms that ran at different points in the evening are confounded with fatigue.
    func testArmsRunAtDifferentPointsInASittingAreFlagged() {
        let d = design(takesPerArm: 2)
        let r = ExperimentAnalysis.analyze(
            design: d,
            takes: takes("steady", [20, 21], elapsed: 4) + takes("melodic", [18, 19], elapsed: 27))

        XCTAssertTrue(r.notes.contains { $0.contains("same point in a sitting") },
                      "position confound must be named: \(r.notes)")
    }

    func testAnArmConfinedToOneSittingIsFlagged() {
        let d = design(takesPerArm: 2)
        let other = UUID()
        let r = ExperimentAnalysis.analyze(
            design: d,
            takes: takes("steady", [20, 21], sitting: sitting)
                 + [ExperimentTake(arm: "melodic", value: 18, elapsedMinutes: 12, sittingId: sitting),
                    ExperimentTake(arm: "melodic", value: 19, elapsedMinutes: 12, sittingId: other)])

        XCTAssertTrue(r.notes.contains { $0.contains("'steady' take comes from one sitting") },
                      r.notes.description)
    }

    /// Bias is reported, never scored — so an experiment on it always says so.
    func testABiasExperimentSaysItHasNoBetterDirection() {
        let d = design(takesPerArm: 2, metric: .bias)
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [-6, -8]) + takes("melodic", [-21, -23]))
        XCTAssertTrue(r.notes.contains { $0.contains("no better direction") }, r.notes.description)
    }

    func testMoreThanTwoArmsRefusesASingleVerdict() {
        let d = design(takesPerArm: 2, arms: ["quarters", "melody", "free"])
        let r = ExperimentAnalysis.analyze(
            design: d,
            takes: takes("quarters", [24, 25]) + takes("melody", [18, 19]) + takes("free", [21, 22]))

        XCTAssertNil(r.difference)
        XCTAssertTrue(r.notes.contains { $0.contains("several") }, r.notes.description)
    }

    // MARK: - Power

    /// The MDE has to reflect the spread actually seen, not a hoped-for one.
    func testTheDetectableEffectGrowsWithTakeToTakeSpread() {
        let d = design(takesPerArm: 4)
        let tight = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [20, 20.2, 19.8, 20.1])
                            + takes("melodic", [18, 18.1, 17.9, 18.2]))
        let loose = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [14, 26, 18, 22])
                            + takes("melodic", [12, 24, 16, 20]))

        let tightMDE = try? XCTUnwrap(tight.minimumDetectableEffect)
        let looseMDE = try? XCTUnwrap(loose.minimumDetectableEffect)
        XCTAssertLessThan(try XCTUnwrap(tightMDE), try XCTUnwrap(looseMDE))
    }

    /// Chasing a smaller effect costs takes, and it costs them quadratically.
    ///
    /// Asserted as a band rather than exactly ×4: both figures are rounded up and the answer is
    /// floored at two takes, so near the floor the relationship is stepped rather than smooth.
    /// The effects here are chosen above it — which is itself the point, since an experiment
    /// asking for a difference smaller than its own take-to-take wobble needs a lot of evenings.
    func testHalvingTheEffectQuadruplesTheTakesNeeded() throws {
        let d = design(takesPerArm: 4)
        let r = ExperimentAnalysis.analyze(
            design: d, takes: takes("steady", [24, 22, 26, 23]) + takes("melodic", [18, 17, 20, 19]))

        let forTwo = try XCTUnwrap(ExperimentAnalysis.takesNeeded(forEffect: 2, arms: r.arms))
        let forOne = try XCTUnwrap(ExperimentAnalysis.takesNeeded(forEffect: 1, arms: r.arms))
        XCTAssertGreaterThan(forTwo, 2, "the fixture must sit above the two-take floor")
        XCTAssertGreaterThan(Double(forOne), Double(forTwo) * 3)
        XCTAssertLessThan(Double(forOne), Double(forTwo) * 5)
    }

    func testPowerFiguresAreAbsentRatherThanGuessedWithoutData() {
        let d = design(takesPerArm: 2)
        let r = ExperimentAnalysis.analyze(design: d, takes: [])
        XCTAssertNil(r.minimumDetectableEffect)
        XCTAssertNil(ExperimentAnalysis.takesNeeded(forEffect: 3, arms: r.arms))
    }
}
