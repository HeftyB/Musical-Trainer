import Foundation
import GrooveCore
import TimingCore

/// Everything a practice surface needs, with no opinion about how results are displayed.
///
/// The CLI and the app both drive this. Keeping presentation out means the measurement
/// logic has exactly one implementation, and a fix to either surface can't silently change
/// what the other one measures.
public enum TrainerEngine {

    /// How long to actually play for.
    ///
    /// `scheduledDurationSeconds()` only knows where the last *sound* is, so any drill that
    /// ends in silence — the tempo drill always, the form drill at level 3 — would be cut off
    /// before its final measured stretch. The config knows the intended length; take whichever
    /// is longer so a trailing cymbal decay is never clipped either.
    private static func runLength(_ intended: Double, _ player: GroovePlayer) -> Double {
        max(intended, player.scheduledDurationSeconds()) + 0.5
    }

    // MARK: - Environment

    public struct Environment {
        public let outputName: String
        public let outputIdentity: String
        public let sampleRate: Double
        public let calibrationMs: Double?
        public let calibrationSource: String?

        public var isCalibrated: Bool { calibrationMs != nil }
    }

    /// Resolve the output device and its calibration. Throws if the configuration cannot
    /// produce trustworthy numbers at all (Bluetooth latency varies run to run).
    public static func environment() throws -> Environment {
        guard let output = AudioDevices.defaultDevice(input: false) else {
            throw SpikeError("Could not resolve the default audio output device.")
        }
        if output.isBluetooth {
            throw SpikeError("""
                Bluetooth audio detected. Its latency varies run to run and cannot be \
                calibrated away. Switch to built-in or wired devices.
                """)
        }
        let store = Calibration.load()
        let constant = store.constant(for: output.identity)
        var sourceLabel: String?
        if let constant {
            switch constant.source {
            case .measured: sourceLabel = "measured"
            case .derived(let from): sourceLabel = "derived from \(store.devices[from]?.displayName ?? from)"
            }
        }
        return Environment(
            outputName: output.dataSource.map { "\(output.name) — \($0)" } ?? output.name,
            outputIdentity: output.identity,
            sampleRate: output.sampleRate,
            calibrationMs: constant?.value,
            calibrationSource: sourceLabel)
    }

    // MARK: - Jam

    public struct JamConfig {
        public var bpm: Double
        public var bars: Int
        public var tag: String?
        public init(bpm: Double = 100, bars: Int = 32, tag: String? = nil) {
            self.bpm = bpm; self.bars = bars; self.tag = tag
        }
        public var durationSeconds: Double { Double(bars + 2) * 4 * 60 / bpm }
    }

    public struct JamOutcome {
        public let report: TimingReport
        public let notesCaptured: Int
        public let eventCount: Int
        public let environment: Environment
        public let config: JamConfig
        fileprivate let gridStartTime: Double
        fileprivate let taps: [Tap]
    }

    public static func runJam(_ config: JamConfig,
                              progress: ((Double) -> Void)? = nil,
                              cancellation: CancellationFlag? = nil) throws -> JamOutcome {
        guard (40...260).contains(config.bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
        guard (4...512).contains(config.bars) else { throw SpikeError("Bars must be 4–512.") }
        let env = try environment()

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: config.bpm, sampleRate: player.outputSampleRate)
        let backing = GrooveLibrary.jamBacking
        let countInBars = 2

        var perBar: [Pattern] = []
        for _ in 0..<countInBars {
            perBar.append(DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0,
                                                groove: GrooveLibrary.basicRock))
        }
        for bar in 0..<config.bars { perBar.append(backing.pattern(atBar: bar)) }

        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() { hits += seq.schedule(pattern: pattern, bar: bar) }
        player.schedule(hits)

        let startSample = seq.barStartSample(bar: countInBars, pattern: GrooveLibrary.basicRock)
        let endSample = seq.barStartSample(bar: countInBars + config.bars, pattern: GrooveLibrary.basicRock)

        let midi = try MIDIInput.started()
        defer { midi.end() }
        midi.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }

        try player.run(forSeconds: runLength(config.durationSeconds, player),
                       progress: progress, cancellation: cancellation)

        guard let reduced = JamAnalysis.reduce(
            outputMap: player.outputMapPairs,
            midi: midi.events.map { ($0.hostTime, Int($0.velocity)) },
            grooveStartSample: startSample, grooveEndSample: endSample,
            bpm: config.bpm, subdivisions: backing.stepsPerBeat,
            calibrationConstantMs: env.calibrationMs ?? 0)
        else { throw SpikeError("Could not reconstruct the take — no audio timing map captured.") }

        let events = TapClustering.collapse(reduced.taps, windowSeconds: 0.035)
        let report = TimingAnalysis.analyze(taps: events, grid: reduced.grid, chordWindowMs: 0)

        return JamOutcome(report: report, notesCaptured: midi.events.count,
                          eventCount: events.count, environment: env, config: config,
                          gridStartTime: reduced.grid.startTime, taps: events)
    }

    @discardableResult
    public static func save(_ outcome: JamOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil) throws -> URL {
        let r = outcome.report
        let session = JamSession(
            date: Date(), bpm: outcome.config.bpm, device: outcome.environment.outputIdentity,
            calibrationConstantMs: outcome.environment.calibrationMs,
            calibrationSource: outcome.environment.calibrationSource,
            grooveName: "jamBacking", bars: outcome.config.bars, subdivisions: 4,
            tag: outcome.config.tag?.lowercased(), feelRating: feelRating,
            gridStartTime: outcome.gridStartTime,
            tapTimes: outcome.taps.map(\.time), tapVelocities: outcome.taps.map(\.velocity),
            matchedCount: r.matchedCount, extraCount: r.extraCount, missedCount: r.missedCount,
            meanAsynchronyMs: r.meanAsynchronyMs, sdAsynchronyMs: r.sdAsynchronyMs,
            lag1Autocorrelation: r.lag1Autocorrelation, driftMsPerBeat: r.driftMsPerBeat,
            headline: r.headline, placement: placement)
        return try SessionStore.save(session)
    }

    // MARK: - Form

    public struct FormConfig {
        public var bpm: Double
        public var bars: Int
        public var phraseBars: Int
        public var level: FormLevel
        public init(bpm: Double = 100, bars: Int = 64, phraseBars: Int = 8,
                    level: FormLevel = .fillAndAccent) {
            self.bpm = bpm; self.bars = bars; self.phraseBars = phraseBars; self.level = level
        }
        public var durationSeconds: Double { Double(bars + 2) * 4 * 60 / bpm }
        public var phrases: Int { bars / phraseBars }
    }

    public struct FormOutcome {
        public let report: FormReport
        public let notesPlayed: Int
        public let environment: Environment
        public let config: FormConfig
        fileprivate let gridStartTime: Double
        fileprivate let markTimes: [Double]
    }

    public static func runForm(_ config: FormConfig,
                               progress: ((Double) -> Void)? = nil,
                               cancellation: CancellationFlag? = nil) throws -> FormOutcome {
        guard (40...260).contains(config.bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
        guard (2...32).contains(config.phraseBars) else { throw SpikeError("Phrase length must be 2–32 bars.") }
        guard config.bars >= config.phraseBars, config.bars <= 512 else {
            throw SpikeError("Bars must be between the phrase length and 512.")
        }
        let env = try environment()

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: config.bpm, sampleRate: player.outputSampleRate)
        let groove = GrooveLibrary.basicRock
        let countInBars = 2

        var perBar: [Pattern] = []
        for _ in 0..<countInBars {
            perBar.append(DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0, groove: groove))
        }
        for bar in 0..<config.bars {
            perBar.append(FormBacking.pattern(bar: bar, phraseBars: config.phraseBars,
                                              level: config.level, groove: groove))
        }

        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() { hits += seq.schedule(pattern: pattern, bar: bar) }
        player.schedule(hits)
        let startSample = seq.barStartSample(bar: countInBars, pattern: groove)

        let midi = try MIDIInput.started()
        defer { midi.end() }
        midi.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }

        try player.run(forSeconds: runLength(config.durationSeconds, player),
                       progress: progress, cancellation: cancellation)

        guard let epoch = player.outputMapPairs.first?.hostTime else {
            throw SpikeError("Could not reconstruct the take — no audio timing map captured.")
        }
        var map = SampleHostMap()
        map.build(pairs: player.outputMapPairs, epoch: epoch)
        guard let startSec = map.hostSeconds(atSample: Double(startSample)) else {
            throw SpikeError("Could not locate the start of the form on the timeline.")
        }

        let constantSec = (env.calibrationMs ?? 0) / 1000
        let markTimes = midi.events.filter(\.isPad)
            .map { HostClock.interval(from: epoch, to: $0.hostTime) - constantSec }
        let grid = Grid(startTime: startSec, bpm: config.bpm, subdivisions: 4)

        let report = FormAnalysis.analyze(markTimes: markTimes, grid: grid, beatsPerBar: 4,
                                          barsPerPhrase: config.phraseBars, totalBars: config.bars)
        return FormOutcome(report: report,
                           notesPlayed: midi.events.filter { !$0.isPad }.count,
                           environment: env, config: config,
                           gridStartTime: startSec, markTimes: markTimes)
    }

    @discardableResult
    public static func save(_ outcome: FormOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil) throws -> URL {
        let r = outcome.report
        let session = FormSession(
            date: Date(), bpm: outcome.config.bpm, bars: outcome.config.bars,
            phraseBars: outcome.config.phraseBars, level: outcome.config.level.rawValue,
            feelRating: feelRating, gridStartTime: outcome.gridStartTime,
            markTimes: outcome.markTimes,
            phrasesAvailable: r.phrasesAvailable, marksPlaced: r.marksPlaced,
            onFormCount: r.onFormCount, tightCount: r.tightCount,
            meanAbsFormErrorBars: r.meanAbsFormErrorBars,
            phaseErrorMeanMs: r.phaseErrorMeanMs, phaseErrorSDms: r.phaseErrorSDms,
            slipBarsPerPhrase: r.slipBarsPerPhrase, missedPhrases: r.missedPhrases,
            headline: r.headline, placement: placement)
        return try SessionStore.save(session)
    }

    // MARK: - Dropout (continuation) drill

    public struct DropoutConfig {
        public var bpm: Double
        public var pacedBars: Int
        public var silentBars: Int
        public var cycles: Int
        public init(bpm: Double = 100, pacedBars: Int = 4, silentBars: Int = 4, cycles: Int = 6) {
            self.bpm = bpm; self.pacedBars = pacedBars; self.silentBars = silentBars; self.cycles = cycles
        }
        public var cycle: DropoutDrill.Cycle {
            DropoutDrill.Cycle(pacedBars: pacedBars, silentBars: silentBars)
        }
        /// One extra paced stretch on the end so the final silence has a re-entry to measure.
        public var totalBars: Int { cycles * cycle.totalBars + pacedBars }
        public var durationSeconds: Double { Double(totalBars + 2) * 4 * 60 / bpm }
    }

    public struct DropoutOutcome {
        public let report: DropoutReport
        public let notesPlayed: Int
        public let environment: Environment
        public let config: DropoutConfig
        /// What to try next, from the measured drift.
        public let suggestedSilentBars: Int
        fileprivate let gridStartTime: Double
        fileprivate let tapTimes: [Double]
    }

    public static func runDropout(_ config: DropoutConfig,
                                  progress: ((Double) -> Void)? = nil,
                                  cancellation: CancellationFlag? = nil) throws -> DropoutOutcome {
        guard (40...260).contains(config.bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
        guard (1...16).contains(config.pacedBars), (1...32).contains(config.silentBars) else {
            throw SpikeError("Paced bars must be 1–16 and silent bars 1–32.")
        }
        guard (1...32).contains(config.cycles) else { throw SpikeError("Cycles must be 1–32.") }
        let env = try environment()

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: config.bpm, sampleRate: player.outputSampleRate)
        let groove = GrooveLibrary.basicRock
        let countInBars = 2
        let cycle = config.cycle

        var perBar: [Pattern] = []
        for _ in 0..<countInBars {
            perBar.append(DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0, groove: groove))
        }
        for bar in 0..<config.totalBars {
            perBar.append(DropoutDrill.pattern(bar: bar, cycle: cycle, groove: groove))
        }

        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() { hits += seq.schedule(pattern: pattern, bar: bar) }
        player.schedule(hits)
        let startSample = seq.barStartSample(bar: countInBars, pattern: groove)

        let midi = try MIDIInput.started()
        defer { midi.end() }
        midi.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }

        try player.run(forSeconds: runLength(config.durationSeconds, player),
                       progress: progress, cancellation: cancellation)

        guard let epoch = player.outputMapPairs.first?.hostTime else {
            throw SpikeError("Could not reconstruct the take — no audio timing map captured.")
        }
        var map = SampleHostMap()
        map.build(pairs: player.outputMapPairs, epoch: epoch)
        guard let startSec = map.hostSeconds(atSample: Double(startSample)) else {
            throw SpikeError("Could not locate the start of the drill on the timeline.")
        }

        let constantSec = (env.calibrationMs ?? 0) / 1000
        // Keys only: pads are not part of this drill.
        let taps = midi.events.filter { !$0.isPad }.map {
            Tap(time: HostClock.interval(from: epoch, to: $0.hostTime) - constantSec,
                velocity: Int($0.velocity))
        }
        let grid = Grid(startTime: startSec, bpm: config.bpm, subdivisions: 1)

        // Build the section timeline from the same cycle the audio used, so analysis and
        // playback can never disagree about when the band was absent.
        let barSeconds = grid.beatInterval * 4
        var sections: [DropoutSection] = []
        var bar = 0
        while bar < config.totalBars {
            let paced = DropoutDrill.isPaced(bar: bar, cycle: cycle)
            var end = bar
            while end < config.totalBars, DropoutDrill.isPaced(bar: end, cycle: cycle) == paced { end += 1 }
            sections.append(DropoutSection(startTime: startSec + Double(bar) * barSeconds,
                                           endTime: startSec + Double(end) * barSeconds,
                                           isPaced: paced))
            bar = end
        }

        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)
        return DropoutOutcome(
            report: report, notesPlayed: taps.count, environment: env, config: config,
            suggestedSilentBars: DropoutDrill.suggestedSilentBars(
                current: config.silentBars, driftMsPerBeat: report.tempoBiasMsPerBeat),
            gridStartTime: startSec, tapTimes: taps.map(\.time))
    }

    @discardableResult
    public static func save(_ outcome: DropoutOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil) throws -> URL {
        let r = outcome.report
        let session = DropoutSession(
            date: Date(), bpm: outcome.config.bpm,
            pacedBars: outcome.config.pacedBars, silentBars: outcome.config.silentBars,
            cycles: outcome.config.cycles, feelRating: feelRating,
            gridStartTime: outcome.gridStartTime, tapTimes: outcome.tapTimes,
            pacedSDms: r.pacedSDms, unpacedIntervalSDms: r.unpacedIntervalSDms,
            clockSDms: r.wingKristofferson?.clockSDms,
            motorSDms: r.wingKristofferson?.motorSDms,
            modelHolds: r.wingKristofferson?.modelHolds ?? false,
            reentryErrorMeanMs: r.reentryErrorMeanMs, reentryErrorSDms: r.reentryErrorSDms,
            headline: r.headline,
            tempoBiasBpm: r.tempoBiasBpm, playedBpm: r.playedBpm,
            splitIsReliable: r.splitIsReliable, discardedTrials: r.discardedTrials,
            placement: placement)
        return try SessionStore.save(session)
    }

    // MARK: - Tempo calibration

    public struct TempoConfig {
        /// One entry per round, cycled. More than one rotates the target, which trains the
        /// mapping from "this tempo" to a period rather than memorising a single number.
        public var targets: [Double]
        public var leadBars: Int
        public var holdBars: Int
        public var rounds: Int

        public init(targets: [Double] = [100], leadBars: Int = 4, holdBars: Int = 4, rounds: Int = 8) {
            self.targets = targets.isEmpty ? [100] : targets
            self.leadBars = leadBars; self.holdBars = holdBars; self.rounds = rounds
        }

        public func target(forRound index: Int) -> Double { targets[index % targets.count] }
        public var durationSeconds: Double {
            (0..<rounds).reduce(0) { total, i in
                total + Double(leadBars + holdBars) * 4 * 60 / target(forRound: i)
            } + 0.5      // matches the lead-in the scheduler inserts
        }
    }

    public struct TempoOutcome {
        public let report: TempoCalibrationReport
        public let environment: Environment
        public let config: TempoConfig
        fileprivate let tapTimes: [Double]
        fileprivate let rounds: [TempoRound]
    }

    public static func runTempo(_ config: TempoConfig,
                                progress: ((Double) -> Void)? = nil,
                                cancellation: CancellationFlag? = nil,
                                roundFinished: ((TempoRoundResult) -> Void)? = nil) throws -> TempoOutcome {
        guard config.targets.allSatisfy({ (40...260).contains($0) }) else {
            throw SpikeError("Every target tempo must be 40–260 BPM.")
        }
        guard (1...16).contains(config.leadBars), (1...16).contains(config.holdBars) else {
            throw SpikeError("Lead and hold must each be 1–16 bars.")
        }
        guard (1...32).contains(config.rounds) else { throw SpikeError("Rounds must be 1–32.") }
        let env = try environment()

        let player = try GroovePlayer()
        let fs = player.outputSampleRate
        let groove = GrooveLibrary.basicRock

        // Each round is scheduled at its own tempo, so the sample cursor is advanced round by
        // round rather than derived from one global sequencer.
        var hits: [ScheduledHit] = []
        var cursorSamples: Int64 = Int64(0.5 * fs)
        var roundWindows: [(target: Double, holdStartSample: Int64, holdEndSample: Int64)] = []

        for index in 0..<config.rounds {
            let bpm = config.target(forRound: index)
            let seq = Sequencer(bpm: bpm, sampleRate: fs)
            let barSamples = seq.barStartSample(bar: 1, pattern: groove)

            for bar in 0..<config.leadBars {
                for hit in seq.schedule(pattern: groove, bar: bar) {
                    hits.append(ScheduledHit(voice: hit.voice,
                                             sample: cursorSamples + hit.sample,
                                             velocity: hit.velocity))
                }
            }
            let holdStart = cursorSamples + Int64(config.leadBars) * barSamples
            let holdEnd = holdStart + Int64(config.holdBars) * barSamples
            roundWindows.append((bpm, holdStart, holdEnd))
            cursorSamples = holdEnd
        }

        player.schedule(hits)

        let midi = try MIDIInput.started()
        defer { midi.end() }
        midi.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }

        // Report each round the moment its silence ends, not at the finish. The drill is a
        // feedback loop — produce, be told, correct, produce again — and feedback delivered
        // after every round is over would make it a plain measurement instead.
        //
        // Analysis runs on the taps captured so far. `MIDIInput.events` is written only by
        // CoreMIDI's single delivery thread and read here on the take thread; a read racing a
        // write can miss the very latest note, which at worst defers a round to the next tick.
        var reported = 0
        let totalSamples = Double(cursorSamples)
        let watch: (Double) -> Void = { fraction in
            progress?(fraction)
            guard reported < roundWindows.count else { return }
            let playedSamples = fraction * totalSamples
            let window = roundWindows[reported]
            guard playedSamples >= Double(window.holdEndSample) else { return }

            // Only the epoch is read live — the full sample↔host map belongs to the render
            // thread until it stops. Sample positions convert at the nominal rate, which the
            // M0 calibration measured accurate to 0.2 ppm: far below what a round boundary
            // needs. The final, saved result is recomputed from the real map afterwards.
            guard let epoch = player.startHostTime else { return }
            let start = Double(window.holdStartSample) / fs
            let end = Double(window.holdEndSample) / fs

            let offset = (env.calibrationMs ?? 0) / 1000
            let soFar = midi.events.filter { !$0.isPad }.map {
                Tap(time: HostClock.interval(from: epoch, to: $0.hostTime) - offset)
            }
            let round = TempoRound(index: reported, targetBpm: window.target,
                                   holdStart: start, holdEnd: end)
            let partial = TempoCalibrationAnalysis.analyze(taps: soFar, rounds: [round])
            if let result = partial.rounds.first { roundFinished?(result) }
            reported += 1
        }

        // The final round ends in silence, so the schedule's last sound is well short of the
        // take's real end — `cursorSamples` is the truth.
        try player.run(forSeconds: Double(cursorSamples) / fs + 0.5,
                       progress: watch, cancellation: cancellation)

        guard let epoch = player.outputMapPairs.first?.hostTime else {
            throw SpikeError("Could not reconstruct the take — no audio timing map captured.")
        }
        var map = SampleHostMap()
        map.build(pairs: player.outputMapPairs, epoch: epoch)

        let constantSec = (env.calibrationMs ?? 0) / 1000
        let taps = midi.events.filter { !$0.isPad }.map {
            Tap(time: HostClock.interval(from: epoch, to: $0.hostTime) - constantSec)
        }

        var rounds: [TempoRound] = []
        for (index, window) in roundWindows.enumerated() {
            guard let start = map.hostSeconds(atSample: Double(window.holdStartSample)),
                  let end = map.hostSeconds(atSample: Double(window.holdEndSample)) else { continue }
            rounds.append(TempoRound(index: index, targetBpm: window.target,
                                     holdStart: start, holdEnd: end))
        }

        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds)

        return TempoOutcome(report: report, environment: env, config: config,
                            tapTimes: taps.map(\.time), rounds: rounds)
    }

    @discardableResult
    public static func save(_ outcome: TempoOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil) throws -> URL {
        let r = outcome.report
        let session = TempoSession(
            date: Date(), targets: outcome.config.targets,
            leadBars: outcome.config.leadBars, holdBars: outcome.config.holdBars,
            rounds: outcome.config.rounds, feelRating: feelRating,
            tapTimes: outcome.tapTimes,
            roundTargets: outcome.rounds.map(\.targetBpm),
            roundHoldStarts: outcome.rounds.map(\.holdStart),
            roundHoldEnds: outcome.rounds.map(\.holdEnd),
            usableCount: r.usableCount, meanErrorPercent: r.meanErrorPercent,
            meanAbsErrorPercent: r.meanAbsErrorPercent,
            improvementPerRound: r.improvementPerRound, headline: r.headline,
            placement: placement)
        return try SessionStore.save(session)
    }

    public static func tempoHistory() -> [HistoryEntry] {
        SessionStore.loadAllTempo().map { session in
            // Recomputed from raw taps, like the other drills, so analysis fixes apply back.
            let r = TempoCalibrationAnalysis.analyze(taps: session.taps, rounds: session.roundWindows)
            let targets = session.targets.map { String(Int($0)) }.joined(separator: "/")
            return HistoryEntry(
                date: session.date,
                title: "\(targets) BPM · \(session.rounds)× \(session.holdBars)-bar holds",
                detail: r.meanErrorPercent.map { String(format: "%+.1f%% bias · %d/%d rounds scored",
                                                        $0, r.usableCount, r.rounds.count) }
                        ?? "no rounds scored",
                feelRating: session.feelRating, headline: r.headline,
                metric: r.meanAbsErrorPercent ?? .nan, metricLabel: "tempo error (%)")
        }
    }

    // MARK: - History

    /// A saved take, flattened for display. Keeps the storage types internal.
    public struct HistoryEntry: Identifiable {
        public let id = UUID()
        public let date: Date
        public let title: String
        public let detail: String
        public let feelRating: Int?
        public let headline: String
        /// The number a trend line should follow: asynchrony SD for jams (lower is
        /// tighter), on-form percentage for form drills (higher is better).
        public let metric: Double
        public let metricLabel: String
    }

    public static func jamHistory() -> [HistoryEntry] {
        SessionStore.loadAll().map { s in
            // Recomputed from the raw taps, like the other drills. The cached summary
            // predates chord clustering on the earliest takes, so plotting it would put a
            // point on the chart that no current analysis produces.
            let r = s.report()
            return HistoryEntry(
                date: s.date,
                title: "\(Int(s.bpm)) BPM · \(s.bars) bars" + (s.tag.map { " · \($0)" } ?? ""),
                detail: String(format: "mean %+.1f ms · SD %.1f ms", r.meanAsynchronyMs, r.sdAsynchronyMs),
                feelRating: s.feelRating, headline: r.headline,
                metric: r.sdAsynchronyMs, metricLabel: "spread (ms)")
        }
    }

    public static func dropoutHistory() -> [HistoryEntry] {
        SessionStore.loadAllDropout().map { session in
            // Re-analysed from the raw taps rather than read from the cached summary, so
            // improvements to the analysis reach takes recorded before them.
            let (taps, grid, sections) = session.reconstruct()
            let r = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)

            let split = r.splitIsReliable && r.wingKristofferson != nil
                ? String(format: "clock %.1f / motor %.1f ms",
                         r.wingKristofferson!.clockSDms, r.wingKristofferson!.motorSDms)
                : "split unreliable"
            let tempo = r.playedBpm.map { String(format: " · %.0f BPM alone", $0) } ?? ""
            return HistoryEntry(
                date: session.date,
                title: "\(session.pacedBars)+\(session.silentBars) bars × \(session.cycles) · \(Int(session.bpm)) BPM",
                detail: split + tempo,
                feelRating: session.feelRating, headline: r.headline,
                // Tempo bias is the metric worth trending: it is measured reliably every
                // time, whereas the clock/motor split often is not.
                metric: r.tempoBiasBpm ?? .nan, metricLabel: "tempo bias (BPM)")
        }
    }

    public static func formHistory() -> [HistoryEntry] {
        SessionStore.loadAllForm().map { s in
            let r = s.report()      // re-analysed from the stored marks, not the cache
            return HistoryEntry(
                date: s.date,
                title: "level \(s.level) · \(s.phraseBars)-bar phrases · \(Int(s.bpm)) BPM",
                detail: "\(r.onFormCount)/\(r.marksPlaced) on form · \(r.tightCount) nailed",
                feelRating: s.feelRating, headline: r.headline,
                metric: r.onFormRate * 100, metricLabel: "on form (%)")
        }
    }

    // MARK: - Session planning

    /// Reduce the stored history to the handful of numbers the planner consults.
    ///
    /// Everything is recomputed from raw taps here too — a planner choosing tonight's drills
    /// from a stale cached summary would be picking work for a player who no longer exists.
    public static func plannerInput() -> PlannerInput {
        let jams = SessionStore.loadAll().map { session -> PlannerInput.Jam in
            let r = session.report()
            return PlannerInput.Jam(bpm: session.bpm, sdMs: r.sdAsynchronyMs,
                                    absBiasMs: abs(r.meanAsynchronyMs),
                                    lag1: r.lag1Autocorrelation)
        }

        let continuations = SessionStore.loadAllDropout().map { session -> PlannerInput.Continuation in
            let (taps, grid, sections) = session.reconstruct()
            let r = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)
            return PlannerInput.Continuation(
                silentBars: session.silentBars,
                absTempoBiasPercent: r.tempoBiasBpm.map { abs($0) / session.bpm * 100 },
                splitIsReliable: r.splitIsReliable,
                clockSDms: r.splitIsReliable ? r.wingKristofferson?.clockSDms : nil,
                motorSDms: r.splitIsReliable ? r.wingKristofferson?.motorSDms : nil)
        }

        let forms = SessionStore.loadAllForm().map { session -> PlannerInput.Form in
            let r = session.report()
            return PlannerInput.Form(level: session.level, phraseBars: session.phraseBars,
                                     onFormRate: r.onFormRate,
                                     hasUnmarkedPhrases: !r.missedPhrases.isEmpty,
                                     markedEveryBars: r.markedEveryBars)
        }

        let tempos = SessionStore.loadAllTempo().map { session -> PlannerInput.Tempo in
            let r = TempoCalibrationAnalysis.analyze(taps: session.taps, rounds: session.roundWindows)
            return PlannerInput.Tempo(targetCount: Set(session.targets).count,
                                      meanAbsErrorPercent: r.meanAbsErrorPercent)
        }

        return PlannerInput(jams: jams, continuations: continuations, forms: forms, tempos: tempos)
    }

    public static func planSession(targetMinutes: Int) -> SessionPlan {
        SessionPlanner.plan(targetMinutes: targetMinutes, from: plannerInput())
    }

    // MARK: - Trends

    public enum DrillKind: String, CaseIterable {
        case jam, form, dropout, tempo
    }

    /// Every trend the stored takes can support, with the confounds that make one unsafe.
    ///
    /// Built here rather than in either front end so the console and the app cannot report a
    /// different answer — and so the app stops plotting one unbroken line through a group the
    /// console warns about.
    public static func trends() -> [TrendSeries] {
        // Ordered as the console has always printed them.
        [DrillKind.jam, .dropout, .form, .tempo].flatMap { trends(for: $0) }
    }

    public static func trends(for kind: DrillKind) -> [TrendSeries] {
        switch kind {
        case .jam:     return jamTrends()
        case .dropout: return dropoutTrends()
        case .form:    return formTrends()
        case .tempo:   return tempoTrends()
        }
    }

    private static func jamTrends() -> [TrendSeries] {
        var series: [TrendSeries] = []

        // Jams are grouped by tempo: asynchrony spread scales with the beat interval, so a
        // trend across a tempo change would be measuring the tempo.
        let jams = SessionStore.loadAll()
        for tempo in Set(jams.map { Int($0.bpm) }).sorted() {
            let takes = jams.filter { Int($0.bpm) == tempo }
            let reports = takes.map { $0.report() }
            var warnings: [String] = []
            let backings = TrendAnalysis.distinct(takes.map(\.grooveName))
            if backings.count > 1 {
                warnings.append("mixed backings (\(backings.joined(separator: ", "))) — "
                              + "spread is not comparable across different music.")
            }
            let devices = TrendAnalysis.distinct(takes.map(\.device))
            if devices.count > 1 {
                warnings.append("mixed output devices — bias is not comparable; spread and r₁ are.")
            }
            series.append(TrendSeries(
                title: "Jams at \(tempo) BPM", takeCount: takes.count, warnings: warnings,
                rows: [
                    TrendAnalysis.row("spread (SD)", reports.map(\.sdAsynchronyMs), lowerIsBetter: true),
                    TrendAnalysis.row("|bias|", reports.map { abs($0.meanAsynchronyMs) }, lowerIsBetter: true),
                    TrendAnalysis.row("r₁ toward 0", reports.map { $0.lag1Autocorrelation.map(abs) ?? .nan },
                                      lowerIsBetter: true),
                ]))
        }
        return series
    }

    private static func dropoutTrends() -> [TrendSeries] {
        var series: [TrendSeries] = []
        let drops = SessionStore.loadAllDropout()
        if !drops.isEmpty {
            let reports = drops.map { session -> DropoutReport in
                let (taps, grid, sections) = session.reconstruct()
                return DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)
            }
            var warnings: [String] = []
            let silences = TrendAnalysis.distinct(drops.map(\.silentBars))
            if silences.count > 1 {
                warnings.append("mixed silence lengths (\(silences.map(String.init).joined(separator: ", ")) bars) — "
                              + "a longer silence is a harder task.")
            }
            series.append(TrendSeries(
                title: "Continuation drill", takeCount: drops.count, warnings: warnings,
                rows: [
                    TrendAnalysis.row("|tempo bias|", reports.map { $0.tempoBiasBpm.map(abs) ?? .nan },
                                      lowerIsBetter: true),
                    TrendAnalysis.row("clock SD",
                                      reports.map { $0.splitIsReliable ? ($0.wingKristofferson?.clockSDms ?? .nan) : .nan },
                                      lowerIsBetter: true),
                ]))
        }
        return series
    }

    private static func formTrends() -> [TrendSeries] {
        var series: [TrendSeries] = []
        let forms = SessionStore.loadAllForm()
        if !forms.isEmpty {
            let reports = forms.map { $0.report() }
            var warnings: [String] = []
            let levels = TrendAnalysis.distinct(forms.map(\.level))
            if levels.count > 1 {
                warnings.append("mixed levels — difficulty changed between takes, so a trend here "
                              + "reflects the ladder as much as you.")
            }
            let phrases = TrendAnalysis.distinct(forms.map(\.phraseBars))
            if phrases.count > 1 {
                warnings.append("mixed phrase lengths (\(phrases.map(String.init).joined(separator: ", ")) bars).")
            }
            series.append(TrendSeries(
                title: "Form drill", takeCount: forms.count, warnings: warnings,
                rows: [TrendAnalysis.row("on-form rate", reports.map(\.onFormRate), lowerIsBetter: false)]))
        }
        return series
    }

    private static func tempoTrends() -> [TrendSeries] {
        var series: [TrendSeries] = []
        let tempos = SessionStore.loadAllTempo()
        if !tempos.isEmpty {
            let reports = tempos.map {
                TempoCalibrationAnalysis.analyze(taps: $0.taps, rounds: $0.roundWindows)
            }
            var warnings: [String] = []
            let targetSets = TrendAnalysis.distinct(tempos.map {
                $0.targets.map { String(Int($0)) }.joined(separator: "/")
            })
            if targetSets.count > 1 {
                warnings.append("mixed target sets (\(targetSets.joined(separator: "; "))) — "
                              + "rotating targets is a harder task than holding one.")
            }
            series.append(TrendSeries(
                title: "Tempo drill", takeCount: tempos.count, warnings: warnings,
                rows: [TrendAnalysis.row("tempo error (%)",
                                         reports.map { $0.meanAbsErrorPercent ?? .nan },
                                         lowerIsBetter: true)]))
        }

        return series
    }

    // MARK: - Free groove

    public struct GrooveConfig {
        public var bpm: Double
        public var bars: Int
        public init(bpm: Double = 100, bars: Int = 32) { self.bpm = bpm; self.bars = bars }
        public var durationSeconds: Double { Double(bars + 1) * 4 * 60 / bpm }
    }

    /// Play the backing with live monitoring and no measurement — just somewhere to noodle.
    public static func playGroove(_ config: GrooveConfig,
                                  progress: ((Double) -> Void)? = nil,
                                  cancellation: CancellationFlag? = nil) throws {
        guard (40...260).contains(config.bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
        let player = try GroovePlayer()
        let seq = Sequencer(bpm: config.bpm, sampleRate: player.outputSampleRate)
        let backing = GrooveLibrary.jamBacking

        var perBar: [Pattern] = [DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0,
                                                       groove: GrooveLibrary.basicRock)]
        for bar in 0..<config.bars { perBar.append(backing.pattern(atBar: bar)) }
        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() { hits += seq.schedule(pattern: pattern, bar: bar) }
        player.schedule(hits)

        let midi = try? MIDIInput.started()
        defer { midi?.end() }
        midi?.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }
        try player.run(forSeconds: runLength(config.durationSeconds, player),
                       progress: progress, cancellation: cancellation)
    }
}
