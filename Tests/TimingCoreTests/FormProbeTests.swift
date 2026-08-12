import XCTest
@testable import TimingCore

/// A probe is not a rung.
///
/// The planner does not propose one — a testing affordance in the planner is a testing affordance
/// in the business logic, changing what the app recommends to a player who is not testing
/// anything. Probes are launched from the shell with `--probe`, and the only thing the planner
/// knows about them is that they must not count.
///
/// The trap that makes the flag load-bearing: the form rule picks the next level from the **last**
/// take, so one level-3 take run by hand becomes the new floor and every later session plans
/// level 3 while reporting that the player is staying there until they clear 90%. See PLAN.md
/// §7.26.
///
/// These live in `TimingCoreTests` rather than beside the storage tests so they run on Linux —
/// `TrainerKitTests` is macOS-only, so a guard placed there alone is a guard CI never sees.
final class FormProbeTests: XCTestCase {

    private func form(level: Int, phraseBars: Int = 8, onFormRate: Double = 0.75,
                      markedEvery: Double? = nil, probe: Bool = false) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          hasUnmarkedPhrases: true, markedEveryBars: markedEvery,
                          wasProbe: probe)
    }

    private func plannedForm(_ forms: [PlannerInput.Form]) -> FormPlan? {
        let plan = SessionPlanner.plan(targetMinutes: 30, from: PlannerInput(forms: forms))
        for block in plan.blocks {
            if case .form(let p) = block.plan { return p }
        }
        return nil
    }

    func testAProbeDoesNotBecomeTheNewFloor() throws {
        let history = [form(level: 2), form(level: 2), form(level: 3, probe: true)]
        let planned = try XCTUnwrap(plannedForm(history))
        XCTAssertEqual(planned.level, 2,
                       "the ladder is where it was earned, not where it was probed")
    }

    func testAnUnflaggedTakeAtTheSameLevelDoesMoveIt() throws {
        let history = [form(level: 2), form(level: 2), form(level: 3)]
        let planned = try XCTUnwrap(plannedForm(history))
        XCTAssertEqual(planned.level, 3,
                       "the flag is the whole distinction — without it this is evidence like "
                     + "any other take")
    }

    func testTheFeltPeriodRuleDoesNotReadAProbeEither() throws {
        // Two probes agreeing on a 32-bar felt period would otherwise satisfy the two-takes-
        // agree rule and drag the phrase length with them.
        let history = [form(level: 2, phraseBars: 8),
                       form(level: 2, phraseBars: 8),
                       form(level: 3, phraseBars: 8, markedEvery: 32, probe: true),
                       form(level: 3, phraseBars: 8, markedEvery: 32, probe: true)]
        let planned = try XCTUnwrap(plannedForm(history))
        XCTAssertEqual(planned.phraseBars, 8)
        XCTAssertEqual(planned.level, 2)
    }

    func testAHistoryOfNothingButProbesPlansFromScratch() throws {
        let planned = try XCTUnwrap(plannedForm([form(level: 3, probe: true)]))
        XCTAssertEqual(planned.level, 0,
                       "no earned take means no ladder position, which is where a player with "
                     + "no form data starts")
        XCTAssertEqual(planned.phraseBars, 8)
    }

    func testTheLadderStillPromotesOnEarnedTakes() throws {
        // Carries a high `cleanRate` because the level ladder is promoted on landing cleanly
        // (§7.41). The claim here is about probes not touching the ordinary path, so the
        // ordinary path has to be one that actually promotes.
        let clean = PlannerInput.Form(level: 1, phraseBars: 8, onFormRate: 1.0, cleanRate: 1.0,
                                      hasUnmarkedPhrases: false, markedEveryBars: nil)
        XCTAssertEqual(try XCTUnwrap(plannedForm([clean])).level, 2,
                       "nothing about probes may touch the ordinary path")
    }
}
