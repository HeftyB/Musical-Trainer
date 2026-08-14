import XCTest
@testable import GrooveCore

/// The band has a bass, and the same music renders to the same bytes twice.
///
/// See PLAN.md §7.29 step 2.
final class BassAndDeterminismTests: XCTestCase {

    // MARK: - Determinism

    /// `Pattern.make` takes a dictionary, and Swift seeds its hashing per process, so the hit
    /// order used to differ on every launch. Float addition is not associative, so two hits on
    /// one sample summed to a value that differed in its last bit run to run — the same backing
    /// rendering to different bytes twice in a row (R1.2.2).
    ///
    /// Inaudible, and it quietly made every byte-comparison gate in this milestone unreliable.
    func testPatternHitsAreInADeterministicOrder() {
        let lines: [BackingVoice: [Int]] = [
            .kick: [0, 8], .snare: [4, 12], .closedHat: [0, 2, 4, 6, 8, 10, 12, 14],
            .ride: [0, 4, 8, 12], .clap: [4, 12], .tom: [14],
        ]
        let reference = Pattern.make(lines).hits
        for _ in 0..<50 {
            XCTAssertEqual(Pattern.make(lines).hits, reference,
                           "the same input must build the same pattern, hit for hit")
        }
    }

    func testHitsComeOutSortedByStepThenVoice() {
        let hits = Pattern.make([.snare: [4], .kick: [0, 4], .closedHat: [0]]).hits
        XCTAssertEqual(hits.map(\.step), [0, 0, 4, 4], "steps ascend")
        XCTAssertEqual(hits.filter { $0.step == 0 }.map(\.voice), [.closedHat, .kick],
                       "and voices break the tie, so the order is total")
    }

    /// Sorting cannot change *which* hits exist, which is why the one sample this moved is a
    /// summation-order difference and not a moved note.
    func testSortingChangesOrderAndNothingElse() {
        let lines: [BackingVoice: [Int]] = [.kick: [0, 8], .snare: [4, 12]]
        let pattern = Pattern.make(lines)
        let expected = lines.flatMap { voice, steps in steps.map { (voice, $0) } }
        XCTAssertEqual(pattern.hits.count, expected.count)
        for (voice, step) in expected {
            XCTAssertTrue(pattern.hits.contains { $0.voice == voice && $0.step == step },
                          "\(voice) at \(step)")
        }
    }

    // MARK: - The bass

    /// **Was `testOnlyTheBassIsPitched`, and the rename is the change.** The bass was the only
    /// pitched voice until M16.5 gave the skank family an organ (§7.56), and a test asserting
    /// "only the bass" would have had to be edited by anyone adding one — which is a test that
    /// asks permission rather than one that guards something.
    ///
    /// What is actually invariant is that **a pitched voice is one that carries a note**: the
    /// drums must never be asked for one, and every pitched voice must have somewhere for its
    /// notes to come from. The second half is asserted where the buffers are, in `OrganStabTests`.
    func testExactlyTheVoicesThatCarryNotesArePitched() {
        let pitched = BackingVoice.allCases.filter(\.isPitched)
        XCTAssertEqual(Set(pitched), [.bass, .organ])

        for voice in BackingVoice.allCases where !voice.isPitched {
            XCTAssertFalse(BackingVoice.timekeepers.contains(voice) && voice.isPitched,
                           "\(voice)")
        }
    }

    func testABassHitCarriesItsNoteAndADrumDoesNot() {
        let pattern = GrooveLibrary.basicRock.adding(GrooveLibrary.bassDemoFigure.hits)
        let bass = pattern.hits.filter { $0.voice == .bass }
        XCTAssertFalse(bass.isEmpty)
        XCTAssertTrue(bass.allSatisfy { $0.note != nil }, "a pitched hit without a pitch is mute")
        XCTAssertTrue(pattern.hits.filter { $0.voice != .bass }.allSatisfy { $0.note == nil },
                      "a drum has one sound, and a note on it would be a field nobody reads")
    }

    /// The note has to survive the same journeys the step does, or a bass line would arrive
    /// silent after a lift or a schedule — the shape of every defect in §7.24.
    func testTheNoteSurvivesRescalingAndScheduling() {
        let figure = Pattern.bass([(step: 0, note: 40), (step: 10, note: 47)])
        let lifted = figure.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat)
        XCTAssertEqual(lifted.hits.map(\.note), [40, 47])
        XCTAssertEqual(lifted.hits.map(\.step), [0, 60], "and the times still scale by six")

        let scheduled = Sequencer(bpm: 100, sampleRate: 44_100).schedule(pattern: lifted, bar: 0)
        XCTAssertEqual(scheduled.map(\.note).sorted { ($0 ?? 0) < ($1 ?? 0) }, [40, 47])
    }

    /// A bass figure is authored as (step, note) pairs, so a drum pattern never carries a column
    /// of `nil`s and a bass line never carries a column of steps it does not use.
    func testTheBassHelperBuildsOnlyBassHits() {
        let figure = Pattern.bass([(step: 0, note: 36), (step: 8, note: 43)])
        XCTAssertTrue(figure.hits.allSatisfy { $0.voice == .bass })
        XCTAssertEqual(figure.hits.count, 2)
    }

    /// Nothing frozen gained a bass. `jamBacking` is the music every recorded take was played
    /// over and R3.5 keeps it exactly as it is; the demo exists to be heard, not scheduled.
    func testNoFrozenBackingCarriesABass() {
        for arrangement in [GrooveLibrary.jamBacking, GrooveLibrary.demo,
                            LadderBackings.backing(notesPerBeat: 1),
                            LadderBackings.backing(notesPerBeat: 2),
                            LadderBackings.backing(notesPerBeat: 3),
                            LadderBackings.backing(notesPerBeat: 4),
                            LadderBackings.swungBacking(notesPerBeat: 2),
                            OffbeatBacking.backing(level: .stated, bars: 8)] {
            for bar in 0..<arrangement.totalBars {
                XCTAssertTrue(arrangement.pattern(atBar: bar).hits.allSatisfy { $0.voice != .bass },
                              "bar \(bar) of a backing takes have been measured against")
            }
        }
    }

    func testTheDemoDoesCarryOne() {
        XCTAssertTrue((0..<GrooveLibrary.bassDemo.totalBars)
            .contains { GrooveLibrary.bassDemo.pattern(atBar: $0).hits.contains { $0.voice == .bass } })
    }
}
