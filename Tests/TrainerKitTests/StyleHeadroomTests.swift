import XCTest
@testable import GrooveCore
@testable import TrainerKit

/// A style that clips is heard as bad playing rather than as a bad gain.
///
/// `render` warns about it, but only if somebody reads the warning — motown clipped on 68 samples
/// when it was first written, because its clap doubles the backbeat and stacking voices is what
/// makes a mix hot rather than any one voice being loud.
///
/// **This lives here rather than beside the styles, and the first version did not.** Peak level is
/// a property of the synthesised mix, not of the pattern data: a hat's buffer peaks far below a
/// kick's and their peaks do not even align in time, so summing velocities called two styles hot
/// that measurably were not — `LESSONS.md` shape 16, a broken probe reporting a defect that is not
/// there. `GrooveCore` knows nothing about how a voice sounds and should not have to.
/// See PLAN.md §7.29 step 3.
final class StyleHeadroomTests: XCTestCase {

    /// Built once. `BackingKit` renders twenty-five bass buffers, and paying for that per
    /// assertion turned a fast test into a forty-second one.
    private static let fs = 44_100.0
    private static let kit = BackingKit(sampleRate: fs)

    private func peak(_ style: Style, intensity: Int, bpm: Double) -> Float {
        let fs = Self.fs
        let sequencer = Sequencer(bpm: bpm, sampleRate: fs)
        var hits: [ScheduledHit] = []
        // Four bars, not eight: the layers cycle in one or two, so a longer window renders more
        // audio without reaching any combination the first four miss. The suite runs unoptimised
        // and eight bars doubled its total runtime.
        let bars = 4
        for bar in 0..<bars {
            hits += sequencer.schedule(pattern: style.pattern(atBar: bar, intensity: intensity),
                                       bar: bar)
        }
        let frames = Int(Double(bars) * 4 * 60 / bpm * fs) + Int(fs / 2)
        let audio = GrooveOfflineRender.mix(hits: hits, kit: Self.kit, frames: frames)
        return audio.map { abs($0) }.max() ?? 0
    }

    func testNoStyleClipsAtAnyIntensity() {
        for style in StyleLibrary.all {
            for intensity in Style.intensityRange {
                let p = peak(style, intensity: intensity, bpm: 100)
                XCTAssertLessThanOrEqual(p, 1.0,
                    String(format: "%@ at intensity %d peaks at %.2f", style.name, intensity, p))
                XCTAssertTrue(p.isFinite, style.name)
            }
        }
    }

    /// Faster music packs the same hits closer together, so a style that just clears the rails at
    /// 100 BPM can exceed them at 160 where the tails overlap.
    func testNoStyleClipsAtTheTopOfTheTempoRange() {
        for style in StyleLibrary.all {
            let p = peak(style, intensity: Style.intensityRange.upperBound, bpm: 160)
            XCTAssertLessThanOrEqual(p, 1.0,
                String(format: "%@ at 160 BPM peaks at %.2f", style.name, p))
        }
    }

    /// Loud has to be audibly louder than quiet, or intensity is a setting that does nothing.
    func testIntensityIsAudible() {
        for style in StyleLibrary.all {
            let quiet = peak(style, intensity: Style.intensityRange.lowerBound, bpm: 100)
            let loud = peak(style, intensity: Style.intensityRange.upperBound, bpm: 100)
            XCTAssertGreaterThan(loud, quiet * 1.2,
                String(format: "%@: %.2f against %.2f", style.name, loud, quiet))
        }
    }
}
