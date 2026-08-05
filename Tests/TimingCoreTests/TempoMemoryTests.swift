import XCTest
@testable import TimingCore

final class TempoMemoryTests: XCTestCase {

    /// Lay out `count` rounds back to back, alternating silent and filled retention.
    private func rounds(count: Int, targetBpm: Double = 100,
                        retention: Double = 9.6, reproduce: Double = 9.6) -> [MemoryRound] {
        var out: [MemoryRound] = []
        var cursor = 0.0
        for i in 0..<count {
            let reference = 9.6
            let retentionStart = cursor + reference
            let retentionEnd = retentionStart + retention
            let reproduceEnd = retentionEnd + reproduce
            out.append(MemoryRound(index: i, targetBpm: targetBpm,
                                   condition: i % 2 == 1 ? .filled : .silent,
                                   retentionStart: retentionStart, retentionEnd: retentionEnd,
                                   reproduceStart: retentionEnd, reproduceEnd: reproduceEnd))
            cursor = reproduceEnd
        }
        return out
    }

    /// Quarter notes through a round's reproduce window at `producedBpm`.
    private func taps(for round: MemoryRound, producedBpm: Double,
                      retentionNotes: Int = 0) -> [Tap] {
        var out: [Tap] = []
        let interval = 60.0 / producedBpm
        var t = round.reproduceStart + 0.01
        while t < round.reproduceEnd {
            out.append(Tap(time: t))
            t += interval
        }
        for i in 0..<retentionNotes {
            out.append(Tap(time: round.retentionStart + 0.5 + Double(i) * 0.4))
        }
        return out
    }

    private func report(_ specs: [(silent: Bool, bpm: Double)],
                        retentionNotes: Int = 0) -> TempoMemoryReport {
        var plan: [MemoryRound] = []
        var cursor = 0.0
        for (i, spec) in specs.enumerated() {
            let retentionStart = cursor + 9.6
            let retentionEnd = retentionStart + 9.6
            let reproduceEnd = retentionEnd + 9.6
            plan.append(MemoryRound(index: i, targetBpm: 100,
                                    condition: spec.silent ? .silent : .filled,
                                    retentionStart: retentionStart, retentionEnd: retentionEnd,
                                    reproduceStart: retentionEnd, reproduceEnd: reproduceEnd))
            cursor = reproduceEnd
        }
        let allTaps = zip(plan, specs).flatMap {
            taps(for: $0.0, producedBpm: $0.1.bpm, retentionNotes: retentionNotes)
        }
        return TempoMemoryAnalysis.analyze(taps: allTaps, rounds: plan)
    }

    /// Same as `report`, but each round carries its own count of notes played during the wait,
    /// so the two conditions can be made to lose different numbers of rounds.
    private func reportWithAttrition(
        _ specs: [(silent: Bool, bpm: Double, retentionNotes: Int)]) -> TempoMemoryReport {
        var plan: [MemoryRound] = []
        var cursor = 0.0
        for (i, spec) in specs.enumerated() {
            let retentionStart = cursor + 9.6
            let retentionEnd = retentionStart + 9.6
            let reproduceEnd = retentionEnd + 9.6
            plan.append(MemoryRound(index: i, targetBpm: 100,
                                    condition: spec.silent ? .silent : .filled,
                                    retentionStart: retentionStart, retentionEnd: retentionEnd,
                                    reproduceStart: retentionEnd, reproduceEnd: reproduceEnd))
            cursor = reproduceEnd
        }
        let allTaps = zip(plan, specs).flatMap {
            taps(for: $0.0, producedBpm: $0.1.bpm, retentionNotes: $0.1.retentionNotes)
        }
        return TempoMemoryAnalysis.analyze(taps: allTaps, rounds: plan)
    }

    /// The §7.17 shape: three of four silent waits played through, one of four filled. This is
    /// the take that produced a +1.30 interference cost, which §7.19 then had to retract.
    private var theRetractedShape: [(silent: Bool, bpm: Double, retentionNotes: Int)] {
        [(true, 100, 3), (false, 90, 0), (true, 100, 3), (false, 89, 3),
         (true, 100, 3), (false, 91, 0), (true, 100, 0), (false, 90, 0)]
    }

    // MARK: - Differential attrition (PLAN.md §7.20 finding 2)

    func testAttritionIsCountedPerConditionRatherThanAsOneTotal() {
        let r = reportWithAttrition(theRetractedShape)
        let silent = r.attrition.first { $0.condition == .silent }
        let filled = r.attrition.first { $0.condition == .filled }

        XCTAssertEqual(silent?.playedThrough, 3)
        XCTAssertEqual(filled?.playedThrough, 1)
        // A single total would read "4 rounds" and hide the whole problem.
        XCTAssertNotEqual(silent?.playedThrough, filled?.playedThrough)
    }

    func testUnequalAttritionMakesTheTwoConditionsIncomparable() {
        let r = reportWithAttrition(theRetractedShape)
        XCTAssertTrue(r.attritionIsImbalanced)
        // The headline must not quote a cost from sets that are not describing the same task.
        XCTAssertTrue(r.headline.contains("not scored on comparable sets"), r.headline)
        XCTAssertFalse(r.headline.contains("Interference costs you"), r.headline)
        // Withheld at source, not merely flagged: the chart, the planner and the debrief all
        // derive from this and none of them should need to remember a precondition.
        XCTAssertNil(r.interferenceCost)
        XCTAssertNil(r.interferenceInterval)
        // The per-condition means still stand — each describes its own condition honestly.
        XCTAssertNotNil(r.silentMeanAbsErrorPercent)
        XCTAssertNotNil(r.filledMeanAbsErrorPercent)
    }

    /// The shape of the *stored* takes whose cost §7.19 retracted: a single silent round lost
    /// and no filled one, four rounds each.
    ///
    /// This is the case a count-based threshold gets wrong. §7.17's "3 silent against 1
    /// filled" is that evening's two takes pooled; within one take the gap is one round, so a
    /// rule of "two rounds apart" passes exactly the takes that caused the retraction. At four
    /// rounds per condition, one round is 25 points of attrition.
    func testOneLostRoundOutOfFourIsAlreadyImbalanced() {
        let r = reportWithAttrition([(true, 100, 3), (false, 90, 0), (true, 100, 0), (false, 89, 0),
                                     (true, 100, 0), (false, 91, 0), (true, 100, 0), (false, 90, 0)])
        XCTAssertEqual(r.attrition.first { $0.condition == .silent }?.playedThrough, 1)
        XCTAssertEqual(r.attrition.first { $0.condition == .filled }?.playedThrough, 0)
        XCTAssertTrue(r.attritionIsImbalanced,
                      "one lost round in four is a quarter of the condition, not a rounding error")
    }

    /// The same absolute gap over more rounds is proportionately small and must not trip it,
    /// or a long take could never produce a cost at all.
    func testOneLostRoundOutOfTenIsNotImbalanced() {
        var specs: [(silent: Bool, bpm: Double, retentionNotes: Int)] = []
        for i in 0..<20 {
            specs.append((i % 2 == 0, i % 2 == 0 ? 100 : 90, i == 0 ? 3 : 0))
        }
        let r = reportWithAttrition(specs)
        XCTAssertEqual(r.attrition.first { $0.condition == .silent }?.playedThrough, 1)
        XCTAssertFalse(r.attritionIsImbalanced)
    }

    func testEqualAttritionStillAllowsTheCostToBeStated() {
        // One lost round per condition is attrition, but not *differential* attrition.
        let r = reportWithAttrition([(true, 100, 3), (false, 88, 3), (true, 101, 0), (false, 90, 0),
                                     (true, 99, 0), (false, 89, 0), (true, 100, 0), (false, 91, 0)])
        XCTAssertFalse(r.attritionIsImbalanced)
        XCTAssertFalse(r.headline.contains("not scored on comparable sets"), r.headline)
        XCTAssertNotNil(r.interferenceCost)
    }

    /// A caveat that does not say which way it cuts is not a finding — §7.19's lesson from the
    /// content analysis, applied here.
    func testTheAttritionNoteStatesWhichWayItPushesTheCost() {
        let silentHeavy = reportWithAttrition(theRetractedShape)
        XCTAssertTrue(silentHeavy.notes.contains { $0.contains("overstates the cost") },
                      "losing more silent rounds inflates filled − silent")

        // Mirror image: the distractor is what gets played through.
        let filledHeavy = reportWithAttrition(
            [(true, 100, 0), (false, 90, 3), (true, 100, 0), (false, 89, 3),
             (true, 100, 0), (false, 91, 3), (true, 100, 0), (false, 90, 0)])
        XCTAssertTrue(filledHeavy.attritionIsImbalanced)
        XCTAssertTrue(filledHeavy.notes.contains { $0.contains("understates the cost") },
                      "losing more filled rounds deflates filled − silent")
    }

    func testEveryRoundIsAccountedForExactlyOnce() {
        // A round that was both played through and otherwise unscorable must not be counted
        // twice, or the bookkeeping stops adding up and the imbalance test drifts with it.
        let r = reportWithAttrition(theRetractedShape)
        for entry in r.attrition {
            XCTAssertEqual(entry.scored + entry.playedThrough + entry.otherwiseUnusable,
                           entry.rounds, "\(entry.condition) does not account for its rounds")
        }
        XCTAssertEqual(r.attrition.reduce(0) { $0 + $1.rounds }, r.rounds.count)
    }

    // MARK: - The contrast the drill exists for

    /// Accurate after silence, badly off after the distractor: the period was being held by
    /// attention, not stored. This is the result PLAN §1 predicts for this player and the
    /// first thing in the app that could put a number on it.
    func testInterferenceCostIsDetectedWhenTheDistractorHurts() {
        let r = report([(true, 100), (false, 88), (true, 101), (false, 90),
                        (true, 99), (false, 89), (true, 100), (false, 91)])

        XCTAssertEqual(r.usableCount, 8)
        XCTAssertNotNil(r.interferenceInterval)
        XCTAssertTrue(r.interferenceInterval!.excludesZero)
        XCTAssertGreaterThan(r.interferenceCost ?? 0, 5)
        XCTAssertTrue(r.headline.contains("held by attention"))
    }

    /// Equally accurate either way: the period survived having something else in the gap,
    /// which is what a stored period looks like.
    func testNoCostWhenTheDistractorMakesNoDifference() {
        let r = report([(true, 100), (false, 101), (true, 99), (false, 100),
                        (true, 101), (false, 99), (true, 100), (false, 100)])

        XCTAssertNotNil(r.interferenceInterval)
        XCTAssertFalse(r.interferenceInterval!.excludesZero)
        XCTAssertTrue(r.headline.contains("nothing measurable"))
    }

    /// An empty gap can invite counting, so being *better* after the distractor is a real
    /// possibility rather than an impossible one — the report names it instead of reporting a
    /// negative cost as if it were success.
    func testBeingBetterAfterTheDistractorIsNamedRatherThanHidden() {
        let r = report([(true, 90), (false, 100), (true, 89), (false, 101),
                        (true, 91), (false, 99), (true, 88), (false, 100)])
        XCTAssertLessThan(r.interferenceCost ?? 0, 0)
        XCTAssertTrue(r.headline.contains("more* accurate"))
    }

    // MARK: - What invalidates a round

    /// Playing through the wait keeps the pulse running, so nothing about *storing* it was
    /// tested. That is a different drill, and the round has to say so rather than contribute
    /// a confident number.
    func testPlayingThroughTheWaitInvalidatesTheRound() {
        let r = report([(true, 100), (false, 100), (true, 100), (false, 100)],
                       retentionNotes: 6)

        XCTAssertEqual(r.usableCount, 0)
        XCTAssertTrue(r.rounds.allSatisfy { ($0.unusableReason ?? "").contains("never let go") })
        XCTAssertTrue(r.notes.contains { $0.contains("continuation drill, not this one") })
    }

    /// A stray note or two is a slip, not a failure to do the exercise.
    func testAStrayNoteDuringTheWaitIsTolerated() {
        let r = report([(true, 100), (false, 100), (true, 100), (false, 100)],
                       retentionNotes: 2)
        XCTAssertEqual(r.usableCount, 4)
        XCTAssertEqual(r.rounds.first?.notesDuringRetention, 2)
    }

    /// The scoring rules that reject a mixed-note-value hold are the tempo drill's, reused
    /// rather than reimplemented — so a round that is not one note per beat is rejected here
    /// too, with the same reason.
    func testAMixedNoteValueReproductionIsRejectedByTheSharedScoring() {
        let plan = rounds(count: 2)
        var mixed: [Tap] = []
        var t = plan[0].reproduceStart + 0.01
        var short = true
        while t < plan[0].reproduceEnd {
            mixed.append(Tap(time: t))
            t += short ? 0.2 : 0.9      // wildly uneven, no single period describes it
            short.toggle()
        }
        let r = TempoMemoryAnalysis.analyze(taps: mixed, rounds: plan)
        XCTAssertFalse(r.rounds[0].isUsable)
        XCTAssertEqual(r.rounds[0].unusableReason, "not one note per beat")
    }

    // MARK: - Refusing to conclude

    func testTooFewRoundsPerConditionGivesNoIntervalAndSaysWhy() {
        let r = report([(true, 100), (false, 92), (true, 99), (false, 90)])
        XCTAssertNotNil(r.interferenceCost, "the point estimate is still worth showing")
        XCTAssertNil(r.interferenceInterval)
        XCTAssertTrue(r.notes.contains { $0.contains("before the difference means anything") })
        XCTAssertTrue(r.headline.contains("Too few rounds"))
    }

    func testOneConditionMissingEntirelyIsSaidPlainly() {
        let r = report([(true, 100), (true, 99), (true, 101)])
        XCTAssertNil(r.interferenceCost)
        XCTAssertTrue(r.headline.contains("no filled rounds"))
    }

    func testNothingPlayedAtAllAsksForTheDrillToBeDoneProperly() {
        let r = TempoMemoryAnalysis.analyze(taps: [], rounds: rounds(count: 4))
        XCTAssertEqual(r.usableCount, 0)
        XCTAssertTrue(r.headline.contains("No round could be scored"))
    }

    // MARK: - Mechanics

    func testProducedTempoIsRecoveredFromTheReproductionWindow() {
        let plan = rounds(count: 1)
        let r = TempoMemoryAnalysis.analyze(taps: taps(for: plan[0], producedBpm: 93),
                                            rounds: plan)
        XCTAssertEqual(r.rounds[0].producedBpm ?? 0, 93, accuracy: 0.5)
        XCTAssertEqual(r.rounds[0].errorPercent ?? 0, -7, accuracy: 0.5)
        XCTAssertEqual(r.rounds[0].retentionSeconds, 9.6, accuracy: 1e-9)
    }

    /// Difficulty follows the clock, because that is what the drill trains — not this
    /// drill's own accuracy, which would be circular.
    func testRetentionGrowsWithATightClockAndShrinksWithALooseOne() {
        XCTAssertEqual(TempoMemoryAnalysis.suggestedRetentionBars(current: 4, clockSDms: 8), 8)
        XCTAssertEqual(TempoMemoryAnalysis.suggestedRetentionBars(current: 4, clockSDms: 22), 2)
        XCTAssertEqual(TempoMemoryAnalysis.suggestedRetentionBars(current: 4, clockSDms: 14), 4)
        XCTAssertEqual(TempoMemoryAnalysis.suggestedRetentionBars(current: 4, clockSDms: nil), 4)
        XCTAssertEqual(TempoMemoryAnalysis.suggestedRetentionBars(current: 16, clockSDms: 2), 16)
    }

    func testTheIntervalIsDeterministic() {
        let specs: [(silent: Bool, bpm: Double)] = [(true, 100), (false, 90), (true, 99),
                                                    (false, 91), (true, 101), (false, 89)]
        XCTAssertEqual(report(specs).interferenceInterval, report(specs).interferenceInterval)
    }
}
