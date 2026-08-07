import Foundation
import GrooveCore
import TimingCore

/// An axis along which two jam takes are not the same task.
///
/// **One list, two readouts.** `review conditions` asks whether two groups differ along an axis;
/// `review tags` asks whether one pool mixes it. They were separate lists and they disagreed:
/// the pooled summary knew about backings, tempos and output devices, the comparison also knew
/// about the rung and the feel, and neither knew about the offbeat drill — so `tired` pooled a
/// 2:1 and a 3:2 swung take and said nothing (§7.28).
///
/// A tag is a label the player applied, not a task the app chose, so the answer here is R3.4 —
/// name the confound at the point of display — and not R3.5's split. Splitting a condition into
/// sub-conditions would be answering a question nobody asked.
struct TakeAxis {
/// How the axis is named when two groups differ: "Backing differs (…)".
let singular: String
/// How it is named when one pool mixes it: "pools takes across different backings".
let plural: String
let value: (JamSession) -> String
/// What stops being comparable, and what still is. Never just "these differ".
let consequence: String

/// The axes a single pool mixes. Empty means the takes are the same task.
///
/// Extracted so a test can reach it: the pooled summary prints, and a decision made inside a
/// print function is a decision no suite can check (`LESSONS.md` shape 1).
static func mixed(in takes: [JamSession]) -> [TakeAxis] {
    all.filter { axis in Set(takes.map(axis.value)).count > 1 }
}

/// Everything that makes two takes a different task, in the order a reader cares.
static let all: [TakeAxis] = [
    TakeAxis(singular: "Backing", plural: "backings", value: { $0.grooveName },
             consequence: "Spread and drift are not comparable across different music."),
    TakeAxis(singular: "Feel", plural: "feels", value: { $0.feel.label },
             consequence: "Where the offbeat is expected is not the same task, so placement "
                        + "and spread are not comparable."),
    // Rung and tempo are one axis in the end — both move the gap between notes — so a rung
    // difference disqualifies a comparison exactly as a tempo one does (§7.23 trap 3).
    TakeAxis(singular: "Subdivision", plural: "subdivisions", value: { $0.rung ?? "free" },
             consequence: "The gap between notes is not the same task, so spread and "
                        + "off-grid rate are not comparable — the matching window scales "
                        + "with the rung."),
    TakeAxis(singular: "Offbeat level", plural: "offbeat levels",
             value: { $0.offbeatLevel.map { "level \($0)" } ?? "not the offbeat drill" },
             consequence: "Holding a position the band never plays is a different task from "
                        + "playing along, and how much of the downbeat is left changes it "
                        + "again."),
    TakeAxis(singular: "Tempo", plural: "tempos", value: { "\(Int($0.bpm)) BPM" },
             consequence: "Timing spread scales with tempo."),
    TakeAxis(singular: "Output device", plural: "output devices", value: { $0.device },
             consequence: "Bias is not comparable; spread and r₁ are unaffected."),
]
}

public enum Commands {

    // MARK: - Shared environment check

    struct Environment {
        let output: AudioDevices.Info
        let input: AudioDevices.Info
    }

    /// Resolve and report the audio devices, refusing configurations that cannot be
    /// calibrated. Bluetooth is rejected outright: its latency varies run to run, so no
    /// stored constant can ever be correct.
    static func checkEnvironment(verbose: Bool = true) throws -> Environment {
        guard let output = AudioDevices.defaultDevice(input: false),
              let input = AudioDevices.defaultDevice(input: true) else {
            throw SpikeError("Could not resolve default audio devices.")
        }

        if verbose {
            let source = output.dataSource.map { " — \($0)" } ?? ""
            print("Output: \(output.name)\(source)  @ \(Int(output.sampleRate)) Hz  [\(output.transport)]")
            print("        reported latency \(output.reportedLatencyFrames) frames, "
                + "safety offset \(output.safetyOffsetFrames), buffer \(output.bufferFrameSize)")
            print("Input:  \(input.name)  @ \(Int(input.sampleRate)) Hz  [\(input.transport)]")
            print("        reported latency \(input.reportedLatencyFrames) frames, "
                + "safety offset \(input.safetyOffsetFrames), buffer \(input.bufferFrameSize)")
        }

        if output.isBluetooth || input.isBluetooth {
            throw SpikeError("""
                Bluetooth audio detected. Its latency varies run to run and cannot be
                calibrated away. Switch to built-in or wired devices.
                """)
        }
        if abs(output.sampleRate - input.sampleRate) > 1 {
            Console.warn("""
                input and output run at different sample rates — they are almost certainly
                on independent clocks. Watch the drift figure closely.
                """)
        }

        AudioDevices.setBufferFrameSize(256, on: output.id)
        return Environment(output: output, input: input)
    }

    static func startMIDI() throws -> MIDIInput {
        let midi = try MIDIInput.started()
        print("\nMIDI listening on: \(midi.sourceNames.joined(separator: ", "))")
        if !midi.skippedSources.isEmpty {
            print("Ignoring control-surface ports: \(midi.skippedSources.joined(separator: ", "))")
        }
        return midi
    }

    // MARK: - M0 validation rig

    public static func runValidation() throws {
        Console.heading("Environment")
        let env = try checkEnvironment()
        let midi = try startMIDI()
        defer { midi.end() }

        Console.heading("Phase 1 — Round-trip latency")
        Console.prompt("""
            Set output to your INTERNAL SPEAKERS at a comfortable volume, and make sure
            nothing is covering the built-in microphone. This measures output latency + air
            travel + input latency by playing 24 chirps and finding them in the recording.
            """)

        print("Measuring...")
        let loopback = try Procedures.loopback()
        try reportLoopback(loopback)

        Console.heading("Phase 2 — Bridge validation (two-path)")
        Console.prompt("""
            Now the real test. A chirp plays once per second through the speakers.

              • Hit ONE key on the Launchkey, FIRMLY, roughly HALFWAY BETWEEN each pair of
                chirps.
              • Accuracy does not matter — we are not measuring your timing here. The
                strike only needs to be well clear of the chirps so the two can be told
                apart.
              • It must be audible to the microphone, so hit it like you mean it.

            This runs for about 100 seconds.
            """)

        let (result, bufferFrames) = try Procedures.twoPath(midi: midi)
        reportValidation(result, bufferFrames: bufferFrames, deviceName: env.output.identity)
    }

    @discardableResult
    private static func reportLoopback(_ outcome: Procedures.LoopbackOutcome) throws -> LatencyResult {
        let r = outcome.latency
        print("\nChirps emitted:  \(r.chirpsExpected)")
        print("Chirps detected: \(r.chirpsFound)")
        if let measured = outcome.measuredInputClock {
            print(String(format: "Input clock:     %.2f Hz measured vs %.0f Hz nominal",
                         measured, outcome.inputSampleRate))
        }
        guard r.roundTripMs.count >= 8 else {
            throw SpikeError("Too few chirps detected. Raise the volume or move the mic closer.")
        }

        print("\nRound trip:  median \(Console.ms(r.median))   IQR \(Console.ms(r.iqr))   "
            + "SD \(Console.ms(r.sd))")

        if let drift = r.driftFit {
            let perMinute = drift.slope * 60
            let locked = abs(perMinute) < 1.0
            print(String(format: "Clock drift: %.3f ms/min  (r = %.3f)  %@",
                         perMinute, drift.r,
                         locked ? "— devices are clock-locked" : "— DRIFTING"))
            print("\nCheck #3 (no clock drift): \(Console.verdict(locked))")
        }
        return r
    }

    private static func reportValidation(_ result: ValidationResult,
                                         bufferFrames: UInt32,
                                         deviceName: String) {
        Console.heading("Results")
        print("Chirps detected:   \(result.chirpsFound)")
        print("MIDI notes:        \(result.midiNotes)")
        print("Key strikes heard: \(result.thocksDetected)")
        print("Paired beats:      \(result.pairedBeats)"
            + "   (\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched)")

        guard result.pairedBeats >= 20 else {
            Console.error("\nNot enough paired beats to draw conclusions.")
            explainPairingFailure(result)
            return
        }

        print("\nResidual (MIDI path − audio path):")
        print("  median \(Console.ms(result.median))   SD \(Console.ms(result.sd))   "
            + "IQR \(Console.ms(result.iqr))")

        let sdPass = result.sd < 1.0
        print("\nCheck #1 — residual SD < 1 ms:        \(Console.verdict(sdPass))  "
            + "(\(Console.ms(result.sd)))")

        if let fit = result.phaseFit {
            let acrossBuffer = fit.slope * Double(max(bufferFrames, 1))
            let pass = abs(acrossBuffer) < 0.5
            print(String(format: "Check #2 — no buffer-phase dependence: %@  (%.3f ms across a buffer, r = %.3f)",
                         Console.verdict(pass), acrossBuffer, fit.r))
            if !pass {
                Console.error("           The host-time to sample-index conversion is wrong.")
            }
        }
        if let fit = result.timeFit {
            let perMinute = fit.slope * 60
            print(String(format: "Check #3 — no drift over time:        %@  (%.3f ms/min, r = %.3f)",
                         Console.verdict(abs(perMinute) < 1.0), perMinute, fit.r))
        }

        print("\nCheck #4 — calibration constant:      \(Console.ms(result.median))")

        Console.heading("Verdict")
        if sdPass {
            print("The clock bridge is sound. The foundation holds.")
            print("\nStore this as a calibration with:  TimingSpike calibrate")
        } else {
            print("The bridge is not stable enough to build on. Investigate before proceeding.")
        }
    }

    private static func explainPairingFailure(_ result: ValidationResult) {
        if result.midiNotes == 0 {
            print("""

            No MIDI arrived at all — the microphone side is fine, this is the keyboard.
            Diagnose it with:  TimingSpike midimon
            """)
        } else if result.thocksDetected < 20 {
            print("""

            MIDI arrived (\(result.midiNotes) notes) but the microphone heard almost no key
            strikes. Move the mic closer to the keyboard and strike harder.
            """)
        } else {
            print("""

            Both inputs produced data (\(result.midiNotes) notes, \(result.thocksDetected) strikes)
            but they could not be paired. Try a quieter room, or strike closer to halfway
            between chirps.
            """)
        }
    }

    // MARK: - M1 calibration

    // MARK: - M9 session

    /// Print the plan without running it, so the choices can be argued with before you commit
    /// twenty minutes to them.
    public static func runSessionPlan(targetMinutes: Int) {
        let plan = TrainerEngine.planSession(targetMinutes: targetMinutes)
        Console.heading("Tonight's session")
        print(String(format: "%d blocks  ·  ~%.0f min planned against a %d min target",
                     plan.blocks.count, plan.estimatedSeconds / 60, plan.targetMinutes))

        for (index, block) in plan.blocks.enumerated() {
            print("\n\(Console.bold)\(index + 1). \(block.plan.drillName)\(Console.reset)"
                + "  \(Console.dim)\(block.role.rawValue) · \(block.plan.settingsLabel)"
                + String(format: " · %.0f min\(Console.reset)", block.estimatedSeconds / 60))
            print("   \(block.reason)")
        }

        if !plan.notes.isEmpty {
            print("")
            for note in plan.notes { Console.warn(note) }
        }
    }

    public static func runSession(targetMinutes: Int) throws {
        let plan = TrainerEngine.planSession(targetMinutes: targetMinutes)
        runSessionPlan(targetMinutes: targetMinutes)

        let env = try TrainerEngine.environment()
        print("\nOutput: \(env.outputName)")
        if let c = env.calibrationMs, let src = env.calibrationSource {
            print("Calibration: \(Console.ms(c)) (\(src))")
        } else {
            Console.warn("no calibration for this output device — bias will be uncorrected. "
                       + "Spread and drift are still valid.")
        }
        // Asked **before** the session, never after. Declared first it is a condition; marked
        // afterwards it would be a way of excusing a sitting that went badly, which is one step
        // from dropping the takes you dislike.
        let states = SessionState.allCases
        let chosen = states[Console.readChoice("How are you coming into this?",
                                               options: states.map { ($0.label, $0.blurb) })]

        guard Console.confirm("\nStart the session?") else { return }

        let runner = SessionRunner(plan: plan, state: chosen)
        var endedEarly = false

        while let block = runner.currentBlock {
            Console.heading("\(runner.index + 1)/\(plan.blocks.count) — \(block.plan.drillName)")
            print("\(Console.dim)\(block.plan.settingsLabel)"
                + String(format: " · %.0f min\(Console.reset)", block.estimatedSeconds / 60))
            print("\n\(block.reason)")
            printInstructions(DrillInstructions.forBlock(block))
            Console.prompt("Ready?")

            let outcome: SessionRunner.BlockOutcome
            do {
                outcome = try runner.runCurrent(roundFinished: { result in
                    // The tempo drill is the one deliberate exception to the silence rule —
                    // it *is* a feedback loop, and the feedback lands during click bars.
                    guard let produced = result.producedBpm, let pct = result.errorPercent else {
                        print("  round \(result.index + 1): \(result.unusableReason ?? "not scored")")
                        return
                    }
                    print(String(format: "  round %d: %.0f BPM  (%+.1f%%)",
                                 result.index + 1, produced, pct))
                })
            } catch is TakeCancelled {
                // Stopping a block is not stopping the session — "wrong tempo, move on" and
                // "I'm done" are different intentions and the runner refuses to guess.
                if Console.confirm("\nStopped. End the whole session?") {
                    runner.skip(); endedEarly = true; break
                }
                runner.skip()
                continue
            }

            // Rate now; the numbers wait for the debrief. For the whole session there is
            // nothing measured to see, which is the blank-screen rule applied end to end.
            let feel = outcome.isMeasured ? Console.readRating("\nHow did that feel?") : nil
            try runner.complete(outcome, feelRating: feel)
        }

        reportSession(try runner.finish(endedEarly: endedEarly))
    }

    private static func reportSession(_ summary: SessionSummary) {
        Console.heading("Session debrief")
        print(String(format: "%d of %d blocks completed  ·  %.0f min",
                     summary.completedCount, summary.plan.blocks.count,
                     summary.durationSeconds / 60))
        if summary.endedEarly { Console.warn("ended early — the remaining blocks were not run.") }

        for result in summary.results {
            let label = "\(result.index + 1). \(result.block.plan.drillName)"
            guard let outcome = result.outcome else {
                print("\n\(pad(label, 18))\(Console.dim)skipped\(Console.reset)")
                continue
            }
            let stars = result.feelRating.map { String(repeating: "★", count: $0) } ?? ""
            print("\n\(Console.bold)\(label)\(Console.reset)  \(Console.dim)"
                + "\(result.block.role.rawValue)\(Console.reset)  \(stars)")
            print("   \(outcome.headline ?? "not measured")")
        }

        print("\n\(Console.dim)Every take is saved with its place in the session, so a cold "
            + "measurement and one taken twenty minutes in can be told apart.\(Console.reset)")
    }


    /// One rung parser for every command, so an unknown name is refused the same way whatever
    /// it was typed after — and refused *before* any audio device is opened (R7.6).
    /// A swing ratio, refused before any audio device is opened (R7.6).
    ///
    /// Refusing a swing without a rung is the important half: a free jam has no prescribed
    /// division, so there is nothing for a feel to describe, and accepting one would store a
    /// ratio the analysis would then score against notes nobody was asked to place.
    static func parseFeel(_ raw: String?, rung: IntervalRung?) throws -> Feel {
        guard let raw else { return .straight }
        guard let ratio = Double(raw), let feel = Feel(swingRatio: ratio) else {
            throw SpikeError("Swing must be a ratio between 1 and 4 — 1 is straight, 2 is the "
                           + "usual triplet feel. Got '\(raw)'.")
        }
        guard let rung else {
            throw SpikeError("A swing needs a rung to swing: free playing prescribes no division "
                           + "for the feel to describe. Try:  jam 100 32 tag eighths 2")
        }
        guard feel.isStraight || feel.applies(toSubdivisions: rung.subdivisions) else {
            throw SpikeError("\(rung.label) has no binary pair to swing — triplets are the "
                           + "division swing borrows from. Use eighths or sixteenths.")
        }
        return feel
    }

    static func parseRung(_ raw: String?) throws -> IntervalRung? {
        guard let raw else { return nil }
        guard let parsed = IntervalRung(rawValue: raw) else {
            throw SpikeError("Unknown rung '\(raw)'. One of: "
                           + IntervalRung.ladder.map(\.rawValue).joined(separator: ", "))
        }
        return parsed
    }

    // MARK: - M4 jam

    public static func runJam(bpm: Double, bars: Int, tag: String?, rung: String? = nil,
                              swing: String? = nil,
                              flags: CommandFlags = CommandFlags()) throws {
        Console.heading("Jam — record a take")

        let prescribed = try parseRung(rung)
        let swingFeel = try parseFeel(swing, rung: prescribed)

        let config = TrainerEngine.JamConfig(bpm: bpm, bars: bars, tag: tag?.lowercased(),
                                             rung: prescribed, feel: swingFeel)
        let env = try TrainerEngine.environment()

        print("Output: \(env.outputName)")
        if let c = env.calibrationMs, let src = env.calibrationSource {
            print("Calibration: \(Console.ms(c)) (\(src))")
        } else {
            Console.warn("""
                no calibration for this output device — timing BIAS will be uncorrected.
                Spread and drift are still valid. Calibrate with:  TimingSpike calibrate
                """)
        }

        print("\n\(bars) bars at \(Int(bpm)) BPM"
            + String(format: "  ·  ~%.1f min", config.durationSeconds / 60))
        if let tag = config.tag { print("Condition: \(Console.bold)\(tag)\(Console.reset)") }
        if let prescribed {
            let feelPart = swingFeel.isStraight ? "" : ", \(swingFeel.label)"
            print("Rung: \(Console.bold)\(prescribed.label)\(feelPart)\(Console.reset)"
                + "  \(Console.dim)(\(config.backing.name), scored on a "
                + "\(config.gridSubdivisions)-per-beat grid)\(Console.reset)")
            // Above its ceiling the rung discards notes the player aimed correctly, and the
            // off-grid rate stops being a fact about them (§7.23 step 1). Said here rather than
            // refused: the planner enforces, a hand-run take is the player's call.
            let spreads = TrainerEngine.recentJamSpreadsMs()
            let spreadMs = spreads.isEmpty ? SessionPlanner.assumedSpreadMs : Stats.median(spreads)
            // Asked of the feel, not the rung: a swing shortens the short half of the pair, so
            // the window binds sooner than an even division would.
            let ceiling = swingFeel.maximumBpm(subdivisions: prescribed.subdivisions,
                                               forSpreadMs: spreadMs)
            if bpm > ceiling {
                Console.warn(String(format: "%@%@ at %d BPM is above its %.0f BPM ceiling for "
                                  + "your %.1f ms spread. The matching window is narrower than "
                                  + "three of your own spreads, so notes you aimed correctly "
                                  + "will be discarded as off-grid and the off-grid rate becomes "
                                  + "a fact about the rung rather than about you.",
                                    prescribed.label,
                                    swingFeel.isStraight ? "" : " \(swingFeel.label)",
                                    Int(bpm), ceiling, spreadMs))
            }
        }
        printInstructions(DrillInstructions.jam(rung: prescribed, feel: swingFeel))
        announceProbe(flags)
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runJam(config)

        // Rate the take BEFORE any numbers appear, so the rating is an honest read of the
        // experience rather than a rationalisation of the measurement.
        let feel = Console.readRating("\nHow did that feel?")
        reportTiming(outcome.report, notesCaptured: outcome.notesCaptured,
                     events: outcome.eventCount, uncalibrated: !env.isCalibrated,
                     grid: outcome.analysisGrid, offbeat: nil)
        let url = try TrainerEngine.save(outcome, feelRating: feel, wasProbe: flags.isProbe)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    /// An offbeat take's own readout, carried as one value rather than as a flag.
    ///
    /// A boolean saying "suppress the swing block" would be R3.3.1's defect — a value every
    /// caller has to remember to check. This cannot be half-passed: a caller either has an
    /// offbeat take and its report, or it does not.
    struct OffbeatContext {
        let report: OffbeatReport
        let level: OffbeatLevel
    }

    /// Which of the two mutually exclusive blocks a take's readout ended with.
    ///
    /// Returned by `reportTiming` rather than computed beside it, and the difference is the
    /// point: a value derived alongside the branch would agree with a branch that had been
    /// changed underneath it, which is `LESSONS.md` shape 1 — the path under test not being the
    /// path that ships, the thing that let a swung take be scored straight for a whole
    /// milestone. This is produced *by* the branch that prints.
    enum Readout: Equatable {
        case swing
        case offbeat(OffbeatLevel)
        /// Nothing to divide and nothing asked for — or too little playing to analyse.
        case neither
    }

    @discardableResult
    static func reportTiming(_ report: TimingReport, notesCaptured: Int, events: Int,
                             uncalibrated: Bool, grid: Grid? = nil,
                             offbeat: OffbeatContext?) -> Readout {
        Console.heading("Your take")
        print("Notes captured: \(notesCaptured)  →  \(events) chord/note events")
        // "Off the grid" = events that landed more than ~40% of a 16th from any beat. Missed
        // grid points are not shown: in free playing you simply aren't playing every 16th.
        print("On the grid:    \(report.matchedCount)   (\(report.extraCount) off the grid)")

        guard report.matchedCount >= 8 else {
            Console.error("\nToo few events landed near the grid to analyze.")
            if notesCaptured == 0 {
                print("No MIDI was captured — check the keyboard with:  TimingSpike midimon")
            } else {
                print("You played \(events) events but few lined up with the beat. Try playing closer to the pulse.")
            }
            return .neither
        }

        print("\n\(Console.bold)\(report.headline)\(Console.reset)\n")

        // 95% confidence intervals via block bootstrap, so it's clear how much of each
        // number is real and how much is the ~130-event sample size.
        let async = report.asynchroniesMs
        let meanCI = Bootstrap.interval(async, statistic: Bootstrap.meanStat)
        let sdCI = Bootstrap.interval(async, statistic: Bootstrap.sdStat)
        let r1CI = Bootstrap.interval(async, statistic: Bootstrap.lag1Stat)

        let biasNote = uncalibrated ? "  \(Console.yellow)(uncalibrated)\(Console.reset)" : ""
        let rushDrag = report.meanAsynchronyMs < 0 ? "ahead / rushing" : "behind / dragging"
        print("Mean asynchrony:  \(Console.ms(report.meanAsynchronyMs))\(ci(meanCI))  (\(rushDrag))\(biasNote)")
        print("Spread (SD):      \(Console.ms(report.sdAsynchronyMs))\(ci(sdCI))   "
            + "\(precisionWord(report.sdAsynchronyMs))")
        print("Median:           \(Console.ms(report.medianAsynchronyMs))")

        if let r = report.lag1Autocorrelation {
            let ciStr = r1CI.map { String(format: "  95%% CI [%+.2f, %+.2f]", $0.low, $0.high) } ?? ""
            print(String(format: "Correction gain:  r₁ = %+.2f%@   %@", r, ciStr, chasingWord(r)))
        }
        if let drift = report.driftMsPerBeat, let bpmErr = report.effectiveBpmError {
            print(String(format: "Drift:            %+.2f ms/beat  (≈ %+.1f BPM)", drift, bpmErr))
        }
        if !report.subdivisionStats.isEmpty {
            let parts = report.subdivisionStats
                .map { "s\($0.subdivision): \(Console.ms($0.sdAsynchronyMs, 1))" }
                .joined(separator: "  ")
            print("Spread by 16th:   \(parts)")
        }
        if let vc = report.velocityTimingCorrelation, abs(vc) > 0.2 {
            print(String(format: "Velocity coupling: r = %+.2f  (%@)", vc,
                         vc > 0 ? "harder = later" : "harder = earlier"))
        }
        // Mutually exclusive, and the offbeat drill wins. On an eighths grid every note the
        // skank asks for sits "off the division", so `SwingAnalysis` reads a held feel as a
        // player dividing the beat and prints a ratio for it — and the tighter the chop, the
        // more confident the wrong number. The two blocks answer different questions about the
        // same notes, and only one of them is the task the player was set (§7.24 step 8).
        if let offbeat {
            reportOffbeat(offbeat.report, level: offbeat.level)
            return .offbeat(offbeat.level)
        }
        if let grid {
            reportSwing(report: report, grid: grid)
            return .swing
        }
        return .neither
    }

    /// How the beat was divided, when enough notes landed off the division to say.
    ///
    /// Shown for any take with off-division playing, not only a swung one — a player asked for
    /// straight eighths who is quietly swinging them is exactly the thing this can see and
    /// nothing else could (§7.24 step 3).
    private static func reportSwing(report: TimingReport, grid: Grid) {
        let swing = SwingAnalysis.analyze(matched: report.matched, grid: grid)
        guard swing.ratioIsMeaningful, swing.offbeatCount >= SwingAnalysis.minimumOffbeats,
              let ratio = swing.producedRatio else { return }

        print("")
        print("\(Console.bold)Dividing \(swing.dividedUnit)\(Console.reset)")
        let interval = swing.producedRatioInterval
            .map { String(format: "  95%% CI [%.2f, %.2f]", $0.low, $0.high) } ?? ""
        print(String(format: "Ratio:            %.2f:1%@", ratio, interval))
        if let on = swing.downbeatSpreadMs, let off = swing.offbeatSpreadMs {
            // Milliseconds, and side by side on purpose: the same steadiness would report as a
            // very different *ratio* spread depending on how hard the swing is, so the ratio is
            // never given a spread of its own.
            print("Spread:           \(Console.ms(off, 1)) off the division, "
                + "\(Console.ms(on, 1)) on it   "
                + "\(Console.dim)(\(swing.offbeatCount) / \(swing.downbeatCount) notes)\(Console.reset)")
        }
        print("\n\(swing.headline)")
        for note in swing.notes { Console.warn(note) }
    }

    /// Format a 95% CI as "  95% CI [lo, hi]" in ms, or "" if unavailable.
    private static func ci(_ interval: ConfidenceInterval?) -> String {
        guard let interval else { return "" }
        return String(format: "  95%% CI [%.1f, %.1f]", interval.low, interval.high)
    }

    private static func precisionWord(_ sd: Double) -> String {
        switch sd {
        case ..<8:  return "— tight"
        case ..<15: return "— solid"
        case ..<25: return "— loose"
        default:    return "— wide"
        }
    }

    private static func chasingWord(_ r: Double) -> String {
        if r < -0.3 { return "chasing the click" }
        if r > 0.3 { return "drifting, uncorrected" }
        return "autonomous pulse"
    }

    /// Re-analyze saved takes with the current analysis. `list` shows all, `compare [i j]`
    /// puts two takes side by side, no argument reviews the most recent. A console stand-in
    /// for the M5 visual review.
    public static func runReview(_ args: [String]) throws {
        // These histories live in their own stores, so they must not be gated on jam takes.
        if args.first == "form" { runFormHistory(); return }
        if args.first == "dropout" { runDropoutHistory(); return }
        if args.first == "trend" { runTrend(); return }
        if args.first == "cold" { runCold(); return }
        if args.first == "content" { runContent(); return }
        if args.first == "experiment" { runExperiments(); return }
        if args.first == "interval" || args.first == "tempo-response" {
            runIntervalResponse(); return
        }
        if args.first == "tempo" { runTempoHistory(); return }

        let sessions = SessionStore.loadAll()
        guard !sessions.isEmpty else {
            print("No sessions yet. Record one with:  TimingSpike jam")
            return
        }

        switch args.first {
        case "list":
            Console.heading("Sessions (\(sessions.count))")
            for (i, s) in sessions.enumerated() {
                // Recomputed, never the cached summary — see STANDARDS.md §3.
                let r = s.report()
                print(String(format: "%2d. %@   %3.0f BPM  %2d bars   mean %@  SD %@",
                             i + 1, dateLabel(s.date), s.bpm, s.bars,
                             Console.ms(r.meanAsynchronyMs, 1), Console.ms(r.sdAsynchronyMs, 1)))
            }
            // STANDARDS.md §9.3 makes this the command that proves a storage change did not
            // orphan history, and `check.sh` reads its exit status. Throwing is what gives that
            // status any meaning: printing a note and exiting 0 is how the check passed for as
            // long as it existed.
            let unreadable = SessionStore.unreadableFiles()
            guard unreadable.isEmpty else {
                throw SpikeError("""
                    \(unreadable.count) stored take(s) no longer decode. They are primary data \
                    and must not be left unreadable — fix the schema rather than the files \
                    (STANDARDS.md R6.1, R6.2):
                    \(unreadable.map { "  " + $0.lastPathComponent }.joined(separator: "\n"))
                    """)
            }
            return
        case "compare":
            let a = args.count > 1 ? Int(args[1]) : nil
            let b = args.count > 2 ? Int(args[2]) : nil
            try runCompare(sessions: sessions, indexA: a, indexB: b)
            return
        case "tags":
            runTags(sessions: sessions)
            return
        case "conditions":
            guard args.count > 2 else {
                print("Usage: review conditions <tagA> <tagB>")
                runTags(sessions: sessions)
                return
            }
            runConditions(sessions: sessions, tagA: args[1].lowercased(), tagB: args[2].lowercased())
            return
        case "feel":
            runFeel(sessions: sessions)
            return
        default:
            break
        }

        // A bare number reviews that take; otherwise the latest.
        guard let latest = sessions.last else { return }
        let session = args.first.flatMap(Int.init)
            .map { sessions[max(0, min(sessions.count - 1, $0 - 1))] } ?? latest
        let (taps, grid) = session.reconstruct()
        let events = TapClustering.collapse(taps, windowSeconds: 0.035)
        let report = TimingAnalysis.analyze(taps: events, grid: grid, chordWindowMs: 0)

        Console.heading("Review — \(dateLabel(session.date))")
        print("\(Int(session.bpm)) BPM · \(session.bars) bars · \(session.device)")
        if let c = session.calibrationConstantMs {
            print("Calibration: \(Console.ms(c)) (\(session.calibrationSource ?? "?"))")
        } else {
            Console.warn("uncalibrated take — bias unreliable.")
        }
        // An offbeat take gets the readout it was recorded for. Without this the review said
        // "steady, just early" about a take that had slipped onto the beat for 86 of its 112
        // notes — the drill's headline failure, computed once at take time and then never
        // again, against R3.1's rule that every readout recomputes from the raw taps
        // (§7.24 step 8).
        reportTiming(report, notesCaptured: session.tapTimes.count, events: events.count,
                     uncalibrated: session.calibrationConstantMs == nil, grid: grid,
                     offbeat: offbeatContext(for: session))
    }

    /// The stored take's offbeat readout, when it was one.
    ///
    /// Goes through `JamSession.offbeatReport()` so the review recomputes from raw taps like
    /// every other number, rather than pairing `reconstruct()` with an `analyze` call of its own.
    ///
    /// Internal rather than private so the decision is reachable from a test. The `print` calls
    /// it feeds are not — that gap is what `offbeat:` losing its default value covers instead:
    /// a new readout cannot silently omit an offbeat take's own result, because it will not
    /// compile without saying something about it.
    static func offbeatContext(for session: JamSession) -> OffbeatContext? {
        guard let level = session.offbeatLevel.flatMap(OffbeatLevel.init(rawValue:)),
              let report = session.offbeatReport() else { return nil }
        return OffbeatContext(report: report, level: level)
    }

    private static func dateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Differences between takes that make a comparison unsafe.
    ///
    /// This exists because the confound actually happened: the jam backing was changed
    /// mid-project, and the resulting spread difference read as "your timing got worse" when
    /// part of it was simply different music. Anything that alters the task or the
    /// measurement is named here, so a confound announces itself instead of quietly becoming
    /// a conclusion.
    static func comparabilityNotes(_ groups: [(label: String, sessions: [JamSession])]) -> [String] {
        guard groups.count >= 2 else { return [] }
        var notes: [String] = []

        /// Describe a per-group set of values, e.g. "relaxed: jamBacking, focused: basicRock".
        func describe(_ key: (JamSession) -> String) -> (differs: Bool, text: String) {
            let perGroup = groups.map { ($0.label, Set($0.sessions.map(key))) }
            let all = perGroup.reduce(into: Set<String>()) { $0.formUnion($1.1) }
            let text = perGroup
                .map { "\($0.0): \($0.1.sorted().joined(separator: "/"))" }
                .joined(separator: ", ")
            return (all.count > 1, text)
        }

        var deviceDiffers = false
        for axis in TakeAxis.all {
            let result = describe(axis.value)
            guard result.differs else { continue }
            if axis.singular == "Output device" { deviceDiffers = true }
            notes.append("\(axis.singular) differs (\(result.text)). \(axis.consequence)")
        }

        // Only when the device is the same: a differing device already says bias is off, and
        // two notes about the same number help nobody.
        if !deviceDiffers {
            let calibrated = describe { $0.calibrationConstantMs != nil ? "yes" : "no" }
            if calibrated.differs {
                notes.append("Calibration differs (\(calibrated.text)). Bias is not comparable; "
                           + "spread and r₁ are unaffected.")
            }
        }
        return notes
    }

    private static func printComparabilityNotes(_ notes: [String]) {
        guard !notes.isEmpty else { return }
        print("")
        for note in notes {
            print("\(Console.yellow)Not comparable:\(Console.reset) \(note)")
        }
    }

    /// The matched asynchrony series for a stored take, re-analyzed with the current logic.
    private static func asynchronies(of session: JamSession) -> [Double] { session.asynchroniesMs }

    /// Side-by-side comparison of two takes with a bootstrap on each *difference*, so real
    /// changes are separated from sample noise instead of eyeballed.
    private static func runCompare(sessions: [JamSession], indexA: Int?, indexB: Int?) throws {
        guard sessions.count >= 2 else {
            print("Need at least two takes to compare — you have \(sessions.count).")
            return
        }
        func pick(_ i: Int?, default d: Int) -> Int {
            let idx = i.map { $0 - 1 } ?? d
            return max(0, min(sessions.count - 1, idx))
        }
        let ai = pick(indexA, default: sessions.count - 2)
        let bi = pick(indexB, default: sessions.count - 1)
        let a = sessions[ai], b = sessions[bi]

        let asyncA = asynchronies(of: a), asyncB = asynchronies(of: b)
        guard asyncA.count >= 8, asyncB.count >= 8 else {
            print("Not enough matched events in one of the takes to compare.")
            return
        }

        Console.heading("Compare")
        print("A (#\(ai + 1)): \(dateLabel(a.date))   \(Int(a.bpm)) BPM, \(a.bars) bars, \(asyncA.count) events")
        print("B (#\(bi + 1)): \(dateLabel(b.date))   \(Int(b.bpm)) BPM, \(b.bars) bars, \(asyncB.count) events")
        printComparabilityNotes(comparabilityNotes([("A", [a]), ("B", [b])]))
        print("\n\(pad("Metric", 16))\(pad("A", 10))\(pad("B", 10))\(pad("change (B−A)", 22))verdict")

        func row(_ name: String, _ stat: @escaping ([Double]) -> Double, unit: String) {
            let va = stat(asyncA), vb = stat(asyncB)
            // difference(B, A) = stat(B) − stat(A): the change from the earlier take to the later.
            let diff = Bootstrap.difference(asyncB, asyncA, statistic: stat)
            let changeStr: String
            let verdict: String
            if let d = diff {
                changeStr = String(format: "%+.2f [%+.2f, %+.2f]", d.point, d.low, d.high)
                verdict = d.excludesZero ? "\(Console.bold)real change\(Console.reset)"
                                         : "\(Console.dim)within noise\(Console.reset)"
            } else { changeStr = "—"; verdict = "—" }
            print("\(pad(name, 16))\(pad(String(format: "%+.2f\(unit)", va), 10))"
                + "\(pad(String(format: "%+.2f\(unit)", vb), 10))"
                + "\(pad(changeStr, 22))\(verdict)")
        }

        row("Mean async", Bootstrap.meanStat, unit: "")
        row("Spread (SD)", Bootstrap.sdStat, unit: "")
        row("r₁", Bootstrap.lag1Stat, unit: "")

        print("\n\(Console.dim)Mean/SD in ms. \"within noise\" = the 95% interval "
            + "for the change includes zero.\(Console.reset)")
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    /// Form-drill history, so progress up the landmark ladder is visible.
    private static func runFormHistory() {
        let sessions = SessionStore.loadAllForm()
        Console.heading("Form drill history")
        guard !sessions.isEmpty else {
            print("No form drills yet. Try:  TimingSpike form 100 64 8 0")
            return
        }
        print("\(pad("When", 22))\(pad("lvl", 5))\(pad("phrase", 8))\(pad("on form", 10))\(pad("nailed", 9))slip")
        for s in sessions {
            // Re-analysed from the stored marks so an analysis fix reaches older takes.
            let r = s.report()
            let onForm = "\(r.onFormCount)/\(r.marksPlaced)"
            let tight = "\(r.tightCount)/\(r.marksPlaced)"
            let slip = r.slipBarsPerPhrase.map { String(format: "%+.2f", $0) } ?? "—"
            // A probe is marked in the ladder it is not part of. Without this a level the
            // player was handed for one take reads as a level they climbed to, which is the
            // whole confusion the role exists to prevent (§7.26).
            let probe = s.wasProbe == true
            let level = probe ? "\(s.level)*" : "\(s.level)"
            print("\(pad(dateLabel(s.date), 22))\(pad(level, 5))"
                + "\(pad("\(s.phraseBars) bars", 8))\(pad(onForm, 10))\(pad(tight, 9))\(slip)")
        }
        print("\n\(Console.dim)\"nailed\" = on the right bar AND close to the downbeat.\(Console.reset)")
        if sessions.contains(where: { $0.wasProbe == true }) {
            print("\(Console.dim)* a probe — a level run for the reading, not one you earned. "
                + "The ladder ignores these.\(Console.reset)")
        }
    }

    /// Summary of every tagged condition, pooled across takes.
    private static func runTags(sessions: [JamSession]) {
        // Paired with their tag as they are selected, so the tag is never re-unwrapped.
        let tagged = sessions.compactMap { s in s.tag.map { (tag: $0, session: s) } }
        guard !tagged.isEmpty else {
            print("No tagged takes yet. Tag one with:  TimingSpike jam 100 32 relaxed")
            return
        }
        let groups = Dictionary(grouping: tagged, by: \.tag).mapValues { $0.map(\.session) }

        Console.heading("Conditions")
        print("\(pad("Tag", 14))\(pad("takes", 7))\(pad("events", 8))\(pad("mean", 20))\(pad("SD", 20))r₁")
        var thin: [String] = []
        for (tag, takes) in groups.sorted(by: { $0.key < $1.key }) {
            let series = takes.map(asynchronies(of:))
            let events = series.reduce(0) { $0 + $1.count }
            let mean = Bootstrap.pooledInterval(series, statistic: Bootstrap.meanStat)
            let sd = Bootstrap.pooledInterval(series, statistic: Bootstrap.sdStat)
            let r1 = Bootstrap.pooledInterval(series, statistic: Bootstrap.lag1Stat)
            if mean == nil { thin.append(tag) }
            func fmt(_ c: ConfidenceInterval?, _ digits: Int = 1) -> String {
                guard let c else { return "—" }
                return String(format: "%+.\(digits)f [%+.\(digits)f,%+.\(digits)f]", c.point, c.low, c.high)
            }
            print("\(pad(tag, 14))\(pad("\(takes.count)", 7))\(pad("\(events)", 8))"
                + "\(pad(fmt(mean), 20))\(pad(fmt(sd), 20))\(fmt(r1, 2))")
        }

        // A condition with one usable take gets no interval at all. The only variation inside
        // a single take is within-take variation, and offering that as the condition's
        // uncertainty is precisely what §7.20 removed.
        if !thin.isEmpty {
            print("\n\(Console.yellow)No interval:\(Console.reset) \(thin.joined(separator: ", ")) "
                + "— fewer than \(Bootstrap.minimumTakes) usable takes. Take-to-take variation "
                + "is most of\nthe variation, so one take cannot put a bound on a condition.")
        }

        // Pooling takes recorded under different conditions hides the confound inside a
        // single row, where no comparison step would ever surface it.
        for (tag, takes) in groups.sorted(by: { $0.key < $1.key }) {
            let mixed = TakeAxis.mixed(in: takes)
            if !mixed.isEmpty {
                print("\n\(Console.yellow)Mixed pool:\(Console.reset) '\(tag)' pools takes across "
                    + "different \(mixed.map(\.plural).joined(separator: " and ")) — the pooled "
                    + "figures blend them.")
                // The consequence, not just the fact. A reader who is told the pool mixes feels
                // still has to be told which number that ruins.
                for axis in mixed { Console.warn("  \(axis.consequence)") }
            }
        }
        print("\n\(Console.dim)Pooled across takes, 95% intervals covering both take-to-take "
            + "and within-take variation.\nCompare two with:  review conditions <a> "
            + "<b>\(Console.reset)")
    }

    /// Pooled comparison of two conditions — the experiment readout.
    private static func runConditions(sessions: [JamSession], tagA: String, tagB: String) {
        let a = sessions.filter { $0.tag == tagA }, b = sessions.filter { $0.tag == tagB }
        guard !a.isEmpty, !b.isEmpty else {
            print("Need takes tagged '\(tagA)' and '\(tagB)' — found \(a.count) and \(b.count).")
            return
        }
        let sa = a.map(asynchronies(of:)), sb = b.map(asynchronies(of:))

        Console.heading("\(tagA) vs \(tagB)")
        print("\(tagA): \(a.count) take(s), \(sa.reduce(0) { $0 + $1.count }) events")
        print("\(tagB): \(b.count) take(s), \(sb.reduce(0) { $0 + $1.count }) events")
        printComparabilityNotes(comparabilityNotes([(tagA, a), (tagB, b)]))
        print("\n\(pad("Metric", 16))\(pad(tagA, 10))\(pad(tagB, 10))\(pad("change (B−A)", 22))verdict")

        func row(_ name: String, _ stat: @escaping ([Double]) -> Double) {
            let va = stat(sa.flatMap { $0 }), vb = stat(sb.flatMap { $0 })
            let diff = Bootstrap.pooledDifference(sb, sa, statistic: stat)
            let change = diff.map { String(format: "%+.2f [%+.2f, %+.2f]", $0.point, $0.low, $0.high) } ?? "—"
            let verdict = diff.map { $0.excludesZero ? "\(Console.bold)real change\(Console.reset)"
                                                     : "\(Console.dim)within noise\(Console.reset)" } ?? "—"
            print("\(pad(name, 16))\(pad(String(format: "%+.2f", va), 10))"
                + "\(pad(String(format: "%+.2f", vb), 10))\(pad(change, 22))\(verdict)")
        }
        row("Mean async", Bootstrap.meanStat)
        row("Spread (SD)", Bootstrap.sdStat)
        row("r₁", Bootstrap.lag1Stat)

        let smaller = min(a.count, b.count)
        if smaller < Bootstrap.minimumTakes {
            print("\n\(Console.yellow)No verdict:\(Console.reset) only \(smaller) take(s) in the "
                + "smaller group. Take-to-take variation is most of the\nvariation here — the "
                + "two benchmark jams a day apart sat 16.7 ms apart on mean asynchrony — so\n"
                + "one take cannot bound a condition. \(Bootstrap.minimumTakes) per side before "
                + "there is anything to compare.")
        } else if smaller < Bootstrap.stableIntervalTakes {
            print("\n\(Console.yellow)Note:\(Console.reset) \(smaller) take(s) in the smaller "
                + "group. The intervals now cover take-to-take variation as well\nas variation "
                + "inside a take, but they are estimated from that many takes, so they are wide "
                + "and\nthemselves coarse. Read a null result as \"not measured yet\" rather "
                + "than \"no difference\".")
        }
    }

    /// Does the player's sense of a good take track the measurement?
    ///
    /// If feel and spread correlate, their instinct is a reliable instrument and can be
    /// trusted mid-practice. If they don't, that gap is itself the finding.
    private static func runFeel(sessions: [JamSession]) {
        let rated = sessions.compactMap { s in s.feelRating.map { (rating: $0, session: s) } }
        Console.heading("Feel vs measurement")
        guard rated.count >= 3 else {
            print("Only \(rated.count) rated take(s). Record a few more — you're asked "
                + "to rate each take before the numbers appear.")
            return
        }

        print("\(pad("Take", 22))\(pad("tag", 12))\(pad("feel", 6))\(pad("SD", 9))mean")
        for (rating, s) in rated {
            let a = asynchronies(of: s)
            print("\(pad(dateLabel(s.date), 22))\(pad(s.tag ?? "—", 12))"
                + "\(pad(String(repeating: "★", count: rating), 6))"
                + "\(pad(Console.ms(Stats.sd(a), 1), 9))\(Console.ms(Stats.mean(a), 1))")
        }

        let feels = rated.map { Double($0.rating) }
        let spreads = rated.map { Stats.sd(asynchronies(of: $0.session)) }
        if let r = Stats.correlation(feels, spreads) {
            print(String(format: "\nfeel vs spread: r = %+.2f", r))
            if rated.count < 6 {
                print("\(Console.dim)Too few takes to read much into this yet — "
                    + "it firms up around 6–8.\(Console.reset)")
            } else if r < -0.5 {
                print("Your instinct is well calibrated: takes that felt good really were tighter.")
            } else if abs(r) < 0.3 {
                print("Your sense of a good take doesn't track your actual precision — worth knowing.")
            }
        }
    }

    /// Print a drill's instructions. Shared text so the console and the app can never
    /// describe the same drill differently.
    private static func printInstructions(_ instructions: DrillInstructions) {
        print("")
        print(instructions.consoleText(bold: Console.bold, reset: Console.reset, dim: Console.dim))
    }

    // MARK: - Tempo calibration

    public static func runTempo(targets: [Double], leadBars: Int, holdBars: Int, rounds: Int,
                                rung: String? = nil) throws {
        Console.heading("Tempo calibration — produce the tempo yourself")
        let prescribed = try parseRung(rung) ?? .quarters
        let config = TrainerEngine.TempoConfig(targets: targets, leadBars: leadBars,
                                               holdBars: holdBars, rounds: rounds,
                                               rung: prescribed)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)")
        let targetText = targets.map { String(Int($0)) }.joined(separator: " / ")
        print("Targets: \(targetText) BPM   ·   \(rounds) rounds   ·   "
            + String(format: "~%.1f min", config.durationSeconds / 60))
        printInstructions(DrillInstructions.tempo(rung: prescribed))
        Console.prompt("Ready?")

        print("")
        // Printed as each round's silence ends, so the correction can be made on the spot.
        let outcome = try TrainerEngine.runTempo(config, roundFinished: { result in
            guard let produced = result.producedBpm, let pct = result.errorPercent else {
                print("  Round \(result.index + 1): \(Console.dim)"
                    + "\(result.unusableReason ?? "not scored")\(Console.reset)")
                return
            }
            let colour = abs(pct) < 2 ? Console.green : (abs(pct) < 5 ? "" : Console.yellow)
            print(String(format: "  Round %d: target %.0f → you played %.1f  \(colour)%+.1f%%\(Console.reset)",
                         result.index + 1, result.targetBpm, produced, pct))
        })
        let feel = Console.readRating("\nHow did that feel?")
        reportTempo(outcome)
        let url = try TrainerEngine.save(outcome, feelRating: feel)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    private static func reportTempo(_ outcome: TrainerEngine.TempoOutcome) {
        let r = outcome.report
        Console.heading("Round by round")
        print("\(pad("Round", 8))\(pad("target", 9))\(pad("you played", 12))\(pad("error", 16))")
        for round in r.rounds {
            guard round.isUsable, let produced = round.producedBpm,
                  let err = round.errorBpm, let pct = round.errorPercent else {
                print("\(pad("\(round.index + 1)", 8))\(pad(String(format: "%.0f", round.targetBpm), 9))"
                    + "\(pad("—", 12))\(Console.dim)\(round.unusableReason ?? "not scored")\(Console.reset)")
                continue
            }
            let colour = abs(pct) < 2 ? Console.green : (abs(pct) < 5 ? "" : Console.yellow)
            print("\(pad("\(round.index + 1)", 8))\(pad(String(format: "%.0f", round.targetBpm), 9))"
                + "\(pad(String(format: "%.1f", produced), 12))"
                + "\(colour)\(pad(String(format: "%+.1f BPM (%+.1f%%)", err, pct), 16))\(Console.reset)")
        }

        Console.heading("Summary")
        guard r.usableCount > 0 else {
            Console.error(r.headline)
            return
        }
        print("\(Console.bold)\(r.headline)\(Console.reset)\n")
        if let bias = r.meanErrorPercent {
            print(String(format: "Bias:      %+.1f%%  (%@)", bias, bias < 0 ? "you run slow" : "you run fast"))
        }
        if let absErr = r.meanAbsErrorPercent {
            print(String(format: "Accuracy:  %.1f%% average error", absErr))
        }
        if let slope = r.improvementPerRound {
            print(String(format: "Trend:     %+.2f%% per round  (%@)", slope,
                         slope < -0.3 ? "tightening" : slope > 0.3 ? "loosening" : "steady"))
        }
        print("Scored:    \(r.usableCount)/\(r.rounds.count) rounds")
    }

    /// Tempo-calibration history.
    private static func runTempoHistory() {
        let sessions = SessionStore.loadAllTempo()
        Console.heading("Tempo calibration history")
        guard !sessions.isEmpty else {
            print("No tempo sessions yet. Try:  TimingSpike tempo 100")
            return
        }
        print("\(pad("When", 22))\(pad("targets", 14))\(pad("bias", 10))\(pad("accuracy", 11))feel")
        for s in sessions {
            let r = s.report()
            let targets = s.targets.map { String(Int($0)) }.joined(separator: "/")
            print("\(pad(dateLabel(s.date), 22))\(pad(targets, 14))"
                + "\(pad(r.meanErrorPercent.map { String(format: "%+.1f%%", $0) } ?? "—", 10))"
                + "\(pad(r.meanAbsErrorPercent.map { String(format: "%.1f%%", $0) } ?? "—", 11))"
                + (s.feelRating.map { String(repeating: "★", count: $0) } ?? "—"))
        }
        print("\n\(Console.dim)Bias is signed (negative = slow). Accuracy is average error "
            + "regardless of direction — that is the number to drive down.\(Console.reset)")
    }

    // MARK: - M11 recall drill

    public static func runMemory(bpm: Double, retentionBars: Int, rounds: Int) throws {
        Console.heading("Recall — is the tempo stored, or just running?")
        let config = TrainerEngine.MemoryConfig(bpm: bpm, referenceBars: 4,
                                                retentionBars: retentionBars,
                                                reproduceBars: 4, rounds: rounds)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)")
        print(String(format: "\n%d rounds at %d BPM, %d-bar wait  ·  ~%.1f min",
                     rounds, Int(bpm), retentionBars, config.durationSeconds / 60))
        printInstructions(DrillInstructions.memory)
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runMemory(config)
        let feel = Console.readRating("\nHow did that feel?")
        reportMemory(outcome)
        let url = try TrainerEngine.save(outcome, feelRating: feel)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    private static func reportMemory(_ outcome: TrainerEngine.MemoryOutcome) {
        let r = outcome.report
        Console.heading("Recall")
        print("\(r.usableCount)/\(r.rounds.count) rounds scored\n")
        print("\(pad("Round", 8))\(pad("wait", 9))\(pad("produced", 11))error")
        for round in r.rounds {
            let condition = round.condition == .silent ? "silent" : "filled"
            if round.isUsable, let produced = round.producedBpm, let pct = round.errorPercent {
                print("\(pad("\(round.index + 1)", 8))\(pad(condition, 9))"
                    + "\(pad(String(format: "%.1f", produced), 11))"
                    + String(format: "%+.1f%%", pct))
            } else {
                print("\(pad("\(round.index + 1)", 8))\(pad(condition, 9))"
                    + "\(Console.dim)\(round.unusableReason ?? "not scored")\(Console.reset)")
            }
        }

        // Per condition, because what each one lost is as much a part of the comparison as
        // what it kept. A single total hides differential attrition entirely.
        print("\nScored: " + r.attrition.map {
            "\($0.condition == .silent ? "silent" : "filled") \($0.scored)/\($0.rounds)"
        }.joined(separator: "   "))

        if let silent = r.silentMeanAbsErrorPercent, let filled = r.filledMeanAbsErrorPercent {
            print(String(format: "Silent wait: %.1f%% off   Filled wait: %.1f%% off", silent, filled))
            if r.attritionIsImbalanced {
                print("\(Console.yellow)Interference cost withheld\(Console.reset) — the two "
                    + "conditions did not lose the same number of rounds.")
            } else if let interval = r.interferenceInterval {
                print(String(format: "Interference cost: %+.1f points [%+.1f, %+.1f]  %@",
                             interval.point, interval.low, interval.high,
                             interval.excludesZero ? "\(Console.bold)real\(Console.reset)"
                                                   : "\(Console.dim)within noise\(Console.reset)"))
            }
        }
        print("\n\(r.headline)")
        for note in r.notes { Console.warn(note) }

        if outcome.suggestedRetentionBars != outcome.config.retentionBars {
            print("\n\(Console.dim)Next time try a \(outcome.suggestedRetentionBars)-bar wait."
                + "\(Console.reset)")
        }
    }

    // MARK: - Offbeat drill

    /// M15: hold the chop between the beats while the beat itself disappears.
    public static func runOffbeat(bpm: Double, bars: Int, level rawLevel: Int,
                                  flags: CommandFlags = CommandFlags()) throws {
        Console.heading("Offbeat drill — hold the chop between the beats")
        guard let level = OffbeatLevel(rawValue: rawLevel) else {
            throw SpikeError("Level must be 0–\(OffbeatLevel.allCases.count - 1): "
                           + OffbeatLevel.allCases
                               .map { "\($0.rawValue) \($0.label)" }.joined(separator: ", "))
        }
        let config = TrainerEngine.JamConfig(bpm: bpm, bars: bars, tag: "offbeat",
                                             offbeatLevel: level)
        try config.validate()
        let env = try TrainerEngine.environment()

        print("Output: \(env.outputName)")
        print("\n\(bars) bars at \(Int(bpm)) BPM  ·  \(Console.bold)level \(level.rawValue) — "
            + "\(level.label)\(Console.reset)"
            + String(format: "  ·  ~%.1f min", config.durationSeconds / 60))
        printInstructions(DrillInstructions.offbeat(level: level))
        announceProbe(flags)
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runJam(config)
        let feel = Console.readRating("\nHow did that feel?")
        let offbeat = OffbeatAnalysis.analyze(matched: outcome.report.matched,
                                              grid: outcome.analysisGrid)
        reportTiming(outcome.report, notesCaptured: outcome.notesCaptured,
                     events: outcome.eventCount, uncalibrated: !env.isCalibrated,
                     grid: outcome.analysisGrid,
                     offbeat: OffbeatContext(report: offbeat, level: level))
        let url = try TrainerEngine.save(outcome, feelRating: feel, wasProbe: flags.isProbe)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    /// Said before the take, not after. A probe is stored differently and read differently, and
    /// a player who did not mean to run one should find out while they can still stop.
    private static func announceProbe(_ flags: CommandFlags) {
        guard flags.isProbe else { return }
        Console.warn("Probe: this take is recorded as a deliberate look at a setting you have "
            + "not earned. Nothing that decides what to practise next will read it, and it "
            + "cannot move a ladder.")
    }

    /// Where the notes went, and — separately — how tightly.
    ///
    /// The two are printed apart because they are different failures. A player who slipped onto
    /// the beat is *precise*, on the wrong points, so a placement figure alone would call a lost
    /// feel an excellent take.
    static func reportOffbeat(_ r: OffbeatReport, level: OffbeatLevel) {
        Console.heading("Where the notes went")

        print(String(format: "Off the beat:     %d of %d  (%.0f%%)",
                     r.onOffbeat, r.onOffbeat + r.onDownbeat, r.offbeatShare * 100))
        if let spread = r.spreadMs, let placement = r.placementMs {
            print("Placement:        \(Console.ms(placement))   "
                + "\(Console.dim)spread \(Console.ms(spread, 1))\(Console.reset)")
        }
        if let onBeat = r.downbeatSpreadMs {
            print("On the beat:      \(Console.ms(onBeat, 1)) spread   "
                + "\(Console.dim)(notes that should not be there)\(Console.reset)")
        }

        print("\n\(r.slipped ? Console.yellow : "")\(r.headline)\(Console.reset)")
        for note in r.notes { Console.warn(note) }

        let next = OffbeatAnalysis.suggestedLevel(
            current: level.rawValue, highest: OffbeatLevel.allCases.count - 1,
            report: r, spreadCeilingMs: 25)
        if next > level.rawValue, let harder = OffbeatLevel(rawValue: next) {
            print("\n\(Console.green)Ready for level \(next) — \(harder.label).\(Console.reset)")
        }
    }

    // MARK: - Rendering a backing to a file

    /// Render every ladder rung, plus the jam backing, to WAV files that can be listened to.
    ///
    /// Auditioning a groove used to mean a live run. A rung the player has never heard is a rung
    /// the planner should not be promoting them onto, and PLAN §7.23 makes that a precondition
    /// for the ladder — so hearing one has to be cheaper than booking a session.
    public static func runRender(bpm: Double, bars: Int, into directory: URL) throws {
        Console.heading("Rendering backings")
        guard (40...260).contains(bpm) else { throw SpikeError("Tempo must be 40–260 BPM.") }
        guard (1...64).contains(bars) else { throw SpikeError("Bars must be 1–64.") }

        let fs = 44_100.0
        let kit = BackingKit(sampleRate: fs)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The ceiling is a fact about *this* player, so it comes from their own takes rather
        // than a constant. Falling back to a stated default is better than refusing to render.
        let spreads = TrainerEngine.recentJamSpreadsMs()
        let spreadMs = spreads.isEmpty ? SessionPlanner.assumedSpreadMs : Stats.median(spreads)

        // Feels are rendered beside the straight rungs, because a swing is a thing you judge by
        // ear or not at all. A step list cannot say whether 1.5:1 sounds like a shuffle or like
        // a mistake, and §7.23's rule — do not promote onto a rung nobody has heard — applies to
        // a feel at least as strongly.
        let subjects: [(name: String, rung: IntervalRung?, feel: Feel, arrangement: Arrangement)] =
            [("quarters", .quarters, .straight, LadderBackings.backing(notesPerBeat: 1)),
             ("eighths", .eighths, .straight, LadderBackings.backing(notesPerBeat: 2)),
             ("triplet-eighths", .tripletEighths, .straight, LadderBackings.backing(notesPerBeat: 3)),
             ("sixteenths", .sixteenths, .straight, LadderBackings.backing(notesPerBeat: 4)),
             ("eighths-swung-1.5", .eighths, Feel(swingRatio: 1.5) ?? .straight,
              LadderBackings.swungBacking(notesPerBeat: 2)),
             ("eighths-swung-2.0", .eighths, .swung, LadderBackings.swungBacking(notesPerBeat: 2)),
             ("eighths-swung-3.0", .eighths, Feel(swingRatio: 3) ?? .straight,
              LadderBackings.swungBacking(notesPerBeat: 2)),
             ("sixteenths-swung-1.5", .sixteenths, Feel(swingRatio: 1.5) ?? .straight,
              LadderBackings.swungBacking(notesPerBeat: 4)),
             ("jam-backing", nil, .straight, GrooveLibrary.jamBacking),
             // The bass, so it can be judged by ear before a style is built on it. Nothing
             // frozen carries it (§7.29 step 2).
             ("bass-demo", nil, .straight, GrooveLibrary.bassDemo)]

        print(String(format: "%d BPM · %d bars each · ceilings from your own spread of %.1f ms%@",
                     Int(bpm), bars, spreadMs,
                     spreads.isEmpty ? " (no takes yet — assumed)" : ""))
        print("")
        for (name, rung, feel, arrangement) in subjects {
            // The same conversion the engine makes, so what is rendered is what would be played.
            let swing = Swing(ratio: feel.swingRatio, notesPerBeat: rung?.subdivisions ?? 1)
            let sequencer = Sequencer(bpm: bpm, sampleRate: fs, swing: swing)
            var hits: [ScheduledHit] = []
            for bar in 0..<bars {
                hits += sequencer.schedule(pattern: arrangement.pattern(atBar: bar), bar: bar)
            }
            // A beat of tail so the last hit is not cut off mid-decay.
            let frames = Int((Double(bars) * 4 + 1) * 60 / bpm * fs)
            let samples = GrooveOfflineRender.mix(hits: hits, kit: kit, frames: frames)

            let url = directory.appendingPathComponent("\(name)-\(Int(bpm))bpm.wav")
            let clipped = try WaveFile.write(samples, sampleRate: fs, to: url)
            let peak = samples.map(abs).max() ?? 0
            // Above its ceiling a rung starts discarding notes the player aimed correctly, so
            // the render says so rather than letting it be judged only by ear.
            // Above its ceiling the window is worth fewer than three of the player's spreads.
            // A feel tightens that further, because the short half of a swung pair is shorter
            // than an even division — so the ceiling is asked of the feel, not the rung alone.
            var note = ""
            if let rung {
                let ceiling = feel.maximumBpm(subdivisions: rung.subdivisions,
                                              forSpreadMs: spreadMs)
                if bpm > ceiling {
                    note = String(format: "  %@above its %.0f BPM ceiling%@", Console.yellow,
                                  ceiling, Console.reset)
                }
            }
            print("  \(pad(name, 22))\(pad(String(format: "peak %.2f", peak), 12))"
                + "\(pad(url.lastPathComponent, 30))\(note)")
            if clipped > 0 {
                Console.warn("\(name) clipped on \(clipped) sample(s) — the mix is too hot, and "
                           + "that would be heard as a bad groove rather than a bad gain.")
            }
        }
        print("\n\(Console.dim)Listen before letting the planner promote you onto a rung. "
            + "Whether a groove is\nplayable-along-to is not something its step list can "
            + "say.\(Console.reset)")
    }

    // MARK: - Dropout drill

    public static func runDropout(bpm: Double, pacedBars: Int, silentBars: Int, cycles: Int,
                                  rung: String? = nil) throws {
        Console.heading("Dropout drill — hold the pulse alone")
        let prescribed = try parseRung(rung) ?? .quarters
        let config = TrainerEngine.DropoutConfig(bpm: bpm, pacedBars: pacedBars,
                                                 silentBars: silentBars, cycles: cycles,
                                                 rung: prescribed)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)")

        print("\n\(Console.bold)\(cycles) cycles\(Console.reset): \(pacedBars) bars with the band, "
            + "\(silentBars) bars alone  ·  "
            + String(format: "~%.1f min", config.durationSeconds / 60))
        printInstructions(DrillInstructions.dropout(rung: prescribed))
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runDropout(config)
        let feel = Console.readRating("\nHow did that feel?")
        reportDropout(outcome)
        let url = try TrainerEngine.save(outcome, feelRating: feel)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    private static func reportDropout(_ outcome: TrainerEngine.DropoutOutcome) {
        let r = outcome.report
        Console.heading("Your pulse, unaccompanied")
        print("Notes played: \(outcome.notesPlayed)   "
            + "(\(r.pacedNoteCount) with the band, \(r.unpacedNoteCount) alone)")
        print("Silences:     \(r.trials.count)")

        guard r.unpacedNoteCount >= 12 else {
            Console.error("\n\(r.headline)")
            return
        }

        print("\n\(Console.bold)\(r.headline)\(Console.reset)\n")

        if r.discardedTrials > 0 {
            Console.warn("\(r.discardedTrials) of \(r.trials.count) silences were discarded — "
                + "they weren't one note per beat. Keep to steady quarters, no subdividing.")
            print("")
        }

        // Said out loud, and with what it is for: a hesitation is not a noisy beat, and the
        // clock/motor figures below are computed over the stretches either side of it rather
        // than through it. Nine such intervals once reported a 193.5 ms clock (§7.25).
        if r.brokenIntervals > 0 {
            Console.warn("\(r.brokenIntervals) gap(s) in the playing — a pause or a dropped note "
                + "— split the silences into shorter runs. The split below is measured on the "
                + "runs, because a gap is the sequence restarting rather than one late beat.")
            print("")
        }

        if let wk = r.wingKristofferson, r.splitIsReliable {
            // The whole reason this drill exists — two numbers no amount of playing by feel
            // can separate.
            print("\(Console.bold)Clock\(Console.reset) (the pulse in your head):  \(Console.ms(wk.clockSDms))")
            print("\(Console.bold)Motor\(Console.reset) (your hands executing it): \(Console.ms(wk.motorSDms))")
            print("\(Console.dim)from \(wk.intervalCount) intervals across \(r.trials.count) silences\(Console.reset)")
        } else {
            Console.warn("""
                the clock/motor split isn't trustworthy from this take. It needs several
                silences of steady quarter notes with no systematic speed change; a motor
                estimate near zero means the model hit its floor rather than measuring you.
                The tempo figures below still stand.
                """)
        }

        print("")
        if let played = r.playedBpm, let bias = r.tempoBiasBpm {
            // The most robust number this drill produces, and the most actionable.
            print(String(format: "Tempo alone:           %.1f BPM  (%+.1f vs the click, %+.1f%%)",
                         played, bias, bias / outcome.config.bpm * 100))
        }
        if !r.pacedSDms.isNaN {
            print("Spread with the band:  \(Console.ms(r.pacedSDms))")
        }
        if !r.unpacedIntervalSDms.isNaN {
            print("Beat-to-beat spread:   \(Console.ms(r.unpacedIntervalSDms))  "
                + "\(Console.dim)(while alone)\(Console.reset)")
        }
        if let within = r.meanWithinTrialDriftMsPerBeat, abs(within) > 0.5 {
            // Distinct from sitting at a steady wrong tempo: this is the period changing
            // *during* a silence.
            print(String(format: "Speeding/slowing:      %+.2f ms per beat within each silence", within))
        }
        if !r.reentryErrorMeanMs.isNaN {
            let sd = r.reentryErrorSDms.isNaN ? "" : "  ± \(Console.ms(r.reentryErrorSDms, 0))"
            print("Re-entry error:        \(Console.ms(r.reentryErrorMeanMs, 0))\(sd)"
                + "  \(Console.dim)(where you were when the band came back)\(Console.reset)")
        }

        if outcome.suggestedSilentBars != outcome.config.silentBars {
            let longer = outcome.suggestedSilentBars > outcome.config.silentBars
            print("\n\(longer ? Console.green : Console.yellow)"
                + "Try \(outcome.suggestedSilentBars) silent bars next\(Console.reset)"
                + (longer ? " — you held that comfortably." : " — that was slipping away."))
            print("\(Console.dim)TimingSpike dropout \(Int(outcome.config.bpm)) "
                + "\(outcome.config.pacedBars) \(outcome.suggestedSilentBars) "
                + "\(outcome.config.cycles)\(Console.reset)")
        }
    }

    /// M14: does tempo change how you play?
    private static func runIntervalResponse() {
        Console.heading("Tempo and interval")
        print("\(Console.dim)Subdivision and tempo are one axis — both move the gap between "
            + "notes, and eighths at 100 BPM\nare the same 300 ms task as quarters at 200. "
            + "Spread is shown relative to that gap, because\nscatter grows with the interval "
            + "it sits inside.\(Console.reset)\n")

        let report = IntervalResponseAnalysis.analyze(TrainerEngine.intervalObservations())
        guard !report.buckets.isEmpty else {
            print("No takes yet.")
            return
        }

        print(pad("interval", 12) + pad("tempo", 10) + pad("takes", 7)
            + pad("spread", 11) + pad("of interval", 13) + "placement")
        for bucket in report.buckets {
            let spread = bucket.meanSpreadMs.map { String(format: "%.1f ms", $0) } ?? "—"
            let relative = bucket.relativeSpreadPercent.map { String(format: "%.1f%%", $0) } ?? "—"
            let bias = bucket.meanBiasMs.map { String(format: "%+.1f ms", $0) } ?? "—"
            let sittings = bucket.sittings <= 1 && bucket.takes > 1 ? "  one sitting" : ""
            print(pad(String(format: "%.0f ms", bucket.intervalMs), 12)
                + pad(String(format: "%.0f BPM", bucket.bpm), 10)
                + pad("\(bucket.takes)", 7)
                + pad(spread, 11) + pad(relative, 13) + pad(bias, 11)
                + "\(Console.dim)\(sittings)\(Console.reset)")
        }

        func row(_ label: String, _ fit: TrendFit?, _ unit: String) {
            guard let fit else {
                print("  \(pad(label, 26))\(Console.dim)not enough range\(Console.reset)")
                return
            }
            let verdict = fit.isReal ? "\(Console.bold)real\(Console.reset)"
                                     : "\(Console.dim)within noise\(Console.reset)"
            print("  \(pad(label, 26))"
                + pad(String(format: "%+.2f%@ [%+.2f, %+.2f]", fit.slope * 100, unit,
                             fit.low * 100, fit.high * 100), 34) + verdict)
        }
        print("\nPer 100 ms of extra interval:")
        row("spread, milliseconds", report.absoluteSpreadVsInterval, " ms")
        row("spread, % of interval", report.relativeSpreadVsInterval, " pts")
        row("placement", report.biasVsInterval, " ms")

        print("\n\(report.headline)")
        for note in report.notes { Console.warn(note) }

        printProducedIntervals()
    }

    /// The same question asked of notes instead of takes — and the one that can be answered.
    ///
    /// `review interval` above compares whole takes at the interval each was *asked* for, and on
    /// today's history that is one interval per tempo and three tempos, so it refuses. Within a
    /// take the player produces several intervals by choice, which is thousands of notes across
    /// a real range, and the question of which description of spread survives a change of
    /// interval is answerable there now. See PLAN.md §7.23.
    private static func printProducedIntervals() {
        let profile = TrainerEngine.producedIntervalProfile()
        guard !profile.bins.isEmpty else { return }

        Console.heading("The intervals you actually produce")
        print("\(Console.dim)Each note keyed by the gap in grid points to the note before it, "
            + "never by the measured\ngap — a note's own error sits inside its measured gap, and "
            + "binning on that fabricates\na placement slope out of a player who has "
            + "none.\(Console.reset)\n")

        print(pad("interval", 12) + pad("notes", 9) + pad("share", 9)
            + pad("spread", 11) + pad("of interval", 13) + "placement")
        for bin in profile.bins {
            print(pad(String(format: "%.0f ms", bin.intervalMs), 12)
                + pad("\(bin.notes)", 9)
                + pad(String(format: "%.1f%%", bin.shareOfNotes * 100), 9)
                + pad(String(format: "%.1f ms", bin.sdMs), 11)
                + pad(String(format: "%.1f%%", bin.relativeSpreadPercent), 13)
                + String(format: "%+.1f ms", bin.meanMs))
        }

        func row(_ label: String, _ fit: TrendFit?, _ unit: String) {
            guard let fit else {
                print("  \(pad(label, 26))\(Console.dim)not enough range\(Console.reset)")
                return
            }
            print("  \(pad(label, 26))"
                + pad(String(format: "%+.2f%@ [%+.2f, %+.2f]", fit.slope * 100, unit,
                             fit.low * 100, fit.high * 100), 34)
                + (fit.isReal ? "\(Console.bold)real\(Console.reset)"
                              : "\(Console.dim)within noise\(Console.reset)"))
        }
        print("\nPer 100 ms of extra interval:")
        row("spread, milliseconds", profile.absoluteFit, " ms")
        row("spread, % of interval", profile.relativeFit, " pts")
        row("placement", profile.placementFit, " ms")

        print("\n\(profile.headline)")
        for note in profile.notes { Console.warn(note) }
    }

    /// M13: what the experiments have collected, and what they are allowed to say.
    private static func runExperiments() {
        Console.heading("Experiments")
        print("\(Console.dim)Arms are assigned before you play and balanced against what has "
            + "already run. Nothing is\ncompared until every arm reaches the number of takes "
            + "declared up front — the app re-runs this\nafter every session, and that is "
            + "optional stopping unless the finish line was fixed first.\(Console.reset)")

        for result in TrainerEngine.experimentResults() {
            let design = result.design
            print("\n\(Console.bold)\(design.name)\(Console.reset)  "
                + "\(Console.dim)\(design.metric.label) · \(design.takesPerArm) takes per "
                + "arm\(Console.reset)")
            print("  \(Console.dim)\(design.question)\(Console.reset)")

            print("  " + pad("arm", 12) + pad("takes", 8) + pad("mean", 12)
                + pad("between takes", 12) + "density")
            for arm in result.arms {
                let mean = arm.mean.map { String(format: "%+.2f", $0) } ?? "—"
                let sd = arm.betweenTakeSD.map { String(format: "± %.2f", $0) } ?? "—"
                // Density is a covariate, printed beside the metric and never scored against
                // it. For an instruction-only experiment about what is played, the arms differ
                // here by construction — see `ExperimentTake.notesPerBeat`.
                let density = arm.meanNotesPerBeat
                    .map { String(format: "%.2f/beat", $0) } ?? "—"
                print("  " + pad(arm.arm, 12)
                    + pad("\(arm.scored)/\(design.takesPerArm)", 8)
                    + pad(mean, 12) + pad(sd, 12) + "\(Console.dim)\(density)\(Console.reset)")
            }

            switch result.verdict {
            case .collecting:
                break      // the headline below already says how many are left
            case .unusable(let reason):
                Console.warn(reason)
            case .noDifferenceFound, .difference:
                if let d = result.difference {
                    print(String(format: "  Difference: %+.2f [%+.2f, %+.2f]  %@",
                                 d.point, d.low, d.high,
                                 d.excludesZero ? "\(Console.bold)real\(Console.reset)"
                                                : "\(Console.dim)within noise\(Console.reset)"))
                }
            }
            if let mde = result.minimumDetectableEffect {
                print(String(format: "  \(Console.dim)Smallest difference %d takes per arm "
                           + "could separate from zero: %.2f\(Console.reset)",
                             design.takesPerArm, mde))
            }
            print("  \(result.headline)")
            for note in result.notes { Console.warn(note) }
        }
    }

    /// M12: does what you play change how you time it?
    ///
    /// Correlates content against timing spread **within** each take, which holds the day, the
    /// tempo, the backing and the fatigue fixed. What it cannot hold fixed is printed with the
    /// result rather than assumed away.
    private static func runContent() {
        Console.heading("What you play")
        print("\(Console.dim)Within a take, does more interesting playing go with tighter "
            + "timing? Within-take holds the day,\nthe tempo and the fatigue fixed — so a "
            + "relationship here cannot be explained by any of them.\(Console.reset)")

        let sessions = SessionStore.loadAll()
        let withPitch = sessions.filter(\.hasPitchData)
        guard !withPitch.isEmpty else {
            print("\nNo take has pitch data yet. Note numbers have been recorded since "
                + "4 August 2026; play a jam and this fills in.")
            return
        }
        if withPitch.count < sessions.count {
            Console.warn("\(sessions.count - withPitch.count) of \(sessions.count) takes predate "
                       + "pitch recording and cannot be analysed.")
        }

        for session in withPitch {
            let r = session.contentReport()
            print("\n\(Console.bold)\(dateLabel(session.date))\(Console.reset)  "
                + "\(Console.dim)\(Int(session.bpm)) BPM · \(session.bars) bars · "
                + "\(r.windows.count) window(s)\(Console.reset)")

            for c in r.correlations {
                let strength = abs(c.r) < 0.3 ? "\(Console.dim)flat\(Console.reset)"
                    : c.r < 0 ? "\(Console.green)tighter\(Console.reset)"
                              : "\(Console.yellow)looser\(Console.reset)"
                print("  \(pad(c.measure, 20))" + pad(String(format: "r = %+.2f", c.r), 14) + strength)
            }
            print("  \(r.headline)")
            for note in r.notes { Console.warn(note) }
        }

        print("\n\(Console.dim)\"tighter\" means more of that measure went with less timing "
            + "spread. One take is a hypothesis;\nthe experiment runner (M13) is what turns "
            + "these into a result.\(Console.reset)")
    }

    /// M10: is the improvement warming up, or getting better?
    private static func runCold() {
        Console.heading("Cold vs warm")
        print("\(Console.dim)Improvement inside a sitting is warming up. Improvement in the "
            + "*cold* take across sittings is learning.\nOnly the second survives a night's "
            + "sleep, and one slope across all takes cannot tell them apart.\(Console.reset)")

        for kind in TrainerEngine.DrillKind.allCases {
            let report = TrainerEngine.warmUpReport(for: kind)
            print("\n\(Console.bold)\(label(for: kind))\(Console.reset)"
                + "  (\(report.takeCount) takes across \(report.sessionCount) sitting(s))")

            row("within a sitting", report.withinSession, unit: "/min")
            row("cold, per sitting", report.betweenSessions, unit: "/sitting")

            print("  \(report.headline)")
            for note in report.notes { Console.warn(note) }
        }
    }

    private static func row(_ label: String, _ fit: TrendFit?, unit: String) {
        guard let fit else {
            print("  \(pad(label, 20))\(Console.dim)not enough data\(Console.reset)")
            return
        }
        let verdict: String
        switch fit.verdict {
        case .flat:      verdict = "\(Console.dim)flat\(Console.reset)"
        case .improving: verdict = "\(Console.green)improving\(Console.reset)"
        case .worsening: verdict = "\(Console.yellow)worsening\(Console.reset)"
        }
        print("  \(pad(label, 20))"
            + pad(String(format: "%+.3f%@ [%+.3f, %+.3f]", fit.slope, unit, fit.low, fit.high), 34)
            + verdict)
    }

    private static func label(for kind: TrainerEngine.DrillKind) -> String {
        switch kind {
        case .jam:     return "Jams — spread"
        case .form:    return "Form — on-form rate"
        case .dropout: return "Continuation — |tempo bias|"
        case .tempo:   return "Tempo drill — error"
        case .memory:  return "Recall drill — interference cost"
        }
    }

    /// M7: is anything actually improving?
    ///
    /// Fits each metric against take number and reports the slope with a bootstrap interval,
    /// so "my spread is coming down" is either supported or isn't. Confounded groups are
    /// split rather than blended — a tempo change moves timing spread on its own, and a trend
    /// computed across the change would be measuring the tempo, not the player.
    private static func runTrend() {
        Console.heading("Trends")

        let series = TrainerEngine.trends()
        guard !series.isEmpty else {
            print("\nNo takes recorded yet.")
            return
        }

        for group in series {
            print("\n\(Console.bold)\(group.title)\(Console.reset)  (\(group.takeCount) takes)")
            for warning in group.warnings { Console.warn(warning) }
            for row in group.rows {
                guard let fit = row.fit else {
                    print("  \(pad(row.label, 16))\(Console.dim)"
                        + "\(row.values.count) usable point(s) — need \(TrendAnalysis.minimumPoints)"
                        + "\(Console.reset)")
                    continue
                }
                let verdict: String
                switch fit.verdict {
                case .flat:      verdict = "\(Console.dim)flat\(Console.reset)"
                case .improving: verdict = "\(Console.green)improving\(Console.reset)"
                case .worsening: verdict = "\(Console.yellow)worsening\(Console.reset)"
                }
                print("  \(pad(row.label, 16))"
                    + pad(String(format: "%+.2f/take [%+.2f, %+.2f]", fit.slope, fit.low, fit.high), 30)
                    + verdict)
            }
        }

        print("\n\(Console.dim)Slope is change per take, with a 95% interval. "
            + "\"flat\" means the interval includes zero. Every figure is recomputed from the "
            + "raw taps, so an analysis fix reaches older takes.\(Console.reset)")
    }

    /// Continuation-drill history — the clock/motor split over time.
    private static func runDropoutHistory() {
        let sessions = SessionStore.loadAllDropout()
        Console.heading("Dropout drill history")
        guard !sessions.isEmpty else {
            print("No dropout drills yet. Try:  TimingSpike dropout 100 4 4 6")
            return
        }
        print("\(pad("When", 22))\(pad("cycle", 10))\(pad("clock", 10))"
            + "\(pad("motor", 10))\(pad("tempo alone", 14))feel")
        for s in sessions {
            // Recomputed from the raw taps so older takes get the current analysis.
            let r = s.report()
            let clock = r.splitIsReliable ? Console.ms(r.wingKristofferson?.clockSDms ?? .nan, 1) : "—"
            let motor = r.splitIsReliable ? Console.ms(r.wingKristofferson?.motorSDms ?? .nan, 1) : "—"
            let tempo = r.playedBpm.map { String(format: "%.0f (%+.0f)", $0, r.tempoBiasBpm ?? 0) } ?? "—"
            print("\(pad(dateLabel(s.date), 22))\(pad("\(s.pacedBars)+\(s.silentBars)×\(s.cycles)", 10))"
                + "\(pad(clock, 10))\(pad(motor, 10))\(pad(tempo, 14))"
                + (s.feelRating.map { String(repeating: "★", count: $0) } ?? "—"))
        }
        print("\n\(Console.dim)Clock = stability of the pulse itself. Motor = execution noise. "
            + "Lower is better for both.\(Console.reset)")
    }

    // MARK: - Form drill

    /// Landmark strength for the form drill — how much the music tells you where you are.
    public static func runForm(bpm: Double, bars: Int, phraseBars: Int, level rawLevel: Int,
                               flags: CommandFlags = CommandFlags()) throws {
        Console.heading("Form drill — feel the phrase")
        guard let level = FormLevel(rawValue: rawLevel) else {
            throw SpikeError("Level \(rawLevel) out of range (0–3).")
        }
        let config = TrainerEngine.FormConfig(bpm: bpm, bars: bars,
                                              phraseBars: phraseBars, level: level)
        _ = try TrainerEngine.environment()

        print("\n\(Console.bold)\(config.phrases) phrases of \(phraseBars) bars\(Console.reset) "
            + "at \(Int(bpm)) BPM  ·  "
            + String(format: "~%.1f min", config.durationSeconds / 60))
        print("Landmarks: \(level.label)")
        printInstructions(DrillInstructions.form(level: level.rawValue))
        announceProbe(flags)
        if level.hasArrivalAccent {
            print("\n  \(Console.dim)At this level a crash cymbal lands exactly on the beat you are\n"
                + "  aiming for — including the very first bar. Land with it, not after it.\(Console.reset)")
        } else {
            print("\n  \(Console.dim)\(level.advice)\(Console.reset)")
        }
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runForm(config)
        let feel = Console.readRating("\nHow did that feel?")
        reportForm(outcome.report, level: level, keyNotes: outcome.notesPlayed)
        let url = try TrainerEngine.save(outcome, feelRating: feel, wasProbe: flags.isProbe)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    private static func reportForm(_ report: FormReport, level: FormLevel, keyNotes: Int) {
        Console.heading("Your form sense")
        print("Phrases:  \(report.phrasesAvailable)   Marks placed: \(report.marksPlaced)"
            + (keyNotes > 0 ? "   (\(keyNotes) notes played)" : ""))

        guard report.marksPlaced >= 3 else {
            Console.error("\n\(report.headline)")
            if report.marksPlaced == 0 {
                print("""

                No pad hits were captured. The drill listens on MIDI channel 10 (the pads).
                Check the pads register with:  TimingSpike midimon
                """)
            }
            return
        }

        print("\n\(Console.bold)\(report.headline)\(Console.reset)\n")

        let pct = Int((report.onFormRate * 100).rounded())
        print("On the right bar: \(report.onFormCount)/\(report.marksPlaced)  (\(pct)%)")
        print("Nailed it:        \(report.tightCount)/\(report.marksPlaced)"
            + "  \(Console.dim)(within \(Console.ms(report.tightToleranceMs, 0)) of the downbeat)\(Console.reset)")

        // The histogram is the clearest picture of *how* the form is missed.
        let keys = report.formErrorHistogram.keys.sorted()
        if keys.count > 1 || keys.first != 0 {
            let bars = report.formErrorHistogram.sorted { $0.key < $1.key }.map { k, count -> String in
                let label = k == 0 ? "on" : (k > 0 ? "+\(k)" : "\(k)")
                return "\(label): \(count)"
            }.joined(separator: "   ")
            print("Bars off:         \(bars)")
        }

        if !report.phaseErrorSDms.isNaN {
            print("Placement:        \(Console.ms(report.phaseErrorMeanMs, 0)) mean, "
                + "\(Console.ms(report.phaseErrorSDms, 0)) SD  \(Console.dim)(on-form marks only)\(Console.reset)")
        }
        if let slip = report.slipBarsPerPhrase, abs(slip) > 0.05 {
            print(String(format: "Slip:             %+.2f bars per phrase", slip))
        }
        if !report.missedPhrases.isEmpty {
            print("Unmarked phrases: \(report.missedPhrases.map(String.init).joined(separator: ", "))"
                + "  \(Console.dim)(lost the thread, or a whole phrase behind)\(Console.reset)")
        }

        // With a crash on the downbeat, a consistently late mark means the crash is being
        // *reacted to* rather than anticipated — human reaction time is ~150-250 ms, so a
        // mean in that band is the signature. Worth naming, because it feels like success.
        if level.hasArrivalAccent, !report.phaseErrorMeanMs.isNaN, report.phaseErrorMeanMs > 120 {
            print("\n\(Console.yellow)You're reacting to the crash, not arriving with it\(Console.reset) — "
                + "marks land \(Console.ms(report.phaseErrorMeanMs, 0)) after the downbeat, about\n"
                + "reaction-time distance. Try to commit to the turn before you hear it land.")
        }

        // Only suggest moving on when the current level is genuinely solid.
        if report.onFormRate >= 0.9, report.missedPhrases.isEmpty, level.rawValue < 3 {
            print("\n\(Console.green)Solid at this level.\(Console.reset) Try:  "
                + "TimingSpike form 100 64 8 \(level.rawValue + 1)")
        }
    }

    // MARK: - M3 groove

    public static func runGroove(bpm: Double) throws {
        Console.heading("Groove")
        let config = TrainerEngine.GrooveConfig(bpm: bpm, bars: 48)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)  @ \(Int(env.sampleRate)) Hz")
        print("Tempo:  \(Int(bpm)) BPM")
        printInstructions(DrillInstructions.groove)
        print(String(format: "\nPlaying ~%.0f s.\n", config.durationSeconds))
        try TrainerEngine.playGroove(config)
        print("Done.")
    }

    public static func runReset() throws {
        let url = Calibration.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No calibration stored — nothing to reset.")
            return
        }
        guard Console.confirm("Delete all stored calibration?") else {
            print("Left unchanged.")
            return
        }
        try FileManager.default.removeItem(at: url)
        print("Calibration cleared.")
    }

    public static func runCalibrate(quick: Bool) throws {
        Console.heading(quick ? "Quick calibration (loopback only)" : "Full calibration")
        let env = try checkEnvironment()
        var store = Calibration.load()
        let identity = env.output.identity
        let displayName = env.output.dataSource.map { "\(env.output.name) — \($0)" } ?? env.output.name

        if quick, store.referenceDevice == nil {
            throw SpikeError("""
                No reference calibration exists yet. Run a full calibration first:
                    TimingSpike calibrate
                """)
        }
        if quick, store.devices[identity]?.residualMs != nil {
            Console.warn("this device already has a directly-measured constant. A quick run "
                + "will refresh its loopback figures but keep that constant.")
        }

        print("\nCalibrating output device: \(Console.bold)\(displayName)\(Console.reset)")
        if let existing = store.devices[identity] {
            Console.warn("this device was already calibrated on "
                + "\(existing.measuredAt.formatted(date: .abbreviated, time: .shortened)) — it will be updated.")
        }

        print("""

        The microphone must hear this device. For internal speakers that is automatic; for
        headphones, rest one earcup against the built-in microphone.
        """)
        let centimetres = Console.readDouble(
            "Distance from the sound source to the microphone, in cm", default: 15)
        let airPath = Calibration.airPathMs(centimetres: centimetres)
        print("  → acoustic travel \(Console.ms(airPath, 3))")

        Console.prompt("Ready to measure round-trip latency (about 12 seconds).")
        print("Measuring...")
        let loopback = try Procedures.loopback()
        let latency = try reportLoopback(loopback)

        if latency.sd > 0.5 {
            Console.warn("round-trip SD is \(Console.ms(latency.sd)) — unusually noisy. "
                + "Check for background noise before trusting this.")
        }

        var device = Calibration.Device(
            displayName: displayName,
            roundTripMs: latency.median,
            roundTripSD: latency.sd,
            airPathMs: airPath,
            sampleRate: loopback.outputSampleRate,
            bufferFrames: env.output.bufferFrameSize,
            measuredAt: Date(),
            residualMs: nil,
            residualSD: nil)

        if !quick {
            let midi = try startMIDI()
            defer { midi.end() }
            store.midiSource = midi.sourceNames.first

            Console.prompt("""
                Now the two-path measurement, which pins down MIDI latency as well.

                  • Hit ONE key, FIRMLY, roughly halfway between each pair of chirps.
                  • Your accuracy is irrelevant; the strike only needs to be clear of the
                    chirps and audible to the microphone.

                About 100 seconds.
                """)

            let (result, bufferFrames) = try Procedures.twoPath(midi: midi)
            print("\nPaired beats: \(result.pairedBeats)"
                + "   (\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched)")

            guard result.pairedBeats >= 20 else {
                explainPairingFailure(result)
                throw SpikeError("Calibration aborted — not enough paired beats.")
            }
            guard result.sd < 1.0 else {
                throw SpikeError("Residual SD is \(Console.ms(result.sd)), too unstable to "
                               + "store as a calibration. Re-run in a quieter room.")
            }
            _ = bufferFrames

            print("Residual: median \(Console.ms(result.median))   SD \(Console.ms(result.sd))")
            device.residualMs = result.median
            device.residualSD = result.sd
            store.referenceDevice = identity
        }

        store.record(identity: identity, device)
        try store.save()

        Console.heading("Stored")
        printCalibration(store, highlighting: identity)
        print("\n\(Console.dim)\(Calibration.storeURL.path)\(Console.reset)")
    }

    public static func runShow() throws {
        let store = Calibration.load()
        Console.heading("Calibration")
        guard !store.devices.isEmpty else {
            print("Nothing stored yet. Run:  TimingSpike calibrate")
            return
        }
        let current = AudioDevices.defaultDevice(input: false)?.identity
        printCalibration(store, highlighting: current)
        print("\n\(Console.dim)\(Calibration.storeURL.path)\(Console.reset)")

        if let current, store.devices[current] == nil {
            print("")
            Console.warn("""
                the current output device (\(current)) has no calibration.
                    TimingSpike calibrate quick
                """)
        }
    }

    private static func printCalibration(_ store: Calibration, highlighting current: String?) {
        if let source = store.midiSource { print("MIDI source: \(source)") }
        if let reference = store.referenceDevice { print("Reference:   \(reference)") }
        print("")

        for identity in store.devices.keys.sorted() {
            guard let device = store.devices[identity] else { continue }
            let marker = identity == current ? "▸ " : "  "
            let emphasis = identity == current ? Console.bold : ""
            let isReference = identity == store.referenceDevice
            print("\(marker)\(emphasis)\(device.displayName)\(Console.reset)"
                + (isReference ? "  \(Console.dim)(reference)\(Console.reset)" : ""))
            print("    round trip   \(Console.ms(device.roundTripMs))  (SD \(Console.ms(device.roundTripSD)))")
            print("    air path     \(Console.ms(device.airPathMs, 3))")

            if let constant = store.constant(for: identity) {
                switch constant.source {
                case .measured:
                    print("    constant     \(Console.bold)\(Console.ms(constant.value))\(Console.reset)"
                        + "  measured directly"
                        + (constant.sd.map { " (SD \(Console.ms($0)))" } ?? ""))
                case .derived(let from):
                    let fromName = store.devices[from]?.displayName ?? from
                    print("    constant     \(Console.bold)\(Console.ms(constant.value))\(Console.reset)"
                        + "  derived from \(fromName)")
                }
            } else {
                print("    constant     \(Console.yellow)unavailable — no reference calibration\(Console.reset)")
            }
            print("    measured     \(device.measuredAt.formatted(date: .abbreviated, time: .shortened))")
        }

        print("""

        \(Console.dim)The constant is L_midi + L_out: subtract it from (midiHostTime −
        clickEmitHostTime) to get true asynchrony.\(Console.reset)
        """)
    }
}
