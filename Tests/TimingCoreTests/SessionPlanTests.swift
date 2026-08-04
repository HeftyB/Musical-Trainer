import XCTest
@testable import TimingCore

final class SessionPlanTests: XCTestCase {

    // MARK: Helpers

    private func continuation(silentBars: Int = 4, reliable: Bool,
                              clock: Double? = nil, motor: Double? = nil,
                              biasPercent: Double? = 5) -> PlannerInput.Continuation {
        PlannerInput.Continuation(silentBars: silentBars, absTempoBiasPercent: biasPercent,
                                  splitIsReliable: reliable, clockSDms: clock, motorSDms: motor)
    }

    private func form(level: Int = 2, phraseBars: Int = 8, onFormRate: Double = 0.6,
                      unmarked: Bool = false, markedEvery: Double? = nil) -> PlannerInput.Form {
        PlannerInput.Form(level: level, phraseBars: phraseBars, onFormRate: onFormRate,
                          hasUnmarkedPhrases: unmarked, markedEveryBars: markedEvery)
    }

    private func blocks(_ plan: SessionPlan, role: BlockRole) -> [SessionBlock] {
        plan.blocks.filter { $0.role == role }
    }

    private func firstDropout(_ plan: SessionPlan) -> DropoutPlan? {
        for block in plan.blocks { if case .dropout(let p) = block.plan { return p } }
        return nil
    }

    private func firstTempoTraining(_ plan: SessionPlan) -> TempoPlan? {
        for block in plan.blocks where block.role == .training {
            if case .tempo(let p) = block.plan { return p }
        }
        return nil
    }

    private func firstForm(_ plan: SessionPlan) -> FormPlan? {
        for block in plan.blocks { if case .form(let p) = block.plan { return p } }
        return nil
    }

    // MARK: Shape

    /// The fixed slots are the whole point of the structure: a cold probe before anything
    /// warms up, and a benchmark early enough that it is never measured tired.
    func testEverySessionOpensColdAndClosesWithPlaying() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
            XCTAssertEqual(plan.blocks.first?.role, .cold, "\(minutes) min")
            XCTAssertEqual(plan.blocks[1].role, .warmUp)
            XCTAssertEqual(plan.blocks[2].role, .benchmark)
            XCTAssertEqual(plan.blocks.last?.role, .closing)
        }
    }

    /// Every confound in this dataset arrived by a parameter changing between takes. The
    /// cold probe and the benchmark jam are the two takes that must never do that, whatever
    /// the history says or however long the session is.
    func testColdAndBenchmarkAreIdenticalAcrossHistoriesAndDurations() {
        let empty = PlannerInput()
        let rich = PlannerInput(
            jams: [PlannerInput.Jam(bpm: 110, sdMs: 30, absBiasMs: 25, lag1: 0.5)],
            continuations: (0..<6).map { _ in continuation(silentBars: 16, reliable: true,
                                                           clock: 30, motor: 5) },
            forms: [form(level: 3, phraseBars: 16, onFormRate: 1.0)],
            tempos: [PlannerInput.Tempo(targetCount: 3, meanAbsErrorPercent: 0.2)])

        var seenCold = Set<String>(), seenBenchmark = Set<String>()
        for input in [empty, rich] {
            for minutes in [20, 30, 45] {
                let plan = SessionPlanner.plan(targetMinutes: minutes, from: input)
                seenCold.insert(blocks(plan, role: .cold)[0].plan.settingsLabel)
                seenBenchmark.insert(blocks(plan, role: .benchmark)[0].plan.settingsLabel)
            }
        }
        XCTAssertEqual(seenCold.count, 1, "the cold probe must not adapt: \(seenCold)")
        XCTAssertEqual(seenBenchmark.count, 1, "the benchmark must not adapt: \(seenBenchmark)")
    }

    /// The plan preview promises a length. Overrunning it by a drill is how a 30-minute
    /// session quietly becomes 45 and stops being done on a weeknight.
    func testPlanFitsInsideItsTarget() {
        let input = PlannerInput(continuations: [continuation(reliable: false)],
                                 forms: [form()],
                                 tempos: [PlannerInput.Tempo(targetCount: 1, meanAbsErrorPercent: 4)])
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: input)
            XCTAssertLessThanOrEqual(plan.estimatedSeconds, Double(minutes) * 60,
                                     "\(minutes) min plan ran to \(plan.estimatedSeconds)s")
            // …and isn't trivially short either.
            XCTAssertGreaterThan(plan.estimatedSeconds, Double(minutes) * 60 * 0.8)
        }
    }

    /// There are only three training drills, so a longer session buys **longer takes, not
    /// more of them** — repeats would be filler, whereas more silences in the continuation
    /// drill is a materially better variance estimate. The rest goes to playing.
    func testLongerSessionsBuyLongerTakesThenPlayingTime() {
        let input = PlannerInput(continuations: [continuation(reliable: false)],
                                 forms: [form()],
                                 tempos: [PlannerInput.Tempo(targetCount: 1, meanAbsErrorPercent: 4)])
        let short = SessionPlanner.plan(targetMinutes: 20, from: input)
        let long = SessionPlanner.plan(targetMinutes: 45, from: input)

        func trainingSeconds(_ plan: SessionPlan) -> Double {
            blocks(plan, role: .training).reduce(0) { $0 + $1.estimatedSeconds }
        }
        XCTAssertGreaterThan(trainingSeconds(long), trainingSeconds(short))
        XCTAssertLessThanOrEqual(blocks(long, role: .training).count,
                                 SessionPlanner.maximumTrainingBlocks)

        guard case .jam(let shortClosing) = short.blocks.last!.plan,
              case .jam(let longClosing) = long.blocks.last!.plan else {
            return XCTFail("both sessions should close on a jam")
        }
        XCTAssertGreaterThan(longClosing.bars, shortClosing.bars)
        XCTAssertEqual(longClosing.bars % 8, 0, "closing length snaps to whole phrases")
    }

    /// A 9-minute jam followed by a 1-minute one is not two takes, it is one take and an
    /// apology. Closing time is split evenly across as few blocks as the cap allows.
    func testClosingTimeIsSplitEvenlyRatherThanLeavingARunt() {
        for minutes in [20, 30, 45] {
            let plan = SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
            let closing = blocks(plan, role: .closing)
            XCTAssertFalse(closing.isEmpty, "a session must end on playing")

            let lengths = Set(closing.map(\.estimatedSeconds))
            XCTAssertEqual(lengths.count, 1,
                           "\(minutes) min: closing jams should be equal, got \(closing.count) "
                         + "of lengths \(lengths.sorted())")
            for block in closing {
                XCTAssertGreaterThanOrEqual(
                    block.estimatedSeconds, Double(SessionPlanner.minimumClosingBars) * 2.4,
                    "\(minutes) min: no runt blocks")
            }
        }
    }

    /// The backing is two sections with a fill every eight bars. It sustains ten minutes and
    /// is hypnotic well before twenty, so a long session gets more jams rather than a longer
    /// one — real musical depth is M17, and pretending otherwise would produce a take nobody
    /// finishes.
    func testALongSessionAddsJamsRatherThanOneEndlessOne() {
        let plan = SessionPlanner.plan(targetMinutes: 45, from: PlannerInput())
        let closing = blocks(plan, role: .closing)
        XCTAssertGreaterThan(closing.count, 1)
        for block in closing {
            XCTAssertLessThanOrEqual(block.estimatedSeconds, 11 * 60,
                                     "no single jam should run past ~10 minutes")
        }
    }

    /// The benchmark is what the trend is fitted to; the closing jam is played tired. If both
    /// carried the same tag they would pool, and the trend would be measuring fatigue.
    func testBenchmarkAndClosingJamsAreTaggedApart() {
        let plan = SessionPlanner.plan(targetMinutes: 30, from: PlannerInput())
        guard case .jam(let benchmark) = blocks(plan, role: .benchmark)[0].plan,
              case .jam(let closing) = blocks(plan, role: .closing)[0].plan else {
            return XCTFail("expected jams in both slots")
        }
        XCTAssertEqual(benchmark.tag, SessionPlanner.benchmarkTag)
        XCTAssertEqual(closing.tag, SessionPlanner.closingTag)
        XCTAssertNotEqual(benchmark.tag, closing.tag)
    }

    // MARK: Continuation drill — the open question

    func testUnsettledSplitSchedulesTheContinuationDrillAndSaysWhy() {
        let input = PlannerInput(continuations: [continuation(reliable: true, clock: 14, motor: 9),
                                                 continuation(reliable: false),
                                                 continuation(reliable: false)])
        let plan = SessionPlanner.plan(targetMinutes: 30, from: input)

        XCTAssertNotNil(firstDropout(plan), "an unsettled split should schedule the drill that settles it")
        XCTAssertTrue(plan.notes.contains { $0.contains("clock/motor split is still unsettled") },
                      "the gap in the data should be stated before the session, not after")
    }

    func testASettledLooseClockLengthensTheSilences() {
        let input = PlannerInput(continuations: (0..<3).map { _ in
            continuation(silentBars: 4, reliable: true, clock: 15, motor: 9)
        })
        let plan = SessionPlanner.plan(targetMinutes: 30, from: input)
        XCTAssertEqual(firstDropout(plan)?.silentBars, 8, "a loose clock earns longer alone")
    }

    /// Motor-dominant needs different work entirely — evenness and dynamics, not longer
    /// silences — and no drill for that exists yet. Scheduling more of the same would be
    /// training the wrong half; saying so is the honest move.
    func testASettledMotorDominantResultSaysSoRatherThanDrillingTheClock() {
        let input = PlannerInput(continuations: (0..<3).map { _ in
            continuation(silentBars: 4, reliable: true, clock: 8, motor: 16)
        })
        let plan = SessionPlanner.plan(targetMinutes: 30, from: input)
        XCTAssertNil(firstDropout(plan))
        XCTAssertTrue(plan.notes.contains { $0.contains("Motor noise is now the larger half") })
    }

    // MARK: Tempo calibration

    func testTempoDrillStaysOnOneTargetWhileTheErrorIsLarge() {
        let input = PlannerInput(continuations: (0..<3).map { _ in
                                    continuation(reliable: true, clock: 8, motor: 16) },
                                 tempos: [PlannerInput.Tempo(targetCount: 1, meanAbsErrorPercent: 4.7)])
        XCTAssertEqual(firstTempoTraining(SessionPlanner.plan(targetMinutes: 30, from: input))?.targets,
                       [SessionPlanner.referenceBpm])
    }

    /// Accurate at one tempo is a lookup table, not a calibrated clock — the next rung is the
    /// mapping, not more of the same.
    func testAccuracyAtOneTargetPromotesToRotatingTargets() {
        let input = PlannerInput(continuations: (0..<3).map { _ in
                                    continuation(reliable: true, clock: 8, motor: 16) },
                                 tempos: [PlannerInput.Tempo(targetCount: 1, meanAbsErrorPercent: 0.3)])
        let targets = firstTempoTraining(SessionPlanner.plan(targetMinutes: 30, from: input))?.targets
        XCTAssertEqual(targets, [76, 100, 132])
    }

    func testRotatingAndAccurateDropsTheTempoDrill() {
        let input = PlannerInput(continuations: (0..<3).map { _ in
                                    continuation(reliable: true, clock: 8, motor: 16) },
                                 forms: [form()],
                                 tempos: [PlannerInput.Tempo(targetCount: 3, meanAbsErrorPercent: 0.4)])
        XCTAssertNil(firstTempoTraining(SessionPlanner.plan(targetMinutes: 30, from: input)))
    }

    // MARK: The recall drill

    /// Only worth scheduling once the split says the clock is the problem — before that it
    /// would be training a weakness that has not been shown to exist.
    func testRecallIsNotScheduledUntilTheClockIsKnownToBeTheWeakHalf() {
        let unsettled = PlannerInput(continuations: [continuation(reliable: false),
                                                     continuation(reliable: false)])
        XCTAssertFalse(hasMemoryBlock(SessionPlanner.plan(targetMinutes: 30, from: unsettled)))

        let motorDominant = PlannerInput(continuations: (0..<3).map { _ in
            continuation(reliable: true, clock: 8, motor: 16) })
        XCTAssertFalse(hasMemoryBlock(SessionPlanner.plan(targetMinutes: 30, from: motorDominant)))

        let clockDominant = PlannerInput(continuations: (0..<3).map { _ in
            continuation(reliable: true, clock: 15, motor: 9) })
        XCTAssertTrue(hasMemoryBlock(SessionPlanner.plan(targetMinutes: 30, from: clockDominant)))
    }

    /// Form is the only drill on the *other* axis — where you are in the music, not where the
    /// note is. Ranking it against the clock drills on their evidence would drop it from every
    /// session the moment a clock drill had a reason, which is exactly what happened the
    /// moment the recall drill was added.
    func testFormKeepsItsSlotEvenWhenEveryClockDrillHasAReason() {
        let input = PlannerInput(
            continuations: (0..<3).map { _ in continuation(reliable: true, clock: 15, motor: 9) },
            forms: [form(level: 2, onFormRate: 0.5)],
            tempos: [PlannerInput.Tempo(targetCount: 1, meanAbsErrorPercent: 5)])
        let plan = SessionPlanner.plan(targetMinutes: 30, from: input)

        XCTAssertNotNil(firstForm(plan), "form was crowded out by the clock drills")
        XCTAssertTrue(hasMemoryBlock(plan))
        XCTAssertLessThanOrEqual(blocks(plan, role: .training).count,
                                 SessionPlanner.maximumTrainingBlocks)
    }

    private func hasMemoryBlock(_ plan: SessionPlan) -> Bool {
        plan.blocks.contains { if case .memory = $0.plan { return true } else { return false } }
    }

    // MARK: Form ladder

    /// A player marking a steady 4-bar phrase against an 8-bar setting has a consistent feel,
    /// not a lost one. Following it measures something; scoring it down measures nothing.
    func testFormFollowsTheFeltPhraseLength() {
        let input = PlannerInput(forms: [form(level: 2, phraseBars: 8, onFormRate: 0.56,
                                              markedEvery: 4)])
        let plan = SessionPlanner.plan(targetMinutes: 30, from: input)
        XCTAssertEqual(firstForm(plan)?.phraseBars, 4)
        XCTAssertEqual(firstForm(plan)?.level, 2, "changing the phrase and the level at once "
                     + "would confound the next result")
    }

    func testCleanTakeEarnsTheNextLandmarkLevel() {
        let input = PlannerInput(forms: [form(level: 1, onFormRate: 1.0, unmarked: false)])
        XCTAssertEqual(firstForm(SessionPlanner.plan(targetMinutes: 30, from: input))?.level, 2)
    }

    func testUnmarkedPhrasesBlockPromotionEvenAtAHighRate() {
        // Every mark on the right bar, but whole phrases went unmarked — which is exactly the
        // failure a high on-form rate hides.
        let input = PlannerInput(forms: [form(level: 1, onFormRate: 1.0, unmarked: true)])
        XCTAssertEqual(firstForm(SessionPlanner.plan(targetMinutes: 30, from: input))?.level, 1)
    }

    func testTheLadderStopsAtTheTopLevel() {
        let input = PlannerInput(forms: [form(level: 3, onFormRate: 1.0)])
        XCTAssertEqual(firstForm(SessionPlanner.plan(targetMinutes: 30, from: input))?.level, 3)
    }

    // MARK: First run

    func testAnEmptyHistoryProducesAUsablePlanAndSaysItIsGuessing() {
        let plan = SessionPlanner.plan(targetMinutes: 30, from: PlannerInput())
        XCTAssertGreaterThanOrEqual(blocks(plan, role: .training).count, 1)
        XCTAssertTrue(plan.notes.contains { $0.contains("No history yet") })
        XCTAssertFalse(plan.blocks.contains { $0.reason.isEmpty }, "every block justifies itself")
    }
}
