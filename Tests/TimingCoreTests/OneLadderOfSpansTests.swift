import XCTest
@testable import TimingCore

/// One list of legal phrase spans, and a ladder nothing can be stranded off.
///
/// There were two lists: `SessionPlanner.phraseSpanLadder` at `[4, 8, 16, 32]`, and a
/// `[2, 4, 8, 16, 32]` written out **twice** inside the felt-period rule. They agreed about four
/// entries of five, which is exactly how long a disagreement goes unnoticed (`LESSONS.md` shape 9).
///
/// The fifth entry was not harmless. A player marking a steady 2-bar period twice running was moved
/// onto a 2-bar phrase — a span the ladder did not contain, the app's picker could not display, and
/// `nextSpan` could not climb off, so the spatial ladder was finished for good.
final class OneLadderOfSpansTests: XCTestCase {

    private func form(phraseBars: Int, felt: [Double?],
                      onFormRate: Double = 0.5) -> [PlannerInput.Form] {
        felt.map {
            PlannerInput.Form(level: 2, phraseBars: phraseBars, onFormRate: onFormRate,
                              cleanRate: 0.5, hasUnmarkedPhrases: false, markedEveryBars: $0)
        }
    }

    private func plan(_ forms: [PlannerInput.Form]) -> FormPlan? {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(forms: forms))
        for block in plan.blocks { if case .form(let p) = block.plan { return p } }
        return nil
    }

    private func notes(_ forms: [PlannerInput.Form]) -> [String] {
        SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(forms: forms)).notes
    }

    // MARK: The list the planner may ask for

    /// Every span the planner can name is a rung, whatever the history says.
    func testThePlannerOnlyEverAsksForARungOfTheLadder() {
        let candidates: [Double?] = [2, 3, 4, 5, 6, 8, 13, 16, 32, 64, nil]
        for felt in candidates {
            for span in [4, 8, 16, 32] {
                let history = form(phraseBars: span, felt: [felt, felt], onFormRate: 1.0)
                guard let planned = plan(history) else { return XCTFail("no form block") }
                XCTAssertTrue(SessionPlanner.phraseSpanLadder.contains(planned.phraseBars),
                              "felt \(String(describing: felt)) at \(span) bars produced "
                            + "\(planned.phraseBars)")
            }
        }
    }

    /// The case that used to move the drill off the ladder, asserted directly.
    func testASteadyTwoBarPeriodDoesNotMoveTheDrillOntoATwoBarPhrase() {
        let history = form(phraseBars: 8, felt: [2, 2])
        XCTAssertEqual(plan(history)?.phraseBars, 8)
    }

    /// A rung it *does* contain still moves, so this closed a door without locking the corridor.
    func testASteadyFourBarPeriodStillMovesTheDrill() {
        XCTAssertEqual(plan(form(phraseBars: 8, felt: [4, 4]))?.phraseBars, 4)
    }

    /// R3.3: a measurement that cannot be acted on is said, not swallowed. Declining in silence
    /// would leave the drill at a span the player has visibly abandoned with nothing accounting
    /// for it.
    func testAnOffLadderFeltPeriodIsReportedRatherThanIgnored() {
        let said = notes(form(phraseBars: 8, felt: [2, 2])).joined(separator: " ")
        XCTAssertTrue(said.contains("2-bar phrase"), said)
        XCTAssertTrue(said.contains("not one of the lengths this drill runs"), said)
    }

    /// And the note names the rungs from the list rather than from a second copy of it, so a rung
    /// added later appears in the sentence without anybody remembering to edit it.
    func testTheNoteNamesTheLaddersOwnRungs() {
        let said = notes(form(phraseBars: 8, felt: [2, 2])).joined(separator: " ")
        XCTAssertTrue(said.contains(SessionPlanner.phraseSpanLadder.map(String.init)
                                        .joined(separator: ", ")), said)
    }

    // MARK: Nothing is stranded

    /// The property the old `nextSpan` broke: from anywhere, the ladder is climbable.
    func testEverySpanBelowTheTopHasARungAboveIt() {
        for span in 2...31 {
            let next = SessionPlanner.nextSpan(after: span)
            XCTAssertNotNil(next, "\(span)-bar phrases had nowhere to go")
            XCTAssertTrue(next.map { $0 > span } ?? false, "\(span) → \(String(describing: next))")
        }
        XCTAssertNil(SessionPlanner.nextSpan(after: 32), "32 is the top rung")
    }

    /// A take run by hand at a span off the ladder — which `FormConfig.validate` allows on purpose,
    /// the same affordance as `--probe` — must not end the spatial ladder for that player.
    func testAHandRunSpanDoesNotEndTheSpatialLadder() {
        let history = form(phraseBars: 6, felt: [nil, nil], onFormRate: 1.0)
        XCTAssertEqual(SessionPlanner.formAxis(for: history[1]), .spatial)
        XCTAssertEqual(plan(history)?.phraseBars, 8, "6 bars should climb to the next rung up")
    }
}
