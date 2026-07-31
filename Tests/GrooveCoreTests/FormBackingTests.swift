import XCTest
@testable import GrooveCore

/// Locks in the layout fix. The first build of the form drill put a crash on the downbeat of
/// the *fill* bar — one bar before the downbeat the player was asked to mark — and let the
/// fill replace the groove, leaving a half-bar of silence. Players marked the crash, so the
/// drill measured reaction to a misleading cue instead of form sense.
final class FormBackingTests: XCTestCase {
    private let groove = GrooveLibrary.basicRock
    private let phraseBars = 8

    private func pattern(_ bar: Int, _ level: FormLevel) -> GrooveCore.Pattern {
        FormBacking.pattern(bar: bar, phraseBars: phraseBars, level: level, groove: groove)
    }

    private func hasCrash(_ bar: Int, _ level: FormLevel) -> Bool {
        pattern(bar, level).hits.contains { $0.voice == .crash }
    }

    /// The single most important invariant in the drill.
    func testCrashLandsOnlyOnPhraseDownbeats() {
        for bar in 0..<32 {
            let isPhraseTop = bar % phraseBars == 0
            XCTAssertEqual(hasCrash(bar, .fillAndAccent), isPhraseTop,
                           "bar \(bar): crash must appear on phrase tops only")
        }
    }

    func testFillBarNeverCarriesACrash() {
        for level in FormLevel.allCases {
            XCTAssertFalse(hasCrash(phraseBars - 1, level),
                           "\(level): the bar before the turn must not be accented")
        }
    }

    func testPulseSurvivesTheTurnWhenTheBandIsPlaying() {
        // Every bar around the boundary must carry a pulse voice, except at the level whose
        // whole purpose is removing the band.
        for level in FormLevel.allCases where level != .dropoutAcross {
            for bar in [phraseBars - 2, phraseBars - 1, phraseBars, phraseBars + 1] {
                let hits = pattern(bar, level).hits
                XCTAssertTrue(hits.contains { $0.voice == .closedHat || $0.voice == .kick },
                              "\(level) bar \(bar): the pulse must not stop through the turn")
            }
        }
    }

    func testLevelsRemoveLandmarksProgressively() {
        XCTAssertTrue(hasCrash(0, .fillAndAccent))
        XCTAssertFalse(hasCrash(0, .fillOnly))          // no arrival confirmation

        XCTAssertEqual(pattern(phraseBars - 1, .fillOnly), GrooveLibrary.snareFill)
        XCTAssertEqual(pattern(phraseBars - 1, .noFills), groove)   // no warning either
    }

    func testDropoutSilencesTheBoundaryOnly() {
        // Silent for the last two bars of a phrase and the first two of the next.
        XCTAssertEqual(pattern(phraseBars - 2, .dropoutAcross), .silence)
        XCTAssertEqual(pattern(phraseBars - 1, .dropoutAcross), .silence)
        XCTAssertEqual(pattern(phraseBars, .dropoutAcross), .silence)
        XCTAssertEqual(pattern(phraseBars + 1, .dropoutAcross), .silence)
        XCTAssertEqual(pattern(phraseBars + 2, .dropoutAcross), groove)   // band returns
    }

    func testArrivalAccentFlagMatchesTheAudio() {
        for level in FormLevel.allCases {
            XCTAssertEqual(level.hasArrivalAccent, hasCrash(0, level),
                           "\(level): hasArrivalAccent must match whether a crash is actually played")
        }
    }
}
