import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// R3.6, made structural: the text comes from the configuration the take will run with.
///
/// The rule was already written down and every surface followed it by hand — the console passed
/// the rung and the feel, a planned block passed the rung and the feel, and the app passed only
/// the rung. So a swung jam started from the app's menu was handed the *straight* text, which
/// tells the player to play "two notes to the beat, evenly" over a hat that swings and a grid that
/// expects the offbeat late. `swung(rung:feel:)` exists because that text describes a different
/// task; handing it to a swung take says the player's own task is a mistake.
///
/// Every assertion here is reachable without an audio device, and none of them builds its own
/// config out of parts — that was the shape of the defect (`LESSONS.md` shape 1). They assert on
/// `forJam`/`forForm`/`forDropout`/`forTempo`, which is what both surfaces now call.
final class InstructionsComeFromTheConfigTests: XCTestCase {

    // MARK: The defect

    /// The one that fails if the feel stops travelling on the config.
    func testASwungJamConfigGetsTheSwungTextRatherThanTheStraightOne() {
        let straight = TrainerEngine.JamConfig(bpm: 100, bars: 32, rung: .eighths)
        var swung = straight
        swung.feel = .swung

        let text = DrillInstructions.forJam(swung)
        XCTAssertNotEqual(text.steps, DrillInstructions.forJam(straight).steps,
                          "a swung take was described exactly as a straight one")
        XCTAssertTrue(text.steps.contains { $0.contains("swing") || $0.contains("swung") },
                      "\(text.steps)")
        XCTAssertTrue(text.pitfalls.contains { $0.contains("straighten up") }, "\(text.pitfalls)")
        XCTAssertFalse(text.steps.contains { $0.contains("evenly") },
                       "the straight instruction to play evenly reached a swung take")
    }

    /// A feel the rung cannot carry must not change the text either, or the player is told to
    /// swing a division that will be scored straight.
    func testATripletRungKeepsTheStraightTextEvenWhenTheConfigCarriesAFeel() {
        var triplets = TrainerEngine.JamConfig(bpm: 100, bars: 32, rung: .tripletEighths)
        triplets.feel = .swung
        XCTAssertEqual(DrillInstructions.forJam(triplets).steps,
                       DrillInstructions.jam(rung: .tripletEighths).steps)
    }

    /// Free playing prescribes nothing, and the benchmark and both experiment arms depend on it
    /// staying that way (R3.5).
    func testAFreeJamKeepsThePlainText() {
        XCTAssertEqual(DrillInstructions.forJam(TrainerEngine.JamConfig(bpm: 100, bars: 64)).steps,
                       DrillInstructions.jam.steps)
    }

    // MARK: The drill's identity travels on the config

    func testAnOffbeatConfigIsDescribedAsTheOffbeatDrill() {
        for level in OffbeatLevel.allCases {
            let config = TrainerEngine.JamConfig.offbeat(bpm: 70, bars: 32, level: level)
            XCTAssertEqual(DrillInstructions.forJam(config).steps,
                           DrillInstructions.offbeat(level: level).steps,
                           "level \(level.rawValue)")
        }
    }

    // MARK: One config, both surfaces

    /// A planned take and a hand-started one at the same settings are the same take, so they get
    /// the same words. Built from the plan on one side and from the config on the other, which is
    /// the pair that used to be able to disagree.
    func testAPlannedBlockAndAHandStartedTakeDescribeOneConfigIdentically() {
        let plan = JamPlan(bpm: 100, bars: 32, tag: "ladder", rung: .eighths, feel: .swung)
        let block = SessionBlock(role: .training, plan: .jam(plan), reason: "the ladder slot")

        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.forJam(SessionRunner.jamConfig(for: plan,
                                                                       role: .training)).steps)
    }

    /// The offbeat level outranks an experiment arm, which is the order the arm branch has always
    /// had. A planned offbeat block carrying an arm must still read as the skank.
    func testAnOffbeatBlockIsStillTheOffbeatDrillWhenItCarriesAnArm() {
        let plan = JamPlan(bpm: 70, bars: 32, tag: "offbeat", offbeatLevel: 2)
        let arm = ExperimentAssignment(experimentId: UUID(), name: "focus",
                                       arm: "relaxed", runIndex: 0)
        let block = SessionBlock(role: .training, plan: .jam(plan), reason: "the skank",
                                 experiment: arm)
        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.offbeat(level: .backbeatOnly).steps)
    }

    // MARK: Every drill's text moves when its own config moves

    /// The totality check. A `for*` function that ignored the parameter that matters would pass
    /// every test above and still describe the wrong take.
    func testTheTextMovesWithEveryConfigParameterThatChangesTheTask() {
        let eight = TrainerEngine.FormConfig(bpm: 100, bars: 64, phraseBars: 8, level: .fillOnly)
        let sixteen = TrainerEngine.FormConfig(bpm: 100, bars: 64, phraseBars: 16, level: .fillOnly)
        XCTAssertNotEqual(DrillInstructions.forForm(eight).steps,
                          DrillInstructions.forForm(sixteen).steps, "phrase length")

        let bare = TrainerEngine.FormConfig(bpm: 100, bars: 64, phraseBars: 8, level: .dropoutAcross)
        XCTAssertNotEqual(DrillInstructions.forForm(eight).steps,
                          DrillInstructions.forForm(bare).steps, "landmark level")

        let quarters = TrainerEngine.DropoutConfig(bpm: 100, rung: .quarters)
        let eighths = TrainerEngine.DropoutConfig(bpm: 100, rung: .eighths)
        XCTAssertNotEqual(DrillInstructions.forDropout(quarters).steps,
                          DrillInstructions.forDropout(eighths).steps, "continuation rung")

        let slowTempo = TrainerEngine.TempoConfig(targets: [100], rung: .quarters)
        let fastTempo = TrainerEngine.TempoConfig(targets: [100], rung: .sixteenths)
        XCTAssertNotEqual(DrillInstructions.forTempo(slowTempo).steps,
                          DrillInstructions.forTempo(fastTempo).steps, "tempo-drill rung")
    }

    /// Shape 13 in the direction this drill actually takes: absent means quarters here, because
    /// the words have demanded one note per beat since M6. A jam's absent rung means the opposite
    /// and `testAFreeJamKeepsThePlainText` holds that end.
    func testAnAbsentRungKeepsTheQuarterNoteTextInTheTwoDrillsThatAlwaysAskedForOne() {
        XCTAssertEqual(DrillInstructions.forDropout(TrainerEngine.DropoutConfig(bpm: 100)).steps,
                       DrillInstructions.forDropout(
                           TrainerEngine.DropoutConfig(bpm: 100, rung: .quarters)).steps)
        XCTAssertEqual(DrillInstructions.forTempo(TrainerEngine.TempoConfig(targets: [100])).steps,
                       DrillInstructions.forTempo(
                           TrainerEngine.TempoConfig(targets: [100], rung: .quarters)).steps)
    }

    // MARK: The planned configs are built once

    /// `runCurrent` and `forBlock` read the same four factories now, so the fallback below cannot
    /// be one value in the drill and another in its description.
    func testAnOutOfRangeFormLevelFallsBackOnceRatherThanTwice() {
        let plan = FormPlan(bpm: 100, bars: 64, phraseBars: 8, level: 99)
        XCTAssertEqual(SessionRunner.formConfig(for: plan).level, .fillAndAccent)

        let block = SessionBlock(role: .training, plan: .form(plan), reason: "form")
        XCTAssertEqual(DrillInstructions.forBlock(block).steps,
                       DrillInstructions.form(level: FormLevel.fillAndAccent.rawValue,
                                              phraseBars: 8).steps)
    }
}
