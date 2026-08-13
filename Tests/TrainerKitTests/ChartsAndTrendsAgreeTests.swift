import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// The picture and the verdict have to be about the same takes.
///
/// The app's history chart drew **one line through every take of a drill** while the trend cards
/// under it split the same takes by tempo, rung, feel, offbeat level and backing, and warned about
/// the confounds. A reader who sees one line has been shown one line — R3.4 is the floor and R3.5
/// is the fix (`LESSONS.md` shape 19), and the cards had already had the fix while the chart above
/// them had not.
///
/// So `HistoryEntry.group` is the title of the `TrendSeries` that take contributes to, and the
/// property asserted here is that those two sets are the same. It fails if either side starts
/// grouping differently, which is the way this drifts back (`LESSONS.md` shape 9): two answers to
/// "which takes belong together" is one answer too many.
final class ChartsAndTrendsAgreeTests: StoreBackedTestCase {

    /// Every group a chart would draw is a group the cards fit, and the other way round.
    private func assertGroupsAgree(_ kind: TrainerEngine.DrillKind,
                                   _ entries: [TrainerEngine.HistoryEntry],
                                   file: StaticString = #filePath, line: UInt = #line) {
        let charted = Set(entries.map(\.group))
        let fitted = Set(TrainerEngine.trends(for: kind).map(\.title))
        XCTAssertFalse(charted.isEmpty, "no takes to group", file: file, line: line)
        XCTAssertEqual(charted, fitted,
                       "the chart would draw \(charted.sorted()) and the cards fit "
                     + "\(fitted.sorted())", file: file, line: line)
    }

    // MARK: Jams — the group with the most axes, and the one a retraction came from

    /// The §7.24 step 8 shape: an offbeat take is a different task and must not share a line with
    /// free jams, however it is drawn.
    func testAnOffbeatTakeIsNotChartedOnTheSameLineAsAFreeJam() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(dayOffset: 0))
        try SessionStore.save(TakeFactory.jam(dayOffset: 1))
        try SessionStore.save(TakeFactory.jam(offbeatLevel: 0, dayOffset: 2))

        let entries = TrainerEngine.jamHistory()
        XCTAssertEqual(entries.count, 3)
        let free = Set(entries.prefix(2).map(\.group))
        XCTAssertEqual(free.count, 1, "two free jams at one tempo are one group")
        XCTAssertFalse(free.contains(entries[2].group),
                       "the offbeat take joined the free jams' line: \(entries[2].group)")
        assertGroupsAgree(.jam, entries)
    }

    /// Tempo, rung and feel each split a line, exactly as they each split a card.
    func testEachConfoundAxisSplitsTheChartAsItSplitsTheFit() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(dayOffset: 0))
        try SessionStore.save(TakeFactory.jam(grid: TakeFactory.grid(bpm: 120), dayOffset: 1))
        try SessionStore.save(TakeFactory.jam(rung: .eighths, dayOffset: 2))
        try SessionStore.save(TakeFactory.jam(rung: .eighths, feel: .swung, dayOffset: 3))

        let entries = TrainerEngine.jamHistory()
        XCTAssertEqual(Set(entries.map(\.group)).count, 4,
                       "four different tasks were charted as \(Set(entries.map(\.group)).count)")
        assertGroupsAgree(.jam, entries)
    }

    // MARK: The other four drills, so the rule is not applied to one of five

    /// §7.20 finding 2's lesson: fixing three of four sites is how a rule comes to be
    /// half-applied. Each of these splits on the axis its own trend splits on.
    func testEveryDrillsChartGroupsTheWayItsTrendDoes() throws {
        assertStoreIsRedirected()

        try SessionStore.save(TakeFactory.form(phraseBars: 8, level: 0, dayOffset: 0))
        try SessionStore.save(TakeFactory.form(phraseBars: 8, level: 2, dayOffset: 1))
        try SessionStore.save(TakeFactory.form(phraseBars: 16, level: 2, dayOffset: 2))
        assertGroupsAgree(.form, TrainerEngine.formHistory())

        try SessionStore.save(TakeFactory.dropout(silentBars: 4, dayOffset: 0))
        try SessionStore.save(TakeFactory.dropout(silentBars: 8, dayOffset: 1))
        assertGroupsAgree(.dropout, TrainerEngine.dropoutHistory())

        try SessionStore.save(TakeFactory.tempo(targets: [100], dayOffset: 0))
        try SessionStore.save(TakeFactory.tempo(targets: [76, 100, 132], dayOffset: 1))
        assertGroupsAgree(.tempo, TrainerEngine.tempoHistory())

        try SessionStore.save(TakeFactory.memory(retentionBars: 4, dayOffset: 0))
        try SessionStore.save(TakeFactory.memory(retentionBars: 8, dayOffset: 1))
        assertGroupsAgree(.memory, TrainerEngine.memoryHistory())
    }

    // MARK: The form drill's second axis reaches the trend

    /// §7.40 made `cleanRate` a peer of `onFormRate` in the report, the planner's input and both
    /// readouts. The trend was not on that list, so the one readout that answers "is this
    /// improving" answered it for the spatial axis alone — while M16 exists to train the temporal
    /// one and its ladder is promoted on exactly this number (§7.41).
    func testTheFormTrendFitsBothAxesRatherThanOnlyTheOneThePlayerIsGoodAt() throws {
        assertStoreIsRedirected()
        for day in 0..<4 {
            try SessionStore.save(TakeFactory.form(phraseBars: 8, level: 2, dayOffset: day))
        }

        let series = try XCTUnwrap(TrainerEngine.trends(for: .form).first)
        XCTAssertEqual(series.rows.map(\.label), ["on-form rate", "clean rate"])
        for row in series.rows {
            XCTAssertEqual(row.values.count, 4, "\(row.label) lost points")
            XCTAssertFalse(row.lowerIsBetter, "\(row.label): more of both is better")
        }
    }

    // MARK: The titles themselves

    /// Moving the group titles onto the key types was meant to change nothing a reader sees, and
    /// "meant to" is not a verification (`LESSONS.md` shape 4). These are transcribed from the
    /// readout rather than rebuilt from the code under test, so a reworded title fails here
    /// instead of quietly renaming a group somebody has quoted a figure against.
    func testTheTrendGroupsAreStable() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        try SessionStore.save(TakeFactory.jam(rung: .eighths, feel: .swung, dayOffset: 3))
        try SessionStore.save(TakeFactory.jam(offbeatLevel: 1, dayOffset: 4))
        for day in 0..<3 { try SessionStore.save(TakeFactory.form(phraseBars: 8, level: 2,
                                                                  dayOffset: day)) }
        try SessionStore.save(TakeFactory.dropout(silentBars: 4))
        try SessionStore.save(TakeFactory.tempo(targets: [76, 100, 132]))
        try SessionStore.save(TakeFactory.memory(retentionBars: 8))

        let titles = Set(TrainerEngine.trends().map(\.title))
        for expected in ["Jams at 100 BPM",
                         "Jams at 100 BPM, eighths, swung (2:1)",
                         "Jams at 100 BPM, offbeat level 1 — kick on 1 only",
                         "Form drill — level 2, 8-bar phrases",
                         "Continuation drill — 4-bar silences, quarter notes",
                         "Tempo drill — 76/100/132 BPM",
                         "Recall drill — 8-bar waits"] {
            XCTAssertTrue(titles.contains(expected), "missing \"\(expected)\" — got \(titles.sorted())")
        }
    }

    // MARK: What the chart draws

    /// Grouping honestly is not enough on its own — this player's jams fall into eighteen groups,
    /// thirteen of them a single take. The chart draws what the cards fit, and says what it left
    /// out rather than dropping it in silence (R3.3).
    func testTheChartDrawsOnlyGroupsBigEnoughToFitAndCountsWhatItLeavesOut() throws {
        assertStoreIsRedirected()
        for day in 0..<4 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        // Two one-take groups: a different tempo and the offbeat drill.
        try SessionStore.save(TakeFactory.jam(grid: TakeFactory.grid(bpm: 120), dayOffset: 4))
        try SessionStore.save(TakeFactory.jam(offbeatLevel: 0, dayOffset: 5))

        let chart = TrainerEngine.chartable(TrainerEngine.jamHistory())
        XCTAssertEqual(Set(chart.entries.map(\.group)).count, 1,
                       "only the group with enough takes should be drawn")
        XCTAssertEqual(chart.entries.count, 4)
        XCTAssertEqual(chart.omittedTakes, 2)
        XCTAssertEqual(chart.omittedGroups, 2)
    }

    /// Every group the chart draws is one the cards fit — the two thresholds are the same rule,
    /// not two numbers that happen to agree (`LESSONS.md` shape 9).
    func testEveryChartedGroupIsAGroupTheCardsActuallyFit() throws {
        assertStoreIsRedirected()
        for day in 0..<4 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        try SessionStore.save(TakeFactory.jam(grid: TakeFactory.grid(bpm: 120), dayOffset: 4))

        let charted = Set(TrainerEngine.chartable(TrainerEngine.jamHistory()).entries.map(\.group))
        let fittedGroups = Set(TrainerEngine.trends(for: .jam)
            .filter { series in series.rows.contains { $0.fit != nil } }
            .map(\.title))
        XCTAssertEqual(charted, fittedGroups)
    }

    /// A take whose metric cannot be computed is not a point on a chart, and it must not take a
    /// whole group down with it either — it is counted as omitted like any other.
    func testAnUnplottableTakeIsOmittedRatherThanDrawnAtZero() {
        let entries = (0..<4).map { i in
            TrainerEngine.HistoryEntry(
                date: Date(timeIntervalSince1970: 1_770_000_000 + Double(i) * 86_400),
                title: "t", detail: "d", feelRating: nil, headline: "h",
                metric: i == 3 ? .nan : Double(i), metricLabel: "m", group: "one group")
        }
        let chart = TrainerEngine.chartable(entries)
        XCTAssertEqual(chart.entries.count, 3, "the non-finite take should not be drawn")
        XCTAssertEqual(chart.omittedTakes, 1)
        XCTAssertTrue(chart.entries.allSatisfy { $0.metric.isFinite })
    }

    /// Both axes are fitted over the same takes, so a group with enough points for one has enough
    /// for the other. A row silently carrying fewer points would make the two verdicts describe
    /// different histories under one heading.
    func testBothFormAxesAreFittedOverTheSameTakes() throws {
        assertStoreIsRedirected()
        for day in 0..<5 {
            try SessionStore.save(TakeFactory.form(phraseBars: 8, level: 2, dayOffset: day))
        }

        let series = try XCTUnwrap(TrainerEngine.trends(for: .form).first)
        let counts = series.rows.map { $0.fit?.pointCount }
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[0], counts[1], "the two axes were fitted over different takes")
    }
}
