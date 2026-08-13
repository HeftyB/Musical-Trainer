import Foundation
import GrooveCore
import TimingCore

/// Runs a planned session block by block.
///
/// Deliberately a state machine rather than a loop: between every block the player rates the
/// take, and a rating needs the UI. A blocking `runWholeSession()` would either have to know
/// how to ask — which puts presentation in the engine — or skip the rating, which is the one
/// thing PLAN §2 says must come before any number.
///
/// **No results are shown until the session ends.** Rating after each block and holding the
/// debrief to the finish makes the eyes-off rule stronger than it is for a single take: for
/// the whole session there is nothing numeric to see. The tempo drill's own round-by-round
/// feedback stays, because that drill *is* a feedback loop and removing it would remove the
/// mechanism rather than protect it.
public final class SessionRunner {

    public enum BlockOutcome {
        case jam(TrainerEngine.JamOutcome)
        case form(TrainerEngine.FormOutcome)
        case dropout(TrainerEngine.DropoutOutcome)
        case tempo(TrainerEngine.TempoOutcome)
        case memory(TrainerEngine.MemoryOutcome)
        /// The warm-up: played, not measured, nothing to rate or save.
        case unmeasured

        public var isMeasured: Bool {
            if case .unmeasured = self { return false }
            return true
        }

        public var headline: String? {
            switch self {
            case .jam(let o):     return o.report.headline
            case .form(let o):    return o.report.headline
            case .dropout(let o): return o.report.headline
            case .tempo(let o):   return o.report.headline
            case .memory(let o):  return o.report.headline
            case .unmeasured:     return nil
            }
        }

        /// The one line of numbers the debrief shows for this block.
        public var detail: String? {
            switch self {
            case .jam(let o):
                return String(format: "mean %+.1f ms · SD %.1f ms",
                              o.report.meanAsynchronyMs, o.report.sdAsynchronyMs)
            case .form(let o):
                return "\(o.report.onFormCount)/\(o.report.marksPlaced) on form · "
                     + "\(o.report.cleanCount)/\(o.report.marksPlaced) clean"
            case .dropout(let o):
                let tempo = o.report.playedBpm.map { String(format: "%.0f BPM alone", $0) }
                var split = "split unreliable"
                if o.report.splitIsReliable, let wk = o.report.wingKristofferson {
                    split = String(format: "clock %.1f / motor %.1f ms", wk.clockSDms, wk.motorSDms)
                }
                return [tempo, split].compactMap { $0 }.joined(separator: " · ")
            case .tempo(let o):
                guard let bias = o.report.meanErrorPercent else { return "no rounds scored" }
                return String(format: "%+.1f%% bias · %d/%d rounds scored",
                              bias, o.report.usableCount, o.report.rounds.count)
            case .memory(let o):
                guard let silent = o.report.silentMeanAbsErrorPercent,
                      let filled = o.report.filledMeanAbsErrorPercent else {
                    return "\(o.report.usableCount)/\(o.report.rounds.count) rounds scored"
                }
                // The debrief is the one place the session's numbers appear, so the withheld
                // cost has to be withheld here too — not quietly shown as 0.
                if o.report.attritionIsImbalanced {
                    return String(format: "silent %.1f%% · filled %.1f%% · cost withheld, "
                                + "unequal attrition", silent, filled)
                }
                return String(format: "silent %.1f%% · filled %.1f%% · cost %+.1f",
                              silent, filled, o.report.interferenceCost ?? 0)
            case .unmeasured:
                return nil
            }
        }
    }

    public struct BlockResult {
        public let index: Int
        public let block: SessionBlock
        public let outcome: BlockOutcome?     // nil when skipped
        public let feelRating: Int?
        public var wasSkipped: Bool { outcome == nil }
    }

    public let plan: SessionPlan
    public let sessionId: UUID
    /// Declared before the first block and stamped on every take of the sitting.
    public let state: SessionState?
    public private(set) var index = 0
    public private(set) var results: [BlockResult] = []

    private let startDate: Date
    /// Elapsed at the moment the current block started playing — the number that makes a
    /// cold take and a take twenty minutes in tell themselves apart later.
    private var blockStartElapsed: Double = 0

    public init(plan: SessionPlan, sessionId: UUID = UUID(), startDate: Date = Date(),
                state: SessionState? = nil) {
        self.plan = plan
        self.sessionId = sessionId
        self.startDate = startDate
        self.state = state
    }

    public var currentBlock: SessionBlock? {
        index < plan.blocks.count ? plan.blocks[index] : nil
    }

    // There is deliberately no `currentInstructions` here. `DrillInstructions.forBlock(_:)` is
    // the one mapping from a planned block to its text, and both surfaces call it directly.
    //
    // A second copy lived on this type until M14 step 4a, and it is worth recording what it
    // cost rather than only deleting it. Nothing in either front end ever called it — but the
    // two tests named for checking that the runner shows the arm's instructions called it, so
    // the path under test was not the path that shipped. That is §7.20 step 4's defect exactly,
    // left in place by the fix for §7.20 step 4: the accessor was orphaned and the tests were
    // not moved with it. An instruction-only experiment is decided entirely by this text, so
    // a copy that only tests can reach is worse than no test at all.

    public var isFinished: Bool { index >= plan.blocks.count }

    /// Blocks remaining, including the current one.
    public var remainingCount: Int { max(0, plan.blocks.count - index) }

    /// Estimated seconds still to play, including gaps.
    public var remainingSeconds: Double {
        let blocks = plan.blocks[min(index, plan.blocks.count)...]
        return blocks.reduce(0) { $0 + $1.estimatedSeconds }
            + Double(max(0, blocks.count - 1)) * SessionPlanner.betweenBlockSeconds
    }

    // MARK: - Running

    /// Roles whose music is frozen for ever (R3.5).
    ///
    /// The cold probe, the benchmark and both experiment arms are the only longitudinal data this
    /// project has — 21 free jams at 100 BPM and a five-point benchmark — and **the failure here
    /// is silent**: a benchmark take over a generated backing is a perfectly good take that has
    /// quietly left the series it exists to extend, and no readout would say so.
    ///
    /// Every role, not a list of the ones that matter, so a role added later has to be classified
    /// before it compiles here — `lockedToTheFixedBacking` is exhaustive over `BlockRole` and a
    /// new case is a compiler error rather than a silent `false`.
    static func lockedToTheFixedBacking(_ role: BlockRole) -> Bool {
        switch role {
        case .cold, .benchmark, .experiment: return true
        case .warmUp, .training, .closing: return false
        }
    }

    /// The config a planned jam block runs as.
    ///
    /// Everything the plan settles travels into the config, so what the block preview announced
    /// is what plays and what the take is stored with. **`offbeatLevel` was the one that did
    /// not**: the field was on `JamPlan` and `DrillInstructions.forBlock` already read it, so a
    /// planned offbeat block would have shown the skank's instructions and run an ordinary jam
    /// over `jamBacking` — the arm-text mismatch of §7.20 finding 9, pre-wired and waiting for
    /// the planner to set the field (§7.24 step 8).
    ///
    /// Extracted from `runCurrent` because a decision inside a function that needs an audio
    /// device is a decision no test can reach, which is how this one shipped unnoticed.
    ///
    /// **It takes the role, and drops a generated backing from a locked slot rather than trusting
    /// the plan.** Not redundant with the planner never setting one: the planner is not the only
    /// thing that builds a block. A stored manifest is replayed, and a manifest written by a
    /// future version is not something today's planner controls — so the refusal belongs at the
    /// point the music is chosen, which is here.
    static func jamConfig(for p: JamPlan, role: BlockRole) -> TrainerEngine.JamConfig {
        TrainerEngine.JamConfig(
            bpm: p.bpm, bars: p.bars, tag: p.tag, rung: p.rung, feel: p.feel,
            offbeatLevel: p.offbeatLevel.flatMap(OffbeatLevel.init(rawValue:)),
            generatedBacking: lockedToTheFixedBacking(role) ? nil
                : p.generatedBacking.map { BackingIdentity(style: $0.style, seed: $0.seed) })
    }

    /// The remaining four, extracted for the same reason and used by the same two callers:
    /// `runCurrent` plays them and `DrillInstructions.forBlock` describes them.
    ///
    /// Two constructions of one config is two chances to disagree, and the disagreement is
    /// invisible — the preview announces one thing and the engine runs another. `jamConfig`
    /// exists because that already happened once with `offbeatLevel`; these close the same door
    /// on the four drills where nobody has tried it yet. The level fallback below is the only
    /// judgement in any of them, and it now lives in one place rather than two.
    static func formConfig(for p: FormPlan) -> TrainerEngine.FormConfig {
        TrainerEngine.FormConfig(bpm: p.bpm, bars: p.bars, phraseBars: p.phraseBars,
                                 level: FormLevel(rawValue: p.level) ?? .fillAndAccent)
    }

    static func dropoutConfig(for p: DropoutPlan) -> TrainerEngine.DropoutConfig {
        TrainerEngine.DropoutConfig(bpm: p.bpm, pacedBars: p.pacedBars,
                                    silentBars: p.silentBars, cycles: p.cycles, rung: p.rung)
    }

    static func tempoConfig(for p: TempoPlan) -> TrainerEngine.TempoConfig {
        TrainerEngine.TempoConfig(targets: p.targets, leadBars: p.leadBars,
                                  holdBars: p.holdBars, rounds: p.rounds, rung: p.rung)
    }

    static func memoryConfig(for p: MemoryPlan) -> TrainerEngine.MemoryConfig {
        TrainerEngine.MemoryConfig(bpm: p.bpm, referenceBars: p.referenceBars,
                                   retentionBars: p.retentionBars,
                                   reproduceBars: p.reproduceBars, rounds: p.rounds)
    }

    /// Play the current block. Blocks for its duration, so call it off the main thread.
    ///
    /// - Throws: `TakeCancelled` when the player stops it. The caller decides whether that
    ///   means skip this drill or end the session — the runner does not assume, because
    ///   "wrong tempo, start that one again" and "I'm done" are different intentions.
    public func runCurrent(progress: ((Double) -> Void)? = nil,
                           cancellation: CancellationFlag? = nil,
                           roundFinished: ((TempoRoundResult) -> Void)? = nil) throws -> BlockOutcome {
        guard let block = currentBlock else { throw SpikeError("The session has already finished.") }
        blockStartElapsed = Date().timeIntervalSince(startDate)

        switch block.plan {
        case .groove(let p):
            try TrainerEngine.playGroove(TrainerEngine.GrooveConfig(bpm: p.bpm, bars: p.bars),
                                         progress: progress, cancellation: cancellation)
            return .unmeasured

        case .jam(let p):
            return .jam(try TrainerEngine.runJam(Self.jamConfig(for: p, role: block.role),
                                                 progress: progress, cancellation: cancellation))

        case .form(let p):
            return .form(try TrainerEngine.runForm(Self.formConfig(for: p),
                                                   progress: progress, cancellation: cancellation))

        case .dropout(let p):
            return .dropout(try TrainerEngine.runDropout(Self.dropoutConfig(for: p),
                                                         progress: progress,
                                                         cancellation: cancellation))

        case .memory(let p):
            return .memory(try TrainerEngine.runMemory(Self.memoryConfig(for: p),
                                                       progress: progress,
                                                       cancellation: cancellation))

        case .tempo(let p):
            return .tempo(try TrainerEngine.runTempo(Self.tempoConfig(for: p),
                                                     progress: progress, cancellation: cancellation,
                                                     roundFinished: roundFinished))
        }
    }

    /// Save the finished block with its place in the session, then advance.
    ///
    /// The placement is what makes the take answer "was this cold or warm?" later. Saving a
    /// session take without one would leave M10 and M16 unable to use it, which is the whole
    /// reason storage changed before anything else in M9 did.
    public func complete(_ outcome: BlockOutcome, feelRating: Int?) throws {
        guard let block = currentBlock else { return }
        let placement = placement(forBlock: block, at: blockStartElapsed)
        // The arm comes from the block, so a take is stamped with the condition the plan said
        // it would run under rather than with one decided at save time.
        let experiment = block.experiment
        switch outcome {
        case .jam(let o):
            try TrainerEngine.save(o, feelRating: feelRating, placement: placement,
                                   experiment: experiment)
        case .form(let o):
            try TrainerEngine.save(o, feelRating: feelRating, placement: placement,
                                   experiment: experiment)
        case .dropout(let o):
            try TrainerEngine.save(o, feelRating: feelRating, placement: placement,
                                   experiment: experiment)
        case .tempo(let o):
            try TrainerEngine.save(o, feelRating: feelRating, placement: placement,
                                   experiment: experiment)
        case .memory(let o):
            try TrainerEngine.save(o, feelRating: feelRating, placement: placement,
                                   experiment: experiment)
        case .unmeasured:     break
        }
        results.append(BlockResult(index: index, block: block, outcome: outcome,
                                   feelRating: feelRating))
        index += 1
    }

    /// The placement that will be stamped on a take finishing now.
    ///
    /// A method rather than four arguments assembled inline in `complete`, because `complete`
    /// can only be reached with a real drill outcome and those need an audio device — anything
    /// decided in there is unreachable from a suite. The same reason `JamConfig.countInBar`
    /// moved out of `runJam`.
    func placement(forBlock block: SessionBlock, at elapsed: Double) -> SessionPlacement {
        SessionPlacement(sessionId: sessionId, blockIndex: index,
                         role: block.role.rawValue, elapsedSeconds: elapsed,
                         state: state?.rawValue)
    }

    /// Abandon the current block and move on. The recording is discarded, exactly as a
    /// stopped single take is: a drill stopped because something was wrong is not worth
    /// measuring, and a fragment would pollute the pooled statistics.
    public func skip() {
        guard let block = currentBlock else { return }
        results.append(BlockResult(index: index, block: block, outcome: nil, feelRating: nil))
        index += 1
    }

    /// Write the session manifest and hand back the debrief.
    @discardableResult
    public func finish(endedEarly: Bool) throws -> SessionSummary {
        let summary = SessionSummary(
            sessionId: sessionId, date: startDate, targetMinutes: plan.targetMinutes,
            durationSeconds: Date().timeIntervalSince(startDate),
            endedEarly: endedEarly, plan: plan, results: results, state: state)
        try SessionStore.save(TrainingSessionRecord(summary))
        return summary
    }
}

/// Everything the debrief needs, and the only place the session's numbers appear.
public struct SessionSummary {
    public let sessionId: UUID
    public let date: Date
    public let targetMinutes: Int
    public let durationSeconds: Double
    public let endedEarly: Bool
    public let plan: SessionPlan
    public let results: [SessionRunner.BlockResult]
    public let state: SessionState?

    public var completedCount: Int { results.filter { !$0.wasSkipped }.count }
    public var skippedCount: Int { results.filter(\.wasSkipped).count }

    /// Measured blocks only — the warm-up has nothing to report.
    public var measuredResults: [SessionRunner.BlockResult] {
        results.filter { $0.outcome?.isMeasured == true }
    }
}

// MARK: - Persistence

/// The session as it actually ran, saved alongside the takes.
///
/// The takes carry the placement that makes them analysable; this carries the intent — what
/// the planner chose, why, and what was skipped. Without it, a session where two drills were
/// abandoned looks identical to one that was planned short.
struct TrainingSessionRecord: Codable, StoredTake {
    struct Block: Codable {
        let index: Int
        let role: String
        let drill: String
        let settings: String
        let reason: String
        let skipped: Bool
        let headline: String?
        let feelRating: Int?
    }

    let id: UUID
    let date: Date
    let targetMinutes: Int
    let durationSeconds: Double
    let endedEarly: Bool
    let planNotes: [String]
    let blocks: [Block]
    /// The declared state, on the manifest as well as on each take: the manifest is the record
    /// of intent, and "what did I say before this evening" belongs with it.
    let state: String?

    init(_ summary: SessionSummary) {
        id = summary.sessionId
        date = summary.date
        targetMinutes = summary.targetMinutes
        durationSeconds = summary.durationSeconds
        endedEarly = summary.endedEarly
        planNotes = summary.plan.notes
        state = summary.state?.rawValue
        blocks = summary.results.map {
            Block(index: $0.index, role: $0.block.role.rawValue,
                  drill: $0.block.plan.drillName, settings: $0.block.plan.settingsLabel,
                  reason: $0.block.reason, skipped: $0.wasSkipped,
                  headline: $0.outcome?.headline, feelRating: $0.feelRating)
        }
    }
}
