import XCTest
@testable import TimingCore
import TestSupport

/// M15 step 6: holding a position the band never states.
///
/// The failure this drill exists to catch is not poor placement. It is the feel **inverting** —
/// the chop moving onto the beat — and the reason that needs its own measure is that a slipped
/// player lands *dead on a grid point*. Score placement alone and a lost feel reads as excellent
/// timing.
final class OffbeatAnalysisTests: XCTestCase {

    /// A player putting notes at a given phase of each beat, with scatter.
    private func player(atPhase phase: Int, beats: Int = 64, spreadMs: Double = 14,
                        biasMs: Double = 0, subdivisions: Int = 2,
                        seed: UInt64 = 0x0FFB) -> (matched: [MatchedTap], grid: Grid) {
        let grid = Grid(startTime: 2, bpm: 100, subdivisions: subdivisions)
        var rng = SeededRNG(seed: seed)
        let taps = (0..<beats).map { beat -> Tap in
            let index = beat * subdivisions + phase
            return Tap(time: grid.time(ofIndex: index) + (biasMs + rng.gaussian(sd: spreadMs)) / 1000)
        }
        return (Matching.match(taps: taps, to: grid).matched, grid)
    }

    // MARK: The two failures, kept apart

    func testAPlayerHoldingTheOffbeatIsReportedAsHoldingIt() {
        let (matched, grid) = player(atPhase: 1, spreadMs: 14)
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertEqual(report.offbeatShare, 1, accuracy: 0.01)
        XCTAssertFalse(report.slipped)
        XCTAssertEqual(report.spreadMs ?? 0, 14, accuracy: 3)
        XCTAssertTrue(report.headline.contains("held the offbeat"), report.headline)
    }

    /// **The point of the drill.** A slipped player is not a sloppy one — they are precise, on
    /// the wrong points. Placement alone would call this an excellent take.
    func testASlippedPlayerIsCaughtDespitePerfectPlacement() {
        let (matched, grid) = player(atPhase: 0, spreadMs: 4)     // dead on the beat
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertTrue(report.slipped, "playing on the beat is the failure, however tightly")
        XCTAssertEqual(report.offbeatShare, 0, accuracy: 0.01)
        XCTAssertEqual(report.downbeatSpreadMs ?? 99, 4, accuracy: 2,
                       "and they were tight — which is exactly why placement cannot catch this")
        XCTAssertTrue(report.headline.contains("slipped onto the beat"), report.headline)
    }

    /// Half and half is oscillating, and worth naming as its own state.
    func testOscillatingBetweenTheBeatAndTheOffbeatCountsAsSlipped() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        var rng = SeededRNG(seed: 0xA17)
        let taps = (0..<64).map { i -> Tap in
            let index = i * 2 + (i % 2)                  // alternating beat / offbeat
            return Tap(time: grid.time(ofIndex: index) + rng.gaussian(sd: 10) / 1000)
        }
        let report = OffbeatAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                             grid: grid)
        XCTAssertTrue(report.slipped)
        XCTAssertEqual(report.offbeatShare, 0.5, accuracy: 0.05)
    }

    /// The millisecond figures still describe whichever notes stayed put, and the report says so
    /// rather than letting them be read as the take's placement.
    func testASlippedTakeSaysItsPlacementFiguresAreNotTheTake() {
        let (matched, grid) = player(atPhase: 0, spreadMs: 6)
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid)
        XCTAssertTrue(report.notes.contains { $0.contains("feel inverting") },
                      report.notes.description)
    }

    // MARK: Placement, when the feel is held

    func testPlacementSignSurvives() {
        let ahead = player(atPhase: 1, biasMs: -25, seed: 11)
        let behind = player(atPhase: 1, biasMs: +25, seed: 11)

        let a = OffbeatAnalysis.analyze(matched: ahead.matched, grid: ahead.grid)
        let b = OffbeatAnalysis.analyze(matched: behind.matched, grid: behind.grid)

        XCTAssertEqual(a.placementMs ?? 0, -25, accuracy: 4)
        XCTAssertEqual(b.placementMs ?? 0, +25, accuracy: 4)
        XCTAssertTrue(a.headline.contains("ahead"), a.headline)
        XCTAssertTrue(b.headline.contains("behind"), b.headline)
    }

    /// A player tight on the beat and loose off it has a feel problem rather than a timing one,
    /// and the two figures sitting side by side is what makes that visible.
    func testBeingTighterOnTheBeatThanOffItIsCalledOut() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        var rng = SeededRNG(seed: 0xB33)
        var taps: [Tap] = []
        for beat in 0..<64 {
            taps.append(Tap(time: grid.time(ofIndex: beat * 2) + rng.gaussian(sd: 5) / 1000))
            taps.append(Tap(time: grid.time(ofIndex: beat * 2 + 1) + rng.gaussian(sd: 28) / 1000))
            taps.append(Tap(time: grid.time(ofIndex: beat * 2 + 1) + rng.gaussian(sd: 28) / 1000))
        }
        let report = OffbeatAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                             grid: grid)
        XCTAssertTrue(report.notes.contains { $0.contains("tighter than") }, report.notes.description)
    }

    // MARK: Refusals

    func testTooLittlePlayingRefusesRatherThanGuessing() {
        let (matched, grid) = player(atPhase: 1, beats: 6)
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid)

        XCTAssertFalse(report.slipped, "six notes cannot establish that a feel was lost")
        XCTAssertTrue(report.headline.contains("Not enough"), report.headline)
    }

    /// On a finer grid, notes between the beat and the offbeat belong to neither and must not
    /// flatter either count.
    func testSixteenthsBetweenThePointsCountForNeither() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)
        let taps = (0..<32).map { Tap(time: grid.time(ofIndex: $0 * 4 + 1)) }   // the "e"
        let report = OffbeatAnalysis.analyze(matched: Matching.match(taps: taps, to: grid).matched,
                                             grid: grid)

        XCTAssertEqual(report.onOffbeat, 0)
        XCTAssertEqual(report.onDownbeat, 0)
    }

    // MARK: Promotion

    func testALevelIsEarnedOnlyByHoldingTheFeelTightly() {
        let held = OffbeatReport(onOffbeat: 60, onDownbeat: 1, offbeatShare: 0.98,
                                 placementMs: -5, spreadMs: 15, downbeatSpreadMs: nil,
                                 slipped: false, headline: "", notes: [])
        XCTAssertEqual(OffbeatAnalysis.suggestedLevel(current: 1, highest: 3, report: held,
                                                      spreadCeilingMs: 20), 2)

        let loose = OffbeatReport(onOffbeat: 60, onDownbeat: 1, offbeatShare: 0.98,
                                  placementMs: -5, spreadMs: 40, downbeatSpreadMs: nil,
                                  slipped: false, headline: "", notes: [])
        XCTAssertEqual(OffbeatAnalysis.suggestedLevel(current: 1, highest: 3, report: loose,
                                                      spreadCeilingMs: 20), 1)
    }

    /// **Nothing is earned by a slipped take**, however tight the surviving notes were —
    /// promoting on one would measure a flip at the next level rather than a placement.
    func testASlippedTakeEarnsNothing() {
        let slipped = OffbeatReport(onOffbeat: 10, onDownbeat: 50, offbeatShare: 0.17,
                                    placementMs: 0, spreadMs: 4, downbeatSpreadMs: 4,
                                    slipped: true, headline: "", notes: [])
        XCTAssertEqual(OffbeatAnalysis.suggestedLevel(current: 1, highest: 3, report: slipped,
                                                      spreadCeilingMs: 20), 1)
    }

    func testTheTopLevelDoesNotPromotePastItself() {
        let held = OffbeatReport(onOffbeat: 60, onDownbeat: 0, offbeatShare: 1,
                                 placementMs: 0, spreadMs: 10, downbeatSpreadMs: nil,
                                 slipped: false, headline: "", notes: [])
        XCTAssertEqual(OffbeatAnalysis.suggestedLevel(current: 3, highest: 3, report: held,
                                                      spreadCeilingMs: 20), 3)
    }
}
