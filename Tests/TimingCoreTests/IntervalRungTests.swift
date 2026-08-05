import XCTest
@testable import TimingCore

/// M14 step 1: the rung, and the ceiling the matching window puts on it.
final class IntervalRungTests: XCTestCase {

    /// This player's measured spread, which is what the ceilings are a fact about.
    private let spread = 20.0

    // MARK: - Subdivision and tempo are one axis

    func testEighthsAtOneTempoAreQuartersAtDouble() {
        XCTAssertEqual(IntervalRung.eighths.intervalSeconds(atBpm: 100),
                       IntervalRung.quarters.intervalSeconds(atBpm: 200), accuracy: 1e-12)
        XCTAssertEqual(IntervalRung.sixteenths.intervalSeconds(atBpm: 60),
                       IntervalRung.eighths.intervalSeconds(atBpm: 120), accuracy: 1e-12)
    }

    func testTheIntervalIsTheGridsInterval() {
        for rung in IntervalRung.allCases {
            let grid = Grid(startTime: 0, bpm: 137, subdivisions: rung.subdivisions)
            XCTAssertEqual(rung.intervalSeconds(atBpm: 137), grid.interval, accuracy: 1e-12,
                           "\(rung.label) must describe the grid it will be scored on")
        }
    }

    func testTheLadderIsOrderedByDifficulty() {
        let intervals = IntervalRung.ladder.map { $0.intervalSeconds(atBpm: 100) }
        XCTAssertEqual(intervals, intervals.sorted(by: >), "easiest is the longest interval")
        XCTAssertNil(IntervalRung.quarters.easier)
        XCTAssertNil(IntervalRung.sixteenths.harder)
        XCTAssertEqual(IntervalRung.eighths.harder, .tripletEighths)
        XCTAssertEqual(IntervalRung.eighths.easier, .quarters)
    }

    // MARK: - The window

    /// The window has to be the matcher's, not a second copy of the number.
    func testTheWindowAgreesWithTheMatcher() {
        for rung in IntervalRung.allCases {
            let grid = Grid(startTime: 0, bpm: 100, subdivisions: rung.subdivisions)
            XCTAssertEqual(rung.windowSeconds(atBpm: 100),
                           grid.interval * Matching.defaultWindowFraction, accuracy: 1e-12)
        }
    }

    /// The arithmetic that motivates the ceiling, stated as the numbers it produces.
    func testTheWindowNarrowsAsTheRungOrTheTempoRises() {
        XCTAssertEqual(IntervalRung.sixteenths.windowInSpreads(atBpm: 100, spreadMs: spread),
                       3.0, accuracy: 0.01, "sixteenths at the reference tempo sit at the floor")
        XCTAssertEqual(IntervalRung.sixteenths.windowInSpreads(atBpm: 140, spreadMs: spread),
                       2.14, accuracy: 0.02, "and drop below it well before the engine's limit")
        XCTAssertGreaterThan(IntervalRung.quarters.windowInSpreads(atBpm: 100, spreadMs: spread),
                             10, "quarters are nowhere near the floor")
    }

    // MARK: - The ceiling

    /// The ceiling is exactly where the window is worth `minimumWindowInSpreads`.
    func testAtTheCeilingTheWindowIsExactlyTheMinimum() {
        for rung in IntervalRung.allCases {
            let ceiling = rung.maximumBpm(forSpreadMs: spread)
            XCTAssertEqual(rung.windowInSpreads(atBpm: ceiling, spreadMs: spread),
                           IntervalRung.minimumWindowInSpreads, accuracy: 1e-9,
                           "\(rung.label) ceiling is not where the rule says it is")
        }
    }

    func testTheCeilingsAtThisPlayersSpread() {
        XCTAssertEqual(IntervalRung.quarters.maximumBpm(forSpreadMs: spread), 400, accuracy: 0.5)
        XCTAssertEqual(IntervalRung.eighths.maximumBpm(forSpreadMs: spread), 200, accuracy: 0.5)
        XCTAssertEqual(IntervalRung.tripletEighths.maximumBpm(forSpreadMs: spread),
                       133.3, accuracy: 0.5)
        XCTAssertEqual(IntervalRung.sixteenths.maximumBpm(forSpreadMs: spread), 100, accuracy: 0.5)
    }

    /// A ceiling that is a fact about the player, not a number somebody picked: it rises as they
    /// tighten and falls as they loosen.
    func testTheCeilingMovesWithThePlayer() {
        let tighter = IntervalRung.sixteenths.maximumBpm(forSpreadMs: 10)
        let looser = IntervalRung.sixteenths.maximumBpm(forSpreadMs: 40)
        XCTAssertEqual(tighter, 200, accuracy: 0.5)
        XCTAssertEqual(looser, 50, accuracy: 0.5)
        XCTAssertGreaterThan(tighter, looser)
    }

    func testScorableRungsShrinkAsTheTempoRises() {
        XCTAssertEqual(IntervalRung.scorable(atBpm: 100, spreadMs: spread),
                       [.quarters, .eighths, .tripletEighths, .sixteenths])
        // At 120 the sixteenths window is under three spreads, so the rung comes off the list.
        XCTAssertEqual(IntervalRung.scorable(atBpm: 120, spreadMs: spread),
                       [.quarters, .eighths, .tripletEighths])
        XCTAssertEqual(IntervalRung.scorable(atBpm: 180, spreadMs: spread), [.quarters, .eighths])
    }

    /// The reference tempo is where the benchmark lives, so what is available there decides what
    /// the ladder can offer without moving a locked parameter.
    func testSixteenthsAreAtTheirCeilingAtTheReferenceTempo() {
        XCTAssertTrue(IntervalRung.sixteenths.isScorable(atBpm: 100, spreadMs: spread))
        XCTAssertFalse(IntervalRung.sixteenths.isScorable(atBpm: 101, spreadMs: spread),
                       "one BPM above the reference and the top rung is no longer honest")
    }

    func testNonsenseInputsDoNotProduceNonsenseCeilings() {
        XCTAssertTrue(IntervalRung.quarters.intervalSeconds(atBpm: 0).isNaN)
        XCTAssertEqual(IntervalRung.quarters.maximumBpm(forSpreadMs: 0), .infinity)
        XCTAssertEqual(IntervalRung.quarters.windowInSpreads(atBpm: 100, spreadMs: 0), .infinity)
    }
}
