import Foundation
import XCTest
@testable import TimingCore
@testable import TrainerKit

/// Synthetic takes with known properties, for exercising storage without hardware.
///
/// Every test file used to roll its own tap builder — `BootstrapTests` has `gaussianSeries`,
/// `TempoMemoryTests` has a round layout, `SelfTest` had a third. One generator means one place
/// to add a pathology, and every drill inherits it. See PLAN.md §7.22.
enum TakeFactory {

    /// Deterministic Gaussian noise. Seeded, so a failing case is reproducible (R1.2.1).
    struct Noise {
        private var rng: SplitMix64
        init(seed: UInt64) { rng = SplitMix64(seed: seed) }
        mutating func uniform() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }
        mutating func gaussian(sd: Double) -> Double {
            guard sd > 0 else { return 0 }
            let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
            return sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    /// What kind of player to simulate. Every field is a quantity the analysis reports back, so
    /// a test can plant a value and check the pipeline recovers it.
    struct Performance {
        var beats: Int = 128
        /// Negative is ahead of the beat, which is the normal direction for this player.
        var biasMs: Double = -12
        var spreadMs: Double = 14
        /// Tempo drift while playing, in ms per beat.
        var driftMsPerBeat: Double = 0
        /// Fraction of notes pushed outside the matching window entirely.
        var offGridRate: Double = 0
        /// Notes per event: 1 is a single line, 3 is chordal.
        var chordSize: Int = 1
        var seed: UInt64 = 0xBEEF

        static let steady = Performance()
        /// Nothing played at all — the case that destroyed a take in a live session.
        static let silent = Performance(beats: 0, biasMs: 0, spreadMs: 0)
        static let oneNote = Performance(beats: 1, biasMs: 0, spreadMs: 0)
    }

    /// Note-on times against a grid, with the planted bias, spread and drift applied.
    static func taps(_ p: Performance, grid: Grid) -> [Tap] {
        guard p.beats > 0 else { return [] }
        var noise = Noise(seed: p.seed)
        var out: [Tap] = []
        for beat in 0..<p.beats {
            let target = grid.time(ofIndex: beat * grid.subdivisions)
            var offset = (p.biasMs + p.driftMsPerBeat * Double(beat)) / 1000
            offset += noise.gaussian(sd: p.spreadMs) / 1000
            // An off-grid note lands beyond the matching window and is counted as an extra.
            if noise.uniform() < p.offGridRate { offset += grid.interval * 0.45 }
            for voice in 0..<Swift.max(1, p.chordSize) {
                out.append(Tap(time: target + offset + Double(voice) * 0.004,
                               velocity: 80, note: 60 + voice * 4))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    static func grid(bpm: Double = 100, subdivisions: Int = 4) -> Grid {
        Grid(startTime: 1_000, bpm: bpm, subdivisions: subdivisions)
    }

    // MARK: - Stored takes
    //
    // Built through the same summary fields the engine writes, so a change to what is stored
    // shows up here rather than only in a live run.

    static func jam(_ p: Performance = .steady, bars: Int = 32, tag: String? = nil) -> JamSession {
        let g = grid()
        let raw = taps(p, grid: g)
        let events = TapClustering.collapse(raw, windowSeconds: 0.035)
        let r = TimingAnalysis.analyze(taps: events, grid: g)
        return JamSession(
            date: Date(timeIntervalSince1970: 1_770_000_000), bpm: g.bpm, device: "test-device",
            calibrationConstantMs: 2.58, calibrationSource: "measured", grooveName: "jamBacking",
            bars: bars, subdivisions: g.subdivisions, tag: tag, feelRating: 4,
            gridStartTime: g.startTime,
            tapTimes: events.map(\.time), tapVelocities: events.map(\.velocity),
            matchedCount: r.matchedCount, extraCount: r.extraCount, missedCount: r.missedCount,
            meanAsynchronyMs: Stats.finite(r.meanAsynchronyMs),
            sdAsynchronyMs: Stats.finite(r.sdAsynchronyMs),
            lag1Autocorrelation: Stats.finite(r.lag1Autocorrelation),
            driftMsPerBeat: Stats.finite(r.driftMsPerBeat),
            headline: r.headline, placement: placement(role: "benchmark"),
            rawTimes: raw.map(\.time), rawNotes: raw.map(\.note),
            rawVelocities: raw.map(\.velocity))
    }

    static func form(marks: Int = 8, phraseBars: Int = 8, level: Int = 0) -> FormSession {
        let g = grid(subdivisions: 4)
        let barSeconds = g.beatInterval * 4
        let markTimes = (0..<marks).map { g.startTime + Double($0 * phraseBars) * barSeconds + 0.01 }
        let r = FormAnalysis.analyze(markTimes: markTimes, grid: g, beatsPerBar: 4,
                                     barsPerPhrase: phraseBars, totalBars: 64)
        return FormSession(
            date: Date(timeIntervalSince1970: 1_770_000_100), bpm: g.bpm, bars: 64,
            phraseBars: phraseBars, level: level, feelRating: 3, gridStartTime: g.startTime,
            markTimes: markTimes, phrasesAvailable: r.phrasesAvailable,
            marksPlaced: r.marksPlaced, onFormCount: r.onFormCount, tightCount: r.tightCount,
            meanAbsFormErrorBars: Stats.finite(r.meanAbsFormErrorBars),
            phaseErrorMeanMs: Stats.finite(r.phaseErrorMeanMs),
            phaseErrorSDms: Stats.finite(r.phaseErrorSDms),
            slipBarsPerPhrase: Stats.finite(r.slipBarsPerPhrase),
            missedPhrases: r.missedPhrases, headline: r.headline,
            placement: placement(role: "training"))
    }

    static func dropout(_ p: Performance = .steady, cycles: Int = 4) -> DropoutSession {
        let g = grid(subdivisions: 1)
        let session = DropoutSession(
            date: Date(timeIntervalSince1970: 1_770_000_200), bpm: g.bpm, pacedBars: 4,
            silentBars: 4, cycles: cycles, feelRating: 4, gridStartTime: g.startTime,
            tapTimes: taps(p, grid: g).map(\.time),
            pacedSDms: nil, unpacedIntervalSDms: nil, clockSDms: nil, motorSDms: nil,
            modelHolds: false, reentryErrorMeanMs: nil, reentryErrorSDms: nil,
            headline: "", tempoBiasBpm: nil, playedBpm: nil, splitIsReliable: nil,
            discardedTrials: nil, placement: placement(role: "training"))
        // Recompute through the same path the engine uses, so the stored summary is the one the
        // analysis actually produces rather than a hand-written guess.
        let (t, gr, sections) = session.reconstruct()
        let r = DropoutAnalysis.analyze(taps: t, grid: gr, sections: sections)
        return DropoutSession(
            date: session.date, bpm: session.bpm, pacedBars: session.pacedBars,
            silentBars: session.silentBars, cycles: session.cycles, feelRating: session.feelRating,
            gridStartTime: session.gridStartTime, tapTimes: session.tapTimes,
            pacedSDms: Stats.finite(r.pacedSDms),
            unpacedIntervalSDms: Stats.finite(r.unpacedIntervalSDms),
            clockSDms: Stats.finite(r.wingKristofferson?.clockSDms),
            motorSDms: Stats.finite(r.wingKristofferson?.motorSDms),
            modelHolds: r.wingKristofferson?.modelHolds ?? false,
            reentryErrorMeanMs: Stats.finite(r.reentryErrorMeanMs),
            reentryErrorSDms: Stats.finite(r.reentryErrorSDms), headline: r.headline,
            tempoBiasBpm: Stats.finite(r.tempoBiasBpm), playedBpm: Stats.finite(r.playedBpm),
            splitIsReliable: r.splitIsReliable, discardedTrials: r.discardedTrials,
            placement: session.placement)
    }

    static func tempo(rounds: Int = 4) -> TempoSession {
        let holdSeconds = 9.6
        let starts = (0..<rounds).map { 1_000 + Double($0) * 20 }
        return TempoSession(
            date: Date(timeIntervalSince1970: 1_770_000_300), targets: [100], leadBars: 4,
            holdBars: 4, rounds: rounds, feelRating: 3,
            tapTimes: starts.flatMap { start in (0..<16).map { start + Double($0) * 0.6 } },
            roundTargets: Array(repeating: 100, count: rounds),
            roundHoldStarts: starts, roundHoldEnds: starts.map { $0 + holdSeconds },
            usableCount: rounds, meanErrorPercent: nil, meanAbsErrorPercent: nil,
            improvementPerRound: nil, headline: "", placement: placement(role: "cold"))
    }

    static func memory(rounds: Int = 4) -> MemorySession {
        let starts = (0..<rounds).map { 1_000 + Double($0) * 30 }
        return MemorySession(
            date: Date(timeIntervalSince1970: 1_770_000_400), bpm: 100, referenceBars: 4,
            retentionBars: 4, reproduceBars: 4, rounds: rounds, feelRating: 3,
            tapTimes: starts.flatMap { start in (0..<16).map { start + 10 + Double($0) * 0.6 } },
            roundConditions: (0..<rounds).map { $0 % 2 == 0 ? "silent" : "filled" },
            roundRetentionStarts: starts, roundRetentionEnds: starts.map { $0 + 9.6 },
            roundReproduceStarts: starts.map { $0 + 9.6 },
            roundReproduceEnds: starts.map { $0 + 19.2 },
            usableCount: rounds, silentMeanAbsErrorPercent: nil,
            filledMeanAbsErrorPercent: nil, interferenceCost: nil, headline: "",
            placement: placement(role: "training"))
    }

    private static func placement(role: String) -> SessionPlacement {
        SessionPlacement(sessionId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")
            ?? UUID(), blockIndex: 2, role: role, elapsedSeconds: 420)
    }
}

/// A test case that redirects the session store into a fresh temporary directory.
///
/// Subclass this rather than calling `SessionStore.save` directly. The player's real practice
/// history is primary data (R6.2) and a suite that writes takes must never be one keystroke
/// away from writing them there.
class StoreBackedTestCase: XCTestCase {
    private(set) var storeURL = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        try super.setUpWithError()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicalTrainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        SessionStore.directoryOverride = storeURL
    }

    override func tearDownWithError() throws {
        SessionStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: storeURL)
        try super.tearDownWithError()
    }

    /// Fails loudly if the redirect is not in place. Every test that writes calls this first.
    func assertStoreIsRedirected(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SessionStore.directory.path, storeURL.path,
                       "the session store must be redirected before a test writes a take",
                       file: file, line: line)
    }
}
