import XCTest
@testable import TimingCore

/// The form drill's levels are a ladder about *landing*, and are promoted on landing cleanly.
///
/// What the levels remove are the cues that say when to land: level 0's crash confirms the
/// arrival, level 1 takes it away, level 2 takes the fill that warned you. Promoting on the
/// spatial rate handed this player thinner landmarks on the axis he was already failing —
/// 25 of 25 on form and 8 of 25 clean (PLAN.md §7.41).
final class TemporalLadderTests: XCTestCase {

    private func form(level: Int, onFormRate: Double, cleanRate: Double,
                      phraseBars: Int = 8, unmarked: Bool = false,
                      wasProbe: Bool = false) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          cleanRate: cleanRate, hasUnmarkedPhrases: unmarked,
                          markedEveryBars: nil, wasProbe: wasProbe)
    }

    private func plan(_ forms: [PlannerInput.Form]) -> SessionPlan {
        SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(forms: forms))
    }

    private func formPlan(_ forms: [PlannerInput.Form]) -> FormPlan? {
        for block in plan(forms).blocks {
            if case .form(let f) = block.plan { return f }
        }
        return nil
    }

    private func formReason(_ forms: [PlannerInput.Form]) -> String {
        for block in plan(forms).blocks {
            if case .form = block.plan { return block.reason }
        }
        return ""
    }

    /// **The defect, as a test.** Perfect spatial awareness and poor landing must not thin the
    /// landmarks: the player would lose the cue for the one thing he cannot do.
    func testKnowingTheBarPerfectlyDoesNotEarnTheNextLevel() {
        let plan = formPlan([form(level: 2, onFormRate: 1.0, cleanRate: 0.32)])
        XCTAssertEqual(plan?.level, 2, "a 100% on-form take with 32% clean must not promote")
    }

    /// And the converse: landing cleanly is what earns it, even from a take whose spatial rate
    /// would not have passed the old gate.
    func testLandingCleanlyEarnsTheNextLevelEvenWhenTheFormWasShaky() {
        let plan = formPlan([form(level: 1, onFormRate: 0.6, cleanRate: 0.95)])
        XCTAssertEqual(plan?.level, 2, "clean landings are what the levels are about")
    }

    /// The ladder still stops at the top.
    func testTheLadderDoesNotClimbPastLevelThree() {
        let plan = formPlan([form(level: 3, onFormRate: 1.0, cleanRate: 1.0)])
        XCTAssertEqual(plan?.level, 3)
    }

    /// Unmarked phrases mean few marks, so a clean rate over them is a rate over a thin sample —
    /// and a missed phrase top is a spatial failure the level ladder should not reward past.
    func testUnmarkedPhrasesStillBlockPromotion() {
        let plan = formPlan([form(level: 0, onFormRate: 1.0, cleanRate: 1.0, unmarked: true)])
        XCTAssertEqual(plan?.level, 0)
    }

    /// A probe is a level run for the reading, not one that was earned, and nothing that decides
    /// where the ladder stands may read it.
    func testAProbeCannotEarnTheNextLevel() {
        let plan = formPlan([form(level: 1, onFormRate: 1.0, cleanRate: 1.0),
                             form(level: 3, onFormRate: 1.0, cleanRate: 1.0, wasProbe: true)])
        XCTAssertEqual(plan?.level, 2, "the probe is ignored; the earned take promotes 1 → 2")
    }

    /// The reason has to say which skill is being asked for, or the player reads a held level as
    /// a comment on the wrong thing — which is exactly what the old text did.
    func testTheReasonNamesLandingRatherThanForm() {
        let reason = formReason([form(level: 2, onFormRate: 1.0, cleanRate: 0.32)])
        XCTAssertTrue(reason.lowercased().contains("bar line") || reason.lowercased().contains("land"),
                      "the held level must be explained by the axis it is about: \(reason)")
    }

    /// Both ladders clear the same bar. Two numbers for "you have got this" would be two
    /// standards, and nobody could say why they differed.
    func testOneStandardIsSharedByBothAxes() {
        let justUnder = SessionPlanner.ladderPromotionRate - 0.01
        XCTAssertEqual(formPlan([form(level: 1, onFormRate: 1.0, cleanRate: justUnder)])?.level, 1)
        XCTAssertEqual(formPlan([form(level: 1, onFormRate: 0.0,
                                      cleanRate: SessionPlanner.ladderPromotionRate)])?.level, 2)
    }
}
