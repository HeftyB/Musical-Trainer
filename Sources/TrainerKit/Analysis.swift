import Foundation
import TimingCore

struct LatencyResult {
    let roundTripMs: [Double]
    let median: Double
    let iqr: Double
    let sd: Double
    /// Round-trip vs. elapsed time. A non-zero slope means input and output devices are
    /// not clock-locked and are sliding apart — check #3.
    let driftFit: Regression?
    let chirpsFound: Int
    let chirpsExpected: Int
}

struct ValidationResult {
    let residualsMs: [Double]
    let median: Double
    let sd: Double
    let iqr: Double
    /// Residual vs. buffer phase — check #2, the one that catches bad bridge arithmetic.
    let phaseFit: Regression?
    /// Residual vs. elapsed time — check #3.
    let timeFit: Regression?
    let pairedBeats: Int
    let midiNotes: Int
    let thocksDetected: Int
    let chirpsFound: Int
    /// MIDI notes with no audio onset within the search radius. A handful is normal
    /// (a strike the mic missed); a large fraction means the bridge is badly wrong.
    let unmatchedNotes: Int
    /// Beats rejected by the 5 ms quality gate — onset misidentifications, not bridge
    /// error. A few is expected in a live room; a large fraction means a noisy recording.
    let trimmedBeats: Int
}

/// Pure analysis. Takes plain arrays rather than an `AudioIO`, so the whole pipeline can
/// be driven with synthetic data of known ground truth — the only way to tell a broken
/// clock bridge apart from broken arithmetic when a live run comes back ugly.
enum Analysis {
    /// Locate every emitted chirp in the captured audio, returning start positions in
    /// input samples with sub-sample refinement.
    static func findChirps(in capture: [Float],
                           expected: Int,
                           inputSampleRate: Double,
                           chirpDuration: Double,
                           minSeparationSamples: Int) -> [(index: Double, value: Float)] {
        // Generate the detection kernel at the *input* rate. If input and output devices
        // run at different rates the recorded sweep is resampled, and a kernel built at
        // the output rate would correlate poorly.
        let kernel = Chirp.make(sampleRate: inputSampleRate, duration: chirpDuration)
        let correlation = DSP.correlate(signal: capture, kernel: kernel)
        guard !correlation.isEmpty else { return [] }
        return DSP.topPeaks(correlation, count: expected, minSeparation: minSeparationSamples)
    }

    static func measureLatency(capture: [Float],
                               emitHostSeconds: [Double],
                               inputMap: SampleHostMap,
                               inputSampleRate: Double,
                               chirpDuration: Double,
                               beatSeconds: Double) -> LatencyResult {
        let arrivals = findChirps(in: capture,
                                  expected: emitHostSeconds.count,
                                  inputSampleRate: inputSampleRate,
                                  chirpDuration: chirpDuration,
                                  minSeparationSamples: Int(beatSeconds * inputSampleRate) / 2)

        var roundTrips: [Double] = []
        var elapsed: [Double] = []
        for i in 0..<min(arrivals.count, emitHostSeconds.count) {
            guard let arrivalHost = inputMap.hostSeconds(atSample: arrivals[i].index) else { continue }
            roundTrips.append((arrivalHost - emitHostSeconds[i]) * 1000)
            elapsed.append(emitHostSeconds[i])
        }

        return LatencyResult(
            roundTripMs: roundTrips,
            median: Stats.median(roundTrips),
            iqr: Stats.iqr(roundTrips),
            sd: Stats.sd(roundTrips),
            driftFit: Stats.linearFit(x: elapsed, y: roundTrips),
            chirpsFound: arrivals.count,
            chirpsExpected: emitHostSeconds.count)
    }

    static func validateBridge(capture: [Float],
                               emitHostSeconds: [Double],
                               phases: [Double],
                               noteHostSeconds: [Double],
                               inputSampleRate fs: Double,
                               chirpDuration: Double,
                               beatSeconds: Double) -> ValidationResult {
        let arrivals = findChirps(in: capture,
                                  expected: emitHostSeconds.count,
                                  inputSampleRate: fs,
                                  chirpDuration: chirpDuration,
                                  minSeparationSamples: Int(beatSeconds * fs) / 2)

        // Mask out the chirps themselves plus a tail for speaker ringing and the first
        // room reflection, so they are never mistaken for key strikes.
        let chirpLen = Int(chirpDuration * fs)
        let preGuard = Int(0.002 * fs)
        let postGuard = Int(0.030 * fs)
        var masked = [Bool](repeating: false, count: capture.count)
        for a in arrivals {
            let lo = max(0, Int(a.index) - preGuard)
            let hi = min(capture.count - 1, Int(a.index) + chirpLen + postGuard)
            if lo <= hi { for i in lo...hi { masked[i] = true } }
        }

        let envelope = DSP.transientEnvelope(capture, smoothing: Float(1.0 / (0.001 * fs)))
        let floor = DSP.noiseFloor(envelope)
        let onsets = DSP.detectOnsets(envelope: envelope,
                                      noiseFloor: floor,
                                      thresholdRatio: 6,
                                      // Keep these tight. A large minSeparation makes the
                                      // scan skip forward past a spurious transient and
                                      // swallow the real strike behind it, leaving only
                                      // the spurious one to choose from. Over-detecting is
                                      // harmless here — the loudest-in-window rule sorts
                                      // duplicates out — but missing the strike is fatal.
                                      minSeparation: Int(0.015 * fs),
                                      searchWindow: Int(0.010 * fs),
                                      backtrackRatio: 0.15,
                                      maxBacktrack: Int(0.008 * fs),
                                      excluded: { masked[$0] })

        // Match each event to the chirp that PRECEDED it, not the nearest one.
        //
        // Nearest-neighbour matching breaks for offbeat playing: a strike halfway between
        // two chirps is equidistant from both, so timing jitter coin-flips the assignment.
        // Half the strikes then attach to the following chirp, colliding with its own
        // strike and discarding both beats. Preceding-chirp matching is unambiguous
        // wherever in the beat the strike lands.
        var notesPerChirp = [Int: [Double]]()
        for t in noteHostSeconds {
            guard let i = precedingIndex(to: t, in: emitHostSeconds, within: beatSeconds) else { continue }
            notesPerChirp[i, default: []].append(t - emitHostSeconds[i])
        }

        // Use the MIDI event to predict where the strike should be in the recording, then
        // take the loudest onset near that prediction.
        //
        // Searching the whole beat picks up spurious transients — key release, hand
        // noise, the desk — and a single wrong pick lands hundreds of milliseconds out,
        // wrecking the SD that check #1 depends on.
        //
        // This does not make the measurement circular. The prediction only decides WHICH
        // transient is the strike; the residual still comes from the independently
        // measured audio onset position. What it does cost is dynamic range: a residual
        // larger than the search radius cannot be seen. That failure is visible rather
        // than silent — a broken bridge shows up as mass rejection in `unmatchedNotes`.
        let arrivalSamples = arrivals.map(\.index)
        let searchRadius = 0.060 * fs

        var residuals: [Double] = []
        var phaseValues: [Double] = []
        var times: [Double] = []
        var unmatched = 0

        for i in 0..<min(emitHostSeconds.count, arrivalSamples.count) {
            guard let midi = notesPerChirp[i], midi.count == 1 else { continue }

            let expected = arrivalSamples[i] + midi[0] * fs
            var best: DSP.Onset?
            for onset in onsets {                       // ascending by sample
                let delta = Double(onset.sample) - expected
                if delta < -searchRadius { continue }
                if delta > searchRadius { break }
                if onset.peak > (best?.peak ?? -.infinity) { best = onset }
            }
            guard let thock = best else { unmatched += 1; continue }

            let audioOffset = (Double(thock.sample) - arrivalSamples[i]) / fs
            residuals.append((midi[0] - audioOffset) * 1000)
            phaseValues.append(i < phases.count ? phases[i] : 0)
            times.append(emitHostSeconds[i])
        }

        // Discard beats more than 5 ms from the median before computing statistics.
        //
        // This is a quality gate, not curve-fitting. The bridge's own jitter is
        // sub-millisecond by construction, so a residual that far out cannot be the
        // bridge — it is a strike the onset detector confused with a competing transient
        // that landed within a few milliseconds of it, which is physically inseparable.
        // Leaving those in corrupts the SD and the two regressions alike. The count is
        // reported, so heavy trimming is visible rather than quietly swallowed.
        let centre = Stats.median(residuals)
        let kept = residuals.indices.filter { abs(residuals[$0] - centre) <= 5.0 }
        let clean = kept.map { residuals[$0] }
        let cleanPhases = kept.map { phaseValues[$0] }
        let cleanTimes = kept.map { times[$0] }

        return ValidationResult(
            residualsMs: clean,
            median: Stats.median(clean),
            sd: Stats.sd(clean),
            iqr: Stats.iqr(clean),
            phaseFit: Stats.linearFit(x: cleanPhases, y: clean),
            timeFit: Stats.linearFit(x: cleanTimes, y: clean),
            pairedBeats: clean.count,
            midiNotes: noteHostSeconds.count,
            thocksDetected: onsets.count,
            chirpsFound: arrivals.count,
            unmatchedNotes: unmatched,
            trimmedBeats: residuals.count - clean.count)
    }

    /// Index of the last entry at or before `value`, provided it is no further back than
    /// `within`. `candidates` must be ascending.
    private static func precedingIndex(to value: Double, in candidates: [Double], within: Double) -> Int? {
        var found: Int? = nil
        for (i, v) in candidates.enumerated() {
            if v <= value { found = i } else { break }
        }
        guard let i = found, value - candidates[i] <= within else { return nil }
        return i
    }
}
