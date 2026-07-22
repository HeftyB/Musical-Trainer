import Foundation

enum Chirp {
    /// Linear frequency sweep with a Hann window.
    ///
    /// A swept chirp is used rather than an impulse because its autocorrelation is a far
    /// sharper spike: the sweep spreads energy over time, so it survives room noise and
    /// speaker roll-off while still collapsing to a single narrow correlation peak. The
    /// Hann window removes the edge discontinuities that would otherwise smear that peak.
    static func make(sampleRate: Double,
                     duration: Double = 0.020,
                     f0: Double = 500,
                     f1: Double = 8000) -> [Float] {
        let n = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            // Instantaneous frequency f(t) = f0 + (f1-f0)·t/T, so phase is its integral.
            let phase = 2 * .pi * (f0 * t + (f1 - f0) * t * t / (2 * duration))
            let window = 0.5 * (1 - cos(2 * .pi * Double(i) / Double(n - 1)))
            out[i] = Float(sin(phase) * window)
        }
        return out
    }
}
