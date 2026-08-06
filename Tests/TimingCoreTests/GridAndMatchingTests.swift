import XCTest
@testable import TimingCore

final class GridTests: XCTestCase {
    func testIndexTimeRoundTrip() {
        let grid = Grid(startTime: 1.0, bpm: 120, subdivisions: 1)   // 0.5 s per beat
        XCTAssertEqual(grid.gap(around: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(grid.time(ofIndex: 4), 3.0, accuracy: 1e-12)
        XCTAssertEqual(grid.nearestIndex(to: 3.02), 4)
        XCTAssertEqual(grid.nearestIndex(to: 2.74), 3)
    }

    func testPhaseHandlesNegativeIndices() {
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 4)
        XCTAssertEqual(grid.phase(ofIndex: 0), 0)
        XCTAssertEqual(grid.phase(ofIndex: 5), 1)
        XCTAssertEqual(grid.phase(ofIndex: -1), 3)   // floored modulo, not -1
        XCTAssertEqual(grid.phase(ofIndex: -4), 0)
    }
}

final class MatchingTests: XCTestCase {
    private let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)   // 0.5 s beats

    func testCleanTapsMatchWithCorrectSign() {
        // Every tap 10 ms early → asynchrony −10 ms (rushing).
        let taps = (0..<8).map { Tap(time: grid.time(ofIndex: $0) - 0.010) }
        let result = Matching.match(taps: taps, to: grid)
        XCTAssertEqual(result.matched.count, 8)
        XCTAssertTrue(result.extraTaps.isEmpty)
        for m in result.matched {
            XCTAssertEqual(m.asynchronyMs, -10, accuracy: 1e-9)
        }
    }

    func testSignInversionTrapIsAvoided() {
        // A note 45% of a beat late must NOT snap forward and report as ~55% early.
        // Window is ±40% of the interval, so it falls in the dead zone → extra.
        let late = Tap(time: grid.time(ofIndex: 0) + 0.45 * grid.gap(around: 0))
        let result = Matching.match(taps: [late], to: grid)
        XCTAssertTrue(result.matched.isEmpty, "a 45%-late note should not be matched at all")
        XCTAssertEqual(result.extraTaps.count, 1)
    }

    func testNoteWithinWindowStillMatches() {
        // 30% late is inside the window and should match its own grid point, late.
        let tap = Tap(time: grid.time(ofIndex: 2) + 0.30 * grid.gap(around: 0))
        let result = Matching.match(taps: [tap], to: grid)
        XCTAssertEqual(result.matched.count, 1)
        XCTAssertEqual(result.matched[0].gridIndex, 2)
        XCTAssertGreaterThan(result.matched[0].asynchronyMs, 0)
    }

    func testDoubleTriggerKeepsClosestAsExtra() {
        let onTime = Tap(time: grid.time(ofIndex: 3) + 0.005)
        let bounce = Tap(time: grid.time(ofIndex: 3) + 0.030)
        let result = Matching.match(taps: [onTime, bounce], to: grid)
        XCTAssertEqual(result.matched.count, 1)
        XCTAssertEqual(result.matched[0].asynchronyMs, 5, accuracy: 1e-9)   // the closer one
        XCTAssertEqual(result.extraTaps.count, 1)
    }

    func testMissedNoteIsReported() {
        // Play beats 0,1,3,4 — beat 2 is dropped.
        let taps = [0, 1, 3, 4].map { Tap(time: grid.time(ofIndex: $0)) }
        let result = Matching.match(taps: taps, to: grid)
        XCTAssertEqual(result.matched.count, 4)
        XCTAssertEqual(result.missedIndices, [2])
    }

    func testTapBetweenBeatsIsExtraNotMissed() {
        let taps = [Tap(time: grid.time(ofIndex: 0)),
                    Tap(time: grid.time(ofIndex: 0) + 0.25),   // dead centre between beats
                    Tap(time: grid.time(ofIndex: 1))]
        let result = Matching.match(taps: taps, to: grid)
        XCTAssertEqual(result.matched.count, 2)
        XCTAssertEqual(result.extraTaps.count, 1)
        XCTAssertTrue(result.missedIndices.isEmpty)
    }
}
