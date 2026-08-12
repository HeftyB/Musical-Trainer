import XCTest
@testable import TimingCore

/// Whether a rung can be swung, and what the player is told when it cannot.
///
/// The app used to answer both questions itself: `subdivisions == 2 || subdivisions == 4` for the
/// first, and one fixed sentence about triplets for the second. The sentence was wrong for
/// quarters, which is what the player actually hit — a disabled control explaining itself wrongly
/// sends the reader looking for the wrong thing (PLAN.md §7.34, §7.39).
final class SwingAvailabilityTests: XCTestCase {

    /// The two questions must not be able to disagree, which is the whole reason the reason
    /// lives beside the test rather than at the surface.
    func testEveryRungAgreesAboutWhetherItCanSwing() {
        for rung in IntervalRung.ladder {
            XCTAssertEqual(rung.canSwing, rung.swingUnavailableReason == nil,
                           "\(rung.label) says it can\(rung.canSwing ? "" : "not") swing but "
                         + "\(rung.swingUnavailableReason == nil ? "gives" : "does not give") a reason")
        }
    }

    /// Binary divisions have a pair for the swing to act on; the other two do not.
    func testOnlyBinaryDivisionsSwing() {
        XCTAssertFalse(IntervalRung.quarters.canSwing)
        XCTAssertTrue(IntervalRung.eighths.canSwing)
        XCTAssertFalse(IntervalRung.tripletEighths.canSwing)
        XCTAssertTrue(IntervalRung.sixteenths.canSwing)
    }

    /// The defect itself: quarters must not be explained by talking about triplets.
    func testQuartersAreNotExplainedByTriplets() {
        let reason = IntervalRung.quarters.swingUnavailableReason
        XCTAssertNotNil(reason)
        XCTAssertFalse(reason!.lowercased().contains("triplet"),
                       "quarters cannot swing because they are undivided, not because of triplets")
    }

    /// And the rung where triplets *are* the reason still says so.
    func testTripletEighthsAreExplainedByTriplets() {
        let reason = IntervalRung.tripletEighths.swingUnavailableReason
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("triplet"))
    }

    /// `canSwing` and the engine's own gate are one rule, not two that happen to agree. A rung
    /// the picker offers a swing for that `Feel` then ignores is a control that lies.
    func testTheRungAndTheFeelAgreeAtEveryRung() {
        guard let swung = Feel(swingRatio: 2) else { return XCTFail("2:1 is a valid ratio") }
        for rung in IntervalRung.ladder {
            XCTAssertEqual(rung.canSwing, swung.applies(toSubdivisions: rung.subdivisions),
                           "\(rung.label) disagrees with Feel.applies")
        }
    }

    /// The rule is "a power of two above one", not "2 or 4" — the shape the app's copy had. A
    /// finer binary rung would swing, and the old test would have said it could not.
    func testTheRuleIsBinaryDivisionRatherThanTheRungsThatExistToday() {
        XCTAssertFalse(Feel.dividesBinarily(1))
        XCTAssertTrue(Feel.dividesBinarily(2))
        XCTAssertFalse(Feel.dividesBinarily(3))
        XCTAssertTrue(Feel.dividesBinarily(4))
        XCTAssertFalse(Feel.dividesBinarily(6))
        XCTAssertTrue(Feel.dividesBinarily(8), "a 32nd rung would swing, and the app's copy said no")
    }
}
