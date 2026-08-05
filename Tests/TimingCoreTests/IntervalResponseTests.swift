import XCTest
@testable import TimingCore

/// M14 step 3: does tempo change how he plays, and can the data say?
final class IntervalResponseTests: XCTestCase {

    private func takes(bpm: Double, subdivisions: Int = 1, spread: [Double], bias: [Double],
                       sittings: [UUID]? = nil) -> [IntervalObservation] {
        spread.indices.map { i in
            IntervalObservation(bpm: bpm, subdivisions: subdivisions,
                                spreadMs: spread[i], biasMs: bias[i],
                                sittingId: sittings?[i] ?? UUID())
        }
    }

    // MARK: - Subdivision and tempo are one axis

    func testTakesAtTheSameIntervalShareABucketHoweverTheyGotThere() {
        // Eighths at 100 BPM and quarters at 200 are both a 300 ms task.
        let mixed = takes(bpm: 100, subdivisions: 2, spread: [20], bias: [-10])
                  + takes(bpm: 200, subdivisions: 1, spread: [22], bias: [-12])
        let report = IntervalResponseAnalysis.analyze(mixed)

        XCTAssertEqual(report.buckets.count, 1, "one interval, two ways of reaching it")
        XCTAssertEqual(report.buckets.first?.takes, 2)
        XCTAssertEqual(report.buckets.first?.intervalMs ?? 0, 300, accuracy: 0.01)
    }

    // MARK: - The refusal

    /// The state of the real data: 16 takes at one tempo, 4 at another, 1 at a third.
    func testAClusterOfOneTempoCannotAnswerTheQuestion() {
        let observations = takes(bpm: 100, spread: Array(repeating: 20, count: 16),
                                 bias: Array(repeating: -15, count: 16))
                         + takes(bpm: 110, spread: [24, 25, 25, 22], bias: [-3, -5, -3, -7])
                         + takes(bpm: 120, spread: [19], bias: [-14])
        let report = IntervalResponseAnalysis.analyze(observations)

        guard case .notEnoughRange(let reason) = report.verdict else {
            return XCTFail("expected a refusal, got \(report.verdict)")
        }
        XCTAssertNil(report.biasVsInterval, "no slope may exist below the range, not even unshown")
        XCTAssertNil(report.relativeSpreadVsInterval)
        XCTAssertTrue(reason.contains("intervals"), reason)
        // It still says what each interval measured — the buckets are not the problem.
        XCTAssertEqual(report.buckets.count, 3)
    }

    func testOneTakeAtAnIntervalDoesNotAnchorIt() {
        let observations = takes(bpm: 80, spread: [20, 21], bias: [-20, -18])
                         + takes(bpm: 100, spread: [20, 19], bias: [-15, -14])
                         + takes(bpm: 120, spread: [18], bias: [-10])
        guard case .notEnoughRange = IntervalResponseAnalysis.analyze(observations).verdict else {
            return XCTFail("two anchored intervals is not an axis")
        }
    }

    // MARK: - The claims, once there is range

    /// "Slow tempos make me rush": bias more negative as the interval lengthens.
    func testRushingAtSlowTemposIsFoundWhenItIsThere() {
        let observations = takes(bpm: 60, spread: [20, 21, 20], bias: [-30, -32, -28])
                         + takes(bpm: 100, spread: [20, 19, 21], bias: [-18, -20, -17])
                         + takes(bpm: 150, spread: [20, 20, 19], bias: [-6, -8, -5])
        let report = IntervalResponseAnalysis.analyze(observations)

        let bias = try? XCTUnwrap(report.biasVsInterval)
        XCTAssertEqual(report.verdict, .responds)
        XCTAssertTrue(try XCTUnwrap(bias).isReal)
        XCTAssertLessThan(try XCTUnwrap(bias).slope, 0, "longer interval, further ahead")
        XCTAssertTrue(report.headline.contains("ahead of the beat"), report.headline)
    }

    /// The trap the whole analysis exists to avoid: raw spread falls at faster tempos on its
    /// own. A player whose *relative* precision is identical everywhere must come back flat.
    func testConstantRelativePrecisionIsNotReportedAsATempoEffect() {
        // Spread is exactly 3% of the interval at every tempo — the same skill throughout.
        let observations = [60.0, 100, 150].flatMap { bpm -> [IntervalObservation] in
            let interval = 60_000 / bpm
            return takes(bpm: bpm,
                         spread: [interval * 0.03, interval * 0.031, interval * 0.029],
                         bias: [-12, -13, -11])
        }
        let report = IntervalResponseAnalysis.analyze(observations)

        let spread = try? XCTUnwrap(report.relativeSpreadVsInterval)
        XCTAssertFalse(try XCTUnwrap(spread).isReal,
                       "identical relative precision must not read as a tempo effect")
        // And the raw millisecond spreads it was computed from are wildly different, which is
        // exactly why the normalisation is not optional.
        let raw = report.buckets.compactMap(\.meanSpreadMs)
        XCTAssertGreaterThan(try XCTUnwrap(raw.max()) / XCTUnwrap(raw.min()), 2)
    }

    func testGenuineRelativeLooseningAtLongIntervalsIsFound() {
        let observations = [60.0, 100, 150].flatMap { bpm -> [IntervalObservation] in
            let interval = 60_000 / bpm
            // Relative spread worsens as the interval grows: 2% at the fast end, 5% at the slow.
            let fraction = 0.02 + 0.03 * (interval - 400) / 600
            return takes(bpm: bpm,
                         spread: [interval * fraction, interval * (fraction + 0.001),
                                  interval * (fraction - 0.001)],
                         bias: [-12, -13, -11])
        }
        let report = IntervalResponseAnalysis.analyze(observations)
        let spread = try? XCTUnwrap(report.relativeSpreadVsInterval)
        XCTAssertTrue(try XCTUnwrap(spread).isReal)
        XCTAssertGreaterThan(try XCTUnwrap(spread).slope, 0)
    }

    // MARK: - Caveats

    func testAnIntervalPlayedOnlyInOneSittingIsFlagged() {
        let evening = UUID()
        let observations = takes(bpm: 60, spread: [20, 21, 20], bias: [-30, -32, -28])
                         + takes(bpm: 100, spread: [20, 19, 21], bias: [-18, -20, -17])
                         + takes(bpm: 150, spread: [20, 20, 19], bias: [-6, -8, -5],
                                 sittings: [evening, evening, evening])
        let report = IntervalResponseAnalysis.analyze(observations)
        XCTAssertTrue(report.notes.contains { $0.contains("one sitting") }, report.notes.description)
    }

    /// Both units are offered and neither is declared the comparable one in advance.
    ///
    /// This asserted the opposite until M14 step 3b: that the report always explains why it
    /// normalised by the interval. It normalised on §7.23's premise that scatter grows with the
    /// interval — and `ProducedIntervalAnalysis`, run over the notes already on disk, found that
    /// premise false for this player. Reporting one derived number and an explanation of it is
    /// how an assumption becomes a result, so the report now shows milliseconds *and*
    /// percentages and says which one turned out flat.
    func testBothUnitsAreOfferedRatherThanOneBeingAssumed() {
        let observations = takes(bpm: 60, spread: [20, 21], bias: [-30, -32])
                         + takes(bpm: 100, spread: [20, 19], bias: [-18, -20])
        let report = IntervalResponseAnalysis.analyze(observations)
        XCTAssertTrue(report.notes.contains { $0.contains("milliseconds")
                                           && $0.contains("percentage") },
                      report.notes.description)
    }

    /// A player with constant absolute spread and one with constant relative spread must not
    /// produce the same report, or the two fits are not carrying independent information.
    func testTheTwoSpreadFitsSeparateTheTwoKindsOfPlayer() throws {
        let intervals = [(60.0, 1000.0), (100.0, 600.0), (150.0, 400.0)]

        let flatMs = intervals.flatMap { bpm, _ in
            takes(bpm: bpm, spread: [20, 21, 19], bias: [-12, -13, -11])
        }
        let flatPercent = intervals.flatMap { bpm, ms in
            takes(bpm: bpm, spread: [ms * 0.04, ms * 0.042, ms * 0.038], bias: [-12, -13, -11])
        }

        let absolute = IntervalResponseAnalysis.analyze(flatMs)
        XCTAssertEqual(absolute.absoluteSpreadVsInterval?.isReal, false)
        XCTAssertEqual(absolute.relativeSpreadVsInterval?.isReal, true)
        XCTAssertTrue(absolute.notes.contains { $0.contains("milliseconds are what compares") },
                      absolute.notes.description)

        let relative = IntervalResponseAnalysis.analyze(flatPercent)
        XCTAssertEqual(relative.relativeSpreadVsInterval?.isReal, false)
        XCTAssertEqual(relative.absoluteSpreadVsInterval?.isReal, true)
        XCTAssertTrue(relative.notes.contains { $0.contains("percentages are what compare") },
                      relative.notes.description)
    }

    /// "To a point" is an optimum, and a straight line cannot carry it. Saying so is the
    /// difference between an answer and half of one.
    func testTheLimitOfAStraightLineIsStated() {
        let observations = [60.0, 100, 150].flatMap { bpm in
            takes(bpm: bpm, spread: [20, 21, 19], bias: [-12, -13, -11])
        }
        let report = IntervalResponseAnalysis.analyze(observations)
        XCTAssertTrue(report.notes.contains { $0.contains("optimum") }, report.notes.description)
    }
}
