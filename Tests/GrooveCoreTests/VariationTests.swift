import XCTest
@testable import GrooveCore

/// No two hits of one voice at exactly the same level — §7.30 item 4, §7.66.
///
/// **The failure this guards against is subtler than "no variation".** A round-robin whose length
/// divides the bar puts the same value on every downbeat, which is a pattern *inside* the variation,
/// exactly aligned to the pattern it exists to break up. That is worse than no variation at all, and
/// it is what a reader reaching for `occurrence % 4` would produce.
final class VariationTests: XCTestCase {

    private func scales(_ voice: BackingVoice, _ count: Int) -> [Double] {
        (0..<count).map { Variation.gainScale(voice: voice, occurrence: $0) }
    }

    // MARK: Reproducibility, which R1.2.2 does not negotiate

    func testTheSameHitAlwaysGetsTheSameScale() {
        for occurrence in [0, 1, 7, 64, 4_095] {
            XCTAssertEqual(Variation.gainScale(voice: .closedHat, occurrence: occurrence),
                           Variation.gainScale(voice: .closedHat, occurrence: occurrence))
        }
    }

    /// Pinned, because the property being claimed is that a piece sounds the same on every run and
    /// every machine. A stateful generator could not promise that once hits are sorted or filtered.
    func testTheScaleIsPinnedRatherThanMerelyRepeatable() {
        XCTAssertEqual(Variation.gainScale(voice: .closedHat, occurrence: 0), 0.8337, accuracy: 1e-4)
        XCTAssertEqual(Variation.gainScale(voice: .kick, occurrence: 0), 0.8479, accuracy: 1e-4)
    }

    // MARK: Attenuation only

    /// Nothing may come out louder than the mix that already shipped, so the clipping guarantee
    /// needs no re-checking — the same reasoning as capping a velocity layer rather than matching it.
    func testEveryScaleAttenuatesAndNoneBoosts() {
        for voice in BackingVoice.allCases {
            for scale in scales(voice, 500) {
                XCTAssertLessThanOrEqual(scale, 1, "\(voice) boosts")
                XCTAssertGreaterThan(scale, 1 - Variation.depth - 1e-9, "\(voice) over-attenuates")
            }
        }
    }

    /// A depth nobody can hear is decoration. Averaged over a piece it should sit near the middle of
    /// the range, so the variation is a spread rather than a handful of outliers.
    func testTheSpreadIsUsedRatherThanClusteredAtOneEnd() {
        let values = scales(.closedHat, 2_000)
        let mean = values.reduce(0, +) / Double(values.count)
        XCTAssertEqual(mean, 1 - Variation.depth / 2, accuracy: 0.01)
    }

    // MARK: The trap — nothing may line up with the bar

    /// **The whole point.** Patterns are 16 steps to the bar, so a cycle of 2, 4, 8 or 16 would put
    /// one value on every downbeat. Sampling the stream at each of those strides has to keep varying.
    func testTheStreamDoesNotRepeatAtAnyBarAlignedStride() {
        for stride in [2, 3, 4, 6, 8, 12, 16, 24, 32] {
            let sampled = Swift.stride(from: 0, to: stride * 40, by: stride).map {
                Variation.gainScale(voice: .closedHat, occurrence: $0)
            }
            XCTAssertGreaterThan(Set(sampled.map { Int($0 * 1_000_000) }).count, 30,
                                 "the stream repeats when sampled every \(stride) hits")
        }
    }

    /// Two voices landing on the same step must not move together, or the pair reads as one accent
    /// rather than as two instruments.
    func testTwoVoicesOnTheSameStepVaryIndependently() {
        for occurrence in 0..<50 {
            XCTAssertNotEqual(Variation.gainScale(voice: .kick, occurrence: occurrence),
                              Variation.gainScale(voice: .closedHat, occurrence: occurrence))
        }
    }

    /// A voice added later gets its own stream without anyone remembering to assign it one — the
    /// salt comes from the name. `LESSONS.md` shape 14, in the direction of not needing the flag.
    func testEveryVoiceHasItsOwnStream() {
        let firsts = BackingVoice.allCases.map { Variation.gainScale(voice: $0, occurrence: 0) }
        XCTAssertEqual(Set(firsts.map { Int($0 * 1_000_000) }).count, firsts.count)
    }

    // MARK: Counting is per voice

    /// **Adding an instrument must not change the ones already there.** Occurrence counts within a
    /// voice, so a piece does not re-roll because a cowbell arrived.
    func testAddingAVoiceLeavesTheOthersUntouched() {
        let hats = (0..<8).map {
            ScheduledHit(voice: .closedHat, sample: Int64($0 * 100), velocity: 90)
        }
        let withCowbell = (hats + (0..<3).map {
            ScheduledHit(voice: .cowbell, sample: Int64($0 * 250), velocity: 80)
        }).sorted { $0.sample < $1.sample }

        let before = Variation.gainScales(for: hats)
        let after = Variation.gainScales(for: withCowbell)
        let hatScalesAfter = zip(withCowbell, after).filter { $0.0.voice == .closedHat }.map(\.1)

        XCTAssertEqual(before, hatScalesAfter)
    }

    func testTheScalesLineUpOneForOneWithTheHits() {
        let hits = (0..<20).map {
            ScheduledHit(voice: $0.isMultiple(of: 2) ? .kick : .snare,
                         sample: Int64($0 * 100), velocity: 100)
        }
        XCTAssertEqual(Variation.gainScales(for: hits).count, hits.count)
    }

    /// The same piece scheduled twice is the same piece. Trivially true of a pure function and worth
    /// pinning anyway, because the obvious implementation — a generator advanced per hit — is not.
    func testSchedulingThePieceTwiceGivesTheSameLevels() {
        let hits = (0..<64).map {
            ScheduledHit(voice: .closedHat, sample: Int64($0 * 50), velocity: 70)
        }
        XCTAssertEqual(Variation.gainScales(for: hits), Variation.gainScales(for: hits))
    }
}
