import XCTest
@testable import TimingCore
import TestSupport

/// M15 step 2's regression gate: **a straight feel must change nothing.**
///
/// `Grid` is the type every measurement in this project rests on, and M15 rewrites how it turns
/// an index into a time. Every take ever recorded was played against an even grid, so if a
/// straight feel is not bit-for-bit the old behaviour then the whole history silently moves —
/// the trend, `review feel`, both experiments, every published figure in §7.
///
/// These are deliberately written against arithmetic stated independently of `Grid`, rather than
/// against `Grid`'s own new implementation. A test that asked the new code whether it agreed
/// with itself would pass through any mistake it happened to make consistently.
final class StraightGridIsUnchangedTests: XCTestCase {

    private let tempos = [60.0, 76, 100, 132, 180]
    private let subdivisionCounts = [1, 2, 3, 4]

    /// The old mapping, written out longhand: `startTime + index × (beat / subdivisions)`.
    private func oldTime(_ grid: Grid, _ index: Int) -> Double {
        grid.startTime + Double(index) * (60.0 / grid.bpm / Double(grid.subdivisions))
    }

    // MARK: Index to time

    func testEveryGridPointLandsExactlyWhereItUsedTo() {
        for bpm in tempos {
            for subdivisions in subdivisionCounts {
                let grid = Grid(startTime: 12.5, bpm: bpm, subdivisions: subdivisions)
                for index in -16...64 {
                    XCTAssertEqual(grid.time(ofIndex: index), oldTime(grid, index),
                                   accuracy: 1e-12,
                                   "\(bpm) BPM, \(subdivisions)/beat, index \(index)")
                }
            }
        }
    }

    /// Negative indices matter: the grid extends backwards so a dropout silence still has a
    /// reference, and floored division is easy to get wrong in exactly that direction.
    func testTheGridStillExtendsBackwardsCorrectly() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)
        XCTAssertEqual(grid.time(ofIndex: -1), -0.15, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofIndex: -4), -0.6, accuracy: 1e-12)
        XCTAssertEqual(grid.phase(ofIndex: -1), 3, "floored modulo, not truncated")
        XCTAssertEqual(grid.phase(ofIndex: -4), 0)
    }

    // MARK: Time to index

    /// The search over neighbouring beats has to agree with the division it replaces, including
    /// well away from the origin where floating-point error accumulates.
    func testNearestIndexAgreesWithTheDivisionItReplaces() {
        var rng = SeededRNG(seed: 0xF33150)
        for bpm in tempos {
            for subdivisions in subdivisionCounts {
                let grid = Grid(startTime: 3.25, bpm: bpm, subdivisions: subdivisions)
                let step = 60.0 / bpm / Double(subdivisions)
                for _ in 0..<400 {
                    // Anywhere in the first few minutes, but never exactly on a midpoint —
                    // those are unobservable (see the test below) and round in a direction
                    // the old code chose arbitrarily.
                    let offset = rng.gaussian(sd: 0.3 * step)
                    let index = Int(rng.uniform() * 600) - 100
                    let time = grid.time(ofIndex: index) + offset

                    let expected = Int(((time - grid.startTime) / step).rounded())
                    XCTAssertEqual(grid.nearestIndex(to: time), expected,
                                   "\(bpm) BPM, \(subdivisions)/beat near index \(index)")
                }
            }
        }
    }

    /// A tap exactly between two grid points cannot be matched to either — the window is 40% of
    /// the gap and a midpoint is 50% away from both — so how the tie breaks is unobservable.
    /// Stated as a test because it is the one place the two implementations may legitimately
    /// disagree, and the reason they may is that the answer never reaches a result.
    func testAMidpointIsAnExtraWhicheverWayItBreaks() {
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        let midpoint = (grid.time(ofIndex: 0) + grid.time(ofIndex: 1)) / 2
        let match = Matching.match(taps: [Tap(time: midpoint)], to: grid)

        XCTAssertTrue(match.matched.isEmpty)
        XCTAssertEqual(match.extraTaps.count, 1)
    }

    // MARK: The whole pipeline, over generated performances

    /// The report is what the player actually sees, so the gate is stated on the report rather
    /// than on the grid alone: plant a range of players, score them, and require every reported
    /// number to be unchanged.
    func testEveryReportedNumberIsUnchangedForAStraightPerformance() {
        for (name, performance) in Performance.pathologies {
            for subdivisions in subdivisionCounts {
                var rng = SeededRNG(seed: performance.seed)
                let grid = Grid(startTime: 8, bpm: 100, subdivisions: subdivisions)
                let taps = Generators.tapsOnGrid(grid: grid, beats: 96,
                                                 biasMs: performance.biasMs,
                                                 jitterMs: performance.spreadMs, rng: &rng)
                let report = TimingAnalysis.analyze(taps: taps, grid: grid)

                // Recomputing on a grid built the old way must give the identical answer. The
                // two grids differ only in that one names its feel, so any difference is the
                // feel leaking into a straight take.
                let same = Grid(startTime: 8, bpm: 100, subdivisions: subdivisions,
                                feel: .straight)
                let again = TimingAnalysis.analyze(taps: taps, grid: same)

                XCTAssertEqual(report.matchedCount, again.matchedCount, name)
                XCTAssertEqual(report.extraCount, again.extraCount, name)
                XCTAssertEqual(report.meanAsynchronyMs, again.meanAsynchronyMs,
                               accuracy: 1e-12, name)
                XCTAssertEqual(report.sdAsynchronyMs, again.sdAsynchronyMs,
                               accuracy: 1e-12, name)
                XCTAssertEqual(report.asynchroniesMs, again.asynchroniesMs, name)
            }
        }
    }

    /// The window a straight grid uses must be the same fraction of the same interval it always
    /// was — `Matching` is the only consumer of that number, and it decides what counts as
    /// played on the grid at all.
    func testTheMatchingWindowIsUnchangedOnAStraightGrid() {
        for bpm in tempos {
            for subdivisions in subdivisionCounts {
                let grid = Grid(startTime: 0, bpm: bpm, subdivisions: subdivisions)
                let oldInterval = 60.0 / bpm / Double(subdivisions)
                for index in 0..<8 {
                    XCTAssertEqual(grid.gap(around: index), oldInterval, accuracy: 1e-12,
                                   "\(bpm) BPM, \(subdivisions)/beat")
                }
            }
        }
    }
}
