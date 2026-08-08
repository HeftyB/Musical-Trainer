import XCTest
@testable import GrooveCore

/// Unbounded music from bounded authoring, and reproducible for ever.
///
/// The seed is stored on the take inside `grooveName`, which is what makes generation
/// permissible rather than reckless: R1.2.2 says a result that cannot be reproduced from stored
/// data is not a result. See PLAN.md §7.29 step 4.
final class StyleArrangerTests: XCTestCase {

    private let style = StyleLibrary.driving

    // MARK: - Reproducible

    func testTheSameSeedGivesTheSameMusic() {
        for seed in [0, 1, 0xDEAD_BEEF, UInt64.max] as [UInt64] {
            let a = StyleArranger.arrangement(style: style, seed: seed, bars: 32)
            let b = StyleArranger.arrangement(style: style, seed: seed, bars: 32)
            XCTAssertEqual(a, b, "seed \(seed)")
        }
    }

    func testDifferentSeedsGiveDifferentMusic() {
        let pieces = (0..<24).map {
            StyleArranger.arrangement(style: style, seed: UInt64($0), bars: 32)
        }
        let distinct = Set(pieces.map { piece in
            (0..<piece.totalBars).map { piece.pattern(atBar: $0).hits.count }
                .map(String.init).joined(separator: ",")
        })
        XCTAssertGreaterThan(distinct.count, 2,
                             "24 seeds produced \(distinct.count) shapes — the seed is barely "
                           + "reaching the music")
    }

    /// A take's music has to be reconstructible from what was stored, years later, without the
    /// generator having to be frozen in amber.
    func testAPieceIsReproducibleFromTheNameAloneOnTheTake() throws {
        let identity = BackingIdentity(style: "driving", seed: 0x8F3A_21C4)

        let parsed = try XCTUnwrap(BackingIdentity.parse(identity.name))
        XCTAssertEqual(parsed.style, "driving")
        XCTAssertEqual(parsed.seed, 0x8F3A_21C4)

        let rebuilt = StyleArranger.arrangement(style: try XCTUnwrap(StyleLibrary.named(parsed.style)),
                                                seed: parsed.seed, bars: 16)
        XCTAssertEqual(rebuilt, StyleArranger.arrangement(style: style, seed: identity.seed,
                                                          bars: 16))
    }

    func testANameThatIsNotGeneratedParsesAsNothing() {
        for name in ["jamBacking", "basicRock", "offbeat-0", "ladder-eighths", "", "@", "rock@"] {
            XCTAssertNil(BackingIdentity.parse(name),
                         "\(name) is not a generated backing and must not pretend to be — every "
                       + "take before M19 played fixed music")
        }
    }

    func testTheNameRoundTripsAtEveryExtreme() {
        for seed in [0, 1, UInt64.max, 0x0000_0000_0000_00FF] as [UInt64] {
            let identity = BackingIdentity(style: "pocket", seed: seed)
            XCTAssertEqual(BackingIdentity.parse(identity.name), identity, "\(seed)")
        }
    }

    // MARK: - The generator adds nothing

    /// **Variation is in what fires, never in when.** The generator selects among bars the style
    /// already defines; it may not invent a hit or move one, because the backing is the ruler the
    /// player is measured against.
    func testEveryHitCameFromTheStyleAtThatBarAndIntensity() {
        for seed in [7, 99, 12345] as [UInt64] {
            let piece = StyleArranger.arrangement(style: style, seed: seed, bars: 32)
            for bar in 0..<piece.totalBars {
                let played = piece.pattern(atBar: bar)
                let candidates = Style.intensityRange.map { style.pattern(atBar: bar, intensity: $0) }
                    + style.fills.map { $0.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat) }
                XCTAssertTrue(candidates.contains { $0.hits == played.hits },
                              "seed \(seed) bar \(bar): the generator produced a bar the style "
                            + "does not define")
            }
        }
    }

    func testEveryHitLandsOnAWholeStepOfTheCommonGrid() {
        for seed in (0..<16).map(UInt64.init) {
            let piece = StyleArranger.arrangement(style: style, seed: seed, bars: 16)
            XCTAssertEqual(piece.stepsPerBeat, Pattern.commonStepsPerBeat)
            for bar in 0..<piece.totalBars {
                for hit in piece.pattern(atBar: bar).hits {
                    XCTAssertTrue(hit.step >= 0 && hit.step < piece.stepsPerBar,
                                  "seed \(seed) bar \(bar): step \(hit.step) is off the bar")
                }
            }
        }
    }

    // MARK: - Shape

    func testIntensityStaysInsideItsRange() {
        for seed in (0..<32).map(UInt64.init) {
            for name in StyleArranger.arrangement(style: style, seed: seed, bars: 32)
                .sections.map(\.name) {
                let level = Int(name.split(separator: "i").last ?? "") ?? -1
                XCTAssertTrue(Style.intensityRange.contains(level), name)
            }
        }
    }

    /// A fill is a landmark, and a landmark on every bar is no landmark at all — the form drill
    /// spends its levels removing exactly these.
    func testFillsLandOnlyAtTheEndOfAPhrase() {
        let piece = StyleArranger.arrangement(style: style, seed: 3, bars: 32, phraseBars: 8)
        for (index, section) in piece.sections.enumerated() {
            let isPhraseEnd = index % 8 == 7
            XCTAssertEqual(section.fill != nil, isPhraseEnd, "bar \(index)")
        }
    }

    /// M16's span ladder grows the phrase to 16 and 32 bars. The generator should not have to
    /// change when it does.
    func testThePhraseLengthIsAParameter() {
        for phraseBars in [4, 8, 16, 32] {
            let piece = StyleArranger.arrangement(style: style, seed: 5, bars: 64,
                                                  phraseBars: phraseBars)
            let fills = piece.sections.enumerated().filter { $0.element.fill != nil }.map(\.offset)
            XCTAssertEqual(fills, Array(stride(from: phraseBars - 1, to: 64, by: phraseBars)),
                           "phrase of \(phraseBars)")
        }
    }

    func testAPieceIsAsLongAsAsked() {
        for bars in [1, 7, 32, 128] {
            XCTAssertEqual(StyleArranger.arrangement(style: style, seed: 1, bars: bars).totalBars,
                           bars)
        }
    }

    /// Two pieces from one seed share their opening, which is what lets a sitting sound like one
    /// evening: the planner keeps the seed within a sitting and rotates the style between them.
    func testOneSeedGivesTwoLengthsTheSameOpening() {
        let short = StyleArranger.arrangement(style: style, seed: 42, bars: 16)
        let long = StyleArranger.arrangement(style: style, seed: 42, bars: 64)
        for bar in 0..<16 {
            XCTAssertEqual(short.pattern(atBar: bar), long.pattern(atBar: bar), "bar \(bar)")
        }
    }
}
