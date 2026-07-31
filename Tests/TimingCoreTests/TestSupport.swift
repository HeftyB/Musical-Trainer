import Foundation
@testable import TimingCore

/// Deterministic Gaussian source so every test is reproducible run to run.
struct SeededRNG {
    private var state: UInt64
    init(seed: UInt64 = 0x9E3779B97F4A7C15) { state = seed }

    mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func gaussian(mean: Double = 0, sd: Double = 1) -> Double {
        let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
        return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}

enum Generators {
    /// A Wing–Kristofferson process with known clock and motor variances.
    ///
    /// Onset k = Σ clock intervals so far + a fresh motor delay. The interval series this
    /// produces has variance σ²_clock + 2σ²_motor and lag-1 autocovariance −σ²_motor by
    /// construction, so a correct decomposition must recover the inputs.
    static func wkTapTimes(count: Int, beatMs: Double,
                           clockSD: Double, motorSD: Double,
                           rng: inout SeededRNG) -> [Double] {
        var times: [Double] = []
        var clockSum = 0.0
        for _ in 0..<count {
            let motor = rng.gaussian(sd: motorSD)
            times.append((clockSum + motor) / 1000)          // ms → s
            clockSum += rng.gaussian(mean: beatMs, sd: clockSD)
        }
        return times
    }

    /// Taps on the grid with a fixed bias and independent jitter.
    static func tapsOnGrid(grid: Grid, beats: Int, biasMs: Double, jitterMs: Double,
                           rng: inout SeededRNG) -> [Tap] {
        (0..<beats).map { k in
            let async = (biasMs + rng.gaussian(sd: jitterMs)) / 1000
            return Tap(time: grid.time(ofIndex: k) + async)
        }
    }
}
