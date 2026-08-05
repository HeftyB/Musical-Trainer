import XCTest
import TestSupport
@testable import TimingCore

final class PooledWingKristoffersonTests: XCTestCase {
    private func wkTrial(count: Int, beatMs: Double, clockSD: Double, motorSD: Double,
                         rng: inout SeededRNG) -> [Double] {
        // Onset k = accumulated clock intervals + a fresh motor delay; intervals are the
        // differences. This construction has variance σ²c + 2σ²m and lag-1 −σ²m.
        var times: [Double] = []
        var clock = 0.0
        for _ in 0..<count {
            times.append(clock + rng.gaussian(sd: motorSD))
            clock += rng.gaussian(mean: beatMs, sd: clockSD)
        }
        return (1..<times.count).map { times[$0] - times[$0 - 1] }
    }

    func testPooledRecoversKnownVariances() {
        var rng = SeededRNG(seed: 11)
        let clockSD = 11.0, motorSD = 6.0
        let trials = (0..<400).map { _ in
            wkTrial(count: 32, beatMs: 600, clockSD: clockSD, motorSD: motorSD, rng: &rng)
        }
        let result = WingKristofferson.decompose(trials: trials)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.modelHolds)
        XCTAssertEqual(result!.clockSDms, clockSD, accuracy: clockSD * 0.12)
        XCTAssertEqual(result!.motorSDms, motorSD, accuracy: motorSD * 0.12)
    }

    /// The reason trials are centred individually: a tempo that differs between silences
    /// must not be counted as clock noise.
    func testBetweenTrialTempoDifferencesAreNotCountedAsClockNoise() {
        var rng = SeededRNG(seed: 12)
        let clockSD = 8.0, motorSD = 5.0
        // Each trial sits at a noticeably different tempo.
        let trials = (0..<400).map { i -> [Double] in
            let base = 600 + Double((i % 5) - 2) * 40      // 520…680 ms between trials
            return wkTrial(count: 32, beatMs: base, clockSD: clockSD, motorSD: motorSD, rng: &rng)
        }
        let result = WingKristofferson.decompose(trials: trials)!
        XCTAssertEqual(result.clockSDms, clockSD, accuracy: clockSD * 0.15)
        XCTAssertEqual(result.motorSDms, motorSD, accuracy: motorSD * 0.15)
    }

    func testNoProductsSpanTrialBoundaries() {
        // Two trials that are individually constant but very different from each other.
        // Concatenating naively would invent a huge lag-1 term at the join.
        let a = [Double](repeating: 500, count: 10)
        let b = [Double](repeating: 700, count: 10)
        let result = WingKristofferson.decompose(trials: [a, b])!
        XCTAssertEqual(result.intervalVarianceMs2, 0, accuracy: 1e-9)
        XCTAssertEqual(result.lag1AutocovarianceMs2, 0, accuracy: 1e-9)
    }

    func testTooShortTrialsAreIgnored() {
        XCTAssertNil(WingKristofferson.decompose(trials: [[500, 500]]))
    }
}

final class DropoutAnalysisTests: XCTestCase {
    // 100 BPM → 0.6 s beats.
    private let grid = Grid(startTime: 0, bpm: 100, subdivisions: 1)
    private let beat = 0.6

    /// 4 bars band + 4 bars silence, twice.
    private func sections() -> [DropoutSection] {
        let bar = beat * 4
        return [
            DropoutSection(startTime: 0, endTime: 4 * bar, isPaced: true),
            DropoutSection(startTime: 4 * bar, endTime: 8 * bar, isPaced: false),
            DropoutSection(startTime: 8 * bar, endTime: 12 * bar, isPaced: true),
            DropoutSection(startTime: 12 * bar, endTime: 16 * bar, isPaced: false),
            DropoutSection(startTime: 16 * bar, endTime: 20 * bar, isPaced: true),
        ]
    }

    /// Quarter notes for the whole drill, with a chosen tempo error during the silences.
    private func taps(unpacedBeatSeconds: Double, jitter: Double = 0, seed: UInt64 = 1) -> [Tap] {
        var rng = SeededRNG(seed: seed)
        var out: [Tap] = []
        var time = 0.0
        var beatIndex = 0
        let sections = self.sections()
        while time < sections.last!.endTime {
            out.append(Tap(time: time + (jitter > 0 ? rng.gaussian(sd: jitter) : 0)))
            let paced = sections.first { time >= $0.startTime && time < $0.endTime }?.isPaced ?? true
            // While the band plays, stay locked to the grid; during silence, run at the
            // player's own tempo, which is what accumulates drift.
            time = paced ? Double(beatIndex + 1) * beat : time + unpacedBeatSeconds
            beatIndex += 1
        }
        return out
    }

    func testDetectsSlowingDuringSilence() {
        // 610 ms beats instead of 600 → +10 ms per beat.
        let report = DropoutAnalysis.analyze(taps: taps(unpacedBeatSeconds: 0.610),
                                             grid: grid, sections: sections())
        XCTAssertNotNil(report.tempoBiasMsPerBeat)
        XCTAssertEqual(report.tempoBiasMsPerBeat!, 10, accuracy: 3.0)
        XCTAssertNotNil(report.tempoBiasBpm)
        XCTAssertLessThan(report.tempoBiasBpm!, 0)         // slower than the grid
        XCTAssertTrue(report.headline.lowercased().contains("slow")
                      || report.headline.lowercased().contains("clock")
                      || report.headline.lowercased().contains("hands"))
    }

    func testDetectsSpeedingUpDuringSilence() {
        let report = DropoutAnalysis.analyze(taps: taps(unpacedBeatSeconds: 0.590),
                                             grid: grid, sections: sections())
        XCTAssertEqual(report.tempoBiasMsPerBeat!, -10, accuracy: 3.0)
        XCTAssertGreaterThan(report.tempoBiasBpm!, 0)      // faster than the grid
    }

    func testSeparatesPacedAndUnpacedPlaying() {
        let report = DropoutAnalysis.analyze(taps: taps(unpacedBeatSeconds: 0.600),
                                             grid: grid, sections: sections())
        XCTAssertGreaterThan(report.pacedNoteCount, 0)
        XCTAssertGreaterThan(report.unpacedNoteCount, 0)
        XCTAssertEqual(report.trials.count, 2)             // two silences
        for trial in report.trials { XCTAssertGreaterThan(trial.intervalsMs.count, 4) }
    }

    func testReentryErrorIsMeasured() {
        // Drift 20 ms per beat through a 16-beat silence, so re-entry is clearly late.
        let report = DropoutAnalysis.analyze(taps: taps(unpacedBeatSeconds: 0.620),
                                             grid: grid, sections: sections())
        let reentries = report.trials.compactMap(\.reentryErrorMs)
        XCTAssertFalse(reentries.isEmpty, "re-entry after the band returns should be measured")
    }

    /// A silence with *mixed* note values is not a continuation sequence, and feeding it to
    /// Wing–Kristofferson produces confident nonsense. This is what actually happened in a
    /// real take: half the silences had eighths dropped into the quarters, and the reported
    /// clock SD came out at 143 ms.
    func testMixedSubdivisionSilenceIsDiscarded() {
        let secs = sections()
        var out: [Tap] = []
        var t = 0.0
        while t < secs[1].endTime { out.append(Tap(time: t)); t += beat }   // clean quarters
        // Second silence: quarters with extra notes squeezed in between.
        t = secs[3].startTime
        var alternate = false
        while t < secs[3].endTime {
            out.append(Tap(time: t))
            t += alternate ? beat / 2 : beat
            alternate.toggle()
        }
        let report = DropoutAnalysis.analyze(taps: out, grid: grid, sections: secs)

        XCTAssertEqual(report.trials.count, 2)
        XCTAssertEqual(report.discardedTrials, 1, "the mixed-value silence should be discarded")
        XCTAssertTrue(report.trials[0].isIsochronous)
        XCTAssertFalse(report.trials[1].isIsochronous)
    }

    /// Consistent subdividing is still a valid continuation task — but the note period is
    /// not the beat period, and reporting it raw would say 200 BPM for a player who is right.
    func testConsistentSubdivisionIsAcceptedAndTempoNormalised() {
        let secs = sections()
        var out: [Tap] = []
        var t = 0.0
        while t < secs.last!.endTime { out.append(Tap(time: t)); t += beat / 2 }   // eighths
        let report = DropoutAnalysis.analyze(taps: out, grid: grid, sections: secs)

        XCTAssertEqual(report.discardedTrials, 0, "steady eighths are isochronous")
        XCTAssertNotNil(report.playedBpm)
        XCTAssertEqual(report.playedBpm!, 100, accuracy: 2,
                       "eighths at the right tempo must not read as 200 BPM")
    }

    func testTempoBiasIsReportedInBpm() {
        // 630 ms beats instead of 600 → about 95 BPM against a 100 BPM click.
        let report = DropoutAnalysis.analyze(taps: taps(unpacedBeatSeconds: 0.630),
                                             grid: grid, sections: sections())
        XCTAssertNotNil(report.playedBpm)
        XCTAssertEqual(report.playedBpm!, 95.2, accuracy: 1.5)
        XCTAssertNotNil(report.tempoBiasBpm)
        XCTAssertLessThan(report.tempoBiasBpm!, 0)          // slower than the click
        XCTAssertTrue(report.headline.lowercased().contains("slower"),
                      "expected the tempo bias to lead, got: \(report.headline)")
    }

    /// A motor estimate pinned at the model's floor is not a measurement of a person.
    func testSplitIsNotCalledReliableWhenMotorPinsAtZero() {
        // Perfectly regular playing: no interval variance at all, so γ₁ = 0 and motor → 0.
        let bar = beat * 4
        var out: [Tap] = []
        var t = 0.0
        while t < sections().last!.endTime { out.append(Tap(time: t)); t += beat }
        _ = bar
        let report = DropoutAnalysis.analyze(taps: out, grid: grid, sections: sections())
        XCTAssertFalse(report.splitIsReliable,
                       "a zero motor estimate is the model hitting its floor, not a result")
    }

    func testSparseInputGivesHonestHeadline() {
        let report = DropoutAnalysis.analyze(taps: [Tap(time: 0), Tap(time: 0.6)],
                                             grid: grid, sections: sections())
        XCTAssertTrue(report.headline.lowercased().contains("not enough"))
    }
}
