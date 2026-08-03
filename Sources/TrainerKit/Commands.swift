import Foundation
import GrooveCore
import TimingCore

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
        guard Console.confirm("\nStart the session?") else { return }

        let runner = SessionRunner(plan: plan)
        var endedEarly = false

        while let block = runner.currentBlock {
            Console.heading("\(runner.index + 1)/\(plan.blocks.count) — \(block.plan.drillName)")
            print("\(Console.dim)\(block.plan.settingsLabel)"
                + String(format: " · %.0f min\(Console.reset)", block.estimatedSeconds / 60))
            print("\n\(block.reason)")
            printInstructions(instructions(for: block.plan))
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

    private static func instructions(for plan: BlockPlan) -> DrillInstructions {
        switch plan {
        case .groove:  return .groove
        case .jam:     return .jam
        case .form:    return .form
        case .dropout: return .dropout
        case .tempo:   return .tempo
        }
    }

    // MARK: - M4 jam

    public static func runJam(bpm: Double, bars: Int, tag: String?) throws {
        Console.heading("Jam — record a take")
        let config = TrainerEngine.JamConfig(bpm: bpm, bars: bars, tag: tag?.lowercased())
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
        printInstructions(DrillInstructions.jam)
        Console.prompt("Ready?")

        let outcome = try TrainerEngine.runJam(config)

        // Rate the take BEFORE any numbers appear, so the rating is an honest read of the
        // experience rather than a rationalisation of the measurement.
        let feel = Console.readRating("\nHow did that feel?")
        reportTiming(outcome.report, notesCaptured: outcome.notesCaptured,
                     events: outcome.eventCount, uncalibrated: !env.isCalibrated)
        let url = try TrainerEngine.save(outcome, feelRating: feel)
        print("\n\(Console.dim)Saved \(url.lastPathComponent)\(Console.reset)")
    }

    private static func reportTiming(_ report: TimingReport, notesCaptured: Int, events: Int,
                                     uncalibrated: Bool) {
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
            return
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
        print("Spread (SD):      \(Console.ms(report.sdAsynchronyMs))\(ci(sdCI))   \(precisionWord(report.sdAsynchronyMs))")
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
                print(String(format: "%2d. %@   %3.0f BPM  %2d bars   mean %@  SD %@",
                             i + 1, dateLabel(s.date), s.bpm, s.bars,
                             Console.ms(s.meanAsynchronyMs, 1), Console.ms(s.sdAsynchronyMs, 1)))
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
        let session = args.first.flatMap(Int.init).map { sessions[max(0, min(sessions.count - 1, $0 - 1))] }
            ?? sessions.last!
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
        reportTiming(report, notesCaptured: session.tapTimes.count, events: events.count,
                     uncalibrated: session.calibrationConstantMs == nil)
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
    private static func comparabilityNotes(_ groups: [(label: String, sessions: [JamSession])]) -> [String] {
        guard groups.count >= 2 else { return [] }
        var notes: [String] = []

        /// Describe a per-group set of values, e.g. "relaxed: jamBacking, focused: basicRock".
        func describe<T: Hashable & Comparable>(_ key: (JamSession) -> T,
                                                _ format: (T) -> String) -> (differs: Bool, text: String) {
            let perGroup = groups.map { ($0.label, Set($0.sessions.map(key))) }
            let all = perGroup.reduce(into: Set<T>()) { $0.formUnion($1.1) }
            let text = perGroup
                .map { "\($0.0): \($0.1.sorted().map(format).joined(separator: "/"))" }
                .joined(separator: ", ")
            return (all.count > 1, text)
        }

        let backing = describe({ $0.grooveName }, { $0 })
        if backing.differs {
            notes.append("Backing differs (\(backing.text)). Spread and drift are not "
                       + "comparable across different music.")
        }

        let tempo = describe({ $0.bpm }, { "\(Int($0)) BPM" })
        if tempo.differs {
            // Asynchrony spread scales with the beat interval, so a tempo change moves the
            // numbers on its own.
            notes.append("Tempo differs (\(tempo.text)). Timing spread scales with tempo.")
        }

        let device = describe({ $0.device }, { $0 })
        if device.differs {
            notes.append("Output device differs (\(device.text)). Bias is not comparable; "
                       + "spread and r₁ are unaffected.")
        } else {
            let calibrated = describe({ $0.calibrationConstantMs != nil ? "yes" : "no" }, { $0 })
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
                verdict = d.excludesZero ? "\(Console.bold)real change\(Console.reset)" : "\(Console.dim)within noise\(Console.reset)"
            } else { changeStr = "—"; verdict = "—" }
            print("\(pad(name, 16))\(pad(String(format: "%+.2f\(unit)", va), 10))\(pad(String(format: "%+.2f\(unit)", vb), 10))\(pad(changeStr, 22))\(verdict)")
        }

        row("Mean async", Bootstrap.meanStat, unit: "")
        row("Spread (SD)", Bootstrap.sdStat, unit: "")
        row("r₁", Bootstrap.lag1Stat, unit: "")

        print("\n\(Console.dim)Mean/SD in ms. \"within noise\" = the 95% interval for the change includes zero.\(Console.reset)")
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
            print("\(pad(dateLabel(s.date), 22))\(pad("\(s.level)", 5))"
                + "\(pad("\(s.phraseBars) bars", 8))\(pad(onForm, 10))\(pad(tight, 9))\(slip)")
        }
        print("\n\(Console.dim)\"nailed\" = on the right bar AND close to the downbeat.\(Console.reset)")
    }

    /// Summary of every tagged condition, pooled across takes.
    private static func runTags(sessions: [JamSession]) {
        let tagged = sessions.filter { $0.tag != nil }
        guard !tagged.isEmpty else {
            print("No tagged takes yet. Tag one with:  TimingSpike jam 100 32 relaxed")
            return
        }
        let groups = Dictionary(grouping: tagged, by: { $0.tag! })

        Console.heading("Conditions")
        print("\(pad("Tag", 14))\(pad("takes", 7))\(pad("events", 8))\(pad("mean", 20))\(pad("SD", 20))r₁")
        for tag in groups.keys.sorted() {
            let series = groups[tag]!.map(asynchronies(of:))
            let events = series.reduce(0) { $0 + $1.count }
            let mean = Bootstrap.pooledInterval(series, statistic: Bootstrap.meanStat)
            let sd = Bootstrap.pooledInterval(series, statistic: Bootstrap.sdStat)
            let r1 = Bootstrap.pooledInterval(series, statistic: Bootstrap.lag1Stat)
            func fmt(_ c: ConfidenceInterval?, _ digits: Int = 1) -> String {
                guard let c else { return "—" }
                return String(format: "%+.\(digits)f [%+.\(digits)f,%+.\(digits)f]", c.point, c.low, c.high)
            }
            print("\(pad(tag, 14))\(pad("\(groups[tag]!.count)", 7))\(pad("\(events)", 8))"
                + "\(pad(fmt(mean), 20))\(pad(fmt(sd), 20))\(fmt(r1, 2))")
        }

        // Pooling takes recorded under different conditions hides the confound inside a
        // single row, where no comparison step would ever surface it.
        for tag in groups.keys.sorted() {
            let takes = groups[tag]!
            var mixed: [String] = []
            if Set(takes.map(\.grooveName)).count > 1 { mixed.append("backings") }
            if Set(takes.map(\.bpm)).count > 1 { mixed.append("tempos") }
            if Set(takes.map(\.device)).count > 1 { mixed.append("output devices") }
            if !mixed.isEmpty {
                print("\n\(Console.yellow)Mixed pool:\(Console.reset) '\(tag)' pools takes across "
                    + "different \(mixed.joined(separator: " and ")) — the pooled figures blend them.")
            }
        }
        print("\n\(Console.dim)Pooled across takes, 95% intervals. Compare two with:  review conditions <a> <b>\(Console.reset)")
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
            print("\(pad(name, 16))\(pad(String(format: "%+.2f", va), 10))\(pad(String(format: "%+.2f", vb), 10))\(pad(change, 22))\(verdict)")
        }
        row("Mean async", Bootstrap.meanStat)
        row("Spread (SD)", Bootstrap.sdStat)
        row("r₁", Bootstrap.lag1Stat)

        if min(a.count, b.count) < 3 {
            print("\n\(Console.yellow)Note:\(Console.reset) only \(min(a.count, b.count)) take(s) in the smaller group. "
                + "The intervals cover variation *within* takes but cannot see\nsession-to-session "
                + "variation — 3+ takes per condition before trusting a null result.")
        }
    }

    /// Does the player's sense of a good take track the measurement?
    ///
    /// If feel and spread correlate, their instinct is a reliable instrument and can be
    /// trusted mid-practice. If they don't, that gap is itself the finding.
    private static func runFeel(sessions: [JamSession]) {
        let rated = sessions.filter { $0.feelRating != nil }
        Console.heading("Feel vs measurement")
        guard rated.count >= 3 else {
            print("Only \(rated.count) rated take(s). Record a few more — you're asked to rate each take before the numbers appear.")
            return
        }

        print("\(pad("Take", 22))\(pad("tag", 12))\(pad("feel", 6))\(pad("SD", 9))mean")
        for s in rated {
            let a = asynchronies(of: s)
            print("\(pad(dateLabel(s.date), 22))\(pad(s.tag ?? "—", 12))"
                + "\(pad(String(repeating: "★", count: s.feelRating!), 6))"
                + "\(pad(Console.ms(Stats.sd(a), 1), 9))\(Console.ms(Stats.mean(a), 1))")
        }

        let feels = rated.map { Double($0.feelRating!) }
        let spreads = rated.map { Stats.sd(asynchronies(of: $0)) }
        if let r = Stats.correlation(feels, spreads) {
            print(String(format: "\nfeel vs spread: r = %+.2f", r))
            if rated.count < 6 {
                print("\(Console.dim)Too few takes to read much into this yet — it firms up around 6–8.\(Console.reset)")
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

    public static func runTempo(targets: [Double], leadBars: Int, holdBars: Int, rounds: Int) throws {
        Console.heading("Tempo calibration — produce the tempo yourself")
        let config = TrainerEngine.TempoConfig(targets: targets, leadBars: leadBars,
                                               holdBars: holdBars, rounds: rounds)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)")
        let targetText = targets.map { String(Int($0)) }.joined(separator: " / ")
        print("Targets: \(targetText) BPM   ·   \(rounds) rounds   ·   "
            + String(format: "~%.1f min", config.durationSeconds / 60))
        printInstructions(DrillInstructions.tempo)
        Console.prompt("Ready?")

        print("")
        // Printed as each round's silence ends, so the correction can be made on the spot.
        let outcome = try TrainerEngine.runTempo(config, roundFinished: { result in
            guard let produced = result.producedBpm, let pct = result.errorPercent else {
                print("  Round \(result.index + 1): \(Console.dim)\(result.unusableReason ?? "not scored")\(Console.reset)")
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
            let r = TempoCalibrationAnalysis.analyze(taps: s.taps, rounds: s.roundWindows)
            let targets = s.targets.map { String(Int($0)) }.joined(separator: "/")
            print("\(pad(dateLabel(s.date), 22))\(pad(targets, 14))"
                + "\(pad(r.meanErrorPercent.map { String(format: "%+.1f%%", $0) } ?? "—", 10))"
                + "\(pad(r.meanAbsErrorPercent.map { String(format: "%.1f%%", $0) } ?? "—", 11))"
                + (s.feelRating.map { String(repeating: "★", count: $0) } ?? "—"))
        }
        print("\n\(Console.dim)Bias is signed (negative = slow). Accuracy is average error "
            + "regardless of direction — that is the number to drive down.\(Console.reset)")
    }

    // MARK: - Dropout drill

    public static func runDropout(bpm: Double, pacedBars: Int, silentBars: Int, cycles: Int) throws {
        Console.heading("Dropout drill — hold the pulse alone")
        let config = TrainerEngine.DropoutConfig(bpm: bpm, pacedBars: pacedBars,
                                                 silentBars: silentBars, cycles: cycles)
        let env = try TrainerEngine.environment()
        print("Output: \(env.outputName)")

        print("\n\(Console.bold)\(cycles) cycles\(Console.reset): \(pacedBars) bars with the band, "
            + "\(silentBars) bars alone  ·  "
            + String(format: "~%.1f min", config.durationSeconds / 60))
        printInstructions(DrillInstructions.dropout)
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

    /// M7: is anything actually improving?
    ///
    /// Fits each metric against take number and reports the slope with a bootstrap interval,
    /// so "my spread is coming down" is either supported or isn't. Confounded groups are
    /// split rather than blended — a tempo change moves timing spread on its own, and a trend
    /// computed across the change would be measuring the tempo, not the player.
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
        }
    }

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
        print("\(pad("When", 22))\(pad("cycle", 10))\(pad("clock", 10))\(pad("motor", 10))\(pad("tempo alone", 14))feel")
        for s in sessions {
            // Recomputed from the raw taps so older takes get the current analysis.
            let (taps, grid, sections) = s.reconstruct()
            let r = DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections)
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
    public static func runForm(bpm: Double, bars: Int, phraseBars: Int, level rawLevel: Int) throws {
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
        printInstructions(DrillInstructions.form)
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
        let url = try TrainerEngine.save(outcome, feelRating: feel)
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
            let bars = keys.map { k -> String in
                let label = k == 0 ? "on" : (k > 0 ? "+\(k)" : "\(k)")
                return "\(label): \(report.formErrorHistogram[k]!)"
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
