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
                     + "\(o.report.tightCount) nailed"
            case .dropout(let o):
                let tempo = o.report.playedBpm.map { String(format: "%.0f BPM alone", $0) }
                let split = o.report.splitIsReliable && o.report.wingKristofferson != nil
                    ? String(format: "clock %.1f / motor %.1f ms",
                             o.report.wingKristofferson!.clockSDms, o.report.wingKristofferson!.motorSDms)
                    : "split unreliable"
                return [tempo, split].compactMap { $0 }.joined(separator: " · ")
            case .tempo(let o):
                guard let bias = o.report.meanErrorPercent else { return "no rounds scored" }
                return String(format: "%+.1f%% bias · %d/%d rounds scored",
                              bias, o.report.usableCount, o.report.rounds.count)
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
    public private(set) var index = 0
    public private(set) var results: [BlockResult] = []

    private let startDate: Date
    /// Elapsed at the moment the current block started playing — the number that makes a
    /// cold take and a take twenty minutes in tell themselves apart later.
    private var blockStartElapsed: Double = 0

    public init(plan: SessionPlan, sessionId: UUID = UUID(), startDate: Date = Date()) {
        self.plan = plan
        self.sessionId = sessionId
        self.startDate = startDate
    }

    public var currentBlock: SessionBlock? {
        index < plan.blocks.count ? plan.blocks[index] : nil
    }

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
            return .jam(try TrainerEngine.runJam(
                TrainerEngine.JamConfig(bpm: p.bpm, bars: p.bars, tag: p.tag),
                progress: progress, cancellation: cancellation))

        case .form(let p):
            return .form(try TrainerEngine.runForm(
                TrainerEngine.FormConfig(bpm: p.bpm, bars: p.bars, phraseBars: p.phraseBars,
                                         level: FormLevel(rawValue: p.level) ?? .fillAndAccent),
                progress: progress, cancellation: cancellation))

        case .dropout(let p):
            return .dropout(try TrainerEngine.runDropout(
                TrainerEngine.DropoutConfig(bpm: p.bpm, pacedBars: p.pacedBars,
                                            silentBars: p.silentBars, cycles: p.cycles),
                progress: progress, cancellation: cancellation))

        case .tempo(let p):
            return .tempo(try TrainerEngine.runTempo(
                TrainerEngine.TempoConfig(targets: p.targets, leadBars: p.leadBars,
                                          holdBars: p.holdBars, rounds: p.rounds),
                progress: progress, cancellation: cancellation, roundFinished: roundFinished))
        }
    }

    /// Save the finished block with its place in the session, then advance.
    ///
    /// The placement is what makes the take answer "was this cold or warm?" later. Saving a
    /// session take without one would leave M10 and M16 unable to use it, which is the whole
    /// reason storage changed before anything else in M9 did.
    public func complete(_ outcome: BlockOutcome, feelRating: Int?) throws {
        guard let block = currentBlock else { return }
        let placement = SessionPlacement(sessionId: sessionId, blockIndex: index,
                                         role: block.role.rawValue,
                                         elapsedSeconds: blockStartElapsed)
        switch outcome {
        case .jam(let o):     try TrainerEngine.save(o, feelRating: feelRating, placement: placement)
        case .form(let o):    try TrainerEngine.save(o, feelRating: feelRating, placement: placement)
        case .dropout(let o): try TrainerEngine.save(o, feelRating: feelRating, placement: placement)
        case .tempo(let o):   try TrainerEngine.save(o, feelRating: feelRating, placement: placement)
        case .unmeasured:     break
        }
        results.append(BlockResult(index: index, block: block, outcome: outcome,
                                   feelRating: feelRating))
        index += 1
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
            endedEarly: endedEarly, plan: plan, results: results)
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
struct TrainingSessionRecord: Codable {
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

    init(_ summary: SessionSummary) {
        id = summary.sessionId
        date = summary.date
        targetMinutes = summary.targetMinutes
        durationSeconds = summary.durationSeconds
        endedEarly = summary.endedEarly
        planNotes = summary.plan.notes
        blocks = summary.results.map {
            Block(index: $0.index, role: $0.block.role.rawValue,
                  drill: $0.block.plan.drillName, settings: $0.block.plan.settingsLabel,
                  reason: $0.block.reason, skipped: $0.wasSkipped,
                  headline: $0.outcome?.headline, feelRating: $0.feelRating)
        }
    }
}
