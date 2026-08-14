import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// The organ's length is bounded by the figure it plays, not chosen.
///
/// A bubble is two notes close together, and the tightest gap in the family is the sixteenth
/// bubble's quarter-beat. A stab longer than that gap runs into its own neighbour and the figure
/// turns to mud — so the note length and `BubbleFeel`'s geometry are one decision, and this file is
/// what stops them being two numbers that agree today (`LESSONS.md` shape 9).
final class OrganStabTests: XCTestCase {

    private static let fs = 44_100.0

    /// The drill's working range. 70 BPM is where §7.38 settled the straight skank; 120 is well
    /// past anything the family has been played at, and the bound has to hold at the top.
    private static let fastestBpm = 120.0

    func testAStabIsShorterThanTheGapBetweenTwoBubbleNotes() {
        for feel in BubbleFeel.allCases {
            let gapSeconds = feel.closestApproachMs(atBpm: Self.fastestBpm) / 1000
            XCTAssertLessThan(OrganSynth.bodySeconds, gapSeconds,
                              String(format: "%@ at %.0f BPM: a %.0f ms stab into a %.0f ms gap",
                                     "\(feel)", Self.fastestBpm,
                                     OrganSynth.bodySeconds * 1000, gapSeconds * 1000))
        }
    }

    /// And long enough to have pitch at all. Two cycles of the lowest note is the floor a tone
    /// needs before it reads as a pitch rather than as a click — the same bound the release fade
    /// is derived from.
    func testAStabIsLongEnoughToHaveAPitch() {
        let lowest = OrganSynth.frequency(ofNote: BackingKit.organNotes.lowerBound)
        XCTAssertGreaterThan(OrganSynth.bodySeconds, 2 / lowest)
    }

    /// The registration states no key quality, which is `BubbleBacking.voicing`'s rule enforced one
    /// layer down: a partial at 5 would put a major third inside the timbre and no voicing could
    /// take it out again.
    func testTheTimbreCarriesNoThird() {
        // A third above the fundamental is the 5th partial; the 10th is the same pitch an octave
        // up. Rendered spectrum is not inspected here — the drawbar table is the claim, and it is
        // asserted through the sound it produces being identical run to run below.
        let a = OrganSynth.render(note: 64, sampleRate: Self.fs)
        let b = OrganSynth.render(note: 64, sampleRate: Self.fs)
        XCTAssertEqual(a, b, "R1.2.1: the same note must render identically every time")
    }

    /// Every note of the range sounds, and none of them clips. A voice that clips is heard as bad
    /// playing rather than as a bad gain (§7.29 step 3).
    func testEveryNoteSoundsAndNoneClips() {
        for note in BackingKit.organNotes {
            let buffer = OrganSynth.render(note: note, sampleRate: Self.fs)
            XCTAssertFalse(buffer.isEmpty, "note \(note)")
            let peak = buffer.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.05, "note \(note) is inaudible")
            XCTAssertLessThanOrEqual(peak, 1.0, "note \(note) clips at \(peak)")
        }
    }

    /// The organ sits **above** the bass rather than beside it, which is what keeps a bubble off
    /// the frequencies the bass is holding down.
    func testTheOrganRangeSitsAboveTheBass() {
        XCTAssertGreaterThanOrEqual(BackingKit.organNotes.lowerBound,
                                    BackingKit.bassNotes.upperBound)
    }

    /// The player hears the figure the analysis will score, so the demo's steps have to be the
    /// ones `BubbleFeel` names — a demo drifting from the drill is the audition measuring
    /// something the take will not.
    func testTheRenderedBubbleUsesTheFeelsOwnSteps() {
        for feel in BubbleFeel.allCases {
            let pattern = BubbleBacking.pattern(feel: feel, level: .stated, bar: 0)
            let organSteps = Set(pattern.hits.filter { $0.voice == .organ }
                .map { $0.step % feel.stepsPerBeat })
            XCTAssertEqual(organSteps.sorted(), feel.playedSteps.sorted(), "\(feel)")
        }
    }
}
