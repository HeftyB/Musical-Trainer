import Foundation

/// Collapses near-simultaneous taps into single rhythmic events.
///
/// A keyboard chord is several note-ons within a few milliseconds; rhythmically it is *one*
/// event, not four. Without this, matching keeps one note per grid point and throws the rest
/// out as "between beats," which both inflates the off-grid count and biases the statistics.
/// A window of a few tens of milliseconds captures block chords and grace-note rolls while
/// staying well under the spacing of even fast single-note runs (a 32nd at 160 BPM is 94 ms),
/// so genuine notes are never merged.
public enum TapClustering {
    /// Group taps whose onsets fall within `windowSeconds` of the group's start. Each group
    /// becomes one tap at the group's mean time, carrying the group's loudest velocity.
    public static func collapse(_ taps: [Tap], windowSeconds: Double) -> [Tap] {
        guard windowSeconds > 0, taps.count > 1 else { return taps }
        let sorted = taps.sorted { $0.time < $1.time }

        var result: [Tap] = []
        var groupTimes: [Double] = []
        var groupVelocity: Int?
        var anchor = sorted[0].time

        func flush() {
            guard !groupTimes.isEmpty else { return }
            let mean = groupTimes.reduce(0, +) / Double(groupTimes.count)
            result.append(Tap(time: mean, velocity: groupVelocity))
            groupTimes.removeAll(keepingCapacity: true)
            groupVelocity = nil
        }

        for tap in sorted {
            if groupTimes.isEmpty { anchor = tap.time }
            // Anchor on the group's first onset so a group spans at most one window — an
            // arpeggio can't chain note-by-note into one giant event.
            if tap.time - anchor <= windowSeconds {
                groupTimes.append(tap.time)
                if let v = tap.velocity { groupVelocity = max(groupVelocity ?? 0, v) }
            } else {
                flush()
                anchor = tap.time
                groupTimes.append(tap.time)
                groupVelocity = tap.velocity
            }
        }
        flush()
        return result
    }
}
