import Foundation
import GrooveCore
import TimingCore

enum Commands {

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
        let midi = MIDIInput()
        try midi.start()
        print("\nMIDI listening on: \(midi.sourceNames.joined(separator: ", "))")
        if !midi.skippedSources.isEmpty {
            print("Ignoring control-surface ports: \(midi.skippedSources.joined(separator: ", "))")
        }
        return midi
    }

    // MARK: - M0 validation rig

    static func runValidation() throws {
        Console.heading("Environment")
        let env = try checkEnvironment()
        let midi = try startMIDI()
        defer { midi.stop() }

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

    // MARK: - M4 jam

    static func runJam(bpm: Double, bars: Int, tag: String?) throws {
        Console.heading("Jam — record a take")
        guard bpm >= 40 && bpm <= 260 else { throw SpikeError("Tempo \(Int(bpm)) BPM is out of range (40–260).") }
        guard bars >= 4 && bars <= 512 else { throw SpikeError("Bars \(bars) out of range (4–512).") }
        let tag = tag?.lowercased()

        let env = try checkEnvironment()

        // Look up the calibration constant for the active output path. Without it the
        // *bias* is uncorrected (mean asynchrony is off by the constant), but variance,
        // drift, and autocorrelation stay meaningful — so we warn and continue rather than
        // refuse.
        let store = Calibration.load()
        let calibration = store.constant(for: env.output.identity)
        if let c = calibration {
            let src: String
            switch c.source {
            case .measured: src = "measured"
            case .derived(let from): src = "derived from \(store.devices[from]?.displayName ?? from)"
            }
            print("Calibration: \(Console.ms(c.value)) (\(src))")
        } else {
            Console.warn("""
                no calibration for this output device — timing BIAS will be uncorrected.
                Spread and drift are still valid. Calibrate with:  TimingSpike calibrate
                """)
        }
        let constantMs = calibration?.value ?? 0

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: bpm, sampleRate: player.outputSampleRate)
        // Sectional backing: 8-bar sections with fills. Variety so a long take doesn't go
        // hypnotic, and a landmark every 8 bars to anchor where you are in the form.
        let backing = GrooveLibrary.jamBacking
        let subdivisions = backing.stepsPerBeat
        let countInBars = 2

        var perBar: [Pattern] = []
        for _ in 0..<countInBars {
            perBar.append(DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0, groove: GrooveLibrary.basicRock))
        }
        for bar in 0..<bars { perBar.append(backing.pattern(atBar: bar)) }

        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() { hits += seq.schedule(pattern: pattern, bar: bar) }
        player.schedule(hits)

        let grooveStartSample = seq.barStartSample(bar: countInBars, pattern: GrooveLibrary.basicRock)
        let grooveEndSample = seq.barStartSample(bar: countInBars + bars, pattern: GrooveLibrary.basicRock)

        let midi = try startMIDI()
        defer { midi.stop() }
        midi.reset()
        // Sonify the keyboard so the player can hear what they play. Runs on the CoreMIDI
        // thread; enqueue is lock-free.
        midi.onNoteEvent = { note, velocity, on in
            player.noteEvent(note: note, velocity: velocity, on: on)
        }

        let minutes = Double(bars) * 4 * 60 / bpm / 60
        print("\n\(countInBars)-bar count-in, then \(bars) bars at \(Int(bpm)) BPM"
            + String(format: " (~%.1f min)", minutes) + ".")
        if let tag { print("Condition: \(Console.bold)\(tag)\(Console.reset)") }
        print("Play along — eyes closed. You'll hear your keys over the groove.\n")

        try player.run(forSeconds: player.scheduledDurationSeconds() + 0.5)

        // Rate the take BEFORE any numbers appear, so the rating is an honest read of the
        // experience rather than a rationalisation of the measurement.
        let feel = Console.readRating("\nHow did that feel?")

        guard let reduced = JamAnalysis.reduce(
            outputMap: player.outputMapPairs,
            midi: midi.events.map { ($0.hostTime, Int($0.velocity)) },
            grooveStartSample: grooveStartSample,
            grooveEndSample: grooveEndSample,
            bpm: bpm, subdivisions: subdivisions, calibrationConstantMs: constantMs)
        else {
            throw SpikeError("Could not reconstruct the take (no audio timing map captured).")
        }

        // Collapse chords to single rhythmic events before analysis, so a four-note chord
        // counts as one beat placement rather than one match and three "off-grid" notes.
        let events = TapClustering.collapse(reduced.taps, windowSeconds: 0.035)
        let report = TimingAnalysis.analyze(taps: events, grid: reduced.grid, chordWindowMs: 0)
        reportTiming(report, notesCaptured: midi.events.count, events: events.count,
                     uncalibrated: calibration == nil)

        let session = JamSession(
            date: Date(), bpm: bpm, device: env.output.identity,
            calibrationConstantMs: calibration?.value,
            calibrationSource: calibration.map { if case .measured = $0.source { return "measured" } else { return "derived" } },
            grooveName: "jamBacking", bars: bars, subdivisions: subdivisions,
            tag: tag, feelRating: feel,
            gridStartTime: reduced.grid.startTime,
            tapTimes: reduced.taps.map(\.time),
            tapVelocities: reduced.taps.map(\.velocity),
            matchedCount: report.matchedCount, extraCount: report.extraCount,
            missedCount: report.missedCount,
            meanAsynchronyMs: report.meanAsynchronyMs, sdAsynchronyMs: report.sdAsynchronyMs,
            lag1Autocorrelation: report.lag1Autocorrelation, driftMsPerBeat: report.driftMsPerBeat,
            headline: report.headline)
        let url = try SessionStore.save(session)
        print("\n\(Console.dim)Saved \(url.lastPathComponent) — \(SessionStore.loadAll().count) session(s) on file.\(Console.reset)")
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
    static func runReview(_ args: [String]) throws {
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

    /// The matched asynchrony series for a stored take, re-analyzed with the current logic.
    private static func asynchronies(of session: JamSession) -> [Double] {
        let (taps, grid) = session.reconstruct()
        let events = TapClustering.collapse(taps, windowSeconds: 0.035)
        return TimingAnalysis.analyze(taps: events, grid: grid, chordWindowMs: 0).asynchroniesMs
    }

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

    // MARK: - M3 groove

    static func runGroove(bpm: Double) throws {
        Console.heading("Groove — M3 demo")
        guard bpm >= 40 && bpm <= 260 else {
            throw SpikeError("Tempo \(Int(bpm)) BPM is out of range (40–260).")
        }
        if let output = AudioDevices.defaultDevice(input: false) {
            let src = output.dataSource.map { " — \($0)" } ?? ""
            print("Output: \(output.name)\(src)  @ \(Int(output.sampleRate)) Hz")
        }
        print("Tempo:  \(Int(bpm)) BPM")

        let player = try GroovePlayer()
        let seq = Sequencer(bpm: bpm, sampleRate: player.outputSampleRate)
        let groove = GrooveLibrary.basicRock

        // Assemble the whole session as a flat list of per-bar patterns, then flatten to
        // sample-accurate hits. One continuous schedule means no gaps or clicks between
        // sections.
        var perBar: [Pattern] = []
        perBar.append(DropoutLadder.pattern(level: .hatsEveryBeat, bar: 0, groove: groove)) // count-in
        for bar in 0..<16 { perBar.append(GrooveLibrary.demo.pattern(atBar: bar)) }         // A/fill/B/fill

        let ladder: [DropoutLevel] = [.fullKit, .hatsEveryBeat, .backbeat,
                                      .beatFourOnly, .downbeatSparse, .silence]
        for level in ladder {
            for b in 0..<4 { perBar.append(DropoutLadder.pattern(level: level, bar: b, groove: groove)) }
        }
        for b in 0..<4 { perBar.append(DropoutLadder.pattern(level: .fullKit, bar: b, groove: groove)) } // slam

        var hits: [ScheduledHit] = []
        for (bar, pattern) in perBar.enumerated() {
            hits.append(contentsOf: seq.schedule(pattern: pattern, bar: bar))
        }
        player.schedule(hits)

        // Optional: if a keyboard is connected, sonify it so you can play along. Not
        // required — the groove plays regardless.
        let midi = try? startMIDI()
        defer { midi?.stop() }
        midi?.onNoteEvent = { note, velocity, on in
            player.noteEvent(note: note, velocity: velocity, on: on)
        }

        print("\nRoadmap (\(perBar.count) bars):")
        print("  • 1-bar count-in")
        print("  • 16 bars: \(GrooveLibrary.demo.sections.map(\.name).joined(separator: " → ")) (with fills)")
        print("  • dropout ladder: \(ladder.map(\.label).joined(separator: " → "))")
        print("  • 4-bar slam back to full kit")
        let duration = player.scheduledDurationSeconds()
        print(String(format: "\nPlaying ~%.0f s — play along, eyes closed.\n", duration))

        try player.run(forSeconds: duration + 0.5)
        print("Done.")
    }

    static func runReset() throws {
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

    static func runCalibrate(quick: Bool) throws {
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
            defer { midi.stop() }
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

    static func runShow() throws {
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
