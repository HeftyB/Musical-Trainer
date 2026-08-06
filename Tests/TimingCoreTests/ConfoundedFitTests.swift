import XCTest
@testable import TimingCore

/// What a confounded fit does, as arithmetic rather than as a warning.
///
/// The trends that pooled across a drill parameter printed a caveat beside the verdict. This is
/// what the caveat was standing next to: groups that are each flat, fitted as one line, produce a
/// confident slope in whichever direction the harder group happens to fall.
///
/// Stated here rather than only in `TrendGroupingTests` because that suite proves the *split*
/// happens and this one proves the split was *needed* — a grouping test alone would pass just as
/// happily if the confound had never mattered. See PLAN.md §7.27.
final class ConfoundedFitTests: XCTestCase {

    /// Five easy takes then five hard ones, each group steady within itself.
    private let easyThenHard = [12.0, 13, 12, 14, 12, 30, 31, 29, 30, 31]

    func testTwoFlatGroupsPooledProduceAConfidentSlope() throws {
        let fit = try XCTUnwrap(TrendAnalysis.row("clock SD", easyThenHard,
                                                  lowerIsBetter: true).fit)
        XCTAssertEqual(fit.verdict, .worsening,
                       "nobody got worse — the task got harder, and one line cannot tell")
        XCTAssertGreaterThan(fit.low, 0,
                             "and the interval excludes zero, so it reads as a real change")
    }

    func testEachGroupOnItsOwnIsFlat() {
        for group in [Array(easyThenHard.prefix(5)), Array(easyThenHard.suffix(5))] {
            XCTAssertEqual(TrendAnalysis.row("clock SD", group, lowerIsBetter: true).fit?.verdict,
                           .flat, "\(group)")
        }
    }

    /// The direction is an artefact of the order the difficulties happened to fall in, which is
    /// the tell that it is not about the player: the same ten takes hardest-first read as
    /// improving.
    func testTheSameTakesInTheOppositeOrderReadAsImproving() {
        let fit = TrendAnalysis.row("clock SD", easyThenHard.reversed(), lowerIsBetter: true).fit
        XCTAssertEqual(fit?.verdict, .improving)
    }

    /// The real one, and the reason this is a fix rather than a tidy-up.
    ///
    /// Every reliable clock SD on record, in the order played, with `nan` for the three takes
    /// whose split was withheld. Values transcribed from `review dropout` rather than recomputed
    /// here, so this asserts against a figure stated independently of the code under test
    /// (`LESSONS.md` shape 4). Silence lengths run 2, 4, 4, 4, 4, 8, 16, 16, 4, 8 — the two
    /// hardest tasks land late, and the fit reads that as the player getting worse.
    func testTheContinuationTrendsWorseningVerdictWasTheSilenceLength() throws {
        let asPlayed: [Double] = [.nan, .nan, 13.8, 12.5, 15.3, 11.4, 21.7,
                                  29.6, 22.1, .nan, 19.6, 24.1]
        let pooled = try XCTUnwrap(TrendAnalysis.row("clock SD", asPlayed,
                                                     lowerIsBetter: true).fit)
        XCTAssertEqual(pooled.verdict, .worsening)
        XCTAssertGreaterThan(pooled.low, 0)

        // The 4-bar takes alone — the only group with enough points to fit — say nothing.
        let fourBarOnly: [Double] = [.nan, .nan, 12.5, 15.3, 11.4, 21.7, 19.6]
        let split = try XCTUnwrap(TrendAnalysis.row("clock SD", fourBarOnly,
                                                    lowerIsBetter: true).fit)
        XCTAssertEqual(split.verdict, .flat,
                       "so the verdict was the ladder, not the player")
        XCTAssertLessThan(split.low, 0)
    }
}
