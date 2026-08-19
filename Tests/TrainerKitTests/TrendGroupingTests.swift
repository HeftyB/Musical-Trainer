import XCTest
import TestSupport
@testable import TimingCore
@testable import TrainerKit

/// Every trend is fitted over one task, not over a task that changed.
///
/// Jams have been grouped since M7. The other four drills warned instead, in words that made the
/// case themselves — *"a longer silence is a harder task"*, *"a trend here reflects the ladder as
/// much as you"* — and then fitted the line anyway. Naming a confound is R3.4; not computing the
/// verdict across it is R3.5, and a reader shown a verdict and a caveat has still been shown a
/// verdict. See JOURNAL.md §7.27.
final class TrendGroupingTests: StoreBackedTestCase {

    private func titles(_ kind: TrainerEngine.DrillKind) -> [String] {
        TrainerEngine.trends(for: kind).map(\.title)
    }

    // MARK: - The continuation drill

    func testSilenceLengthsAreNotFittedTogether() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.dropout(silentBars: 4, dayOffset: day)) }
        for day in 3..<6 { try SessionStore.save(TakeFactory.dropout(silentBars: 8, dayOffset: day)) }

        let series = TrainerEngine.trends(for: .dropout)
        XCTAssertEqual(series.count, 2, "got \(series.map(\.title))")
        XCTAssertEqual(series.map(\.takeCount), [3, 3])
        XCTAssertTrue(series.allSatisfy { $0.title.contains("bar silences") }, "\(titles(.dropout))")
    }

    func testTheRungSplitsTheContinuationTrendToo() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.dropout(dayOffset: day)) }
        for day in 3..<6 {
            try SessionStore.save(TakeFactory.dropout(rung: .eighths, dayOffset: day))
        }
        XCTAssertEqual(TrainerEngine.trends(for: .dropout).count, 2,
                       "two notes per beat is a different task from one — §7.23 trap 3")
    }

    /// The asymmetry, and the reason it is decided by the instructions rather than the field.
    ///
    /// A jam with no rung says *play what you like*, which is not quarters. The continuation
    /// drill has demanded one note per beat in words since M6, and `DrillInstructions.dropout`
    /// returns the same text for `nil` and for `.quarters` — so the player was set the same task
    /// and the takes belong in one group. Splitting them would invent a distinction never shown.
    func testAnAbsentRungIsQuartersForThisDrillUnlikeAJam() throws {
        assertStoreIsRedirected()
        XCTAssertEqual(DrillInstructions.dropout(rung: nil).steps,
                       DrillInstructions.dropout(rung: .quarters).steps,
                       "if these ever differ, the grouping below stops being justified")

        for day in 0..<2 { try SessionStore.save(TakeFactory.dropout(dayOffset: day)) }
        for day in 2..<4 {
            try SessionStore.save(TakeFactory.dropout(rung: .quarters, dayOffset: day))
        }

        let series = TrainerEngine.trends(for: .dropout)
        XCTAssertEqual(series.count, 1, "got \(series.map(\.title))")
        XCTAssertEqual(series.first?.takeCount, 4)
    }

    // MARK: - The other drills

    func testFormLevelsAreNotFittedTogether() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.form(level: 1, dayOffset: day)) }
        for day in 3..<6 { try SessionStore.save(TakeFactory.form(level: 2, dayOffset: day)) }

        // Indexed only after a `guard`: `XCTAssertEqual` does not stop the test, so asserting
        // the count and then subscripting turns a failure into an out-of-range trap that takes
        // the whole run down with it — §7.24 step 6, and it happened again writing this file.
        let series = TrainerEngine.trends(for: .form)
        guard series.count == 2 else {
            return XCTFail("expected one series per level, got \(series.map(\.title))")
        }
        XCTAssertTrue(series[0].title.contains("level 1"), series[0].title)
        XCTAssertTrue(series[1].title.contains("level 2"), series[1].title)
    }

    func testFormPhraseLengthsAreNotFittedTogether() throws {
        assertStoreIsRedirected()
        for day in 0..<2 { try SessionStore.save(TakeFactory.form(phraseBars: 8, dayOffset: day)) }
        for day in 2..<4 { try SessionStore.save(TakeFactory.form(phraseBars: 4, dayOffset: day)) }
        XCTAssertEqual(TrainerEngine.trends(for: .form).count, 2)
    }

    func testRecallWaitLengthsAreNotFittedTogether() throws {
        assertStoreIsRedirected()
        for day in 0..<2 {
            try SessionStore.save(TakeFactory.memory(retentionBars: 2, dayOffset: day))
        }
        for day in 2..<4 {
            try SessionStore.save(TakeFactory.memory(retentionBars: 8, dayOffset: day))
        }
        XCTAssertEqual(TrainerEngine.trends(for: .memory).count, 2)
    }

    /// Splits nothing on today's data — every tempo take targets 100 — and is here because
    /// M14's ladder rotates tempo between sittings by design. Three of four sites fixed is how
    /// a rule comes to be half-applied.
    func testRotatingTempoTargetsAreNotFittedWithAFixedOne() throws {
        assertStoreIsRedirected()
        for day in 0..<2 { try SessionStore.save(TakeFactory.tempo(targets: [100], dayOffset: day)) }
        for day in 2..<4 {
            try SessionStore.save(TakeFactory.tempo(targets: [90, 110], dayOffset: day))
        }
        XCTAssertEqual(TrainerEngine.trends(for: .tempo).count, 2)
    }

    // MARK: - Nothing was lost

    func testASingleTaskStillProducesOneSeries() throws {
        assertStoreIsRedirected()
        for day in 0..<4 { try SessionStore.save(TakeFactory.dropout(dayOffset: day)) }
        let series = TrainerEngine.trends(for: .dropout)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.takeCount, 4)
        XCTAssertEqual(series.first?.rows.count, 2, "both metrics survive the grouping")
    }

    func testGroupsTooSmallToFitSaySoRatherThanFitting() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.dropout(silentBars: 4))
        try SessionStore.save(TakeFactory.dropout(silentBars: 16, dayOffset: 1))

        let series = TrainerEngine.trends(for: .dropout)
        XCTAssertEqual(series.count, 2)
        XCTAssertTrue(series.allSatisfy { $0.rows.allSatisfy { $0.fit == nil } },
                      "one take per group is not a trend, and the visible cost of splitting")
    }
}
