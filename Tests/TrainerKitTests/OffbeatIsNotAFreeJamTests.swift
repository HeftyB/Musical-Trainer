import XCTest
@testable import GrooveCore
@testable import TimingCore
import TestSupport
@testable import TrainerKit

/// An offbeat take is stored as a jam and is not one.
///
/// It shares `JamSession` because it is the same capture, the same grid and the same storage — and
/// it measures a different skill, against a different expectation, at a spread that runs half again
/// as wide. Two readouts already had this fixed: §7.24 step 8 split it out of the trend, §7.48 gave
/// it its own line on the chart. **The planner's input never was**, and unlike a readout nothing
/// about that is visible: it widens the spread estimate that decides which rungs the ladder may
/// schedule and which the app's picker will even offer.
///
/// The estimate reads the last six takes, so a run of skanks displaces the free jams entirely.
final class OffbeatIsNotAFreeJamTests: StoreBackedTestCase {

    /// A wide skank. Only the spread and the level matter to what is under test here; the phase
    /// is `OffbeatAnalysis`'s business and has its own suite.
    private static let wideSkank = Performance(beats: 128, biasMs: -12, spreadMs: 34)

    /// Three tight free jams then six wide skanks, which is the real shape: offbeat takes on
    /// record run 26–41 ms against 20–27 for free playing, and the estimate reads the last six.
    private func corpus() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        for day in 3..<9 {
            try SessionStore.save(TakeFactory.jam(Self.wideSkank, offbeatLevel: 0, dayOffset: day))
        }
    }

    func testTheStoreSeparatesPlayAlongTakesFromDrillTakes() throws {
        try corpus()
        XCTAssertEqual(SessionStore.loadAll().count, 9)
        XCTAssertEqual(SessionStore.loadAllPlayAlong().count, 3)
        XCTAssertTrue(SessionStore.loadAllPlayAlong().allSatisfy { $0.offbeatLevel == nil })
    }

    /// The defect, at the point it bites: six offbeat takes in a row would otherwise *be* the
    /// window the spread estimate reads.
    func testARunOfOffbeatTakesDoesNotBecomeThePlayersSpread() throws {
        try corpus()
        let spreads = TrainerEngine.recentJamSpreadsMs()
        XCTAssertEqual(spreads.count, 3, "the window filled with drill takes")
        XCTAssertLessThan(Stats.median(spreads), 30,
                          "a skank's spread reached the picker as the player's own")
    }

    /// And the consequence a player would actually notice: rungs vanishing from the picker.
    func testTheRungsOnOfferAreNotDecidedByTheSkank() throws {
        try corpus()
        let spread = Stats.median(TrainerEngine.recentJamSpreadsMs())
        let offered = IntervalRung.scorable(atBpm: 100, spreadMs: spread)
        XCTAssertTrue(offered.contains(.eighths), "eighths at 100 BPM went missing")
        XCTAssertTrue(offered.contains(.tripletEighths), "triplet eighths at 100 BPM went missing")
    }

    /// The planner reads the same estimate to decide which rung the interval ladder may ask for.
    func testThePlannerDoesNotSeeDrillTakesAsFreeJams() throws {
        try corpus()
        let input = TrainerEngine.plannerInput()
        XCTAssertEqual(input.jams.count, 3, "\(input.jams.count) jams — drill takes leaked in")
    }

    /// §7.20 finding 2's lesson: three of four sites fixed is how a rule comes to be
    /// half-applied. Each of these asks "how tightly does this player place a note", and none of
    /// them may answer it with a take that was not about placing notes with the band.
    func testEveryReadoutThatEstimatesThePlayersSpreadExcludesTheDrill() throws {
        try corpus()

        XCTAssertEqual(TrainerEngine.intervalObservations().count, 3, "interval axis")
        XCTAssertEqual(TrainerEngine.warmUpReport(for: .jam).takeCount, 3, "cold vs warm")
        XCTAssertEqual(TrainerEngine.plannerInput().jams.count, 3, "planner")
        XCTAssertEqual(TrainerEngine.recentJamSpreadsMs(9).count, 3, "recent spread")
    }

    /// What must **not** change: the history, the review and the trend show every take, because
    /// they group by task rather than averaging across it (§7.48). Hiding the drill from those
    /// would be the opposite mistake.
    func testTheHistoryAndTheTrendStillShowEveryTake() throws {
        try corpus()
        XCTAssertEqual(TrainerEngine.jamHistory().count, 9, "the history must show the drill")

        let titles = TrainerEngine.trends(for: .jam).map(\.title)
        XCTAssertTrue(titles.contains { $0.contains("offbeat level 0") },
                      "the trend must still fit the drill on its own line: \(titles)")
        XCTAssertTrue(titles.contains { !$0.contains("offbeat") }, "\(titles)")
    }
}
