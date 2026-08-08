import XCTest
import TestSupport
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// The offbeat drill's identity, past the moment the take was recorded.
///
/// M15 step 6 built the drill and wired it into the live console path only. The first take ever
/// recorded — 6 August, level 0, 32 bars — slipped onto the beat for 86 of its 112 notes, and
/// none of the three surfaces that read it back could say so: the review reported "steady, just
/// early", the trend pooled it with the free jams, and the planner could not have run it at all.
/// Every one of those is the same shape as §7.24 step 7 — the path under test was not the path
/// that ships — arriving one milestone step later in a different place.
final class OffbeatSurvivesTheTakeTests: StoreBackedTestCase {

    private static let eighths = Grid(startTime: 1_000, bpm: 100, subdivisions: 2)

    private func slippedTake() -> JamSession {
        TakeFactory.jam(.slippedSkank, grid: Self.eighths, offbeatLevel: 0)
    }

    private func heldTake() -> JamSession {
        TakeFactory.jam(.skank, grid: Self.eighths, offbeatLevel: 0)
    }

    // MARK: - The review

    func testAStoredOffbeatTakeStillSaysItSlipped() {
        guard let report = slippedTake().offbeatReport() else {
            return XCTFail("an offbeat take must produce an offbeat report on review")
        }
        XCTAssertTrue(report.slipped,
                      "a take with most of its notes on the beat has lost the feel, and the "
                    + "review is where that has to survive — the live readout is gone")
        XCTAssertLessThan(report.offbeatShare, OffbeatAnalysis.slipThreshold)
    }

    func testAHeldOffbeatTakeReviewsAsHeld() {
        guard let report = heldTake().offbeatReport() else {
            return XCTFail("an offbeat take must produce an offbeat report on review")
        }
        XCTAssertFalse(report.slipped)
        XCTAssertGreaterThan(report.offbeatShare, 0.9)
    }

    func testAnOrdinaryJamHasNoOffbeatReport() {
        XCTAssertNil(TakeFactory.jam().offbeatReport(),
                     "nil is what tells the surface to print the swing block instead")
    }

    func testTheReviewBuildsAnOffbeatContextFromAStoredTake() {
        let context = Commands.offbeatContext(for: slippedTake())
        XCTAssertEqual(context?.level, .stated)
        XCTAssertEqual(context?.report.slipped, true)
        XCTAssertNil(Commands.offbeatContext(for: TakeFactory.jam()))
    }

    // MARK: - The swing block, which must not appear

    /// The reason the two blocks are mutually exclusive, stated as a measurement rather than a
    /// preference. `SwingAnalysis` splits notes into "on the division" and "off" it; a skank puts
    /// everything off it, so a *held* take clears both of the analysis's guards and reports a
    /// ratio for a player who is not dividing anything.
    ///
    /// Note the direction: the better the feel is held, the more confident the wrong number.
    /// The one real take escaped it only by slipping so badly that the share guard withheld it.
    func testAHeldSkankWouldOtherwiseBeReportedAsSwinging() {
        let take = heldTake()
        let swing = SwingAnalysis.analyze(matched: take.report().matched,
                                          grid: take.reconstruct().grid)
        XCTAssertTrue(swing.ratioIsMeaningful)
        XCTAssertGreaterThanOrEqual(swing.offbeatCount, SwingAnalysis.minimumOffbeats)
        XCTAssertNotNil(swing.producedRatio,
                        "if this ever returns nil the suppression below is untested rather than "
                      + "unnecessary — the whole point is that the wrong number is computable")

        XCTAssertNotNil(take.offbeatReport(),
                        "so the take must carry what the surface shows instead")
    }

    /// The suppression itself, taken off the branch that prints it rather than from a value
    /// computed beside it — a readout derived alongside the branch would agree with a branch
    /// that had been changed underneath it.
    func testAnOffbeatTakeGetsTheOffbeatBlockAndNotTheSwingBlock() {
        let take = heldTake()
        let readout = Commands.reportTiming(
            take.report(), notesCaptured: take.tapTimes.count, events: take.tapTimes.count,
            uncalibrated: false, grid: take.reconstruct().grid,
            offbeat: Commands.offbeatContext(for: take))
        XCTAssertEqual(readout, .offbeat(.stated))
    }

    func testAnOrdinaryJamStillGetsTheSwingBlock() {
        let take = TakeFactory.jam()
        let readout = Commands.reportTiming(
            take.report(), notesCaptured: take.tapTimes.count, events: take.tapTimes.count,
            uncalibrated: false, grid: take.reconstruct().grid,
            offbeat: Commands.offbeatContext(for: take))
        XCTAssertEqual(readout, .swing,
                       "the swing readout answers a real question on ordinary takes — a player "
                     + "asked for straight eighths who is quietly swinging them")
    }

    // MARK: - The trend

    func testAnOffbeatTakeIsNotPooledWithTheFreeJams() throws {
        assertStoreIsRedirected()
        for _ in 0..<3 { try SessionStore.save(TakeFactory.jam()) }
        try SessionStore.save(slippedTake())

        let series = TrainerEngine.trends(for: .jam)
        let free = try XCTUnwrap(series.first { !$0.title.contains("offbeat") },
                                 "the free jams keep their own group")
        XCTAssertEqual(free.takeCount, 3,
                       "the offbeat take is a different task: one note per beat held where the "
                     + "band plays nothing, over a different backing. Fitting it into the group "
                     + "the project reads its progress from measures the drill, not the player")
        XCTAssertNotNil(series.first { $0.title.contains("offbeat") },
                        "and it is still reported, in a group of its own")
    }

    func testTheOffbeatGroupNamesItsLevel() throws {
        assertStoreIsRedirected()
        try SessionStore.save(slippedTake())
        let title = try XCTUnwrap(TrainerEngine.trends(for: .jam).first?.title)
        XCTAssertTrue(title.contains("level 0"), "got \(title)")
        XCTAssertTrue(title.contains(OffbeatLevel.stated.label), "got \(title)")
    }

    // MARK: - The planner

    /// `JamPlan.offbeatLevel` and `DrillInstructions.forBlock` both handled the level; the runner
    /// dropped it. A planned offbeat block would have shown the skank's instructions and played
    /// an ordinary jam, which is a take recorded under a task it never performed.
    func testAPlannedOffbeatBlockRunsAsTheOffbeatDrill() {
        let plan = JamPlan(bpm: 100, bars: 32, tag: "offbeat", offbeatLevel: 2)
        let config = SessionRunner.jamConfig(for: plan, role: .training)
        XCTAssertEqual(config.offbeatLevel, .backbeatOnly)
        XCTAssertEqual(config.backing.name, "offbeat-2",
                       "the level has to reach the backing, or the band states a downbeat the "
                     + "drill exists to remove")
        XCTAssertEqual(config.gridSubdivisions, 2,
                       "and the grid, or a stray sixteenth flatters the share that decides "
                     + "whether the feel was held")
    }

    func testAPlannedOrdinaryJamIsUnchanged() {
        let plan = JamPlan(bpm: 100, bars: 64, tag: "benchmark", rung: .eighths, feel: .swung)
        let config = SessionRunner.jamConfig(for: plan, role: .training)
        XCTAssertNil(config.offbeatLevel)
        XCTAssertEqual(config.rung, .eighths)
        XCTAssertEqual(config.feel, .swung)
    }
}
