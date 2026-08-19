import XCTest
import TestSupport
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// A trend is fitted over one band, not over a band that changed every evening.
///
/// The closing jam rotates its style between sittings and keeps one seed within a sitting (§7.29),
/// so without this every evening would drop a new `grooveName` into "Jams at 100 BPM" — a warning
/// growing an entry each time and a line fitted across music sharing nothing but a tempo. That is
/// the defect §7.24 step 8 and §7.27 retracted three verdicts for: naming a confound is the floor,
/// separating it is the fix (R3.4 against R3.5, `LESSONS.md` shape 19).
///
/// The split is fixed against generated, and the generated side keys on the **style** rather than
/// the seed. Keying on the seed would make every take a group of one — `minimumPoints` is 3 — and
/// take the 21-take free-jam series with it. See JOURNAL.md §7.29 step 7.
final class GeneratedBackingTrendTests: StoreBackedTestCase {

    private func driving(_ seed: UInt64) -> BackingIdentity {
        BackingIdentity(style: "driving", seed: seed)
    }

    // MARK: - What the group key does

    func testAFixedNameAndAGeneratedOneAreDifferentGroups() {
        XCTAssertEqual(BackingGroup(grooveName: "jamBacking"), .fixed)
        XCTAssertEqual(BackingGroup(grooveName: "basicRock"), .fixed)
        XCTAssertEqual(BackingGroup(grooveName: "offbeat-2"), .fixed)
        XCTAssertEqual(BackingGroup(grooveName: driving(1).name), .style("driving"))
    }

    /// **The preservation guarantee.** Every fixed backing is one bucket, so `basicRock` beside
    /// `jamBacking` pools exactly as it did before this change — 21 takes, one warning naming the
    /// mix. Splitting them is a defensible readout and a different one, and re-scoring the
    /// project's headline series while building something else is how a finding gets attributed to
    /// the wrong cause.
    func testEveryFixedBackingStaysInOneBucket() {
        let fixed = ["jamBacking", "basicRock", "ladder-eighths", "offbeat-0"]
        XCTAssertEqual(Set(fixed.map(BackingGroup.init(grooveName:))), [.fixed])
    }

    func testTwoSeedsOfOneStyleAreTheSameGroupAndTwoStylesAreNot() {
        XCTAssertEqual(BackingGroup(grooveName: driving(1).name),
                       BackingGroup(grooveName: driving(999).name))
        XCTAssertNotEqual(
            BackingGroup(grooveName: driving(1).name),
            BackingGroup(grooveName: BackingIdentity(style: "pocket", seed: 1).name))
    }

    /// A fixed group's title has to be byte-identical to what it has always printed, or every
    /// figure quoted against "Jams at 100 BPM" stops matching the readout it came from.
    func testAFixedGroupAddsNothingToItsTitle() {
        XCTAssertEqual(BackingGroup.fixed.label, "")
        XCTAssertEqual(BackingGroup.style("driving").label, ", driving")
    }

    // MARK: - End to end, through the path that ships

    func testGeneratedTakesDoNotJoinTheFreeJamTrend() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        for day in 3..<6 {
            try SessionStore.save(TakeFactory.jam(generatedBacking: driving(0xA), dayOffset: day))
        }

        let series = TrainerEngine.trends(for: .jam)
        XCTAssertEqual(series.count, 2, "got \(series.map(\.title))")
        XCTAssertEqual(series.map(\.takeCount), [3, 3])
        XCTAssertEqual(series.first?.title, "Jams at 100 BPM",
                       "the fixed group's title may never move")
        XCTAssertTrue(series.last?.title.hasSuffix(", driving") == true,
                      "a generated group names its style: \(series.map(\.title))")
    }

    func testTwoStylesAreFittedApart() throws {
        assertStoreIsRedirected()
        for day in 0..<3 {
            try SessionStore.save(TakeFactory.jam(generatedBacking: driving(1), dayOffset: day))
        }
        for day in 3..<6 {
            try SessionStore.save(TakeFactory.jam(
                generatedBacking: BackingIdentity(style: "pocket", seed: 1), dayOffset: day))
        }
        XCTAssertEqual(TrainerEngine.trends(for: .jam).count, 2,
                       "a different band is a different task")
    }

    /// The point of keying on the style: a series survives the seed rotating. Three sittings of
    /// `driving` on three seeds is one fittable group, not three groups of one.
    func testSeedsRotatingWithinAStyleStillFitOneLine() throws {
        assertStoreIsRedirected()
        for (day, seed) in [(0, UInt64(1)), (1, 2), (2, 3)] {
            try SessionStore.save(TakeFactory.jam(generatedBacking: driving(seed), dayOffset: day))
        }
        let series = TrainerEngine.trends(for: .jam)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.takeCount, 3)
        XCTAssertNotNil(series.first?.rows.first?.fit,
                        "three points is what a fit needs; keying on the seed would give three "
                      + "groups of one and no fit at all")
    }

    /// **And it says the pool is provisional.** Two seeds of one style share the tempo, density,
    /// instrumentation and backbeat, and the generator never invents or moves a hit — but that is
    /// an argument and not a measurement, because no take over a generated backing existed when
    /// this was written. R3.3: when a measurement cannot be fully trusted, say so and say why.
    func testAPoolOfSeedsSaysItHasNeverBeenMeasured() throws {
        assertStoreIsRedirected()
        for (day, seed) in [(0, UInt64(1)), (1, 2), (2, 3)] {
            try SessionStore.save(TakeFactory.jam(generatedBacking: driving(seed), dayOffset: day))
        }
        let warnings = try XCTUnwrap(TrainerEngine.trends(for: .jam).first).warnings
        XCTAssertTrue(warnings.contains { $0.contains("3 seeds of driving") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("never been measured") },
                      "a pool nobody has checked must not read as settled: \(warnings)")
    }

    /// One seed is one piece of music, so there is nothing to caveat and nothing is said.
    func testOneSeedCarriesNoSeedWarning() throws {
        assertStoreIsRedirected()
        for day in 0..<3 {
            try SessionStore.save(TakeFactory.jam(generatedBacking: driving(7), dayOffset: day))
        }
        let warnings = try XCTUnwrap(TrainerEngine.trends(for: .jam).first).warnings
        XCTAssertFalse(warnings.contains { $0.contains("seeds of") }, "\(warnings)")
    }

    // MARK: - review tags

    /// `TakeAxis` gains a *style* axis beside the backing one, and it fires on strictly less. Two
    /// seeds differ as backings — different pieces — but not as bands.
    func testTheStyleAxisIsSilentOnEveryTakeRecordedBeforeM19() {
        let fixed = [TakeFactory.jam(), TakeFactory.jam(offbeatLevel: 1)]
        let style = TakeAxis.all.first { $0.plural == "styles" }
        XCTAssertNotNil(style)
        XCTAssertEqual(Set(fixed.map { style?.value($0) }).count, 1,
                       "the whole existing corpus is one value here, so this axis says nothing "
                     + "about it and `review tags` reads exactly as it did")
    }

    func testSeedsMixAsBackingsAndStylesDoNotMixAsSeeds() {
        let seeds = [TakeFactory.jam(generatedBacking: driving(1)),
                     TakeFactory.jam(generatedBacking: driving(2))]
        let mixed = TakeAxis.mixed(in: seeds).map(\.plural)
        XCTAssertTrue(mixed.contains("backings"), "two seeds are two pieces of music: \(mixed)")
        XCTAssertFalse(mixed.contains("styles"), "two seeds are one band: \(mixed)")

        let bands = [TakeFactory.jam(generatedBacking: driving(1)),
                     TakeFactory.jam(generatedBacking: BackingIdentity(style: "pocket", seed: 1))]
        XCTAssertTrue(TakeAxis.mixed(in: bands).map(\.plural).contains("styles"))
    }
}
