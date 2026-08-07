import Foundation
import GrooveCore
import TimingCore

/// Drives the full analysis pipeline with synthetic audio whose ground truth we control.
///
/// This is what makes a bad live result interpretable. If the self-test passes and the
/// live run fails, the fault is in the hardware or the clock bridge — not in the maths.
public enum SelfTest {

    /// A percussive transient: instantaneous attack, exponential decay, broadband.
    private static func burst(_ signal: inout [Float], at start: Int,
                              amplitude: Double, fs: Double, rng: inout RNG) {
        guard start >= 0 else { return }
        let decay = 0.004 * fs
        for k in 0..<Int(0.030 * fs) where start + k < signal.count {
            signal[start + k] += Float(exp(-Double(k) / decay) * rng.gaussian(sd: amplitude))
        }
    }

    /// Deterministic LCG so results are reproducible run to run.
    private struct RNG {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian(sd: Double) -> Double {
            let u1 = max(next(), 1e-12), u2 = next()
            return sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    private static func check(_ label: String, _ pass: Bool, _ detail: String) -> Bool {
        let mark = pass ? "\u{001B}[32mPASS\u{001B}[0m" : "\u{001B}[31mFAIL\u{001B}[0m"
        print("  \(mark)  \(label.padding(toLength: 42, withPad: " ", startingAt: 0)) \(detail)")
        return pass
    }

    public static func run() -> Bool {
        print("\n\u{001B}[1mSelf-test — analysis pipeline against known ground truth\u{001B}[0m")
        print(String(repeating: "─", count: 62))

        var ok = true
        ok = chirpLocalisation() && ok
        ok = statistics() && ok
        ok = calibrationDerivation() && ok
        ok = grooveRendering() && ok
        ok = liveInstrument() && ok
        ok = jamReduction() && ok
        ok = fullPipeline() && ok

        print("\n" + (ok
            ? "\u{001B}[32mAnalysis pipeline verified.\u{001B}[0m A failed live run means hardware, not maths."
            : "\u{001B}[31mAnalysis pipeline is broken.\u{001B}[0m Fix before running against hardware."))
        return ok
    }

    // MARK: - Chirp localisation

    private static func chirpLocalisation() -> Bool {
        print("\nChirp localisation (sub-sample accuracy under noise)")
        let fs = 44100.0
        let chirpDuration = 0.020
        let chirp = Chirp.make(sampleRate: fs, duration: chirpDuration)

        var rng = RNG()
        var signal = [Float](repeating: 0, count: Int(5 * fs))
        for i in 0..<signal.count { signal[i] = Float(rng.gaussian(sd: 0.002)) }

        let truePositions = [10_000, 50_000, 95_000, 140_000, 180_000]
        for p in truePositions {
            for k in 0..<chirp.count { signal[p + k] += chirp[k] * 0.3 }
        }

        let found = Analysis.findChirps(in: signal, expected: truePositions.count,
                                        inputSampleRate: fs, chirpDuration: chirpDuration,
                                        minSeparationSamples: 10_000)

        guard found.count == truePositions.count else {
            return check("all chirps located", false, "found \(found.count) of \(truePositions.count)")
        }
        let errors = zip(found, truePositions).map { abs($0.index - Double($1)) }
        let worst = errors.max() ?? .infinity
        return check("localisation error < 0.5 samples", worst < 0.5,
                     String(format: "worst %.3f samples (%.1f µs)", worst, worst / fs * 1e6))
    }

    // MARK: - Statistics

    private static func statistics() -> Bool {
        print("\nStatistics")
        let x = (0..<200).map(Double.init)
        let y = x.map { 3.5 * $0 + 12.0 }
        guard let fit = Stats.linearFit(x: x, y: y) else {
            return check("linear fit", false, "no fit produced")
        }
        var ok = check("recovers known slope", abs(fit.slope - 3.5) < 1e-9,
                       String(format: "%.6f vs 3.5", fit.slope))
        ok = check("recovers known intercept", abs(fit.intercept - 12.0) < 1e-9,
                   String(format: "%.6f vs 12.0", fit.intercept)) && ok

        let sample = [1.0, 2.0, 3.0, 4.0, 100.0]
        ok = check("median resists outliers", Stats.median(sample) == 3.0,
                   "\(Stats.median(sample))") && ok
        return ok
    }

    // MARK: - Calibration derivation

    /// Checks that a device calibrated by loopback alone recovers the same constant a full
    /// two-path run would have produced.
    ///
    /// Built from known latencies so the expected answer is arithmetic, not opinion. A sign
    /// error here would be invisible in normal use and would bias every asynchrony the app
    /// ever reports.
    private static func calibrationDerivation() -> Bool {
        print("\nCalibration derivation")

        // Ground truth, all in ms.
        let midiLatency = 6.0
        let inputLatency = 11.5          // cancels — same input path for both devices
        let speakerOut = 4.0,  speakerAir = Calibration.airPathMs(centimetres: 15)
        let phonesOut  = 1.5,  phonesAir  = Calibration.airPathMs(centimetres: 1)

        var store = Calibration()
        store.devices["Speakers"] = .init(
            displayName: "Speakers",
            roundTripMs: speakerOut + speakerAir + inputLatency,
            roundTripSD: 0.01, airPathMs: speakerAir, sampleRate: 44100,
            bufferFrames: 256, measuredAt: Date(),
            residualMs: midiLatency + speakerOut,     // what the two-path run measures
            residualSD: 0.6)
        store.devices["Headphones"] = .init(
            displayName: "Headphones",
            roundTripMs: phonesOut + phonesAir + inputLatency,
            roundTripSD: 0.01, airPathMs: phonesAir, sampleRate: 44100,
            bufferFrames: 256, measuredAt: Date(),
            residualMs: nil, residualSD: nil)
        store.referenceDevice = "Speakers"

        var ok = true
        if let derived = store.constant(for: "Headphones") {
            let expected = midiLatency + phonesOut
            ok = check("derives an uncalibrated device", abs(derived.value - expected) < 1e-9,
                       String(format: "%.4f ms vs %.4f expected", derived.value, expected)) && ok
            if case .derived(let from) = derived.source {
                ok = check("marks it as derived", from == "Speakers", "from \(from)") && ok
            } else {
                ok = check("marks it as derived", false, "reported as measured") && ok
            }
        } else {
            ok = check("derives an uncalibrated device", false, "returned nil") && ok
        }

        if let reference = store.constant(for: "Speakers") {
            ok = check("reference returns its own measurement",
                       abs(reference.value - (midiLatency + speakerOut)) < 1e-9,
                       String(format: "%.4f ms", reference.value)) && ok
            if case .measured = reference.source {} else {
                ok = check("reference marked as measured", false, "reported as derived") && ok
            }
        }

        var orphan = Calibration()
        orphan.devices["Headphones"] = store.devices["Headphones"]
        ok = check("no constant without a reference", orphan.constant(for: "Headphones") == nil,
                   orphan.constant(for: "Headphones") == nil ? "nil" : "returned a value") && ok

        // Regression: a quick (residual=nil) calibration on the SAME identity as the
        // reference must not wipe the reference's measured residual. This is the exact
        // data-loss bug the first live M1 run hit.
        var clobber = store
        clobber.record(identity: "Speakers", .init(
            displayName: "Speakers", roundTripMs: 99, roundTripSD: 0.01,
            airPathMs: speakerAir, sampleRate: 44100, bufferFrames: 256,
            measuredAt: Date(), residualMs: nil, residualSD: nil))
        if let after = clobber.constant(for: "Speakers"), case .measured = after.source {
            ok = check("quick run preserves reference residual",
                       abs(after.value - (midiLatency + speakerOut)) < 1e-9,
                       String(format: "%.4f ms survived", after.value)) && ok
        } else {
            ok = check("quick run preserves reference residual", false, "residual was destroyed") && ok
        }

        // Persistence must survive a round trip or a stored calibration is worthless.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? encoder.encode(store),
           let restored = try? decoder.decode(Calibration.self, from: data),
           let a = restored.constant(for: "Headphones")?.value,
           let b = store.constant(for: "Headphones")?.value {
            ok = check("survives encode/decode", abs(a - b) < 1e-9, String(format: "%.4f ms", a)) && ok
        } else {
            ok = check("survives encode/decode", false, "round trip failed") && ok
        }
        return ok
    }

    // MARK: - Groove rendering

    private static func rms(_ x: [Float], _ lo: Int, _ hi: Int) -> Double {
        let a = max(0, lo), b = min(x.count, hi)
        guard b > a else { return 0 }
        var sum = 0.0
        for i in a..<b { sum += Double(x[i]) * Double(x[i]) }
        return (sum / Double(b - a)).squareRoot()
    }

    /// Exercises the whole groove path — voice synthesis, sequencing, the dropout ladder,
    /// and mixing — with no audio hardware. Confirms the voices actually make sound, the
    /// groove has energy, a `silence` ladder level is genuinely silent, and the mix does
    /// not blow past the rails.
    private static func grooveRendering() -> Bool {
        print("\nGroove rendering (synth + sequencer + dropout + mix)")
        let fs = 44100.0
        let kit = BackingKit(sampleRate: fs)
        var ok = true

        for voice in BackingVoice.allCases where !voice.isPitched {
            let b = kit.buffer(for: voice)
            let finite = b.allSatisfy { $0.isFinite }
            let peak = b.map { abs($0) }.max() ?? 0
            ok = check("voice \(voice.rawValue) renders",
                       !b.isEmpty && finite && peak > 0.01 && peak <= 1.2,
                       String(format: "%d samples, peak %.2f", b.count, peak)) && ok
        }

        // The bass has one buffer per note rather than one per voice, so it is checked across
        // its range: every note must sound, none may be silent or hotter than the drums, and
        // the pitch must actually rise — a bass rendering one frequency for every note would
        // pass a peak check and be musically useless.
        var bassOK = true
        var lastCentroid = 0.0
        for note in BackingKit.bassNotes {
            let b = kit.buffer(for: .bass, note: note)
            let peak = b.map { abs($0) }.max() ?? 0
            if b.isEmpty || !b.allSatisfy({ $0.isFinite }) || peak < 0.01 || peak > 1.2 {
                bassOK = false
            }
            // Zero crossings stand in for pitch: cheap, and monotone in frequency.
            let crossings = zip(b, b.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            let centroid = Double(crossings) / max(Double(b.count), 1)
            if centroid <= lastCentroid { bassOK = false }
            lastCentroid = centroid
        }
        ok = check("bass renders every note in its range, rising in pitch", bassOK,
                   "\(BackingKit.bassNotes.count) notes, "
                 + "\(BassSynth.frequency(ofNote: BackingKit.bassNotes.lowerBound).rounded())"
                 + "–\(BassSynth.frequency(ofNote: BackingKit.bassNotes.upperBound).rounded()) Hz") && ok

        // Four bars of full kit, then four bars of ladder-silence.
        let seq = Sequencer(bpm: 120, sampleRate: fs)
        let groove = GrooveLibrary.basicRock
        var hits: [ScheduledHit] = []
        for bar in 0..<4 { hits += seq.schedule(pattern: groove, bar: bar) }
        for bar in 4..<8 {
            hits += seq.schedule(pattern: DropoutLadder.pattern(level: .silence, bar: bar, groove: groove),
                                 bar: bar)
        }

        let barSamples = Int(seq.barStartSample(bar: 1, pattern: groove))   // 88200 at 120 BPM
        let audio = GrooveOfflineRender.mix(hits: hits, kit: kit, frames: barSamples * 8 + Int(fs))

        let grooveRMS = rms(audio, 0, barSamples * 4)
        // Start after the longest voice tail (kick ~0.32 s) so we measure true silence.
        let silenceRMS = rms(audio, barSamples * 4 + Int(0.4 * fs), barSamples * 8)
        let peak = audio.map { abs($0) }.max() ?? 0

        ok = check("groove section has audio", grooveRMS > 0.01,
                   String(format: "RMS %.4f", grooveRMS)) && ok
        ok = check("silence section is silent", silenceRMS < grooveRMS * 0.02,
                   String(format: "RMS %.6f vs %.4f", silenceRMS, grooveRMS)) && ok
        ok = check("mix does not clip (≤ 0 dBFS)", peak <= 1.0,
                   String(format: "peak %.2f", peak)) && ok
        return ok
    }

    // MARK: - Live instrument

    /// Drives the synth the way the audio thread would — enqueue events, render blocks —
    /// and checks it makes sound on note-on, holds while sustained, and returns to silence
    /// after note-off. No hardware, no audio device.
    private static func liveInstrument() -> Bool {
        print("\nLive instrument (MIDI → synth)")
        let fs = 44100.0
        let inst = LiveInstrument(sampleRate: fs)
        let block = 256
        var ok = true

        func renderRMS(blocks: Int) -> Double {
            var sum = 0.0, count = 0
            for _ in 0..<blocks {
                let p = inst.render(frames: block)
                for i in 0..<block { sum += Double(p[i]) * Double(p[i]); count += 1 }
            }
            return (sum / Double(count)).squareRoot()
        }

        let beforeNote = renderRMS(blocks: 4)
        ok = check("silent before any note", beforeNote < 1e-6,
                   String(format: "RMS %.2e", beforeNote)) && ok

        inst.enqueue(note: 69, velocity: 100, on: true)     // A4
        let sustained = renderRMS(blocks: 40)               // ~0.23 s of held tone
        ok = check("makes sound while held", sustained > 0.02,
                   String(format: "RMS %.3f", sustained)) && ok

        inst.enqueue(note: 69, velocity: 100, on: false)
        _ = renderRMS(blocks: 60)                            // let the release finish
        let afterRelease = renderRMS(blocks: 8)
        ok = check("returns to silence after note-off", afterRelease < 1e-4,
                   String(format: "RMS %.2e", afterRelease)) && ok

        // A chord is louder than a single note but the mix stays bounded (voices sum but
        // the master soft-clip lives in GroovePlayer; here we just confirm no runaway).
        for n: UInt8 in [60, 64, 67, 71] { inst.enqueue(note: n, velocity: 100, on: true) }
        var peak = 0.0
        for _ in 0..<20 {
            let p = inst.render(frames: block)
            for i in 0..<block { peak = max(peak, abs(Double(p[i]))) }
        }
        ok = check("chord renders and stays finite", peak > 0.05 && peak.isFinite,
                   String(format: "peak %.2f", peak)) && ok
        return ok
    }

    // MARK: - Jam reduction

    /// Verifies the jam reduction end to end on synthetic data: an output-sample↔host-time
    /// map plus MIDI note-ons carrying a known true asynchrony and a known calibration
    /// constant. The reduction must strip the constant with the correct sign and recover the
    /// true asynchrony — a sign slip here would bias every "am I rushing?" answer the app gives.
    private static func jamReduction() -> Bool {
        print("\nJam reduction (two clocks → calibrated asynchrony)")
        let fs = 44100.0
        let bpm = 120.0
        let beatSamples = Int64(fs * 60 / bpm)          // 22050
        let grooveStart = Int64(fs)                     // 1 s in
        let beats = 40
        let trueAsyncMs = -9.0                          // the player rushes 9 ms
        let constantMs = 11.0                           // L_midi + L_out to strip

        // Output map with an exact sample = fs·seconds relationship (intercept 0).
        let epoch = HostClock.now()
        var outputMap: [(hostTime: UInt64, sample: Int64)] = []
        for i in 0..<400 {
            let sample = Int64(Double(i) * 0.01 * fs)
            outputMap.append((epoch &+ HostClock.ticks(seconds: Double(sample) / fs), sample))
        }

        // A note near each beat: emit time + constant + true asynchrony (+ light jitter).
        var rng = RNG()
        var midi: [(hostTime: UInt64, velocity: Int, note: Int)] = []
        for k in 0..<beats {
            let beatSample = grooveStart + Int64(k) * beatSamples
            let emitSec = Double(beatSample) / fs
            let jitter = rng.gaussian(sd: 0.003)
            let noteSec = emitSec + constantMs / 1000 + trueAsyncMs / 1000 + jitter
            midi.append((epoch &+ HostClock.ticks(seconds: noteSec), 90, 60))
        }

        let grooveEnd = grooveStart + Int64(beats) * beatSamples

        guard let corrected = JamAnalysis.reduce(
            outputMap: outputMap, midi: midi,
            grooveStartSample: grooveStart, grooveEndSample: grooveEnd,
            bpm: bpm, subdivisions: 1, calibrationConstantMs: constantMs) else {
            return check("reduction produced a result", false, "nil")
        }
        let report = TimingAnalysis.analyze(taps: corrected.taps, grid: corrected.grid)

        var ok = check("all beats captured", report.matchedCount == beats,
                       "\(report.matchedCount) of \(beats)")
        ok = check("recovers true asynchrony (constant stripped)",
                   abs(report.meanAsynchronyMs - trueAsyncMs) < 1.0,
                   String(format: "%.2f ms vs %.1f expected", report.meanAsynchronyMs, trueAsyncMs)) && ok

        // With the constant NOT removed, the mean must shift by exactly the constant —
        // proving the correction is real and correctly signed, not incidental.
        if let raw = JamAnalysis.reduce(
            outputMap: outputMap, midi: midi,
            grooveStartSample: grooveStart, grooveEndSample: grooveEnd,
            bpm: bpm, subdivisions: 1, calibrationConstantMs: 0) {
            let rawMean = TimingAnalysis.analyze(taps: raw.taps, grid: raw.grid).meanAsynchronyMs
            ok = check("constant shifts bias by exactly its value",
                       abs((rawMean - report.meanAsynchronyMs) - constantMs) < 0.01,
                       String(format: "%.2f ms shift vs %.1f", rawMean - report.meanAsynchronyMs, constantMs)) && ok
        }

        // Count-in / stray notes outside the window must be dropped.
        var withStray = midi
        withStray.insert((epoch &+ HostClock.ticks(seconds: 0.1), 90, 60), at: 0)   // during count-in
        if let r = JamAnalysis.reduce(outputMap: outputMap, midi: withStray,
                                      grooveStartSample: grooveStart, grooveEndSample: grooveEnd,
                                      bpm: bpm, subdivisions: 1, calibrationConstantMs: constantMs) {
            ok = check("out-of-window notes are excluded", r.tapsInWindow == beats,
                       "\(r.tapsInWindow) in window") && ok
        }
        return ok
    }

    // MARK: - Full pipeline

    /// Synthesises a complete Phase 2 session and checks that the known constant residual
    /// is recovered.
    ///
    /// The simulated key strikes carry 20 ms of timing jitter — far worse than any human
    /// would play. If the residual still comes back tight, that proves the measurement is
    /// independent of how accurately the player performs, which is the central claim of
    /// the two-path design.
    private static func fullPipeline() -> Bool {
        print("\nFull pipeline (100 beats, synthetic)")

        let fs = 44100.0
        let chirpDuration = 0.020
        let beatSeconds = 1.0
        let beats = 100
        let leadIn = 2.0
        let roundTrip = 0.012            // simulated speaker → mic latency
        let trueResidualMs = 4.2         // the constant the pipeline must recover
        let playJitterSD = 0.020         // deliberately awful human timing

        var rng = RNG()
        let totalSamples = Int((leadIn + Double(beats) * beatSeconds + 2) * fs)
        var capture = [Float](repeating: 0, count: totalSamples)
        for i in 0..<capture.count { capture[i] = Float(rng.gaussian(sd: 0.0008)) }

        let chirp = Chirp.make(sampleRate: fs, duration: chirpDuration)
        var emitHost: [Double] = []
        var phases: [Double] = []
        var noteHost: [Double] = []

        for i in 0..<beats {
            let emit = leadIn + Double(i) * beatSeconds
            emitHost.append(emit)
            // Spread buffer phase across the run so check #2 has something to regress on.
            phases.append(Double((i * 68) % 256))

            let arrival = (emit + roundTrip) * fs
            let a = Int(arrival.rounded())
            for k in 0..<chirp.count where a + k < capture.count {
                capture[a + k] += chirp[k] * 0.3
            }

            // Strike lands roughly on the offbeat, well clear of the chirps.
            let offset = 0.5 + rng.gaussian(sd: playJitterSD)
            let strike = Int((arrival + offset * fs).rounded())
            burst(&capture, at: strike, amplitude: 0.5, fs: fs, rng: &rng)

            // Reproduce the live failure mode: a real room throws off several quieter
            // transients per beat (key release, hand noise, desk knocks). The live run saw
            // 455 onsets for ~100 strikes, so plant roughly that ratio here.
            for _ in 0..<4 {
                let at = Int(arrival + rng.next() * beatSeconds * fs)
                burst(&capture, at: at, amplitude: 0.15, fs: fs, rng: &rng)
            }

            // Δ_audio for this beat is `offset`; construct the MIDI time so that
            // residual = Δ_midi − Δ_audio is exactly trueResidualMs.
            noteHost.append(emit + offset + trueResidualMs / 1000)
        }

        let result = Analysis.validateBridge(
            capture: capture, emitHostSeconds: emitHost, phases: phases,
            noteHostSeconds: noteHost, inputSampleRate: fs,
            chirpDuration: chirpDuration, beatSeconds: beatSeconds)

        var ok = check("chirps located", result.chirpsFound == beats,
                       "\(result.chirpsFound) of \(beats)")
        ok = check("beats paired", result.pairedBeats >= 90,
                   "\(result.pairedBeats) of \(beats), "
                   + "\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched") && ok
        ok = check("residual SD < 1 ms (check #1)", result.sd < 1.0,
                   String(format: "%.3f ms", result.sd)) && ok

        if result.sd >= 1.0 {
            let m = Stats.median(result.residualsMs)
            let outliers = result.residualsMs.enumerated().filter { abs($0.element - m) > 20 }
            print(String(format: "        %d outliers >20 ms from median; p5 %.1f  p50 %.1f  p95 %.1f",
                         outliers.count,
                         Stats.percentile(result.residualsMs, 0.05), m,
                         Stats.percentile(result.residualsMs, 0.95)))
            print("        worst: " + outliers.prefix(8)
                .map { String(format: "beat %d: %.1f ms", $0.offset, $0.element) }
                .joined(separator: ", "))
        }

        let bias = result.median - trueResidualMs
        ok = check("recovers known residual ±1 ms", abs(bias) < 1.0,
                   String(format: "%.3f ms (detector bias %+.3f ms)", result.median, bias)) && ok

        if let fit = result.phaseFit {
            let acrossBuffer = fit.slope * 256
            ok = check("no phase dependence (check #2)", abs(acrossBuffer) < 0.5,
                       String(format: "%.4f ms/buffer, r = %.3f", acrossBuffer, fit.r)) && ok
        }
        if let fit = result.timeFit {
            let perMinute = fit.slope * 60
            ok = check("no drift over time (check #3)", abs(perMinute) < 1.0,
                       String(format: "%.4f ms/min, r = %.3f", perMinute, fit.r)) && ok
        }
        return ok
    }
}
