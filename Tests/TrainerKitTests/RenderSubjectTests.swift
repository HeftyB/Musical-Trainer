import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// What `render` will write, asserted before anything is written.
///
/// The seeded audition was generated at 32 bars and rendered at the command's bar count, so
/// `render 100 8` — the invocation `AGENT.md` documents — produced one 8-bar phrase at one
/// intensity, and the arc had never been heard. `ArcLengthTests` proves a full-arc-length piece
/// moves; **this proves `render` asks for one**, which is the half that was missing: the decision
/// lived inside a function that writes files to disk, so nothing could observe it either way
/// (`LESSONS.md` shape 1). See PLAN.md §7.31 finding 3.
final class RenderSubjectTests: XCTestCase {

    private func seeded(_ subjects: [Commands.Subject]) -> [Commands.Subject] {
        subjects.filter { BackingIdentity.parse($0.name) != nil }
    }

    /// The defect, named: at the documented invocation the seeded pieces are rendered long enough
    /// to contain an arc, whatever the command asked for.
    func testASeededPieceIsRenderedLongEnoughToContainItsArc() {
        for requested in [1, 4, 8, 16, 32, 64] {
            let pieces = seeded(Commands.renderSubjects(bars: requested))
            XCTAssertEqual(pieces.count, StyleLibrary.all.count,
                           "one generated piece per style, at \(requested) bars requested")
            for piece in pieces {
                XCTAssertGreaterThanOrEqual(piece.bars, StyleArranger.barsForAFullArc(),
                    "\(piece.name) renders \(piece.bars) bars at a requested \(requested), which "
                  + "is less than one intensity arc — the audition would be a loop")
            }
        }
    }

    /// **Generated and rendered at the same length.** The defect was not that the piece was short;
    /// it was that the piece was long and the render was short, so the two disagreed silently.
    func testTheRenderedLengthMatchesTheGeneratedLength() {
        for requested in [8, 32, 64] {
            for piece in seeded(Commands.renderSubjects(bars: requested)) {
                let identity = try? XCTUnwrap(BackingIdentity.parse(piece.name))
                guard let identity, let style = StyleLibrary.named(identity.style) else {
                    return XCTFail("\(piece.name) does not name a style in the library")
                }
                let expected = StyleArranger.arrangement(style: style, seed: identity.seed,
                                                         bars: piece.bars)
                XCTAssertEqual(piece.arrangement, expected,
                    "\(piece.name) was generated at a different length from the one rendered")
            }
        }
    }

    /// A longer floor for the seeded pieces must not quietly lengthen everything else: a kit voice
    /// is four bars of quarter notes, and a ladder backing is however much was asked for.
    func testEverythingElseIsRenderedAtTheLengthRequested() {
        for requested in [4, 8, 32] {
            for subject in Commands.renderSubjects(bars: requested)
                where BackingIdentity.parse(subject.name) == nil {
                let expected = subject.name.hasPrefix("kit-") ? 4 : requested
                XCTAssertEqual(subject.bars, expected, subject.name)
            }
        }
    }

    /// The subject list is what `AGENT.md` quotes a file count from, and a count in prose is a
    /// claim like any other. Forty-five: ten ladder and demo backings, four styles at four
    /// intensities, one seeded piece each, thirteen drum voices and the bass.
    func testTheFileCountIsWhatTheDocumentationSays() {
        let subjects = Commands.renderSubjects(bars: 8)
        let styles = StyleLibrary.all.count
        let kitVoices = BackingVoice.allCases.filter { !$0.isPitched }.count
        XCTAssertEqual(subjects.count, 10 + styles * Style.intensityRange.count + styles
                                          + kitVoices + 1)
        XCTAssertEqual(Set(subjects.map(\.name)).count, subjects.count,
                       "two subjects with one name would overwrite each other's file")
    }

    /// `kit-bass` is the file whose absence kept the loudest truncation click in the kit out of
    /// §7.29 step 6b's table for a whole milestone. It walks the range, and the *lowest* note is
    /// the one that matters — it truncates loudest and its period is longest.
    func testTheBassIsRenderedAtAll() throws {
        let subjects = Commands.renderSubjects(bars: 8)
        let bass = try XCTUnwrap(subjects.first { $0.name == "kit-bass" })
        let notes = bass.arrangement.pattern(atBar: 0).hits.compactMap(\.note)
        XCTAssertTrue(notes.contains(BackingKit.bassNotes.lowerBound), "the low end is the point")
        XCTAssertTrue(notes.contains(BackingKit.bassNotes.upperBound))
    }
}
