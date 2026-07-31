import XCTest
@testable import GrooveCore

/// Regression tests for a real defect: the fills used to *replace* the groove and carry a
/// crash on their own downbeat. That left a half-bar hole in the pulse and put the loudest
/// event in the drill exactly one bar before the downbeat the player was asked to mark, which
/// made a form drill measure the wrong thing entirely.
final class FillTests: XCTestCase {
    /// Named so a failure says which fill broke. `Pattern` must be module-qualified: the
    /// name is ambiguous against another `Pattern` visible through XCTest.
    private var fills: [String: GrooveCore.Pattern] {
        ["snareFill": GrooveLibrary.snareFill, "tomFill": GrooveLibrary.tomFill]
    }

    func testFillsKeepThePulseGoing() {
        for (name, fill) in fills {
            let hasPulse = fill.hits.contains { $0.voice == .closedHat || $0.voice == .kick }
            XCTAssertTrue(hasPulse, "\(name) must keep a pulse voice under the fill")

            // No silent gap longer than a beat, or the player loses the beat through the turn.
            let steps = Set(fill.hits.map(\.step)).sorted()
            var previous = 0
            for step in steps {
                XCTAssertLessThanOrEqual(step - previous, fill.stepsPerBeat,
                                         "\(name) has a gap longer than a beat before step \(step)")
                previous = step
            }
        }
    }

    func testFillsCarryNoCrash() {
        for (name, fill) in fills {
            XCTAssertFalse(fill.hits.contains { $0.voice == .crash },
                           "\(name) must not contain a crash — it would be a landmark one bar early")
        }
    }

    func testAccentPutsCrashOnTheDownbeat() {
        let accented = GrooveLibrary.accented(GrooveLibrary.basicRock)
        let crashes = accented.hits.filter { $0.voice == .crash }
        XCTAssertEqual(crashes.count, 1)
        XCTAssertEqual(crashes.first?.step, 0, "the arrival accent belongs on the downbeat")
        // The groove underneath is untouched.
        XCTAssertEqual(accented.hits.count, GrooveLibrary.basicRock.hits.count + 1)
    }

    func testAddingPreservesGrid() {
        let p = GrooveLibrary.basicRock.adding([Hit(voice: .crash, step: 0)])
        XCTAssertEqual(p.stepsPerBar, GrooveLibrary.basicRock.stepsPerBar)
        XCTAssertEqual(p.stepsPerBeat, GrooveLibrary.basicRock.stepsPerBeat)
    }
}
