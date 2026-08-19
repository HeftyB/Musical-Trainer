import XCTest
@testable import GrooveCore

/// Two things may share the pulse; they may not play the same steps.
///
/// Found by ear, not by a test: *"the ride cymbal sounds kind of like a bell with the hats going
/// as well — usually you keep rhythm on the ride or the hats, never both at the same time."*
/// `motown` played sixteenths on the hat and quarters on the ride at intensity 3, and `half-time`
/// played the hat and the ride on the **same four steps** from intensity 2 — identical rhythm,
/// two timbres, which reads as a bell ringing over a hat rather than as either.
///
/// Doubling is not a fuller sound, it is two drummers. **Interlocking is different and fine**:
/// a hat on the downbeats and a shaker on the offbeats are one pulse shared between two hands,
/// which is ordinary percussion — the first version of this rule forbade that too, and narrowing
/// it to voices that share steps is what makes it describe the defect rather than the genre.
/// See JOURNAL.md §7.29 step 6.
final class TimekeeperTests: XCTestCase {

    func testNoStyleDoublesItsTimekeeperAtAnyIntensity() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                let doubled = style.doubledTimekeepers(atIntensity: intensity)
                XCTAssertTrue(doubled.isEmpty,
                    "\(style.name) at intensity \(intensity) plays "
                  + "\(doubled.map(\.rawValue).sorted().joined(separator: " and ")) on the same "
                  + "steps — the same rhythm in two timbres, not a fuller sound")
            }
        }
    }

    /// The distinction the rule turns on, and the reason it is not simply "one timekeeper".
    func testInterlockingVoicesAreAllowed() {
        let style = Style(
            name: "test",
            layers: [
                Layer(Pattern.make([.kick: [0, 8]])),
                Layer(Pattern.make([.closedHat: [0, 4, 8, 12]]), entersAt: 1),
                Layer(Pattern.make([.shaker: [2, 6, 10, 14]]), entersAt: 1),
            ],
            fills: [], playerVoices: [.kick], density: .medium)
        XCTAssertTrue(style.doubledTimekeepers(atIntensity: 1).isEmpty,
                      "one pulse shared between two hands is ordinary percussion")
    }

    /// The threshold, stated: three hits in a bar is keeping time, fewer is a colour. Without it
    /// a single crash or a ride hit on the downbeat would read as a second timekeeper and the
    /// rule would forbid ordinary music.
    func testAnOccasionalHitOnATimekeepingVoiceIsNotKeepingTime() {
        let style = Style(
            name: "test",
            layers: [
                Layer(Pattern.make([.kick: [0, 8], .snare: [4, 12]])),
                Layer(Pattern.make([.closedHat: [0, 2, 4, 6, 8, 10, 12, 14]]), entersAt: 1),
                // One ride hit to mark the bar. A colour, not a pulse.
                Layer(Pattern.make([.ride: [0]]), entersAt: 2),
            ],
            fills: [], playerVoices: [.kick], density: .medium)

        XCTAssertTrue(style.doubledTimekeepers(atIntensity: 2).isEmpty)
    }

    func testTwoVoicesKeepingTimeIsDetected() {
        let style = Style(
            name: "test",
            layers: [
                Layer(Pattern.make([.kick: [0, 8]])),
                Layer(Pattern.make([.closedHat: [0, 4, 8, 12]]), entersAt: 1),
                Layer(Pattern.make([.ride: [0, 4, 8, 12]]), entersAt: 1),
            ],
            fills: [], playerVoices: [.kick], density: .medium)

        XCTAssertEqual(style.doubledTimekeepers(atIntensity: 1), [.closedHat, .ride],
                       "the exact shape half-time had: the same four steps, twice")
    }

    /// Hand percussion keeps time as readily as a cymbal does — a tambourine on every eighth is
    /// the pulse, whatever else is playing.
    func testHandPercussionCountsAsATimekeeper() {
        XCTAssertTrue(BackingVoice.timekeepers.contains(.tambourine))
        XCTAssertTrue(BackingVoice.timekeepers.contains(.shaker))
        XCTAssertFalse(BackingVoice.timekeepers.contains(.crash), "a crash marks, it does not keep")
        XCTAssertFalse(BackingVoice.timekeepers.contains(.cowbell),
                       "a cowbell is a landmark; it can double the pulse without being it")
    }
}
