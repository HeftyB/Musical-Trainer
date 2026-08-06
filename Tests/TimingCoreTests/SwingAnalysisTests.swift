import XCTest
@testable import TimingCore
import TestSupport

/// M15 step 3: how the player divides the beat, and in which unit that may be reported.
final class SwingAnalysisTests: XCTestCase {

    /// A player who divides the beat at `playedRatio` while being scored against `askedFeel`.
    private func performance(askedFeel: Feel, playedRatio: Double, spreadMs: Double,
                             subdivisions: Int = 2, beats: Int = 128,
                             seed: UInt64 = 0x11FE) -> (matched: [MatchedTap], grid: Grid) {
        let grid = Grid(startTime: 1, bpm: 100, subdivisions: subdivisions, feel: askedFeel)
        guard let played = Feel(swingRatio: playedRatio) else { return ([], grid) }
        let truth = Grid(startTime: 1, bpm: 100, subdivisions: subdivisions, feel: played)

        var rng = SeededRNG(seed: seed)
        let taps = (0..<(beats * subdivisions)).map { index in
            Tap(time: truth.time(ofIndex: index) + rng.gaussian(sd: spreadMs) / 1000)
        }
        return (Matching.match(taps: taps, to: grid).matched, grid)
    }

    // MARK: The ratio comes back

    func testAPlayerSwingingAtTheAskedRatioReportsThatRatio() {
        let (matched, grid) = performance(askedFeel: .swung, playedRatio: 2, spreadMs: 15)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertEqual(report.producedRatio ?? 0, 2, accuracy: 0.15)
        XCTAssertEqual(report.producedPhase ?? 0, 2.0 / 3, accuracy: 0.02)
        XCTAssertTrue(report.ratioIsMeaningful)
    }

    /// Scored against one feel while playing another, the gap shows up rather than vanishing.
    func testPlayingStraighterThanAskedIsReportedAsSuch() {
        let (matched, grid) = performance(askedFeel: .swung, playedRatio: 1.4, spreadMs: 12)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertEqual(report.askedRatio, 2)
        XCTAssertLessThan(report.producedRatio ?? 99, 1.8)
        XCTAssertTrue(report.notes.contains { $0.contains("Asked for") }, report.notes.description)
    }

    /// A player asked for straight eighths who is quietly swinging them. This is answerable on
    /// takes that exist, and nothing in the app could ask it before.
    func testUnconsciousSwingOnAStraightGridIsVisible() {
        let (matched, grid) = performance(askedFeel: .straight, playedRatio: 1.35, spreadMs: 12)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertEqual(report.askedRatio, 1, "the take was asked for straight")
        XCTAssertGreaterThan(report.producedPhase ?? 0, SwingAnalysis.audibleSwingPhase)
        XCTAssertEqual(report.producedRatio ?? 0, 1.35, accuracy: 0.15)
    }

    func testAnEvenPlayerReadsAsStraightRatherThanFaintlySwung() {
        let (matched, grid) = performance(askedFeel: .straight, playedRatio: 1, spreadMs: 18)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertEqual(report.producedPhase ?? 0, 0.5, accuracy: 0.02)
        XCTAssertTrue(report.headline.contains("straight"), report.headline)
    }

    // MARK: Consistency is a spread in milliseconds

    /// **The argument of §7.24, as a test.** Two players with the *same* physical steadiness, one
    /// straight and one swinging hard: their reported consistency must match, because it is a
    /// spread in milliseconds. Report it as a spread of ratios instead and the deep swinger
    /// looks far worse for no reason he could hear or change.
    func testTheSameSteadinessReportsTheSameConsistencyAtAnyRatio() {
        let straight = performance(askedFeel: .straight, playedRatio: 1, spreadMs: 16, seed: 7)
        let deep = performance(askedFeel: Feel(swingRatio: 3) ?? .swung, playedRatio: 3,
                               spreadMs: 16, seed: 7)

        let a = SwingAnalysis.analyze(matched: straight.matched, grid: straight.grid)
        let b = SwingAnalysis.analyze(matched: deep.matched, grid: deep.grid)

        XCTAssertEqual(a.offbeatSpreadMs ?? 0, 16, accuracy: 2.5)
        XCTAssertEqual(b.offbeatSpreadMs ?? 0, 16, accuracy: 2.5)
        XCTAssertEqual(a.offbeatSpreadMs ?? 0, b.offbeatSpreadMs ?? 0, accuracy: 3,
                       "same hands, same number — whatever the ratio")

        // What the rejected unit would have said about those same two takes.
        let asRatioSpread = { (feel: Feel) -> Double in
            let phase = feel.offbeatPhase
            return 1 / pow(1 - phase, 2) * (16.0 / 600)
        }
        XCTAssertGreaterThan(asRatioSpread(Feel(swingRatio: 3) ?? .swung)
                           / asRatioSpread(.straight), 3.5,
                             "a ratio spread would call the deep swinger 3.5x worse")
    }

    /// The downbeat's spread sits beside the offbeat's precisely so a reader can ask whether the
    /// pulse or the placement inside it is the looser half — the clock/motor question on a new
    /// axis.
    func testTheBeatAndTheSwungNoteAreReportedSideBySide() {
        let (matched, grid) = performance(askedFeel: .swung, playedRatio: 2, spreadMs: 14)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertNotNil(report.downbeatSpreadMs)
        XCTAssertNotNil(report.offbeatSpreadMs)
        XCTAssertGreaterThan(report.downbeatCount, 100)
        XCTAssertGreaterThan(report.offbeatCount, 100)
    }

    /// An offbeat that scatters far more than the beat is worth naming — it is the difference
    /// between an unsteady pulse and an unsteady feel.
    func testALooseOffbeatOverASteadyBeatIsCalledOut() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2, feel: .swung)
        var rng = SeededRNG(seed: 0xB0B)
        let taps = (0..<256).map { index -> Tap in
            let jitter = index % 2 == 0 ? 5.0 : 30.0
            return Tap(time: grid.time(ofIndex: index) + rng.gaussian(sd: jitter) / 1000)
        }
        let report = SwingAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                           grid: grid)

        XCTAssertTrue(report.notes.contains { $0.contains("scatters more than the beat") },
                      report.notes.description)
    }

    // MARK: Refusals

    /// Triplets are the division swing borrows from, so there is no pair to swing and no ratio.
    func testATripletGridReportsNoRatioAndSaysWhy() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 3)
        let taps = (0..<96).map { Tap(time: grid.time(ofIndex: $0)) }
        let report = SwingAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                           grid: grid)

        XCTAssertFalse(report.ratioIsMeaningful)
        XCTAssertNil(report.producedRatio)
        XCTAssertTrue(report.notes.contains { $0.contains("no binary pair") },
                      report.notes.description)
    }

    /// **Found by wiring the readout to real takes, not by reasoning.** A free jam with 12 notes
    /// off the division against 117 on it reported "you swing each eighth 1.4:1" with an
    /// interval excluding even — a confident statement about a feel, computed from twelve
    /// incidental grace notes. Twelve is plenty for a bootstrap and nowhere near a division.
    func testOrnamentalOffDivisionNotesAreNotAFeel() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        var taps = (0..<120).map { Tap(time: grid.time(ofIndex: $0 * 2)) }
        // A scattering of off-division notes, pushed late enough to look like swing.
        taps += (0..<30).map { Tap(time: grid.time(ofIndex: $0 * 8 + 1) + 0.03) }

        let report = SwingAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                           grid: grid)
        XCTAssertNil(report.producedRatio, "30 notes against 120 is ornament, not a division")
        XCTAssertTrue(report.notes.contains { $0.contains("ornament") }, report.notes.description)
    }

    /// And a player genuinely dividing — roughly one off-division note per on — is measured.
    func testAGenuineDivisionIsMeasured() {
        let (matched, grid) = performance(askedFeel: .swung, playedRatio: 2, spreadMs: 15)
        let report = SwingAnalysis.analyze(matched: matched, grid: grid)
        XCTAssertNotNil(report.producedRatio)
        XCTAssertGreaterThan(Double(report.offbeatCount) / Double(report.downbeatCount),
                             SwingAnalysis.minimumOffbeatShare)
    }

    func testTooFewOffDivisionNotesRefusesRatherThanGuessing() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        // Beats only — nothing between them.
        let taps = (0..<40).map { Tap(time: grid.time(ofIndex: $0 * 2)) }
        let report = SwingAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                           grid: grid)

        XCTAssertNil(report.producedRatio)
        XCTAssertEqual(report.offbeatCount, 0)
        XCTAssertTrue(report.notes.contains { $0.contains("are needed") }, report.notes.description)
        XCTAssertTrue(report.headline.contains("Not enough"), report.headline)
    }

    // MARK: The interval on the ratio

    /// Transformed from the phase interval rather than bootstrapped directly, so it must still
    /// bracket the point and widen as the playing gets looser.
    func testTheRatioIntervalBracketsThePointAndWidensWithScatter() throws {
        let tight = performance(askedFeel: .swung, playedRatio: 2, spreadMs: 8, seed: 3)
        let loose = performance(askedFeel: .swung, playedRatio: 2, spreadMs: 40, seed: 3)

        let a = try XCTUnwrap(SwingAnalysis.analyze(matched: tight.matched, grid: tight.grid)
                                .producedRatioInterval)
        let b = try XCTUnwrap(SwingAnalysis.analyze(matched: loose.matched, grid: loose.grid)
                                .producedRatioInterval)

        XCTAssertLessThan(a.low, a.point)
        XCTAssertGreaterThan(a.high, a.point)
        XCTAssertGreaterThan(b.margin, a.margin, "looser playing must widen the interval")
    }

    /// The transform is monotonic, which is the property that lets endpoints map across at all.
    func testTheRatioTransformIsMonotonicAndRefusesTheEnds() {
        var previous = -Double.infinity
        for phase in stride(from: 0.06, through: 0.94, by: 0.02) {
            let ratio = SwingAnalysis.ratioFor(phase: phase)
            XCTAssertNotNil(ratio, "\(phase)")
            XCTAssertGreaterThan(ratio ?? 0, previous, "\(phase)")
            previous = ratio ?? 0
        }
        XCTAssertNil(SwingAnalysis.ratioFor(phase: 0.01))
        XCTAssertNil(SwingAnalysis.ratioFor(phase: 0.99))
    }
}
