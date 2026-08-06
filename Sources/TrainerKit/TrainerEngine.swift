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
        /// The subdivision the player is asked to produce, or `nil` for free playing.
        ///
        /// See `JamPlan.rung`: `nil` is "no rung was prescribed", not "quarters".
        public var rung: IntervalRung?
        /// Where the subdivision is expected to sit. Straight unless asked otherwise, and
        /// straight is the identity — see `Feel`.
        public var feel: Feel = .straight
        /// The offbeat drill's level, when this take is one.
        ///
        /// A jam variant rather than a separate drill type, for the same reason the experiment
        /// arms are: it is the same capture, the same grid and the same storage, and only what
        /// the player is asked to do and what the band states underneath differ. A fifth stored
        /// type carrying the same fields would be a schema to keep in step for no gain.
        public var offbeatLevel: OffbeatLevel?

        public init(bpm: Double = 100, bars: Int = 32, tag: String? = nil,
                    rung: IntervalRung? = nil, feel: Feel = .straight,
                    offbeatLevel: OffbeatLevel? = nil) {
            self.bpm = bpm; self.bars = bars; self.tag = tag
            self.rung = rung; self.feel = feel; self.offbeatLevel = offbeatLevel
        }
        public var durationSeconds: Double { Double(bars + 2) * 4 * 60 / bpm }

        /// The backing this take plays over, and the name it is stored under.
        ///
        /// A free jam keeps `jamBacking` exactly as every recorded take had it. A rung gets the
        /// ladder groove that makes its division audible — asked for sixteenths over a backing
        /// that only marks beats, the player is really being asked to subdivide from memory.
        var backing: (name: String, arrangement: Arrangement) {
            if let level = offbeatLevel {
                return ("offbeat-\(level.rawValue)",
                        OffbeatBacking.backing(level: level, bars: max(1, bars)))
            }
            guard let rung else { return ("jamBacking", GrooveLibrary.jamBacking) }
            // A feel gets its own groove, not the straight one with warped timing. Warping alone
            // leaves every loud event on an even grid and the feel inaudible — see
            // `LadderBackings.swungPattern`.
            guard feel.isStraight || !feel.applies(toSubdivisions: rung.subdivisions) else {
                return ("ladder-\(rung.rawValue)-swung",
                        LadderBackings.swungBacking(notesPerBeat: rung.subdivisions))
            }
            return ("ladder-\(rung.rawValue)",
                    LadderBackings.backing(notesPerBeat: rung.subdivisions))
        }

        /// Grid points per beat for the **analysis**.
        ///
        /// The rung when there is one, and only otherwise the backing's step resolution. Those
        /// are different quantities and this is the third place in M14 where confusing them was
        /// the available mistake — `LadderBackings` returns a pattern whose `stepsPerBeat` is 4
        /// for quarters, eighths *and* sixteenths, because all three are programmed on a
        /// sixteenth step grid and differ only in which steps fire. Scoring a quarters rung on
        /// that resolution would measure a task nobody was set, and it is what step 1's tempo
        /// ceilings are derived against: the window is `0.4 × 60 / (bpm × subdivisions)`, so the
        /// subdivision here *is* the thing the ceiling constrains.
        /// The offbeat drill is scored on eighths whatever else is set: the offbeat *is* the
        /// half-beat, and a finer grid would let a stray sixteenth count as neither the beat nor
        /// the offbeat and quietly shrink both counts.
        var gridSubdivisions: Int {
            if offbeatLevel != nil { return 2 }
            return rung?.subdivisions ?? backing.arrangement.stepsPerBeat
        }

        /// The feel, restated for the band.
        ///
        /// **This is the one place a `Feel` becomes a `Swing`**, and it has to be: `GrooveCore`
        /// cannot see `TimingCore` (R1.1.3), so the type the analysis scores against and the
        /// type the band plays are different types describing one thing. A second conversion
        /// somewhere else would be two constants to keep in sync, and a groove swinging at one
        /// ratio while the grid scores at another teaches one thing and measures another — with
        /// nothing on screen to show it. `SwingAgreementTests` pins the two to the sample.
        ///
        /// Keyed on `gridSubdivisions` rather than the pattern's step resolution, because the
        /// rung is what is being divided.
        var swing: Swing {
            Swing(ratio: feel.swingRatio, notesPerBeat: gridSubdivisions)
        }

        /// The bar the count-in plays, twice, before the backing starts.
        ///
        /// A property rather than a literal inside `runJam` for the same reason `backing` and
        /// `gridSubdivisions` are: `runJam` needs an audio device, so anything decided inline
        /// there can only be verified by playing it. Reverting this to the fixed hats-on-the-beat
        /// count-in compiled cleanly and broke no test until it moved out here.
        ///
        /// A free jam keeps exactly the count-in every recorded take has had. A rung counts in
        /// on its own division, because the count-in is where the drill tells a player with
        /// their eyes shut what it is asking for — see `LadderBackings.countIn`.
        var countInBar: Pattern {
            guard let rung else {
                return DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0,
                                             groove: GrooveLibrary.basicRock)
            }
            return LadderBackings.countIn(notesPerBeat: rung.subdivisions)
        }

        /// R7.6: the boundary validates before anything is scheduled.
        ///
        /// Lives on the config rather than inside `runJam` so it can be tested without opening
        /// an audio device. A test that reaches the engine to check a range check is one
        /// regression away from playing a full take through the speakers.
        public func validate() throws {
            guard (40...260).contains(bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
            guard (4...512).contains(bars) else { throw SpikeError("Bars must be 4–512.") }
            guard offbeatLevel == nil || feel.isStraight else {
                throw SpikeError("The offbeat drill is straight: an offbeat is at half the beat, "
                               + "and swinging it would move the very point being held.")
            }
        }
    }

    public struct JamOutcome {
        public let report: TimingReport
        public let notesCaptured: Int
        public let eventCount: Int
        public let environment: Environment
        public let config: JamConfig
        fileprivate let gridStartTime: Double
        /// The grid the take was *analysed* on.
        ///
        /// Carried on the outcome rather than re-derived at save time. The stored value used to
        /// be a hardcoded 4 while the analysis used the backing's step count, which agreed only
        /// because the default is 4 — and everything recomputes from stored data (R3.1), so the
        /// moment a backing differed every number would have moved between the live report and
        /// the review.
        fileprivate let gridSubdivisions: Int
        /// The grid this take was scored on, for readouts that need more than the summary —
        /// the swing analysis asks which grid points were off the division.
        public var analysisGrid: Grid {
            Grid(startTime: gridStartTime, bpm: config.bpm, subdivisions: gridSubdivisions,
                 feel: config.feel)
        }
        fileprivate let taps: [Tap]
        /// Every note-on in the window, before chord clustering — pitch, velocity and time.
        /// Clustering collapses a chord to one rhythmic event, which is right for timing and
        /// wrong for asking what was played.
        fileprivate let rawTaps: [Tap]
    }

    public static func runJam(_ config: JamConfig,
                              progress: ((Double) -> Void)? = nil,
                              cancellation: CancellationFlag? = nil) throws -> JamOutcome {
        try config.validate()
        let env = try environment()

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: config.bpm, sampleRate: player.outputSampleRate,
                            swing: config.swing)
        let backing = config.backing.arrangement
        let countInBars = 2

        var perBar = [Pattern](repeating: config.countInBar, count: countInBars)
        for bar in 0..<config.bars { perBar.append(backing.pattern(atBar: bar)) }

        // The count-in is on the 16-step grid and a triplet backing is on a 12-step one, which
        // is safe only because every pattern here is four beats to the bar: bar 2 is eight beats
        // in whichever resolution asks. `GroovePlayer.schedule` sorts, so the two interleave.
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
            midi: midi.events.map { ($0.hostTime, Int($0.velocity), Int($0.note)) },
            grooveStartSample: startSample, grooveEndSample: endSample,
            bpm: config.bpm, subdivisions: config.gridSubdivisions, feel: config.feel,
            calibrationConstantMs: env.calibrationMs ?? 0)
        else { throw SpikeError("Could not reconstruct the take — no audio timing map captured.") }

        let events = TapClustering.collapse(reduced.taps, windowSeconds: 0.035)
        let report = TimingAnalysis.analyze(taps: events, grid: reduced.grid, chordWindowMs: 0)

        return JamOutcome(report: report, notesCaptured: midi.events.count,
                          eventCount: events.count, environment: env, config: config,
                          gridStartTime: reduced.grid.startTime,
                          gridSubdivisions: reduced.grid.subdivisions, taps: events,
                          rawTaps: reduced.taps)
    }

    @discardableResult
    public static func save(_ outcome: JamOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil,
                            experiment: ExperimentAssignment? = nil) throws -> URL {
        let r = outcome.report
        let session = JamSession(
            date: Date(), bpm: outcome.config.bpm, device: outcome.environment.outputIdentity,
            calibrationConstantMs: outcome.environment.calibrationMs,
            calibrationSource: outcome.environment.calibrationSource,
            // The backing that actually played, not a literal. Every confound check keyed on
            // this — `comparabilityNotes`, the trend warnings — went blind the moment a jam
            // could play over something other than `jamBacking` (R3.4).
            grooveName: outcome.config.backing.name, bars: outcome.config.bars,
            subdivisions: outcome.gridSubdivisions,
            rung: outcome.config.rung?.rawValue,
            swingRatio: outcome.config.feel.isStraight ? nil : outcome.config.feel.swingRatio,
            offbeatLevel: outcome.config.offbeatLevel?.rawValue,
            tag: outcome.config.tag?.lowercased(), feelRating: feelRating,
            gridStartTime: outcome.gridStartTime,
            tapTimes: outcome.taps.map(\.time), tapVelocities: outcome.taps.map(\.velocity),
            matchedCount: r.matchedCount, extraCount: r.extraCount, missedCount: r.missedCount,
            meanAsynchronyMs: Stats.finite(r.meanAsynchronyMs),
            sdAsynchronyMs: Stats.finite(r.sdAsynchronyMs),
            lag1Autocorrelation: Stats.finite(r.lag1Autocorrelation),
            driftMsPerBeat: Stats.finite(r.driftMsPerBeat),
            headline: r.headline, placement: placement, experiment: experiment,
            rawTimes: outcome.rawTaps.map(\.time),
            rawNotes: outcome.rawTaps.map(\.note),
            rawVelocities: outcome.rawTaps.map(\.velocity))
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

        /// R7.6 — see `JamConfig.validate`.
        public func validate() throws {
            guard (40...260).contains(bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
            guard (2...32).contains(phraseBars) else {
                throw SpikeError("Phrase length must be 2–32 bars.")
            }
            guard bars >= phraseBars, bars <= 512 else {
                throw SpikeError("Bars must be between the phrase length and 512.")
            }
        }
    }

    public struct FormOutcome {
        public let report: FormReport
        public let notesPlayed: Int
        public let environment: Environment
        public let config: FormConfig
        fileprivate let gridStartTime: Double
        /// The grid the marks were scored against — see `JamOutcome.gridSubdivisions`.
        fileprivate let gridSubdivisions: Int
        fileprivate let markTimes: [Double]
    }

    public static func runForm(_ config: FormConfig,
                               progress: ((Double) -> Void)? = nil,
                               cancellation: CancellationFlag? = nil) throws -> FormOutcome {
        try config.validate()
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
                           gridStartTime: startSec,
                           gridSubdivisions: grid.subdivisions, markTimes: markTimes)
    }

    @discardableResult
    public static func save(_ outcome: FormOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil,
                            experiment: ExperimentAssignment? = nil) throws -> URL {
        let r = outcome.report
        let session = FormSession(
            date: Date(), bpm: outcome.config.bpm, bars: outcome.config.bars,
            phraseBars: outcome.config.phraseBars, level: outcome.config.level.rawValue,
            feelRating: feelRating, gridStartTime: outcome.gridStartTime,
            subdivisions: outcome.gridSubdivisions,
            markTimes: outcome.markTimes,
            phrasesAvailable: r.phrasesAvailable, marksPlaced: r.marksPlaced,
            onFormCount: r.onFormCount, tightCount: r.tightCount,
            meanAbsFormErrorBars: Stats.finite(r.meanAbsFormErrorBars),
            phaseErrorMeanMs: Stats.finite(r.phaseErrorMeanMs),
            phaseErrorSDms: Stats.finite(r.phaseErrorSDms),
            slipBarsPerPhrase: Stats.finite(r.slipBarsPerPhrase), missedPhrases: r.missedPhrases,
            headline: r.headline, placement: placement, experiment: experiment)
        return try SessionStore.save(session)
    }

    // MARK: - Dropout (continuation) drill

    public struct DropoutConfig {
        public var bpm: Double
        public var pacedBars: Int
        public var silentBars: Int
        public var cycles: Int
        /// The note value asked for through the silences.
        ///
        /// This drill has always demanded one note per beat in words — "Play exactly ONE NOTE
        /// PER BEAT" — while the analysis *inferred* the note value from what was played and
        /// snapped it to the nearest whole number. Setting it makes the analysis know what the
        /// instructions already said, which is what removes the snapping (§7.23 step 4e).
        public var rung: IntervalRung?
        /// Where the subdivision is expected to sit — **straight only**, and `validate()`
        /// enforces it.
        ///
        /// Swing and Wing–Kristofferson are incompatible, not merely awkward together. The
        /// decomposition assumes an isochronous series and swing makes the intervals alternate
        /// by design: at 2:1 they run 400/200 at 100 BPM, which the isochrony gate *passes*
        /// because both sit inside 0.6–1.6× of their own median. The alternation then lands
        /// entirely in the lag-1 autocovariance, which is what motor variance is derived from.
        ///
        /// Measured on a planted 12 ms clock and 8 ms motor: straight eighths recover 9.0 and
        /// 7.7; swung eighths report **motor 99.7 ms and a negative clock variance**. A
        /// confident number, twelve times wrong, from a drill that looked like it ran fine.
        ///
        /// Making this work needs the decomposition to operate on pairs rather than on
        /// intervals, which is a different piece of analysis and not one M15 needs.
        public var feel: Feel = .straight

        public init(bpm: Double = 100, pacedBars: Int = 4, silentBars: Int = 4, cycles: Int = 6,
                    rung: IntervalRung? = nil, feel: Feel = .straight) {
            self.bpm = bpm; self.pacedBars = pacedBars; self.silentBars = silentBars
            self.cycles = cycles; self.rung = rung; self.feel = feel
        }
        public var cycle: DropoutDrill.Cycle {
            DropoutDrill.Cycle(pacedBars: pacedBars, silentBars: silentBars)
        }
        /// One extra paced stretch on the end so the final silence has a re-entry to measure.
        public var totalBars: Int { cycles * cycle.totalBars + pacedBars }
        public var durationSeconds: Double { Double(totalBars + 2) * 4 * 60 / bpm }

        /// R7.6 — see `JamConfig.validate`.
        public func validate() throws {
            guard (40...260).contains(bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
            guard (1...16).contains(pacedBars), (1...32).contains(silentBars) else {
                throw SpikeError("Paced bars must be 1–16 and silent bars 1–32.")
            }
            guard (1...32).contains(cycles) else { throw SpikeError("Cycles must be 1–32.") }
            guard feel.isStraight else {
                throw SpikeError("The continuation drill cannot be swung: Wing–Kristofferson "
                               + "needs an isochronous series, and a swung one alternates by "
                               + "design. See DropoutConfig.feel.")
            }
        }
    }

    public struct DropoutOutcome {
        public let report: DropoutReport
        public let notesPlayed: Int
        public let environment: Environment
        public let config: DropoutConfig
        /// What to try next, from the measured drift.
        public let suggestedSilentBars: Int
        fileprivate let gridStartTime: Double
        /// The grid the silences were scored against — see `JamOutcome.gridSubdivisions`.
        fileprivate let gridSubdivisions: Int
        /// The grid this take was scored on, for readouts that need more than the summary —
        /// the swing analysis asks which grid points were off the division.
        public var analysisGrid: Grid {
            Grid(startTime: gridStartTime, bpm: config.bpm, subdivisions: gridSubdivisions,
                 feel: config.feel)
        }
        fileprivate let tapTimes: [Double]
    }

    public static func runDropout(_ config: DropoutConfig,
                                  progress: ((Double) -> Void)? = nil,
                                  cancellation: CancellationFlag? = nil) throws -> DropoutOutcome {
        try config.validate()
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
        let grid = Grid(startTime: startSec, bpm: config.bpm,
                        subdivisions: config.rung?.subdivisions ?? 1)

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

        let report = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections,
                                             notesPerBeat: config.rung?.subdivisions)
        return DropoutOutcome(
            report: report, notesPlayed: taps.count, environment: env, config: config,
            suggestedSilentBars: DropoutDrill.suggestedSilentBars(
                current: config.silentBars, driftMsPerBeat: report.tempoBiasMsPerBeat),
            gridStartTime: startSec, gridSubdivisions: grid.subdivisions,
            tapTimes: taps.map(\.time))
    }

    @discardableResult
    public static func save(_ outcome: DropoutOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil,
                            experiment: ExperimentAssignment? = nil) throws -> URL {
        let r = outcome.report
        let session = DropoutSession(
            date: Date(), bpm: outcome.config.bpm,
            pacedBars: outcome.config.pacedBars, silentBars: outcome.config.silentBars,
            cycles: outcome.config.cycles, feelRating: feelRating,
            gridStartTime: outcome.gridStartTime, subdivisions: outcome.gridSubdivisions,
            tapTimes: outcome.tapTimes,
            pacedSDms: Stats.finite(r.pacedSDms), unpacedIntervalSDms: Stats.finite(r.unpacedIntervalSDms),
            clockSDms: Stats.finite(r.wingKristofferson?.clockSDms),
            motorSDms: Stats.finite(r.wingKristofferson?.motorSDms),
            modelHolds: r.wingKristofferson?.modelHolds ?? false,
            reentryErrorMeanMs: Stats.finite(r.reentryErrorMeanMs), reentryErrorSDms: Stats.finite(r.reentryErrorSDms),
            headline: r.headline,
            tempoBiasBpm: Stats.finite(r.tempoBiasBpm), playedBpm: Stats.finite(r.playedBpm),
            splitIsReliable: r.splitIsReliable, discardedTrials: r.discardedTrials,
            placement: placement, experiment: experiment,
            rung: outcome.config.rung?.rawValue,
            swingRatio: outcome.config.feel.isStraight ? nil : outcome.config.feel.swingRatio)
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
        /// The note value asked for during each hold. See `DropoutConfig.rung`: the drill has
        /// always demanded one note per beat in words while the analysis inferred it.
        public var rung: IntervalRung?

        public init(targets: [Double] = [100], leadBars: Int = 4, holdBars: Int = 4,
                    rounds: Int = 8, rung: IntervalRung? = nil) {
            self.targets = targets.isEmpty ? [100] : targets
            self.leadBars = leadBars; self.holdBars = holdBars; self.rounds = rounds
            self.rung = rung
        }

        public func target(forRound index: Int) -> Double { targets[index % targets.count] }
        public var durationSeconds: Double {
            (0..<rounds).reduce(0) { total, i in
                total + Double(leadBars + holdBars) * 4 * 60 / target(forRound: i)
            } + 0.5      // matches the lead-in the scheduler inserts
        }

        /// R7.6 — see `JamConfig.validate`.
        ///
        /// The empty case cannot arrive through `init`, which substitutes a default, but
        /// `targets` is a `var` and `target(forRound:)` traps on `% 0`. A guard that reads as
        /// a range check on every element accepts a list with no elements at all.
        public func validate() throws {
            guard !targets.isEmpty else {
                throw SpikeError("The tempo drill needs at least one target tempo.")
            }
            guard targets.allSatisfy({ (40...260).contains($0) }) else {
                throw SpikeError("Every target tempo must be 40–260 BPM.")
            }
            guard (1...16).contains(leadBars), (1...16).contains(holdBars) else {
                throw SpikeError("Lead and hold must each be 1–16 bars.")
            }
            guard (1...32).contains(rounds) else { throw SpikeError("Rounds must be 1–32.") }
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
        try config.validate()
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
            let partial = TempoCalibrationAnalysis.analyze(taps: soFar, rounds: [round],
                                                          notesPerBeat: config.rung?.subdivisions)
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

        let report = TempoCalibrationAnalysis.analyze(taps: taps, rounds: rounds,
                                                     notesPerBeat: config.rung?.subdivisions)

        return TempoOutcome(report: report, environment: env, config: config,
                            tapTimes: taps.map(\.time), rounds: rounds)
    }

    @discardableResult
    public static func save(_ outcome: TempoOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil,
                            experiment: ExperimentAssignment? = nil) throws -> URL {
        let r = outcome.report
        let session = TempoSession(
            date: Date(), targets: outcome.config.targets,
            leadBars: outcome.config.leadBars, holdBars: outcome.config.holdBars,
            rounds: outcome.config.rounds, feelRating: feelRating,
            tapTimes: outcome.tapTimes,
            roundTargets: outcome.rounds.map(\.targetBpm),
            roundHoldStarts: outcome.rounds.map(\.holdStart),
            roundHoldEnds: outcome.rounds.map(\.holdEnd),
            usableCount: r.usableCount, meanErrorPercent: Stats.finite(r.meanErrorPercent),
            meanAbsErrorPercent: Stats.finite(r.meanAbsErrorPercent),
            improvementPerRound: Stats.finite(r.improvementPerRound), headline: r.headline,
            placement: placement, experiment: experiment,
            rung: outcome.config.rung?.rawValue)
        return try SessionStore.save(session)
    }

    public static func tempoHistory() -> [HistoryEntry] {
        SessionStore.loadAllTempo().map { session in
            // Recomputed from raw taps, like the other drills, so analysis fixes apply back.
            let r = session.report()
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
                // The rung belongs in the title, not the detail: two takes at the same tempo
                // and length are different tasks if one was asked for a subdivision, and the
                // list is where they sit next to each other.
                title: "\(Int(s.bpm)) BPM · \(s.bars) bars"
                     + (s.rung.flatMap { IntervalRung(rawValue: $0)?.label }
                            .map { " · \($0)" } ?? "")
                     + (s.tag.map { " · \($0)" } ?? ""),
                detail: String(format: "mean %+.1f ms · SD %.1f ms", r.meanAsynchronyMs, r.sdAsynchronyMs),
                feelRating: s.feelRating, headline: r.headline,
                metric: r.sdAsynchronyMs, metricLabel: "spread (ms)")
        }
    }

    public static func dropoutHistory() -> [HistoryEntry] {
        SessionStore.loadAllDropout().map { session in
            // Re-analysed from the raw taps rather than read from the cached summary, so
            // improvements to the analysis reach takes recorded before them.
            let r = session.report()

            var split = "split unreliable"
            if r.splitIsReliable, let wk = r.wingKristofferson {
                split = String(format: "clock %.1f / motor %.1f ms", wk.clockSDms, wk.motorSDms)
            }
            let tempo = r.playedBpm.map { String(format: " · %.0f BPM alone", $0) } ?? ""
            return HistoryEntry(
                date: session.date,
                title: "\(session.pacedBars)+\(session.silentBars) bars × "
                     + "\(session.cycles) · \(Int(session.bpm)) BPM"
                     + (session.rung.flatMap { IntervalRung(rawValue: $0)?.label }
                            .map { " · \($0)" } ?? ""),
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

    // MARK: - M11 tempo memory

    public struct MemoryConfig {
        public var bpm: Double
        public var referenceBars: Int
        public var retentionBars: Int
        public var reproduceBars: Int
        public var rounds: Int

        public init(bpm: Double = 100, referenceBars: Int = 4, retentionBars: Int = 4,
                    reproduceBars: Int = 4, rounds: Int = 8) {
            self.bpm = bpm; self.referenceBars = referenceBars
            self.retentionBars = retentionBars; self.reproduceBars = reproduceBars
            self.rounds = rounds
        }

        public var roundBars: Int { referenceBars + retentionBars + reproduceBars }
        public var durationSeconds: Double { Double(rounds * roundBars) * 4 * 60 / bpm + 0.5 }

        /// R7.6 — see `JamConfig.validate`.
        public func validate() throws {
            guard (40...260).contains(bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
            guard (1...16).contains(referenceBars), (1...32).contains(retentionBars),
                  (1...16).contains(reproduceBars) else {
                throw SpikeError("Reference and reproduce must be 1–16 bars, the wait 1–32.")
            }
            guard (2...32).contains(rounds) else {
                throw SpikeError("Rounds must be 2–32 — the drill needs both conditions.")
            }
        }
    }

    public struct MemoryOutcome {
        public let report: TempoMemoryReport
        public let environment: Environment
        public let config: MemoryConfig
        /// What to try next, from the measured clock stability.
        public let suggestedRetentionBars: Int
        fileprivate let tapTimes: [Double]
        fileprivate let rounds: [MemoryRound]
    }

    /// Hear a tempo, wait through the gap, reproduce it.
    ///
    /// The gap is silent on even rounds and filled with an aperiodic distractor on odd ones,
    /// which is the whole experiment — see `TempoMemoryAnalysis`. Two scheduling details are
    /// load-bearing:
    ///
    /// 1. **The distractor is placed off-grid**, at sample positions with no relation to the
    ///    beat. Built from `Pattern` it would land on sixteenths of the very tempo being
    ///    remembered and rehearse it instead of interfering with it.
    /// 2. **Exactly one sound in the reproduction window** — a single kick marking "go". One
    ///    onset carries no period; two would hand the tempo straight back.
    public static func runMemory(_ config: MemoryConfig,
                                 progress: ((Double) -> Void)? = nil,
                                 cancellation: CancellationFlag? = nil) throws -> MemoryOutcome {
        try config.validate()
        let env = try environment()

        let player = try GroovePlayer()
        let fs = player.outputSampleRate
        let groove = GrooveLibrary.basicRock
        let seq = Sequencer(bpm: config.bpm, sampleRate: fs)
        let barSamples = seq.barStartSample(bar: 1, pattern: groove)
        let beatSeconds = 60.0 / config.bpm

        var hits: [ScheduledHit] = []
        var cursor = Int64(0.5 * fs)
        var windows: [(condition: RetentionCondition,
                       retention: (Int64, Int64), reproduce: (Int64, Int64))] = []

        for index in 0..<config.rounds {
            let filled = TempoMemoryDrill.isFilled(round: index)

            // Reference: the player plays along and entrains. The last bar carries a fill
            // that warns the silence is coming — see `TempoMemoryDrill.isWarningBar`.
            for bar in 0..<config.referenceBars {
                let pattern = TempoMemoryDrill.referencePattern(
                    bar: bar, referenceBars: config.referenceBars, groove: groove)
                for hit in seq.schedule(pattern: pattern, bar: bar) {
                    hits.append(ScheduledHit(voice: hit.voice, sample: cursor + hit.sample,
                                             velocity: hit.velocity))
                }
            }

            let retentionStart = cursor + Int64(config.referenceBars) * barSamples
            let retentionEnd = retentionStart + Int64(config.retentionBars) * barSamples
            if filled {
                hits += Distractor.hits(from: retentionStart, to: retentionEnd,
                                        sampleRate: fs, beatSeconds: beatSeconds,
                                        gridOriginSample: cursor,
                                        seed: 0x0D15 &+ UInt64(index))
            }

            // One *instant*, and only one: the cue to start producing.
            //
            // A single kick turned out to be findable but easy to miss if you were not
            // already listening for it — the first live run said so. Crash and kick together
            // at full velocity is unmistakable, and it is still a single point in time, which
            // is the property that matters: one onset carries no period. Two onsets, however
            // quiet, would hand the tempo straight back.
            let reproduceStart = retentionEnd
            let reproduceEnd = reproduceStart + Int64(config.reproduceBars) * barSamples
            hits.append(ScheduledHit(voice: .kick, sample: reproduceStart, velocity: 127))
            hits.append(ScheduledHit(voice: .crash, sample: reproduceStart, velocity: 120))

            windows.append((filled ? .filled : .silent,
                            (retentionStart, retentionEnd), (reproduceStart, reproduceEnd)))
            cursor = reproduceEnd
        }

        player.schedule(hits)

        let midi = try MIDIInput.started()
        defer { midi.end() }
        midi.onNoteEvent = { note, velocity, on, channel in
            player.noteEvent(note: note, velocity: velocity, on: on, channel: channel)
        }

        // The last round ends in silence, so the schedule's final sound is well short of the
        // take's real end — the cursor is the truth. Same lesson as the tempo drill (§7.12).
        try player.run(forSeconds: Double(cursor) / fs + 0.5,
                       progress: progress, cancellation: cancellation)

        guard let epoch = player.outputMapPairs.first?.hostTime else {
            throw SpikeError("Could not reconstruct the take — no audio timing map captured.")
        }
        var map = SampleHostMap()
        map.build(pairs: player.outputMapPairs, epoch: epoch)

        let constantSec = (env.calibrationMs ?? 0) / 1000
        let taps = midi.events.filter { !$0.isPad }.map {
            Tap(time: HostClock.interval(from: epoch, to: $0.hostTime) - constantSec)
        }

        var rounds: [MemoryRound] = []
        for (index, window) in windows.enumerated() {
            guard let rStart = map.hostSeconds(atSample: Double(window.retention.0)),
                  let rEnd = map.hostSeconds(atSample: Double(window.retention.1)),
                  let pStart = map.hostSeconds(atSample: Double(window.reproduce.0)),
                  let pEnd = map.hostSeconds(atSample: Double(window.reproduce.1))
            else { continue }
            rounds.append(MemoryRound(index: index, targetBpm: config.bpm,
                                      condition: window.condition,
                                      retentionStart: rStart, retentionEnd: rEnd,
                                      reproduceStart: pStart, reproduceEnd: pEnd))
        }

        let report = TempoMemoryAnalysis.analyze(taps: taps, rounds: rounds)

        // Difficulty follows the *clock*, which is what this drill trains — so it reads the
        // continuation drill's most recent trustworthy split rather than its own accuracy.
        let clockSD = SessionStore.loadAllDropout().reversed().compactMap { session -> Double? in
            let r = session.report()
            return r.splitIsReliable ? r.wingKristofferson?.clockSDms : nil
        }.first

        return MemoryOutcome(
            report: report, environment: env, config: config,
            suggestedRetentionBars: TempoMemoryAnalysis.suggestedRetentionBars(
                current: config.retentionBars, clockSDms: clockSD),
            tapTimes: taps.map(\.time), rounds: rounds)
    }

    @discardableResult
    public static func save(_ outcome: MemoryOutcome, feelRating: Int?,
                            placement: SessionPlacement? = nil,
                            experiment: ExperimentAssignment? = nil) throws -> URL {
        let r = outcome.report
        let session = MemorySession(
            date: Date(), bpm: outcome.config.bpm,
            referenceBars: outcome.config.referenceBars,
            retentionBars: outcome.config.retentionBars,
            reproduceBars: outcome.config.reproduceBars,
            rounds: outcome.config.rounds, feelRating: feelRating,
            tapTimes: outcome.tapTimes,
            roundConditions: outcome.rounds.map { $0.condition.rawValue },
            roundRetentionStarts: outcome.rounds.map(\.retentionStart),
            roundRetentionEnds: outcome.rounds.map(\.retentionEnd),
            roundReproduceStarts: outcome.rounds.map(\.reproduceStart),
            roundReproduceEnds: outcome.rounds.map(\.reproduceEnd),
            usableCount: r.usableCount,
            silentMeanAbsErrorPercent: Stats.finite(r.silentMeanAbsErrorPercent),
            filledMeanAbsErrorPercent: Stats.finite(r.filledMeanAbsErrorPercent),
            interferenceCost: Stats.finite(r.interferenceCost),
            headline: r.headline, placement: placement, experiment: experiment)
        return try SessionStore.save(session)
    }

    public static func memoryHistory() -> [HistoryEntry] {
        SessionStore.loadAllMemory().map { session in
            let r = TempoMemoryAnalysis.analyze(taps: session.taps, rounds: session.roundWindows)
            let detail: String
            if let silent = r.silentMeanAbsErrorPercent, let filled = r.filledMeanAbsErrorPercent {
                detail = r.attritionIsImbalanced
                    ? String(format: "silent %.1f%% · filled %.1f%% · cost withheld, "
                           + "unequal attrition", silent, filled)
                    : String(format: "silent %.1f%% · filled %.1f%% · cost %+.1f",
                             silent, filled, r.interferenceCost ?? 0)
            } else {
                detail = "\(r.usableCount)/\(session.rounds) rounds scored"
            }
            return HistoryEntry(
                date: session.date,
                title: "\(Int(session.bpm)) BPM · \(session.retentionBars)-bar wait × \(session.rounds)",
                detail: detail, feelRating: session.feelRating, headline: r.headline,
                // The number this drill exists to move — already withheld by the analysis when
                // the conditions are not comparable, so an artefact never reaches the chart.
                metric: r.interferenceCost ?? .nan, metricLabel: "interference cost (points)")
        }
    }

    // MARK: - Session planning

    /// Reduce the stored history to the handful of numbers the planner consults.
    ///
    /// Everything is recomputed from raw taps here too — a planner choosing tonight's drills
    /// from a stale cached summary would be picking work for a player who no longer exists.
    /// Every experiment's current state, read from the takes assigned to it.
    ///
    /// The metric is pulled from the recomputed report, never the stored summary (R3.1), so an
    /// analysis fix reaches takes recorded before it — which matters more here than anywhere
    /// else, since an experiment's two arms may be weeks apart and a fix landing between them
    /// would otherwise compare a take under the old analysis with one under the new.
    public static func experimentResults() -> [ExperimentResult] {
        let jams = SessionStore.loadAll()
        return ExperimentLibrary.all.map { design in
            let takes = jams.compactMap { session -> ExperimentTake? in
                guard let assigned = session.experiment, assigned.name == design.name else {
                    return nil
                }
                let r = session.report()
                let value: Double?
                switch design.metric {
                case .spread:         value = Stats.finite(r.sdAsynchronyMs)
                case .bias:           value = Stats.finite(r.meanAsynchronyMs)
                case .correctionGain: value = Stats.finite(r.lag1Autocorrelation.map(abs))
                // Not derivable from a jam. No experiment in the library uses these yet, and a
                // test holds that line — an experiment declared on one would collect takes
                // forever while reporting "still collecting", which is the most expensive kind
                // of quiet failure this project can have.
                case .interferenceCost, .tempoError: value = nil
                }
                return ExperimentTake(
                    arm: assigned.arm, value: value,
                    elapsedMinutes: session.placement.map { $0.elapsedSeconds / 60 },
                    sittingId: session.placement?.sessionId,
                    notesPerBeat: session.notesPerBeat)
            }
            return ExperimentAnalysis.analyze(design: design, takes: takes)
        }
    }

    /// Every jam reduced to the interval it was played at, for the tempo question.
    ///
    /// The subdivision comes from the take rather than a constant — which is the whole reason
    /// M14 step 0 came first. Without it the interval cannot be recovered, and a take scored on
    /// a sixteenth grid would be indistinguishable from one scored on quarters.
    public static func intervalObservations() -> [IntervalObservation] {
        // A swung take has no single interval. At 2:1 the notes alternate 400 and 200 ms, so the
        // nominal 300 describes nothing that was played — and reporting it would be §7.23 step
        // 3's mistake again, where the grid the take was *scored* on stood in for the task it
        // actually performed. Swung takes are excluded rather than averaged onto the axis.
        SessionStore.loadAll().filter { $0.feel.isStraight }.map { session in
            let r = session.report()
            // The rung, or the beat when no rung was prescribed — never the stored grid. A free
            // jam asks for no subdivision; it was *scored* on a sixteenth grid, which is a
            // property of the analysis rather than of the task, and calling that a 150 ms task
            // would report an interval nobody performed. `taskSubdivisions` is that distinction.
            return IntervalObservation(
                bpm: session.bpm, subdivisions: session.taskSubdivisions,
                spreadMs: Stats.finite(r.sdAsynchronyMs),
                biasMs: Stats.finite(r.meanAsynchronyMs),
                sittingId: session.placement?.sessionId)
        }
    }

    /// The player's own recent jam spreads, newest last — what every tempo ceiling rests on.
    ///
    /// One implementation, because the ceiling has to mean the same thing wherever it is
    /// computed: `render` marks a rung above it, the jam command warns before a take, and the
    /// app's rung picker offers only what is under it. Three copies of "the median of the last
    /// six" would be three chances for those three to disagree about what is scorable.
    ///
    /// Recomputed from raw taps like everything else (R3.1), so an analysis fix moves the
    /// ceiling with it.
    public static func recentJamSpreadsMs(_ count: Int = 6) -> [Double] {
        SessionStore.loadAll().suffix(count).compactMap { Stats.finite($0.report().sdAsynchronyMs) }
    }

    /// Every jam's notes, keyed by the interval they were produced at.
    ///
    /// Pooled across takes on purpose. The question is about a property *within* playing — does
    /// a note 300 ms after the last one scatter differently from one 600 ms after — and the unit
    /// is therefore the note, not the take. That is the opposite of `ExperimentAnalysis`, where
    /// the take is the unit because the comparison is between conditions days apart.
    ///
    /// Pooling across tempos is safe here because the key is the interval in milliseconds, not
    /// the grid gap: a gap of four at 100 BPM is 600 ms and at 120 BPM is 500 ms, and they land
    /// in different bins as they should.
    public static func producedIntervalProfile() -> ProducedIntervalProfile {
        ProducedIntervalAnalysis.analyze(SessionStore.loadAll().flatMap { $0.producedNotes() })
    }

    public static func plannerInput() -> PlannerInput {
        let allJams = SessionStore.loadAll()
        let jams = allJams.map { session -> PlannerInput.Jam in
            let r = session.report()
            return PlannerInput.Jam(bpm: session.bpm, sdMs: r.sdAsynchronyMs,
                                    absBiasMs: abs(r.meanAsynchronyMs),
                                    lag1: r.lag1Autocorrelation)
        }

        // Ladder takes are jams with a rung, and they are the only jams whose tempo the planner
        // is allowed to move — so they are handed over separately from the free ones rather than
        // filtered out of them downstream.
        let ladders = allJams.compactMap { session -> PlannerInput.Ladder? in
            guard let raw = session.rung, let rung = IntervalRung(rawValue: raw),
                  let sd = Stats.finite(session.report().sdAsynchronyMs) else { return nil }
            return PlannerInput.Ladder(bpm: session.bpm, rung: rung, sdMs: sd)
        }

        let continuations = SessionStore.loadAllDropout().map { session -> PlannerInput.Continuation in
            let r = session.report()
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
            let r = session.report()
            return PlannerInput.Tempo(targetCount: Set(session.targets).count,
                                      meanAbsErrorPercent: r.meanAbsErrorPercent)
        }

        let memories = SessionStore.loadAllMemory().map { session -> PlannerInput.Memory in
            let r = TempoMemoryAnalysis.analyze(taps: session.taps, rounds: session.roundWindows)
            // Already nil when the two conditions lost different numbers of rounds — the
            // analysis withholds it rather than trusting every caller to check.
            return PlannerInput.Memory(retentionBars: session.retentionBars,
                                       interferenceCost: r.interferenceCost)
        }
        // Which arms each experiment has already collected, oldest-first. Read from the takes
        // themselves rather than from a separate ledger: the assignment on the take is the
        // record of what actually ran, and a ledger could disagree with it.
        var armsByExperiment: [String: [String]] = [:]
        for session in SessionStore.loadAll() {
            guard let assigned = session.experiment else { continue }
            armsByExperiment[assigned.name, default: []].append(assigned.arm)
        }
        let experiments = ExperimentLibrary.all.map {
            PlannerInput.Experiment(name: $0.name, completedArms: armsByExperiment[$0.name] ?? [])
        }

        return PlannerInput(jams: jams, continuations: continuations, forms: forms,
                            tempos: tempos, memories: memories, experiments: experiments,
                            ladders: ladders)
    }

    public static func planSession(targetMinutes: Int) -> SessionPlan {
        SessionPlanner.plan(targetMinutes: targetMinutes, from: plannerInput())
    }

    // MARK: - M10 cold vs warm

    /// One stored take on the way to `SessionedTake`.
    private struct DatedTake {
        let date: Date
        let placement: SessionPlacement?
        let value: Double
    }

    /// Assign every take to a sitting, and work out how warm the player was when they played it.
    ///
    /// Takes recorded through the session builder carry the answer. Everything recorded before
    /// M9 does not — but the timestamps still hold it, because an evening's practice is a run
    /// of takes minutes apart and the next sitting is hours later. Recovering that makes the
    /// whole existing history usable for the within-sitting question instead of starting from
    /// nothing, at the cost of a proxy that the report flags rather than hides.
    private static func sessioned(_ takes: [DatedTake]) -> [SessionedTake] {
        let sorted = takes.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }

        var result: [SessionedTake] = []
        var sittingIndex = 0
        var sittingStart = sorted[0].date

        for (i, take) in sorted.enumerated() {
            if i > 0 {
                let previous = sorted[i - 1]
                let isNewSitting: Bool
                if let a = previous.placement?.sessionId, let b = take.placement?.sessionId {
                    isNewSitting = a != b
                } else {
                    // Either side is a loose take: fall back to the gap rule.
                    isNewSitting = take.date.timeIntervalSince(previous.date) > 45 * 60
                }
                if isNewSitting { sittingIndex += 1; sittingStart = take.date }
            }

            // A session take knows how long into the evening it started, which counts the
            // blocks of *other* drills too — that is exactly the warmth we want. A loose take
            // can only be measured from the first take of its sitting.
            let elapsed = take.placement?.elapsedSeconds
                ?? take.date.timeIntervalSince(sittingStart)
            result.append(SessionedTake(sessionIndex: sittingIndex,
                                        elapsedMinutes: elapsed / 60,
                                        isColdProbe: take.placement?.role == BlockRole.cold.rawValue,
                                        value: take.value))
        }
        return result
    }

    /// Is the improvement in this drill warm-up or learning?
    public static func warmUpReport(for kind: DrillKind) -> WarmUpReport {
        switch kind {
        case .jam:
            // Spread, the same metric the jam trend follows.
            let takes = SessionStore.loadAll().map {
                DatedTake(date: $0.date, placement: $0.placement, value: $0.report().sdAsynchronyMs)
            }
            return WarmUpAnalysis.analyze(sessioned(takes), lowerIsBetter: true)

        case .form:
            let takes = SessionStore.loadAllForm().map {
                DatedTake(date: $0.date, placement: $0.placement, value: $0.report().onFormRate)
            }
            return WarmUpAnalysis.analyze(sessioned(takes), lowerIsBetter: false)

        case .dropout:
            let takes = SessionStore.loadAllDropout().map { session -> DatedTake in
                let r = session.report()
                return DatedTake(date: session.date, placement: session.placement,
                                 value: r.tempoBiasBpm.map(abs) ?? .nan)
            }
            return WarmUpAnalysis.analyze(sessioned(takes), lowerIsBetter: true)

        case .tempo:
            let takes = SessionStore.loadAllTempo().map { session -> DatedTake in
                let r = session.report()
                return DatedTake(date: session.date, placement: session.placement,
                                 value: r.meanAbsErrorPercent ?? .nan)
            }
            return WarmUpAnalysis.analyze(sessioned(takes), lowerIsBetter: true)

        case .memory:
            let takes = SessionStore.loadAllMemory().map { session -> DatedTake in
                let r = TempoMemoryAnalysis.analyze(taps: session.taps, rounds: session.roundWindows)
                return DatedTake(date: session.date, placement: session.placement,
                                 value: r.interferenceCost ?? .nan)
            }
            return WarmUpAnalysis.analyze(sessioned(takes), lowerIsBetter: true)
        }
    }

    // MARK: - Trends

    public enum DrillKind: String, CaseIterable {
        case jam, form, dropout, tempo, memory
    }

    /// Every trend the stored takes can support, with the confounds that make one unsafe.
    ///
    /// Built here rather than in either front end so the console and the app cannot report a
    /// different answer — and so the app stops plotting one unbroken line through a group the
    /// console warns about.
    public static func trends() -> [TrendSeries] {
        // Ordered as the console has always printed them.
        [DrillKind.jam, .dropout, .form, .tempo, .memory].flatMap { trends(for: $0) }
    }

    public static func trends(for kind: DrillKind) -> [TrendSeries] {
        switch kind {
        case .jam:     return jamTrends()
        case .dropout: return dropoutTrends()
        case .form:    return formTrends()
        case .tempo:   return tempoTrends()
        case .memory:  return memoryTrends()
        }
    }

    /// A group of jams comparable enough to fit one line through: same tempo, same rung.
    private struct GroupKey: Hashable, Comparable {
        let bpm: Int
        let rung: String?
        /// Feel joins tempo and rung as a confound axis: a swung take and a straight one at the
        /// same tempo and rung are different tasks, and a line fitted across the change would
        /// be measuring the change.
        let swingRatio: Double?
        /// So does the offbeat drill, and it is the sharpest case of the three.
        ///
        /// An offbeat take stores no rung and no swing, so without this it keys identically to a
        /// free jam and lands in the group the project reads its progress from. The first one
        /// ever recorded did exactly that: a 48.4 ms spread — by a wide margin the worst take on
        /// record, and a different task — fitted into "Jams at 100 BPM" alongside 21 free jams,
        /// with only a mixed-backings warning to name it (§7.24 step 8).
        let offbeatLevel: Int?

        var label: String {
            let rungPart = rung.flatMap { IntervalRung(rawValue: $0)?.label }.map { ", \($0)" } ?? ""
            let feelPart = swingRatio.flatMap { Feel(swingRatio: $0) }
                .map { ", \($0.label)" } ?? ""
            let offbeatPart = offbeatLevel.flatMap(OffbeatLevel.init(rawValue:))
                .map { ", offbeat level \($0.rawValue) — \($0.label)" } ?? ""
            return rungPart + feelPart + offbeatPart
        }

        static func < (a: GroupKey, b: GroupKey) -> Bool {
            if a.bpm != b.bpm { return a.bpm < b.bpm }
            if (a.rung ?? "") != (b.rung ?? "") { return (a.rung ?? "") < (b.rung ?? "") }
            if (a.swingRatio ?? 1) != (b.swingRatio ?? 1) {
                return (a.swingRatio ?? 1) < (b.swingRatio ?? 1)
            }
            return (a.offbeatLevel ?? -1) < (b.offbeatLevel ?? -1)
        }
    }

    /// The group a take belongs to. One construction site, because two would let the set of
    /// groups and the filter that fills them disagree about what a group is.
    private static func groupKey(_ take: JamSession) -> GroupKey {
        GroupKey(bpm: Int(take.bpm), rung: take.rung, swingRatio: take.swingRatio,
                 offbeatLevel: take.offbeatLevel)
    }

    private static func jamTrends() -> [TrendSeries] {
        var series: [TrendSeries] = []

        // Jams are grouped by tempo: asynchrony spread scales with the beat interval, so a
        // trend across a tempo change would be measuring the tempo.
        // Grouped by tempo **and rung**, because those are the same axis: both move the gap
        // between notes, and a trend fitted across a rung change would be measuring the rung
        // (§7.23 trap 3). Free playing is its own group rather than being folded into quarters —
        // "play what you like" and "play one note per beat" are different tasks.
        let jams = SessionStore.loadAll()
        let groups = Set(jams.map(groupKey))
        for key in groups.sorted() {
            let takes = jams.filter { groupKey($0) == key }
            let tempo = key.bpm
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
                title: "Jams at \(tempo) BPM\(key.label)", takeCount: takes.count,
                warnings: warnings,
                rows: [
                    TrendAnalysis.row("spread (SD)", reports.map(\.sdAsynchronyMs), lowerIsBetter: true),
                    TrendAnalysis.row("|bias|", reports.map { abs($0.meanAsynchronyMs) }, lowerIsBetter: true),
                    TrendAnalysis.row("r₁ toward 0", reports.map { $0.lag1Autocorrelation.map(abs) ?? .nan },
                                      lowerIsBetter: true),
                ]))
        }
        return series
    }

    /// One line per comparable group, rather than one line and a warning beside it.
    ///
    /// Jams have been grouped since M7 — by tempo, then rung, then feel, then offbeat level —
    /// because a trend fitted across a change of task measures the change. The other three
    /// drills warned instead, in words that made the case themselves: *"a longer silence is a
    /// harder task"*, *"a trend here reflects the ladder as much as you"*, *"a longer wait is a
    /// harder task"* — and then fitted the line anyway.
    ///
    /// Naming a confound is the floor, not the fix (R3.4 versus R3.5). A reader who sees a
    /// verdict and a caveat has still been shown a verdict, and the continuation drill's clock
    /// SD read "worsening" on a series whose two hardest takes were also its most recent
    /// (§7.26).
    ///
    /// Groups smaller than `TrendAnalysis.minimumPoints` get no fit, which is the honest answer
    /// and the visible cost of this change: splitting twelve takes four ways leaves most of them
    /// unable to say anything. They could not say anything before either.
    private static func groupedTrends<Take, Key: Hashable & Comparable>(
        _ takes: [Take],
        by key: (Take) -> Key,
        title: (Key) -> String,
        rows: ([Take]) -> [TrendRow],
        warnings: ([Take]) -> [String] = { _ in [] }
    ) -> [TrendSeries] {
        Set(takes.map(key)).sorted().map { groupKey in
            let group = takes.filter { key($0) == groupKey }
            return TrendSeries(title: title(groupKey), takeCount: group.count,
                               warnings: warnings(group), rows: rows(group))
        }
    }

    /// Silence length **and** rung: both change the task. A longer silence is harder, and a
    /// rung changes the note value being sustained, which is §7.23 trap 3 inside this drill.
    ///
    /// **Here an absent rung really does mean quarters**, and that is the opposite of the rule
    /// for jams. The two are decided by what the player was told, not by the field: a jam with
    /// no rung says *play what you like*, which is a different task from quarters, while
    /// `DrillInstructions.dropout(rung:)` returns the *same text* for `nil` and for `.quarters`
    /// — "Play exactly ONE NOTE PER BEAT" — because this drill has demanded one note per beat in
    /// words since M6. Grouping them apart would split one task in two on a distinction the
    /// player was never shown (`LESSONS.md` shape 13, and §7.24 step 1 for the jam side).
    private struct DropoutKey: Hashable, Comparable {
        let silentBars: Int
        let rung: IntervalRung

        init(silentBars: Int, rung: String?) {
            self.silentBars = silentBars
            self.rung = rung.flatMap(IntervalRung.init(rawValue:)) ?? .quarters
        }

        static func < (a: DropoutKey, b: DropoutKey) -> Bool {
            a.silentBars != b.silentBars
                ? a.silentBars < b.silentBars : a.rung.rawValue < b.rung.rawValue
        }
    }

    private static func dropoutTrends() -> [TrendSeries] {
        groupedTrends(
            SessionStore.loadAllDropout(),
            by: { DropoutKey(silentBars: $0.silentBars, rung: $0.rung) },
            title: { "Continuation drill — \($0.silentBars)-bar silences, \($0.rung.label)" },
            rows: { group in
                let reports = group.map { $0.report() }
                return [
                    TrendAnalysis.row("|tempo bias|",
                                      reports.map { $0.tempoBiasBpm.map(abs) ?? .nan },
                                      lowerIsBetter: true),
                    TrendAnalysis.row("clock SD",
                                      reports.map {
                                          $0.splitIsReliable
                                              ? ($0.wingKristofferson?.clockSDms ?? .nan) : .nan
                                      },
                                      lowerIsBetter: true),
                ]
            })
    }

    /// Level and phrase length. The level is a *ladder* — it is meant to rise — so a line fitted
    /// across it measures the promotion rather than the player, and on-form rate falling as the
    /// landmarks are removed is the drill working rather than the player getting worse.
    private struct FormKey: Hashable, Comparable {
        let level: Int
        let phraseBars: Int
        static func < (a: FormKey, b: FormKey) -> Bool {
            a.level != b.level ? a.level < b.level : a.phraseBars < b.phraseBars
        }
    }

    private static func formTrends() -> [TrendSeries] {
        groupedTrends(
            SessionStore.loadAllForm(),
            by: { FormKey(level: $0.level, phraseBars: $0.phraseBars) },
            title: { "Form drill — level \($0.level), \($0.phraseBars)-bar phrases" },
            rows: { group in
                [TrendAnalysis.row("on-form rate", group.map { $0.report().onFormRate },
                                   lowerIsBetter: false)]
            })
    }

    private static func memoryTrends() -> [TrendSeries] {
        groupedTrends(
            SessionStore.loadAllMemory(),
            by: { $0.retentionBars },
            title: { "Recall drill — \($0)-bar waits" },
            rows: { group in
                let reports = group.map {
                    TempoMemoryAnalysis.analyze(taps: $0.taps, rounds: $0.roundWindows)
                }
                return [TrendAnalysis.row("interference cost",
                                          reports.map { $0.interferenceCost ?? .nan },
                                          lowerIsBetter: true)]
            })
    }

    /// The target set, because rotating targets is a harder task than holding one.
    ///
    /// Every take on record targets 100, so this splits nothing today — and it is here for the
    /// same reason the others are: M14's ladder rotates tempo between sittings by design, so the
    /// confound is scheduled rather than hypothetical. Fixing three of four sites is how a rule
    /// comes to be half-applied (§7.20 finding 2).
    private static func tempoKey(_ take: TempoSession) -> String {
        take.targets.map { String(Int($0)) }.joined(separator: "/")
    }

    private static func tempoTrends() -> [TrendSeries] {
        groupedTrends(
            SessionStore.loadAllTempo(),
            by: tempoKey,
            title: { "Tempo drill — \($0) BPM" },
            rows: { group in
                [TrendAnalysis.row("tempo error (%)",
                                   group.map { $0.report().meanAbsErrorPercent ?? .nan },
                                   lowerIsBetter: true)]
            })
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
