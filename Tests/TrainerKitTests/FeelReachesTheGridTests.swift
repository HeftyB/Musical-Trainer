import XCTest
@testable import TimingCore
import TestSupport
@testable import TrainerKit

/// **The feel has to reach the grid the app actually scores against.**
///
/// M15 shipped with a full set of tests proving that a swung grid places notes correctly, that a
/// swung player on one scores as perfect, and that the same player on a straight grid reads as
/// badly dragging. Every one of them built its grid *in the test*. Neither place that builds a
/// grid in the running app — `JamAnalysis.reduce` for a live take, `SessionStore.reconstruct` for
/// a review — passed the feel along, so both swung takes ever recorded were scored straight.
///
/// It did not fail. It reported:
///
/// | | scored straight | scored swung |
/// |---|---|---|
/// | mean | +22.3 ms dragging | −16.6 ms rushing |
/// | spread | 54.0 ms | 28.7 ms |
/// | r₁ | −0.52 "chasing the click" | +0.49 drifting |
///
/// That r₁ would have been the **first negative in the project's history**, directly
/// contradicting §5.1's founding claim, from a player who has been +0.13 to +0.47 across 27
/// takes. `LESSONS.md` shape 1 — the path under test is not the path that ships — costing a
/// finding rather than a build.
final class FeelReachesTheGridTests: StoreBackedTestCase {

    /// A stored take must recompute on the grid it was played against, feel included.
    func testAStoredSwungTakeIsRecomputedOnASwungGrid() throws {
        for ratio in [1.5, 2.0, 3.0] {
            guard let feel = Feel(swingRatio: ratio) else { return XCTFail("\(ratio)") }
            let stored = TakeFactory.jam(rung: .eighths, feel: feel)

            XCTAssertEqual(stored.reconstruct().grid.feel, feel,
                           "ratio \(ratio) did not survive into the grid")
            XCTAssertEqual(stored.report().matched.isEmpty, false)
        }
    }

    func testAStoredStraightTakeStillReconstructsStraight() {
        XCTAssertEqual(TakeFactory.jam(rung: .eighths).reconstruct().grid.feel, .straight)
        XCTAssertEqual(TakeFactory.jam().reconstruct().grid.feel, .straight)
    }

    /// The number the defect actually produced. A player placing notes exactly where a 2:1 feel
    /// asks must score as perfect when the feel reaches the grid — and as a large, plausible,
    /// entirely wrong drag when it does not.
    func testTheDefectsSignatureIsReproducedAndFixed() {
        let swung = Grid(startTime: 0, bpm: 100, subdivisions: 2, feel: .swung)
        let taps = (0..<256).map { Tap(time: swung.time(ofIndex: $0)) }

        let correct = TimingAnalysis.analyze(taps: taps, grid: swung, chordWindowMs: 0)
        XCTAssertEqual(correct.sdAsynchronyMs, 0, accuracy: 1e-6)
        XCTAssertEqual(correct.meanAsynchronyMs, 0, accuracy: 1e-6)

        let asShipped = Grid(startTime: 0, bpm: 100, subdivisions: 2)
        let wrong = TimingAnalysis.analyze(taps: taps, grid: asShipped, chordWindowMs: 0)
        XCTAssertEqual(wrong.meanAsynchronyMs, 50, accuracy: 1,
                       "the drag a perfectly swung player reads as on a straight grid")
        XCTAssertEqual(wrong.sdAsynchronyMs, 50, accuracy: 1)
        XCTAssertEqual(wrong.extraCount, 0, "and nothing is flagged, which is why it is invisible")
    }

    /// The live path. `runJam` needs a device, so the assertion is on the config property it
    /// hands to the analysis — the same reason `countInBar` and `gridSubdivisions` live there.
    func testTheConfigCarriesItsFeelToWhateverBuildsTheGrid() {
        guard let feel = Feel(swingRatio: 1.5) else { return XCTFail("1.5 is valid") }
        let config = TrainerEngine.JamConfig(bpm: 100, rung: .eighths, feel: feel)

        XCTAssertEqual(config.feel, feel)
        XCTAssertEqual(config.swing.ratio, 1.5, "the band's half")
        // And the grid the analysis will build from those two.
        let grid = Grid(startTime: 0, bpm: config.bpm,
                        subdivisions: config.gridSubdivisions, feel: config.feel)
        XCTAssertEqual(grid.feel, feel, "the grid's half")
        XCTAssertEqual(grid.time(ofIndex: 1), 0.6 * feel.offbeatPhase, accuracy: 1e-9)
    }

    /// `JamAnalysis.reduce` is where a live take's grid is born. It defaults to straight, which
    /// is right for every take before M15 and wrong the moment a caller forgets.
    func testTheReductionBuildsTheGridWithTheFeelItIsGiven() throws {
        let epoch = HostClock.now()
        let map = stride(from: 0.0, through: 8.0, by: 0.01).map { t in
            (hostTime: epoch &+ HostClock.ticks(seconds: t), sample: Int64(t * 44_100))
        }
        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: map, midi: [],
            grooveStartSample: Int64(2.0 * 44_100), grooveEndSample: Int64(6.0 * 44_100),
            bpm: 100, subdivisions: 2, feel: .swung, calibrationConstantMs: 0))

        XCTAssertEqual(reduced.grid.feel, .swung)
        XCTAssertEqual(reduced.grid.subdivisions, 2)
    }
}
