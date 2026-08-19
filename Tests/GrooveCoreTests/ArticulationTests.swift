import XCTest
@testable import GrooveCore

/// One instrument, one state at a time.
///
/// A hi-hat cannot be open and closed at the same instant. `driving` played the closed hat on step
/// 14 and the open hat on step 14 from intensity 2, and `syncopated` did it on steps 6 and 14 at
/// intensity 3 — so instead of the open hat *replacing* the closed one, which is what the gesture
/// is, both buffers sounded and a 45 ms "tss" sat on top of a 1.2-second wash.
///
/// **`doubledTimekeepers` cannot catch this and should not be widened to.** That rule is about two
/// voices keeping the same *pulse*, and it ignores a voice with fewer than three hits a bar so an
/// occasional ride hit is not mistaken for a second drummer. An open hat is exactly that occasional
/// hit. Doubling a pulse and doubling an instrument are different mistakes with different fixes.
/// See JOURNAL.md §7.31 finding 2.
final class ArticulationTests: XCTestCase {

    /// The property that matters: whatever is authored, nothing impossible reaches the sequencer.
    func testNoStyleSoundsOneInstrumentTwoWaysAtAnyIntensity() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                // Two bars, because a layer may cycle over two and the collision can live in
                // either — `driving`'s bass figure is two bars long and its hat line is one.
                for bar in 0..<2 {
                    let pattern = style.pattern(atBar: bar, intensity: intensity)
                    var seen: Set<String> = []
                    for hit in pattern.hits {
                        guard let (group, _) = BackingVoice.articulation(of: hit.voice) else {
                            continue
                        }
                        let key = "\(hit.step):\(group)"
                        XCTAssertFalse(seen.contains(key),
                            "\(style.name) at intensity \(intensity), bar \(bar) sounds two "
                          + "articulations of one instrument on step \(hit.step)")
                        seen.insert(key)
                    }
                }
            }
        }
    }

    /// The defect itself, named. Reverting the call in `Style.pattern` fails this.
    func testTheOpenHatReplacesTheClosedOneRatherThanStackingWithIt() {
        let driving = StyleLibrary.driving.pattern(atBar: 0, intensity: 2)
        let step = 14 * (Pattern.commonStepsPerBeat / 4)
        XCTAssertTrue(driving.hits.contains { $0.voice == .openHat && $0.step == step },
                      "the open hat on the and of four is the whole gesture")
        XCTAssertFalse(driving.hits.contains { $0.voice == .closedHat && $0.step == step },
                       "a closed hat under an open one is two hi-hats")
    }

    /// The quieter half of the same defect, and the reason it needs its own assertion: at
    /// intensity 3 `syncopated` runs sixteenths on the hat, so the open hat lands on two steps
    /// the hat line already occupies rather than one.
    func testSyncopatedLosesBothCollidingClosedHats() {
        let pattern = StyleLibrary.syncopated.pattern(atBar: 0, intensity: 3)
        let scale = Pattern.commonStepsPerBeat / 4
        for step in [6 * scale, 14 * scale] {
            XCTAssertTrue(pattern.hits.contains { $0.voice == .openHat && $0.step == step },
                          "open hat missing at \(step)")
            XCTAssertFalse(pattern.hits.contains { $0.voice == .closedHat && $0.step == step },
                           "closed hat survived under the open hat at \(step)")
        }
    }

    /// Resolution removes and never adds or moves, so everything else in the bar is untouched —
    /// the backing is the ruler the player is measured against, and a rule that repositioned a
    /// hit to avoid a collision would be measurement error attributed to the player.
    func testResolutionOnlyEverRemoves() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                let resolved = style.pattern(atBar: 0, intensity: intensity)
                let raw = style.layers.filter { $0.entersAt <= intensity }
                    .flatMap { $0.bars[0].rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat).hits }
                for hit in resolved.hits {
                    XCTAssertTrue(raw.contains(hit),
                                  "\(style.name) at \(intensity) invented or moved a hit")
                }
                XCTAssertLessThanOrEqual(resolved.hits.count, raw.count)
            }
        }
    }

    /// Sorted output is not cosmetic: merged hit order decides float summation order in the mix,
    /// and an unsorted merge renders to different bytes run to run (§7.29 step 2). A filter that
    /// preserves order keeps that; one that rebuilt the array might not.
    func testResolvedHitsStaySorted() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                let hits = style.pattern(atBar: 0, intensity: intensity).hits
                for (a, b) in zip(hits, hits.dropFirst()) {
                    XCTAssertTrue((a.step, a.voice.rawValue) <= (b.step, b.voice.rawValue),
                                  "\(style.name) at \(intensity) is out of order")
                }
            }
        }
    }

    /// Interlocking articulations of *different* instruments are ordinary music and must survive:
    /// a closed hat on the downbeats against a shaker on the offbeats is one pulse shared between
    /// two hands. The same distinction `doubledTimekeepers` had to learn.
    func testTwoDifferentInstrumentsOnOneStepAreUntouched() {
        let hits = [Hit(voice: .kick, step: 0), Hit(voice: .closedHat, step: 0),
                    Hit(voice: .snare, step: 0)]
        XCTAssertEqual(BackingVoice.resolvingArticulations(hits).count, 3,
                       "a kit plays several instruments at once; that is what a kit is")
    }
}
