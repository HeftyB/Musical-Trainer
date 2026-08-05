import XCTest
@testable import GrooveCore

final class DistractorTests: XCTestCase {
    private let fs = 44_100.0
    private let beat = 0.6                  // 100 BPM
    private var beatSamples: Double { beat * fs }

    private func makeHits(bars: Int = 8, seed: UInt64 = 0x0D15) -> [ScheduledHit] {
        let end = Int64(Double(bars) * 4 * beatSamples)
        return Distractor.hits(from: 0, to: end, sampleRate: fs, beatSeconds: beat,
                               gridOriginSample: 0, seed: seed)
    }

    private func phases(_ hits: [ScheduledHit]) -> [Double] {
        hits.map { Distractor.beatPhase(sample: $0.sample, gridOriginSample: 0,
                                        beatSamples: beatSamples) }
    }

    /// Circular concentration of the beat-phases at a given harmonic, in 0...1.
    ///
    /// The fundamental alone is not enough, and assuming otherwise nearly let a metronome
    /// through: onsets on every *sixteenth* sit at phases 0, ¼, ½, ¾, which are spread
    /// perfectly evenly around the circle and score ≈0 at k=1. They score 1 at k=4. Locking
    /// to any subdivision shows up at that subdivision's harmonic, so the test has to look
    /// at all of them.
    private func concentration(_ phases: [Double], harmonic k: Int) -> Double {
        guard !phases.isEmpty else { return 1 }
        var x = 0.0, y = 0.0
        for p in phases {
            x += Foundation.cos(2 * .pi * Double(k) * p)
            y += Foundation.sin(2 * .pi * Double(k) * p)
        }
        return (x * x + y * y).squareRoot() / Double(phases.count)
    }

    /// The worst case across the beat and its usual subdivisions.
    private func worstConcentration(_ phases: [Double]) -> Double {
        (1...4).map { concentration(phases, harmonic: $0) }.max() ?? 1
    }

    // MARK: - The property the drill rests on

    /// The obvious implementation — build it from `Pattern` — puts every onset on a
    /// sixteenth of the tempo being remembered, which rehearses the period instead of
    /// interfering with it. This test is what tells the two apart.
    ///
    /// The threshold is not zero, and should not be: the beat guard deliberately pushes
    /// onsets away from the beat, which by itself leaves a mild concentration near half a
    /// beat. That bias is the drill working, not failing. What matters is the distance from
    /// an entrainable train, which scores ≈1.
    func testOnsetsAreSpreadAcrossTheBeatRatherThanLockedToIt() {
        let hits = makeHits(bars: 32)
        XCTAssertGreaterThan(hits.count, 60, "need enough onsets to judge the distribution")
        XCTAssertLessThan(worstConcentration(phases(hits)), 0.5,
                          "onsets cluster at some subdivision — the distractor carries the pulse")
    }

    /// Sanity check on the measure itself: grid-aligned trains must score near 1, so a low
    /// score above is evidence rather than an artefact of how concentration is computed.
    func testTheConcentrationMeasureCatchesGridAlignedTrains() {
        for perBeat in [1, 2, 4] {
            let onGrid = (0..<48).map {
                ScheduledHit(voice: .closedHat,
                             sample: Int64(Double($0) * beatSamples / Double(perBeat)),
                             velocity: 80)
            }
            XCTAssertGreaterThan(worstConcentration(phases(onGrid)), 0.95,
                                 "\(perBeat) per beat should be caught")
        }
    }

    func testNoOnsetLandsOnABeat() {
        for phase in phases(makeHits(bars: 16)) {
            XCTAssertGreaterThanOrEqual(phase, Distractor.beatGuard - 1e-6)
            XCTAssertLessThanOrEqual(phase, 1 - Distractor.beatGuard + 1e-6)
        }
    }

    /// If the intervals were secretly isochronous the phase test could still pass by luck at
    /// an awkward period, so check the intervals themselves are genuinely varied.
    func testIntervalsAreNotSecretlyIsochronous() {
        let samples = makeHits(bars: 16).map { Double($0.sample) }
        var intervals: [Double] = []
        for i in 1..<samples.count { intervals.append(samples[i] - samples[i - 1]) }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let sd = (intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                  / Double(intervals.count - 1)).squareRoot()
        XCTAssertGreaterThan(sd / mean, 0.25, "intervals barely vary — this is a pulse")
    }

    /// No kick and no crash: both read as downbeats however they are placed, and a heard
    /// downbeat is a bar line the player can rebuild the tempo from.
    func testNoDownbeatVoicesAreUsed() {
        let used = Set(makeHits(bars: 16).map(\.voice))
        XCTAssertFalse(used.contains(.kick))
        XCTAssertFalse(used.contains(.crash))
    }

    // MARK: - Mechanics

    func testIsDeterministicForASeedAndDiffersAcrossSeeds() {
        XCTAssertEqual(makeHits(seed: 7), makeHits(seed: 7))
        XCTAssertNotEqual(makeHits(seed: 7), makeHits(seed: 8))
    }

    func testHitsStayInsideTheWindow() {
        let start: Int64 = 100_000
        let end: Int64 = 400_000
        let hits = Distractor.hits(from: start, to: end, sampleRate: fs, beatSeconds: beat,
                                   gridOriginSample: 0, seed: 3)
        XCTAssertFalse(hits.isEmpty)
        for hit in hits {
            XCTAssertGreaterThanOrEqual(hit.sample, start)
            XCTAssertLessThan(hit.sample, end)
        }
    }

    func testDegenerateWindowsProduceNothing() {
        XCTAssertTrue(Distractor.hits(from: 100, to: 100, sampleRate: fs,
                                      beatSeconds: beat).isEmpty)
        XCTAssertTrue(Distractor.hits(from: 0, to: 1000, sampleRate: fs,
                                      beatSeconds: 0).isEmpty)
    }

    /// The phase guarantee has to hold when the grid does not start at sample zero, which is
    /// the normal case once a count-in and earlier rounds are in front of it.
    func testTheBeatGuardHoldsAgainstAnOffsetGrid() {
        let origin: Int64 = 12_345
        let hits = Distractor.hits(from: origin, to: origin + Int64(32 * beatSamples),
                                   sampleRate: fs, beatSeconds: beat,
                                   gridOriginSample: origin, seed: 11)
        for hit in hits {
            let phase = Distractor.beatPhase(sample: hit.sample, gridOriginSample: origin,
                                             beatSamples: beatSamples)
            XCTAssertGreaterThanOrEqual(phase, Distractor.beatGuard - 1e-6)
            XCTAssertLessThanOrEqual(phase, 1 - Distractor.beatGuard + 1e-6)
        }
    }

    // MARK: - Difficulty

    /// The groove stopping with no warning caught the player out on the first live run. The
    /// fill lands in the last reference bar, while the groove is still playing, so it gives
    /// away no tempo the player does not already have.
    func testTheLastReferenceBarCarriesAStopWarning() {
        XCTAssertFalse(TempoMemoryDrill.isWarningBar(bar: 0, referenceBars: 4))
        XCTAssertFalse(TempoMemoryDrill.isWarningBar(bar: 2, referenceBars: 4))
        XCTAssertTrue(TempoMemoryDrill.isWarningBar(bar: 3, referenceBars: 4))

        let groove = GrooveLibrary.basicRock
        let plain = TempoMemoryDrill.referencePattern(bar: 0, referenceBars: 4, groove: groove)
        let warning = TempoMemoryDrill.referencePattern(bar: 3, referenceBars: 4, groove: groove)

        XCTAssertEqual(plain, groove, "only the last bar differs")
        XCTAssertGreaterThan(warning.hits.count, groove.hits.count, "the fill adds hits")
    }

    /// The fill **adds to** the groove. A fill that replaced it would leave a hole where the
    /// pulse should be, and the player would have to re-find the beat going into the silence —
    /// the opposite of what the drill trains (PLAN.md §6.1).
    func testTheWarningFillNeverRemovesThePulse() {
        let groove = GrooveLibrary.basicRock
        let warning = TempoMemoryDrill.referencePattern(bar: 3, referenceBars: 4, groove: groove)
        for hit in groove.hits {
            XCTAssertTrue(warning.hits.contains(hit),
                          "the groove's own \(hit.voice) at step \(hit.step) was dropped")
        }
        XCTAssertFalse(warning.hits.contains { $0.voice == .crash },
                       "a crash would be a landmark, not a warning")
    }

    /// A one-bar reference section has no room for a warning bar that is not the whole thing.
    func testASingleReferenceBarCarriesNoWarning() {
        XCTAssertFalse(TempoMemoryDrill.isWarningBar(bar: 0, referenceBars: 1))
        XCTAssertEqual(TempoMemoryDrill.referencePattern(bar: 0, referenceBars: 1,
                                                         groove: GrooveLibrary.basicRock),
                       GrooveLibrary.basicRock)
    }

    func testConditionsAlternateStartingWithTheControl() {
        XCTAssertFalse(TempoMemoryDrill.isFilled(round: 0), "the first round is the control")
        XCTAssertTrue(TempoMemoryDrill.isFilled(round: 1))
        let filled = (0..<8).filter { TempoMemoryDrill.isFilled(round: $0) }.count
        XCTAssertEqual(filled, 4, "conditions stay balanced across the session")
    }
}
