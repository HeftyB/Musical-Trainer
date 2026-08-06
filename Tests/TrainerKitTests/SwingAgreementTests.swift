import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// **The band and the grid must agree about where a swung note goes.**
///
/// A feel is described twice, by two types that cannot be shared: `Feel` tells the analysis
/// where to expect a note, `Swing` tells the sequencer when to play one, and `GrooveCore`
/// depends on nothing — not even `TimingCore` (R1.1.3) — so neither can be defined in terms of
/// the other. That is a real hazard, not a tidiness problem. A groove swinging at 2:1 while the
/// grid scored at 1.5:1 would teach one feel and measure another, produce a large and stable
/// asynchrony, and look exactly like a player who drags.
///
/// Since they cannot share code, they are pinned by these. This file is the only thing standing
/// between the two derivations and a silent disagreement.
final class SwingAgreementTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// Where the sequencer actually puts a step, in seconds from the start of the take.
    private func scheduled(step: Int, stepsPerBeat: Int, bpm: Double, swing: Swing) -> Double {
        let sequencer = Sequencer(bpm: bpm, sampleRate: sampleRate, swing: swing)
        return Double(sequencer.sample(globalStep: step, stepsPerBeat: stepsPerBeat)) / sampleRate
    }

    // MARK: The two derivations, to the sample

    /// Every subdivision of every beat, at every ratio and rung, on both step resolutions the
    /// ladder uses. If the warp and `Feel.phases` ever part company, this is where it shows.
    func testASwungHatLandsExactlyWhereTheGridExpectsIt() {
        for ratio in [1.0, 1.25, 1.5, 2.0, 3.0] {
            guard let feel = Feel(swingRatio: ratio) else { return XCTFail("\(ratio)") }
            for rung in [IntervalRung.eighths, .sixteenths] {
                let notesPerBeat = rung.subdivisions
                let swing = Swing(ratio: ratio, notesPerBeat: notesPerBeat)
                let grid = Grid(startTime: 0, bpm: 100, subdivisions: notesPerBeat, feel: feel)

                for beat in 0..<8 {
                    for phase in 0..<notesPerBeat {
                        let index = beat * notesPerBeat + phase
                        let played = scheduled(step: index, stepsPerBeat: notesPerBeat,
                                               bpm: 100, swing: swing)
                        XCTAssertEqual(played, grid.time(ofIndex: index), accuracy: 1.0 / sampleRate,
                                       "ratio \(ratio), \(rung.label), index \(index)")
                    }
                }
            }
        }
    }

    /// The ladder's straight rungs are programmed on a sixteenth step grid, so a swung eighths
    /// backing has steps *between* the notes being swung. Those have to move with their pair
    /// rather than staying put — otherwise a sixteenth ornament inside a swung eighth lands in
    /// the wrong half of it.
    func testStepsFinerThanTheSwungDivisionMoveWithTheirPair() {
        let swing = Swing(ratio: 2, notesPerBeat: 2)
        let beat = 0.6

        // A sixteenth-step grid: steps 0..3 span one beat, and the swung eighth is step 2.
        XCTAssertEqual(scheduled(step: 0, stepsPerBeat: 4, bpm: 100, swing: swing),
                       0, accuracy: 1e-4)
        XCTAssertEqual(scheduled(step: 2, stepsPerBeat: 4, bpm: 100, swing: swing),
                       beat * 2 / 3, accuracy: 1e-4, "the swung eighth")
        XCTAssertEqual(scheduled(step: 1, stepsPerBeat: 4, bpm: 100, swing: swing),
                       beat / 3, accuracy: 1e-4, "halfway through the long note, not at 0.25")
        XCTAssertEqual(scheduled(step: 4, stepsPerBeat: 4, bpm: 100, swing: swing),
                       beat, accuracy: 1e-4, "the next beat has not moved")
    }

    // MARK: Nothing moves that should not

    /// A straight feel must schedule byte-for-byte what it always did, or every backing every
    /// recorded take played over has quietly changed.
    func testAStraightFeelSchedulesExactlyWhatItAlwaysDid() {
        for bpm in [80.0, 100, 132] {
            for stepsPerBeat in [3, 4] {
                let plain = Sequencer(bpm: bpm, sampleRate: sampleRate)
                let explicit = Sequencer(bpm: bpm, sampleRate: sampleRate, swing: .none)
                let unity = Sequencer(bpm: bpm, sampleRate: sampleRate,
                                      swing: Swing(ratio: 1, notesPerBeat: 2))
                for step in 0..<64 {
                    let expected = plain.sample(globalStep: step, stepsPerBeat: stepsPerBeat)
                    XCTAssertEqual(explicit.sample(globalStep: step, stepsPerBeat: stepsPerBeat),
                                   expected, "\(bpm)/\(stepsPerBeat) step \(step)")
                    XCTAssertEqual(unity.sample(globalStep: step, stepsPerBeat: stepsPerBeat),
                                   expected, "a ratio of 1 is straight")
                }
            }
        }
    }

    /// Beat and bar lines must not move under any swing. The count-in hands over to the backing
    /// on a bar line, and the analysis window is cut on one.
    func testBeatAndBarLinesNeverMoveHoweverDeepTheSwing() {
        for ratio in [1.5, 2.0, 3.0, 4.0] {
            for notesPerBeat in [2, 4] {
                let swing = Swing(ratio: ratio, notesPerBeat: notesPerBeat)
                let straight = Sequencer(bpm: 100, sampleRate: sampleRate)
                let swung = Sequencer(bpm: 100, sampleRate: sampleRate, swing: swing)
                for beat in 0..<16 {
                    XCTAssertEqual(swung.sample(globalStep: beat * 4, stepsPerBeat: 4),
                                   straight.sample(globalStep: beat * 4, stepsPerBeat: 4),
                                   "ratio \(ratio), \(notesPerBeat)/beat, beat \(beat)")
                }
            }
        }
    }

    /// Triplets have no binary pair, so a feel must leave them alone on both sides at once.
    func testATripletRungIsUntouchedByBothTheGridAndTheBand() {
        let swing = Swing(ratio: 2, notesPerBeat: 3)
        XCTAssertFalse(swing.isActive)
        XCTAssertFalse(Feel.swung.applies(toSubdivisions: 3))

        let straight = Sequencer(bpm: 100, sampleRate: sampleRate)
        let swung = Sequencer(bpm: 100, sampleRate: sampleRate, swing: swing)
        for step in 0..<24 {
            XCTAssertEqual(swung.sample(globalStep: step, stepsPerBeat: 3),
                           straight.sample(globalStep: step, stepsPerBeat: 3))
        }
    }

    // MARK: The config is the single conversion point

    /// One place turns a `Feel` into a `Swing`. If a second appears, the two can drift.
    func testTheJamConfigIsWhereAFeelBecomesASwing() {
        guard let feel = Feel(swingRatio: 1.5) else { return XCTFail("1.5 is valid") }
        let config = TrainerEngine.JamConfig(bpm: 100, rung: .eighths, feel: feel)

        XCTAssertEqual(config.swing.ratio, 1.5)
        XCTAssertEqual(config.swing.notesPerBeat, config.gridSubdivisions,
                       "the band divides what the grid scores")
        XCTAssertEqual(config.swing.notesPerBeat, 2)
    }

    /// A free jam carries no rung, so it must carry no swing either — the benchmark and both
    /// experiment arms play exactly what they always have (R3.5).
    func testAFreeJamSwingsNothing() {
        let free = TrainerEngine.JamConfig(bpm: 100, bars: 64, tag: "benchmark")
        XCTAssertFalse(free.swing.isActive)
        XCTAssertEqual(free.feel, .straight)
    }
}
