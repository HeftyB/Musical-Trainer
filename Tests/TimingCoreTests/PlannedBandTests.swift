import XCTest
import TestSupport
@testable import TimingCore

/// The closing jam gets a band, and nothing else does.
///
/// §7.29's slot table: the cold probe, the benchmark and the experiment arms are frozen for ever
/// (R3.5), and the deep music goes where nothing longitudinal is read. In a planned session the
/// closing jam is the only *free* jam there is — the ladder training block carries a rung, and a
/// rung and a style are two backings that cannot both play. See PLAN.md §7.33.
final class PlannedBandTests: XCTestCase {

    private let approved = ["driving", "half-time", "pocket", "syncopated"]

    private func input(jams: [PlannerInput.Jam] = [], styles: [String]? = nil) -> PlannerInput {
        PlannerInput(jams: jams.isEmpty ? [Self.jam()] : jams,
                     auditionedStyles: styles ?? approved)
    }

    private static func jam(style: String? = nil, sd: Double = 23) -> PlannerInput.Jam {
        PlannerInput.Jam(bpm: 100, sdMs: sd, absBiasMs: 8, lag1: 0.3, style: style)
    }

    private func blocks(_ plan: SessionPlan, _ role: BlockRole) -> [JamPlan] {
        plan.blocks.filter { $0.role == role }.compactMap {
            if case .jam(let p) = $0.plan { return p }
            return nil
        }
    }

    // MARK: - Which slots

    func testTheClosingJamCarriesABand() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: input())
        let closing = blocks(plan, .closing)
        XCTAssertFalse(closing.isEmpty)
        for jam in closing {
            XCTAssertNotNil(jam.generatedBacking, "the musical payoff plays the band")
            XCTAssertTrue(approved.contains(jam.generatedBacking?.style ?? ""))
        }
    }

    /// **R3.5, restated where it can fail.** `SessionRunner` drops a backing from a locked slot
    /// whatever the plan says, and this is the other end of that: the plan must not ask.
    func testNoLockedSlotEverAsksForOne() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: input())
            for role in [BlockRole.cold, .benchmark, .experiment] {
                for jam in blocks(plan, role) {
                    XCTAssertNil(jam.generatedBacking,
                                 "\(role.rawValue) at \(minutes) min asked for a style")
                }
            }
        }
    }

    /// The ladder block is a training jam and it must stay on its ladder groove: a style would be
    /// a second backing, and `JamConfig.validate` refuses the pair outright.
    func testATrainingJamWithARungNeverGetsAStyle() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: input())
        for jam in blocks(plan, .training) where jam.rung != nil {
            XCTAssertNil(jam.generatedBacking,
                         "a rung and a style are two backings and only one can play")
        }
    }

    // MARK: - One evening, one identity

    /// §7.29's settled decision: one seed within a sitting, so an evening has a single musical
    /// identity, and a new one next time.
    func testEveryClosingBlockInOneSittingSharesTheBand() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: input())
        let bands = Set(blocks(plan, .closing).compactMap { $0.generatedBacking })
        XCTAssertEqual(bands.count, 1, "\(bands)")
    }

    /// Two plans from one history are the same plan — which is what makes `session plan` an honest
    /// preview of `session`, and what R1.2.1 requires of anything with a seed in it.
    func testThePlanIsDeterministic() {
        let history = input(jams: [Self.jam(), Self.jam(style: "driving")])
        let a = SessionPlanner.plan(targetMinutes: 45, from: history)
        let b = SessionPlanner.plan(targetMinutes: 45, from: history)
        XCTAssertEqual(blocks(a, .closing).first?.generatedBacking,
                       blocks(b, .closing).first?.generatedBacking)
    }

    /// And a different evening is different music: the seed moves with the history.
    func testTheNextSittingGetsANewSeed() {
        let first = SessionPlanner.plan(targetMinutes: 45,
                                        from: input(jams: [Self.jam()]))
        let later = SessionPlanner.plan(targetMinutes: 45,
                                        from: input(jams: [Self.jam(), Self.jam(style: "driving")]))
        XCTAssertNotEqual(blocks(first, .closing).first?.generatedBacking?.seed,
                          blocks(later, .closing).first?.generatedBacking?.seed)
    }

    // MARK: - The rotation

    /// Min-count, like the ladder's tempo: the style played least is the one that comes up, so
    /// four sittings cover four styles rather than repeating a favourite.
    func testTheStylePlayedLeastIsTheOneChosen() {
        var history = [Self.jam()]
        var seen: Set<String> = []
        for _ in 0..<approved.count {
            let plan = SessionPlanner.plan(targetMinutes: 45,
                                           from: input(jams: history))
            let style = blocks(plan, .closing).first?.generatedBacking?.style
            seen.insert(style ?? "")
            history.append(Self.jam(style: style))
        }
        XCTAssertEqual(seen, Set(approved),
                       "four sittings should visit four bands, not one four times: \(seen)")
    }

    /// **An empty library is the correct answer, not an error.** It was the state of the world
    /// until 8 August, and it is the state again the moment a style is retired — the closing jam
    /// falls back to the fixed backing every take on record already used.
    func testNothingApprovedMeansTheFixedBacking() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: input(styles: []))
        XCTAssertFalse(blocks(plan, .closing).isEmpty, "the closing jam still happens")
        for jam in blocks(plan, .closing) {
            XCTAssertNil(jam.generatedBacking)
        }
        XCTAssertNil(SessionPlanner.nextStyle(from: input(styles: [])))
    }

    /// The planner can only ever choose from what it was given, which is where the approval gate
    /// actually bites: `TrainerKit` passes `StyleLibrary.auditioned`, never `all`.
    func testOnlyTheStylesHandedInCanBeScheduled() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: input(styles: ["half-time"]))
        for jam in blocks(plan, .closing) {
            XCTAssertEqual(jam.generatedBacking?.style, "half-time")
        }
    }
}
