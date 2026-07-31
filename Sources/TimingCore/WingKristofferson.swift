import Foundation

/// Splits the timing variance of a self-paced continuation task into a central timekeeper
/// ("clock") and peripheral motor execution ("motor"). See PLAN.md §5.2.
///
/// The two-level model treats each inter-onset interval as a clock interval plus the
/// difference of two independent motor delays (one at each end). That structure forces the
/// motor noise to show up as *negative* lag-1 autocovariance — a long interval tends to be
/// followed by a short one, because the shared motor delay at the boundary lands with
/// opposite sign in the two intervals. Hence:
///
///     σ²_motor = −γ₁
///     σ²_clock =  γ₀ + 2γ₁
///
/// where γ₀ is the interval variance and γ₁ their lag-1 autocovariance.
///
/// Why it matters here: it answers a question feel cannot — is the pulse in your head
/// unstable, or is the pulse fine and your hands are noisy? Those demand different training
/// and are indistinguishable from the inside.
public struct WingKristoffersonResult: Equatable {
    public let clockVarianceMs2: Double
    public let motorVarianceMs2: Double
    /// √clock variance, floored at 0. The standard deviation of the internal timekeeper.
    public let clockSDms: Double
    /// √motor variance, floored at 0. The standard deviation of motor execution noise.
    public let motorSDms: Double
    public let intervalVarianceMs2: Double        // γ₀
    public let lag1AutocovarianceMs2: Double      // γ₁
    public let intervalCount: Int

    /// The decomposition is only valid when γ₁ ≤ 0 (so motor variance ≥ 0) and the clock
    /// variance is non-negative. A positive γ₁ means the sequence is drifting rather than
    /// stationary — tempo wandering, not a stable timekeeper — and the split is unreliable.
    /// Read the estimates only when this is true.
    public let modelHolds: Bool
}

public enum WingKristofferson {
    /// Decompose from inter-onset intervals in milliseconds.
    ///
    /// Needs a stationary continuation sequence: taps produced *after* the click drops out,
    /// with no external pacing. A drifting or accelerating passage violates the model's
    /// stationarity assumption and trips `modelHolds`.
    public static func decompose(intervalsMs: [Double], tolerance: Double = 1e-9) -> WingKristoffersonResult? {
        guard intervalsMs.count >= 3 else { return nil }

        let g0 = Stats.populationVariance(intervalsMs)
        let g1 = Stats.autocovariance(intervalsMs, lag: 1)

        let motorVar = -g1
        let clockVar = g0 + 2 * g1

        let holds = motorVar >= -tolerance && clockVar >= -tolerance
        return WingKristoffersonResult(
            clockVarianceMs2: clockVar,
            motorVarianceMs2: motorVar,
            clockSDms: max(0, clockVar).squareRoot(),
            motorSDms: max(0, motorVar).squareRoot(),
            intervalVarianceMs2: g0,
            lag1AutocovarianceMs2: g1,
            intervalCount: intervalsMs.count,
            modelHolds: holds)
    }

    /// Convenience: decompose directly from tap times in seconds.
    public static func decompose(tapTimes: [Double]) -> WingKristoffersonResult? {
        guard tapTimes.count >= 4 else { return nil }
        var intervals: [Double] = []
        intervals.reserveCapacity(tapTimes.count - 1)
        for i in 1..<tapTimes.count {
            intervals.append((tapTimes[i] - tapTimes[i - 1]) * 1000)
        }
        return decompose(intervalsMs: intervals)
    }
}
