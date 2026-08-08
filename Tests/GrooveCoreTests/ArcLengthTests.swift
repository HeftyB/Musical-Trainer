import XCTest
@testable import GrooveCore

/// A piece has to be long enough to contain its own intensity arc.
///
/// `render` generated a seeded piece at 32 bars and wrote the command's bar count, so
/// `render 100 8` — the invocation `AGENT.md` documents — produced **one 8-bar phrase at one
/// intensity**. The arc is the part of M19 a step list cannot judge, and the argument for choosing
/// it from five shapes rather than sampling per phrase is entirely about how a piece *moves*
/// (§7.29 step 4). Nobody had ever heard one move. See PLAN.md §7.31 finding 3.
///
/// The length lives here rather than as a literal in the render command because it is a property
/// of the arc table: adding a five-phrase shape must lengthen the audition, not be truncated by it
/// (`LESSONS.md` shape 9).
final class ArcLengthTests: XCTestCase {

    private let seeds: [UInt64] = [1, 42, 0x5EED_0001, 0xDEAD_BEEF]

    /// Which intensity a bar is playing, found by matching against what the style produces.
    /// Exact rather than inferred from hit count — since §7.31 finding 2 an open hat supersedes a
    /// closed one, so two intensities of `driving` can have the *same* number of hits.
    private func intensity(of piece: Arrangement, bar: Int, in style: Style) -> Int? {
        Style.intensityRange.first { style.pattern(atBar: bar, intensity: $0)
                                        == piece.pattern(atBar: bar) }
    }

    func testAFullArcLengthPieceActuallyChangesIntensity() {
        let bars = StyleArranger.barsForAFullArc()
        for style in StyleLibrary.all {
            for seed in seeds {
                let piece = StyleArranger.arrangement(style: style, seed: seed, bars: bars)
                // Phrase starts only: a fill lands on the last bar of a phrase, and layers cycle
                // at their own lengths — with an even phrase length every phrase start sits at
                // the same point in a two-bar bass figure, so a difference here is intensity and
                // nothing else.
                let intensities = stride(from: 0, to: bars, by: StyleArranger.defaultPhraseBars)
                    .compactMap { intensity(of: piece, bar: $0, in: style) }
                XCTAssertEqual(intensities.count, StyleArranger.arcPhrases,
                               "\(style.name)@\(seed): a phrase start matched no intensity")
                XCTAssertGreaterThan(Set(intensities).count, 1,
                    "\(style.name)@\(seed) holds one intensity across a whole arc, so the "
                  + "audition would sound like a loop rather than like music going somewhere")
            }
        }
    }

    /// The defect, stated: one phrase is one intensity, whatever the arc says. This is what
    /// `render 100 8` was writing, and it is why the floor exists.
    func testASinglePhraseCannotShowAnArcAtAll() {
        let bars = StyleArranger.defaultPhraseBars
        for style in StyleLibrary.all {
            for seed in seeds {
                let piece = StyleArranger.arrangement(style: style, seed: seed, bars: bars)
                let intensities = (0..<bars).compactMap { intensity(of: piece, bar: $0, in: style) }
                XCTAssertEqual(Set(intensities).count, 1,
                               "\(style.name)@\(seed): a phrase is one intensity by construction")
            }
        }
    }

    /// The length is derived from the arc table, not written beside it. Adding a longer shape
    /// without lengthening the audition is the failure this asserts against.
    func testTheFullArcLengthCoversTheLongestShape() {
        XCTAssertEqual(StyleArranger.arcPhrases, StyleArranger.arcs.map(\.count).max())
        XCTAssertEqual(StyleArranger.barsForAFullArc(),
                       StyleArranger.defaultPhraseBars * StyleArranger.arcPhrases)
        // M16 grows the phrase to 16 and 32 bars; the audition has to grow with it.
        XCTAssertEqual(StyleArranger.barsForAFullArc(phraseBars: 32),
                       32 * StyleArranger.arcPhrases)
    }

    /// Rendering longer must not mean rendering *different* music: the first phrase of a long
    /// piece is the first phrase of a short one, which is what lets a sitting keep one seed and
    /// still choose its length (§7.29 step 4's draw-before-the-loop rule).
    func testALongerPieceOpensTheSameWay() {
        for style in StyleLibrary.all {
            for seed in seeds {
                let short = StyleArranger.arrangement(style: style, seed: seed,
                                                      bars: StyleArranger.defaultPhraseBars)
                let long = StyleArranger.arrangement(style: style, seed: seed,
                                                     bars: StyleArranger.barsForAFullArc())
                for bar in 0..<StyleArranger.defaultPhraseBars {
                    XCTAssertEqual(short.pattern(atBar: bar), long.pattern(atBar: bar),
                                   "\(style.name)@\(seed) bar \(bar) differs with length")
                }
            }
        }
    }
}
