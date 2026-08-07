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
    func testIntensityOnlyEverAddsToWhatWasAlreadyPlaying() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange.dropLast() {
                let quiet = style.pattern(atBar: 0, intensity: intensity)
                let loud = style.pattern(atBar: 0, intensity: intensity + 1)
                for hit in quiet.hits {
                    XCTAssertTrue(loud.hits.contains(hit),
                                  "\(style.name): raising the intensity dropped \(hit.voice) at "
                                + "step \(hit.step), so the two bars are different music rather "
                                + "than the same music with more of it")
                }
                XCTAssertGreaterThanOrEqual(loud.hits.count, quiet.hits.count, style.name)
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
        let style = StyleLibrary.rock
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
        XCTAssertEqual(StyleLibrary.rock.density, .medium)
        XCTAssertEqual(StyleLibrary.motown.density, .busy,
                       "a tambourine on every sixteenth is hard to hear a voice through (M24)")
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
