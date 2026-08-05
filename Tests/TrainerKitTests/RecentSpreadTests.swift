import XCTest
@testable import TimingCore
import TestSupport
@testable import TrainerKit

/// The spread every tempo ceiling is derived from, in one place.
///
/// `render` marks a rung above its ceiling, the `jam` command warns before a take, and the app's
/// rung picker offers only what is under it. All three were computing "the median of the last
/// six takes" separately, which is three chances to disagree about what is scorable — and the
/// ceiling is not a display detail: it decides which rungs the player is allowed onto.
final class RecentSpreadTests: StoreBackedTestCase {

    func testItReturnsTheMostRecentTakesNewestLast() throws {
        let spreads: [Double] = [8, 12, 16, 20, 24, 28, 32, 36]
        for sd in spreads {
            _ = try SessionStore.save(TakeFactory.jam(Performance(spreadMs: sd)))
        }

        let recent = TrainerEngine.recentJamSpreadsMs()
        XCTAssertEqual(recent.count, 6, "the last six, not all eight")

        // Recomputed from raw taps, so the figures are near the planted ones rather than equal.
        let all = try XCTUnwrap(TrainerEngine.recentJamSpreadsMs(spreads.count).last)
        XCTAssertEqual(all, try XCTUnwrap(recent.last), accuracy: 0.001,
                       "newest last in both")
    }

    func testAnEmptyHistoryReturnsNothingRatherThanAZero() {
        XCTAssertTrue(TrainerEngine.recentJamSpreadsMs().isEmpty)
    }

    /// A take too degenerate to produce a spread contributes nothing rather than a NaN — one
    /// non-finite entry would poison a median and with it every ceiling on screen.
    func testATakeWithNoComputableSpreadIsSkipped() throws {
        _ = try SessionStore.save(TakeFactory.jam(.silent))
        _ = try SessionStore.save(TakeFactory.jam(Performance(spreadMs: 20)))

        let recent = TrainerEngine.recentJamSpreadsMs()
        XCTAssertTrue(recent.allSatisfy(\.isFinite), "\(recent)")
        XCTAssertLessThanOrEqual(recent.count, 2)
    }

    /// The number this feeds is a rung's tempo ceiling, and a tighter player earns a higher one.
    /// Stated as a test because the direction is the whole point: the ceiling moves as they
    /// improve rather than being a constant somebody picked (§7.23 step 1).
    func testATighterHistoryRaisesTheCeilingItFeeds() throws {
        for _ in 0..<6 { _ = try SessionStore.save(TakeFactory.jam(Performance(spreadMs: 40))) }
        let loose = Stats.median(TrainerEngine.recentJamSpreadsMs())

        for _ in 0..<6 { _ = try SessionStore.save(TakeFactory.jam(Performance(spreadMs: 8))) }
        let tight = Stats.median(TrainerEngine.recentJamSpreadsMs())

        XCTAssertLessThan(tight, loose)
        XCTAssertGreaterThan(IntervalRung.sixteenths.maximumBpm(forSpreadMs: tight),
                             IntervalRung.sixteenths.maximumBpm(forSpreadMs: loose))
    }
}
