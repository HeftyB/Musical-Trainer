import Foundation
import TimingCore

/// Turns a recorded jam into something TimingCore can analyze.
///
/// Two clocks come in — the groove's (hostTime, sample) map and the captured MIDI note-ons
/// in host time — and both are reduced to one "seconds since epoch" timeline. Calibration is
/// applied here by shifting every tap earlier by the stored constant, so
/// `asynchrony = (midiHostSec − clickEmitSec) − (L_midi + L_out)` exactly as in the M0 rig.
///
/// Factored out of the command so the calibration arithmetic — above all the *sign* of the
/// constant — is pinned down by `selftest` rather than trusted.
enum JamAnalysis {
    struct Reduced {
        let taps: [Tap]
        let grid: Grid
        /// Notes that arrived within the analysis window, before matching.
        let tapsInWindow: Int
    }

    static func reduce(outputMap: [(hostTime: UInt64, sample: Int64)],
                       midi: [(hostTime: UInt64, velocity: Int, note: Int)],
                       grooveStartSample: Int64,
                       grooveEndSample: Int64,
                       bpm: Double,
                       subdivisions: Int,
                       feel: Feel = .straight,
                       calibrationConstantMs: Double) -> Reduced? {
        guard let epoch = outputMap.first?.hostTime else { return nil }
        var map = SampleHostMap()
        map.build(pairs: outputMap, epoch: epoch)
        guard let startSec = map.hostSeconds(atSample: Double(grooveStartSample)),
              let endSec = map.hostSeconds(atSample: Double(grooveEndSample)) else { return nil }

        let constantSec = calibrationConstantMs / 1000
        // The feel has to reach the grid or a swung take is scored straight, which does not
        // fail — it reports a large, plausible drag with a doubled spread and an inverted r₁.
        // See JOURNAL.md §7.24 step 7.
        let grid = Grid(startTime: startSec, bpm: bpm, subdivisions: subdivisions, feel: feel)

        // A one-beat guard band on each side drops the count-in notes and any final
        // ring-out so they cannot masquerade as timing data.
        let lo = startSec - grid.beatInterval
        let hi = endSec + grid.beatInterval
        let taps = midi.compactMap { event -> Tap? in
            let t = HostClock.interval(from: epoch, to: event.hostTime) - constantSec
            guard t >= lo && t <= hi else { return nil }
            return Tap(time: t, velocity: event.velocity, note: event.note)
        }
        return Reduced(taps: taps, grid: grid, tapsInWindow: taps.count)
    }
}
