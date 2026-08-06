import XCTest
@testable import TimingCore

/// M15 step 1: where a subdivision is *expected* to land, before anything is scored against it.
///
/// Matching swing against an even grid reports style as error, with numbers that stay plausible
/// the whole way — §5.3's sign inversion in a costume that is much harder to notice. These pin
/// the arithmetic that stops it.
final class FeelTests: XCTestCase {

    // MARK: Straight is the identity, not a special case

    func testAStraightFeelPutsEverySubdivisionWhereItAlwaysWas() {
        for subdivisions in [1, 2, 3, 4] {
            let expected = (0..<subdivisions).map { Double($0) / Double(subdivisions) }
            XCTAssertEqual(Feel.straight.phases(subdivisions: subdivisions), expected,
                           "\(subdivisions) per beat")
        }
    }

    /// A ratio of 1 *is* straight. If this ever stops holding, every straight take in the
    /// history moves the moment feels are wired in.
    func testARatioOfOneIsIndistinguishableFromStraight() {
        let unity = Feel(swingRatio: 1)
        XCTAssertEqual(unity, Feel.straight)
        XCTAssertEqual(unity?.offbeatPhase, 0.5)
        XCTAssertEqual(unity?.phases(subdivisions: 4), Feel.straight.phases(subdivisions: 4))
    }

    // MARK: Swing moves the offbeat and nothing else

    func testSwungEighthsDelayTheOffbeatByTheRatio() {
        XCTAssertEqual(Feel.swung.phases(subdivisions: 2), [0, 2.0 / 3], "2:1 is the triplet feel")

        guard let shallow = Feel(swingRatio: 1.5) else { return XCTFail("1.5 is a valid ratio") }
        XCTAssertEqual(shallow.phases(subdivisions: 2).last ?? 0, 0.6, accuracy: 1e-12)
    }

    /// Swung sixteenths delay the second of each pair while the eighths stay put. Moving the
    /// eighths as well would be swinging a division that is not being swung.
    func testSwungSixteenthsLeaveTheEighthsWhereTheyAre() {
        let phases = Feel.swung.phases(subdivisions: 4)

        XCTAssertEqual(phases[0], 0, accuracy: 1e-12)
        XCTAssertEqual(phases[2], 0.5, accuracy: 1e-12, "the eighth must not move")
        XCTAssertEqual(phases[1], 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(phases[3], 0.5 + 1.0 / 3, accuracy: 1e-12)
    }

    /// Triplets are the division swing borrows from. "Swung triplets" is a division of a
    /// division nobody plays, so the feel has no effect rather than an invented one.
    func testATripletRungIsAlwaysStraightWhateverTheFeel() {
        XCTAssertEqual(Feel.swung.phases(subdivisions: 3), Feel.straight.phases(subdivisions: 3))
        XCTAssertFalse(Feel.swung.applies(toSubdivisions: 3))
        XCTAssertFalse(Feel.swung.applies(toSubdivisions: 1), "an undivided beat cannot swing")
        XCTAssertTrue(Feel.swung.applies(toSubdivisions: 2))
        XCTAssertTrue(Feel.swung.applies(toSubdivisions: 4))
    }

    /// Phases must stay in order and inside the beat, or the matcher's notion of "the next
    /// grid point" stops meaning anything.
    func testPhasesAreOrderedAndInsideTheBeat() {
        for ratio in [1.0, 1.25, 1.5, 2.0, 3.0, 4.0] {
            guard let feel = Feel(swingRatio: ratio) else { return XCTFail("\(ratio)") }
            for subdivisions in [1, 2, 3, 4] {
                let phases = feel.phases(subdivisions: subdivisions)
                XCTAssertEqual(phases.first, 0, "\(ratio)/\(subdivisions) must start on the beat")
                XCTAssertEqual(phases, phases.sorted(), "\(ratio)/\(subdivisions) out of order")
                XCTAssertTrue(phases.allSatisfy { $0 >= 0 && $0 < 1 },
                              "\(ratio)/\(subdivisions): \(phases)")
            }
        }
    }

    // MARK: Refusals

    func testARatioThatDescribesNothingPlayableIsRefused() {
        XCTAssertNil(Feel(swingRatio: 0.5), "below 1 the offbeat would come early")
        XCTAssertNil(Feel(swingRatio: 0), "a ratio of zero is not a feel")
        XCTAssertNil(Feel(swingRatio: 9), "the short note stops being a note value")
        XCTAssertNil(Feel(swingRatio: .nan))
        XCTAssertNil(Feel(swingRatio: .infinity))
    }

    // MARK: The ceiling, and its agreement with M14

    /// Swing makes the division uneven, so the *short* note is what the matcher has to resolve.
    /// At 2:1 the short half of an eighth pair is a third of the beat — the same 200 ms at
    /// 100 BPM that a triplet rung produces.
    func testTheShortestGapIsTheShortHalfOfThePair() {
        XCTAssertEqual(Feel.swung.shortestGapSeconds(subdivisions: 2, atBpm: 100),
                       0.2, accuracy: 1e-12)
        XCTAssertEqual(Feel.straight.shortestGapSeconds(subdivisions: 2, atBpm: 100),
                       0.3, accuracy: 1e-12)
    }

    /// **The consistency check.** At a ratio of 1 the feel *is* the rung, so its ceiling has to
    /// be the rung's — if these two derivations ever disagree, one of them is wrong and the
    /// player is being told a rung is scorable when it is not.
    func testAStraightFeelReproducesTheRungsOwnCeiling() {
        for subdivisions in [1, 2, 3, 4] {
            let rung = IntervalRung.ladder.first { $0.subdivisions == subdivisions }!
            XCTAssertEqual(Feel.straight.maximumBpm(subdivisions: subdivisions, forSpreadMs: 20),
                           rung.maximumBpm(forSpreadMs: 20), accuracy: 0.01,
                           "\(rung.label)")
        }
    }

    /// And swinging tightens it, because the short note is shorter than an even division.
    func testSwingLowersTheCeilingBelowTheStraightRung() {
        let straight = Feel.straight.maximumBpm(subdivisions: 2, forSpreadMs: 20)
        let swung = Feel.swung.maximumBpm(subdivisions: 2, forSpreadMs: 20)

        XCTAssertEqual(straight, 199, accuracy: 1)
        XCTAssertEqual(swung, 133, accuracy: 1, "2:1 eighths resolve like triplets")
        XCTAssertLessThan(swung, straight)
    }
}
