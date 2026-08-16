import XCTest
@testable import TimingCore

/// What makes two takes a different task — the list §7.28 named, tested where CI can reach it.
///
/// These rules produced three defects and every one of them shipped: §7.24 step 8 pooled the first
/// skank ever recorded with 21 free jams, §7.48 drew one chart line through groups the cards beneath
/// it refused to pool, and §7.52 fed every skank to the *planner* as an ordinary jam, which decides
/// what you are told to practise rather than merely what you are shown.
///
/// All three were reachable only through `TrainerEngine`, which needs CoreAudio, so none of them was
/// reachable by the leg of CI that actually runs. §7.60 moved the rules into `TimingCore` and this is
/// what that buys: the list is now checked on every push, on Linux, with no hardware.
final class TaskIdentityTests: XCTestCase {

    private func jam(bpm: Int = 100, rung: String? = nil, backing: BackingGroup = .fixed,
                     swing: Double? = nil, offbeat: Int? = nil,
                     kit: KitGroup = .original) -> JamTask {
        JamTask(bpm: bpm, rung: rung, backing: backing, swingRatio: swing,
                offbeatLevel: offbeat, kit: kit)
    }

    private func name(_ task: JamTask) -> String {
        task.title(offbeatLevelName: { ["stated", "no kick", "no backbeat", "bare"][safe: $0] })
    }

    // MARK: The three defects, as rules

    /// §7.24 step 8. An offbeat take stores no rung and no swing, so without this axis it keys
    /// identically to a free jam — and the first one recorded had the worst spread on record.
    func testAnOffbeatTakeIsNotAFreeJam() {
        XCTAssertNotEqual(jam(offbeat: 0), jam(),
                          "a skank and a free jam at the same tempo are not one series")
        XCTAssertNotEqual(jam(offbeat: 0), jam(offbeat: 1), "the levels are a ladder")
    }

    /// §7.52's register: the same confound, but reaching the planner rather than a readout.
    func testEveryOffbeatLevelKeysApartFromEveryFreeJam() {
        let free = jam()
        for level in 0...3 {
            XCTAssertNotEqual(jam(offbeat: level), free)
        }
    }

    /// §7.48. Two backings that are the same band playing a different piece pool; two bands do not.
    func testSeedsOfOneStylePoolAndStylesDoNot() {
        XCTAssertEqual(jam(backing: .style("driving")), jam(backing: .style("driving")),
                       "two seeds of one style are one group — §7.29 step 7")
        XCTAssertNotEqual(jam(backing: .style("driving")), jam(backing: .style("pocket")))
        XCTAssertNotEqual(jam(backing: .style("driving")), jam(backing: .fixed))
    }

    // MARK: The axes that were added one defect at a time

    func testTempoRungAndFeelAreEachATaskChange() {
        XCTAssertNotEqual(jam(bpm: 100), jam(bpm: 110))
        XCTAssertNotEqual(jam(rung: "eighths"), jam(rung: "sixteenths"))
        XCTAssertNotEqual(jam(rung: "eighths", swing: 2), jam(rung: "eighths"))
    }

    /// "Play what you like" and "play one note per beat" are different instructions, so they are
    /// different tasks — the opposite of the continuation drill's rule below.
    func testFreePlayingIsNotQuarters() {
        XCTAssertNotEqual(jam(rung: nil), jam(rung: "quarters"))
    }

    /// **The guard the move added.** Decoding to `IntervalRung` here would fold anything this build
    /// does not recognise into `nil` — free playing, the largest and oldest group in the corpus — so
    /// a rung from a newer build would silently join the series the project reads its progress from.
    func testAnUnknownRungGroupsOnItsOwnRatherThanAsFreePlaying() {
        XCTAssertNotEqual(jam(rung: "quintuplets"), jam(rung: nil))
        XCTAssertNotEqual(jam(rung: "quintuplets"), jam(rung: "sixteenths"))
        XCTAssertEqual(jam(rung: "quintuplets"), jam(rung: "quintuplets"))
    }

    // MARK: Ordering, which decides what every readout lists first

    func testGroupsSortByTempoThenRungThenFeelThenOffbeatThenBacking() {
        let sorted = [
            jam(bpm: 110),
            jam(bpm: 100, offbeat: 0),
            jam(bpm: 100, rung: "eighths"),
            jam(bpm: 100),
            jam(bpm: 100, rung: "eighths", swing: 2),
        ].sorted()

        XCTAssertEqual(sorted.map(\.bpm), [100, 100, 100, 100, 110])
        XCTAssertEqual(sorted[0].offbeatLevel, nil, "an absent rung and no offbeat level sort first")
        XCTAssertEqual(sorted[1].offbeatLevel, 0)
        XCTAssertEqual(sorted[2].rung, "eighths")
        XCTAssertEqual(sorted[3].swingRatio, 2, "straight before swung at one rung")
    }

    func testAFixedBackingSortsBeforeEveryGeneratedOne() {
        XCTAssertEqual([BackingGroup.style("pocket"), .fixed, .style("driving")].sorted(),
                       [.fixed, .style("driving"), .style("pocket")])
    }

    // MARK: Titles — the one name the card and the chart share

    /// Every title this project has ever printed has to be unchanged, or the history reads as though
    /// the groups moved when only the code did.
    func testAPlainJamKeepsTheTitleItAlwaysHad() {
        XCTAssertEqual(name(jam()), "Jams at 100 BPM")
        XCTAssertEqual(name(jam(bpm: 110)), "Jams at 110 BPM")
    }

    func testTheTitleNamesEveryAxisThatIsSet() {
        XCTAssertEqual(name(jam(rung: "eighths")), "Jams at 100 BPM, eighths")
        XCTAssertEqual(name(jam(rung: "eighths", swing: 2)),
                       "Jams at 100 BPM, eighths, swung (2:1)")
        XCTAssertEqual(name(jam(backing: .style("driving"))), "Jams at 100 BPM, driving")
        XCTAssertEqual(name(jam(offbeat: 1)), "Jams at 100 BPM, offbeat level 1 — no kick")
    }

    /// The backing module owns the level's word, so an unrecognised level drops the clause rather
    /// than printing a number beside a missing name.
    func testAnUnnamedOffbeatLevelDropsItsClauseRatherThanPrintingHalfOfIt() {
        XCTAssertEqual(name(jam(offbeat: 9)), "Jams at 100 BPM")
    }

    /// An unrecognised rung is a group of its own but has no name to print, for the same reason.
    func testAnUnknownRungIsGroupedWithoutBeingNamed() {
        XCTAssertEqual(name(jam(rung: "quintuplets")), "Jams at 100 BPM")
    }

    // MARK: The kit, which is the axis nothing keyed on until §7.61

    /// **The design decision, and the one most likely to be "corrected" later.** Every take on
    /// record predates the field, so if unrecorded were its own group the corpus would split from
    /// everything recorded afterwards — 104 takes orphaned on a bookkeeping distinction rather than
    /// an acoustic one, and the 21-take free-jam series would stop growing the day it merged.
    func testAnUnrecordedKitAndTheOriginalOneAreTheSameGroup() {
        XCTAssertEqual(KitGroup(fingerprint: nil), .original)
        XCTAssertEqual(KitGroup(fingerprint: KitGroup.originalFingerprint), .original)
        XCTAssertEqual(jam(kit: KitGroup(fingerprint: nil)),
                       jam(kit: KitGroup(fingerprint: KitGroup.originalFingerprint)))
    }

    func testADifferentKitIsADifferentTask() {
        XCTAssertNotEqual(jam(kit: .original), jam(kit: .changed("ffffffffffff")))
        XCTAssertNotEqual(jam(kit: .changed("aaaaaaaaaaaa")), jam(kit: .changed("ffffffffffff")))
    }

    /// The original kit contributes nothing to a title, so every heading this project has printed
    /// stays exactly as it was — the same guarantee `BackingGroup.fixed` carries.
    func testTheOriginalKitIsNotNamedAndAChangedOneIs() {
        XCTAssertEqual(name(jam(kit: .original)), "Jams at 100 BPM")
        XCTAssertEqual(name(jam(kit: .changed(KitGroup.velocityLayeredFingerprint))),
                       "Jams at 100 BPM, kit velocity layers")
    }

    /// A kit nobody has named still has to be distinguishable in a heading, so it prints enough
    /// digest to tell two apart rather than going silent.
    func testAnUnnamedKitPrintsItsDigest() {
        XCTAssertEqual(name(jam(kit: .changed("abcdef123456"))), "Jams at 100 BPM, kit abcdef")
    }

    func testTheOriginalKitSortsBeforeEveryChangedOne() {
        XCTAssertEqual([KitGroup.changed("bbb"), .original, .changed("aaa")].sorted(),
                       [.original, .changed("aaa"), .changed("bbb")])
    }

    /// The band drops out in the continuation drill and plays the landmarks in the form drill, so a
    /// changed kit changes both tasks as surely as it changes a jam.
    func testTheOtherTwoDrillsCarryTheKitToo() {
        XCTAssertNotEqual(ContinuationTask(silentBars: 4, rung: nil, kit: .original),
                          ContinuationTask(silentBars: 4, rung: nil, kit: .changed("ff")))
        XCTAssertNotEqual(FormTask(level: 0, phraseBars: 8, kit: .original),
                          FormTask(level: 0, phraseBars: 8, kit: .changed("ff")))
        XCTAssertEqual(
            FormTask(level: 0, phraseBars: 8,
                     kit: .changed(KitGroup.velocityLayeredFingerprint)).title,
            "Form drill — level 0, 8-bar phrases, kit velocity layers")
    }

    // MARK: The continuation drill, whose rung rule is the opposite one

    /// `LESSONS.md` shape 13. The drill has demanded one note per beat *in words* since M6, so
    /// grouping `nil` apart from `.quarters` would split one task on a distinction the player was
    /// never shown.
    func testAnAbsentRungReallyDoesMeanQuartersHere() {
        XCTAssertEqual(ContinuationTask(silentBars: 4, rung: nil, kit: .original),
                       ContinuationTask(silentBars: 4, rung: "quarters", kit: .original))
    }

    func testSilenceLengthAndRungAreBothTaskChanges() {
        XCTAssertNotEqual(ContinuationTask(silentBars: 4, rung: nil, kit: .original),
                          ContinuationTask(silentBars: 8, rung: nil, kit: .original))
        XCTAssertNotEqual(ContinuationTask(silentBars: 4, rung: "eighths", kit: .original),
                          ContinuationTask(silentBars: 4, rung: "quarters", kit: .original))
        XCTAssertEqual(ContinuationTask(silentBars: 4, rung: nil, kit: .original).title,
                       "Continuation drill — 4-bar silences, quarter notes")
    }

    // MARK: The form drill's two axes

    private func form(_ level: Int, _ phraseBars: Int) -> FormTask {
        FormTask(level: level, phraseBars: phraseBars, kit: .original)
    }

    func testLevelAndPhraseLengthAreBothTaskChanges() {
        XCTAssertNotEqual(form(0, 8), form(1, 8))
        XCTAssertNotEqual(form(0, 8), form(0, 16))
        XCTAssertEqual(form(2, 16).title, "Form drill — level 2, 16-bar phrases")
    }

    func testFormGroupsSortByLevelThenSpan() {
        XCTAssertEqual([form(1, 4), form(0, 16), form(0, 8)].sorted().map(\.phraseBars),
                       [8, 16, 4])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
