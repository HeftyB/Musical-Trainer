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
