import XCTest
@testable import TimingCore

/// M14 step 4d: the planner varies tempo — on exactly one block, and never on the locked ones.
///
/// R3.5 exists because every confound already in this dataset arrived by a parameter changing
/// between takes. The ladder is the first block the planner is *allowed* to vary, which makes
/// the tests that it leaves the others alone the load-bearing ones here.
final class LadderPlanningTests: XCTestCase {

    // MARK: Helpers

    private func ladder(_ bpm: Double, _ rung: IntervalRung, sd: Double = 20)
        -> PlannerInput.Ladder {
        PlannerInput.Ladder(bpm: bpm, rung: rung, sdMs: sd)
    }

    private func jams(_ sd: Double, count: Int = 6) -> [PlannerInput.Jam] {
        (0..<count).map { _ in
            PlannerInput.Jam(bpm: 100, sdMs: sd, absBiasMs: 15, lag1: 0.3)
        }
    }

    private func ladderPlan(_ plan: SessionPlan) -> JamPlan? {
        for block in plan.blocks where block.role == .training {
            if case .jam(let p) = block.plan { return p }
        }
        return nil
    }

    private func block(_ plan: SessionPlan, _ role: BlockRole) -> SessionBlock? {
        plan.blocks.first { $0.role == role }
    }

    /// Histories that differ in everything the ladder reads.
    private var histories: [PlannerInput] {
        var out = [PlannerInput(jams: jams(20))]
        var running: [PlannerInput.Ladder] = []
        for (bpm, rung) in [(80.0, IntervalRung.quarters), (100, .quarters), (120, .eighths),
                            (140, .eighths), (80, .tripletEighths), (100, .eighths)] {
            running.append(ladder(bpm, rung))
            out.append(PlannerInput(jams: jams(20), ladders: running))
        }
        out.append(PlannerInput(jams: jams(8), ladders: running))     // a much tighter player
        out.append(PlannerInput(jams: jams(45), ladders: running))    // a much looser one
        return out
    }

    // MARK: The blocks that must never move

    /// The take the trend is fitted to. If this ever varies with the ladder, every comparison
    /// §7 has published stops meaning what it says.
    ///
    /// Asserted **absolutely**, not against a reference plan built by the same code. The first
    /// version of this test did the latter, and planting a benchmark at `referenceBpm + 5` did
    /// not fail it: the reference moved with the thing it was checking. A relative assertion
    /// catches variation *between* histories and is blind to a constant that is simply wrong,
    /// which is the more likely mistake once a planner has a tempo rotation in it at all.
    func testTheBenchmarkIsAlwaysTheSameLockedTakeWhateverTheLadderDoes() {
        for (i, input) in histories.enumerated() {
            for minutes in [20, 30, 45] {
                let plan = SessionPlanner.plan(targetMinutes: minutes, from: input)
                guard case .jam(let p)? = block(plan, .benchmark)?.plan else {
                    return XCTFail("history \(i) at \(minutes) min has no benchmark jam")
                }
                XCTAssertEqual(p.bpm, SessionPlanner.referenceBpm, "history \(i)/\(minutes)")
                XCTAssertEqual(p.bars, SessionPlanner.benchmarkBars, "history \(i)/\(minutes)")
                XCTAssertEqual(p.tag, SessionPlanner.benchmarkTag, "history \(i)/\(minutes)")
                XCTAssertNil(p.rung, "history \(i)/\(minutes): the benchmark gained a rung")
            }
        }
    }

    /// And the whole block, reason included, is identical from one history to the next — a
    /// benchmark whose *description* drifted would still be the same take, but the player would
    /// have no way to tell it had not.
    func testTheBenchmarkBlockIsIdenticalAcrossEveryHistory() {
        let plans = histories.map { SessionPlanner.plan(targetMinutes: 45, from: $0) }
        let benchmarks = plans.compactMap { block($0, .benchmark) }
        XCTAssertEqual(benchmarks.count, plans.count)
        for (i, mark) in benchmarks.enumerated() {
            XCTAssertEqual(mark, benchmarks[0], "history \(i) moved the benchmark")
        }
    }

    /// An experiment take runs at the benchmark's locked settings, and its arm is the only thing
    /// about it that may change. A rung leaking in would make the two arms different tasks.
    func testTheExperimentBlockNeverGainsARungOrChangesTempo() {
        for (i, input) in histories.enumerated() {
            let plan = SessionPlanner.plan(targetMinutes: 45, from: input)
            guard case .jam(let p)? = block(plan, .experiment)?.plan else {
                continue        // no experiment left to run is a legitimate outcome
            }
            XCTAssertNil(p.rung, "history \(i): the experiment take gained a rung")
            XCTAssertEqual(p.bpm, SessionPlanner.referenceBpm, "history \(i)")
            XCTAssertEqual(p.bars, SessionPlanner.benchmarkBars, "history \(i)")
        }
    }

    func testTheColdProbeIsAlwaysTheSameLockedRoundsWhateverTheLadderDoes() {
        for (i, input) in histories.enumerated() {
            let plan = SessionPlanner.plan(targetMinutes: 45, from: input)
            guard case .tempo(let p)? = block(plan, .cold)?.plan else {
                return XCTFail("history \(i) has no cold probe")
            }
            XCTAssertEqual(p.targets, [SessionPlanner.referenceBpm], "history \(i)")
            XCTAssertEqual(p.rounds, SessionPlanner.coldRounds, "history \(i)")
            XCTAssertEqual(p.holdBars, SessionPlanner.coldHoldBars, "history \(i)")
        }
    }

    // MARK: The rung is never above what can be scored

    /// Above its ceiling a rung discards notes the player aimed correctly, so the off-grid rate
    /// stops being a fact about the player (§7.23 step 1). The planner must never schedule one.
    func testTheRungIsAlwaysScorableAtTheTempoItWasPickedFor() {
        for (i, input) in histories.enumerated() {
            let plan = SessionPlanner.plan(targetMinutes: 45, from: input)
            guard let jam = ladderPlan(plan), let rung = jam.rung else { continue }
            let spread = SessionPlanner.spreadEstimate(for: rung, from: input)
            XCTAssertTrue(rung.isScorable(atBpm: jam.bpm, spreadMs: spread),
                          "history \(i): \(rung.label) at \(jam.bpm) BPM is above its "
                        + "\(rung.maximumBpm(forSpreadMs: spread)) BPM ceiling")
        }
    }

    /// The concrete case: a loose player at the top of the rotation cannot be given sixteenths,
    /// because 140 BPM cannot score them at any plausible spread.
    func testAFastTempoForcesACoarserRungThanTheLadderHasReached() {
        let reached = [ladder(80, .quarters), ladder(80, .eighths), ladder(80, .tripletEighths)]
        let input = PlannerInput(jams: jams(20), ladders: reached)

        XCTAssertEqual(SessionPlanner.nextRung(atBpm: 80, from: input), .sixteenths,
                       "80 BPM can score the rung above triplets")
        XCTAssertEqual(SessionPlanner.nextRung(atBpm: 140, from: input), .eighths,
                       "140 BPM cannot, so it drops to the finest rung it can score")
    }

    // MARK: Promotion is one rung at a time

    /// No rung above eighths has ever been played, and whether a groove is playable-along-to is
    /// not something its step list can answer (R5.6). Two rungs at once would put the player on
    /// a backing nobody has heard.
    func testARungIsNeverPromotedMoreThanOneStepFromWhatHasBeenPlayed() {
        let order = IntervalRung.ladder
        for played in order {
            let input = PlannerInput(jams: jams(12), ladders: [ladder(80, played)])
            let next = SessionPlanner.nextRung(atBpm: 80, from: input)
            let step = (order.firstIndex(of: next) ?? 0) - (order.firstIndex(of: played) ?? 0)
            XCTAssertLessThanOrEqual(step, 1, "\(played.label) jumped to \(next.label)")
        }
    }

    func testTheLadderStartsAtQuartersWithNoHistory() {
        XCTAssertEqual(SessionPlanner.nextRung(atBpm: 100, from: PlannerInput()), .quarters)
    }

    // MARK: Tempo rotation

    /// Min-count, so the tempos stay within one of each other rather than settling into a fixed
    /// order — the `ExperimentSchedule` argument, on a different axis.
    func testTheRotationVisitsEveryTempoBeforeRepeatingAny() {
        var run: [PlannerInput.Ladder] = []
        var seen: [Double] = []
        for _ in 0..<SessionPlanner.ladderTempos.count {
            let bpm = SessionPlanner.nextLadderTempo(from: run)
            seen.append(bpm)
            run.append(ladder(bpm, .quarters))
        }
        XCTAssertEqual(Set(seen), Set(SessionPlanner.ladderTempos),
                       "every tempo once before any repeat: \(seen)")
    }

    func testTheRotationStaysBalancedOverManySittings() {
        var run: [PlannerInput.Ladder] = []
        for _ in 0..<20 { run.append(ladder(SessionPlanner.nextLadderTempo(from: run), .quarters)) }
        let counts = SessionPlanner.ladderTempos.map { bpm in
            run.filter { abs($0.bpm - bpm) < 0.5 }.count
        }
        XCTAssertLessThanOrEqual((counts.max() ?? 0) - (counts.min() ?? 0), 1, "\(counts)")
    }

    /// R1.2.2: the same history must plan the same evening, or "real change" is a coin flip.
    func testTheSameHistoryAlwaysPicksTheSameTempo() {
        let run = [ladder(80, .quarters), ladder(120, .quarters)]
        let picks = (0..<8).map { _ in SessionPlanner.nextLadderTempo(from: run) }
        XCTAssertEqual(Set(picks).count, 1, "\(picks)")
    }

    // MARK: The spread the ceiling rests on

    /// One take at a rung must not overrule the overall figure: a bad first evening would lower
    /// that rung's own ceiling and lock the player out of tempos they can handle.
    func testOneTakeAtARungDoesNotOverruleTheOverallSpread() {
        let input = PlannerInput(jams: jams(20), ladders: [ladder(80, .eighths, sd: 60)])
        XCTAssertEqual(SessionPlanner.spreadEstimate(for: .eighths, from: input), 20, accuracy: 0.1)
    }

    func testEnoughTakesAtARungDoesOverruleIt() {
        let input = PlannerInput(jams: jams(20),
                                 ladders: [ladder(80, .eighths, sd: 60),
                                           ladder(100, .eighths, sd: 60)])
        XCTAssertEqual(SessionPlanner.spreadEstimate(for: .eighths, from: input), 60, accuracy: 0.1)
    }

    func testWithNoHistoryAtAllTheAssumedSpreadIsUsed() {
        XCTAssertEqual(SessionPlanner.spreadEstimate(for: .sixteenths, from: PlannerInput()),
                       SessionPlanner.assumedSpreadMs, accuracy: 0.1)
    }

    // MARK: It does not displace anything

    /// Form was crowded out of every session once before, when Recall was added to a priority
    /// list (§7.16). The ladder takes its own slot for the same reason and must not repeat it.
    ///
    /// **Every session length**, because the first version of this test ran only at 45 minutes
    /// and passed while the ladder was silently dropping form from every 20-minute session. Both
    /// blocks take a slot outright, so the shortest session is the only place the ordering
    /// between them is observable — which makes it the only place worth testing.
    func testTheLadderDoesNotCrowdOutFormAtAnySessionLength() {
        for (i, input) in histories.enumerated() {
            for minutes in [20, 30, 45] {
                let plan = SessionPlanner.plan(targetMinutes: minutes, from: input)
                let hasForm = plan.blocks.contains {
                    if case .form = $0.plan { return true }
                    return false
                }
                XCTAssertTrue(hasForm, "history \(i) at \(minutes) min dropped form")
            }
        }
    }

    /// And when the ladder is the block that does not fit, the plan says so — a block silently
    /// missing is a session the player cannot disagree with.
    func testAShortSessionThatCannotFitTheLadderSaysSo() {
        let input = PlannerInput(
            jams: jams(20),
            continuations: (0..<3).map { _ in
                PlannerInput.Continuation(silentBars: 8, absTempoBiasPercent: 1,
                                          splitIsReliable: true, clockSDms: 22, motorSDms: 9)
            },
            forms: [PlannerInput.Form(level: 2, phraseBars: 4, onFormRate: 0.5,
                                      hasUnmarkedPhrases: false, markedEveryBars: nil)])
        let plan = SessionPlanner.plan(targetMinutes: 20, from: input)

        let hasLadder = plan.blocks.contains {
            if case .jam(let p) = $0.plan { return p.rung != nil }
            return false
        }
        if !hasLadder {
            XCTAssertTrue(plan.notes.contains { $0.contains("interval-ladder") },
                          "the ladder was dropped without a word: \(plan.notes)")
        }
    }

    func testASessionStillEndsOnPlaying() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput(jams: jams(20)))
            XCTAssertEqual(plan.blocks.last?.role, .closing, "\(minutes) min")
        }
    }

    /// A ladder take is tagged apart from the benchmark and the closing jams, so it can never be
    /// pooled with free playing — they are different tasks (§7.23 step 4b).
    func testTheLadderTakeIsTaggedApartFromFreePlaying() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(jams: jams(20)))
        let jam = ladderPlan(plan)
        XCTAssertEqual(jam?.tag, "ladder")
        XCTAssertNotEqual(jam?.tag, SessionPlanner.benchmarkTag)
        XCTAssertNotEqual(jam?.tag, SessionPlanner.closingTag)
    }

    /// The plan preview has to say which rung, or the player cannot disagree with it.
    func testThePreviewNamesTheRungAndTheTempo() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput(jams: jams(20)))
        guard let ladderBlock = plan.blocks.first(where: {
            if case .jam(let p) = $0.plan { return p.rung != nil }
            return false
        }) else { return XCTFail("no ladder block") }

        XCTAssertTrue(ladderBlock.plan.settingsLabel.contains("quarter notes"),
                      ladderBlock.plan.settingsLabel)
        XCTAssertTrue(ladderBlock.reason.contains("gap between notes"), ladderBlock.reason)
    }
}
