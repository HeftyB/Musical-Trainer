import XCTest
@testable import TimingCore
@testable import TrainerKit

/// Every drill validates its ranges and throws before any audio is scheduled (R7.6).
///
/// The checks live on the config as `validate()`, and each `run*` calls it before
/// `environment()`. That split is not cosmetic: these tests call `validate()` directly and can
/// never open an audio device. Written the obvious way — asserting that `runTempo` throws — the
/// first version of this file **played a full two-and-a-half-minute drill through the speakers**
/// when a config it expected to be rejected turned out to be legal.
///
/// The runners themselves stay live-run-only (R5.6). This is the boundary, not the drill.
final class DrillConfigTests: XCTestCase {

    private func assertRejects(_ label: String, _ body: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), "\(label) must be rejected", file: file, line: line) {
            XCTAssertTrue($0 is SpikeError,
                          "\(label) must throw SpikeError, not \(type(of: $0))",
                          file: file, line: line)
        }
    }

    func testJamRejectsImpossibleTempoAndLength() {
        assertRejects("39 BPM") { try TrainerEngine.JamConfig(bpm: 39, bars: 32).validate() }
        assertRejects("261 BPM") { try TrainerEngine.JamConfig(bpm: 261, bars: 32).validate() }
        assertRejects("3 bars") { try TrainerEngine.JamConfig(bpm: 100, bars: 3).validate() }
        assertRejects("513 bars") { try TrainerEngine.JamConfig(bpm: 100, bars: 513).validate() }
        XCTAssertNoThrow(try TrainerEngine.JamConfig(bpm: 100, bars: 64).validate())
    }

    func testFormRejectsAPhraseLongerThanTheTake() {
        assertRejects("0 BPM") {
            try TrainerEngine.FormConfig(bpm: 0, bars: 64, phraseBars: 8,
                                         level: .fillAndAccent).validate()
        }
        assertRejects("a 128-bar phrase") {
            try TrainerEngine.FormConfig(bpm: 100, bars: 64, phraseBars: 128,
                                         level: .fillAndAccent).validate()
        }
        assertRejects("an 8-bar phrase in a 4-bar take") {
            try TrainerEngine.FormConfig(bpm: 100, bars: 4, phraseBars: 8,
                                         level: .noFills).validate()
        }
    }

    func testContinuationRejectsACycleThatCannotBeScored() {
        assertRejects("0 cycles") {
            try TrainerEngine.DropoutConfig(bpm: 100, pacedBars: 4, silentBars: 4,
                                            cycles: 0).validate()
        }
        assertRejects("no silence") {
            try TrainerEngine.DropoutConfig(bpm: 100, pacedBars: 4, silentBars: 0,
                                            cycles: 6).validate()
        }
    }

    func testTempoRejectsAnEmptyTargetList() {
        // `init` substitutes a default for an empty list, so the empty case can only be
        // reached by mutating the property afterwards — and `target(forRound:)` traps on `% 0`.
        var emptied = TrainerEngine.TempoConfig()
        emptied.targets = []
        assertRejects("no targets") { try emptied.validate() }
        assertRejects("an out-of-range target") {
            try TrainerEngine.TempoConfig(targets: [500], leadBars: 4, holdBars: 4,
                                          rounds: 8).validate()
        }
        XCTAssertEqual(TrainerEngine.TempoConfig(targets: []).targets, [100],
                       "init substitutes a default rather than accepting nothing")
    }

    /// The recall drill needs both conditions, so one round is never a drill.
    func testRecallRejectsTooFewRoundsToHoldBothConditions() {
        assertRejects("1 round") {
            try TrainerEngine.MemoryConfig(bpm: 100, referenceBars: 4, retentionBars: 4,
                                           reproduceBars: 4, rounds: 1).validate()
        }
        assertRejects("33 rounds") {
            try TrainerEngine.MemoryConfig(bpm: 100, referenceBars: 4, retentionBars: 4,
                                           reproduceBars: 4, rounds: 33).validate()
        }
    }

    /// The planner's own output must always satisfy the engine's limits. A plan that cannot
    /// run is worse than no plan: it fails partway through an evening rather than at the start.
    func testEveryPlannedBlockIsWithinTheEnginesLimits() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
            XCTAssertFalse(plan.blocks.isEmpty, "\(minutes) minutes produced no blocks")
            for block in plan.blocks {
                switch block.plan {
                case .groove(let p):
                    XCTAssertTrue((40...260).contains(p.bpm))
                case .jam(let p):
                    XCTAssertTrue((40...260).contains(p.bpm))
                    XCTAssertTrue((4...512).contains(p.bars))
                case .form(let p):
                    XCTAssertTrue((2...32).contains(p.phraseBars))
                    XCTAssertTrue(p.bars >= p.phraseBars && p.bars <= 512)
                case .dropout(let p):
                    XCTAssertTrue((1...16).contains(p.pacedBars))
                    XCTAssertTrue((1...32).contains(p.silentBars))
                    XCTAssertTrue((1...32).contains(p.cycles))
                case .tempo(let p):
                    XCTAssertFalse(p.targets.isEmpty, "a tempo block with no target traps")
                    XCTAssertTrue(p.targets.allSatisfy { (40...260).contains($0) })
                    XCTAssertTrue((1...32).contains(p.rounds))
                case .memory(let p):
                    XCTAssertTrue((1...32).contains(p.retentionBars))
                    XCTAssertTrue((2...32).contains(p.rounds), "both conditions need rounds")
                }
            }
        }
    }
}
