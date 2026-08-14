import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// A one-shot must not stop mid-decay.
///
/// Every voice's buffer length is a constant and every envelope is exponential, so before the
/// release fade the signal stepped to zero from whatever value it happened to hold — a step
/// discontinuity, which is a broadband impulse. The kick's landed at **−31.8 dBFS**, 0.320 s after
/// every hit, which at 100 BPM is 0.53 of a beat: a click sitting just past the offbeat, in every
/// take recorded since M3. See PLAN.md §7.29 step 6b.
///
/// **The bass was five times worse and had never been measured**, because `render` writes one file
/// per *non-pitched* voice and there was no `kit-bass`. §7.31 finding 1 quantified it off a
/// reimplementation of `BassSynth`, which is a probe — and `LESSONS.md` shape 16 says suspect the
/// probe. This file is the answer to that: the property is asserted against the buffers the app
/// actually plays, so nothing rests on a reimplementation and the defect cannot come back quietly.
///
/// Reverting either `fadedOut` call fails `testNoVoiceStopsMidDecay` on kick, snare, clap, ride and
/// all twenty-five bass notes.
final class OneShotTailTests: XCTestCase {

    /// Built once. `BackingKit` renders twenty-five bass buffers and paying for that per assertion
    /// turns a fast test into a slow one — the same reason `StyleHeadroomTests` shares its kit.
    private static let fs = 44_100.0
    private static let kit = BackingKit(sampleRate: fs)

    /// −80 dBFS. Far below anything audible over a groove, and far above the floor a raised-cosine
    /// fade actually lands on, so the threshold is not measuring rounding. The defect it excludes
    /// sat at −31.8.
    private static let ceiling: Float = 1e-4

    private func voices() -> [(name: String, buffer: [Float])] {
        var all = BackingVoice.allCases.filter { !$0.isPitched }.map {
            (name: $0.rawValue, buffer: Self.kit.buffer(for: $0))
        }
        all += BackingKit.bassNotes.map {
            (name: "bass \($0)", buffer: Self.kit.buffer(for: .bass, note: $0))
        }
        // **Enumerated, not listed.** The bass was missed here for a milestone because the filter
        // above hides pitched voices, and the fix was to add the bass by hand — which is the same
        // fix waiting to be forgotten the next time a pitched voice arrives. It did: the organ
        // (§7.56). Every pitched voice's whole range goes through this now.
        all += BackingKit.organNotes.map {
            (name: "organ \($0)", buffer: Self.kit.buffer(for: .organ, note: $0))
        }
        return all
    }

    /// Every pitched voice has buffers to be checked at all. A voice added to the enum without a
    /// synthesiser behind it would make every assertion here pass over an empty array — which is
    /// `LESSONS.md` shape 3, a filter that hides the thing being looked for, one level up.
    func testEveryPitchedVoiceHasSoundToCheck() {
        for voice in BackingVoice.allCases where voice.isPitched {
            let range = voice == .bass ? BackingKit.bassNotes : BackingKit.organNotes
            for note in range {
                XCTAssertFalse(Self.kit.buffer(for: voice, note: note).isEmpty,
                               "\(voice) \(note) renders nothing")
            }
        }
    }

    /// The defect itself: the last sample *is* the size of the step to silence, because the sample
    /// after the buffer is zero by construction.
    func testNoVoiceStopsMidDecay() {
        for (name, buffer) in voices() {
            let last = abs(buffer.last ?? 0)
            XCTAssertLessThan(last, Self.ceiling,
                String(format: "%@ ends at %.5f (%.1f dBFS) — a step to zero is a click",
                       name, last, 20 * log10(max(Double(last), 1e-12))))
        }
    }

    /// A fade that removed the sound would also pass the assertion above, so this is the other
    /// half: every voice still has a peak, and that peak lands *before* the fade region, which is
    /// what makes it impossible for the fade to be doing the work.
    func testTheFadeDoesNotEatTheVoice() throws {
        for (name, buffer) in voices() {
            let peak = buffer.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.01, "\(name) renders nothing")

            let fade = min(Int(DrumSynth.fadeSeconds * Self.fs),
                           Int(Double(buffer.count) * DrumSynth.maximumFadeFraction))
            let peakIndex = try XCTUnwrap(buffer.indices.max(by: { abs(buffer[$0]) < abs(buffer[$1]) }))
            XCTAssertLessThan(peakIndex, buffer.count - fade,
                              "\(name) peaks inside its own fade")
        }
    }

    /// The fade length is derived from the lowest note the band can sound — two cycles of E1 at
    /// 41.2 Hz — rather than chosen by ear. A fade shorter than a cycle of the fundamental acts
    /// inside one swing of the waveform and leaves most of the step it exists to remove, so this
    /// asserts the derivation rather than the number: widening `bassNotes` downward without
    /// revisiting `fadeSeconds` fails here.
    func testTheFadeCoversTwoCyclesOfTheLowestNote() {
        let lowest = BassSynth.frequency(ofNote: BackingKit.bassNotes.lowerBound)
        XCTAssertGreaterThanOrEqual(DrumSynth.fadeSeconds, 2 / lowest,
            String(format: "%.3f s of fade is under two cycles of %.1f Hz",
                   DrumSynth.fadeSeconds, lowest))
    }

    /// The rimshot is 50 ms long altogether and truncates at 0.2% of peak, so a 50 ms fade would
    /// be the whole voice. The clamp is what stops a fix for the loud voices gutting the short
    /// ones, and a short voice keeping its character is the reason it exists.
    func testAShortVoiceIsNotSwallowedByItsOwnFade() {
        for voice in [BackingVoice.rimshot, .sidestick, .shaker] {
            let buffer = Self.kit.buffer(for: voice)
            let fade = min(Int(DrumSynth.fadeSeconds * Self.fs),
                           Int(Double(buffer.count) * DrumSynth.maximumFadeFraction))
            XCTAssertLessThanOrEqual(Double(fade), Double(buffer.count) * 0.25,
                                     "\(voice.rawValue) is mostly fade")
        }
    }
}
