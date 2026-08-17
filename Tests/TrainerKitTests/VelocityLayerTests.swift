import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// A drum hit harder is a different sound, not the same one louder.
///
/// §7.30 item 1, and the largest single gap between this kit and a genre: *"a ghost snare at
/// velocity 34 and a backbeat at 100 are different instruments, and rendering both from one buffer
/// is why quiet hits sound like a fader move"*.
///
/// **The first pass at this shipped inaudible and every test passed** (§7.64). They asserted the
/// buffers were *not equal*, which is true of a difference nobody can hear — measured afterwards,
/// the closed hat's spectral centroid had moved 2%, in the wrong direction. So the assertions here
/// are about **magnitude**: a test that a value changed cannot protect a value changing *enough*.
final class VelocityLayerTests: XCTestCase {

    private let fs = 44_100.0

    /// Shared across the whole target — see `TestKit`. Building one is the most expensive thing a
    /// test in this project can do.
    private static let kit = TestKit.at(44_100)

    /// Every voice that is supposed to respond to how hard it is hit.
    private static var accented: [BackingVoice] {
        BackingVoice.allCases.filter { !$0.isPitched && !DrumSynth.unaccented.contains($0) }
    }

    /// Voices whose energy sits below the room's own return, so its reflections dominate their
    /// spectral centroid. Measured rather than listed — see the test that pins the membership.
    private static let lowVoices: [BackingVoice] = accented.filter {
        DrumSynth.centroid(of: kit.buffer(for: $0, velocity: 100), sampleRate: 44_100) < 400
    }

    // MARK: The nominal layer is the kit that already existed

    /// `tilt` has to return *exactly* 1 at nominal. The algebra says it does; binary floating point
    /// disagrees at `soft = 0.3`, and a hair on every sample moves the kit fingerprint.
    func testTiltIsExactlyOneAtNominalStrength() {
        for soft in [0.08, 0.28, 0.3, 0.35, 0.4, 0.45, 0.55, 0.65, 0.7, 0.75, 0.8] {
            for hard in [1.12, 1.15, 1.2, 1.25, 1.3, 1.35, 1.5, 1.8] {
                XCTAssertEqual(DrumSynth.tilt(DrumSynth.nominalStrength, soft: soft, hard: hard), 1,
                               accuracy: 0, "soft \(soft), hard \(hard)")
            }
        }
    }

    func testTheNominalLayerIsWhatTheKitPlaysAtVelocityOneHundred() {
        let kit = Self.kit
        for voice in BackingVoice.allCases where !voice.isPitched {
            XCTAssertEqual(kit.buffer(for: voice, velocity: 100),
                           DrumSynth.render(voice, sampleRate: fs,
                                            strength: DrumSynth.nominalStrength),
                           "\(voice) at velocity 100 is not the sound this kit has always made")
        }
    }

    // MARK: Which layer a velocity plays on

    func testTheLayerBoundariesAreWhereTheStylesActuallyWrite() {
        XCTAssertEqual(BackingKit.layer(forVelocity: 40), 0, "a ghost note")
        XCTAssertEqual(BackingKit.layer(forVelocity: 55), 0)
        XCTAssertEqual(BackingKit.layer(forVelocity: 56), 1)
        XCTAssertEqual(BackingKit.layer(forVelocity: 76), 1)
        XCTAssertEqual(BackingKit.layer(forVelocity: 100), BackingKit.nominalLayer,
                       "the velocity the patterns cluster at is the nominal layer")
        XCTAssertEqual(BackingKit.layer(forVelocity: 108), 3)
    }

    /// A velocity outside 1–127 is a programming error, not a reason to trap in an audio path.
    func testAnOutOfRangeVelocityClampsRatherThanTrapping() {
        XCTAssertEqual(BackingKit.layer(forVelocity: 0), 0)
        XCTAssertEqual(BackingKit.layer(forVelocity: 999), BackingKit.layerStrengths.count - 1)
    }

    // MARK: The layers differ by enough to hear, which is not the same as differing

    /// The thresholds are floors well below what the kit measures — energy runs 0.02–0.14 of the
    /// hard layer, centroid 0.14–0.78 — so ordinary tuning does not trip them, and a collapse back
    /// toward "one buffer at two gains" does.
    func testASoftLayerCarriesFarLessEnergyThanAHardOne() {
        let kit = Self.kit
        for voice in Self.accented {
            let soft = kit.buffer(for: voice, velocity: BackingKit.layerCeilings[0])
            let hard = kit.buffer(for: voice, velocity: 127)
            XCTAssertLessThan(DrumSynth.energy(of: soft), DrumSynth.energy(of: hard) * 0.30,
                              "\(voice): a ghost stroke carries nearly as much as a hard one")
        }
    }

    /// Brightness is most of what an ear calls a soft hit, and it is exactly what a shift in the
    /// balance between components that are already present cannot produce.
    ///
    /// **Only for voices that sit above the room's own return.** See below.
    func testASoftLayerIsSubstantiallyDarkerThanAHardOne() {
        let kit = Self.kit
        for voice in Self.accented where !Self.lowVoices.contains(voice) {
            let soft = DrumSynth.centroid(of: kit.buffer(for: voice,
                                                         velocity: BackingKit.layerCeilings[0]),
                                          sampleRate: fs)
            let hard = DrumSynth.centroid(of: kit.buffer(for: voice, velocity: 127), sampleRate: fs)
            XCTAssertLessThan(soft, hard * 0.70, "\(voice) barely changes colour with force")
        }
    }

    /// **The low voices carry their dynamic in energy rather than in colour, and the room is why.**
    ///
    /// A room returns something brighter than a kick, so once the kit is in one the reflections
    /// dominate a low voice's spectral centroid and the soft-to-hard ratio compresses — the kick
    /// went from 0.78 dry to 0.85 in the room (§7.65). That is an acoustic fact rather than a
    /// tuning failure: it is why a real kick is mostly recorded close-miked.
    ///
    /// **Defined by where the voice sits, not by a list of names**, so the exemption cannot quietly
    /// grow to cover a voice that simply stopped working. The membership assertion is the guard on
    /// the guard.
    func testTheLowVoicesCarryTheirDynamicInEnergyRatherThanColour() {
        let kit = Self.kit
        XCTAssertEqual(Set(Self.lowVoices), [.kick, .tom],
                       "the set of voices exempt from the colour test changed")

        for voice in Self.lowVoices {
            let soft = kit.buffer(for: voice, velocity: BackingKit.layerCeilings[0])
            let hard = kit.buffer(for: voice, velocity: 127)
            XCTAssertLessThan(DrumSynth.energy(of: soft), DrumSynth.energy(of: hard) * 0.30,
                              "\(voice) has to carry a dynamic even without a colour change")
        }
    }

    /// **The tom is the weakest of the two and for a second reason**: it is a pure pitch-swept sine
    /// with no noise, click or wash, so a softer strike has nothing to fail to excite. Every other
    /// voice in the kit has a component a soft hit leaves alone. The fix is a stick transient, which
    /// is synthesis work M26 has not done (§7.64).
    func testTheTomHasNoTransientToLose() {
        let kit = Self.kit
        let soft = DrumSynth.centroid(of: kit.buffer(for: .tom, velocity: 40), sampleRate: fs)
        let hard = DrumSynth.centroid(of: kit.buffer(for: .tom, velocity: 127), sampleRate: fs)
        XCTAssertGreaterThan(soft, hard * 0.85,
                             "the tom moved — give it a stick transient and drop this exception")
    }

    func testEveryLayeredVoiceRespondsToStrength() {
        let kit = Self.kit
        for voice in Self.accented {
            XCTAssertNotEqual(kit.buffer(for: voice, velocity: 40),
                              kit.buffer(for: voice, velocity: 100),
                              "\(voice) sounds identical soft and hard")
        }
    }

    /// The voices that deliberately do not respond — currently the shaker, whose own comment carries
    /// the argument: *"a shaker that could be accented would become a second snare"*.
    ///
    /// **`raw` honoured that and `render` darkened it anyway**, so the one voice documented as
    /// unaccentable was the one whose timbre moved most per unit of velocity until §7.64. One list
    /// now, read by both halves.
    func testAnUnaccentedVoiceIsByteIdenticalAtEveryVelocity() {
        let kit = Self.kit
        for voice in DrumSynth.unaccented {
            for velocity in [1, 40, 55, 80, 127] {
                XCTAssertEqual(kit.buffer(for: voice, velocity: velocity),
                               kit.buffer(for: voice, velocity: 100), "\(voice) at \(velocity)")
            }
        }
    }

    // MARK: Loudness stays velocity's job

    /// **The clipping guarantee.** `selftest` checks the mix stays off the rails, and a hard layer
    /// both brighter *and* hotter than the nominal one could push a coincident kick and crash past
    /// 0 dBFS on a downbeat. No layer may exceed the nominal peak.
    ///
    /// **Capped, not matched.** Matching lifted the darkened soft layers back up and handed a ghost
    /// snare more total energy than the backbeat had (§7.64) — a quiet stroke that carries more
    /// energy than a loud one is not a quiet stroke.
    func testNoLayerIsLouderThanTheNominalOne() {
        let kit = Self.kit
        for voice in BackingVoice.allCases where !voice.isPitched {
            let peaks = BackingKit.layerCeilings.map { velocity -> Float in
                kit.buffer(for: voice, velocity: velocity).map(abs).max() ?? 0
            }
            let nominal = peaks[BackingKit.nominalLayer]
            for (layer, peak) in peaks.enumerated() {
                XCTAssertLessThanOrEqual(peak, nominal * 1.0001,
                                         "\(voice) layer \(layer) peaks at \(peak) "
                                       + "against the nominal \(nominal)")
            }
        }
    }

    /// And the soft layers really are quieter, rather than merely not louder — which is what makes
    /// the timbre and the velocity gain pull in the same direction.
    func testASoftLayerIsQuieterThanTheNominalOne() {
        let kit = Self.kit
        for voice in Self.accented {
            let soft = kit.buffer(for: voice, velocity: 40).map(abs).max() ?? 0
            let nominal = kit.buffer(for: voice, velocity: 100).map(abs).max() ?? 0
            XCTAssertLessThan(soft, nominal, "\(voice)")
        }
    }
}
