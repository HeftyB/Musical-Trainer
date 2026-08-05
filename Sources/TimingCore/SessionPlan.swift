import Foundation

/// What a block is *for*, which is not the same as which drill it runs.
///
/// The role is what makes a session comparable to the one before it. A tempo drill run cold
/// as the first thing of the evening and the same drill run twenty minutes in are different
/// measurements, and only the role says which is which.
public enum BlockRole: String, Codable, Equatable, CaseIterable {
    /// Before any warm-up, fixed parameters, every session. Reserved for M10.
    case cold
    /// Unmeasured playing to get the hands moving.
    case warmUp
    /// Locked parameters, fixed slot. The take the trend line is fitted to.
    case benchmark
    /// Chosen from recent data. The only blocks the planner is allowed to vary.
    case training
    /// The musical payoff, and the longest stretch of playing in the session.
    case closing
}

// MARK: - Block parameters
//
// These mirror the engine's drill configs rather than reusing them, because the engine's
// configs carry validation and audio-scheduling concerns that a plan has no business
// knowing about. The mapping is one-directional and lives in the runner.

public struct GroovePlan: Codable, Equatable {
    public let bpm: Double
    public let bars: Int
    public init(bpm: Double, bars: Int) { self.bpm = bpm; self.bars = bars }
}

public struct JamPlan: Codable, Equatable {
    public let bpm: Double
    public let bars: Int
    public let tag: String?
    public init(bpm: Double, bars: Int, tag: String?) { self.bpm = bpm; self.bars = bars; self.tag = tag }
}

public struct FormPlan: Codable, Equatable {
    public let bpm: Double
    public let bars: Int
    public let phraseBars: Int
    public let level: Int
    public init(bpm: Double, bars: Int, phraseBars: Int, level: Int) {
        self.bpm = bpm; self.bars = bars; self.phraseBars = phraseBars; self.level = level
    }
}

public struct DropoutPlan: Codable, Equatable {
    public let bpm: Double
    public let pacedBars: Int
    public let silentBars: Int
    public let cycles: Int
    public init(bpm: Double, pacedBars: Int, silentBars: Int, cycles: Int) {
        self.bpm = bpm; self.pacedBars = pacedBars; self.silentBars = silentBars; self.cycles = cycles
    }
}

public struct TempoPlan: Codable, Equatable {
    public let targets: [Double]
    public let leadBars: Int
    public let holdBars: Int
    public let rounds: Int
    public init(targets: [Double], leadBars: Int, holdBars: Int, rounds: Int) {
        self.targets = targets; self.leadBars = leadBars; self.holdBars = holdBars; self.rounds = rounds
    }
}

public struct MemoryPlan: Codable, Equatable {
    public let bpm: Double
    public let referenceBars: Int
    public let retentionBars: Int
    public let reproduceBars: Int
    public let rounds: Int
    public init(bpm: Double, referenceBars: Int, retentionBars: Int,
                reproduceBars: Int, rounds: Int) {
        self.bpm = bpm; self.referenceBars = referenceBars
        self.retentionBars = retentionBars; self.reproduceBars = reproduceBars
        self.rounds = rounds
    }
}

public enum BlockPlan: Codable, Equatable {
    case groove(GroovePlan)
    case jam(JamPlan)
    case form(FormPlan)
    case dropout(DropoutPlan)
    case tempo(TempoPlan)
    case memory(MemoryPlan)

    /// Short name for the plan preview.
    public var drillName: String {
        switch self {
        case .groove:  return "Play"
        case .jam:     return "Jam"
        case .form:    return "Form"
        case .dropout: return "Alone"
        case .tempo:   return "Tempo"
        case .memory:  return "Recall"
        }
    }

    /// The settings, in the words the setup screen uses.
    public var settingsLabel: String {
        switch self {
        case .groove(let p):  return "\(Int(p.bpm)) BPM · \(p.bars) bars"
        case .jam(let p):     return "\(Int(p.bpm)) BPM · \(p.bars) bars"
        case .form(let p):    return "level \(p.level) · \(p.phraseBars)-bar phrases · \(p.bars) bars"
        case .dropout(let p): return "\(p.pacedBars)+\(p.silentBars) bars × \(p.cycles)"
        case .tempo(let p):
            let targets = p.targets.map { String(Int($0)) }.joined(separator: "/")
            return "\(targets) BPM · \(p.rounds)× \(p.holdBars)-bar holds"
        case .memory(let p):
            return "\(Int(p.bpm)) BPM · \(p.retentionBars)-bar wait × \(p.rounds)"
        }
    }

    /// How long this block plays for, matching the engine's own duration arithmetic. The
    /// plan preview promises the player a session length, so this has to agree with what
    /// actually runs.
    public var estimatedSeconds: Double {
        switch self {
        case .groove(let p):  return Double(p.bars + 1) * 4 * 60 / p.bpm
        case .jam(let p):     return Double(p.bars + 2) * 4 * 60 / p.bpm
        case .form(let p):    return Double(p.bars + 2) * 4 * 60 / p.bpm
        case .dropout(let p):
            let total = p.cycles * (p.pacedBars + p.silentBars) + p.pacedBars
            return Double(total + 2) * 4 * 60 / p.bpm
        case .tempo(let p):
            // No targets means no rounds to estimate, and `% 0` would trap rather than say so.
            guard !p.targets.isEmpty else { return 0 }
            return (0..<p.rounds).reduce(0.5) { total, i in
                total + Double(p.leadBars + p.holdBars) * 4 * 60 / p.targets[i % p.targets.count]
            }
        case .memory(let p):
            let bars = p.rounds * (p.referenceBars + p.retentionBars + p.reproduceBars)
            return Double(bars) * 4 * 60 / p.bpm + 0.5
        }
    }
}

public struct SessionBlock: Codable, Equatable {
    public let role: BlockRole
    public let plan: BlockPlan
    /// Why this block, at this difficulty, in one sentence.
    ///
    /// Shown with the plan before the session starts. A session the app chose but cannot
    /// justify is one the player has no way to disagree with.
    public let reason: String
    /// The experiment and arm this block belongs to, when the planner assigned one.
    ///
    /// Optional and always nil until M13's runner exists. It sits on the block rather than
    /// being handed to `SessionRunner` separately so that the arm travels with the thing that
    /// decides it — a plan that says which arm it is running can be shown, stored and checked
    /// before a note is played, and the runner only has to carry it through.
    public let experiment: ExperimentAssignment?

    public init(role: BlockRole, plan: BlockPlan, reason: String,
                experiment: ExperimentAssignment? = nil) {
        self.role = role; self.plan = plan; self.reason = reason
        self.experiment = experiment
    }

    public var estimatedSeconds: Double { plan.estimatedSeconds }
}

public struct SessionPlan: Codable, Equatable {
    public let targetMinutes: Int
    public let blocks: [SessionBlock]
    /// What the planner could not decide and what it would need to decide it. Shown with the
    /// plan, so a gap in the data is visible before the session rather than discovered after.
    public let notes: [String]

    public init(targetMinutes: Int, blocks: [SessionBlock], notes: [String]) {
        self.targetMinutes = targetMinutes; self.blocks = blocks; self.notes = notes
    }

    /// Playing time plus the gaps between blocks.
    public var estimatedSeconds: Double {
        blocks.reduce(0) { $0 + $1.estimatedSeconds }
            + Double(max(0, blocks.count - 1)) * SessionPlanner.betweenBlockSeconds
    }
}

// MARK: - Input

/// Recent history, reduced to the few numbers the rules actually consult.
///
/// Deliberately not the stored session types: the planner has to be testable against
/// hand-built histories, and taking plain summaries is what makes "given three unreliable
/// splits, does it schedule the continuation drill?" a test rather than a fixture directory.
public struct PlannerInput: Equatable {
    public struct Jam: Equatable {
        public let bpm: Double
        public let sdMs: Double
        public let absBiasMs: Double
        public let lag1: Double?
        public init(bpm: Double, sdMs: Double, absBiasMs: Double, lag1: Double?) {
            self.bpm = bpm; self.sdMs = sdMs; self.absBiasMs = absBiasMs; self.lag1 = lag1
        }
    }

    public struct Continuation: Equatable {
        public let silentBars: Int
        public let absTempoBiasPercent: Double?
        public let splitIsReliable: Bool
        public let clockSDms: Double?
        public let motorSDms: Double?
        public init(silentBars: Int, absTempoBiasPercent: Double?, splitIsReliable: Bool,
                    clockSDms: Double?, motorSDms: Double?) {
            self.silentBars = silentBars; self.absTempoBiasPercent = absTempoBiasPercent
            self.splitIsReliable = splitIsReliable; self.clockSDms = clockSDms; self.motorSDms = motorSDms
        }
    }

    public struct Form: Equatable {
        public let level: Int
        public let phraseBars: Int
        public let onFormRate: Double
        public let hasUnmarkedPhrases: Bool
        /// The sub-multiple the player actually marked, when they were consistent about one.
        /// A steady 4-bar feel against an 8-bar setting is a different finding from a lost
        /// one, and the ladder should follow the feel rather than score it down.
        public let markedEveryBars: Double?
        public init(level: Int, phraseBars: Int, onFormRate: Double,
                    hasUnmarkedPhrases: Bool, markedEveryBars: Double?) {
            self.level = level; self.phraseBars = phraseBars; self.onFormRate = onFormRate
            self.hasUnmarkedPhrases = hasUnmarkedPhrases; self.markedEveryBars = markedEveryBars
        }
    }

    public struct Tempo: Equatable {
        public let targetCount: Int
        public let meanAbsErrorPercent: Double?
        public init(targetCount: Int, meanAbsErrorPercent: Double?) {
            self.targetCount = targetCount; self.meanAbsErrorPercent = meanAbsErrorPercent
        }
    }

    public struct Memory: Equatable {
        public let retentionBars: Int
        /// filled − silent, in percentage points. Positive means the distractor hurt.
        public let interferenceCost: Double?
        public init(retentionBars: Int, interferenceCost: Double?) {
            self.retentionBars = retentionBars; self.interferenceCost = interferenceCost
        }
    }

    /// All oldest-first, matching `SessionStore`.
    public let jams: [Jam]
    public let continuations: [Continuation]
    public let forms: [Form]
    public let tempos: [Tempo]
    public let memories: [Memory]

    public init(jams: [Jam] = [], continuations: [Continuation] = [],
                forms: [Form] = [], tempos: [Tempo] = [], memories: [Memory] = []) {
        self.jams = jams; self.continuations = continuations
        self.forms = forms; self.tempos = tempos; self.memories = memories
    }
}

// MARK: - The planner

public enum SessionPlanner {

    // Fixed structure. These are constants rather than settings on purpose: the moment the
    // cold probe or the benchmark jam can be adjusted per session, the day-to-day comparison
    // they exist for stops being a comparison. Every confound already in this dataset — a
    // changed backing, a changed tempo — arrived exactly that way.
    public static let referenceBpm: Double = 100
    public static let coldRounds = 3
    public static let coldHoldBars = 4
    public static let benchmarkBars = 64
    public static let benchmarkTag = "benchmark"
    public static let closingTag = "closing"

    /// Rating plus the brief for the next block. Playing time alone would under-promise.
    public static let betweenBlockSeconds: Double = 25

    /// A closing jam shorter than this isn't worth the name.
    public static let minimumClosingBars = 16
    public static let maximumTrainingBlocks = 3
    public static let maximumClosingBlocks = 3

    /// Recent history means the last handful, not all of it. A drill fixed six weeks ago
    /// should not keep being scheduled because it once went badly.
    public static let recentWindow = 6

    /// How much drill a session of a given length can hold.
    ///
    /// A longer session buys **longer takes, not more of them.** There are only three
    /// training drills, so padding a 45-minute session with repeats would be filler — whereas
    /// a continuation drill with ten silences instead of six gives a materially better
    /// variance estimate, which is precisely what the unsettled clock/motor split needs. The
    /// rest of the time goes where the project actually points: playing.
    struct Sizes {
        let dropoutCycles: Int
        let formBars: Int
        let tempoRounds: Int
        /// The longest a single closing jam is allowed to get.
        ///
        /// Not the engine's 512-bar limit. `jamBacking` is two sections with a fill every
        /// eight bars, which sustains ten minutes and is hypnotic well before twenty — PLAN
        /// §6 names that as the thing that kills a long session, and real musical depth is
        /// M17. Past the cap the time goes into a *second* closing jam instead, which also
        /// gives two takes at different points in the evening: the within-session contrast
        /// `SessionPlacement.elapsedSeconds` exists to expose.
        let closingCapBars: Int
        /// Always even, so the silent and filled conditions stay balanced.
        let memoryRounds: Int

        init(targetMinutes: Int) {
            switch targetMinutes {
            case ..<25:  self = Sizes(dropoutCycles: 6, formBars: 64, tempoRounds: 8,
                                      closingCapBars: 160, memoryRounds: 6)
            case ..<40:  self = Sizes(dropoutCycles: 8, formBars: 96, tempoRounds: 12,
                                      closingCapBars: 224, memoryRounds: 8)
            default:     self = Sizes(dropoutCycles: 10, formBars: 128, tempoRounds: 16,
                                      closingCapBars: 256, memoryRounds: 10)
            }
        }

        private init(dropoutCycles: Int, formBars: Int, tempoRounds: Int,
                     closingCapBars: Int, memoryRounds: Int) {
            self.dropoutCycles = dropoutCycles; self.formBars = formBars
            self.tempoRounds = tempoRounds; self.closingCapBars = closingCapBars
            self.memoryRounds = memoryRounds
        }
    }

    public static func plan(targetMinutes: Int, from input: PlannerInput) -> SessionPlan {
        var notes: [String] = []
        var blocks: [SessionBlock] = [coldBlock(), warmUpBlock(), benchmarkBlock()]

        let sizes = Sizes(targetMinutes: targetMinutes)
        let budget = Double(targetMinutes) * 60
        // Reserve the closing jam's floor up front, so training blocks can never eat the
        // whole session and leave the player finishing on a drill.
        let closingFloor = BlockPlan.jam(JamPlan(bpm: referenceBpm, bars: minimumClosingBars,
                                                 tag: closingTag)).estimatedSeconds

        func spent(_ blocks: [SessionBlock]) -> Double {
            blocks.reduce(0) { $0 + $1.estimatedSeconds }
                + Double(max(0, blocks.count - 1)) * betweenBlockSeconds
        }

        func fits(_ candidate: SessionBlock) -> Bool {
            // + the gap before the closing jam, and the closing jam itself.
            spent(blocks + [candidate]) + betweenBlockSeconds + closingFloor <= budget
        }

        // Timing candidates compete with each other for all but one slot.
        for candidate in timingCandidates(from: input, sizes: sizes, notes: &notes) {
            guard blocks.filter({ $0.role == .training }).count < maximumTrainingBlocks - 1 else { break }
            if fits(candidate) { blocks.append(candidate) }
        }

        // Form gets the remaining slot outright rather than competing for it. It is the only
        // drill on the *other* axis — knowing where you are in the music, which is tens of
        // seconds, not milliseconds (§6.1) — so ranking it against the clock drills on their
        // evidence would drop it from every session the moment a clock drill had a reason.
        let form = formBlock(from: input, sizes: sizes, notes: &notes)
        if fits(form) { blocks.append(form) }

        // Whatever is left goes to closing jams, snapped to whole 8-bar phrases.
        //
        // Split **evenly** across as few blocks as the cap allows, rather than filling one to
        // the brim and leaving a runt: a 9-minute jam followed by a 1-minute one is not two
        // takes, it is one take and an apology. The session always ends on playing, even if
        // the only block that fits has to overrun a little.
        let barSeconds = 4 * 60 / referenceBpm
        let base = spent(blocks)
        var closing = (count: 1, bars: minimumClosingBars)
        for count in 1...maximumClosingBlocks {
            let available = budget - base - Double(count) * betweenBlockSeconds
            guard available > 0 else { break }
            let each = Int((available / (Double(count) * barSeconds)).rounded(.down)) - 2
            let snapped = (each / 8) * 8
            if snapped <= sizes.closingCapBars {
                closing = (count, max(minimumClosingBars, snapped))
                break
            }
            closing = (count, sizes.closingCapBars)     // still capped; try one more block
        }

        for index in 0..<closing.count {
            blocks.append(SessionBlock(
                role: .closing,
                plan: .jam(JamPlan(bpm: referenceBpm, bars: closing.bars, tag: closingTag)),
                reason: index == 0
                    ? "Finish by playing. Measured like any jam, but tagged apart from the "
                    + "benchmark — this one is played tired, and that difference is the point."
                    : "More playing, after a breather. Jams spread across the evening say more "
                    + "about how the pulse holds up than one long one would."))
        }

        if input.jams.isEmpty && input.continuations.isEmpty && input.forms.isEmpty
            && input.tempos.isEmpty && input.memories.isEmpty {
            notes.append("No history yet, so this is the standard opening session. From the "
                       + "second session on, the training blocks are chosen from what the data says.")
        }
        return SessionPlan(targetMinutes: targetMinutes, blocks: blocks, notes: notes)
    }

    // MARK: Fixed blocks

    private static func coldBlock() -> SessionBlock {
        SessionBlock(
            role: .cold,
            plan: .tempo(TempoPlan(targets: [referenceBpm], leadBars: 4,
                                   holdBars: coldHoldBars, rounds: coldRounds)),
            reason: "Cold, before anything warms up. Identical every session — \(coldRounds) rounds "
                  + "at \(Int(referenceBpm)) BPM — so today's cold start can be compared with "
                  + "the last one. Nothing here adapts.")
    }

    private static func warmUpBlock() -> SessionBlock {
        SessionBlock(
            role: .warmUp,
            plan: .groove(GroovePlan(bpm: referenceBpm, bars: 32)),
            reason: "Nothing measured. Play whatever you like and let the hands catch up.")
    }

    private static func benchmarkBlock() -> SessionBlock {
        SessionBlock(
            role: .benchmark,
            plan: .jam(JamPlan(bpm: referenceBpm, bars: benchmarkBars, tag: benchmarkTag)),
            reason: "Locked at \(Int(referenceBpm)) BPM and \(benchmarkBars) bars, in the same slot "
                  + "every session — warm but not yet tired. This is the take the trend is "
                  + "fitted to, so nothing about it is allowed to vary.")
    }

    // MARK: Training selection

    /// Beat-level candidates, most-needed first. The caller takes as many as fit.
    ///
    /// Form is deliberately not here — see `plan`.
    private static func timingCandidates(from input: PlannerInput, sizes: Sizes,
                                         notes: inout [String]) -> [SessionBlock] {
        var candidates: [SessionBlock] = []
        if let block = continuationBlock(from: input, sizes: sizes, notes: &notes) {
            candidates.append(block)
        }
        if let block = memoryBlock(from: input, sizes: sizes) { candidates.append(block) }
        if let block = tempoBlock(from: input, sizes: sizes) { candidates.append(block) }
        return candidates
    }

    /// The continuation drill is first whenever the clock/motor split is still unsettled.
    ///
    /// That split is the open question the whole training plan branches on (PLAN §7.9): a
    /// loose clock and noisy hands feel identical from the inside and need completely
    /// different work. Until it is answered, collecting the data that answers it beats
    /// training either half on a guess.
    private static func continuationBlock(from input: PlannerInput, sizes: Sizes,
                                          notes: inout [String]) -> SessionBlock? {
        let recent = Array(input.continuations.suffix(recentWindow))
        let reliable = recent.filter(\.splitIsReliable)
        let current = recent.last?.silentBars ?? 4

        guard reliable.count >= 3 else {
            let needed = 3 - reliable.count
            notes.append("The clock/motor split is still unsettled — \(reliable.count) of the last "
                       + "\(recent.count) continuation takes gave a trustworthy one. \(needed) more "
                       + "clean take(s) and the app can say which half is the weak one.")
            return SessionBlock(
                role: .training,
                plan: .dropout(DropoutPlan(bpm: referenceBpm, pacedBars: 4,
                                           silentBars: current, cycles: sizes.dropoutCycles)),
                reason: "Only \(reliable.count) of the last \(recent.count) continuation takes gave a "
                      + "trustworthy clock/motor split. Steady quarters, no subdividing — that is "
                      + "what makes a silence usable.")
        }

        // Settled: train whichever half the measurement says is looser.
        let clock = mean(reliable.compactMap(\.clockSDms))
        let motor = mean(reliable.compactMap(\.motorSDms))
        guard let clock, let motor else { return nil }

        if clock > motor {
            let harder = min(16, current * 2)
            return SessionBlock(
                role: .training,
                plan: .dropout(DropoutPlan(bpm: referenceBpm, pacedBars: 4,
                                           silentBars: harder, cycles: sizes.dropoutCycles)),
                reason: String(format: "Your clock is the looser half (%.1f ms against %.1f ms motor), "
                             + "so the silences go to %d bars. Longer alone is the way to load it.",
                               clock, motor, harder))
        }
        notes.append(String(format: "Motor noise is now the larger half (%.1f ms against %.1f ms "
                          + "clock). That changes the training target — evenness and dynamics "
                          + "rather than longer silences — and no drill for it exists yet.",
                            motor, clock))
        return nil
    }

    /// The recall drill, once the clock is known to be the weak half.
    ///
    /// The continuation drill loads the clock by making it run longer. This loads it a
    /// different way: by making the player *let go* of the period and pick it up again. A
    /// pulse that only survives while it is being produced is a different weakness from one
    /// that is genuinely unstable, and the two need different work — which is why this is a
    /// separate drill and not a longer silence.
    private static func memoryBlock(from input: PlannerInput, sizes: Sizes) -> SessionBlock? {
        let recentSplits = Array(input.continuations.suffix(recentWindow)).filter(\.splitIsReliable)
        let clock = mean(recentSplits.compactMap(\.clockSDms))
        let motor = mean(recentSplits.compactMap(\.motorSDms))
        // Only worth scheduling once the split says the clock is the problem. Before that it
        // would be training a weakness that has not been shown to exist.
        guard let clock, let motor, clock > motor else { return nil }

        let recent = Array(input.memories.suffix(recentWindow))
        let retention = recent.last.map {
            TempoMemoryAnalysis.suggestedRetentionBars(current: $0.retentionBars, clockSDms: clock)
        } ?? 4

        guard let last = recent.last else {
            return SessionBlock(
                role: .training,
                plan: .memory(MemoryPlan(bpm: referenceBpm, referenceBars: 4,
                                         retentionBars: retention, reproduceBars: 4,
                                         rounds: sizes.memoryRounds)),
                reason: String(format: "Your clock is the looser half (%.1f ms against %.1f ms "
                             + "motor). This asks whether the period is *stored* or only held "
                             + "by keeping it running — half the waits are silent, half are "
                             + "filled with unrelated percussion.", clock, motor))
        }

        if let cost = last.interferenceCost, cost > 1 {
            return SessionBlock(
                role: .training,
                plan: .memory(MemoryPlan(bpm: referenceBpm, referenceBars: 4,
                                         retentionBars: retention, reproduceBars: 4,
                                         rounds: sizes.memoryRounds)),
                reason: String(format: "Interference cost you %.1f points last time — the period "
                             + "goes when something else needs the attention. More rounds at a "
                             + "%d-bar wait.", cost, retention))
        }
        return SessionBlock(
            role: .training,
            plan: .memory(MemoryPlan(bpm: referenceBpm, referenceBars: 4,
                                     retentionBars: retention, reproduceBars: 4,
                                     rounds: sizes.memoryRounds)),
            reason: "The wait goes to \(retention) bars. The period survived the last one — "
                  + "the question is how long it keeps surviving.")
    }

    /// Tempo calibration, while the produced period is still off.
    private static func tempoBlock(from input: PlannerInput, sizes: Sizes) -> SessionBlock? {
        let recent = Array(input.tempos.suffix(recentWindow))
        guard let last = recent.last, let error = last.meanAbsErrorPercent else {
            return SessionBlock(
                role: .training,
                plan: .tempo(TempoPlan(targets: [referenceBpm], leadBars: 4, holdBars: 4,
                                       rounds: sizes.tempoRounds)),
                reason: "No tempo-calibration data yet. One target, eight rounds, to establish "
                      + "how far off the produced period is.")
        }

        if error >= 2 {
            return SessionBlock(
                role: .training,
                plan: .tempo(TempoPlan(targets: [referenceBpm], leadBars: 4, holdBars: 4,
                                       rounds: sizes.tempoRounds)),
                reason: String(format: "Last session you were %.1f%% off at a single target. Stay on "
                             + "one tempo until that comes under 2%%.", error))
        }

        // Accurate at one target is a lookup table, not a calibrated clock. Rotating is the
        // next rung, and it is a harder task — expect the error to go back up.
        if last.targetCount == 1 {
            return SessionBlock(
                role: .training,
                plan: .tempo(TempoPlan(targets: [76, referenceBpm, 132], leadBars: 4, holdBars: 4,
                                       rounds: (sizes.tempoRounds / 3) * 3)),
                reason: String(format: "You are within %.1f%% at %d BPM, so the target starts "
                             + "rotating — 76/100/132. A clock calibrated at one tempo is a lookup "
                             + "table; the mapping is the skill. Expect the error to rise at first.",
                               error, Int(referenceBpm)))
        }
        return nil      // rotating and accurate: nothing more this drill can teach today
    }

    /// Form is always available — it trains a different axis from everything above, so it
    /// never competes with them on evidence.
    private static func formBlock(from input: PlannerInput, sizes: Sizes,
                                  notes: inout [String]) -> SessionBlock {
        let recent = Array(input.forms.suffix(recentWindow))
        guard let last = recent.last else {
            return SessionBlock(
                role: .training,
                plan: .form(FormPlan(bpm: referenceBpm, bars: sizes.formBars, phraseBars: 8, level: 0)),
                reason: "No form data yet. Level 0, 8-bar phrases — a fill warns you and a crash "
                      + "confirms the downbeat you are marking.")
        }

        // A player who consistently marked a shorter period was not lost; they were feeling a
        // different phrase. Following the feel measures something, scoring it down measures
        // nothing.
        //
        // But following it on a *single* take makes the planner chase the player. It did
        // exactly that: an 8-bar setting where the player felt 4 moved the drill to 4, and the
        // next take at 4 — where they felt 8 — would have moved it straight back. The two
        // takes at 4 bars also disagreed wildly with each other (16/17 on form, then 5/14), so
        // one take is not evidence of a stable felt period at all.
        //
        // The rule now needs the two most recent takes to agree. That cannot oscillate on
        // noise, and when it does move, something real has been measured twice.
        let feltPeriods = recent.suffix(2).map { $0.markedEveryBars.map { Int($0.rounded()) } }
        if feltPeriods.count == 2, let latest = feltPeriods[1], let previous = feltPeriods[0],
           latest == previous, latest != last.phraseBars, [2, 4, 8, 16, 32].contains(latest) {
            return SessionBlock(
                role: .training,
                plan: .form(FormPlan(bpm: referenceBpm, bars: sizes.formBars, phraseBars: latest,
                                     level: last.level)),
                reason: "Both of your last two form takes marked a steady \(latest)-bar phrase "
                      + "against the \(last.phraseBars)-bar setting. Twice is a feel rather than "
                      + "a slip, so the drill follows it — \(latest)-bar phrases at level "
                      + "\(last.level).")
        }
        if let latest = feltPeriods.last ?? nil, latest != last.phraseBars,
           [2, 4, 8, 16, 32].contains(latest) {
            notes.append("Your last form take marked a steady \(latest)-bar phrase against the "
                       + "\(last.phraseBars)-bar setting, but the take before it did not agree. "
                       + "The phrase length stays put until two takes running say the same "
                       + "thing — chasing one take is how the setting started oscillating.")
        }

        if last.onFormRate >= 0.9 && !last.hasUnmarkedPhrases && last.level < 3 {
            let next = last.level + 1
            return SessionBlock(
                role: .training,
                plan: .form(FormPlan(bpm: referenceBpm, bars: sizes.formBars,
                                     phraseBars: last.phraseBars, level: next)),
                reason: String(format: "%.0f%% on form last time with nothing unmarked, so the "
                             + "landmarks thin out: level %d.", last.onFormRate * 100, next))
        }

        return SessionBlock(
            role: .training,
            plan: .form(FormPlan(bpm: referenceBpm, bars: sizes.formBars,
                                 phraseBars: last.phraseBars, level: last.level)),
            reason: String(format: "%.0f%% on form last time — stay at level %d until it is "
                         + "above 90%% with nothing unmarked.", last.onFormRate * 100, last.level))
    }

    private static func mean(_ x: [Double]) -> Double? {
        x.isEmpty ? nil : x.reduce(0, +) / Double(x.count)
    }
}
