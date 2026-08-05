import XCTest
import TestSupport
@testable import TimingCore
@testable import TrainerKit

/// A take is re-analysed on the grid it was measured on, not on a constant that happens to match.
///
/// The defect this closes (PLAN.md §7.23, step 0): a jam was analysed on
/// `Grid(subdivisions: backing.stepsPerBeat)` and stored with a hardcoded `4`, while
/// `reconstruct()` rebuilt from the stored value. They agreed only because `Pattern` defaults to
/// 4. Since everything recomputes from raw taps (R3.1), the first backing with a different step
/// count would have moved every number for those takes between the live report and the review —
/// silently, and in a direction nobody would think to check.
///
/// M14 exists to vary exactly that, which is why this is its step 0 rather than a later tidy-up.
final class GridSubdivisionTests: StoreBackedTestCase {

    func testAJamIsRebuiltOnTheSubdivisionItWasStoredWith() throws {
        assertStoreIsRedirected()
        let wanted = [1, 2, 3, 4]
        for subdivisions in wanted {
            let take = TakeFactory.jam(grid: Grid(startTime: 1_000, bpm: 100,
                                                  subdivisions: subdivisions))
            XCTAssertEqual(take.reconstruct().grid.subdivisions, subdivisions)
            try SessionStore.save(take)
        }
        // Compared as a set: the factory gives every take the same date, so load order is not
        // save order and picking "the last one" would be testing the sort, not the storage.
        let loaded = Set(SessionStore.loadAll().map { $0.reconstruct().grid.subdivisions })
        XCTAssertEqual(loaded, Set(wanted))
    }

    /// What a wrong subdivision actually costs, which is not what it first looks like.
    ///
    /// For notes played *on the beat* the subdivision changes nothing: the beat is a grid point
    /// at every subdivision, so the asynchrony and the spread come out identical. The first
    /// version of this test asserted they differed and failed — correctly.
    ///
    /// It bites on notes played *between* beats. An eighth-note offbeat is 300 ms from the
    /// nearest quarter-note grid point at 100 BPM, well outside the ±240 ms window, so a coarse
    /// grid throws it away as off-grid instead of scoring it. A take reconstructed one rung too
    /// coarse therefore silently discards half the performance and reports the survivors.
    func testACoarseGridDiscardsOffbeatNotesRatherThanScoringThem() {
        let beat = 0.6                                   // 100 BPM
        let onAndOffBeats = (0..<64).map { i -> Tap in
            Tap(time: 1_000 + Double(i) * beat / 2 + 0.002)      // straight eighths
        }
        let asEighths = TimingAnalysis.analyze(
            taps: onAndOffBeats, grid: Grid(startTime: 1_000, bpm: 100, subdivisions: 2))
        let asQuarters = TimingAnalysis.analyze(
            taps: onAndOffBeats, grid: Grid(startTime: 1_000, bpm: 100, subdivisions: 1))

        XCTAssertEqual(asEighths.matchedCount, 64, "every eighth lands on an eighth-note grid")
        XCTAssertEqual(asQuarters.matchedCount, 32, "the offbeats fall outside every window")
        XCTAssertEqual(asQuarters.extraCount, 32, "and are counted as extras, not as timing")
    }

    func testAFormTakeIsRebuiltOnItsOwnSubdivision() throws {
        assertStoreIsRedirected()
        let take = TakeFactory.form()
        try SessionStore.save(take)
        let loaded = try XCTUnwrap(SessionStore.loadAllForm().first)
        XCTAssertEqual(loaded.subdivisions, take.subdivisions)
        XCTAssertEqual(loaded.report().marksPlaced, take.report().marksPlaced)
    }

    func testAContinuationTakeIsRebuiltOnItsOwnSubdivision() throws {
        assertStoreIsRedirected()
        let take = TakeFactory.dropout()
        try SessionStore.save(take)
        let loaded = try XCTUnwrap(SessionStore.loadAllDropout().first)
        XCTAssertEqual(loaded.reconstruct().grid.subdivisions,
                       take.reconstruct().grid.subdivisions)
    }

    /// Every take on disk today predates the field. R6.1 says all of them keep decoding, and
    /// they must also keep producing the *same* numbers — a fallback that guessed differently
    /// would rewrite history rather than preserve it.
    func testTakesRecordedBeforeTheFieldFallBackToWhatTheyWereScoredOn() throws {
        assertStoreIsRedirected()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var form = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(TakeFactory.form())) as? [String: Any])
        form.removeValue(forKey: "subdivisions")
        try JSONSerialization.data(withJSONObject: form)
            .write(to: storeURL.appendingPathComponent("form-20260731-121648.json"))

        var dropout = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(TakeFactory.dropout())) as? [String: Any])
        dropout.removeValue(forKey: "subdivisions")
        try JSONSerialization.data(withJSONObject: dropout)
            .write(to: storeURL.appendingPathComponent("dropout-20260731-121648.json"))

        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
        XCTAssertEqual(try XCTUnwrap(SessionStore.loadAllForm().first).subdivisions ?? 4, 4,
                       "form was always scored at 4")
        XCTAssertEqual(try XCTUnwrap(SessionStore.loadAllDropout().first)
                        .reconstruct().grid.subdivisions, 1, "continuation was always quarters")
    }
}
