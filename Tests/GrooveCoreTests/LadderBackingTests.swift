import XCTest
@testable import GrooveCore

/// M14 step 2: each rung's backing has to make its own division audible.
final class LadderBackingTests: XCTestCase {

    private let straightRungs = [1, 2, 4]

    /// The hat carries the division. A rung whose groove only marks beats is asking the player
    /// to subdivide from memory, which is a different and much harder task than the rung names.
    func testTheHatMarksEveryPointOfTheDivision() {
        for notesPerBeat in [1, 2, 3, 4] {
            let pattern = LadderBackings.pattern(notesPerBeat: notesPerBeat)
            let hats = pattern.hits.filter { $0.voice == .closedHat }.map(\.step).sorted()
            let expected = stride(from: 0, to: pattern.stepsPerBar,
                                  by: pattern.stepsPerBeat / notesPerBeat).map { $0 }

            XCTAssertEqual(hats, expected,
                           "\(notesPerBeat) per beat: the hat must land on every division point")
            XCTAssertEqual(hats.count, pattern.beatsPerBar * notesPerBeat)
        }
    }

    /// Only the density changes. If the kick or the backbeat moved between rungs, the ladder
    /// would be measuring the groove as well as the subdivision.
    func testTheSkeletonIsIdenticalAcrossEveryRung() {
        for notesPerBeat in [1, 2, 3, 4] {
            let pattern = LadderBackings.pattern(notesPerBeat: notesPerBeat)
            let perBeat = pattern.stepsPerBeat
            let kicks = pattern.hits.filter { $0.voice == .kick }.map { $0.step / perBeat }.sorted()
            let snares = pattern.hits.filter { $0.voice == .snare }.map { $0.step / perBeat }.sorted()

            XCTAssertEqual(kicks, [0, 2], "kick on 1 and 3 at \(notesPerBeat) per beat")
            XCTAssertEqual(snares, [1, 3], "backbeat on 2 and 4 at \(notesPerBeat) per beat")
        }
    }

    func testEveryBackingIsFourBeatsToTheBar() {
        for notesPerBeat in [1, 2, 3, 4] {
            XCTAssertEqual(LadderBackings.pattern(notesPerBeat: notesPerBeat).beatsPerBar, 4)
        }
    }

    /// Triplets are a different division, not a phase offset on the straight grid.
    func testTripletsUseTheirOwnStepResolution() {
        let triplets = LadderBackings.tripletEighths
        XCTAssertEqual(triplets.stepsPerBeat, 3)
        XCTAssertEqual(triplets.stepsPerBar, 12)
        for straight in straightRungs {
            XCTAssertNotEqual(LadderBackings.pattern(notesPerBeat: straight).stepsPerBar,
                              triplets.stepsPerBar,
                              "no shared step grid carries both — that is why they never mix")
        }
    }

    /// A fill adds to the groove rather than replacing it, and stays at the rung's resolution so
    /// it never contradicts the division it interrupts (§6.1).
    func testAFillKeepsThePulseAndTheResolution() {
        for notesPerBeat in [1, 2, 3, 4] {
            let groove = LadderBackings.pattern(notesPerBeat: notesPerBeat)
            let fill = LadderBackings.fill(notesPerBeat: notesPerBeat)

            XCTAssertEqual(fill.stepsPerBeat, groove.stepsPerBeat)
            XCTAssertEqual(fill.stepsPerBar, groove.stepsPerBar)
            XCTAssertFalse(fill.hits.filter { $0.voice == .tom }.isEmpty, "a fill has toms")
            XCTAssertFalse(fill.hits.filter { $0.step < groove.stepsPerBar / 2 }.isEmpty,
                           "the groove keeps running under the first half")
            XCTAssertTrue(fill.hits.allSatisfy { $0.voice != .crash },
                          "no crash in a fill bar — the crash belongs on the arrival")
        }
    }

    func testABackingLoopsWithLandmarksRatherThanRunningFlat() {
        for notesPerBeat in [1, 2, 3, 4] {
            let backing = LadderBackings.backing(notesPerBeat: notesPerBeat)
            XCTAssertEqual(backing.stepsPerBeat, notesPerBeat == 3 ? 3 : 4)
            XCTAssertEqual(backing.totalBars, 16)
            // A fill on the last bar of each eight, so the form is feelable without counting.
            XCTAssertNotEqual(backing.pattern(atBar: 7), backing.pattern(atBar: 6))
            XCTAssertEqual(backing.pattern(atBar: 6), backing.pattern(atBar: 0))
        }
    }

    /// The step grid is programming; this is what the player actually hears.
    ///
    /// Step indices are easy to get right and prove nothing on their own — the Sequencer turns
    /// them into samples at `60 / bpm / stepsPerBeat`, and a twelve-step bar at three per beat
    /// is exactly where that conversion could quietly produce a bar of the wrong length. So the
    /// assertion is in seconds: the gap between hats must be the rung's own interval, and a bar
    /// must last four beats however it is divided.
    func testTheHatsLandAtTheRungsIntervalInSeconds() {
        let bpm = 100.0, sampleRate = 44_100.0
        let beat = 60.0 / bpm

        for notesPerBeat in [1, 2, 3, 4] {
            let pattern = LadderBackings.pattern(notesPerBeat: notesPerBeat)
            let sequencer = Sequencer(bpm: bpm, sampleRate: sampleRate)
            let hits = sequencer.schedule(pattern: pattern, bar: 0)
                .filter { $0.voice == .closedHat }
                .map { Double($0.sample) / sampleRate }
                .sorted()

            let expectedGap = beat / Double(notesPerBeat)
            for (a, b) in zip(hits, hits.dropFirst()) {
                XCTAssertEqual(b - a, expectedGap, accuracy: 1e-9,
                               "\(notesPerBeat) per beat should space hats \(expectedGap)s apart")
            }
            XCTAssertEqual(hits.count, 4 * notesPerBeat, "four beats' worth")

            let barStart = Double(sequencer.barStartSample(bar: 1, pattern: pattern)) / sampleRate
            XCTAssertEqual(barStart, 4 * beat, accuracy: 1e-9,
                           "a bar is four beats at every rung, whatever its step count")
        }
    }

    /// An unrecognised rung falls back to what every take before the ladder played over, rather
    /// than to silence or a crash.
    func testAnUnknownSubdivisionFallsBackToEighths() {
        XCTAssertEqual(LadderBackings.pattern(notesPerBeat: 7), LadderBackings.eighths)
        XCTAssertEqual(LadderBackings.pattern(notesPerBeat: 0), LadderBackings.eighths)
    }

    /// The count-in is where a drill tells an eyes-shut player what it is asking for, so it has
    /// to carry the division rather than a generic pulse. Every jam counted in on the beat
    /// whatever the rung until M15 step 0b: a sixteenths take announced quarters, then switched.
    func testTheCountInCarriesTheRungsOwnDivision() {
        for notesPerBeat in [1, 2, 3, 4] {
            let countIn = LadderBackings.countIn(notesPerBeat: notesPerBeat)
            let hats = countIn.hits.filter { $0.voice == .closedHat }

            XCTAssertEqual(hats.count, 4 * notesPerBeat,
                           "\(notesPerBeat) per beat: the count-in must state the division")
            XCTAssertEqual(countIn.hits.count, hats.count,
                           "hats only — a count-in carrying the backbeat is just the groove")
            XCTAssertEqual(countIn.stepsPerBar,
                           LadderBackings.pattern(notesPerBeat: notesPerBeat).stepsPerBar,
                           "same bar length as what follows, or the take starts in the wrong place")
        }
    }

    /// Two rungs whose count-ins sounded alike would leave the boundary unmarked, which is the
    /// whole failure this fixes.
    func testEveryRungsCountInIsAudiblyDifferentFromTheOthers() {
        let lines = [1, 2, 3, 4].map { n in
            LadderBackings.countIn(notesPerBeat: n).hits.map(\.step).sorted()
        }
        for (i, a) in lines.enumerated() {
            for (j, b) in lines.enumerated() where i < j {
                XCTAssertNotEqual(a, b, "count-ins \(i + 1) and \(j + 1) per beat are identical")
            }
        }
    }

    /// The ladder must not have moved the backing every recorded take was played over.
    func testTheExistingJamBackingIsUntouched() {
        XCTAssertEqual(GrooveLibrary.jamBacking.stepsPerBeat, 4)
        XCTAssertEqual(GrooveLibrary.basicRock.hits.filter { $0.voice == .closedHat }.count, 8)
    }
}
