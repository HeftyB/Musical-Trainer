import XCTest
@testable import GrooveCore

final class SequencerTests: XCTestCase {
    func testStepSampleMathIsExact() {
        // 120 BPM, 4 steps/beat, 44100 Hz → one step is 0.125 s = 5512.5 samples.
        let seq = Sequencer(bpm: 120, sampleRate: 44100)
        XCTAssertEqual(seq.sample(globalStep: 0, stepsPerBeat: 4), 0)
        XCTAssertEqual(seq.sample(globalStep: 1, stepsPerBeat: 4), 5513)  // 5512.5 rounds up
        XCTAssertEqual(seq.sample(globalStep: 2, stepsPerBeat: 4), 11025)
        XCTAssertEqual(seq.sample(globalStep: 8, stepsPerBeat: 4), 44100) // one beat = 0.5 s
    }

    /// The property that matters: index arithmetic must not drift from the ideal position
    /// however many bars elapse. Accumulation would; this must not.
    func testNoDriftOverManyBars() {
        let seq = Sequencer(bpm: 137, sampleRate: 48000)   // deliberately awkward tempo
        let stepsPerBeat = 4
        for step in stride(from: 0, through: 16 * 5000, by: 137) {
            let got = seq.sample(globalStep: step, stepsPerBeat: stepsPerBeat)
            let ideal = Double(step) * 60.0 / 137.0 / 4.0 * 48000.0
            XCTAssertLessThanOrEqual(abs(Double(got) - ideal), 0.5,
                                     "step \(step) drifted past half a sample")
        }
    }

    func testBarSchedulingPlacesHitsCorrectly() {
        let seq = Sequencer(bpm: 120, sampleRate: 44100)
        let pattern = Pattern.make([.kick: [0], .snare: [4]])
        let bar2 = seq.schedule(pattern: pattern, bar: 2)

        // Bar 2 begins at global step 32 → 32 * 5512.5 = 176400.
        // Snare is at global step 36 → round(36 * 5512.5) = 198450. Note this is NOT
        // barStart + 4*round(5512.5): rounding each step and summing would give 198452,
        // a 2-sample drift. Rounding the global step once is the whole point.
        let kick = bar2.first { $0.voice == .kick }
        let snare = bar2.first { $0.voice == .snare }
        XCTAssertEqual(kick?.sample, 176400)
        XCTAssertEqual(snare?.sample, 198450)
    }

    func testArrangementScheduleIsSortedBySample() {
        let seq = Sequencer(bpm: 100, sampleRate: 44100)
        let hits = seq.schedule(arrangement: GrooveLibrary.demo, bars: 0..<16)
        XCTAssertFalse(hits.isEmpty)
        for i in 1..<hits.count {
            XCTAssertLessThanOrEqual(hits[i - 1].sample, hits[i].sample)
        }
    }
}
