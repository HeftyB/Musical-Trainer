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
    /// A take assigned to an experiment arm. Locked parameters, fixed slot — only the arm moves.
    case experiment
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

/// A generated backing a plan is asking for: which style, and the seed that rebuilds it.
///
/// **Deliberately not `GrooveCore.BackingIdentity`, and it cannot be.** `TimingCore` imports
/// `Foundation` and nothing else, `GrooveCore` depends on nothing at all (R1.1.3), and neither may
/// import the other — the planner decides what to practise from measured history and must not be
/// able to reach a pattern. So the plan carries the *identity* and `TrainerKit`, the one module
/// that sees both, resolves it into music. That is exactly the shape `Feel` and `Swing` already
/// have across the same boundary, down to there being one conversion and a test pinning the two
/// together.
///
/// **One optional value rather than two optional fields**, which is a change from §7.29 step 7 as
/// written: the plan there was `styleName: String?` beside `seed: UInt64?` with `init` refusing the
/// half-set case. A `precondition` cannot hold that line, because `Codable` bypasses `init` and a
/// stored manifest is decoded rather than constructed — so a file with one field and not the other
/// would have decoded into a plan nobody can replay. Making the pair a single value costs one type
/// and makes the illegal state unrepresentable instead of merely rejected.
///
/// A seed that could not rebuild its backing would make every take played over it unexplainable
/// (R1.2.2), which is why this is not optional bookkeeping.
public struct PlannedBacking: Codable, Equatable, Hashable {
    /// Lower-case and stable, matching `Style.name`. A raw `String` for the same reason
    /// `ExperimentAssignment.arm` and `SessionPlacement.role` are: renaming or retiring a style
    /// must never orphan a stored manifest, and the rename from `motown` to `pocket` has already
    /// happened once.
    public let style: String
    public let seed: UInt64

    public init(style: String, seed: UInt64) {
        self.style = style
        self.seed = seed
    }
}

public struct JamPlan: Codable, Equatable {
    public let bpm: Double
    public let bars: Int
    public let tag: String?
    /// The generated backing this block asks for, or `nil` for the fixed one.
    ///
    /// Named for what it is rather than `backing`, because `JamConfig` has a `backing` already —
    /// the *music* a config resolves to — and one word meaning both the request and the resolution
    /// is `LESSONS.md` shape 10 invited in on purpose. The two sides of the conversion share this
    /// name so the seam reads the same from either end.
    ///
    /// **`nil` is the identity here, and that is the opposite of `rung` two fields down.** Every
    /// plan ever written meant the fixed `jamBacking`, so an absent value describes them exactly
    /// rather than standing in for something nobody chose. `rung`'s absence means *no rung was
    /// prescribed* and is emphatically not quarters. `LESSONS.md` shape 13 says decide which kind
    /// each optional is and write the reason beside the field; this is that decision.
    ///
    /// **Every locked slot leaves it `nil` for ever** (R3.5). A generated backing in the cold
    /// probe, the benchmark or an experiment arm would be a perfectly good take that had quietly
    /// left the series it exists to extend, and no readout would say so — which is why the guard
    /// is three-deep rather than a comment. See §7.29 step 7.
    public let generatedBacking: PlannedBacking?
    /// The subdivision the player is asked to produce, or `nil` for free playing.
    ///
    /// **`nil` is not "quarters".** It means no rung was prescribed at all — play whatever you
    /// like — which is what every take on record is and what the benchmark and the experiment
    /// blocks must stay, because a prescribed rung is a different task and R3.5 locks those
    /// slots. Optional rather than defaulted for exactly that reason: a default would silently
    /// convert the trend's own slot into a drill.
    public let rung: IntervalRung?
    /// How the division is placed. Straight is the identity, so a plan that says nothing about
    /// feel is a straight plan — unlike `rung`, where saying nothing means no rung at all.
    ///
    /// Stored as the ratio rather than a `Feel` so an old plan still decodes; `feel` rebuilds it.
    public let swingRatio: Double?
    /// The offbeat drill's level, when this block is one. Raw so a new level never orphans a plan.
    public let offbeatLevel: Int?

    public init(bpm: Double, bars: Int, tag: String?, rung: IntervalRung? = nil,
                feel: Feel = .straight, offbeatLevel: Int? = nil,
                generatedBacking: PlannedBacking? = nil) {
        self.bpm = bpm; self.bars = bars; self.tag = tag; self.rung = rung
        self.swingRatio = feel.isStraight ? nil : feel.swingRatio
        self.offbeatLevel = offbeatLevel
        self.generatedBacking = generatedBacking
    }

    public var feel: Feel { swingRatio.flatMap { Feel(swingRatio: $0) } ?? .straight }
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
    /// The note value asked for through the silences.
    ///
    /// Set to `.quarters` by the planner rather than left `nil`, and that is not a change of
    /// task: the drill's instructions have demanded one note per beat since M6. What changes is
    /// that the analysis is now *told* rather than inferring it from what was played and
    /// snapping to the nearest whole number — a snap that inverts the sign of the tempo error
    /// when the player lands between note values (§7.23 step 4e).
    public let rung: IntervalRung?

    public init(bpm: Double, pacedBars: Int, silentBars: Int, cycles: Int,
                rung: IntervalRung? = nil) {
        self.bpm = bpm; self.pacedBars = pacedBars; self.silentBars = silentBars
        self.cycles = cycles; self.rung = rung
    }
}

public struct TempoPlan: Codable, Equatable {
    public let targets: [Double]
    public let leadBars: Int
    public let holdBars: Int
    public let rounds: Int
    /// The note value asked for during each hold. See `DropoutPlan.rung`.
    public let rung: IntervalRung?

    public init(targets: [Double], leadBars: Int, holdBars: Int, rounds: Int,
                rung: IntervalRung? = nil) {
        self.targets = targets; self.leadBars = leadBars; self.holdBars = holdBars
        self.rounds = rounds; self.rung = rung
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
        case .jam(let p):
            let rung = p.rung.map { " · \($0.label)" } ?? ""
            let feel = p.feel.isStraight ? "" : " · \(p.feel.label)"
            // The band belongs here beside the rung, and here rather than in either front end:
            // this is the one mapping from a plan to its summary line, so the app's session view
            // and the console's plan preview cannot describe the same block differently. The
            // *reason* explains the choice; this is what it is, at a glance.
            let band = p.generatedBacking.map { " · \($0.style)" } ?? ""
            return "\(Int(p.bpm)) BPM · \(p.bars) bars\(rung)\(feel)\(band)"
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
    /// The experiment this block belongs to, if any — for messages that name it.
    public var experimentName: String? { experiment?.name }
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
        /// The style this take was played over, or `nil` for the fixed backing — which is every
        /// take recorded before M19. Carried so the planner can rotate away from what has been
        /// played most, and a raw name because `TimingCore` cannot see `GrooveCore` (R1.1.3).
        public let style: String?
        public init(bpm: Double, sdMs: Double, absBiasMs: Double, lag1: Double?,
                    style: String? = nil) {
            self.bpm = bpm; self.sdMs = sdMs; self.absBiasMs = absBiasMs; self.lag1 = lag1
            self.style = style
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
        /// True when this take was a `probe` — a level run for the reading, not one the player
        /// earned. Excluded from everything that decides where the ladder currently stands.
        public let wasProbe: Bool
        public init(level: Int, phraseBars: Int, onFormRate: Double,
                    hasUnmarkedPhrases: Bool, markedEveryBars: Double?, wasProbe: Bool = false) {
            self.level = level; self.phraseBars = phraseBars; self.onFormRate = onFormRate
            self.hasUnmarkedPhrases = hasUnmarkedPhrases; self.markedEveryBars = markedEveryBars
            self.wasProbe = wasProbe
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

    /// A take played at a prescribed rung. Free jams are `Jam`s and never appear here.
    public struct Ladder: Equatable {
        public let bpm: Double
        public let rung: IntervalRung
        public let sdMs: Double
        public init(bpm: Double, rung: IntervalRung, sdMs: Double) {
            self.bpm = bpm; self.rung = rung; self.sdMs = sdMs
        }
    }

    /// What each experiment has collected so far, oldest-first: the arm of every take already
    /// assigned to it. That is all the scheduler needs — balance and counterbalancing are both
    /// functions of the arms already run.
    public struct Experiment: Equatable {
        public let name: String
        public let completedArms: [String]
        public init(name: String, completedArms: [String]) {
            self.name = name; self.completedArms = completedArms
        }
    }

    /// All oldest-first, matching `SessionStore`.
    public let jams: [Jam]
    public let continuations: [Continuation]
    public let forms: [Form]
    public let tempos: [Tempo]
    public let memories: [Memory]
    public let experiments: [Experiment]
    public let ladders: [Ladder]
    /// The styles the planner may schedule: names only, and **only the approved ones**.
    ///
    /// The filtering happens where the library lives, so this module cannot reach past the gate
    /// even by mistake — `TimingCore` has no way to see a `Style`, let alone its flag. Empty is
    /// the correct answer for a library nobody has approved, and the planner falls back to the
    /// fixed backing rather than reaching for one (§7.29 step 5).
    public let auditionedStyles: [String]

    public init(jams: [Jam] = [], continuations: [Continuation] = [],
                forms: [Form] = [], tempos: [Tempo] = [], memories: [Memory] = [],
                experiments: [Experiment] = [], ladders: [Ladder] = [],
                auditionedStyles: [String] = []) {
        self.jams = jams; self.continuations = continuations
        self.forms = forms; self.tempos = tempos; self.memories = memories
        self.experiments = experiments; self.ladders = ladders
        self.auditionedStyles = auditionedStyles
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
    public static let maximumTrainingBlocks = 4
    public static let maximumClosingBlocks = 3

    // MARK: The interval ladder

    /// The tempos a ladder block rotates through.
    ///
    /// Spread out on purpose. §7.23 step 3 refuses to fit until three intervals carry two takes
    /// each, and four takes at one tempo six minutes apart bought almost nothing — one take per
    /// tempo per sitting, rotated, is what gets there. The benchmark stays at 100 forever
    /// regardless (R3.5); this is the block that was *designed* to vary.
    public static let ladderTempos: [Double] = [80, 100, 120, 140]

    /// Locked, like the benchmark's, so a ladder take is comparable to the last one at its rung.
    public static let ladderBars = 32

    /// The rung the planner starts the ladder on, and never goes below.
    ///
    /// **Eighths, not quarters**, and the first live session is what settled it. Five of that
    /// session's nine blocks asked for one note per beat — the cold probe, the continuation
    /// drill, the recall drill's reproduction, the experiment's `steady` arm and the ladder at
    /// quarters — and three of its four jams played over the same backing. The player lost
    /// track of which drill he was in, which is the correct response to a session that asks for
    /// the same physical action five times and distinguishes the asks by metadata nobody can
    /// hear.
    ///
    /// Quarters is also the wrong rung to *start* on. `LadderBackings.eighths` is the same
    /// skeleton as `basicRock`, which every take on record has played over, so it is the least
    /// novel backing in the set — while quarters is the sparsest and the one that duplicates
    /// those five blocks. The one-step promotion rule exists to keep the player off a backing
    /// nobody has heard (R5.6), and eighths satisfies it outright.
    ///
    /// Quarters is still reachable by hand from either surface. It is only the *planner* that
    /// will not choose it.
    public static let ladderFloorRung: IntervalRung = .eighths

    /// Ladder takes at a rung before that rung's own spread is trusted over the overall figure.
    ///
    /// The ceiling is derived from the player's spread, and §7.23 step 3b measured that spread
    /// to be interval-invariant — so the overall median is a sound starting estimate for a rung
    /// never played. One take at a rung is not a reason to overrule it: a bad first evening
    /// would lower that rung's ceiling and lock the player out of tempos they can handle.
    public static let minimumTakesForRungSpread = 2

    /// Spread assumed for a player with no takes at all, matching `IntervalRung`'s worked table.
    public static let assumedSpreadMs = 20.0

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

        // The experiment take goes immediately after the benchmark, in a fixed slot, at the
        // benchmark's own locked settings. Both halves are R3.5.
        //
        // Locked parameters, because an experiment whose tempo or length moved between arms
        // would be comparing those instead. And a *fixed slot*, because the alternative — the
        // block landing wherever it fits — would let the arm correlate with how far into the
        // evening it ran, and §7.17 has two takes identical on every number rated 4 and 1
        // twenty minutes apart. With the slot fixed, the arm alternates across sittings and
        // position is held constant; `ExperimentAnalysis` checks that it worked.
        if let block = experimentBlock(from: input) {
            if fits(block) { blocks.append(block) } else {
                notes.append("No room for the \(block.experimentName ?? "experiment") take in "
                           + "\(targetMinutes) minutes. It runs at the benchmark's locked "
                           + "settings and cannot be shortened to fit, so a longer session is "
                           + "what it needs.")
            }
        }

        // Timing candidates compete with each other for the slots the two reserved ones leave —
        // the ladder and form each take one outright, for the reasons given below.
        let reservedSlots = 2
        for candidate in timingCandidates(from: input, sizes: sizes, notes: &notes) {
            guard blocks.filter({ $0.role == .training }).count
                    < maximumTrainingBlocks - reservedSlots else { break }
            if fits(candidate) { blocks.append(candidate) }
        }

        // Form gets a slot outright rather than competing for it. It is the only drill on the
        // *other* axis — knowing where you are in the music, which is tens of seconds, not
        // milliseconds (§6.1) — so ranking it against the clock drills on their evidence would
        // drop it from every session the moment a clock drill had a reason.
        let form = formBlock(from: input, sizes: sizes, notes: &notes)
        if fits(form) { blocks.append(form) }

        // The ladder gets a slot outright too, for a matching reason: it is on a *third* axis.
        // The clock drills measure how steadily a pulse is held; form measures knowing where you
        // are in the music; this measures how the gap between notes changes both, and nothing
        // else in the app varies it. Ranked against the clock drills on their evidence it would
        // never be scheduled — the split is settled and the clock is the looser half, so those
        // two candidates fill every slot they are offered.
        //
        // **After form, and that ordering is load-bearing.** Both take a slot outright, so in a
        // session too short for both the one appended second is the one that goes. Adding the
        // ladder ahead of form silently dropped form from every 20-minute session — §7.16's
        // regression exactly, on a new cause, and it survived the first version of the test that
        // exists to catch it because that test only ran at 30 minutes. Form has the older claim
        // and the explicit guard; the ladder is the one that waits for a longer evening.
        let ladder = ladderBlock(from: input)
        if fits(ladder) { blocks.append(ladder) } else {
            notes.append("No room for an interval-ladder take in \(targetMinutes) minutes. It is "
                       + "the only block that varies the gap between notes, and `review interval` "
                       + "stays a refusal until three intervals carry two takes each — a longer "
                       + "session is what it needs.")
        }

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

        // **The one slot in a planned session that gets a band.**
        //
        // §7.29's table says training blocks and the closing jam get deep music, and in practice
        // the closing jam is the only *free* jam a session contains: the ladder training block
        // carries a rung, and a rung and a style are two backings that cannot both play — the
        // ladder groove exists to make its division audible and a style does not. Everything else
        // is another drill entirely.
        //
        // One style and one seed for every closing block in the plan, so an evening sounds like
        // one evening (§7.29). `nil` when nothing is approved, and then this is `jamBacking`,
        // which is what every take on record already played over.
        let band = Self.nextStyle(from: input).map {
            PlannedBacking(style: $0, seed: Self.sittingSeed(from: input))
        }
        for index in 0..<closing.count {
            blocks.append(SessionBlock(
                role: .closing,
                plan: .jam(JamPlan(bpm: referenceBpm, bars: closing.bars, tag: closingTag,
                                   generatedBacking: band)),
                reason: (index == 0
                    ? "Finish by playing. Measured like any jam, but tagged apart from the "
                    + "benchmark — this one is played tired, and that difference is the point."
                    : "More playing, after a breather. Jams spread across the evening say more "
                    + "about how the pulse holds up than one long one would.")
                    // A session that cannot say what it is about to play is one the player has no
                    // way to disagree with, which is what every other `reason` here exists for.
                    // The seed is named too: it is the only route back to this exact piece.
                    + (band.map {
                        " Tonight the band is \($0.style), one piece all evening — "
                        + String(format: "%@@%016llx.", $0.style, $0.seed)
                      } ?? "")))
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
                                   holdBars: coldHoldBars, rounds: coldRounds,
                                   rung: .quarters)),
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

    /// The active experiment's next take, or nothing when every experiment is finished.
    ///
    /// The arm comes from `ExperimentSchedule`, so it is balanced and counterbalanced against
    /// what has already been run rather than chosen here.
    private static func experimentBlock(from input: PlannerInput) -> SessionBlock? {
        var finished: [String: Bool] = [:]
        for e in input.experiments {
            guard let design = ExperimentLibrary.all.first(where: { $0.name == e.name }) else { continue }
            finished[e.name] = ExperimentSchedule.progress(design: design,
                                                           completed: e.completedArms).hasPower
        }
        guard let design = ExperimentLibrary.active(progressByName: finished) else { return nil }

        let completed = input.experiments.first { $0.name == design.name }?.completedArms ?? []
        let assignment = ExperimentSchedule.assignment(design: design, completed: completed)
        let progress = ExperimentSchedule.progress(design: design, completed: completed)

        // The arm's own tempo when tempo is the condition, the benchmark's otherwise. Everything
        // else stays locked either way: exactly one thing may differ between arms (R3.5).
        let bpm = design.bpm(forArm: assignment.arm) ?? referenceBpm
        let held = design.variesTempo
            ? "Same length, same backing and the same free playing as the benchmark — the tempo "
            + "is the one thing that changes between arms."
            : "Same tempo, same length and same backing as the benchmark — the only thing that "
            + "changes between arms is what you are asked to play."

        return SessionBlock(
            role: .experiment,
            plan: .jam(JamPlan(bpm: bpm, bars: benchmarkBars, tag: design.name)),
            reason: "\(design.question) Today's take is the **\(assignment.arm)** arm"
                  + (design.variesTempo ? ", at \(Int(bpm)) BPM. " : ". ")
                  + held + " \(progress.takesRemaining) take(s) to go before anything is "
                  + "compared.",
            experiment: assignment)
    }

    // MARK: The interval ladder

    /// One take at a rotated tempo and the hardest rung that tempo can score honestly.
    ///
    /// **Tempo first, rung second, and they are one decision.** Step 1 derived a tempo ceiling
    /// per rung from the matching window, so a rung picked before the tempo could be illegal by
    /// the time the tempo arrives — at 140 BPM only quarters and eighths can be scored at this
    /// player's spread. Choosing in this order means the ceiling constrains rather than
    /// contradicts.
    ///
    /// This block and this block alone varies tempo. The benchmark, the experiment take and the
    /// cold probe are all locked at the reference (R3.5), because every confound already in this
    /// dataset arrived by a parameter changing between takes.
    static func ladderBlock(from input: PlannerInput) -> SessionBlock {
        let bpm = nextLadderTempo(from: input.ladders)
        let rung = nextRung(atBpm: bpm, from: input)
        let spread = spreadEstimate(for: rung, from: input)
        let ceiling = rung.maximumBpm(forSpreadMs: spread)

        let why: String
        if let highest = highestRungPlayed(input.ladders), rung != highest {
            why = "Up a rung from the \(highest.label) you have on record. "
        } else if input.ladders.isEmpty {
            why = "The first rung of the ladder, and the first take that asks for a subdivision. "
        } else {
            let held = ceiling < 260
                ? "this tempo cannot honestly score a finer one"
                : "the rung above needs a take at this one first"
            why = "The same rung again — \(held). "
        }

        return SessionBlock(
            role: .training,
            plan: .jam(JamPlan(bpm: bpm, bars: ladderBars, tag: "ladder", rung: rung)),
            reason: why + String(format: "%d BPM asks for a %.0f ms gap between notes, and the "
                               + "tempo rotates between sittings so the interval actually varies "
                               + "— four takes at one tempo say almost nothing about it. Scored "
                               + "against %@, whose ceiling here is %.0f BPM at your %.1f ms "
                               + "spread.",
                                 Int(bpm), rung.intervalSeconds(atBpm: bpm) * 1000,
                                 rung.label, ceiling, spread))
    }

    /// The least-used tempo in the rotation, ties broken by a seeded draw.
    ///
    /// Min-count rather than a cycle, for the reason `ExperimentSchedule` uses it: a strict
    /// rotation puts each tempo at a fixed position in the sequence, so anything that varies
    /// with *where in a run* a take falls lands entirely on one tempo. Min-count keeps them
    /// within one of each other and still shuffles the order.
    static func nextLadderTempo(from ladders: [PlannerInput.Ladder]) -> Double {
        var counts = [Int](repeating: 0, count: ladderTempos.count)
        for take in ladders {
            if let i = ladderTempos.firstIndex(where: { abs($0 - take.bpm) < 0.5 }) { counts[i] += 1 }
        }
        let fewest = counts.min() ?? 0
        let candidates = ladderTempos.indices.filter { counts[$0] == fewest }
        var rng = SplitMix64(seed: 0x1A44E4 &+ UInt64(ladders.count))
        return ladderTempos[candidates[Int(rng.next() % UInt64(candidates.count))]]
    }

    /// The style the closing jam plays, rotated between sittings.
    ///
    /// Min-count over what has been played, exactly as `nextLadderTempo` does and for the same
    /// reason: a strict cycle puts each style at a fixed position in the sequence, so anything
    /// that varies with *where in a run* a take falls lands entirely on one style. Ties are broken
    /// by a seeded draw (R1.2.1), so the order still shuffles.
    ///
    /// `nil` when nothing has been approved, and the closing jam then plays the fixed backing —
    /// which is what every take on record already used, so an empty library costs nothing.
    static func nextStyle(from input: PlannerInput) -> String? {
        let candidates = input.auditionedStyles.sorted()
        guard !candidates.isEmpty else { return nil }
        var counts = [Int](repeating: 0, count: candidates.count)
        for jam in input.jams {
            if let style = jam.style, let i = candidates.firstIndex(of: style) { counts[i] += 1 }
        }
        let fewest = counts.min() ?? 0
        let tied = candidates.indices.filter { counts[$0] == fewest }
        var rng = SplitMix64(seed: 0x5B1A_11E5 &+ UInt64(input.jams.count))
        return candidates[tied[Int(rng.next() % UInt64(tied.count))]]
    }

    /// One seed for the whole sitting, so an evening has a single musical identity and the next
    /// evening is new (§7.29's settled decisions).
    ///
    /// Derived from the history rather than drawn from a clock, because the planner is pure — a
    /// plan that read the time could not be tested, and R1.1.4 forbids it outright. Two plans
    /// built from one history are the same plan, which is also what makes `session plan` an honest
    /// preview of `session`.
    static func sittingSeed(from input: PlannerInput) -> UInt64 {
        var rng = SplitMix64(seed: 0x5EED_5177 &+ UInt64(input.jams.count))
        return rng.next()
    }

    /// The hardest rung that is both scorable at this tempo and one step from what has been played.
    ///
    /// Two gates, and they exist for different reasons. The **ceiling** is a measurement problem:
    /// above it the matching window is worth fewer than three of the player's own spreads and
    /// notes they aimed correctly get discarded, so the off-grid rate becomes a property of the
    /// rung (§7.23 step 1). The **one-step rule** is a live-run problem: no rung above eighths
    /// has ever been played, and whether a groove is playable-along-to is not something its step
    /// list can answer (R5.6). Promoting two rungs at once would put the player on a backing
    /// nobody has heard at a tempo nobody has tried.
    static func nextRung(atBpm bpm: Double, from input: PlannerInput) -> IntervalRung {
        // One step up from the highest played, but never below the floor.
        let order = IntervalRung.ladder
        let climbed = highestRungPlayed(input.ladders).map { $0.harder ?? $0 }
        let reachable = (order.firstIndex(of: climbed ?? ladderFloorRung) ?? 0)
                      >= (order.firstIndex(of: ladderFloorRung) ?? 0)
            ? (climbed ?? ladderFloorRung) : ladderFloorRung

        // Walk down from the reachable rung to the first that this tempo can score.
        for rung in IntervalRung.ladder.reversed()
        where IntervalRung.ladder.firstIndex(of: rung) ?? 0
              <= IntervalRung.ladder.firstIndex(of: reachable) ?? 0 {
            if rung.isScorable(atBpm: bpm, spreadMs: spreadEstimate(for: rung, from: input)) {
                return rung
            }
        }
        // Nothing at or below the reachable rung can be scored at this tempo, which only
        // happens for a very loose player at a fast one. Quarters has the highest ceiling of
        // all, so it is the honest floor here even though the planner never *starts* there.
        return .quarters
    }

    private static func highestRungPlayed(_ ladders: [PlannerInput.Ladder]) -> IntervalRung? {
        ladders.map(\.rung).max { a, b in
            (IntervalRung.ladder.firstIndex(of: a) ?? 0) < (IntervalRung.ladder.firstIndex(of: b) ?? 0)
        }
    }

    /// The spread the ceiling is computed against: this rung's own once it has enough takes,
    /// otherwise the player's overall figure.
    ///
    /// Step 3b measured absolute spread to be interval-invariant for this player, which is what
    /// makes the overall figure a sound estimate for a rung never played. Preferring the rung's
    /// own once it exists is the part that self-corrects if that stops being true.
    static func spreadEstimate(for rung: IntervalRung, from input: PlannerInput) -> Double {
        let atRung = input.ladders.filter { $0.rung == rung }.map(\.sdMs).filter { $0 > 0 }
        if atRung.count >= minimumTakesForRungSpread, let median = median(atRung) { return median }
        let recent = Array(input.jams.suffix(recentWindow)).map(\.sdMs).filter { $0 > 0 }
        return median(recent) ?? assumedSpreadMs
    }

    private static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
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
                                           silentBars: current, cycles: sizes.dropoutCycles,
                                           rung: .quarters)),
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
                                           silentBars: harder, cycles: sizes.dropoutCycles,
                                           rung: .quarters)),
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
                                       rounds: sizes.tempoRounds, rung: .quarters)),
                reason: "No tempo-calibration data yet. One target, eight rounds, to establish "
                      + "how far off the produced period is.")
        }

        if error >= 2 {
            return SessionBlock(
                role: .training,
                plan: .tempo(TempoPlan(targets: [referenceBpm], leadBars: 4, holdBars: 4,
                                       rounds: sizes.tempoRounds, rung: .quarters)),
                reason: String(format: "Last session you were %.1f%% off at a single target. Stay on "
                             + "one tempo until that comes under 2%%.", error))
        }

        // Accurate at one target is a lookup table, not a calibrated clock. Rotating is the
        // next rung, and it is a harder task — expect the error to go back up.
        if last.targetCount == 1 {
            return SessionBlock(
                role: .training,
                plan: .tempo(TempoPlan(targets: [76, referenceBpm, 132], leadBars: 4, holdBars: 4,
                                       rounds: (sizes.tempoRounds / 3) * 3, rung: .quarters)),
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
        // **Probes are filtered before anything reads the ladder**, not after. A level the
        // player was handed for one take is not a level they reached, and every rule below —
        // the felt-period rule, the promotion gate, and the fallback that holds position — asks
        // "where are they now" (§7.26).
        let earned = input.forms.filter { !$0.wasProbe }
        let recent = Array(earned.suffix(recentWindow))
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
