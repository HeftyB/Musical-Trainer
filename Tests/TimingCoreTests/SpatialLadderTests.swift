import XCTest
@testable import TimingCore

/// The phrase span is a ladder about *holding your place*, and is promoted on knowing the bar.
///
/// Growing the phrase asks the player to carry their position across more music. It changes
/// nothing about the cues that say when to land — a 32-bar phrase at level 2 has exactly the
/// landmarks an 8-bar phrase at level 2 has — so the rate that decides it is the spatial one,
/// and the level ladder's is the temporal one (PLAN.md §7.43).
final class SpatialLadderTests: XCTestCase {

    private func form(level: Int = 2, phraseBars: Int = 8,
                      onFormRate: Double, cleanRate: Double = 0,
                      unmarked: Bool = false, markedEvery: Double? = nil,
                      wasProbe: Bool = false) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          cleanRate: cleanRate, hasUnmarkedPhrases: unmarked,
                          markedEveryBars: markedEvery, wasProbe: wasProbe)
    }

    private func formPlan(_ forms: [PlannerInput.Form]) -> FormPlan? {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(forms: forms))
        for block in plan.blocks {
            if case .form(let f) = block.plan { return f }
        }
        return nil
    }

    /// Knowing the bar grows the phrase.
    func testKnowingTheBarGrowsThePhrase() {
        let plan = formPlan([form(phraseBars: 8, onFormRate: 1.0)])
        XCTAssertEqual(plan?.phraseBars, 16)
        XCTAssertEqual(plan?.level, 2, "the span moves at a fixed level")
    }

    /// And the whole ladder is walked, in order, rather than jumping to the top.
    func testTheLadderClimbsOneRungAtATime() {
        XCTAssertEqual(formPlan([form(phraseBars: 4, onFormRate: 1.0)])?.phraseBars, 8)
        XCTAssertEqual(formPlan([form(phraseBars: 8, onFormRate: 1.0)])?.phraseBars, 16)
        XCTAssertEqual(formPlan([form(phraseBars: 16, onFormRate: 1.0)])?.phraseBars, 32)
    }

    /// The top of the ladder holds.
    func testTheLadderDoesNotGrowPastTheLongestSpan() {
        XCTAssertEqual(formPlan([form(phraseBars: 32, onFormRate: 1.0)])?.phraseBars, 32)
    }

    /// Landing cleanly is the *other* axis and must not grow the span. A player who lands
    /// beautifully on a phrase he keeps losing has not earned more music to lose it across.
    func testLandingCleanlyDoesNotGrowThePhrase() {
        let plan = formPlan([form(phraseBars: 8, onFormRate: 0.4, cleanRate: 1.0)])
        XCTAssertEqual(plan?.phraseBars, 8, "the span is about knowing the bar, not landing on it")
    }

    /// Unmarked phrases mean the player lost the thread outright, which is the spatial failure
    /// this ladder measures — it cannot be the thing that earns a longer one.
    func testUnmarkedPhrasesBlockTheSpanFromGrowing() {
        let plan = formPlan([form(phraseBars: 8, onFormRate: 1.0, unmarked: true)])
        XCTAssertEqual(plan?.phraseBars, 8)
    }

    /// **The property that keeps takes comparable**: a single plan may move one axis or the
    /// other, never both. Two changes at once and the next take differs from the last one in two
    /// ways, so neither result says which change did it.
    ///
    /// Step 3 turns *which* axis moves into a decision; this asserts that only one ever does.
    func testOnlyOneAxisMovesInAnyPlan() {
        for phraseBars in SessionPlanner.phraseSpanLadder {
            for level in 0...3 {
                let both = form(level: level, phraseBars: phraseBars,
                                onFormRate: 1.0, cleanRate: 1.0)
                guard let planned = formPlan([both]) else { return XCTFail("no form block") }
                let levelMoved = planned.level != level
                let spanMoved = planned.phraseBars != phraseBars
                XCTAssertFalse(levelMoved && spanMoved,
                               "level \(level) at \(phraseBars) bars moved both axes at once")
            }
        }
    }

    /// The felt-period rule is this ladder's demotion: a player marking a shorter phrase twice
    /// running is moved back to the span he is actually tracking, and a correction beats a
    /// promotion because promoting someone onto a span they are not following measures nothing.
    func testMarkingAShorterPhraseTwiceMovesTheSpanBackDown() {
        let history = [form(phraseBars: 16, onFormRate: 1.0, markedEvery: 8),
                       form(phraseBars: 16, onFormRate: 1.0, markedEvery: 8)]
        XCTAssertEqual(formPlan(history)?.phraseBars, 8,
                       "two takes feeling 8 outrank a promotion to 32")
    }

    /// A probe is a span run for the reading rather than one that was earned.
    ///
    /// Paired with a real take, so the assertion is that the ladder *held* rather than that it
    /// fell back to the no-data default — which would pass at 8 bars for the wrong reason.
    func testAProbeCannotGrowTheSpan() {
        let history = [form(level: 1, phraseBars: 8, onFormRate: 0.4),
                       form(level: 1, phraseBars: 8, onFormRate: 1.0, wasProbe: true)]
        let plan = formPlan(history)
        XCTAssertEqual(plan?.phraseBars, 8, "the probe's perfect rate must not grow the span")
        XCTAssertEqual(plan?.level, 1, "and the held take is the one setting the position")
    }
}
