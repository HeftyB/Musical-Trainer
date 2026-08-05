import XCTest
@testable import TimingCore

/// M13 step 2: assignment and the stopping rule, against planted histories.
final class ExperimentTests: XCTestCase {

    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()

    private func design(arms: [String] = ["steady", "melodic"],
                        takesPerArm: Int = 4) -> ExperimentDesign {
        guard let d = ExperimentDesign(id: id, name: "steady-vs-melodic",
                                       question: "Does playing a melody change how you time it?",
                                       arms: arms, metric: .spread, takesPerArm: takesPerArm) else {
            preconditionFailure("the fixture design must be valid")
        }
        return d
    }

    // MARK: - The design refuses what it cannot answer

    func testADesignNeedsAtLeastTwoDistinctArms() {
        XCTAssertNil(ExperimentDesign(name: "x", question: "q", arms: ["only"],
                                      metric: .spread, takesPerArm: 4))
        XCTAssertNil(ExperimentDesign(name: "x", question: "q", arms: ["a", "a"],
                                      metric: .spread, takesPerArm: 4))
        XCTAssertNil(ExperimentDesign(name: "x", question: "q", arms: ["a", ""],
                                      metric: .spread, takesPerArm: 4))
    }

    /// One take per arm cannot see between-take variation at all — the whole of §7.20 finding 1.
    func testADesignNeedsMoreThanOneTakePerArm() {
        XCTAssertNil(ExperimentDesign(name: "x", question: "q", arms: ["a", "b"],
                                      metric: .spread, takesPerArm: 1))
        XCTAssertNotNil(ExperimentDesign(name: "x", question: "q", arms: ["a", "b"],
                                         metric: .spread, takesPerArm: 2))
    }

    /// Bias is reported, never scored. Variance is the skill (§2).
    func testBiasHasNoBetterDirection() {
        XCTAssertNil(ExperimentMetric.bias.lowerIsBetter)
        XCTAssertEqual(ExperimentMetric.spread.lowerIsBetter, true)
    }

    // MARK: - Balance

    func testTheArmsNeverDriftMoreThanOneTakeApart() {
        let d = design()
        var completed: [String] = []
        for _ in 0..<20 {
            completed.append(ExperimentSchedule.nextArm(design: d, completed: completed))
            let counts = d.arms.map { arm in completed.filter { $0 == arm }.count }
            let spread = (counts.max() ?? 0) - (counts.min() ?? 0)
            XCTAssertLessThanOrEqual(spread, 1, "after \(completed.count): \(counts)")
        }
    }

    func testBalanceHoldsWithThreeArmsToo() {
        let d = design(arms: ["quarters", "melody", "free"], takesPerArm: 3)
        var completed: [String] = []
        for _ in 0..<21 {
            completed.append(ExperimentSchedule.nextArm(design: d, completed: completed))
        }
        let counts = d.arms.map { arm in completed.filter { $0 == arm }.count }
        XCTAssertEqual(Set(counts).count, 1, "21 takes over 3 arms should be exactly even: \(counts)")
    }

    /// A gap is filled rather than perpetuated: if one arm is behind, it goes next.
    func testAnArmThatIsBehindIsScheduledNext() {
        let d = design()
        XCTAssertEqual(ExperimentSchedule.nextArm(design: d, completed: ["steady", "steady"]),
                       "melodic")
    }

    // MARK: - Counterbalancing

    /// The arm that goes first must not always be the same one.
    ///
    /// §7.17 has two takes identical on every number rated 4 and 1 twenty minutes apart. An arm
    /// that always ran first would carry the whole of that freshness difference and report it as
    /// a condition effect.
    func testTheFirstArmIsNotAlwaysTheSameAcrossExperiments() {
        let firsts = (0..<40).map { n -> String in
            let d = ExperimentDesign(id: UUID(uuidString: String(format:
                        "%08X-0000-0000-0000-000000000000", n)) ?? UUID(),
                     name: "e\(n)", question: "q", arms: ["a", "b"],
                     metric: .spread, takesPerArm: 4)
            return ExperimentSchedule.nextArm(design: d!, completed: [])
        }
        XCTAssertEqual(Set(firsts).count, 2, "both arms must lead sometimes: \(Set(firsts))")
    }

    /// An arm can repeat once, never twice.
    ///
    /// Strict alternation was the obvious thing to assert and is the wrong design: `ABABAB`
    /// puts one arm in every odd position, so any effect of *where in the sequence* a take
    /// falls lands entirely on one arm. What the min-count rule produces instead is a random
    /// `ABBA`-like sequence — a repeat can only happen across a tie, and after it that arm is
    /// ahead so the other must follow. Two is therefore the ceiling, and position stays even.
    func testNoArmEverRunsMoreThanTwiceInARow() {
        let d = design()
        var completed: [String] = []
        for _ in 0..<40 {
            completed.append(ExperimentSchedule.nextArm(design: d, completed: completed))
        }
        var run = 1
        for (a, b) in zip(completed, completed.dropFirst()) {
            run = a == b ? run + 1 : 1
            XCTAssertLessThanOrEqual(run, 2, "a run of \(run) in \(completed)")
        }
    }

    /// Neither arm may monopolise the odd or even slots, which is what strict alternation does
    /// and what would let position masquerade as a condition effect.
    func testNeitherArmMonopolisesThePositions() {
        let d = design(takesPerArm: 40)
        var completed: [String] = []
        for _ in 0..<40 {
            completed.append(ExperimentSchedule.nextArm(design: d, completed: completed))
        }
        let evens = completed.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let steadyOnEvens = evens.filter { $0 == "steady" }.count
        XCTAssertGreaterThan(steadyOnEvens, 2, "steady never leads: \(completed)")
        XCTAssertLessThan(steadyOnEvens, evens.count - 2, "steady always leads: \(completed)")
    }

    /// R1.2.2: the schedule must be recoverable from stored data, on any launch.
    ///
    /// Seeded from the design's UUID bytes rather than `hashValue`, which Swift salts per
    /// process — that would give a different schedule every launch while looking deterministic.
    func testTheScheduleIsReproducible() {
        let d = design()
        let first = (0..<8).reduce(into: [String]()) { acc, _ in
            acc.append(ExperimentSchedule.nextArm(design: d, completed: acc))
        }
        let second = (0..<8).reduce(into: [String]()) { acc, _ in
            acc.append(ExperimentSchedule.nextArm(design: d, completed: acc))
        }
        XCTAssertEqual(first, second)
    }

    // MARK: - The stopping rule

    func testNoPowerUntilEveryArmReachesTheTarget() {
        let d = design(takesPerArm: 3)
        XCTAssertFalse(ExperimentSchedule.progress(design: d, completed: []).hasPower)
        // Five takes, but one arm has only two.
        let lopsided = ["steady", "melodic", "steady", "melodic", "steady"]
        let p = ExperimentSchedule.progress(design: d, completed: lopsided)
        XCTAssertFalse(p.hasPower, "an arm short of target is not power, whatever the total")
        XCTAssertEqual(p.takesRemaining, 1)
        XCTAssertEqual(p.nextArm, "melodic")
    }

    func testPowerArrivesExactlyAtTheTarget() {
        let d = design(takesPerArm: 2)
        let p = ExperimentSchedule.progress(
            design: d, completed: ["steady", "melodic", "steady", "melodic"])
        XCTAssertTrue(p.hasPower)
        XCTAssertEqual(p.takesRemaining, 0)
        XCTAssertEqual(p.takesPerArm, [2, 2])
    }

    /// Below the target the app says how many takes remain and nothing else. Optional stopping
    /// plus a bootstrap eventually manufactures a result, so the headline must not hint at one.
    func testTheHeadlineNeverHintsAtAResultBeforeItHasPower() {
        let d = design(takesPerArm: 4)
        for completed in [[], ["steady"], ["steady", "melodic", "steady"]] {
            let p = ExperimentSchedule.progress(design: d, completed: completed)
            XCTAssertFalse(p.hasPower)
            for word in ["real change", "within noise", "better", "worse", "wins"] {
                XCTAssertFalse(p.headline.lowercased().contains(word),
                               "\"\(word)\" in: \(p.headline)")
            }
        }
    }

    func testAnAssignmentCarriesTheRunIndexAndArm() {
        let d = design()
        let first = ExperimentSchedule.assignment(design: d, completed: [])
        XCTAssertEqual(first.runIndex, 0)
        XCTAssertEqual(first.experimentId, d.id)
        XCTAssertEqual(first.name, d.name)

        let third = ExperimentSchedule.assignment(design: d, completed: ["steady", "melodic"])
        XCTAssertEqual(third.runIndex, 2)
        XCTAssertTrue(d.arms.contains(third.arm))
    }

    /// A take whose arm is no longer in the design must not be silently counted as another.
    func testAnUnknownArmIsNotCountedTowardAnyArm() {
        let d = design(takesPerArm: 2)
        let p = ExperimentSchedule.progress(
            design: d, completed: ["steady", "melodic", "retired-arm", "steady", "melodic"])
        XCTAssertEqual(p.takesPerArm, [2, 2])
        XCTAssertTrue(p.hasPower)
        XCTAssertEqual(p.runIndex, 5, "the take still happened, it just counts toward no arm")
    }
}
