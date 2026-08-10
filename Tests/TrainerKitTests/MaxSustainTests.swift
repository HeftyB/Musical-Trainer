import XCTest
@testable import TrainerKit

/// A voice whose note-off never arrives must release itself.
///
/// `LiveInstrument.release(note:)` was the only path out of a sounding voice, so a missing
/// note-off meant a tone that rang until the engine stopped. The instrument hung exactly that way
/// twice — 8 and 10 August 2026 — one note sustaining while the keyboard went silent underneath it
/// (PLAN.md §7.34, §7.35). The cause is still not established; this ceiling is the half of the fix
/// that does not depend on knowing it.
///
/// These assert against `LiveInstrument` itself rather than a reimplementation of its envelope,
/// because the whole point is that the *shipping* voice loop times out — `LESSONS.md` shape 1.
/// Deleting the `heldSamples` block in `render` fails `testAVoiceWithNoNoteOffGoesSilentOnItsOwn`.
final class MaxSustainTests: XCTestCase {

    private static let fs = 44_100.0
    private let block = 512

    /// Peak absolute sample over `seconds` of rendering, with no further events enqueued.
    private func peak(_ instrument: LiveInstrument, overSeconds seconds: Double) -> Float {
        var highest: Float = 0
        var rendered = 0
        let total = Int(seconds * Self.fs)
        while rendered < total {
            let (samples, count) = instrument.render(frames: block)
            for i in 0..<count { highest = max(highest, abs(samples[i])) }
            rendered += count
        }
        return highest
    }

    /// The defect itself: hold a note, never release it, and require silence.
    ///
    /// Rendered in two spans so the assertion is "it was sounding, then it stopped" rather than
    /// "it is quiet now" — which a voice that never triggered would also satisfy.
    func testAVoiceWithNoNoteOffGoesSilentOnItsOwn() {
        let instrument = LiveInstrument(sampleRate: Self.fs)
        instrument.enqueue(note: 69, velocity: 100, on: true)

        let whileHeld = peak(instrument, overSeconds: 1.0)
        XCTAssertGreaterThan(whileHeld, 0.05, "the note should be sounding a second in")

        // Past the ceiling, plus the release tail.
        _ = peak(instrument, overSeconds: LiveInstrument.maxSustainSeconds + 1.0)
        let afterCeiling = peak(instrument, overSeconds: 0.5)
        XCTAssertLessThan(afterCeiling, 1e-4,
                          "a voice that never received its note-off is still sounding")
    }

    /// The bound that stops the fix becoming a defect of its own.
    ///
    /// A whole bar of four beats at 40 BPM — the slowest tempo any drill accepts — is 6.0 s. A
    /// ceiling below that would cut off a note held for one bar at a tempo the app offers, which
    /// is real playing rather than a fault. **If the 40 BPM floor is ever lowered, nothing here
    /// notices**: the floor is a literal repeated at eight call sites rather than a shared
    /// constant, so this assertion pins the ceiling and not the relationship.
    func testTheCeilingClearsAWholeBarAtTheSlowestTempoTheAppAllows() {
        let barAtSlowestTempo = 4.0 * 60.0 / 40.0
        XCTAssertEqual(barAtSlowestTempo, 6.0, accuracy: 1e-9)
        XCTAssertGreaterThan(LiveInstrument.maxSustainSeconds, barAtSlowestTempo,
                             "the ceiling would cut off a bar held at 40 BPM")
    }

    /// A note that *is* released still stops when it was told to, not when the ceiling says so.
    func testAReleasedNoteStopsLongBeforeTheCeiling() {
        let instrument = LiveInstrument(sampleRate: Self.fs)
        instrument.enqueue(note: 69, velocity: 100, on: true)
        _ = peak(instrument, overSeconds: 0.5)
        instrument.enqueue(note: 69, velocity: 0, on: false)
        _ = peak(instrument, overSeconds: 0.5)          // let the 0.22 s release finish

        let afterRelease = peak(instrument, overSeconds: 0.25)
        XCTAssertLessThan(afterRelease, 1e-4, "note-off should still end the voice")
    }

    /// The click voice is a one-shot that ignores note-off and decays on its own, so the ceiling
    /// must not be what silences it — it is already inaudible long before.
    func testAPadClickIsUnaffectedByTheCeiling() {
        let instrument = LiveInstrument(sampleRate: Self.fs)
        instrument.enqueue(note: 40, velocity: 100, on: true, click: true)
        let early = peak(instrument, overSeconds: 0.01)
        XCTAssertGreaterThan(early, 0.05, "the click should sound")

        // Discard the decay itself before measuring: its ~8 ms time constant means a span that
        // *starts* during the tail still peaks on it, which says nothing about where it ended.
        _ = peak(instrument, overSeconds: 0.2)
        let afterItsOwnDecay = peak(instrument, overSeconds: 0.25)
        XCTAssertLessThan(afterItsOwnDecay, 1e-3, "the click decays on its own, well inside 8 s")
    }

    /// The render contract the mix depends on: a request larger than the scratch buffer is
    /// clamped rather than grown, and the caller is told so.
    ///
    /// `GroovePlayer.render` mixed the full `frameCount` against this buffer, so a buffer above
    /// `scratchCapacity` read past the allocation. Returning the count is what makes that
    /// unwritable; this pins the contract behind it.
    func testTheInstrumentReportsHowManyFramesItWrote() {
        let instrument = LiveInstrument(sampleRate: Self.fs)
        XCTAssertEqual(instrument.render(frames: 256).count, 256, "an ordinary buffer is exact")

        let oversized = instrument.render(frames: 100_000)
        XCTAssertLessThan(oversized.count, 100_000, "an oversized request must be clamped")
        XCTAssertGreaterThan(oversized.count, 0)
    }
}
