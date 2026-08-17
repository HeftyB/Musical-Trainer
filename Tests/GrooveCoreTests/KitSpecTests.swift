import XCTest
@testable import GrooveCore

/// A style is steps *and* a kit — §7.30 item 2, §7.67.
final class KitSpecTests: XCTestCase {

    /// **Every multiplier is exactly 1**, which is what makes the standard kit bit-identical without
    /// a branch: IEEE guarantees `x * 1.0 == x`, so the synthesis applies these unconditionally and
    /// there is no default-only path to get wrong.
    func testTheStandardKitIsTheIdentityInEveryField() {
        let standard = KitSpec.standard
        XCTAssertEqual(standard.snareTuning, 1)
        XCTAssertEqual(standard.snareDecay, 1)
        XCTAssertEqual(standard.snareRattle, 1)
        XCTAssertEqual(standard.kickTuning, 1)
        XCTAssertEqual(standard.kickDecay, 1)
        XCTAssertEqual(standard.cymbalDecay, 1)
        XCTAssertEqual(standard.roomAmount, 1)
    }

    /// A field added later must default to the identity too, or adding one silently re-voices every
    /// style that never asked for it — and, through the fingerprint, splits the corpus.
    func testANewSpecWithNoArgumentsIsTheStandardKit() {
        XCTAssertEqual(KitSpec(name: "standard"), KitSpec.standard)
    }

    /// Until somebody has tuned a kit and heard it, a style sounds exactly as it did.
    func testAStyleWithoutATunedKitGetsTheStandardOne() {
        for style in StyleLibrary.all {
            XCTAssertEqual(style.kit, .standard, "\(style.name) carries an untested kit")
        }
    }

    func testAStyleCanCarryItsOwnKit() {
        let spec = KitSpec(name: "motown", snareTuning: 1.15, snareDecay: 0.7)
        let style = Style(name: "test", layers: StyleLibrary.all[0].layers,
                          fills: StyleLibrary.all[0].fills,
                          playerVoices: [], density: StyleLibrary.all[0].density, kit: spec)
        XCTAssertEqual(style.kit, spec)
        XCTAssertNotEqual(style.kit, .standard)
    }

    /// Two kits differing in one field are two kits. `Hashable` is what the fingerprint cache keys
    /// on, so a collision there would serve one kit's digest for another's sound.
    func testTwoSpecsDifferingInOneFieldAreNotEqual() {
        XCTAssertNotEqual(KitSpec(name: "a"), KitSpec(name: "a", snareDecay: 0.99))
        XCTAssertNotEqual(KitSpec(name: "a"), KitSpec(name: "b"))
        XCTAssertEqual(Set([KitSpec.standard, KitSpec(name: "standard")]).count, 1)
    }

    /// It is `Codable` so a style library could be authored as data later. A round trip that lost a
    /// field would quietly return the standard kit.
    func testASpecSurvivesACodableRoundTrip() throws {
        let spec = KitSpec(name: "rock", snareTuning: 0.9, snareDecay: 1.4, snareRattle: 1.2,
                           kickTuning: 1.1, kickDecay: 0.8, cymbalDecay: 1.3, roomAmount: 0.5)
        let data = try JSONEncoder().encode(spec)
        XCTAssertEqual(try JSONDecoder().decode(KitSpec.self, from: data), spec)
    }
}
