import Accelerate
import Foundation

enum DSP {
    /// Cross-correlation of `signal` against `kernel`.
    ///
    /// `vDSP_conv` computes `C[n] = sum_p A[n+p] * F[p]` — a sliding dot product with no
    /// kernel reversal. That is correlation, not convolution, which is what we want here;
    /// convolution would require passing the kernel reversed.
    static func correlate(signal: [Float], kernel: [Float]) -> [Float] {
        let n = signal.count - kernel.count + 1
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        vDSP_conv(signal, 1, kernel, 1, &out, 1, vDSP_Length(n), vDSP_Length(kernel.count))
        return out
    }

    /// Refine a discrete peak to sub-sample resolution by fitting a parabola through the
    /// three samples bracketing it. At 44.1 kHz this takes resolution from ~23 µs to
    /// well under a microsecond — free precision, since we already have the samples.
    static func refinePeak(_ x: [Float], at k: Int) -> Double {
        guard k > 0, k < x.count - 1 else { return Double(k) }
        let ym1 = Double(x[k - 1]), y0 = Double(x[k]), yp1 = Double(x[k + 1])
        let denom = ym1 - 2 * y0 + yp1
        guard denom != 0 else { return Double(k) }
        let delta = 0.5 * (ym1 - yp1) / denom
        // A well-formed peak lands within half a sample; anything else is noise.
        return abs(delta) <= 1 ? Double(k) + delta : Double(k)
    }

    /// The `count` strongest correlation peaks, no two closer than `minSeparation`.
    /// Greedy peak-picking: take the global max, suppress its neighbourhood, repeat.
    static func topPeaks(_ x: [Float], count: Int, minSeparation: Int) -> [(index: Double, value: Float)] {
        guard !x.isEmpty, count > 0 else { return [] }
        var suppressed = [Bool](repeating: false, count: x.count)
        var found: [(index: Double, value: Float)] = []

        for _ in 0..<count {
            var bestIdx = -1
            var bestVal = -Float.greatestFiniteMagnitude
            for i in 0..<x.count where !suppressed[i] && x[i] > bestVal {
                bestVal = x[i]; bestIdx = i
            }
            guard bestIdx >= 0, bestVal > 0 else { break }
            found.append((refinePeak(x, at: bestIdx), bestVal))
            let lo = max(0, bestIdx - minSeparation)
            let hi = min(x.count - 1, bestIdx + minSeparation)
            for i in lo...hi { suppressed[i] = true }
        }
        return found.sorted { $0.index < $1.index }
    }

    /// Transient-emphasising envelope: first-difference high-pass, rectify, one-pole smooth.
    ///
    /// The first difference kills low-frequency room rumble and fan noise while passing the
    /// broadband edge of a key strike, which is exactly the discrimination we need.
    static func transientEnvelope(_ x: [Float], smoothing: Float) -> [Float] {
        var env = [Float](repeating: 0, count: x.count)
        var state: Float = 0
        var prev: Float = 0
        for i in 0..<x.count {
            let hp = x[i] - prev
            prev = x[i]
            state += smoothing * (abs(hp) - state)
            env[i] = state
        }
        return env
    }

    struct Onset {
        let sample: Int
        let peak: Float
        /// Peak amplitude over the local noise floor. Used to reject weak detections.
        let snr: Float
    }

    /// Peak-pick the envelope, then walk back to where the transient actually began.
    ///
    /// Taking the envelope peak alone would systematically report an onset late by the
    /// smoothing time constant. Backtracking to a fraction of the peak removes most of
    /// that bias and, crucially, makes the remaining bias *consistent* across strikes.
    static func detectOnsets(envelope: [Float],
                             noiseFloor: Float,
                             thresholdRatio: Float,
                             minSeparation: Int,
                             searchWindow: Int,
                             backtrackRatio: Float,
                             maxBacktrack: Int,
                             excluded: (Int) -> Bool) -> [Onset] {
        let threshold = noiseFloor * thresholdRatio
        var onsets: [Onset] = []
        var i = 0
        while i < envelope.count {
            guard envelope[i] > threshold, !excluded(i) else { i += 1; continue }

            let hi = min(envelope.count - 1, i + searchWindow)
            var peakIdx = i
            for j in i...hi where envelope[j] > envelope[peakIdx] { peakIdx = j }
            let peakVal = envelope[peakIdx]

            // Walk back to where the attack began, but no further than `maxBacktrack`.
            //
            // The distance bound is what makes this robust. A percussive attack is over
            // in a couple of milliseconds, so anything further back belongs to a
            // different event — without the bound, a transient decaying in from 20 ms
            // earlier keeps the envelope above the ratio and the walk runs straight
            // through it, reporting the onset tens of milliseconds early.
            //
            // Stopping at a local minimum instead was tried and is worse: a noisy
            // envelope has minima on its own attack slope, so the walk halts early and
            // biases every onset late.
            var start = peakIdx
            let floorVal = peakVal * backtrackRatio
            let limit = min(peakIdx, maxBacktrack)
            while start > 0, envelope[start - 1] > floorVal, peakIdx - start < limit {
                start -= 1
            }

            if !excluded(start) {
                onsets.append(Onset(sample: start,
                                    peak: peakVal,
                                    snr: noiseFloor > 0 ? peakVal / noiseFloor : .infinity))
            }
            i = peakIdx + minSeparation
        }
        return onsets
    }

    /// Robust noise floor: a low percentile of the envelope, which ignores the transients
    /// we are trying to find.
    static func noiseFloor(_ envelope: [Float]) -> Float {
        guard !envelope.isEmpty else { return 0 }
        let sorted = envelope.sorted()
        return sorted[Int(0.2 * Double(sorted.count - 1))]
    }
}
