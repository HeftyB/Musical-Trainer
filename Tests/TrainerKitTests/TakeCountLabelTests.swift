import XCTest
@testable import TimingCore
@testable import TrainerKit

/// A readout's own words are part of the measurement's credibility.
///
/// Both surfaces interpolated a count beside a bare "takes", so every group holding one take read
/// **"1 takes"** — in the console, on screen, and in the screenshots this project keeps as the
/// record of what a surface looked like. `TrendSeries.takeCountLabel` is written once and read by
/// both, which is the same move as `DrillInstructions.for*`: a surface cannot phrase it differently
/// if it is not phrasing it at all.
final class TakeCountLabelTests: StoreBackedTestCase {

    func testOneTakeIsNotOneTakes() {
        let series = TrendSeries(title: "t", takeCount: 1, warnings: [], rows: [])
        XCTAssertEqual(series.takeCountLabel, "1 take")
    }

    func testEveryOtherCountIsPlural() {
        for n in [0, 2, 3, 27] {
            XCTAssertEqual(TrendSeries(title: "t", takeCount: n, warnings: [], rows: []).takeCountLabel,
                           "\(n) takes")
        }
    }

    /// The label has to reach a real series, not just exist. A group of one is the commonest
    /// shape in this history — sixteen of the eighteen jam groups — so it is what a reader sees
    /// most often.
    func testARealGroupOfOneSaysTake() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(offbeatLevel: 0))
        let series = try XCTUnwrap(TrainerEngine.trends(for: .jam).first)
        XCTAssertEqual(series.takeCount, 1)
        XCTAssertEqual(series.takeCountLabel, "1 take")
    }
}
