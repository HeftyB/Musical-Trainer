import Foundation
import XCTest
@testable import GrooveCore
@testable import TimingCore
import TestSupport
@testable import TrainerKit

/// Builders for *stored* takes, on top of the shared `Performance` generator.
///
/// The generator itself lives in `TestSupport` so every suite shares it. These builders cannot:
/// the session types are `internal` to `TrainerKit`, and making them public to share a test
/// helper would be an API commitment bought for a convenience. The boundary is forced by
/// visibility rather than chosen, which is the only reason it is here.
enum TakeFactory {

    /// A stand-in assignment, so a test can check the arm survives storage.
    static func assignment(arm: String, runIndex: Int = 0) -> ExperimentAssignment {
        ExperimentAssignment(
            experimentId: UUID(uuidString: "00000000-0000-0000-0000-00000000E00D") ?? UUID(),
            name: "steady-vs-melodic", arm: arm, runIndex: runIndex)
    }

    static func grid(bpm: Double = 100, subdivisions: Int = 4) -> Grid {
        Grid(startTime: 1_000, bpm: bpm, subdivisions: subdivisions)
    }

    // MARK: - Stored takes
    //
    // Built through the same summary fields the engine writes, so a change to what is stored
    // shows up here rather than only in a live run.

    static func jam(_ p: Performance = .steady, bars: Int = 32, tag: String? = nil,
                    experiment: ExperimentAssignment? = nil,
                    grid customGrid: Grid? = nil,
                    rung: IntervalRung? = nil, feel: Feel = .straight,
                    offbeatLevel: Int? = nil,
                    generatedBacking: BackingIdentity? = nil,
                    // A day apart, like the other four factories. Two takes sharing a timestamp
                    // overwrite each other on disk (§7.22), so a trend needs distinct dates.
                    dayOffset: Int = 0,
                    // `nil` is what every take recorded before §7.61 carries, so it is the
                    // honest default for a synthetic one. A test about the kit axis sets it.
                    kitFingerprint: String? = nil) -> JamSession {
        let g = customGrid ?? grid()
        let raw = p.taps(grid: g)
        let events = TapClustering.collapse(raw, windowSeconds: 0.035)
        let r = TimingAnalysis.analyze(taps: events, grid: g)
        return JamSession(
            date: Date(timeIntervalSince1970: 1_770_000_000 + Double(dayOffset) * 86_400),
            bpm: g.bpm, device: "test-device", kitFingerprint: kitFingerprint,
            calibrationConstantMs: 2.58, calibrationSource: "measured",
            // The name the engine would have written, not a literal: an offbeat take is stored
            // under its backing, and a test that says "jamBacking" cannot see a confound the
            // real take carries.
            // A generated backing overrides, because a take over a style is stored under
            // `style@seed` and a test that says "jamBacking" cannot see the axis the real take
            // carries — the same reason the offbeat name is derived rather than written.
            grooveName: generatedBacking?.name
                ?? offbeatLevel.map { "offbeat-\($0)" } ?? "jamBacking",
            bars: bars, subdivisions: g.subdivisions, rung: rung?.rawValue,
            swingRatio: feel.isStraight ? nil : feel.swingRatio,
            offbeatLevel: offbeatLevel, tag: tag, feelRating: 4,
            gridStartTime: g.startTime,
            tapTimes: events.map(\.time), tapVelocities: events.map(\.velocity),
            matchedCount: r.matchedCount, extraCount: r.extraCount, missedCount: r.missedCount,
            meanAsynchronyMs: Stats.finite(r.meanAsynchronyMs),
            sdAsynchronyMs: Stats.finite(r.sdAsynchronyMs),
            lag1Autocorrelation: Stats.finite(r.lag1Autocorrelation),
            driftMsPerBeat: Stats.finite(r.driftMsPerBeat),
            headline: r.headline, placement: placement(role: "benchmark"),
            experiment: experiment, wasProbe: nil,
            rawTimes: raw.map(\.time), rawNotes: raw.map(\.note),
            rawVelocities: raw.map(\.velocity))
    }

    static func form(marks: Int = 8, phraseBars: Int = 8, level: Int = 0,
                     dayOffset: Int = 0, wasProbe: Bool = false) -> FormSession {
        let g = grid(subdivisions: 4)
        let barSeconds = g.beatInterval * 4
        let markTimes = (0..<marks).map { g.startTime + Double($0 * phraseBars) * barSeconds + 0.01 }
        let r = FormAnalysis.analyze(markTimes: markTimes, grid: g, beatsPerBar: 4,
                                     barsPerPhrase: phraseBars, totalBars: 64)
        return FormSession(
            date: Date(timeIntervalSince1970: 1_770_000_100 + Double(dayOffset) * 86_400),
            kitFingerprint: nil,
            bpm: g.bpm, bars: 64,
            phraseBars: phraseBars, level: level, feelRating: 3, gridStartTime: g.startTime,
            subdivisions: g.subdivisions, markTimes: markTimes, phrasesAvailable: r.phrasesAvailable,
            marksPlaced: r.marksPlaced, onFormCount: r.onFormCount, tightCount: r.nailedCount,
            meanAbsFormErrorBars: Stats.finite(r.meanAbsFormErrorBars),
            phaseErrorMeanMs: Stats.finite(r.phaseErrorMeanMs),
            phaseErrorSDms: Stats.finite(r.phaseErrorSDms),
            slipBarsPerPhrase: Stats.finite(r.slipBarsPerPhrase),
            missedPhrases: r.missedPhrases, headline: r.headline,
            placement: placement(role: "training"), experiment: nil,
            wasProbe: wasProbe ? true : nil)
    }

    static func dropout(_ p: Performance = .steady, cycles: Int = 4, silentBars: Int = 4,
                        rung: IntervalRung? = nil, dayOffset: Int = 0) -> DropoutSession {
        let g = grid(subdivisions: 1)
        let session = DropoutSession(
            date: Date(timeIntervalSince1970: 1_770_000_200 + Double(dayOffset) * 86_400),
            kitFingerprint: nil,
            bpm: g.bpm, pacedBars: 4,
            silentBars: silentBars, cycles: cycles, feelRating: 4, gridStartTime: g.startTime,
            subdivisions: g.subdivisions, tapTimes: p.taps(grid: g).map(\.time),
            pacedSDms: nil, unpacedIntervalSDms: nil, clockSDms: nil, motorSDms: nil,
            modelHolds: false, reentryErrorMeanMs: nil, reentryErrorSDms: nil,
            headline: "", tempoBiasBpm: nil, playedBpm: nil, splitIsReliable: nil,
            discardedTrials: nil, placement: placement(role: "training"), experiment: nil,
            rung: rung?.rawValue, swingRatio: nil)
        // Recompute through the same path the engine uses, so the stored summary is the one the
        // analysis actually produces rather than a hand-written guess.
        let (t, gr, sections) = session.reconstruct()
        let r = DropoutAnalysis.analyze(taps: t, grid: gr, sections: sections)
        return DropoutSession(
            date: session.date, kitFingerprint: session.kitFingerprint,
            bpm: session.bpm, pacedBars: session.pacedBars,
            silentBars: session.silentBars, cycles: session.cycles, feelRating: session.feelRating,
            gridStartTime: session.gridStartTime, subdivisions: session.subdivisions,
            tapTimes: session.tapTimes,
            pacedSDms: Stats.finite(r.pacedSDms),
            unpacedIntervalSDms: Stats.finite(r.unpacedIntervalSDms),
            clockSDms: Stats.finite(r.wingKristofferson?.clockSDms),
            motorSDms: Stats.finite(r.wingKristofferson?.motorSDms),
            modelHolds: r.wingKristofferson?.modelHolds ?? false,
            reentryErrorMeanMs: Stats.finite(r.reentryErrorMeanMs),
            reentryErrorSDms: Stats.finite(r.reentryErrorSDms), headline: r.headline,
            tempoBiasBpm: Stats.finite(r.tempoBiasBpm), playedBpm: Stats.finite(r.playedBpm),
            splitIsReliable: r.splitIsReliable, discardedTrials: r.discardedTrials,
            placement: session.placement, experiment: nil, rung: rung?.rawValue,
            swingRatio: nil)
    }

    static func tempo(rounds: Int = 4, targets: [Double] = [100],
                      dayOffset: Int = 0) -> TempoSession {
        let holdSeconds = 9.6
        let starts = (0..<rounds).map { 1_000 + Double($0) * 20 }
        return TempoSession(
            date: Date(timeIntervalSince1970: 1_770_000_300 + Double(dayOffset) * 86_400),
            kitFingerprint: nil,
            targets: targets, leadBars: 4,
            holdBars: 4, rounds: rounds, feelRating: 3,
            tapTimes: starts.flatMap { start in (0..<16).map { start + Double($0) * 0.6 } },
            roundTargets: (0..<rounds).map { targets[$0 % targets.count] },
            roundHoldStarts: starts, roundHoldEnds: starts.map { $0 + holdSeconds },
            usableCount: rounds, meanErrorPercent: nil, meanAbsErrorPercent: nil,
            improvementPerRound: nil, headline: "", placement: placement(role: "cold"),
            experiment: nil, rung: nil)
    }

    static func memory(rounds: Int = 4, retentionBars: Int = 4,
                       dayOffset: Int = 0) -> MemorySession {
        let starts = (0..<rounds).map { 1_000 + Double($0) * 30 }
        return MemorySession(
            date: Date(timeIntervalSince1970: 1_770_000_400 + Double(dayOffset) * 86_400),
            kitFingerprint: nil,
            bpm: 100, referenceBars: 4,
            retentionBars: retentionBars, reproduceBars: 4, rounds: rounds, feelRating: 3,
            tapTimes: starts.flatMap { start in (0..<16).map { start + 10 + Double($0) * 0.6 } },
            roundConditions: (0..<rounds).map { $0 % 2 == 0 ? "silent" : "filled" },
            roundRetentionStarts: starts, roundRetentionEnds: starts.map { $0 + 9.6 },
            roundReproduceStarts: starts.map { $0 + 9.6 },
            roundReproduceEnds: starts.map { $0 + 19.2 },
            usableCount: rounds, silentMeanAbsErrorPercent: nil,
            filledMeanAbsErrorPercent: nil, interferenceCost: nil, headline: "",
            placement: placement(role: "training"), experiment: nil)
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
