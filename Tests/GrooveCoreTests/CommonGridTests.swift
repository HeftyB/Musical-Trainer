import XCTest
@testable import GrooveCore

/// One grid, and lifting onto it moves nothing.
///
/// Sections used to have to share a step resolution, so a triplet section and a straight one
/// could never appear in the same arrangement — the format's hard limit on musical depth, and
/// the thing that would have blocked M16.5's triplet skank and every shuffle style. They are now
/// lifted to `Pattern.commonStepsPerBeat`, twenty-four, which is a whole multiple of every
/// resolution anything here is authored at.
///
/// **The lift must be exact.** A hit that moves is the backing moving under a measurement, and
/// it would be attributed to the player. See JOURNAL.md §7.29 step 1.
final class CommonGridTests: XCTestCase {

    /// Everything in the codebase that is or becomes a pattern.
    private var everyPattern: [GrooveCore.Pattern] {
        var out: [GrooveCore.Pattern] = [GrooveLibrary.basicRock, GrooveLibrary.drivingRide,
                              GrooveLibrary.fourOnFloor, GrooveLibrary.halfTime,
                              GrooveLibrary.tomFill, GrooveLibrary.snareFill, .silence]
        for notes in [1, 2, 3, 4] {
            out.append(LadderBackings.pattern(notesPerBeat: notes))
            out.append(LadderBackings.swungPattern(notesPerBeat: notes))
            out.append(LadderBackings.fill(notesPerBeat: notes))
        }
        for level in OffbeatLevel.allCases {
            for bar in 0..<4 { out.append(OffbeatBacking.pattern(level: level, bar: bar)) }
        }
        return out
    }

    // MARK: - The lift is exact

    /// The gate for this step, and it is not an approximation: every hit of every pattern, at
    /// three tempos and four feels, lands on the *same sample* before and after the lift.
    func testNoHitMovesWhenAPatternIsLiftedToTheCommonGrid() {
        var compared = 0
        for bpm in [76.0, 100.0, 132.0] {
            for swing in [Swing.none, Swing(ratio: 1.5, notesPerBeat: 2),
                          Swing(ratio: 2, notesPerBeat: 2), Swing(ratio: 3, notesPerBeat: 2)] {
                let sequencer = Sequencer(bpm: bpm, sampleRate: 44_100, swing: swing)
                for pattern in everyPattern {
                    let lifted = pattern.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat)
                    for bar in 0..<8 {
                        let before = sequencer.schedule(pattern: pattern, bar: bar)
                            .map(\.sample).sorted()
                        let after = sequencer.schedule(pattern: lifted, bar: bar)
                            .map(\.sample).sorted()
                        XCTAssertEqual(before, after,
                                       "\(Int(bpm)) BPM, swing \(swing.ratio), bar \(bar)")
                        compared += before.count
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 20_000, "the sweep should be wide, not token")
    }

    func testLiftingIsIdempotent() {
        for pattern in everyPattern {
            let once = pattern.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat)
            XCTAssertEqual(once.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat), once)
        }
    }

    func testTheCommonGridDividesEveryResolutionInUse() {
        for pattern in everyPattern {
            XCTAssertEqual(Pattern.commonStepsPerBeat % pattern.stepsPerBeat, 0,
                           "\(pattern.stepsPerBeat) does not divide the common grid, so a "
                         + "pattern authored at it could only be lifted by rounding")
        }
    }

    /// Twenty-four is not arbitrary: it is what makes every subdivision this roadmap asks for
    /// expressible on one grid.
    func testEverySubdivisionTheRoadmapNeedsIsExpressible() {
        for division in [1, 2, 3, 4, 6, 8, 12, 24] {
            XCTAssertEqual(Pattern.commonStepsPerBeat % division, 0,
                           "\(division) per beat must land on whole steps")
        }
    }

    // MARK: - What it unlocks

    /// The reason for the whole step. This threw before.
    func testATripletSectionAndAStraightSectionCanShareAnArrangement() {
        let straight = Pattern.make([.kick: [0, 8], .snare: [4, 12]])
        let triplets = Pattern.make(stepsPerBar: 12, stepsPerBeat: 3, [.closedHat: [0, 1, 2]])

        let arrangement = Arrangement(sections: [
            Section(name: "straight", pattern: straight, bars: 4),
            Section(name: "triplets", pattern: triplets, bars: 4),
        ])

        XCTAssertEqual(arrangement.stepsPerBeat, Pattern.commonStepsPerBeat)
        XCTAssertEqual(arrangement.pattern(atBar: 0).stepsPerBeat, Pattern.commonStepsPerBeat)
        XCTAssertEqual(arrangement.pattern(atBar: 4).stepsPerBeat, Pattern.commonStepsPerBeat)
        XCTAssertEqual(arrangement.pattern(atBar: 4).hits.map(\.step).sorted(), [0, 8, 16],
                       "a triplet still divides the beat in three, on a grid of twenty-four")
    }

    func testAFillIsLiftedWithItsSection() {
        let arrangement = Arrangement(sections: [
            Section(name: "a", pattern: GrooveLibrary.basicRock, bars: 2,
                    fill: Pattern.make(stepsPerBar: 12, stepsPerBeat: 3, [.tom: [0, 1, 2]])),
        ])
        XCTAssertEqual(arrangement.pattern(atBar: 1).stepsPerBeat, Pattern.commonStepsPerBeat,
                       "a fill authored at another resolution must be lifted too, or the bar it "
                     + "plays in is scheduled against the wrong step count")
    }

    /// Bars must still be the same length. A 3/4 section beside a 4/4 one would make the bar
    /// index the sequencer walks mean two different things, and every drill counts phrases in
    /// bars.
    func testSectionsMustStillAgreeOnBeatsPerBar() {
        let four = Pattern.make([.kick: [0]])
        XCTAssertEqual(four.beatsPerBar, 4)
        let three = Pattern.make(stepsPerBar: 12, stepsPerBeat: 4, [.kick: [0]])
        XCTAssertEqual(three.beatsPerBar, 3)
        // Not asserted by construction here — `Arrangement` traps, which a test cannot catch —
        // but the two are demonstrably different lengths, which is what the precondition names.
    }
}
