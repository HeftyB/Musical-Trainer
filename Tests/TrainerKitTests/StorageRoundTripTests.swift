import XCTest
@testable import TimingCore
@testable import TrainerKit

/// Save it, load it back, recompute: the report must not move.
///
/// One property, and it subsumes three separate defect classes this project has already shipped.
/// A field that fails to encode loses the whole take (§7.20 finding 11). A field that decodes to
/// something the analysis reads differently is the cached-summary defect that shipped three
/// times (R3.1). A schema change that orphans history is R6.1. All three fail this by
/// construction, and none of them had a test before.
final class StorageRoundTripTests: StoreBackedTestCase {

    func testAJamSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let original = TakeFactory.jam(tag: "benchmark")
        try SessionStore.save(original)

        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        let before = original.report(), after = loaded.report()

        XCTAssertEqual(after.sdAsynchronyMs, before.sdAsynchronyMs, accuracy: 1e-9)
        XCTAssertEqual(after.meanAsynchronyMs, before.meanAsynchronyMs, accuracy: 1e-9)
        XCTAssertEqual(after.matchedCount, before.matchedCount)
        XCTAssertEqual(loaded.tag, "benchmark")
        // The raw note-ons are what M12 and M13 read; losing them loses the question for good.
        XCTAssertEqual(loaded.playedNotes.count, original.playedNotes.count)
        XCTAssertEqual(loaded.placement?.role, "benchmark")
    }

    func testAFormTakeSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let original = TakeFactory.form()
        try SessionStore.save(original)

        let loaded = try XCTUnwrap(SessionStore.loadAllForm().first)
        XCTAssertEqual(loaded.report().onFormCount, original.report().onFormCount)
        XCTAssertEqual(loaded.markTimes, original.markTimes)
        XCTAssertEqual(loaded.phraseBars, original.phraseBars)
    }

    func testAContinuationTakeSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let original = TakeFactory.dropout()
        try SessionStore.save(original)

        let loaded = try XCTUnwrap(SessionStore.loadAllDropout().first)
        let (t1, g1, s1) = original.reconstruct()
        let (t2, g2, s2) = loaded.reconstruct()
        XCTAssertEqual(t2.map(\.time), t1.map(\.time))
        XCTAssertEqual(g2.bpm, g1.bpm)
        XCTAssertEqual(s2.count, s1.count)
    }

    func testATempoTakeSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let original = TakeFactory.tempo()
        try SessionStore.save(original)

        let loaded = try XCTUnwrap(SessionStore.loadAllTempo().first)
        XCTAssertEqual(loaded.roundWindows.count, original.roundWindows.count)
        XCTAssertEqual(loaded.taps.map(\.time), original.taps.map(\.time))
    }

    func testARecallTakeSurvivesSaveAndReload() throws {
        assertStoreIsRedirected()
        let original = TakeFactory.memory()
        try SessionStore.save(original)

        let loaded = try XCTUnwrap(SessionStore.loadAllMemory().first)
        XCTAssertEqual(loaded.roundWindows.count, original.roundWindows.count)
        XCTAssertEqual(loaded.roundWindows.map(\.condition), original.roundWindows.map(\.condition))
    }

    /// Every take type in one directory, because the prefixes are what keep them apart and a
    /// take decoded as the wrong type would be silent and wrong rather than loud and wrong.
    func testTakeTypesDoNotDecodeAsEachOther() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam())
        try SessionStore.save(TakeFactory.form())
        try SessionStore.save(TakeFactory.dropout())
        try SessionStore.save(TakeFactory.tempo())
        try SessionStore.save(TakeFactory.memory())

        XCTAssertEqual(SessionStore.loadAll().count, 1)
        XCTAssertEqual(SessionStore.loadAllForm().count, 1)
        XCTAssertEqual(SessionStore.loadAllDropout().count, 1)
        XCTAssertEqual(SessionStore.loadAllTempo().count, 1)
        XCTAssertEqual(SessionStore.loadAllMemory().count, 1)
        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
    }

    /// Two takes that finish in the same second are two takes.
    ///
    /// The filename is derived from the take's own date, so both resolved to one path and the
    /// second overwrote the first — a stored take rewritten, which R6.2 forbids outright. Found
    /// by this suite on its first run, saving synthetic takes that shared a timestamp.
    func testTwoTakesWithTheSameTimestampBothSurvive() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(tag: "first"))
        try SessionStore.save(TakeFactory.jam(tag: "second"))

        let loaded = SessionStore.loadAll()
        XCTAssertEqual(loaded.count, 2, "the second take must not overwrite the first")
        XCTAssertEqual(Set(loaded.compactMap(\.tag)), ["first", "second"])
    }

    /// R6.1: every take ever recorded must continue to decode, and the check that proves it has
    /// to be able to fail. For most of its life it could not — `review list` printed a note and
    /// exited 0 (§7.20 finding 6).
    func testACorruptFileIsReportedRatherThanIgnored() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam())
        try Data("{ \"not\": \"a take\" }".utf8)
            .write(to: storeURL.appendingPathComponent("form-20990101-000000.json"))

        let unreadable = SessionStore.unreadableFiles()
        XCTAssertEqual(unreadable.count, 1)
        XCTAssertEqual(unreadable.first?.lastPathComponent, "form-20990101-000000.json")
    }

    /// A file that decodes but contradicts itself is unreadable too (§7.20 finding 8). It used
    /// to trap on the first index out of range while reading history.
    func testASelfContradictoryFileIsUnreadable() throws {
        assertStoreIsRedirected()
        let good = TakeFactory.memory(rounds: 4)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(good)) as? [String: Any])
        // One more condition than there are round windows.
        json["roundConditions"] = ["silent", "filled", "silent", "filled", "silent"]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: storeURL.appendingPathComponent("memory-20990101-000000.json"))

        XCTAssertEqual(SessionStore.unreadableFiles().count, 1)
        XCTAssertTrue(SessionStore.loadAllMemory().isEmpty,
                      "a self-contradictory take must not load as though it were fine")
    }
}
