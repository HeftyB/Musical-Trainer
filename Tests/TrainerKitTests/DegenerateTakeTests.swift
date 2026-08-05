import XCTest
@testable import TimingCore
@testable import TrainerKit

/// The worst take of the evening must still be storable.
///
/// This is a matrix rather than a list of remembered cases, and the distinction is the whole
/// point. Finding 11 was one cell of it — a form drill with no marks — and it was found by
/// destroying a real take in a live session rather than by anything here.
///
/// The inversion is what makes it worth being systematic: a take is lost exactly when it went
/// *badly*, because that is when there are too few marks, usable trials or matched notes to
/// compute a summary. The takes being discarded were the most diagnostic ones in the set.
final class DegenerateTakeTests: StoreBackedTestCase {

    /// Every pathology worth generating, named so a failure says which one broke.
    private var pathologies: [(name: String, performance: TakeFactory.Performance)] {
        [("nothing played", .silent),
         ("a single note", .oneNote),
         ("everything off the grid", .init(beats: 64, biasMs: 0, spreadMs: 2, offGridRate: 1)),
         ("wild spread", .init(beats: 64, biasMs: 0, spreadMs: 400)),
         ("block chords only", .init(beats: 64, spreadMs: 8, chordSize: 4)),
         ("running away", .init(beats: 64, biasMs: 0, spreadMs: 6, driftMsPerBeat: 8))]
    }

    func testEveryDegenerateJamCanBeSavedAndReloaded() throws {
        assertStoreIsRedirected()
        for (name, performance) in pathologies {
            let take = TakeFactory.jam(performance)
            XCTAssertNoThrow(try SessionStore.save(take), "a jam with \(name) must still save")
        }
        XCTAssertEqual(SessionStore.loadAll().count, pathologies.count)
        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
    }

    func testEveryDegenerateContinuationTakeCanBeSaved() throws {
        assertStoreIsRedirected()
        for (name, performance) in pathologies {
            XCTAssertNoThrow(try SessionStore.save(TakeFactory.dropout(performance)),
                             "a continuation take with \(name) must still save")
        }
        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
    }

    /// The exact take lost on 5 August 2026: level 2, no landmarks, and the player never
    /// committed to a phrase top. `phaseErrorMeanMs` is NaN and `JSONEncoder` refused it.
    func testAFormTakeWithNoMarksSaves() throws {
        assertStoreIsRedirected()
        let take = TakeFactory.form(marks: 0, level: 2)
        XCTAssertNil(Stats.finite(take.report().phaseErrorMeanMs),
                     "the analysis really does produce a non-finite phase error here")
        XCTAssertNoThrow(try SessionStore.save(take))
        XCTAssertEqual(SessionStore.loadAllForm().count, 1)
    }

    func testAFormTakeWithOneMarkSaves() throws {
        assertStoreIsRedirected()
        // One mark: the mean exists, the SD does not.
        XCTAssertNoThrow(try SessionStore.save(TakeFactory.form(marks: 1)))
        XCTAssertEqual(SessionStore.loadAllForm().count, 1)
    }

    func testTakesWithNoRoundsSave() throws {
        assertStoreIsRedirected()
        XCTAssertNoThrow(try SessionStore.save(TakeFactory.tempo(rounds: 0)))
        XCTAssertNoThrow(try SessionStore.save(TakeFactory.memory(rounds: 0)))
        XCTAssertTrue(SessionStore.unreadableFiles().isEmpty)
    }

    /// The general statement, rather than one field at a time: nothing non-finite reaches disk.
    ///
    /// `Stats.mean` and `Stats.sd` return `.nan` for "not computable from this input", which is
    /// honest in memory and fatal in JSON. Any new summary field that skips `Stats.finite`
    /// fails here rather than in a live session.
    func testNoStoredSummaryIsEverNonFinite() throws {
        assertStoreIsRedirected()
        for (_, performance) in pathologies {
            try SessionStore.save(TakeFactory.jam(performance))
            try SessionStore.save(TakeFactory.dropout(performance))
        }
        try SessionStore.save(TakeFactory.form(marks: 0))

        for url in try FileManager.default.contentsOfDirectory(at: storeURL,
                                                               includingPropertiesForKeys: nil) {
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in ["nan", "NaN", "inf", "Infinity"] {
                XCTAssertFalse(text.contains(token),
                               "\(url.lastPathComponent) contains \(token)")
            }
        }
    }
}
