import Darwin
import Foundation
import TimingCore

/// Conversions for `mach_absolute_time` ticks. The ratio is fixed at boot, so it is
/// resolved once and cached.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 { mach_absolute_time() }

    static func seconds(ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Signed interval `b - a`. Host time is unsigned, so a naive subtraction would
    /// wrap when b precedes a.
    static func interval(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? seconds(ticks: b - a) : -seconds(ticks: a - b)
    }
}

/// Least-squares map between a stream's sample index and host time.
///
/// A single (hostTime, sample) pair would be enough in principle, but the pairs carry
/// callback jitter. Fitting a line over many of them averages that out and — because
/// the fitted slope *is* the device's true sample rate — also absorbs the difference
/// between nominal and actual clock rate.
struct SampleHostMap {
    private(set) var hostSeconds: [Double] = []
    private(set) var sampleIndex: [Double] = []
    private var fit: Regression?

    /// `sample = intercept + slope * hostSeconds`, so slope is samples/sec.
    mutating func build(pairs: [(hostTime: UInt64, sample: Int64)], epoch: UInt64) {
        hostSeconds = pairs.map { HostClock.interval(from: epoch, to: $0.hostTime) }
        sampleIndex = pairs.map { Double($0.sample) }
        fit = Stats.linearFit(x: hostSeconds, y: sampleIndex)
    }

    var measuredSampleRate: Double? { fit?.slope }

    func sample(atHostSeconds t: Double) -> Double? {
        guard let f = fit else { return nil }
        return f.intercept + f.slope * t
    }

    func hostSeconds(atSample s: Double) -> Double? {
        guard let f = fit, f.slope != 0 else { return nil }
        return (s - f.intercept) / f.slope
    }
}
