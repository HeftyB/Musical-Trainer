import XCTest
@testable import TimingCore

/// A probe is not a rung.
///
/// Level 3 — silence across the phrase boundary — is the level the form drill was designed
/// around and has never run. Not because it was locked: both surfaces have always offered it.
/// It has never run because nothing proposed it, and the promotion gate needs 90% on form from a
/// player sitting at 75%.
///
/// The trap that makes the role load-bearing: the planner picks the next level from the **last**
/// take, so one forced level-3 take becomes the new floor and every later session plans level 3
/// while reporting that the player is staying there until they clear 90%. See PLAN.md §7.26.
final class FormProbeTests: XCTestCase {

    private func form(level: Int, phraseBars: Int = 8, onFormRate: Double = 0.75,
                      unmarked: Bool = true, probe: Bool = false) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          hasUnmarkedPhrases: unmarked, markedEveryBars: nil, wasProbe: probe)
    }

    private func firstForm(_ plan: SessionPlan) -> (block: SessionBlock, plan: FormPlan)? {
        for block in plan.blocks {
            if case .form(let p) = block.plan { return (block, p) }
        }
        return nil
    }

    private func planned(_ forms: [PlannerInput.Form]) -> (block: SessionBlock, plan: FormPlan)? {
        firstForm(SessionPlanner.plan(targetMinutes: 30, from: PlannerInput(forms: forms)))
    }

    private var heldAtTwo: [PlannerInput.Form] {
        Array(repeating: form(level: 2), count: SessionPlanner.probeAfterHeldTakes)
    }

    // MARK: - When it fires

    func testStuckAtALevelEarnsAProbeAtTheTop() throws {
        let result = try XCTUnwrap(planned(heldAtTwo))
        XCTAssertEqual(result.plan.level, SessionPlanner.probeLevel)
        XCTAssertEqual(result.block.role, .probe,
                       "the role is what stops this reading as a promotion")
    }

    func testTheProbeMovesTheLevelAndNothingElse() throws {
        let history = Array(repeating: form(level: 2, phraseBars: 4),
                            count: SessionPlanner.probeAfterHeldTakes)
        let result = try XCTUnwrap(planned(history))
        XCTAssertEqual(result.plan.phraseBars, 4,
                       "moving the phrase length too would confound the one reading this exists "
                     + "to get — the same rule M16's two axes are built on")
        XCTAssertEqual(result.plan.bpm, SessionPlanner.referenceBpm)
    }

    func testUnmarkedPhrasesDoNotBlockTheProbe() throws {
        // Deliberate, and the opposite of the promotion gate. The takes that make a player stuck
        // are the ones with unmarked phrases; requiring none would offer the probe only to
        // someone about to be promoted anyway, which is nobody who needs it.
        let result = try XCTUnwrap(planned(heldAtTwo.map { _ in form(level: 2, unmarked: true) }))
        XCTAssertEqual(result.block.role, .probe)
    }

    // MARK: - When it must not

    func testOneStuckTakeIsNotEnough() throws {
        let result = try XCTUnwrap(planned([form(level: 2)]))
        XCTAssertEqual(result.plan.level, 2)
        XCTAssertEqual(result.block.role, .training)
    }

    func testAnEarnedPromotionBeatsAProbe() throws {
        var history = heldAtTwo
        history.append(form(level: 2, onFormRate: 1.0, unmarked: false))
        let result = try XCTUnwrap(planned(history))
        XCTAssertEqual(result.plan.level, 3)
        XCTAssertEqual(result.block.role, .training,
                       "an earned level is worth more than a probed one, so the gate wins")
    }

    func testAMovingPhraseLengthBeatsAProbe() throws {
        var history = heldAtTwo
        history.append(form(level: 2, phraseBars: 8))
        history.append(contentsOf: [
            PlannerInput.Form(level: 2, phraseBars: 8, onFormRate: 0.75,
                              hasUnmarkedPhrases: true, markedEveryBars: 4),
            PlannerInput.Form(level: 2, phraseBars: 8, onFormRate: 0.75,
                              hasUnmarkedPhrases: true, markedEveryBars: 4),
        ])
        let result = try XCTUnwrap(planned(history))
        XCTAssertEqual(result.plan.phraseBars, 4, "a confound to settle comes first")
        XCTAssertEqual(result.block.role, .training)
    }

    func testTheProbeIsOfferedOnlyOnce() throws {
        var history = heldAtTwo
        history.append(form(level: 3, onFormRate: 0.2, probe: true))
        let result = try XCTUnwrap(planned(history))
        XCTAssertNotEqual(result.plan.level, SessionPlanner.probeLevel,
                          "one reading is the point; a second would be a rung, and rungs are "
                        + "earned")
        XCTAssertEqual(result.block.role, .training)
    }

    // MARK: - The trap the role exists to prevent

    /// Revert `wasProbe` filtering and this is what happens: a take handed to the player for one
    /// reading becomes the level the planner holds them at from then on.
    func testAProbeDoesNotBecomeTheNewFloor() throws {
        var history = heldAtTwo
        history.append(form(level: 3, onFormRate: 0.2, probe: true))
        let result = try XCTUnwrap(planned(history))

        XCTAssertEqual(result.plan.level, 2,
                       "the ladder is where it was earned, not where it was probed")
        XCTAssertTrue(result.block.reason.contains("level 2"), result.block.reason)
    }

    func testAProbeDoesNotDragThePhraseLengthEither() throws {
        var history = Array(repeating: form(level: 2, phraseBars: 8),
                            count: SessionPlanner.probeAfterHeldTakes)
        history.append(PlannerInput.Form(level: 3, phraseBars: 32, onFormRate: 0.2,
                                         hasUnmarkedPhrases: true, markedEveryBars: 32,
                                         wasProbe: true))
        let result = try XCTUnwrap(planned(history))
        XCTAssertEqual(result.plan.phraseBars, 8,
                       "the felt-period rule must not read a probe either — it is one take at a "
                     + "task the player was handed")
    }
}
