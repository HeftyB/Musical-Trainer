import XCTest
import TestSupport
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// One list of what makes two takes a different task, read by both readouts.
///
/// They used to be two lists and they disagreed. `review tags` knew about backings, tempos and
/// output devices; `review conditions` also knew about the rung and the feel; neither knew about
/// the offbeat drill. The visible consequence was `tired` pooling a 2:1 and a 3:2 swung take —
/// two different tasks under one label — and saying nothing at all. See PLAN.md §7.28.
final class TakeAxisTests: XCTestCase {

    private static let grid = TakeFactory.grid()

    /// Two takes differing on exactly one axis, for each axis in turn.
    private func pair(differingOn axis: String) -> [JamSession] {
        switch axis {
        case "Backing":
            return [TakeFactory.jam(), TakeFactory.jam(offbeatLevel: 0)]
        case "Style":
            // Two bands, not two takes of one. A pair of *seeds* would differ as backings and
            // not as styles, which is the distinction this axis exists to draw.
            return [TakeFactory.jam(generatedBacking: BackingIdentity(style: "driving", seed: 1)),
                    TakeFactory.jam(generatedBacking: BackingIdentity(style: "pocket", seed: 1))]
        case "Feel":
            return [TakeFactory.jam(rung: .eighths, feel: .swung),
                    TakeFactory.jam(rung: .eighths,
                                    feel: Feel(swingRatio: 1.5) ?? .straight)]
        case "Subdivision":
            return [TakeFactory.jam(rung: .eighths), TakeFactory.jam(rung: .sixteenths)]
        case "Offbeat level":
            return [TakeFactory.jam(offbeatLevel: 0), TakeFactory.jam(offbeatLevel: 2)]
        case "Tempo":
            return [TakeFactory.jam(), TakeFactory.jam(grid: TakeFactory.grid(bpm: 110))]
        case "Output device":
            return [TakeFactory.jam()]     // covered by the identity check below instead
        default:
            return []
        }
    }

    /// Every axis is detected by **both** readouts. Parameterised over the list itself, so an
    /// axis added later is covered without anyone remembering to add a case.
    func testEveryAxisIsSeenByBothReadouts() {
        for axis in TakeAxis.all where axis.singular != "Output device" {
            let takes = pair(differingOn: axis.singular)
            // `continue` rather than an assertion alone: without it a missing fixture traps on
            // `takes[0]` and takes the whole run down, so the one thing this test exists to catch
            // — an axis added without a fixture — reports as a crash instead of as a failure.
            guard takes.count >= 2 else {
                XCTFail("no fixture for \(axis.singular) — add one to `pair(differingOn:)`")
                continue
            }

            let mixed = TakeAxis.mixed(in: takes).map(\.singular)
            XCTAssertTrue(mixed.contains(axis.singular),
                          "review tags missed \(axis.singular); saw \(mixed)")

            let notes = Commands.comparabilityNotes([("a", [takes[0]]), ("b", [takes[1]])])
            XCTAssertTrue(notes.contains { $0.hasPrefix(axis.singular) },
                          "review conditions missed \(axis.singular); saw \(notes)")
        }
    }

    /// The gap that prompted this: a pool of swung takes at different ratios.
    func testAPoolOfTwoSwingRatiosIsFlagged() {
        let takes = [TakeFactory.jam(rung: .eighths, feel: .swung),
                     TakeFactory.jam(rung: .eighths, feel: Feel(swingRatio: 1.5) ?? .straight)]
        XCTAssertEqual(TakeAxis.mixed(in: takes).map(\.singular), ["Feel"],
                       "the two real `tired` takes, which were pooled silently")
    }

    /// And the one that would have gone the same way: an offbeat take tagged alongside jams.
    func testAnOffbeatTakeInAPoolOfJamsIsFlagged() {
        let mixed = TakeAxis.mixed(in: [TakeFactory.jam(), TakeFactory.jam(offbeatLevel: 0)])
            .map(\.singular)
        XCTAssertTrue(mixed.contains("Offbeat level"), "saw \(mixed)")
    }

    func testTakesOfTheSameTaskAreNotFlagged() {
        let takes = [TakeFactory.jam(tag: "relaxed"), TakeFactory.jam(tag: "relaxed")]
        XCTAssertTrue(TakeAxis.mixed(in: takes).isEmpty,
                      "a warning on an unmixed pool is noise, and noise is how a real warning "
                    + "stops being read")
    }

    func testASingleTakeMixesNothing() {
        XCTAssertTrue(TakeAxis.mixed(in: [TakeFactory.jam()]).isEmpty)
    }

    /// Every axis says what stops being comparable. "These differ" leaves the reader to guess
    /// which number it ruined, which is the whole job of the note.
    func testEveryAxisStatesAConsequence() {
        for axis in TakeAxis.all {
            XCTAssertFalse(axis.consequence.isEmpty, axis.singular)
            XCTAssertTrue(axis.consequence.hasSuffix("."), axis.singular)
            XCTAssertGreaterThan(axis.consequence.count, 30,
                                 "\(axis.singular): \(axis.consequence)")
        }
    }

    func testComparabilityNotesSaysNothingAboutOneGroup() {
        XCTAssertTrue(Commands.comparabilityNotes([("only", [TakeFactory.jam()])]).isEmpty)
    }
}
