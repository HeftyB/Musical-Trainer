import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// M15 step 5: a feel reaching the drills, and the two places it must not.
///
/// Every assertion here is reachable without an audio device. That is deliberate and it is the
/// §7.22 lesson: a test written as "assert the runner rejects this" once played a full
/// two-and-a-half-minute drill through the speakers, because the config it expected to be
/// refused was legal and the test fell through into the engine.
final class FeelWiringTests: XCTestCase {

    // MARK: Where a feel must not go

    /// **Swing and Wing–Kristofferson are incompatible, not merely awkward.** The decomposition
    /// assumes an isochronous series; swing makes the intervals alternate by design, and the
    /// isochrony gate passes them because 400 and 200 both sit inside 0.6–1.6× of their own
    /// median. The alternation then lands in the lag-1 autocovariance, which is where motor
    /// variance comes from. On a planted 12 ms clock and 8 ms motor, a swung series reports
    /// motor 99.7 ms and a *negative* clock variance.
    func testTheContinuationDrillRefusesASwingRatherThanReportingRubbish() {
        var config = TrainerEngine.DropoutConfig(bpm: 100, pacedBars: 4, silentBars: 4, cycles: 6)
        config.feel = .swung

        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertTrue("\(error)".contains("isochronous"), "\(error)")
        }
    }

    func testTheContinuationDrillIsHappyStraight() throws {
        var config = TrainerEngine.DropoutConfig(bpm: 100, pacedBars: 4, silentBars: 4, cycles: 6)
        config.feel = .straight
        XCTAssertNoThrow(try config.validate())
    }

    /// A swung take has no single interval — at 2:1 the notes alternate 400 and 200 ms — so it
    /// cannot sit on an axis whose unit is "the interval". Putting it there would repeat §7.23
    /// step 3's mistake, where a grid the take was *scored* on stood in for the task it performed.
    func testSwungTakesAreExcludedFromTheIntervalAxis() throws {
        let straight = TakeFactory.jam(rung: .eighths)
        let swung = TakeFactory.jam(rung: .eighths, feel: .swung)

        XCTAssertTrue(straight.feel.isStraight)
        XCTAssertFalse(swung.feel.isStraight)
        // `intervalObservations` filters on exactly this, so the property it filters on has to
        // survive storage.
        XCTAssertEqual(swung.swingRatio, 2)
        XCTAssertNil(straight.swingRatio, "straight writes nothing")
    }

    // MARK: Argument parsing, before any device is opened

    func testASwingNeedsARungToSwing() {
        XCTAssertThrowsError(try Commands.parseFeel("2", rung: nil)) { error in
            XCTAssertTrue("\(error)".contains("needs a rung"), "\(error)")
        }
    }

    /// Triplets are the division swing borrows from, so there is no pair to swing.
    func testATripletRungRefusesASwing() {
        XCTAssertThrowsError(try Commands.parseFeel("2", rung: .tripletEighths)) { error in
            XCTAssertTrue("\(error)".contains("binary pair"), "\(error)")
        }
    }

    func testAnUnplayableRatioIsRefused() {
        for raw in ["0.5", "9", "banana", "-2"] {
            XCTAssertThrowsError(try Commands.parseFeel(raw, rung: .eighths), raw)
        }
    }

    func testNoSwingArgumentIsStraightRatherThanAnError() throws {
        XCTAssertEqual(try Commands.parseFeel(nil, rung: .eighths), .straight)
        XCTAssertEqual(try Commands.parseFeel(nil, rung: nil), .straight)
    }

    func testAValidRatioParses() throws {
        XCTAssertEqual(try Commands.parseFeel("1.5", rung: .eighths).swingRatio, 1.5)
        XCTAssertEqual(try Commands.parseFeel("2", rung: .sixteenths), .swung)
    }

    // MARK: Instructions (R3.6)

    /// The straight text tells the player to aim at a beat or an off-beat and warns against
    /// playing between them — which is exactly what a swung offbeat does. Handing a swung take
    /// that text would tell the player their own task is a mistake.
    func testASwungRungGetsItsOwnTextRatherThanTheStraightOne() {
        let straight = DrillInstructions.jam(rung: .eighths)
        let swung = DrillInstructions.jam(rung: .eighths, feel: .swung)

        XCTAssertNotEqual(straight.steps, swung.steps)
        XCTAssertTrue(swung.steps.contains { $0.contains("swing") || $0.contains("swung") },
                      "\(swung.steps)")
        XCTAssertTrue(swung.pitfalls.contains { $0.contains("straighten up") }, "\(swung.pitfalls)")
    }

    /// A feel that cannot apply must not change the text either, or the player is told to swing
    /// a division that will be scored straight.
    func testATripletRungKeepsTheStraightTextEvenIfHandedAFeel() {
        XCTAssertEqual(DrillInstructions.jam(rung: .tripletEighths, feel: .swung).steps,
                       DrillInstructions.jam(rung: .tripletEighths).steps)
    }

    /// Both surfaces go through `forBlock`, so the feel has to arrive by that route.
    func testAPlannedBlockCarriesTheFeelIntoItsInstructions() {
        let block = SessionBlock(role: .training,
                                 plan: .jam(JamPlan(bpm: 100, bars: 32, tag: "ladder",
                                                    rung: .eighths, feel: .swung)),
                                 reason: "the ladder slot")
        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.jam(rung: .eighths, feel: .swung).steps)
    }

    // MARK: The planner does not schedule a feel yet

    /// **A feel nobody has heard is a feel the planner must not promote onto.** §7.23 made that a
    /// rule for rungs and it applies at least as strongly here: whether 1.5:1 reads as a shuffle
    /// or as a mistake is not something a step list can answer. Swing is hand-selected until a
    /// swung take exists in the history, at which point the same one-step promotion argument
    /// that governs rungs can govern feels too.
    func testThePlannerSchedulesNothingSwungUntilOneHasBeenPlayed() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
            for block in plan.blocks {
                if case .jam(let p) = block.plan {
                    XCTAssertTrue(p.feel.isStraight,
                                  "\(minutes) min: \(block.role) was scheduled swung")
                }
            }
        }
    }

    /// And the plan preview names a feel when one is set, so it can never run unannounced.
    func testThePreviewNamesTheFeel() {
        let swung = BlockPlan.jam(JamPlan(bpm: 100, bars: 32, tag: nil,
                                          rung: .eighths, feel: .swung))
        XCTAssertTrue(swung.settingsLabel.contains("swung"), swung.settingsLabel)

        let straight = BlockPlan.jam(JamPlan(bpm: 100, bars: 64, tag: "benchmark"))
        XCTAssertEqual(straight.settingsLabel, "100 BPM · 64 bars", "unchanged for the benchmark")
    }
}
