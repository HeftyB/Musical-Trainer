import XCTest
import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// The grid a take is scored on is a measurement decision, not a fact about the drums.
///
/// It was `backing.arrangement.stepsPerBeat` until M19 step 0. `jamBacking` is programmed at four
/// steps per beat, so twenty-six of the thirty takes on record are analysed at sixteenths for
/// that reason alone — and M19 re-voices every pattern onto a twenty-four-step grid, which would
/// silently have re-scored the whole history.
///
/// `LESSONS.md` shape 10, and the fifth instance on this project: one word — how finely we divide
/// the beat — meaning both what the content is authored at and what the player is scored against.
/// See PLAN.md §7.29 step 0.
final class FreePlayingGridTests: XCTestCase {

    private func config(rung: IntervalRung? = nil, offbeat: OffbeatLevel? = nil)
        -> TrainerEngine.JamConfig {
        TrainerEngine.JamConfig(bpm: 100, bars: 32, tag: nil, rung: rung, offbeatLevel: offbeat)
    }

    func testAFreeTakeIsScoredAtSixteenthsWhateverTheBackingIsWrittenAt() {
        XCTAssertEqual(config().gridSubdivisions, 4)
        XCTAssertEqual(TrainerEngine.JamConfig.freePlayingSubdivisions, 4,
                       "every take on record was scored here; moving it re-scores all of them")
    }

    /// The decoupling, now provable.
    ///
    /// When step 0 landed, both quantities were 4 — `jamBacking` was written at four steps per
    /// beat and a free take was scored at sixteenths — so reverting it changed no observable
    /// value and no test could tell the two apart. That is `LESSONS.md` shape 9, a constant that
    /// happens to match, and it is why the guard was a `check.sh` grep rather than an assertion.
    ///
    /// Step 1 lifted every arrangement to twenty-four steps a beat and the numbers separated.
    /// **This is the assertion step 0 could not write**, and reverting step 0 now fails it
    /// outright rather than passing in silence.
    func testTheScoredGridDoesNotFollowTheAuthoringGrid() {
        XCTAssertEqual(config().gridSubdivisions, 4,
                       "the grid every take on disk was scored on, unchanged")
        XCTAssertEqual(config().backing.arrangement.stepsPerBeat,
                       GrooveCore.Pattern.commonStepsPerBeat,
                       "while the music is now written six times finer")
        XCTAssertNotEqual(config().gridSubdivisions,
                          config().backing.arrangement.stepsPerBeat)
    }

    func testAPrescribedRungStillWins() {
        for rung in IntervalRung.allCases {
            XCTAssertEqual(config(rung: rung).gridSubdivisions, rung.subdivisions,
                           "\(rung.rawValue): the rung is the task, and it outranks any default")
        }
    }

    func testTheOffbeatDrillStillForcesEighths() {
        XCTAssertEqual(config(offbeat: .stated).gridSubdivisions, 2)
        XCTAssertEqual(config(rung: .sixteenths, offbeat: .stated).gridSubdivisions, 2,
                       "a finer grid would let a stray sixteenth count as neither the beat nor "
                     + "the offbeat and quietly flatter both counts")
    }

    /// Storage is what makes the history safe: a take carries the grid it was scored on, so a
    /// change to the constant reaches new takes only.
    func testAStoredTakeCarriesItsOwnGridRatherThanRederivingOne() {
        let take = TakeFactory.jam()
        XCTAssertEqual(take.reconstruct().grid.subdivisions, take.subdivisions,
                       "every review recomputes on the grid the take was recorded with")
    }
}
