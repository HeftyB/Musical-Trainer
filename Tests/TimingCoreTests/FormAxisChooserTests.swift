import XCTest
@testable import TimingCore

/// Which of the form drill's two ladders may move, asked directly.
///
/// The choice used to be the order the two branches happened to sit in — a planner decision nobody
/// made, invisible in a diff and changed by moving code, which is `LESSONS.md` shape 5. These
/// assert the decision rather than its consequences, which is the point of it having a name
/// (PLAN.md §7.44).
final class FormAxisChooserTests: XCTestCase {

    private func form(level: Int = 1, phraseBars: Int = 8,
                      onFormRate: Double = 0, cleanRate: Double = 0,
                      unmarked: Bool = false) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          cleanRate: cleanRate, hasUnmarkedPhrases: unmarked,
                          markedEveryBars: nil)
    }

    private let bar = SessionPlanner.ladderPromotionRate

    /// Earning one axis moves that one.
    func testEachAxisIsChosenByItsOwnRate() {
        XCTAssertEqual(SessionPlanner.formAxis(for: form(cleanRate: bar)), .temporal)
        XCTAssertEqual(SessionPlanner.formAxis(for: form(onFormRate: bar)), .spatial)
    }

    /// **The decision this type exists for.** Both earned, and the temporal ladder goes first —
    /// advancing a level costs no data, growing the span halves the marks the other ladder is
    /// judged on.
    func testTheTemporalLadderGoesFirstWhenBothAreEarned() {
        XCTAssertEqual(SessionPlanner.formAxis(for: form(onFormRate: 1.0, cleanRate: 1.0)),
                       .temporal, "the free rung is taken before the one that costs data")
    }

    /// And when the temporal ladder has nowhere to go, the span gets its turn rather than the
    /// sitting being wasted — the preference is an ordering, not a veto.
    func testTheSpanMovesWhenTheLevelIsAtTheTop() {
        let topped = form(level: 3, onFormRate: 1.0, cleanRate: 1.0)
        XCTAssertEqual(SessionPlanner.formAxis(for: topped), .spatial)
    }

    /// Neither earned is a hold, and the drill repeats — which is where this player sits.
    func testNeitherEarnedHolds() {
        XCTAssertEqual(SessionPlanner.formAxis(for: form(onFormRate: 0.43, cleanRate: 0.14)),
                       .hold)
    }

    /// A missed phrase top is the spatial failure the drill measures, and it also means few
    /// marks — so a rate computed over them is a rate over a thin sample. Neither may climb.
    func testUnmarkedPhrasesHoldBothAxes() {
        let messy = form(onFormRate: 1.0, cleanRate: 1.0, unmarked: true)
        XCTAssertEqual(SessionPlanner.formAxis(for: messy), .hold)
    }

    /// Both ladders at the top is a hold rather than a spin.
    func testBothLaddersAtTheTopHold() {
        let done = form(level: 3, phraseBars: 32, onFormRate: 1.0, cleanRate: 1.0)
        XCTAssertEqual(SessionPlanner.formAxis(for: done), .hold)
    }

    /// A span the ladder does not contain climbs to the first rung above it.
    ///
    /// **This reverses what this test asserted**, which was that an off-ladder span cannot be
    /// climbed from at all, on the grounds that inventing a "next" from an unknown rung would be
    /// guessing. It is not guessing — the ladder is ordered, and "the first rung wider than where
    /// you are" is what climbing means. What the old rule actually did was strand the player: a
    /// span reached by hand (`form 100 64 6 2`) left `formAxis` unable to answer `.spatial` ever
    /// again, on a ladder whose whole job is to widen. See PLAN.md §7.50.
    func testASpanOffTheLadderClimbsToTheNextRungAboveIt() {
        XCTAssertEqual(SessionPlanner.nextSpan(after: 2), 4)
        XCTAssertEqual(SessionPlanner.nextSpan(after: 6), 8)
        XCTAssertEqual(SessionPlanner.nextSpan(after: 20), 32)
        XCTAssertNil(SessionPlanner.nextSpan(after: 33), "nothing is wider than the top rung")

        let odd = form(phraseBars: 6, onFormRate: 1.0)
        XCTAssertEqual(SessionPlanner.formAxis(for: odd), .spatial,
                       "a player off the ladder must still be able to climb it")
    }

    /// The ladder is walked one rung at a time and stops at the top.
    func testNextSpanWalksTheLadder() {
        XCTAssertEqual(SessionPlanner.nextSpan(after: 4), 8)
        XCTAssertEqual(SessionPlanner.nextSpan(after: 8), 16)
        XCTAssertEqual(SessionPlanner.nextSpan(after: 16), 32)
        XCTAssertNil(SessionPlanner.nextSpan(after: 32))
    }

    /// Exactly at the bar counts as earned. A ladder that needed to be beaten rather than met
    /// would make the stated threshold a lie by one hundredth.
    func testTheBarIsMetRatherThanBeaten() {
        XCTAssertEqual(SessionPlanner.formAxis(for: form(cleanRate: bar)), .temporal)
        XCTAssertEqual(SessionPlanner.formAxis(for: form(cleanRate: bar - 0.001)), .hold)
    }
}
