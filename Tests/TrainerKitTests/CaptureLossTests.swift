import XCTest
@testable import TrainerKit

/// What a take lost, and whether it can say so.
///
/// Two defects, both in the capture path, both silent by construction. The buffer stopped writing
/// at its end and said nothing — `LESSONS.md` shape 20, the error path discarding exactly the
/// observation that says something went wrong — and the two readouts counted incidents by
/// subtraction, so the kind that reports it would have been printed under another kind's name.
///
/// What is here is the arithmetic that decides the buffer is big enough, and the readout that
/// describes the result — which is where the second defect lived. **The overflow itself used to be
/// unreachable** without CoreMIDI delivering tens of thousands of packets (R5.6); §7.58 moved the
/// buffer's rules into `MIDIInput.Capture`, which can be handed a capacity of three, and
/// `CaptureTests` provokes it directly.
final class CaptureLossTests: XCTestCase {

    // MARK: The buffer is sized from the longest take, not from a number that looked generous

    /// Four-note chords on sixteenths is 16 note-ons a beat, and this player is a keyboard player.
    /// The old 8192 covered barely four a beat across a maximum-length take.
    func testTheCaptureBufferCoversADenseTakeAtTheEnginesOwnLimit() {
        XCTAssertGreaterThanOrEqual(MIDIInput.notesPerBeatCovered, 16,
                                    "\(MIDIInput.captureCapacity) note-ons over "
                                  + "\(TrainerEngine.maximumTakeBars) bars is "
                                  + "\(MIDIInput.notesPerBeatCovered) per beat")
    }

    /// The link is what matters: raising the bar cap without the buffer must fail here rather
    /// than silently shortening how much of a take gets recorded (`LESSONS.md` shape 9).
    func testTheBufferIsDerivedFromTheTakeLimitRatherThanFixed() {
        XCTAssertEqual(MIDIInput.notesPerBeatCovered,
                       Double(MIDIInput.captureCapacity) / Double(TrainerEngine.maximumTakeBars * 4))
    }

    // MARK: The readout, which is where the silence would have persisted

    private func incident(_ kind: MIDIIncident.Kind, at hostTime: UInt64 = 1,
                          name: String? = nil) -> MIDIIncident {
        MIDIIncident(kind: kind, hostTime: hostTime, name: name)
    }

    func testNothingHappenedProducesNoReportRatherThanAnEmptyWarning() {
        XCTAssertNil(MIDIIncidentReport.of([]))
    }

    /// The defect: a dropped-note incident must not be counted as a setup change. Both surfaces
    /// derived "everything that is not a removal" by subtraction.
    func testAFullBufferIsNotReportedAsASetupChange() throws {
        let report = try XCTUnwrap(MIDIIncidentReport.of([incident(.captureFull(dropped: 12))]))
        XCTAssertEqual(report.lines.count, 1)
        XCTAssertTrue(report.lines[0].contains("12 notes not recorded"), report.lines[0])
        XCTAssertFalse(report.lines.joined().contains("setup change"), report.lines[0])
    }

    /// A source going away and a full buffer are different losses and get different words: never
    /// delivered against delivered and not stored. Reporting both as "may be missing playing"
    /// understates the second, whose numbers are computed over a truncated take.
    func testTheConsequenceSaysWhichKindOfLossHappened() throws {
        let gone = try XCTUnwrap(MIDIIncidentReport.of([incident(.sourceRemoved)]))
        XCTAssertTrue(gone.consequence.contains("never delivered"), gone.consequence)
        XCTAssertFalse(gone.consequence.contains("truncated"), gone.consequence)

        let full = try XCTUnwrap(MIDIIncidentReport.of([incident(.captureFull(dropped: 3))]))
        XCTAssertTrue(full.consequence.contains("truncated"), full.consequence)
        XCTAssertFalse(full.consequence.contains("never delivered"), full.consequence)

        let both = try XCTUnwrap(MIDIIncidentReport.of([incident(.sourceRemoved),
                                                        incident(.captureFull(dropped: 3))]))
        XCTAssertTrue(both.consequence.contains("never delivered"), both.consequence)
        XCTAssertTrue(both.consequence.contains("truncated"), both.consequence)
    }

    /// §7.34's rule, in the words the player reads: an incident is a record, never an exclusion.
    func testEveryReportSaysNothingHasBeenExcluded() throws {
        for kind in [MIDIIncident.Kind.sourceRemoved, .setupChanged, .captureFull(dropped: 1)] {
            let report = try XCTUnwrap(MIDIIncidentReport.of([incident(kind)]))
            XCTAssertTrue(report.consequence.contains("record, not a verdict"), "\(kind)")
        }
    }

    func testCountsReadAsEnglishAtOne() throws {
        let one = try XCTUnwrap(MIDIIncidentReport.of([incident(.sourceRemoved),
                                                        incident(.setupChanged),
                                                        incident(.captureFull(dropped: 1))]))
        XCTAssertEqual(one.lines[0], "1 source removal")
        XCTAssertEqual(one.lines[1], "1 setup change")
        XCTAssertTrue(one.lines[2].hasPrefix("1 note not recorded"), one.lines[2])
    }

    /// Dropped counts add up across incidents rather than being counted as one event, since the
    /// number the player wants is how much playing is missing.
    func testDroppedNotesAreSummedRatherThanCounted() throws {
        let report = try XCTUnwrap(MIDIIncidentReport.of([incident(.captureFull(dropped: 10)),
                                                          incident(.captureFull(dropped: 5))]))
        XCTAssertTrue(report.lines[0].hasPrefix("15 notes not recorded"), report.lines[0])
    }

    func testTheNamedSourceIsCarriedIntoTheLine() throws {
        let report = try XCTUnwrap(MIDIIncidentReport.of([
            incident(.sourceRemoved, name: nil),
            incident(.sourceRemoved, at: 2, name: "LK Mini MIDI"),
        ]))
        XCTAssertEqual(report.lines[0], "2 source removals, including LK Mini MIDI")
    }
}
