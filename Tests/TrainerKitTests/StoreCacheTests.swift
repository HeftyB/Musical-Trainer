import XCTest
@testable import TimingCore
import TestSupport
@testable import TrainerKit

/// The decoded corpus is held for the life of the process, and the ways that could go wrong.
///
/// It is safe only because a stored take is immutable (R6.2) and new ones arrive through `save`
/// alone. Both of those are assumptions about the *rest* of the system, so they are asserted here
/// rather than trusted: a cache that outlives a save would mean a player finishing a take and not
/// finding it in their history, which is worse than the slowness it was added to fix.
final class StoreCacheTests: StoreBackedTestCase {

    func testATakeSavedAfterAReadIsVisibleToTheNextRead() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(dayOffset: 0))
        XCTAssertEqual(SessionStore.loadAll().count, 1, "priming read")

        try SessionStore.save(TakeFactory.jam(dayOffset: 1))
        XCTAssertEqual(SessionStore.loadAll().count, 2, "the save did not invalidate the cache")
    }

    /// Every stored type, because invalidation that covered jams alone would leave the other five
    /// stale — and a form take vanishing is the same defect wearing a different hat.
    func testEveryStoredTypeIsVisibleAfterItsOwnSave() throws {
        assertStoreIsRedirected()
        _ = SessionStore.loadAll()
        _ = SessionStore.loadAllForm()
        _ = SessionStore.loadAllDropout()
        _ = SessionStore.loadAllTempo()
        _ = SessionStore.loadAllMemory()

        try SessionStore.save(TakeFactory.jam())
        try SessionStore.save(TakeFactory.form())
        try SessionStore.save(TakeFactory.dropout())
        try SessionStore.save(TakeFactory.tempo())
        try SessionStore.save(TakeFactory.memory())

        XCTAssertEqual(SessionStore.loadAll().count, 1, "jam")
        XCTAssertEqual(SessionStore.loadAllForm().count, 1, "form")
        XCTAssertEqual(SessionStore.loadAllDropout().count, 1, "dropout")
        XCTAssertEqual(SessionStore.loadAllTempo().count, 1, "tempo")
        XCTAssertEqual(SessionStore.loadAllMemory().count, 1, "memory")
    }

    /// The redirect moving is the other way a cache goes stale, and it is the one every test in
    /// this suite depends on: `StoreBackedTestCase` points the store at a fresh directory per
    /// test, so a cache surviving that would leak one test's takes into the next.
    func testMovingTheStoreDirectoryDropsWhatWasRead() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam())
        XCTAssertEqual(SessionStore.loadAll().count, 1)

        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicalTrainerCacheTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }

        SessionStore.directoryOverride = elsewhere
        XCTAssertEqual(SessionStore.loadAll().count, 0, "the previous directory's takes persisted")

        SessionStore.directoryOverride = storeURL
        XCTAssertEqual(SessionStore.loadAll().count, 1, "moving back lost the take")
    }

    /// A cached read must return what a fresh decode would, not merely something.
    func testACachedReadMatchesAFreshOne() throws {
        assertStoreIsRedirected()
        for day in 0..<3 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }

        let first = SessionStore.loadAll()
        SessionStore.invalidateCache()
        let fresh = SessionStore.loadAll()

        XCTAssertEqual(first.map(\.date), fresh.map(\.date))
        XCTAssertEqual(first.map { $0.report().sdAsynchronyMs },
                       fresh.map { $0.report().sdAsynchronyMs })
    }

    // MARK: The History payload

    /// One pass has to produce exactly what the separate calls did, or the screen quietly starts
    /// showing something the console does not (R3.4).
    func testTheHistoryPayloadMatchesTheReadoutsItReplaces() throws {
        assertStoreIsRedirected()
        for day in 0..<4 { try SessionStore.save(TakeFactory.jam(dayOffset: day)) }
        try SessionStore.save(TakeFactory.jam(offbeatLevel: 0, dayOffset: 4))
        for day in 0..<3 { try SessionStore.save(TakeFactory.form(dayOffset: day)) }

        let jam = TrainerEngine.historyPayload(for: .jam)
        XCTAssertEqual(jam.entries.map(\.date), TrainerEngine.jamHistory().map(\.date))
        XCTAssertEqual(jam.chart.entries.count, TrainerEngine.chartable(jam.entries).entries.count)
        XCTAssertEqual(jam.trends.map(\.title), TrainerEngine.trends(for: .jam).map(\.title))
        XCTAssertEqual(jam.warmUp.takeCount, TrainerEngine.warmUpReport(for: .jam).takeCount)
        XCTAssertEqual(jam.experiments.count, TrainerEngine.experimentResults().count)

        let form = TrainerEngine.historyPayload(for: .form)
        XCTAssertEqual(form.entries.map(\.date), TrainerEngine.formHistory().map(\.date))
        XCTAssertTrue(form.experiments.isEmpty, "only the jam carries experiments")
    }
}
