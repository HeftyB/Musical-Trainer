import Foundation
import GrooveCore
import SwiftUI
import TimingCore
import TrainerKit

@MainActor
final class AppModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case jam, offbeat, form, dropout, tempo, memory, groove
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jam: return "Jam"
            case .offbeat: return "Offbeat"
            case .form: return "Form"
            case .dropout: return "Alone"
            case .tempo: return "Tempo"
            case .memory: return "Recall"
            case .groove: return "Play"
            }
        }
        var symbol: String {
            switch self {
            case .jam: return "waveform"
            case .offbeat: return "chart.bar.xaxis"
            case .form: return "square.grid.3x3"
            case .dropout: return "speaker.slash"
            case .tempo: return "metronome"
            case .memory: return "brain.head.profile"
            case .groove: return "play.circle"
            }
        }
        /// Full instructions, shared with the console so the two can't describe a drill
        /// differently. The form drill's text depends on the level — the landmarks it
        /// describes are exactly what the ladder removes.
        func instructions(formLevel: Int = 0, rung: IntervalRung? = nil,
                          offbeatLevel: OffbeatLevel = .stated) -> DrillInstructions {
            switch self {
            case .jam: return .jam(rung: rung)
            case .offbeat: return .offbeat(level: offbeatLevel)
            case .form: return .form(level: formLevel)
            case .dropout: return .dropout(rung: rung ?? .quarters)
            case .tempo: return .tempo(rung: rung ?? .quarters)
            case .memory: return .memory
            case .groove: return .groove
            }
        }

        var blurb: String {
            switch self {
            case .jam: return "Play along and measure how you place the beat."
            case .offbeat: return "Hold the chop between the beats while the downbeat disappears."
            case .form: return "Mark the top of each phrase without counting."
            case .dropout: return "Hold quarter notes through the silences — is it your clock or your hands?"
            case .tempo: return "Produce a tempo unaccompanied and find out what you actually played."
            case .memory: return "Hear a tempo, let go of it, then get it back — stored, or just running?"
            case .groove: return "Just the backing. Nothing measured."
            }
        }
    }

    /// Rating comes between the take and the results on purpose: a rating shown after the
    /// numbers would just echo them.
    enum Screen {
        case setup, running, rating, results, history
        /// M9: pick a length and read what the app proposes, before committing the evening.
        case sessionPlan
        /// Between blocks — what is next and why. The only readable screen in a session.
        case sessionBrief
        /// Every number from the session, all at the end.
        case sessionDebrief
    }

    @Published var screen: Screen = .setup
    @Published var mode: Mode = .jam { didSet { adoptDefaultLength(for: mode) } }

    @Published var bpm: Double = 100
    @Published private(set) var bars: Int = 32
    @Published var tag: String = ""
    /// The subdivision to ask for, or `nil` for free playing.
    ///
    /// `nil` is the default and it is not "quarters": free playing prescribes nothing, which is
    /// what every take on record is. Applies to Jam, Alone and Tempo — the three drills whose
    /// analysis is scored against a note value (§7.23 steps 4b and 4e).
    @Published var rung: IntervalRung? { didSet { clampFeelToRung(); clampBandToRung() } }
    /// How the division is placed. Straight is the identity, so this needs no "none" case.
    ///
    /// Jam only. The continuation drill refuses a swing outright — Wing–Kristofferson needs an
    /// isochronous series and a swung one alternates by design (see `DropoutConfig.feel`).
    @Published var swingRatio: Double = 1
    /// The band, by name, or `nil` for the fixed backing every take on record played over.
    ///
    /// **Only the approved styles are offered**, because `bandChoices` reads
    /// `StyleLibrary.auditioned` — the same list the planner gets, and the same reason: a style
    /// nobody has played over is one nothing may promote you onto (§7.29 step 5). The CLI can
    /// reach an unapproved one with `--probe`; the app deliberately cannot, because a picker is
    /// not a deliberate look at something unearned.
    ///
    /// Jam and Play only. A rung and a style are two backings and cannot both play, so choosing a
    /// band clears the rung — see `clampRungToBand`.
    @Published var band: String? { didSet { clampRungToBand() } }
    /// Drawn once when a band is chosen so the take is reproducible from what is stored (R1.2.2),
    /// and re-drawn whenever the band changes so two takes in a row are two pieces of music.
    @Published private(set) var bandSeed: UInt64 = 0
    @Published var phraseBars: Int = 8 { didSet { setBars(bars) } }
    @Published var formLevel: FormLevel = .fillAndAccent

    // Offbeat drill.
    @Published var offbeatLevel: OffbeatLevel = .stated

    /// The tempo the offbeat drill starts at, and it is not the app's usual 100.
    ///
    /// At 100 BPM the chop sits 300 ms from the beat either side and the feel inverted: 23% of
    /// notes off the beat, against 96% at 69 (§7.38). The rate is not what changes with tempo —
    /// an offbeat take is one note per beat either way — it is that each note must land at the
    /// midpoint of an interval whose endpoints are not being played. Faster is still reachable
    /// by asking, because ska and punk live up there.
    static let defaultOffbeatBpm: Double = 70

    // Dropout drill.
    @Published var pacedBars: Int = 4
    @Published var silentBars: Int = 4
    @Published var cycles: Int = 6

    // Recall drill.
    @Published var retentionBars: Int = 4
    @Published var memoryRounds: Int = 8

    // Tempo calibration.
    @Published var tempoTargets: [Double] = [100]
    @Published var tempoRounds: Int = 8
    @Published var holdBars: Int = 4

    /// Form takes default longer than jams: at 8-bar phrases, 32 bars yields only four
    /// phrases and five marks, which is too few to tell a real slip from noise.
    private let defaultFormBars = 64

    /// Snap the take length to a sensible granularity — and in the form drill to a whole
    /// number of phrases, so the last phrase is never cut off mid-way.
    func setBars(_ value: Int) {
        let granularity = mode == .form ? phraseBars : 4
        let snapped = max(granularity, Int((Double(value) / Double(granularity)).rounded()) * granularity)
        bars = min(192, snapped)
    }

    /// Entering the form drill from a short jam length would silently give an
    /// underpowered take, so bump to the form default the first time.
    private func adoptDefaultLength(for mode: Mode) {
        if mode == .form, bars < defaultFormBars { setBars(defaultFormBars) } else { setBars(bars) }
        // Entering the offbeat drill at the app's usual 100 hands the player the tempo that
        // inverted the feel (§7.38). Only on the way in, and only from the default, so a tempo
        // deliberately chosen is never overwritten.
        if mode == .offbeat, bpm == 100 { bpm = Self.defaultOffbeatBpm }
    }

    @Published private(set) var environment: TrainerEngine.Environment?
    @Published private(set) var environmentError: String?
    @Published var errorMessage: String?

    @Published private(set) var jamOutcome: TrainerEngine.JamOutcome?
    @Published private(set) var formOutcome: TrainerEngine.FormOutcome?
    @Published private(set) var dropoutOutcome: TrainerEngine.DropoutOutcome?
    @Published private(set) var tempoOutcome: TrainerEngine.TempoOutcome?
    @Published private(set) var memoryOutcome: TrainerEngine.MemoryOutcome?
    @Published var feelRating: Int?

    /// Rounds scored so far in a running tempo drill.
    ///
    /// The take screen is otherwise deliberately blank, but this drill *is* a feedback loop —
    /// produce, be told, correct, produce again — so withholding the number until the end
    /// would remove the mechanism rather than protect it. Feedback also arrives during the
    /// click bars, never while a measured silence is in progress.
    @Published private(set) var liveRounds: [TempoRoundResult] = []

    /// Set while a take is being torn down, so the button can acknowledge the press
    /// immediately rather than appearing to do nothing for a few milliseconds.
    @Published private(set) var isStopping = false
    private var cancellation: CancellationFlag?

    /// Abandon the running take. The recording is discarded, not analysed: a take stopped
    /// because something was wrong is not worth measuring, and saving a fragment would
    /// quietly pollute the history and the pooled condition stats.
    func stopTake() {
        guard screen == .running else { return }
        isStopping = true
        cancellation?.cancel()
    }

    init() { refreshEnvironment() }

    func refreshEnvironment() {
        do {
            environment = try TrainerEngine.environment()
            environmentError = nil
        } catch {
            environment = nil
            environmentError = error.localizedDescription
        }
    }

    var estimatedDuration: Double {
        switch mode {
        case .jam:    return TrainerEngine.JamConfig(bpm: bpm, bars: bars, rung: rung).durationSeconds
        case .offbeat: return offbeatConfig.durationSeconds
        case .form:   return TrainerEngine.FormConfig(bpm: bpm, bars: bars, phraseBars: phraseBars,
                                                      level: formLevel).durationSeconds
        case .dropout: return dropoutConfig.durationSeconds
        case .tempo: return tempoConfig.durationSeconds
        case .memory: return memoryConfig.durationSeconds
        case .groove: return TrainerEngine.GrooveConfig(bpm: bpm, bars: bars).durationSeconds
        }
    }

    var phraseCount: Int { max(1, bars / max(1, phraseBars)) }

    var tempoConfig: TrainerEngine.TempoConfig {
        // These two default to quarters rather than to nothing: both drills have asked for one
        // note per beat in words since M6 and M8, and leaving it unset would make the analysis
        // infer what the instructions already state (§7.23 step 4e).
        TrainerEngine.TempoConfig(targets: tempoTargets, leadBars: 4,
                                  holdBars: holdBars, rounds: tempoRounds,
                                  rung: rung ?? .quarters)
    }

    var memoryConfig: TrainerEngine.MemoryConfig {
        TrainerEngine.MemoryConfig(bpm: bpm, referenceBars: 4, retentionBars: retentionBars,
                                   reproduceBars: 4, rounds: memoryRounds)
    }

    /// The offbeat take, which is a jam carrying a level.
    ///
    /// Tagged `offbeat` exactly as the console tags it, so takes recorded from the two surfaces
    /// pool together rather than forming two conditions that mean the same thing. No rung and no
    /// feel: the offbeat grid is straight — ska and reggae are not a *feel*, only the drill
    /// changes — and `JamConfig.validate` refuses an offbeat level beside a swing anyway.
    var offbeatConfig: TrainerEngine.JamConfig {
        .offbeat(bpm: bpm, bars: bars, level: offbeatLevel)
    }

    var dropoutConfig: TrainerEngine.DropoutConfig {
        TrainerEngine.DropoutConfig(bpm: bpm, pacedBars: pacedBars,
                                    silentBars: silentBars, cycles: cycles,
                                    rung: rung ?? .quarters)
    }

    func start() {
        errorMessage = nil
        jamOutcome = nil
        formOutcome = nil
        dropoutOutcome = nil
        tempoOutcome = nil
        memoryOutcome = nil
        liveRounds = []
        feelRating = nil
        isStopping = false
        let flag = CancellationFlag()
        cancellation = flag
        screen = .running

        let mode = self.mode
        let jamConfig = TrainerEngine.JamConfig(
            bpm: bpm, bars: bars,
            tag: tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag,
            rung: rung, feel: feel, generatedBacking: generatedBacking)
        let formConfig = TrainerEngine.FormConfig(bpm: bpm, bars: bars,
                                                  phraseBars: phraseBars, level: formLevel)
        let grooveConfig = TrainerEngine.GrooveConfig(bpm: bpm, bars: bars,
                                                      generatedBacking: generatedBacking)
        let dropConfig = dropoutConfig
        let tempConfig = tempoConfig
        let memConfig = memoryConfig
        let offbeatCfg = offbeatConfig

        // The engine blocks for the length of the take, so it runs off the main thread and
        // the UI stays responsive. `self` is captured strongly: the closure runs once and
        // releases, so there is no cycle, and a weak optional cannot be referenced from
        // concurrently-executing code.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch mode {
                case .jam:
                    let outcome = try TrainerEngine.runJam(jamConfig, cancellation: flag)
                    Task { @MainActor in self.finish(jam: outcome) }
                case .offbeat:
                    // The same runner as a jam, because an offbeat take *is* a jam with the
                    // level set — the drill's identity travels on `JamConfig.offbeatLevel`
                    // rather than on a separate engine path.
                    let outcome = try TrainerEngine.runJam(offbeatCfg, cancellation: flag)
                    Task { @MainActor in self.finish(jam: outcome) }
                case .form:
                    let outcome = try TrainerEngine.runForm(formConfig, cancellation: flag)
                    Task { @MainActor in self.finish(form: outcome) }
                case .dropout:
                    let outcome = try TrainerEngine.runDropout(dropConfig, cancellation: flag)
                    Task { @MainActor in self.finish(dropout: outcome) }
                case .tempo:
                    let outcome = try TrainerEngine.runTempo(
                        tempConfig, cancellation: flag,
                        roundFinished: { result in
                            Task { @MainActor in self.liveRounds.append(result) }
                        })
                    Task { @MainActor in self.finish(tempo: outcome) }
                case .memory:
                    let outcome = try TrainerEngine.runMemory(memConfig, cancellation: flag)
                    Task { @MainActor in self.finish(memory: outcome) }
                case .groove:
                    try TrainerEngine.playGroove(grooveConfig, cancellation: flag)
                    Task { @MainActor in self.backToSetup() }
                }
            } catch is TakeCancelled {
                // Stopping on purpose is a normal outcome, not a failure to report.
                Task { @MainActor in self.backToSetup() }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self.errorMessage = message
                    self.screen = .setup
                }
            }
        }
    }

    private func finish(jam outcome: TrainerEngine.JamOutcome) {
        jamOutcome = outcome
        screen = .rating
    }

    private func finish(form outcome: TrainerEngine.FormOutcome) {
        formOutcome = outcome
        screen = .rating
    }

    private func finish(dropout outcome: TrainerEngine.DropoutOutcome) {
        dropoutOutcome = outcome
        screen = .rating
    }

    private func finish(tempo outcome: TrainerEngine.TempoOutcome) {
        tempoOutcome = outcome
        screen = .rating
    }

    private func finish(memory outcome: TrainerEngine.MemoryOutcome) {
        memoryOutcome = outcome
        screen = .rating
    }

    /// Store the rating and reveal the numbers — unless a session is running, in which case
    /// the numbers wait for the debrief and this just advances to the next block.
    func submitRating(_ rating: Int?) {
        feelRating = rating
        if isInSession { return submitSessionRating(rating) }
        do {
            if let outcome = jamOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = formOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = dropoutOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = tempoOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = memoryOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
        } catch {
            errorMessage = "Could not save the take: \(error.localizedDescription)"
        }
        screen = .results
    }

    func backToSetup() {
        isStopping = false
        cancellation = nil
        screen = .setup
        refreshEnvironment()
    }

    // MARK: - M9 planned session

    /// The lengths on offer. No default: the app asks how long you have before it decides
    /// what to do with it, because the answer changes the plan rather than trimming it.
    static let sessionLengths = [20, 30, 45]

    @Published private(set) var sessionMinutes: Int?
    @Published private(set) var sessionPlan: SessionPlan?
    /// Declared before the session starts, never after — see `SessionState`. Defaults to
    /// `usual` so pressing straight through records an ordinary evening rather than nothing.
    @Published var sessionState: SessionState = .usual
    @Published private(set) var sessionSummary: SessionSummary?
    /// Raised when a block was stopped mid-way: skip this drill, or end the session?
    @Published var sessionStopDecision = false

    private var runner: SessionRunner?
    private var pendingOutcome: SessionRunner.BlockOutcome?

    var isInSession: Bool { runner != nil }
    var sessionBlock: SessionBlock? { runner?.currentBlock }
    var sessionPosition: (index: Int, total: Int)? {
        guard let runner else { return nil }
        return (runner.index + 1, runner.plan.blocks.count)
    }
    var sessionRemainingSeconds: Double { runner?.remainingSeconds ?? 0 }

    /// What the take screen says, whether the take came from the menu or from a session.
    /// Instructions for the mode as currently configured.
    var currentInstructions: DrillInstructions {
        mode.instructions(formLevel: formLevel.rawValue, rung: rung,
                          offbeatLevel: offbeatLevel)
    }

    var feel: Feel { Feel(swingRatio: swingRatio) ?? .straight }

    /// Whether a swing means anything at the chosen rung. Triplets have no binary pair, and free
    /// playing prescribes no division for a feel to describe.
    ///
    /// Asks the rung rather than testing its subdivisions here. The inline copy was
    /// `subdivisions == 2 || subdivisions == 4`, which is the same answer as the engine's rule
    /// for exactly today's four rungs and a different rule — shape 9.
    var feelApplies: Bool { rung?.canSwing ?? false }

    /// The ratios offered, each labelled in the words a player would use.
    /// Three, all audibly distinct. A 4:3 option sat 20 ms from straight at 100 BPM and the
    /// player could not tell it apart from either neighbour — false precision in a picker whose
    /// job is to let him choose a feel he can hear. The ratio stays continuous in the model,
    /// because measuring what he actually produces needs it; only the offered choices are
    /// coarse.
    static let swingChoices: [(ratio: Double, label: String)] = [
        (1, "Straight"), (1.5, "Shuffle (3:2)"), (2, "Swung (2:1)"),
    ]

    /// What choosing a band means, said where the choice is made.
    ///
    /// Names the seed, because it is the only route back to a piece the player liked — the same
    /// reason the CLI prints it and the planner's `reason` carries it.
    var bandAdvice: String {
        guard let band else {
            return "The fixed groove every take on record was played over. Trends compare across "
                 + "it, so this is the one to leave alone if you want tonight to line up with "
                 + "what came before."
        }
        return String(format: "A piece generated from %@, stored as %@@%016llx — the seed is how "
                    + "you ask for this exact one again. Choosing a band clears the subdivision: "
                    + "a ladder groove marks the division being asked for and a style does not, "
                    + "so only one of them can play.", band, band, bandSeed)
    }

    /// The bands the app may offer: the approved library, and nothing else.
    static var bandChoices: [String] { StyleLibrary.auditioned.map(\.name).sorted() }

    /// The identity a take is stored under, or `nil` for the fixed backing.
    var generatedBacking: BackingIdentity? {
        band.map { BackingIdentity(style: $0, seed: bandSeed) }
    }

    /// A rung and a style are two backings and only one can play — `JamConfig.validate` refuses
    /// the pair, so the picker must not be able to ask for it. Choosing a band clears the rung
    /// rather than failing at Start, which is the same discipline as `clampFeelToRung`.
    /// And the other way round, so the two pickers can never both be set.
    private func clampBandToRung() {
        if rung != nil { band = nil }
    }

    private func clampRungToBand() {
        if band != nil {
            rung = nil
            // A fresh piece each time the band changes, and a stable one while it does not.
            bandSeed = UInt64.random(in: 1...UInt64.max)
        }
    }

    /// Drop a swing the chosen rung cannot carry, so the picker and the take never disagree.
    func clampFeelToRung() {
        if !feelApplies { swingRatio = 1 }
    }

    /// Rungs this tempo can score honestly, for a player of this spread.
    ///
    /// Above its ceiling a rung's matching window is worth fewer than three of the player's own
    /// spreads, so notes they aimed correctly are discarded and the off-grid rate becomes a
    /// property of the rung rather than of them (§7.23 step 1). The picker offers what is
    /// scorable rather than offering everything and reporting a caveat afterwards.
    var scorableRungs: [IntervalRung] {
        IntervalRung.scorable(atBpm: bpm, spreadMs: recentSpreadMs)
    }

    /// The player's own recent spread, which is what the ceiling is derived from. Falls back to
    /// the figure §7.23 step 1 works its table through when there is nothing to measure.
    var recentSpreadMs: Double {
        let spreads = TrainerEngine.recentJamSpreadsMs()
        guard !spreads.isEmpty else { return SessionPlanner.assumedSpreadMs }
        return Stats.median(spreads)
    }

    /// Why the Feel picker is greyed out, when it is. Shown rather than left to be guessed.
    var feelAdvice: String? {
        guard mode == .jam, !feelApplies else { return nil }
        guard let rung else {
            return "Swing needs a subdivision to swing — pick eighths or sixteenths above."
        }
        // The rung says why, because this said "triplets" for every unswingable rung including
        // quarters — where triplets are irrelevant — and a disabled control that explains itself
        // wrongly sends the reader looking for the wrong thing (§7.39).
        return rung.swingUnavailableReason
    }

    /// What the chosen tempo asks of the chop, in milliseconds rather than in BPM.
    ///
    /// This is the one drill where tempo changes the *task* rather than only its speed. The note
    /// rate is one per beat either way — no faster than a quarter-note jam — but each note has to
    /// land at the midpoint of an interval whose endpoints are not being played, and that midpoint
    /// closes on the beat as the tempo rises.
    ///
    /// States the geometry and the two takes there are, and stops. **No threshold**: one take at
    /// each of two tempos cannot support one, and picking a number that reads as measured would be
    /// `LESSONS.md` shape 11 in a tooltip.
    var offbeatTempoAdvice: String {
        let gapMs = 60_000 / max(bpm, 1) / 2
        return String(format: "The chop lands %.0f ms from the beat on either side. Tempo changes "
                    + "the task here more than in any other drill: the one take on record at "
                    + "100 BPM inverted the feel, and one at 69 held it.", gapMs)
    }

    /// One line under the picker saying what the choice costs, in the player's terms.
    var rungAdvice: String {
        let choice: String
        if let rung {
            choice = String(format: "Asks for %@ and scores against them: a %.0f ms gap between "
                          + "notes at %d BPM. A coarser note value lands off-grid and is "
                          + "discarded rather than counted late.",
                            rung.label, rung.intervalSeconds(atBpm: bpm) * 1000, Int(bpm))
        } else {
            choice = "Free playing measures where you put notes without asking for any "
                   + "particular note value — what every take on record is."
        }
        return ([choice] + [hiddenRungAdvice]).compactMap { $0 }.joined(separator: " ")
    }

    /// Which rungs this tempo cannot score, and **the tempo that would let them in**.
    ///
    /// The way in is the part worth saying. Sixteenths sit at a ~99 BPM ceiling at this player's
    /// spread, so they are unreachable from the 100 BPM default — a picker that hides them
    /// without naming the tempo that reveals them looks like the rung does not exist. §7.23
    /// step 1 predicted exactly this: sixteenths are already at their ceiling at the reference
    /// tempo, and the rung becomes available as the spread comes down, which is the thing being
    /// trained.
    private var hiddenRungAdvice: String? {
        let spread = recentSpreadMs
        let hidden = IntervalRung.ladder.filter {
            bpm > feel.maximumBpm(subdivisions: $0.subdivisions, forSpreadMs: spread)
        }
        guard !hidden.isEmpty else { return nil }

        let named = hidden.map { rung -> String in
            let ceiling = feel.maximumBpm(subdivisions: rung.subdivisions, forSpreadMs: spread)
            return "\(rung.label) at \(Int(ceiling.rounded(.down))) BPM or below"
        }
        let list = named.count == 1
            ? named[0]
            : named.dropLast().joined(separator: ", ") + " and " + (named.last ?? "")
        return String(format: "Hidden at %d BPM, because the scoring window would be under three "
                    + "times your own %.0f ms spread and notes you aimed correctly would be "
                    + "thrown out: %@. They open up as your spread comes down.",
                      Int(bpm), spread, list)
    }

    /// Drop a rung that this tempo can no longer score, so the picker and the take never
    /// disagree about what is legal. Called when the tempo moves.
    func clampRungToTempo() {
        if let rung, !scorableRungs.contains(rung) { self.rung = scorableRungs.last }
    }

    var takePrompt: String {
        if let block = sessionBlock {
            if case .form = block.plan { return "Mark each phrase top." }
            return "Play."
        }
        return mode == .form ? "Mark each phrase top." : "Play."
    }

    /// The tempo drill is the one deliberate exception to the blank take screen.
    var takeShowsTempoFeedback: Bool {
        if let block = sessionBlock, case .tempo = block.plan { return true }
        return runner == nil && mode == .tempo
    }

    func openSessionPlanner() {
        errorMessage = nil
        sessionMinutes = nil
        sessionPlan = nil
        sessionSummary = nil
        runner = nil
        screen = .sessionPlan
    }

    func chooseSessionLength(_ minutes: Int) {
        sessionMinutes = minutes
        sessionPlan = TrainerEngine.planSession(targetMinutes: minutes)
    }

    func beginSession() {
        guard let plan = sessionPlan else { return }
        runner = SessionRunner(plan: plan, state: sessionState)
        showNextBrief()
    }

    private func showNextBrief() {
        guard let runner else { return }
        if runner.isFinished { endSession(early: false) } else { screen = .sessionBrief }
    }

    /// Run the block the brief just described.
    func startSessionBlock() {
        guard let runner, runner.currentBlock != nil else { return }
        errorMessage = nil
        liveRounds = []
        feelRating = nil
        isStopping = false
        let flag = CancellationFlag()
        cancellation = flag
        screen = .running

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try runner.runCurrent(
                    cancellation: flag,
                    roundFinished: { result in
                        Task { @MainActor in self.liveRounds.append(result) }
                    })
                Task { @MainActor in self.finishSessionBlock(outcome) }
            } catch is TakeCancelled {
                // Stopping a block is not stopping the session. "Wrong tempo, move on" and
                // "I'm done" are different intentions, so the player says which.
                Task { @MainActor in
                    self.isStopping = false
                    self.sessionStopDecision = true
                    self.screen = .sessionBrief
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self.errorMessage = message
                    self.screen = .sessionBrief
                }
            }
        }
    }

    private func finishSessionBlock(_ outcome: SessionRunner.BlockOutcome) {
        isStopping = false
        pendingOutcome = outcome
        // The warm-up measures nothing, so there is nothing to rate — asking anyway would
        // make the rating a habit rather than a judgement.
        if outcome.isMeasured { screen = .rating } else { submitSessionRating(nil) }
    }

    /// Store the rating, save the take with its place in the session, and move on. No numbers
    /// appear — the whole session's results wait for the debrief.
    private func submitSessionRating(_ rating: Int?) {
        guard let runner, let outcome = pendingOutcome else { return }
        do {
            try runner.complete(outcome, feelRating: rating)
        } catch {
            errorMessage = "Could not save that take: \(error.localizedDescription)"
        }
        pendingOutcome = nil
        showNextBrief()
    }

    /// Skip the block that was stopped and carry on with the rest of the session.
    func skipSessionBlock() {
        sessionStopDecision = false
        runner?.skip()
        showNextBrief()
    }

    func endSession(early: Bool) {
        sessionStopDecision = false
        guard let runner else { return backToSetup() }
        if early { runner.skip() }
        do {
            sessionSummary = try runner.finish(endedEarly: early)
        } catch {
            errorMessage = "Could not save the session: \(error.localizedDescription)"
        }
        self.runner = nil
        cancellation = nil
        isStopping = false
        screen = .sessionDebrief
    }

    func leaveSession() {
        runner = nil
        sessionPlan = nil
        sessionMinutes = nil
        pendingOutcome = nil
        backToSetup()
    }
}
