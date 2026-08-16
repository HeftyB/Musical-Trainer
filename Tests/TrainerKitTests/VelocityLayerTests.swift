import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// A drum hit harder is a different sound, not the same one louder.
///
/// §7.30 item 1, and the largest single gap between this kit and a genre: *"a ghost snare at
/// velocity 34 and a backbeat at 100 are different instruments, and rendering both from one buffer
/// is why quiet hits sound like a fader move"*.
///
/// Two properties hold this together and both are easy to break later. **The nominal layer is the
/// sound this kit has always made** — so a backbeat is unchanged and the thirty takes over it stay
/// comparable to what follows. And **strength carries timbre, not loudness** — every layer is peak-
/// matched to the nominal one, so velocity keeps its existing job and no new clipping is possible.
final class VelocityLayerTests: XCTestCase {

    private let fs = 44_100.0

    // MARK: The nominal layer is the kit that already existed

    /// `tilt` has to return *exactly* 1 at nominal. The algebra says it does; binary floating point
    /// disagrees at `soft = 0.3`, and a hair on every sample moves the kit fingerprint.
    func testTiltIsExactlyOneAtNominalStrength() {
        for soft in [0.3, 0.45, 0.55, 0.6, 0.65, 0.7, 0.72, 0.75, 0.8] {
            for hard in [1.12, 1.15, 1.18, 1.2, 1.25, 1.3, 1.35, 1.5, 1.55] {
                XCTAssertEqual(DrumSynth.tilt(DrumSynth.nominalStrength, soft: soft, hard: hard), 1,
                               accuracy: 0, "soft \(soft), hard \(hard)")
            }
        }
    }

    func testTheNominalLayerIsWhatTheKitPlaysAtVelocityOneHundred() {
        let kit = BackingKit(sampleRate: fs)
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

    // MARK: The layers are genuinely different sounds

    /// The whole milestone in one assertion: a ghost and a backbeat must not be one buffer.
    func testAGhostNoteIsNotTheBackbeatTurnedDown() {
        let kit = BackingKit(sampleRate: fs)
        let ghost = kit.buffer(for: .snare, velocity: 40)
        let backbeat = kit.buffer(for: .snare, velocity: 100)

        XCTAssertNotEqual(ghost, backbeat)
        XCTAssertLessThan(DrumSynth.energy(of: ghost), DrumSynth.energy(of: backbeat) * 0.9,
                          "a ghost note carries less total energy at the same peak — it is shorter "
                        + "and has far less snare rattle behind it")
    }

    func testEveryLayeredVoiceRespondsToStrength() {
        let kit = BackingKit(sampleRate: fs)
        for voice in BackingVoice.allCases where !voice.isPitched && voice != .shaker {
            XCTAssertNotEqual(kit.buffer(for: voice, velocity: 40),
                              kit.buffer(for: voice, velocity: 100),
                              "\(voice) sounds identical soft and hard")
        }
    }

    /// The one voice that deliberately does not, and its own doc comment says why: *"a shaker that
    /// could be accented would become a second snare"*. Its job is to be the surface a groove sits
    /// on.
    func testTheShakerIgnoresStrengthOnPurpose() {
        let kit = BackingKit(sampleRate: fs)
        XCTAssertEqual(kit.buffer(for: .shaker, velocity: 40),
                       kit.buffer(for: .shaker, velocity: 127))
    }

    // MARK: Loudness stays velocity's job

    /// **The clipping guarantee.** `selftest` checks the mix stays off the rails; a hard layer that
    /// were both brighter and hotter than the nominal one could push a coincident kick and crash
    /// past 0 dBFS on a downbeat. Every layer is peak-matched instead, so the only thing that scales
    /// a hit is the gain it always had.
    func testEveryLayerHasTheSamePeakAsTheNominalOne() {
        let kit = BackingKit(sampleRate: fs)
        for voice in BackingVoice.allCases where !voice.isPitched {
            let peaks = (0..<BackingKit.layerStrengths.count).map { layer -> Float in
                kit.buffer(for: voice, velocity: BackingKit.layerCeilings[layer])
                    .map(abs).max() ?? 0
            }
            let nominal = peaks[BackingKit.nominalLayer]
            for (layer, peak) in peaks.enumerated() {
                XCTAssertEqual(peak, nominal, accuracy: nominal * 1e-4,
                               "\(voice) layer \(layer) peaks at \(peak) against \(nominal)")
            }
        }
    }
}
