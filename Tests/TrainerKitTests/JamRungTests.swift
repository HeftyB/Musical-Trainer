import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// M14 step 4b: a jam can be asked for a subdivision, and is then scored against it.
///
/// The whole step turns on one distinction that this codebase has got wrong three times: the
/// **rung** is how finely the player is asked to divide the beat, and the **pattern's step
/// resolution** is how finely the drums are programmed. `LadderBackings` returns a pattern whose
/// `stepsPerBeat` is 4 for quarters, eighths *and* sixteenths, so deriving the analysis grid
/// from the backing — which is what `runJam` did until this step — would score three different
/// rungs identically and a quarters take four times finer than the task it set.
final class JamRungTests: XCTestCase {

    // MARK: - The grid comes from the rung, never from the backing

    func testTheAnalysisGridIsTheRungAndNotTheBackingsStepResolution() {
        let expected: [IntervalRung: Int] = [
            .quarters: 1, .eighths: 2, .tripletEighths: 3, .sixteenths: 4,
        ]
        for (rung, subdivisions) in expected {
            let config = TrainerEngine.JamConfig(bpm: 100, bars: 32, tag: nil, rung: rung)
            XCTAssertEqual(config.gridSubdivisions, subdivisions, "\(rung.label)")
        }
    }

    /// The trap stated as a number. Three of the four ladder backings are programmed on the same
    /// sixteenth step grid, so the backing cannot tell the rungs apart.
    func testThreeRungsShareAStepResolutionAndAreStillScoredDifferently() {
        let straight: [IntervalRung] = [.quarters, .eighths, .sixteenths]
        let resolutions = straight.map { rung in
            TrainerEngine.JamConfig(rung: rung).backing.arrangement.stepsPerBeat
        }
        XCTAssertEqual(resolutions, [4, 4, 4], "all three are programmed on sixteenth steps")

        let grids = straight.map { TrainerEngine.JamConfig(rung: $0).gridSubdivisions }
        XCTAssertEqual(grids, [1, 2, 4], "but each is scored against its own rung")
    }

    /// A quarters rung on the backing's resolution would score against a 150 ms grid at 100 BPM,
    /// which is a task nobody was set — and it is the interval step 1's ceilings are derived on.
    func testAQuartersRungIsNotScoredOnASixteenthGrid() {
        let config = TrainerEngine.JamConfig(bpm: 100, rung: .quarters)
        let grid = Grid(startTime: 0, bpm: config.bpm, subdivisions: config.gridSubdivisions)
        XCTAssertEqual(grid.interval, 0.6, accuracy: 1e-9, "a beat, not a sixteenth")
    }

    // MARK: - Free playing is untouched

    /// The benchmark and both experiment blocks carry no rung and must behave exactly as every
    /// recorded take did (R3.5). If this fails, the trend's own slot has changed underneath it.
    func testAJamWithNoRungIsByteIdenticalToWhatItAlwaysWas() {
        let free = TrainerEngine.JamConfig(bpm: 100, bars: 64, tag: "benchmark")
        XCTAssertNil(free.rung)
        XCTAssertEqual(free.backing.name, "jamBacking")
        XCTAssertEqual(free.backing.arrangement, GrooveLibrary.jamBacking)
        XCTAssertEqual(free.gridSubdivisions, GrooveLibrary.jamBacking.stepsPerBeat)
        XCTAssertEqual(free.gridSubdivisions, 4, "the grid every take on disk was scored on")
    }

    /// `nil` means "no rung was prescribed", not "quarters" — they are different tasks and would
    /// pool into one group if the distinction were lost.
    func testNoRungIsNotTheSameAsQuarters() {
        let free = TrainerEngine.JamConfig(bpm: 100)
        let quarters = TrainerEngine.JamConfig(bpm: 100, rung: .quarters)
        XCTAssertNotEqual(free.gridSubdivisions, quarters.gridSubdivisions)
        XCTAssertNotEqual(free.backing.name, quarters.backing.name)
    }

    // MARK: - Storage

    func testTheRungSurvivesStorageAndTheTaskIntervalComesBack() throws {
        for rung in IntervalRung.ladder {
            let stored = TakeFactory.jam(rung: rung)
            XCTAssertEqual(stored.rung, rung.rawValue)
            XCTAssertEqual(stored.taskSubdivisions, rung.subdivisions, "\(rung.label)")
        }
    }

    /// Every take on disk predates the field, and each must keep reading as free playing rather
    /// than as an accidental rung (R6.1).
    func testATakeWithoutARungDecodesAsFreePlaying() throws {
        let stored = TakeFactory.jam()
        let data = try JSONEncoder().encode(stored)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "rung")

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(JamSession.self, from: stripped)

        XCTAssertNil(back.rung)
        XCTAssertEqual(back.taskSubdivisions, 1, "the task was the beat, not the scoring grid")
        XCTAssertEqual(back.subdivisions, 4, "and the grid it was scored on is unchanged")
    }

    /// A rung whose name this build does not know must not become a different rung.
    func testAnUnknownRungFallsBackToTheBeatRatherThanGuessing() throws {
        let stored = TakeFactory.jam()
        let data = try JSONEncoder().encode(stored)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["rung"] = "quintuplets"

        let odd = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(JamSession.self, from: odd)
        XCTAssertEqual(back.rung, "quintuplets", "the record of what ran is kept verbatim")
        XCTAssertEqual(back.taskSubdivisions, 1, "but nothing is inferred from a name we lack")
    }

    // MARK: - Instructions (R3.6)

    func testEachRungAsksForItsOwnDivisionInWords() {
        let wanted: [IntervalRung: String] = [
            .quarters: "one note on every beat",
            .eighths: "two notes to the beat",
            .tripletEighths: "three notes to the beat",
            .sixteenths: "four notes to the beat",
        ]
        for (rung, phrase) in wanted {
            let text = DrillInstructions.jam(rung: rung)
            XCTAssertTrue(text.steps.contains { $0.contains(phrase) },
                          "\(rung.label) never says '\(phrase)': \(text.steps)")
            XCTAssertNotEqual(text.steps, DrillInstructions.jam.steps)
        }
    }

    /// The one mistake a rung take can make that invalidates it rather than lowering the score.
    func testEveryRungWarnsThatACoarserDivisionIsDiscardedRatherThanScored() {
        for rung in IntervalRung.ladder {
            XCTAssertTrue(DrillInstructions.jam(rung: rung).pitfalls
                            .contains { $0.contains("off-grid") },
                          "\(rung.label): \(DrillInstructions.jam(rung: rung).pitfalls)")
        }
    }

    func testNoRungKeepsThePlainJamText() {
        XCTAssertEqual(DrillInstructions.jam(rung: nil).steps, DrillInstructions.jam.steps)
    }

    /// Both surfaces go through `forBlock`, so the rung has to arrive by that route too.
    func testAPlannedBlockWithARungShowsTheRungsInstructions() {
        let block = SessionBlock(role: .training,
                                 plan: .jam(JamPlan(bpm: 100, bars: 32, tag: "ladder",
                                                    rung: .eighths)),
                                 reason: "the ladder slot")
        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.jam(rung: .eighths).steps)
    }

    /// An experiment take is at the benchmark's locked settings and carries no rung, so the arm
    /// must keep winning — losing it would swap the conditions of an instruction-only design.
    func testAnExperimentArmStillWinsOverARung() {
        let block = SessionBlock(
            role: .experiment,
            plan: .jam(JamPlan(bpm: 100, bars: 64, tag: "steady-vs-melodic", rung: .eighths)),
            reason: "the experiment slot",
            experiment: TakeFactory.assignment(arm: "melodic"))
        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.jam(arm: "melodic").steps)
    }

    // MARK: - The plan preview

    func testThePlanLabelNamesTheRungSoItIsVisibleBeforePlaying() {
        let withRung = BlockPlan.jam(JamPlan(bpm: 100, bars: 32, tag: nil, rung: .sixteenths))
        XCTAssertTrue(withRung.settingsLabel.contains("sixteenths"), withRung.settingsLabel)

        let free = BlockPlan.jam(JamPlan(bpm: 100, bars: 64, tag: "benchmark"))
        XCTAssertEqual(free.settingsLabel, "100 BPM · 64 bars", "unchanged for the benchmark")
    }
}
