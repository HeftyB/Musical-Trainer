import XCTest
import TestSupport
@testable import TimingCore

/// One asked-for position generalised to a set, and the number that only exists once there is one.
///
/// §7.13's premise for the whole skank family is that "hold a position the band never plays"
/// generalises. `OffbeatAnalysis` hardcoded a single phase — `max(1, subdivisions / 2)`, the "and" —
/// which is the one figure the family had when it was written.
///
/// **The share cannot see a half-played figure**, and that is what makes this more than a
/// refactor: asked for two notes after each beat, a player who plays only the first is 100% off
/// the beat. Perfect by every number the report had before, and playing half the figure.
final class OffbeatPhaseSetTests: XCTestCase {

    /// A player who hits `phases` cleanly, `perPhase` notes at each, on a grid of `subdivisions`.
    private func player(phases: [Int], perPhase: Int, subdivisions: Int,
                        spreadMs: Double = 8, seed: UInt64 = 7)
        -> (matched: [MatchedTap], grid: Grid) {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: subdivisions)
        var rng = SplitMix64(seed: seed)
        var matched: [MatchedTap] = []
        for beat in 0..<perPhase {
            for phase in phases {
                let index = beat * subdivisions + phase
                let jitter = (Double(rng.next() % 1000) / 1000 - 0.5) * 2 * spreadMs
                matched.append(MatchedTap(tap: Tap(time: grid.time(ofIndex: index) + jitter / 1000),
                                          gridIndex: index, asynchronyMs: jitter))
            }
        }
        return (matched, grid)
    }

    // MARK: The number that did not exist before

    /// The defect this generalisation is for. Both players are **100% off the beat**; one is
    /// playing the figure and one is playing half of it.
    func testAHalfPlayedFigureIsCaughtByCompletenessAndNotByTheShare() {
        let whole = player(phases: [1, 2], perPhase: 16, subdivisions: 3)
        let half = player(phases: [1], perPhase: 32, subdivisions: 3)

        let a = OffbeatAnalysis.analyze(matched: whole.matched, grid: whole.grid, asking: [1, 2])
        let b = OffbeatAnalysis.analyze(matched: half.matched, grid: half.grid, asking: [1, 2])

        XCTAssertEqual(a.offbeatShare, 1, accuracy: 1e-9)
        XCTAssertEqual(b.offbeatShare, 1, accuracy: 1e-9, "the share cannot tell these apart")

        XCTAssertEqual(a.completeness, 1, accuracy: 1e-9)
        XCTAssertEqual(b.completeness, 0, accuracy: 1e-9)
        XCTAssertFalse(a.incomplete)
        XCTAssertTrue(b.incomplete, "half a figure read as a whole one")
    }

    /// And it says so where the player reads, rather than only in a field.
    func testAHalfPlayedFigureIsSaidOutLoud() {
        let half = player(phases: [2], perPhase: 32, subdivisions: 4)
        let report = OffbeatAnalysis.analyze(matched: half.matched, grid: half.grid, asking: [2, 3])

        XCTAssertTrue(report.headline.contains("part of the figure"), report.headline)
        XCTAssertTrue(report.notes.contains { $0.contains("half the figure is missing") },
                      "\(report.notes)")
    }

    /// A lean is not a missing note. The threshold has to admit a player favouring one of the pair
    /// while still catching one who is not playing the other at all.
    func testAnUnevenButWholeFigureIsNotCalledIncomplete() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 3)
        var matched: [MatchedTap] = []
        for beat in 0..<24 {
            matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 3 + 1,
                                      asynchronyMs: 0))
            if beat % 3 != 0 {      // two of every three — a lean, not an absence
                matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 3 + 2,
                                      asynchronyMs: 0))
            }
        }
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid, asking: [1, 2])
        XCTAssertGreaterThan(report.completeness, OffbeatAnalysis.completenessThreshold)
        XCTAssertFalse(report.incomplete)
    }

    // MARK: Per-phase placement

    /// `SwingReport`'s precedent: the two notes of a figure get their own placement, because a
    /// single spread over the pair describes neither. Planted with one position tight and the
    /// other loose, which one number would average into something true of no note played.
    func testEachAskedPositionIsPlacedOnItsOwn() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 3)
        var matched: [MatchedTap] = []
        for beat in 0..<24 {
            matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 3 + 1,
                                      asynchronyMs: beat % 2 == 0 ? -1 : 1))
            matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 3 + 2,
                                      asynchronyMs: beat % 2 == 0 ? -40 : 40))
        }
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid, asking: [1, 2])

        XCTAssertEqual(report.perPhase.map(\.phase), [1, 2], "reported in the order asked")
        let tight = report.perPhase[0]
        let loose = report.perPhase[1]
        XCTAssertEqual(tight.spreadMs ?? 0, 1, accuracy: 0.5)
        XCTAssertEqual(loose.spreadMs ?? 0, 40, accuracy: 1)
        XCTAssertEqual(tight.count, 24)
        XCTAssertEqual(loose.count, 24)
    }

    // MARK: Nothing already recorded moves

    /// **The guard on the whole change.** Seven offbeat takes exist and R3.1 re-analyses every one
    /// of them on every readout, so a generalisation that shifted the single-phase answer would
    /// silently move seven takes' worth of published numbers.
    func testASinglePhaseFigureIsScoredExactlyAsBefore() {
        for subdivisions in [2, 4] {
            let skank = player(phases: [max(1, subdivisions / 2)], perPhase: 32,
                               subdivisions: subdivisions)
            let asked = OffbeatAnalysis.skankPhases(on: skank.grid)
            let report = OffbeatAnalysis.analyze(matched: skank.matched, grid: skank.grid,
                                                 asking: asked)

            XCTAssertEqual(asked, [max(1, subdivisions / 2)], "the drill's own phase")
            XCTAssertEqual(report.offbeatShare, 1, accuracy: 1e-9)
            XCTAssertEqual(report.onOffbeat, 32)
            // A figure of one position is complete by definition, so this can never make an
            // existing take read as half-played.
            XCTAssertEqual(report.completeness, 1, accuracy: 1e-9)
            XCTAssertFalse(report.incomplete)
            XCTAssertEqual(report.perPhase.count, 1)
            XCTAssertEqual(report.perPhase.first?.spreadMs ?? -1, report.spreadMs ?? -2,
                           accuracy: 1e-9, "one position: the pooled and per-phase figures are one")
        }
    }

    /// Notes that are neither the beat nor asked for stay out of both counts — the rule that was
    /// already there for stray sixteenths, now stated over a set.
    func testNotesAtUnaskedPositionsCountForNeitherSide() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)
        var matched: [MatchedTap] = []
        for beat in 0..<24 {
            matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 4 + 2,
                                      asynchronyMs: 0))    // asked
            matched.append(MatchedTap(tap: Tap(time: 0), gridIndex: beat * 4 + 1,
                                      asynchronyMs: 0))    // the "e" — neither
        }
        let report = OffbeatAnalysis.analyze(matched: matched, grid: grid, asking: [2])
        XCTAssertEqual(report.onOffbeat, 24)
        XCTAssertEqual(report.onDownbeat, 0)
        XCTAssertEqual(report.offbeatShare, 1, accuracy: 1e-9)
    }
}
