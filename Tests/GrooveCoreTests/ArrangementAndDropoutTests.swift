import XCTest
@testable import GrooveCore

final class ArrangementTests: XCTestCase {
    private let a = Pattern.make([.kick: [0]])
    private let b = Pattern.make([.snare: [0]])
    private let fill = Pattern.make([.crash: [0]])

    /// An arrangement lifts its sections to `Pattern.commonStepsPerBeat` so a triplet section
    /// and a straight one can sit in one piece of music (§7.29 step 1), so what comes back out
    /// is the same music on a finer grid rather than the literal that went in. Comparing
    /// against the lift is what keeps these tests about *ordering*, which is what they are for.
    private func lifted(_ pattern: GrooveCore.Pattern) -> GrooveCore.Pattern {
        pattern.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat)
    }

    func testResolvesSectionsInOrder() {
        let arr = Arrangement(sections: [
            Section(name: "A", pattern: a, bars: 4),
            Section(name: "B", pattern: b, bars: 4),
        ], loop: false)

        XCTAssertEqual(arr.pattern(atBar: 0), lifted(a))
        XCTAssertEqual(arr.pattern(atBar: 3), lifted(a))
        XCTAssertEqual(arr.pattern(atBar: 4), lifted(b))
        XCTAssertEqual(arr.pattern(atBar: 7), lifted(b))
        XCTAssertEqual(arr.totalBars, 8)
    }

    func testFillReplacesLastBarOfSection() {
        let arr = Arrangement(sections: [
            Section(name: "A", pattern: a, bars: 4, fill: fill),
        ], loop: false)
        XCTAssertEqual(arr.pattern(atBar: 2), lifted(a))
        XCTAssertEqual(arr.pattern(atBar: 3), lifted(fill))   // last bar
    }

    func testLoopingWrapsAround() {
        let arr = Arrangement(sections: [Section(name: "A", pattern: a, bars: 4)], loop: true)
        XCTAssertEqual(arr.pattern(atBar: 5), lifted(a))      // 5 % 4 == 1
        XCTAssertEqual(arr.pattern(atBar: 400), lifted(a))
    }

    func testNonLoopingGoesSilentPastEnd() {
        let arr = Arrangement(sections: [Section(name: "A", pattern: a, bars: 4)], loop: false)
        XCTAssertEqual(arr.pattern(atBar: 10), .silence,
                       "silence is returned unlifted, and has no hits to move either way")
    }
}

final class DropoutTests: XCTestCase {
    private let groove = GrooveLibrary.basicRock   // 16 steps, 4 per beat

    private func steps(_ level: DropoutLevel, bar: Int = 0) -> Set<Int> {
        Set(DropoutLadder.pattern(level: level, bar: bar, groove: groove).hits.map(\.step))
    }

    func testFullKitIsTheGrooveUntouched() {
        XCTAssertEqual(DropoutLadder.pattern(level: .fullKit, bar: 0, groove: groove), groove)
    }

    func testLadderThinsProgressively() {
        // Beats begin at steps 0,4,8,12 on this grid.
        XCTAssertEqual(steps(.hatsEveryBeat), [0, 4, 8, 12])
        XCTAssertEqual(steps(.backbeat), [4, 12])          // beats 2 and 4
        XCTAssertEqual(steps(.beatFourOnly), [12])         // beat 4
        XCTAssertEqual(steps(.silence), [])
    }

    func testDownbeatSparseAlternatesByBar() {
        XCTAssertEqual(steps(.downbeatSparse, bar: 0), [0])   // even bar: downbeat
        XCTAssertEqual(steps(.downbeatSparse, bar: 1), [])    // odd bar: silent
        XCTAssertEqual(steps(.downbeatSparse, bar: 2), [0])
    }

    func testLevelsAreOrdered() {
        XCTAssertLessThan(DropoutLevel.fullKit, DropoutLevel.silence)
        XCTAssertEqual(DropoutLevel.allCases.count, 6)
    }
}
