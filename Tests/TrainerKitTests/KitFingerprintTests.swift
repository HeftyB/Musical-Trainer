import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// Which kit a take heard, and why it is derived rather than declared.
///
/// **The kit has already changed under the corpus and nothing recorded it** (§7.61). On 7 August
/// every one-shot gained a fade — a truncation click an ear had named — and every style's timekeeper
/// gained accents. Takes either side of that heard different bands under the same groove name, and
/// `BackingGroup` keys on the name.
///
/// M26 is about to change every voice at once, so the field lands before the change rather than
/// after it: a take recorded without it is lost to the question for good (R6.3).
final class KitFingerprintTests: StoreBackedTestCase {

    private func ramp(_ n: Int, scale: Float = 1) -> [Float] {
        (0..<n).map { Float($0) / Float(n) * scale }
    }

    // MARK: The digest

    /// **Pinned to a literal**, which is the point of the test rather than a convenience. Swift's
    /// `Hasher` is seeded per process and would give a different answer every launch, so every take
    /// would record a kit nobody else had ever heard. A hardcoded expectation fails the day someone
    /// swaps the implementation for one that is not stable across runs.
    ///
    /// The value is read off this implementation rather than derived independently, so it checks
    /// *stability* and not correctness — which is the property being claimed. What it cannot catch
    /// is a digest that is stable and weak; `BackingKit.digest`'s FNV-1a is not cryptographic and
    /// does not need to be, since nothing adversarial writes a kit.
    func testTheDigestIsStableAcrossRunsAndNotJustWithinOne() {
        XCTAssertEqual(BackingKit.digest([[0, 0.5, -0.25]]), "a2aa3d5dd969")
    }

    func testTheSameVoicesAlwaysDigestTheSame() {
        let voices = [ramp(64), ramp(32, scale: -1)]
        XCTAssertEqual(BackingKit.digest(voices), BackingKit.digest(voices))
    }

    /// A decay constant moving by a hair has to move this, or the guard is decoration.
    func testOneChangedSampleChangesTheDigest() {
        var changed = ramp(64)
        changed[40] += 1e-6
        XCTAssertNotEqual(BackingKit.digest([ramp(64)]), BackingKit.digest([changed]))
    }

    /// The 7 August change was a *fade*: same samples for most of the buffer, different length and
    /// tail. Without mixing the length in, a truncated voice and a faded one could collide.
    func testALongerVoiceDigestsDifferentlyFromAPrefixOfItself() {
        let long = ramp(128)
        XCTAssertNotEqual(BackingKit.digest([long]), BackingKit.digest([Array(long.prefix(64))]))
    }

    /// Order is part of the identity: the same buffers assigned to different voices is a different
    /// kit, and concatenating without regard to order would hide it.
    func testTheOrderOfVoicesIsPartOfTheIdentity() {
        XCTAssertNotEqual(BackingKit.digest([ramp(8), ramp(16)]),
                          BackingKit.digest([ramp(16), ramp(8)]))
    }

    // MARK: It describes the synthesis, not the output device

    /// The reason `fingerprint` renders its own kit at a fixed rate instead of digesting the one
    /// being played. The buffers genuinely differ by rate — so a fingerprint taken off the live kit
    /// would make headphones and speakers read as two different bands.
    func testTheSameKitAtTwoSampleRatesWouldOtherwiseDigestDifferently() throws {
        let voice = try XCTUnwrap(BackingVoice.allCases.first { !$0.isPitched })
        let a = try XCTUnwrap(TestKit.at(44_100).buffers[voice])
        let b = try XCTUnwrap(TestKit.at(48_000).buffers[voice])

        XCTAssertNotEqual(BackingKit.digest([a]), BackingKit.digest([b]),
                          "the rate changes the buffers, which is why it must not reach the field")
    }

    func testTheFingerprintIsOneValueForTheProcess() {
        XCTAssertEqual(BackingKit.fingerprint, BackingKit.fingerprint)
        XCTAssertEqual(BackingKit.fingerprint.count, 12)
    }

    // MARK: What a take carries

    func testASavedTakeCarriesTheKitItHeard() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam(kitFingerprint: BackingKit.fingerprint))

        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        XCTAssertEqual(loaded.kitFingerprint, BackingKit.fingerprint)
    }

    /// Every take on record predates the field, and none of them may stop decoding for it — R6.1,
    /// and the reason the field is optional. `nil` means *unrecorded*, not any particular kit.
    func testATakeWithNoKitRecordedStillDecodes() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.jam())

        let loaded = try XCTUnwrap(SessionStore.loadAll().first)
        XCTAssertNil(loaded.kitFingerprint)
        XCTAssertEqual(loaded.report().matchedCount, TakeFactory.jam().report().matchedCount,
                       "an absent kit changes nothing about how the take is scored")
    }
}

/// The guard that turns a kit change into a decision rather than a surprise.
extension KitFingerprintTests {

    /// **This test failing is not a bug — it is the notification.** `KitGroup.originalFingerprint`
    /// pins the kit all 104 takes on record were played over. The moment any voice changes, this
    /// fails, and whoever changed it has to decide what the grouping should do: takes over the new
    /// kit are a different task from every take before it, and `KitGroup` is where that is said.
    ///
    /// The pinned value is history and never moves. What moves is the kit, and a second era is
    /// added rather than this constant being edited.
    func testTheLiveKitIsOneThisProjectHasNamed() {
        XCTAssertEqual(BackingKit.fingerprint, KitGroup.known.last?.fingerprint,
                       "A voice changed. That is allowed — but takes over this kit are a different "
                     + "task from every take before it, so **append** an era to `KitGroup.known` "
                     + "rather than editing one. See JOURNAL.md §7.62 and §7.63.")
    }

    /// The list is history, so a row may be added and none may be altered: editing one would
    /// re-label takes that heard a different kit.
    func testEveryKnownKitIsDistinctAndTheOriginalIsFirst() {
        let fingerprints = KitGroup.known.map(\.fingerprint)
        XCTAssertEqual(Set(fingerprints).count, fingerprints.count, "a kit is listed twice")
        XCTAssertEqual(fingerprints.first, KitGroup.originalFingerprint)
    }
}
