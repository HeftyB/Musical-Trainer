import Foundation

/// The metronomic grid a performance is measured against.
///
/// The grid is defined by index arithmetic, never by accumulating an interval, so it never
/// drifts however long a session runs — the same discipline the audio clock uses. It also
/// extends infinitely in both directions, which matters for dropout drills: when the click
/// falls silent the grid is still defined, so we can measure how far the player has drifted
/// from where the beat *would* have been.
///
/// **Indices stay uniform; only their times move.** A feel shifts where a subdivision is
/// expected within the beat (M15, §7.24), and it would have been possible to express that by
/// making the grid unevenly indexed. It is not: index `n` is still the `n`th subdivision, every
/// beat still holds `subdivisions` of them, and `phase(ofIndex:)` is still a modulo. That is
/// what keeps the change contained — everything downstream of matching works in grid indices,
/// so a feel reaches `Matching` and stops.
public struct Grid: Equatable {
    /// Timeline position of grid index 0, in seconds.
    public let startTime: Double
    public let bpm: Double
    /// Grid points per beat: 1 = quarter notes, 2 = eighths, 4 = sixteenths, 3 = triplets.
    public let subdivisions: Int
    /// Where within the beat each subdivision is expected. Straight is the identity, and every
    /// take recorded before M15 is straight — see `Feel`.
    public let feel: Feel

    public init(startTime: Double, bpm: Double, subdivisions: Int = 1, feel: Feel = .straight) {
        precondition(bpm > 0, "bpm must be positive")
        precondition(subdivisions >= 1, "subdivisions must be at least 1")
        self.startTime = startTime
        self.bpm = bpm
        self.subdivisions = subdivisions
        self.feel = feel
    }

    /// Seconds per beat, independent of subdivision.
    public var beatInterval: Double { 60.0 / bpm }

    // There is deliberately no `interval`. Under a feel the grid has no single spacing, so a
    // property claiming one would be a lie the moment swing arrived — and it had exactly one
    // consumer, the matching window, which now asks `gap(around:)` for the spacing at a
    // *particular* point. Killing it was cheaper than letting a second meaning grow around it,
    // which is the mistake §7.23 made four times with "how finely we divide the beat".

    /// Where each subdivision of the beat sits, as a fraction of the beat.
    ///
    /// Computed on each access, not cached — `nearestIndex(to:)` searches three beats' worth of
    /// candidates per tap and every one of them rebuilds this array. It has never been on a hot
    /// path that mattered (analysis runs after the take, never in the render callback), so the
    /// allocation is left alone rather than traded for a stored property that would have to be
    /// kept in step with `feel` and `subdivisions`. The comment here previously claimed a cache
    /// that did not exist, which is worse than either choice.
    private var phases: [Double] { feel.phases(subdivisions: subdivisions) }

    public func time(ofIndex index: Int) -> Double {
        let beat = Int(floor(Double(index) / Double(subdivisions)))
        return startTime + (Double(beat) + phases[phase(ofIndex: index)]) * beatInterval
    }

    /// Grid index whose time is closest to `time`. May be negative.
    ///
    /// A search rather than a division, because under a feel the points are unevenly spaced and
    /// there is nothing to divide by. It looks at the beat the time falls in and its two
    /// neighbours, which is every point that could possibly be nearest — a beat is the period
    /// of the feel, so no point more than one beat away can beat one inside it.
    public func nearestIndex(to time: Double) -> Int {
        let beat = Int(floor((time - startTime) / beatInterval))
        var best = beat * subdivisions
        var bestDistance = Double.infinity
        for candidateBeat in (beat - 1)...(beat + 1) {
            for phase in 0..<subdivisions {
                let index = candidateBeat * subdivisions + phase
                let distance = abs(time - self.time(ofIndex: index))
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
        }
        return best
    }

    /// The spacing that governs a point's capture window: the **smaller** of the gaps to its
    /// neighbours.
    ///
    /// Symmetric on the smaller side rather than asymmetric per side, and that is a measurement
    /// decision rather than a convenience. A window reaching 40% of each neighbouring gap would
    /// be wider on the long side of a swung pair, so it would capture more late outliers than
    /// early ones and **pull the mean late** — §5.3's trap in a form where the numbers stay
    /// plausible. Symmetric costs a little capture and biases nothing.
    ///
    /// It also guarantees the windows stay disjoint, which `Matching` relies on: each half-width
    /// is at most 40% of the gap it sits in, so two adjacent windows span at most 80% of the
    /// distance between their points and can never overlap.
    public func gap(around index: Int) -> Double {
        let here = time(ofIndex: index)
        return min(here - time(ofIndex: index - 1), time(ofIndex: index + 1) - here)
    }

    /// Which subdivision within the beat a grid index falls on: 0 is the downbeat.
    /// Uses floored modulo so negative indices classify correctly.
    public func phase(ofIndex index: Int) -> Int {
        ((index % subdivisions) + subdivisions) % subdivisions
    }
}
