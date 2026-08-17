import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// What a `KitSpec`'s numbers actually do to the drums.
///
/// **A parameter that is plumbed through and moves nothing is the failure this guards against**, and
/// it is the same shape §7.64 shipped: velocity layers were wired end to end, every test passed, and
/// the effect was inaudible because nothing asserted a *magnitude*. So each knob here is checked
/// against the quantity it claims to move, by the amount it claims to move it.
///
/// Single voices rather than whole kits: `DrumSynth.render` for one voice is a fraction of a second
/// where a kit is twenty-four (§7.66), and a knob's effect is visible on the voice it names.
final class KitSpecSynthesisTests: XCTestCase {

    private let fs = 44_100.0

    private func voice(_ v: BackingVoice, _ spec: KitSpec) -> [Float] {
        DrumSynth.render(v, sampleRate: fs, spec: spec)
    }

    private func duration(_ buffer: [Float]) -> Double {
        DrumSynth.durationSeconds(of: buffer, sampleRate: fs)
    }

    private func centroid(_ buffer: [Float]) -> Double {
        DrumSynth.centroid(of: buffer, sampleRate: fs)
    }

    // MARK: The standard kit is the kit that already shipped

    /// **Bit-identical, not merely close.** The fixed backing that 104 takes were played over has to
    /// keep its exact sound, or `KitGroup` sees a new kit and splits the corpus (§7.62). No branch
    /// protects this — it holds because `x * 1.0 == x` — so it is worth asserting on real output.
    func testTheStandardSpecRendersTheKitThatAlreadyExisted() {
        for v in BackingVoice.allCases where !v.isPitched {
            XCTAssertEqual(voice(v, .standard), DrumSynth.render(v, sampleRate: fs), "\(v)")
        }
    }

    func testTheStandardSpecKeepsTheFingerprintThisProjectHasNamed() {
        XCTAssertEqual(BackingKit.fingerprint(of: .standard), BackingKit.fingerprint)
    }

    func testADifferentKitHasADifferentFingerprint() {
        XCTAssertNotEqual(BackingKit.fingerprint(of: KitSpec(name: "damped", snareDecay: 0.6)),
                          BackingKit.fingerprint(of: .standard))
    }

    // MARK: Each knob moves the thing it names, by enough to hear

    /// **Measured at the partials rather than by centroid**, because the centroid is unreliable for
    /// tonal content: the snare's apparent centroid *falls* threefold when it is tuned up, since the
    /// partials move nearer one of the probe frequencies (§7.67). The snare's tone sits at 180 and
    /// 330 Hz, so a 1.35 tuning puts it at 243 and 446 — and asking there is exact.
    func testSnareTuningRaisesTheSnaresPitchAndNothingElses() {
        let high = KitSpec(name: "high", snareTuning: 1.35)
        let tuned = voice(.snare, high), standard = voice(.snare, .standard)

        XCTAssertGreaterThan(DrumSynth.power(of: tuned, atHz: 243, sampleRate: fs),
                             DrumSynth.power(of: standard, atHz: 243, sampleRate: fs) * 4)
        XCTAssertLessThan(DrumSynth.power(of: tuned, atHz: 180, sampleRate: fs),
                          DrumSynth.power(of: standard, atHz: 180, sampleRate: fs) * 0.25)
        XCTAssertEqual(voice(.kick, high), voice(.kick, .standard), "it reached the kick")
    }

    func testSnareDecayDampensTheSnare() {
        let damped = KitSpec(name: "damped", snareDecay: 0.55)
        XCTAssertLessThan(duration(voice(.snare, damped)),
                          duration(voice(.snare, .standard)) * 0.85)
    }

    /// Rattle is the wires against the head — more of it is more noise, which reads as brighter.
    func testSnareRattleMovesTheBalanceTowardTheWires() {
        let loose = KitSpec(name: "loose", snareRattle: 1.6)
        let tight = KitSpec(name: "tight", snareRattle: 0.4)
        XCTAssertGreaterThan(centroid(voice(.snare, loose)), centroid(voice(.snare, tight)) * 1.1)
    }

    /// The kick's body settles at 45 Hz and its sweep starts at 185. Tuning multiplies both, so the
    /// question is asked at the pitch it settles to rather than at a centroid the beater dominates.
    func testKickTuningRaisesTheKick() {
        let clicky = KitSpec(name: "clicky", kickTuning: 1.4)
        let tuned = voice(.kick, clicky), standard = voice(.kick, .standard)

        XCTAssertGreaterThan(DrumSynth.power(of: tuned, atHz: 63, sampleRate: fs),
                             DrumSynth.power(of: standard, atHz: 63, sampleRate: fs) * 2)
        XCTAssertLessThan(DrumSynth.power(of: tuned, atHz: 45, sampleRate: fs),
                          DrumSynth.power(of: standard, atHz: 45, sampleRate: fs))
    }

    func testKickDecayShortensTheKick() {
        let dead = KitSpec(name: "dead", kickDecay: 0.5)
        XCTAssertLessThan(duration(voice(.kick, dead)), duration(voice(.kick, .standard)) * 0.85)
    }

    /// One knob for both cymbals, because a kit with a tight hat and a washy ride is two decisions
    /// nobody has asked for yet.
    func testCymbalDecayShortensTheHatAndTheRideTogether() {
        let tight = KitSpec(name: "tight", cymbalDecay: 0.5)
        XCTAssertLessThan(duration(voice(.closedHat, tight)),
                          duration(voice(.closedHat, .standard)) * 0.85)
        XCTAssertLessThan(duration(voice(.ride, tight)),
                          duration(voice(.ride, .standard)) * 0.9)
    }

    /// **A genre parameter as much as any drum's tuning**, and the one that most separates a sixties
    /// record from a modern one. Zero has to mean genuinely dry, since that is what a close-miked
    /// style would ask for.
    func testRoomAmountChangesHowMuchTailAVoiceCarries() {
        let dry = KitSpec(name: "dry", roomAmount: 0)
        let wet = KitSpec(name: "wet", roomAmount: 2)

        XCTAssertLessThan(DrumSynth.energy(of: voice(.snare, dry)),
                          DrumSynth.energy(of: voice(.snare, .standard)))
        XCTAssertGreaterThan(DrumSynth.energy(of: voice(.snare, wet)),
                             DrumSynth.energy(of: voice(.snare, .standard)))
    }

    /// A kit nobody tuned must not accidentally be wetter or drier than the house room.
    func testTheStandardRoomAmountIsExactlyWhatTheRoomAlreadyDid() {
        XCTAssertEqual(Room.applied(to: [1, 0, 0, 0], sampleRate: fs, amount: 1),
                       Room.applied(to: [1, 0, 0, 0], sampleRate: fs))
    }

    // MARK: The kit reaches the take that heard it

    /// **One resolution, or a take is played on one kit and stored as having heard another.** The
    /// arrangement and the kit come out of the same `backing` property for exactly this reason —
    /// `Feel`/`Swing`'s failure mode, which §7.24 step 7 already paid for once.
    func testAGeneratedBackingCarriesItsStylesKitAndAFixedOneDoesNot() throws {
        let style = try XCTUnwrap(StyleLibrary.auditioned.first)
        let generated = TrainerEngine.JamConfig(
            bpm: 100, bars: 8, tag: nil,
            generatedBacking: BackingIdentity(style: style.name, seed: 1))
        XCTAssertEqual(generated.backing.kit, style.kit)

        let fixed = TrainerEngine.JamConfig(bpm: 100, bars: 8, tag: nil)
        XCTAssertEqual(fixed.backing.kit, .standard)
        XCTAssertEqual(fixed.backing.name, "jamBacking")
    }
}
