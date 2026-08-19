import XCTest
import TestSupport
@testable import TimingCore

/// A hesitation is not a noisy beat.
///
/// `maxOddFraction` admits a trial with up to a quarter of its intervals outside the isochrony
/// band. That is the right question for "was this a continuation attempt at all" and the wrong
/// guard for what happens next, because Wing–Kristofferson is quadratic in the residuals: a
/// fraction gate counts an outlier once, and the variance it protects counts it squared.
///
/// Found on real data, not by reasoning. One take reported a clock SD of 193.5 ms at a 600 ms
/// beat — a third of a beat, one sigma, from a player whose every other take reads 11–41 ms.
/// Nine intervals out of 232 did it. See JOURNAL.md §7.25.
final class ContinuationRunTests: XCTestCase {

    // MARK: - Splitting

    func testASteadySequenceIsOneRun() {
        let intervals = Array(repeating: 600.0, count: 20)
        XCTAssertEqual(DropoutAnalysis.continuationRuns(intervals), [intervals])
    }

    func testAGapBreaksTheSequenceInTwo() {
        let intervals = Array(repeating: 600.0, count: 8)
            + [3000.0]
            + Array(repeating: 600.0, count: 9)
        let runs = DropoutAnalysis.continuationRuns(intervals)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map(\.count), [8, 9])
        XCTAssertFalse(runs.flatMap { $0 }.contains(3000.0),
                       "the gap itself is never an interval in a continuation sequence")
    }

    func testOrdinaryJitterIsNotABreak() {
        var rng = SeededRNG(seed: 0x51A9)
        let intervals = (0..<30).map { _ in 600 + rng.gaussian(sd: 25) }
        XCTAssertEqual(DropoutAnalysis.continuationRuns(intervals).count, 1,
                       "a 25 ms spread around a 600 ms beat is the thing being measured, not a "
                     + "break — the band is 0.6–1.6x, which is 360 to 960 ms")
    }

    func testABreakAtTheEdgeDoesNotProduceAnEmptyRun() {
        XCTAssertEqual(DropoutAnalysis.continuationRuns([3000] + Array(repeating: 600.0, count: 5)),
                       [Array(repeating: 600.0, count: 5)])
        XCTAssertEqual(DropoutAnalysis.continuationRuns(Array(repeating: 600.0, count: 5) + [3000]),
                       [Array(repeating: 600.0, count: 5)])
    }

    // MARK: - What it is for

    /// The defect's own signature, planted: a clean player with one hesitation in the middle.
    func testOneHesitationDoesNotBecomeClockNoise() {
        var rng = SeededRNG(seed: 0xC10C)
        let clean = (0..<40).map { _ in 600 + rng.gaussian(sd: 12) }

        let clockTruth = WingKristofferson.decompose(trials: [clean])?.clockSDms ?? .nan

        // One five-beat pause dropped into the middle of the same playing.
        var withGap = clean
        withGap.insert(3070, at: 20)

        let naive = WingKristofferson.decompose(trials: [withGap])
        let fixed = WingKristofferson.decompose(trials: DropoutAnalysis.continuationRuns(withGap))

        XCTAssertGreaterThan(naive?.clockSDms ?? 0, 300,
                             "this is the failure being prevented: a single pause reads as a "
                           + "clock wandering by half a beat")
        XCTAssertEqual(fixed?.clockSDms ?? .nan, clockTruth, accuracy: 6,
                       "split at the gap, the same playing recovers the clock it was planted "
                     + "with rather than the pause")
    }

    /// A fraction gate cannot protect a variance, stated as arithmetic rather than as prose.
    func testAFewOutliersDominateTheSquaredErrorTheyAreAMinorityOf() {
        var rng = SeededRNG(seed: 0x5EED)
        var intervals = (0..<48).map { _ in 600 + rng.gaussian(sd: 12) }
        intervals.insert(3070, at: 12)
        intervals.insert(2592, at: 30)

        let median = Stats.median(intervals)
        let odd = intervals.filter { $0 < 0.6 * median || $0 > 1.6 * median }
        let total = intervals.reduce(0.0) { $0 + ($1 - median) * ($1 - median) }
        let fromOdd = odd.reduce(0.0) { $0 + ($1 - median) * ($1 - median) }

        XCTAssertLessThan(Double(odd.count) / Double(intervals.count), 0.25,
                          "inside the trial-level fraction gate, so the trial is accepted whole")
        XCTAssertGreaterThan(fromOdd / total, 0.9,
                             "while carrying almost all of the variance the split is derived "
                           + "from — the mismatch this milestone exists to close")
    }

    // MARK: - Through the analysis

    private func report(intervalsPerSilence: [[Double]], bpm: Double = 100) -> DropoutReport {
        let grid = Grid(startTime: 0, bpm: bpm, subdivisions: 1)
        var taps: [Tap] = []
        var sections: [DropoutSection] = []
        var t = 0.0
        for intervals in intervalsPerSilence {
            let start = t
            taps.append(Tap(time: t, velocity: 80))
            for interval in intervals {
                t += interval / 1000
                taps.append(Tap(time: t, velocity: 80))
            }
            t += 1.0
            sections.append(DropoutSection(startTime: start, endTime: t, isPaced: false))
            let pacedStart = t
            t += 2.4
            sections.append(DropoutSection(startTime: pacedStart, endTime: t, isPaced: true))
        }
        return DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)
    }

    func testTheReportCountsTheGapsItBrokeOut() {
        var rng = SeededRNG(seed: 0x9A17)
        let silence = { (gaps: [Int]) -> [Double] in
            var out = (0..<30).map { _ in 600 + rng.gaussian(sd: 12) }
            for index in gaps.sorted(by: >) { out.insert(2800, at: index) }
            return out
        }
        let r = report(intervalsPerSilence: [silence([10]), silence([5, 20]), silence([])])

        XCTAssertEqual(r.brokenIntervals, 3, "one plus two plus none")
        XCTAssertEqual(r.discardedTrials, 0, "none of these silences was unusable as a whole")
        XCTAssertNotNil(r.wingKristofferson)
        XCTAssertLessThan(r.wingKristofferson?.clockSDms ?? .infinity, 40,
                          "the planted clock is 12 ms; without the split the pauses put this "
                        + "into the hundreds")
    }

    func testACleanTakeReportsNoBrokenIntervalsAndIsUnchanged() {
        var rng = SeededRNG(seed: 0xB0B)
        let silences = (0..<3).map { _ in (0..<30).map { _ in 600 + rng.gaussian(sd: 12) } }
        let r = report(intervalsPerSilence: silences)

        XCTAssertEqual(r.brokenIntervals, 0)
        XCTAssertEqual(r.wingKristofferson?.intervalCount,
                       silences.reduce(0) { $0 + $1.count },
                       "every interval still reaches the decomposition when nothing broke")
    }

    /// The tempo readout is built from medians and was right the whole time. Worth pinning, so
    /// a future change to the runs does not quietly move a number that was never wrong.
    func testTheTempoReadoutIsUnaffectedByGaps() {
        var rng = SeededRNG(seed: 0x7EE0)
        let clean = (0..<30).map { _ in 620 + rng.gaussian(sd: 12) }
        var gappy = clean
        gappy.insert(3070, at: 15)

        let a = report(intervalsPerSilence: [clean, clean, clean])
        let b = report(intervalsPerSilence: [gappy, gappy, gappy])
        XCTAssertEqual(try XCTUnwrap(a.playedBpm), try XCTUnwrap(b.playedBpm), accuracy: 0.5)
    }
}
