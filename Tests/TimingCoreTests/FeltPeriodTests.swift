import XCTest
@testable import TimingCore

/// What the player actually marked, and when that is too loose to be called a period at all.
///
/// The regularity gate was ±35%, which spans a factor of 2.08 — wider than a doubling, while the
/// phrase lengths it describes sit a factor of two apart. The first irregular take through it
/// reported "a steady 13.2-bar phrase" from gaps of 4.1, 12.4, 16.0 and 14.0 (JOURNAL.md §7.45).
final class FeltPeriodTests: XCTestCase {

    private let bpm = 100.0
    private var grid: Grid { Grid(startTime: 0, bpm: bpm, subdivisions: 4) }
    private var barSeconds: Double { 60 / bpm * 4 }

    private func report(marksAtBars bars: [Double], phraseBars: Int = 8,
                        totalBars: Int = 64) -> FormReport {
        FormAnalysis.analyze(markTimes: bars.map { $0 * barSeconds }, grid: grid,
                             beatsPerBar: 4, barsPerPhrase: phraseBars, totalBars: totalBars)
    }

    /// **The take that motivated this.** 12 August, a 16-bar setting: six consecutive gaps of
    /// 7.88 to 8.12 bars — the steadiest phrase in the corpus — which the drill scored 3/7 on form
    /// because every other figure is measured against the setting rather than what was held.
    func testASteadyEightBarPhraseIsReportedEvenAgainstASixteenBarSetting() {
        let marks = [9.99, 17.91, 25.89, 33.77, 41.77, 49.89, 57.90]
        let felt = report(marksAtBars: marks, phraseBars: 16).markedEveryBars

        XCTAssertNotNil(felt, "six gaps within a quarter of a bar of each other is a period")
        XCTAssertEqual(try XCTUnwrap(felt), 8, accuracy: 0.2)
    }

    /// **The defect.** The same day's other take: no period, and the old gate named one.
    func testIrregularMarkingReportsNoPeriodAtAll() {
        let marks = [9.87, 13.98, 26.35, 42.35, 56.34]
        XCTAssertNil(report(marksAtBars: marks).markedEveryBars,
                     "gaps of 4.1, 12.4, 16.0 and 14.0 bars are not a steady phrase")
    }

    /// The reason the old tolerance could not work, stated as a test rather than as a comment: a
    /// band wide enough to hold two rungs of a doubling ladder cannot say which rung it means.
    func testTheToleranceIsNarrowerThanTheLadderItDescribes() {
        // Gaps straddling 8 and 16 — both are legal phrase lengths, so no single period is
        // supportable and the honest answer is none.
        let straddling = [0.0, 8.0, 24.0, 32.0, 48.0]
        XCTAssertNil(report(marksAtBars: straddling, phraseBars: 8, totalBars: 96).markedEveryBars,
                     "gaps of 8 and 16 bars do not average into a 12-bar phrase")
    }

    /// A genuinely steady period that happens to match the setting is still reported, so the
    /// readout can say "what you held is what was asked" rather than going quiet.
    func testAPeriodMatchingTheSettingIsStillReported() {
        let felt = report(marksAtBars: [0.0, 8.0, 16.0, 24.0, 32.0]).markedEveryBars
        XCTAssertEqual(try XCTUnwrap(felt), 8, accuracy: 0.05)
    }

    /// Too few marks to fit a period against. Three gaps is the minimum the analysis accepts.
    func testTooFewMarksReportNoPeriod() {
        XCTAssertNil(report(marksAtBars: [0.0, 8.0]).markedEveryBars)
    }

    /// A little human variation is still a period — the gate rejects irregularity, not humanity.
    func testOrdinaryHumanVariationStillCountsAsAPeriod() {
        let human = [0.0, 8.3, 15.8, 24.2, 31.9, 40.1]
        let felt = report(marksAtBars: human).markedEveryBars
        XCTAssertEqual(try XCTUnwrap(felt), 8, accuracy: 0.4)
    }
}
