import XCTest
@testable import GrooveCore

/// The organ bubble's two candidate figures, and the property that makes both of them the skank.
///
/// M16.5's premise is that "hold a position the band never plays" generalises from one position to
/// a set. The invariant that carries across the whole family is **nothing on the beat** — if a
/// candidate figure ever states the beat it is playing along, not skanking, and the drill measures
/// something else entirely.
final class BubbleBackingTests: XCTestCase {

    // MARK: The invariant the family is built on

    /// The figure never lands on a beat, at any feel, at any level. The band's *downbeat* may be
    /// there — that is the ladder — but the bubble itself never is.
    func testTheFigureNeverPlaysOnABeat() {
        for feel in BubbleFeel.allCases {
            for level in OffbeatLevel.allCases {
                for bar in 0..<8 {
                    let pattern = BubbleBacking.pattern(feel: feel, level: level, bar: bar)
                    let figure = pattern.hits.filter { $0.voice == .organ }
                    XCTAssertFalse(figure.isEmpty, "\(feel) \(level): no figure at all")
                    for hit in figure {
                        XCTAssertNotEqual(hit.step % pattern.stepsPerBeat, 0,
                                          "\(feel) level \(level.rawValue) bar \(bar): the bubble "
                                        + "landed on a beat at step \(hit.step)")
                    }
                }
            }
        }
    }

    /// Two *positions* per beat, eight to the bar, whichever feel — so the two candidates differ
    /// in *where* rather than in *how many*, which is what makes the A/B about placement.
    ///
    /// Counted as distinct steps rather than as hits, because a stab is a voicing: §7.56 puts two
    /// notes on each, and a test that counted hits would have to be edited every time the chord
    /// changed. The figure is its steps.
    func testBothFeelsPlayTwoPositionsPerBeat() {
        for feel in BubbleFeel.allCases {
            let pattern = BubbleBacking.pattern(feel: feel, level: .stated, bar: 0)
            let steps = Set(pattern.hits.filter { $0.voice == .organ }.map(\.step))
            XCTAssertEqual(steps.count, 8, "\(feel)")
        }
    }

    /// Every stab sounds the whole voicing — a note missing from one of them is a chord that
    /// changes shape mid-bar, which no test above would notice.
    func testEveryStabSoundsTheWholeVoicing() {
        for feel in BubbleFeel.allCases {
            let hits = BubbleBacking.pattern(feel: feel, level: .stated, bar: 0)
                .hits.filter { $0.voice == .organ }
            for (step, group) in Dictionary(grouping: hits, by: \.step) {
                XCTAssertEqual(group.compactMap(\.note).sorted(), BubbleBacking.voicing.sorted(),
                               "\(feel) step \(step)")
            }
        }
    }

    /// The voicing states no key quality, which is the bass's rule (§7.29 step 2) and stays true
    /// while harmony belongs to M25. A third would be 4 or 3 semitones off the root.
    func testTheVoicingCommitsToNoKeyQuality() {
        let intervals = BubbleBacking.voicing.map { $0 - BubbleBacking.voicing[0] }
        XCTAssertFalse(intervals.contains(3), "a minor third states a key quality")
        XCTAssertFalse(intervals.contains(4), "a major third states a key quality")
    }

    /// The steps each feel is named for, asserted outright rather than derived from the code under
    /// test — a triplet bubble that quietly became a sixteenth one would still pass every
    /// structural check above (`LESSONS.md` shape 4).
    func testEachFeelPlaysTheStepsItIsNamedFor() {
        let triplet = BubbleBacking.pattern(feel: .triplet, level: .implied, bar: 1)
        XCTAssertEqual(triplet.stepsPerBeat, 3)
        XCTAssertEqual(Set(triplet.hits.filter { $0.voice == .organ }.map(\.step)).sorted(),
                       [1, 2, 4, 5, 7, 8, 10, 11])

        let sixteenth = BubbleBacking.pattern(feel: .sixteenth, level: .implied, bar: 1)
        XCTAssertEqual(sixteenth.stepsPerBeat, 4)
        XCTAssertEqual(Set(sixteenth.hits.filter { $0.voice == .organ }.map(\.step)).sorted(),
                       [2, 3, 6, 7, 10, 11, 14, 15])
    }

    /// No layer at one velocity — the rule an ear found in §7.29 and the reason eight identical
    /// hits a bar read as a metronome rather than as a part.
    func testTheFigureLeans() {
        for feel in BubbleFeel.allCases {
            let velocities = Set(BubbleBacking.pattern(feel: feel, level: .stated, bar: 0)
                .hits.filter { $0.voice == .organ }.map(\.velocity))
            XCTAssertGreaterThan(velocities.count, 1, "\(feel) plays at one velocity")
        }
    }

    // MARK: The downbeat ladder, shared with the straight skank

    /// Each level removes what its name says, on the beats — not on the figure.
    func testTheLadderRemovesTheDownbeatAndNeverTheFigure() {
        for feel in BubbleFeel.allCases {
            let counts = OffbeatLevel.allCases.map { level -> Int in
                BubbleBacking.pattern(feel: feel, level: level, bar: 1, phraseBars: 4)
                    .hits.filter { $0.voice != .organ }.count
            }
            XCTAssertEqual(counts, [4, 3, 2, 0], "\(feel): the ladder is not monotone")
        }
    }

    /// The hardest level keeps one marker at the top of a phrase, for the reason `OffbeatBacking`
    /// gives: with nothing on a beat, a player can hear their own figure as the downbeat, and once
    /// that flips every later note is scored against the wrong points.
    func testTheHardestLevelStillAnchorsEachPhrase() {
        for feel in BubbleFeel.allCases {
            let top = BubbleBacking.pattern(feel: feel, level: .implied, bar: 4, phraseBars: 4)
            XCTAssertEqual(top.hits.filter { $0.voice == .kick }.count, 1, "\(feel) phrase top")

            let inside = BubbleBacking.pattern(feel: feel, level: .implied, bar: 5, phraseBars: 4)
            XCTAssertTrue(inside.hits.allSatisfy { $0.voice == .organ }, "\(feel) mid-phrase")
        }
    }

    // MARK: The geometry that decides the tempo

    /// §7.38 found that tempo changes this family's task rather than only its speed, because each
    /// note lands at a point whose neighbours nobody plays. Generalised to a *set* of positions,
    /// the quantity is the **closest approach** any note makes to a beat — and the two candidates
    /// differ on it, so neither inherits the offbeat drill's 70 BPM default and they cannot share
    /// one either.
    ///
    /// This test was written asserting the wrong thing first: that both bubbles sit tighter than
    /// the straight chop, measured from the *first* note of each pair. The sixteenth bubble's first
    /// note **is** the chop, and it is its second note that is tight. Kept as an ordering assertion
    /// on real fractions rather than a claim about which note matters (JOURNAL.md §7.55).
    func testTheCandidatesSitAtDifferentDistancesFromTheBeat() {
        XCTAssertEqual(BubbleFeel.triplet.closestApproachFraction, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(BubbleFeel.sixteenth.closestApproachFraction, 0.25, accuracy: 1e-9)

        // The straight skank's chop, for scale: half a beat, the loosest of the three.
        XCTAssertLessThan(BubbleFeel.triplet.closestApproachFraction, 0.5)
        XCTAssertLessThan(BubbleFeel.sixteenth.closestApproachFraction,
                          BubbleFeel.triplet.closestApproachFraction,
                          "the sixteenth bubble is the tightest figure in the family")
    }

    /// The difference that decides what M16.5 measures: one candidate contains a position this
    /// player already holds at 100%, and the other does not.
    func testOnlyTheSixteenthBubbleContainsTheStraightChop() {
        XCTAssertTrue(BubbleFeel.sixteenth.containsTheStraightChop,
                      "the \"and\" is the chop — the sixteenth bubble extends the existing drill")
        XCTAssertFalse(BubbleFeel.triplet.containsTheStraightChop,
                       "both triplet partials are positions the corpus has nothing on")
    }

    /// The gap scales with tempo, which is the whole reason it is computed rather than tabulated.
    func testTheGapHalvesWhenTheTempoDoubles() {
        for feel in BubbleFeel.allCases {
            XCTAssertEqual(feel.closestApproachMs(atBpm: 140),
                           feel.closestApproachMs(atBpm: 70) / 2, accuracy: 0.001, "\(feel)")
        }
    }
}
