import XCTest
@testable import GrooveCore

/// A style is authored once and plays at any intensity.
///
/// The format is what M19 step 3 is proving; the two styles exist to prove it holds a sparse
/// hat-led groove and a busy sixteenth-led one without either being a special case. See PLAN.md
/// §7.29 step 3.
final class StyleTests: XCTestCase {

    // MARK: - The format

    /// Intensity adds and removes layers. It never moves a hit, and it never may: the backing is
    /// the ruler the player is measured against, so a bar that is louder must be the *same* bar
    /// with more in it.
    ///
    /// **Asserted per instrument and step rather than per hit, and that is a correction rather
    /// than a relaxation.** The first version required the louder bar to contain each quieter
    /// hit *identically*, which is stronger than the invariant above and forbids something the
    /// invariant permits: an open hat entering on a step the hat line already plays replaces the
    /// closed hat there, because a hi-hat cannot be open and closed at once (§7.31 finding 2).
    /// Nothing moves — same step, same instrument, same sample, louder articulation — so the
    /// ruler is unchanged and the bar is still the quiet bar with more in it.
    ///
    /// The rewritten form is stronger in the direction that matters: a step that sounded quietly
    /// may not fall *silent* when the music gets louder, whatever voice it was written for.
    /// `LESSONS.md` shape 4 — the assertion was a proxy for the claim its own name makes.
    func testIntensityOnlyEverAddsToWhatWasAlreadyPlaying() {
        // A hit's instrument: its articulation group where it has one, so an open hat and a
        // closed hat on one step count as the same hi-hat rather than as two voices.
        func instrument(_ hit: Hit) -> String {
            BackingVoice.articulation(of: hit.voice).map { "group \($0.group)" } ?? hit.voice.rawValue
        }
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange.dropLast() {
                let quiet = style.pattern(atBar: 0, intensity: intensity)
                let loud = style.pattern(atBar: 0, intensity: intensity + 1)
                let sounding = Set(loud.hits.map { "\($0.step):\(instrument($0))" })
                for hit in quiet.hits {
                    XCTAssertTrue(sounding.contains("\(hit.step):\(instrument(hit))"),
                                  "\(style.name): raising the intensity silenced \(hit.voice) at "
                                + "step \(hit.step), so the two bars are different music rather "
                                + "than the same music with more of it")
                }
                XCTAssertGreaterThanOrEqual(loud.hits.count, quiet.hits.count, style.name)
            }
        }
    }

    /// The other half of the same invariant, and the one the rewrite above must not have lost:
    /// a hit that is *not* an articulation of something else survives a rise in intensity
    /// unchanged — same voice, same step, same velocity. Only a hi-hat may be superseded.
    func testOnlyAnArticulationOfTheSameInstrumentMayBeSuperseded() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange.dropLast() {
                let quiet = style.pattern(atBar: 0, intensity: intensity)
                let loud = style.pattern(atBar: 0, intensity: intensity + 1)
                for hit in quiet.hits where BackingVoice.articulation(of: hit.voice) == nil {
                    XCTAssertTrue(loud.hits.contains(hit),
                                  "\(style.name): \(hit.voice) at step \(hit.step) is not an "
                                + "articulation of anything and must survive untouched")
                }
            }
        }
    }

    func testEveryStyleHasASkeletonThatPlaysAtTheQuietestIntensity() {
        for style in StyleLibrary.all {
            let bar = style.pattern(atBar: 0, intensity: Style.intensityRange.lowerBound)
            XCTAssertFalse(bar.hits.isEmpty, "\(style.name) is silent at intensity 0")
            XCTAssertTrue(bar.hits.contains { $0.voice == .kick }, style.name)
        }
    }

    func testLayersOfDifferentLengthsCycleAtTheirOwnRate() {
        // Rock's bass is two bars against a one-bar hat, so bar 0 and bar 1 must differ while
        // bar 0 and bar 2 agree.
        let style = StyleLibrary.driving
        XCTAssertNotEqual(style.pattern(atBar: 0, intensity: 3),
                          style.pattern(atBar: 1, intensity: 3))
        XCTAssertEqual(style.pattern(atBar: 0, intensity: 3),
                       style.pattern(atBar: 2, intensity: 3))
    }

    func testEveryBarComesOutOnTheCommonGridAndSorted() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                for bar in 0..<8 {
                    let p = style.pattern(atBar: bar, intensity: intensity)
                    XCTAssertEqual(p.stepsPerBeat, Pattern.commonStepsPerBeat, style.name)
                    let keys = p.hits.map { [$0.step, Int($0.voice.rawValue.count)] }
                    XCTAssertEqual(p.hits.map(\.step), p.hits.map(\.step).sorted(),
                                   "\(style.name): merged hits must be ordered, or the mix sums "
                                 + "them in a different order run to run \(keys.count)")
                }
            }
        }
    }

    func testTheSameArgumentsAlwaysGiveTheSameBar() {
        for style in StyleLibrary.all {
            let reference = style.pattern(atBar: 3, intensity: 2)
            for _ in 0..<20 {
                XCTAssertEqual(style.pattern(atBar: 3, intensity: 2), reference, style.name)
            }
        }
    }

    func testANegativeBarIndexDoesNotTrap() {
        for style in StyleLibrary.all {
            XCTAssertFalse(style.pattern(atBar: -1, intensity: 3).hits.isEmpty, style.name)
        }
    }

    // MARK: - The roadmap hooks

    /// M20 inverts the roles: the player becomes the drummer and the backing becomes the click.
    /// Declaring which voices that means while the style is being written is easy; inferring it
    /// afterwards is guesswork.
    func testEveryStyleSaysWhichVoicesThePlayerWouldTake() {
        for style in StyleLibrary.all {
            XCTAssertFalse(style.playerVoices.isEmpty, style.name)
            XCTAssertFalse(style.playerVoices.contains(.bass),
                           "\(style.name): a drummer sitting in does not take the bass")
            let sounded = Set((0..<4).flatMap { bar in
                style.pattern(atBar: bar, intensity: 3).hits.map(\.voice)
            })
            XCTAssertTrue(style.playerVoices.isSubset(of: sounded.union([.crash, .tom])),
                          "\(style.name) claims voices it never plays")
        }
    }

    func testDensityIsDeclaredAndBassIsDerived() {
        XCTAssertEqual(StyleLibrary.driving.density, .medium)
        XCTAssertEqual(StyleLibrary.pocket.density, .busy,
                       "a tambourine on every eighth is hard to hear a voice through (M24)")
        for style in StyleLibrary.all {
            XCTAssertTrue(style.carriesBass,
                          "\(style.name): derived from the layers, so it cannot drift from them")
        }
    }

    func testStylesAreFoundByTheNameTheyWillBeStoredUnder() {
        for style in StyleLibrary.all {
            XCTAssertEqual(StyleLibrary.named(style.name)?.name, style.name)
            XCTAssertEqual(style.name, style.name.lowercased(), "stored, so it stays stable")
        }
        XCTAssertNil(StyleLibrary.named("bossa"), "not yet authored, and it must not pretend")
    }

    // MARK: - The audition gate

    /// §7.23's rule — do not promote a player onto something nobody has heard — has been prose
    /// since M14, and prose is what a hurried afternoon ignores. It is a flag now, and the
    /// planner will schedule only styles that carry it.
    ///
    /// **Nothing sets it but the person who has to play over the groove.** Whether a style is
    /// worth thirty minutes is not a property of its step list, so an author cannot honestly
    /// mark their own work.
    func testANewlyAuthoredStyleIsNotAuditioned() {
        let fresh = Style(name: "test", layers: [Layer(Pattern.make([.kick: [0]]))],
                          fills: [], playerVoices: [.kick], density: .sparse)
        XCTAssertFalse(fresh.auditioned, "the default has to be no, or the gate is decorative")
    }

    func testTheAuditionedListIsASubsetOfTheAuthoredOne() {
        XCTAssertTrue(Set(StyleLibrary.auditioned.map(\.name))
            .isSubset(of: Set(StyleLibrary.all.map(\.name))))
        for style in StyleLibrary.auditioned {
            XCTAssertTrue(style.auditioned, style.name)
        }
    }

    /// The state of the library today, asserted so that flipping a style to auditioned is a
    /// deliberate edit that shows up in a diff rather than something that drifts.
    func testTheLibraryHoldsFourStylesAndAllFourAreApproved() {
        // Descriptive, not generic: none of these claims a genre, because none of them is one
        // yet. The names come back when M26's kit earns them (§7.30).
        XCTAssertEqual(StyleLibrary.all.map(\.name).sorted(),
                       ["driving", "half-time", "pocket", "syncopated"])
        XCTAssertTrue(StyleLibrary.all.allSatisfy { style in
            !["rock", "motown", "funk", "jazz", "bossa", "reggae", "ska", "soul", "hip-hop"]
                .contains(style.name)
        }, "a genre name is a promise the kit cannot keep yet")
        // **Approved on 8 August 2026, and this assertion is the record that it was a decision.**
        // The flag was false from the day it was written; flipping it failed three tests, which is
        // what §7.29 step 5 built it for — an approval that arrives in a diff rather than drifting.
        //
        // What each rests on differs and §7.33 says so: `driving` and `half-time` were played over,
        // `pocket` and `syncopated` were listened to at every intensity and never played. A style
        // added later starts at `false` again and this test fails until somebody says otherwise.
        // **Withdrawn in §7.68** because all four kits changed, then given back across two listening
        // passes in §7.69: `driving` and `pocket` on the first, `syncopated` and `half-time` after
        // the retune their verdicts asked for. Back to four, on new drums this time.
        XCTAssertEqual(StyleLibrary.auditioned.count, 4,
                       "approving or retiring a style is a deliberate edit, and this is where it "
                     + "shows up")
    }

    func testTheLibraryCoversTheDensitiesTheRoadmapNeeds() {
        let densities = Set(StyleLibrary.all.map(\.density))
        XCTAssertTrue(densities.contains(.sparse),
                      "M24's vocal drills need something a voice can be heard through")
        XCTAssertTrue(densities.contains(.busy), "and something worth playing over")
    }

    // MARK: - Nothing is scheduled yet

    /// Step 3 adds a format and two styles. Until the generator and the planner have had their
    /// say, no take may be recorded over any of it.
    func testNoStyleIsReachableFromAFrozenBacking() {
        let frozen = [GrooveLibrary.jamBacking, GrooveLibrary.demo,
                      LadderBackings.backing(notesPerBeat: 2),
                      OffbeatBacking.backing(level: .stated, bars: 8)]
        let styleHits = Set(StyleLibrary.all.flatMap { style in
            (0..<4).flatMap { style.pattern(atBar: $0, intensity: 3).hits.map(\.voice) }
        })
        XCTAssertTrue(styleHits.contains(.bass), "the styles do use the new voice")
        for arrangement in frozen {
            for bar in 0..<arrangement.totalBars {
                XCTAssertFalse(arrangement.pattern(atBar: bar).hits.contains { $0.voice == .bass },
                               "a backing takes have been measured against gained a bass")
            }
        }
    }
}
