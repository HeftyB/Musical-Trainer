import XCTest
@testable import TimingCore

/// Knowing which bar the phrase turns on, and landing on it, are two skills — and the report
/// has to be able to say so about the *same* take.
///
/// Before M16 step 0 the placement figures were computed over on-form marks only, so the
/// temporal score was conditioned on the spatial one succeeding. That makes it a statistic about
/// a population that changes whenever the other axis improves, which is fatal for a ladder about
/// to be promoted on it (JOURNAL.md §7.40).
final class FormAxesArePeersTests: XCTestCase {

    private let bpm = 100.0
    private let beatsPerBar = 4
    private let barsPerPhrase = 8

    private var grid: Grid { Grid(startTime: 0, bpm: bpm, subdivisions: 4) }
    private var barSeconds: Double { 60 / bpm * Double(beatsPerBar) }

    /// A mark `bars` after the start, nudged by `offsetMs`.
    private func mark(bars: Double, offsetMs: Double = 0) -> Double {
        bars * barSeconds + offsetMs / 1000
    }

    /// The take that used to be unreadable: every mark crisp on a bar line, and half of them on
    /// the wrong bar. Placement is excellent, the map is lost, and one number cannot say that.
    ///
    /// This is the corpus's own 5 August take in miniature — 5/14 on form against 10/14 clean.
    func testAMarkOnTheWrongBarStillCountsAsCleanlyPlaced() {
        let times = [
            mark(bars: 0),          // phrase 0 top, dead on
            mark(bars: 9),          // a bar late, dead on that bar line
            mark(bars: 16),         // phrase 2 top, dead on
            mark(bars: 25),         // a bar late again, dead on
        ]
        let report = FormAnalysis.analyze(markTimes: times, grid: grid,
                                          beatsPerBar: beatsPerBar,
                                          barsPerPhrase: barsPerPhrase, totalBars: 32)

        XCTAssertEqual(report.onFormCount, 2, "half the marks were a bar out")
        XCTAssertEqual(report.cleanCount, 4, "but every one of them landed on a bar line")
        XCTAssertEqual(report.nailedCount, 2, "both axes at once is still the intersection")
    }

    /// The mirror image, which is where this player actually is: the bar right every time and
    /// the downbeat missed. 10 August was 25/25 on form and 8/25 clean.
    func testMarksOnTheRightBarCanStillMissTheDownbeat() {
        let sloppy = 400.0      // well outside the 150 ms tolerance at 100 BPM
        let times = [
            mark(bars: 0, offsetMs: sloppy),
            mark(bars: 8, offsetMs: sloppy),
            mark(bars: 16, offsetMs: sloppy),
            mark(bars: 24, offsetMs: 0),
        ]
        let report = FormAnalysis.analyze(markTimes: times, grid: grid,
                                          beatsPerBar: beatsPerBar,
                                          barsPerPhrase: barsPerPhrase, totalBars: 32)

        XCTAssertEqual(report.onFormCount, 4, "every mark was on the right bar")
        XCTAssertEqual(report.cleanCount, 1, "only one of them landed on the line")
        XCTAssertEqual(report.nailedCount, 1)
    }

    /// The selection effect itself, stated as a test: the unconditioned placement spread must
    /// include marks that were off form. Computing it over on-form marks only makes it move when
    /// the *spatial* axis changes, which is the defect step 0 exists to remove.
    func testPlacementSpreadIncludesMarksThatWereOffForm() {
        // Two marks on form and crisp, two a bar out and very late. Pooling all four has to see
        // the late pair; pooling only the on-form ones cannot.
        let times = [
            mark(bars: 0),
            mark(bars: 8),
            mark(bars: 17, offsetMs: 500),
            mark(bars: 25, offsetMs: 500),
        ]
        let report = FormAnalysis.analyze(markTimes: times, grid: grid,
                                          beatsPerBar: beatsPerBar,
                                          barsPerPhrase: barsPerPhrase, totalBars: 32)

        XCTAssertEqual(report.onFormCount, 2)
        XCTAssertFalse(report.phaseErrorSDms.isNaN)
        XCTAssertGreaterThan(report.phaseErrorSDms, 100,
                             "the unconditioned spread must see the two late marks")
        XCTAssertLessThan(report.onFormPhaseErrorSDms, 50,
                          "and the on-form-only figure must still describe the clean pair")
    }

    /// `nailedCount` is the intersection and must never exceed either axis. It is the field the
    /// old readout called "nailed", and it is reported unchanged so the history stays readable
    /// across the change.
    func testNailedIsTheIntersectionOfBothAxes() {
        let times = [
            mark(bars: 0),
            mark(bars: 8, offsetMs: 500),
            mark(bars: 17),
            mark(bars: 25, offsetMs: 500),
        ]
        let report = FormAnalysis.analyze(markTimes: times, grid: grid,
                                          beatsPerBar: beatsPerBar,
                                          barsPerPhrase: barsPerPhrase, totalBars: 32)

        XCTAssertLessThanOrEqual(report.nailedCount, report.onFormCount)
        XCTAssertLessThanOrEqual(report.nailedCount, report.cleanCount)
    }

    /// A rate rather than a count, since the ladder will read the rate and the takes differ in
    /// how many marks they contain.
    func testCleanRateIsOverEveryMarkPlaced() {
        let times = [mark(bars: 0), mark(bars: 8), mark(bars: 16, offsetMs: 500), mark(bars: 24)]
        let report = FormAnalysis.analyze(markTimes: times, grid: grid,
                                          beatsPerBar: beatsPerBar,
                                          barsPerPhrase: barsPerPhrase, totalBars: 32)

        XCTAssertEqual(report.marksPlaced, 4)
        XCTAssertEqual(report.cleanCount, 3)
        XCTAssertEqual(report.cleanRate, 0.75, accuracy: 1e-9)
    }
}
