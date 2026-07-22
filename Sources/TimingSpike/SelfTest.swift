import Foundation

/// Drives the full analysis pipeline with synthetic audio whose ground truth we control.
///
/// This is what makes a bad live result interpretable. If the self-test passes and the
/// live run fails, the fault is in the hardware or the clock bridge — not in the maths.
enum SelfTest {

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

    static func run() -> Bool {
        print("\n\u{001B}[1mSelf-test — analysis pipeline against known ground truth\u{001B}[0m")
        print(String(repeating: "─", count: 62))

        var ok = true
        ok = chirpLocalisation() && ok
        ok = statistics() && ok
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
