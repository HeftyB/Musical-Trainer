import XCTest
@testable import TimingCore
import TestSupport

/// M15 step 2: a grid that expects the offbeat somewhere other than halfway.
///
/// The failure this exists to prevent is not a crash and not an obviously wrong number. It is
/// **style reported as error**: a player swinging correctly, scored against an even grid,
/// producing a large and entirely plausible-looking asynchrony. §5.3's sign inversion was the
/// same shape and took a live session to notice.
final class SwungGridTests: XCTestCase {

    /// Notes exactly where a feel says they belong.
    private func perfectTaps(feel: Feel, subdivisions: Int, bpm: Double = 100,
                             beats: Int = 64) -> (taps: [Tap], grid: Grid) {
        let grid = Grid(startTime: 5, bpm: bpm, subdivisions: subdivisions, feel: feel)
        let taps = (0..<(beats * subdivisions)).map { Tap(time: grid.time(ofIndex: $0)) }
        return (taps, grid)
    }

    // MARK: The trap, from both sides

    /// A player swinging perfectly, scored on the grid they were asked for, is perfect.
    func testAPerfectlySwungPerformanceScoresAsPerfect() {
        let (taps, grid) = perfectTaps(feel: .swung, subdivisions: 2)
        let report = TimingAnalysis.analyze(taps: taps, grid: grid, chordWindowMs: 0)

        XCTAssertEqual(report.matchedCount, taps.count, "every note is where it was asked for")
        XCTAssertEqual(report.extraCount, 0)
        XCTAssertEqual(report.sdAsynchronyMs, 0, accuracy: 1e-9)
        XCTAssertEqual(report.meanAsynchronyMs, 0, accuracy: 1e-9)
    }

    /// **Style as error, stated as the number it produces.**
    ///
    /// The first version of this test assumed the swung offbeats would be *discarded* by a
    /// straight grid. They are not, and that is what makes the failure dangerous rather than
    /// merely wrong: at 100 BPM a 2:1 offbeat sits 400 ms into the beat, only 100 ms past the
    /// straight eighth at 300 ms, and the window is ±120 ms. So every note matches, nothing is
    /// flagged, and a player swinging *perfectly* is reported as dragging 50 ms on average with
    /// a 50 ms spread — worse than any real take in this project's history, and completely
    /// plausible on the page. There is no off-grid rate to warn anybody either.
    func testAPerfectlySwungPlayerOnAStraightGridReadsAsBadlyDragging() {
        let (taps, _) = perfectTaps(feel: .swung, subdivisions: 2)
        let straight = Grid(startTime: 5, bpm: 100, subdivisions: 2)
        let report = TimingAnalysis.analyze(taps: taps, grid: straight, chordWindowMs: 0)

        XCTAssertEqual(report.matchedCount, taps.count,
                       "nothing is discarded — which is why this is invisible")
        XCTAssertEqual(report.extraCount, 0, "and no off-grid rate warns anybody")
        XCTAssertEqual(report.meanAsynchronyMs, 50, accuracy: 1,
                       "half the notes read as 100 ms late")
        XCTAssertEqual(report.sdAsynchronyMs, 50, accuracy: 1)
    }

    /// And straight playing scored on a swung grid is equally wrong, in the other direction.
    func testStraightPlayingOnASwungGridIsAlsoPenalised() {
        let (taps, _) = perfectTaps(feel: .straight, subdivisions: 2)
        let swung = Grid(startTime: 5, bpm: 100, subdivisions: 2, feel: .swung)
        let report = TimingAnalysis.analyze(taps: taps, grid: swung, chordWindowMs: 0)

        XCTAssertLessThan(report.matchedCount, taps.count)
    }

    // MARK: The sign convention survives the feel

    /// §5.3's trap, re-planted per feel: a note between two points, outside both windows, is an
    /// extra rather than being snapped to whichever is nearer and reported with the wrong sign.
    ///
    /// 45% of the gap past a point is the interesting place — beyond that point's own window and
    /// still short of the next one's. Under a feel the two neighbours are different distances
    /// away, which is exactly where a nearest-point search with one global window inverts.
    func testANoteBetweenTwoPointsIsAnExtraRatherThanSnapped() {
        for feel in [Feel.straight, .swung] {
            let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2, feel: feel)
            let late = Tap(time: grid.time(ofIndex: 1) + grid.gap(around: 1) * 0.45)
            let match = Matching.match(taps: [late], to: grid)

            XCTAssertTrue(match.matched.isEmpty, "\(feel.label): it became a match")
            XCTAssertEqual(match.extraTaps.count, 1, "\(feel.label)")
        }
    }

    /// Sign is preserved on both sides of a swung offbeat, where the room differs either way.
    func testEarlyIsNegativeAndLateIsPositiveAroundASwungOffbeat() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2, feel: .swung)
        let offbeat = grid.time(ofIndex: 1)

        let early = Matching.match(taps: [Tap(time: offbeat - 0.02)], to: grid)
        let late = Matching.match(taps: [Tap(time: offbeat + 0.02)], to: grid)

        XCTAssertEqual(early.matched.first?.asynchronyMs ?? 0, -20, accuracy: 0.001)
        XCTAssertEqual(late.matched.first?.asynchronyMs ?? 0, +20, accuracy: 0.001)
        XCTAssertEqual(early.matched.first?.gridIndex, 1)
        XCTAssertEqual(late.matched.first?.gridIndex, 1)
    }

    // MARK: The window under uneven spacing

    /// Symmetric on the smaller gap. An asymmetric window would be wider on the long side of a
    /// swung pair, capture more late outliers than early ones, and pull the mean late — a bias
    /// rather than merely a lost note.
    func testTheWindowIsSymmetricAndTakenFromTheSmallerGap() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2, feel: .swung)

        // Downbeat: 400 ms of room before it, 400 ms after (the previous offbeat is 200 ms back).
        XCTAssertEqual(grid.gap(around: 0), 0.2, accuracy: 1e-12)
        // Offbeat: 400 ms since the downbeat, 200 ms to the next one — the shorter one wins.
        XCTAssertEqual(grid.gap(around: 1), 0.2, accuracy: 1e-12)
    }

    /// Windows must never overlap, or a tap could match two points and the matcher's collision
    /// rule would be resolving a contradiction it should never see.
    func testAdjacentWindowsNeverOverlapAtAnyRatio() {
        for ratio in [1.0, 1.5, 2.0, 3.0, 4.0] {
            guard let feel = Feel(swingRatio: ratio) else { return XCTFail("\(ratio)") }
            for subdivisions in [2, 4] {
                let grid = Grid(startTime: 0, bpm: 100, subdivisions: subdivisions, feel: feel)
                for index in 0..<(subdivisions * 4) {
                    let here = grid.time(ofIndex: index)
                    let next = grid.time(ofIndex: index + 1)
                    let reach = Matching.defaultWindowFraction
                              * (grid.gap(around: index) + grid.gap(around: index + 1))
                    XCTAssertLessThan(reach, next - here,
                                      "ratio \(ratio), \(subdivisions)/beat, index \(index)")
                }
            }
        }
    }

    // MARK: A realistic swung player

    /// Planted swing with realistic scatter must come back as the ratio it was played at, and
    /// with the *spread* it was played with — the two numbers the swing report will rest on.
    func testAScatteredSwungPlayerRecoversItsRatioAndItsSpread() {
        guard let feel = Feel(swingRatio: 1.7) else { return XCTFail("1.7 is valid") }
        let grid = Grid(startTime: 2, bpm: 100, subdivisions: 2, feel: feel)
        var rng = SeededRNG(seed: 0x5A1B2)

        let taps = (0..<256).map { index in
            Tap(time: grid.time(ofIndex: index) + rng.gaussian(sd: 18) / 1000)
        }
        let report = TimingAnalysis.analyze(taps: taps, grid: grid, chordWindowMs: 0)

        XCTAssertEqual(report.meanAsynchronyMs, 0, accuracy: 3, "no systematic offset")
        XCTAssertEqual(report.sdAsynchronyMs, 18, accuracy: 3, "the spread it was played with")
        XCTAssertGreaterThan(Double(report.matchedCount) / 256, 0.95, "few notes lost")
    }
}
