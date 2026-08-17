import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// Cymbals as struck plates — §7.30 item 6, §7.70.
///
/// **Every assertion here is about a magnitude**, because §7.64 shipped a change that was wired end
/// to end, passed every test, and was inaudible. "The buffers differ" is not a claim about sound.
///
/// Brightness is measured with `energyAbove` rather than `centroid`: a bank of discrete modes can
/// fall between the centroid's probe frequencies and read far darker than it is, which is §7.67's
/// finding and which showed up again here (§7.70).
final class CymbalSynthTests: XCTestCase {

    private let fs = 44_100.0

    private func plate(modes: Int = 24, damping: Double = 0.6, tilt: Double = 0,
                       decay: Double = 0.5, lowest: Double = 400,
                       shimmer: Double = 0.3) -> CymbalSynth.Plate {
        CymbalSynth.Plate(lowestModeHz: lowest, modeCount: modes, stretch: 1.0,
                          inharmonicity: 0.22, lowestModeDecaySeconds: decay, damping: damping,
                          excitationTilt: tilt, strikeSeconds: 0.002, level: 0.6,
                          shimmerLevel: shimmer, shimmerDecayFraction: 0.2, shimmerFromHz: 4_000,
                          strikeNoise: 0.1)
    }

    private func bright(_ buffer: [Float]) -> Double {
        DrumSynth.energyAbove(2_000, of: buffer, sampleRate: fs)
    }

    // MARK: The modes are what makes it metal

    /// **Inharmonic is a property of the set, not of each mode.**
    ///
    /// The claim to test is not "no mode is near a whole-number multiple of the lowest" — a real
    /// plate can easily have one, and with modes nudged ±30% some will land there by chance. What
    /// matters is that they do not form a *series*: a harmonic series fuses into a pitch, which is
    /// what a musical note is, and a cymbal is a sound rather than a note.
    ///
    /// So the assertion is that only a minority sit near integer ratios. A harmonic series would put
    /// every one of them there.
    func testTheModesDoNotFormAHarmonicSeries() {
        let modes = CymbalSynth.modes(of: plate())
        let lowest = modes[0].frequency
        let nearHarmonic = modes.filter { mode in
            let ratio = mode.frequency / lowest
            return abs(ratio - ratio.rounded()) < 0.03
        }
        XCTAssertLessThan(Double(nearHarmonic.count) / Double(modes.count), 0.35,
                          "\(nearHarmonic.count) of \(modes.count) modes sit on harmonics — the "
                        + "ear will hear a pitch rather than a plate")
    }

    /// And with no irregularity at all they *do* line up into a pattern, which is what the knob is
    /// for: the difference between a cymbal and a bell is reachable rather than hard-coded.
    func testWithoutInharmonicityTheModesAreExactlyRegular() {
        let regular = CymbalSynth.Plate(
            lowestModeHz: 400, modeCount: 12, stretch: 1, inharmonicity: 0,
            lowestModeDecaySeconds: 0.5, damping: 0.6, excitationTilt: 0,
            strikeSeconds: 0.002, level: 0.6, shimmerLevel: 0, shimmerDecayFraction: 0.5,
            shimmerFromHz: 4_000, strikeNoise: 0.2)
        let ratios = CymbalSynth.modes(of: regular).map { $0.frequency / 400 }
        XCTAssertEqual(ratios, (1...12).map(Double.init))
    }

    /// The irregularity is deterministic and per index, so adding a mode does not move the ones
    /// already there — the same rule `Variation` follows for hits (§7.66).
    func testTheIrregularityIsFixedPerModeRatherThanAStream() {
        let few = CymbalSynth.modes(of: plate(modes: 8)).map(\.frequency)
        let many = CymbalSynth.modes(of: plate(modes: 30)).map(\.frequency)
        XCTAssertEqual(few, Array(many.prefix(8)))
    }

    /// **High modes die faster, which is what makes a cymbal darken as it rings.**
    ///
    /// Compared by *frequency*, not by index — which is not a nicety. Inharmonicity nudges each mode
    /// by up to ±30%, so mode 8 can easily sit below mode 7, and an index-ordered assertion fails on
    /// a plate that is behaving correctly. The physical claim is about frequency: whatever is higher
    /// dies sooner.
    func testHigherModesDecayFasterThanLowerOnes() {
        let byFrequency = CymbalSynth.modes(of: plate()).sorted { $0.frequency < $1.frequency }
        for (low, high) in zip(byFrequency, byFrequency.dropFirst()) {
            XCTAssertLessThanOrEqual(high.decaySeconds, low.decaySeconds,
                                     "\(high.frequency) Hz outlives \(low.frequency) Hz")
        }
    }

    /// And with no damping they all ring equally long — the old crash's behaviour, kept reachable so
    /// the difference is a parameter rather than a rewrite.
    func testZeroDampingRingsEveryModeForTheSameTime() {
        let modes = CymbalSynth.modes(of: plate(damping: 0))
        XCTAssertEqual(Set(modes.map { ($0.decaySeconds * 1e6).rounded() }).count, 1)
    }

    // MARK: What that does to the sound

    /// **The headline property.** Ignore the first fiftieth of a second and what remains has to be a
    /// different, darker sound — not the attack turned down.
    ///
    /// The shimmer's decay fraction is part of this rather than incidental: it stands in for the
    /// modes too high to model, and if it outlasts the body then the tail is *brighter* than the
    /// attack. That is what the first pass at the shimmer did, and this test is what said so (§7.71).
    func testTheTailIsFarDarkerThanTheAttack() {
        let rendered = CymbalSynth.render(plate(decay: 0.8), seconds: 1.0, sampleRate: fs)
        let head = Array(rendered.prefix(Int(0.05 * fs)))
        let tail = Array(rendered.dropFirst(Int(0.3 * fs)))

        XCTAssertGreaterThan(bright(head), 0.5, "the attack should be bright")
        XCTAssertLessThan(bright(tail), bright(head) * 0.5, "the tail kept the attack's colour")
    }

    /// Fact 3: a harder strike is brighter, not merely louder. Approximated at the strike rather than
    /// modelled as mode coupling — §7.70 says so plainly.
    func testAHarderStrikeIsBrighterAndNotJustLouder() {
        // Shimmer off: this is a claim about where the *strike* puts its energy across the
        // modes, and a broadband band sitting on top would mask it.
        let soft = CymbalSynth.render(plate(tilt: 0.6, shimmer: 0), seconds: 0.6, sampleRate: fs)
        let hard = CymbalSynth.render(plate(tilt: -0.6, shimmer: 0), seconds: 0.6, sampleRate: fs)

        XCTAssertGreaterThan(bright(hard), bright(soft) * 1.5)
        XCTAssertEqual(hard.map(abs).max() ?? 0, soft.map(abs).max() ?? 0, accuracy: 0.01,
                       "brightness must not smuggle in loudness — level is set separately")
    }

    /// Loudness is a property of the plate rather than of how many modes it has or how long they
    /// ring, or `modeCount` and `cymbalDecay` would double as volume controls.
    func testTheRenderedPeakIsWhatThePlateAsksFor() {
        for modes in [6, 24, 40] {
            for decay in [0.1, 0.5, 2.0] {
                let rendered = CymbalSynth.render(plate(modes: modes, decay: decay, shimmer: 0),
                                                  seconds: 0.5, sampleRate: fs)
                XCTAssertEqual(rendered.map(abs).max() ?? 0, 0.6, accuracy: 1e-5,
                               "\(modes) modes, \(decay)s")
            }
        }
    }

    /// Denser is not louder and not longer — it is only less separable, which is the whole point of
    /// the knob.
    func testMoreModesChangesTheSoundWithoutChangingItsLevel() {
        let sparse = CymbalSynth.render(plate(modes: 6, shimmer: 0), seconds: 0.5, sampleRate: fs)
        let dense = CymbalSynth.render(plate(modes: 36, shimmer: 0), seconds: 0.5, sampleRate: fs)
        XCTAssertNotEqual(sparse, dense)
        XCTAssertEqual(sparse.map(abs).max() ?? 0, dense.map(abs).max() ?? 0, accuracy: 1e-5)
    }
}
