import XCTest
@testable import GrooveCore

final class DropoutDrillTests: XCTestCase {
    private let groove = GrooveLibrary.basicRock
    private let cycle = DropoutDrill.Cycle(pacedBars: 4, silentBars: 4)

    /// The analysis builds its section timeline from `isPaced`, while the audio comes from
    /// `pattern`. If those two ever disagree, the drill would measure "unpaced" playing that
    /// actually had a band under it — and the clock/motor split would be quietly meaningless.
    func testIsPacedAgreesWithWhatIsPlayed() {
        for bar in 0..<40 {
            let pattern = DropoutDrill.pattern(bar: bar, cycle: cycle, groove: groove)
            let paced = DropoutDrill.isPaced(bar: bar, cycle: cycle)
            XCTAssertEqual(paced, pattern != .silence,
                           "bar \(bar): isPaced says \(paced) but the pattern disagrees")
        }
    }

    func testCyclesAlternateCorrectly() {
        XCTAssertTrue(DropoutDrill.isPaced(bar: 0, cycle: cycle))
        XCTAssertTrue(DropoutDrill.isPaced(bar: 3, cycle: cycle))
        XCTAssertFalse(DropoutDrill.isPaced(bar: 4, cycle: cycle))
        XCTAssertFalse(DropoutDrill.isPaced(bar: 7, cycle: cycle))
        XCTAssertTrue(DropoutDrill.isPaced(bar: 8, cycle: cycle))   // next cycle
    }

    func testBandReturnsWithACrashButDoesNotStartWithOne() {
        func hasCrash(_ bar: Int) -> Bool {
            DropoutDrill.pattern(bar: bar, cycle: cycle, groove: groove)
                .hits.contains { $0.voice == .crash }
        }
        XCTAssertFalse(hasCrash(0), "the drill's opening bar is not a re-entry")
        XCTAssertTrue(hasCrash(8), "the band should slam back in after the first silence")
        XCTAssertTrue(hasCrash(16))
        XCTAssertFalse(hasCrash(9), "only the return bar is accented")
    }

    func testUnevenCycleLengths() {
        let long = DropoutDrill.Cycle(pacedBars: 2, silentBars: 8)
        XCTAssertTrue(DropoutDrill.isPaced(bar: 0, cycle: long))
        XCTAssertTrue(DropoutDrill.isPaced(bar: 1, cycle: long))
        XCTAssertFalse(DropoutDrill.isPaced(bar: 2, cycle: long))
        XCTAssertFalse(DropoutDrill.isPaced(bar: 9, cycle: long))
        XCTAssertTrue(DropoutDrill.isPaced(bar: 10, cycle: long))
    }

    func testDifficultySuggestionFollowsDrift() {
        // Comfortable — go longer.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 4, driftMsPerBeat: 0.5), 8)
        // Losing it — go shorter.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 8, driftMsPerBeat: -9.0), 4)
        // In between — hold.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 4, driftMsPerBeat: 3.0), 4)
        // Sign must not matter: drifting fast either way is still losing it.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 8, driftMsPerBeat: 9.0), 4)
        // Nothing measured — leave it alone.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 4, driftMsPerBeat: nil), 4)
        // Bounded.
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 16, driftMsPerBeat: 0.1), 16)
        XCTAssertEqual(DropoutDrill.suggestedSilentBars(current: 2, driftMsPerBeat: 20), 2)
    }
}
