import Foundation

/// One note-on, before chord clustering.
///
/// The timing analysis collapses a chord to a single rhythmic event, which is right for
/// asking *when* a note landed and useless for asking *what* was played. Content measures
/// need every note.
public struct PlayedNote: Equatable {
    public let time: Double
    public let note: Int?
    public let velocity: Int?

    public init(time: Double, note: Int?, velocity: Int?) {
        self.time = time; self.note = note; self.velocity = velocity
    }
}

/// What was played over a stretch of a take, with no reference to how well it was timed.
public struct ContentMeasures: Equatable {
    public let noteCount: Int
    /// Rhythmic events per beat — chords count once. The density of the *playing*, which is
    /// also the most obvious confound with timing spread.
    public let eventsPerBeat: Double
    /// Distinct pitch classes touched.
    public let pitchClassCount: Int
    /// Shannon entropy of the pitch-class distribution, in bits. Zero when one note repeats.
    public let pitchEntropyBits: Double
    /// Mean absolute step in the top line, in semitones. Zero for a repeated note.
    public let meanIntervalSemitones: Double
    /// Fraction of melodic steps that reverse direction, 0…1. A scale runs near 0; a shaped
    /// melody sits well above it.
    public let contourReversalRate: Double
    /// Mean simultaneous notes per event — 1 is a single line, 3+ is chordal.
    public let meanChordSize: Double
    /// Spread of velocity. Dynamics, roughly.
    public let velocitySD: Double

    /// A single 0…1 summary of how far this is from a metronomic single repeated note.
    ///
    /// Deliberately crude and deliberately named "interest" rather than anything that sounds
    /// like a measurement: it is a convenience for ranking windows, not a quantity. Any
    /// finding must be stated against a specific component, never this.
    public var interest: Double {
        let pitch = min(1, pitchEntropyBits / 3)          // 3 bits ≈ 8 pitch classes
        let melodic = min(1, meanIntervalSemitones / 7)   // a fifth
        let shape = min(1, contourReversalRate / 0.5)
        let dynamics = min(1, velocitySD / 20)
        return (pitch + melodic + shape + dynamics) / 4
    }
}

/// One window of a take: what was played, and how it was timed.
public struct ContentWindow: Equatable {
    public let index: Int
    public let startTime: Double
    public let endTime: Double
    public let content: ContentMeasures
    /// SD of asynchrony over the events that matched the grid in this window.
    public let spreadMs: Double
    public let matchedCount: Int
    /// Fraction of events that fell outside the matching window.
    ///
    /// **Load-bearing for interpretation.** Spread is computed only on matched events, so a
    /// window where more notes fell off the grid reports the spread of a self-selected
    /// subset. Rising off-grid alongside rising "interest" means the comparison is censored,
    /// not that the playing got tighter.
    public let offGridRate: Double
}

public struct ContentCorrelation: Equatable {
    public let measure: String
    /// Pearson r against timing spread. Positive means more of this measure went with looser
    /// timing.
    public let r: Double
    public let windowCount: Int
}

public struct ContentReport: Equatable {
    public let windows: [ContentWindow]
    public let correlations: [ContentCorrelation]
    public let headline: String
    /// Everything that would make a reader over-claim from the numbers above.
    public let notes: [String]
}

/// Does what you play change how you time it?
///
/// The player's own observation, from the first full session: steady quarter notes with no
/// pitch change are close to sleep-inducing, while playing an actual melody feels far more in
/// the pocket. If that holds it matters, because "drill a boring exercise until it is tight"
/// would then be the wrong prescription for this player.
///
/// The design is **within-take**: a take is cut into windows, and content is correlated
/// against timing across those windows. Within-take holds the day, the fatigue, the tempo and
/// the backing fixed, so a relationship cannot be explained by any of them. What it cannot
/// hold fixed is stated in `notes` rather than assumed away.
public enum MusicalContentAnalysis {

    /// Notes closer together than this are one chord rather than a melodic step.
    public static let chordWindowSeconds = 0.035
    /// Below this many windows a correlation is not worth reporting.
    public static let minimumWindows = 5

    public static func analyze(rawNotes: [PlayedNote],
                               events: [Tap],
                               grid: Grid,
                               windowBars: Int = 8,
                               beatsPerBar: Int = 4,
                               matchWindowFraction: Double = 0.4) -> ContentReport {
        let match = Matching.match(taps: events, to: grid, windowFraction: matchWindowFraction)
        let windowSeconds = Double(windowBars * beatsPerBar) * grid.beatInterval
        guard windowSeconds > 0, !rawNotes.isEmpty else {
            return ContentReport(windows: [], correlations: [],
                                 headline: "Nothing was played in this take.", notes: [])
        }

        let start = grid.startTime
        let end = max(rawNotes.map(\.time).max() ?? start, events.map(\.time).max() ?? start)
        let windowCount = max(1, Int(((end - start) / windowSeconds).rounded(.up)))

        var windows: [ContentWindow] = []
        for index in 0..<windowCount {
            let from = start + Double(index) * windowSeconds
            let to = from + windowSeconds
            let notes = rawNotes.filter { $0.time >= from && $0.time < to }
            guard notes.count >= 2 else { continue }

            let matched = match.matched.filter { $0.tap.time >= from && $0.tap.time < to }
            let extras = match.extraTaps.filter { $0.time >= from && $0.time < to }
            let total = matched.count + extras.count

            windows.append(ContentWindow(
                index: index, startTime: from, endTime: to,
                content: measures(of: notes, overBeats: windowSeconds / grid.beatInterval),
                spreadMs: matched.count >= 4 ? Stats.sd(matched.map(\.asynchronyMs)) : .nan,
                matchedCount: matched.count,
                offGridRate: total > 0 ? Double(extras.count) / Double(total) : 0))
        }

        let usable = windows.filter { $0.spreadMs.isFinite }
        let correlations = correlate(usable)
        return ContentReport(windows: windows, correlations: correlations,
                             headline: headline(correlations, windows: usable),
                             notes: caveats(usable))
    }

    // MARK: - Measures

    public static func measures(of notes: [PlayedNote], overBeats beats: Double) -> ContentMeasures {
        let sorted = notes.sorted { $0.time < $1.time }
        let clusters = cluster(sorted)

        // The top line: the highest note of each chord. A melodic contour is carried by the
        // top voice far more than by the bass, and using every note of a chord would report
        // block chords as wild melodic activity.
        let topLine = clusters.compactMap { $0.compactMap(\.note).max() }
        var intervals: [Int] = []
        for i in 1..<max(topLine.count, 1) where topLine.count > 1 {
            intervals.append(topLine[i] - topLine[i - 1])
        }

        let moving = intervals.filter { $0 != 0 }
        var reversals = 0
        for i in 1..<max(moving.count, 1) where moving.count > 1 {
            if (moving[i] > 0) != (moving[i - 1] > 0) { reversals += 1 }
        }

        let velocities = sorted.compactMap(\.velocity).map(Double.init)
        return ContentMeasures(
            noteCount: sorted.count,
            eventsPerBeat: beats > 0 ? Double(clusters.count) / beats : 0,
            pitchClassCount: Set(sorted.compactMap { $0.note.map { $0 % 12 } }).count,
            pitchEntropyBits: entropy(of: sorted.compactMap { $0.note.map { $0 % 12 } }),
            meanIntervalSemitones: intervals.isEmpty ? 0
                : Stats.mean(intervals.map { Double(abs($0)) }),
            contourReversalRate: moving.count > 1
                ? Double(reversals) / Double(moving.count - 1) : 0,
            meanChordSize: clusters.isEmpty ? 0
                : Double(sorted.count) / Double(clusters.count),
            velocitySD: velocities.count > 1 ? Stats.sd(velocities) : 0)
    }

    /// Group near-simultaneous notes into chords.
    private static func cluster(_ sorted: [PlayedNote]) -> [[PlayedNote]] {
        var out: [[PlayedNote]] = []
        for note in sorted {
            if let last = out.last, let anchor = last.first,
               note.time - anchor.time <= chordWindowSeconds {
                out[out.count - 1].append(note)
            } else {
                out.append([note])
            }
        }
        return out
    }

    /// Shannon entropy of a distribution, in bits.
    private static func entropy(of values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        let n = Double(values.count)
        return -counts.values.reduce(0.0) { total, count in
            let p = Double(count) / n
            return total + p * Foundation.log2(p)
        }
    }

    // MARK: - Correlation

    private static func correlate(_ windows: [ContentWindow]) -> [ContentCorrelation] {
        guard windows.count >= minimumWindows else { return [] }
        let spread = windows.map(\.spreadMs)

        func row(_ name: String, _ value: (ContentMeasures) -> Double) -> ContentCorrelation? {
            guard let r = Stats.correlation(windows.map { value($0.content) }, spread) else {
                return nil
            }
            return ContentCorrelation(measure: name, r: r, windowCount: windows.count)
        }

        return [
            row("notes per beat", \.eventsPerBeat),
            row("pitch variety", \.pitchEntropyBits),
            row("melodic step", \.meanIntervalSemitones),
            row("contour shape", \.contourReversalRate),
            row("chord size", \.meanChordSize),
            row("dynamics", \.velocitySD),
            row("overall interest", \.interest),
        ].compactMap { $0 }
    }

    private static func headline(_ correlations: [ContentCorrelation],
                                 windows: [ContentWindow]) -> String {
        guard let interest = correlations.first(where: { $0.measure == "overall interest" }) else {
            return "Not enough of this take could be scored to relate what you played to how "
                 + "you timed it — \(windows.count) usable window(s), "
                 + "\(minimumWindows) needed."
        }
        if abs(interest.r) < 0.3 {
            return String(format: "Across %d windows, what you played and how tightly you "
                        + "played it look unrelated (r = %+.2f).",
                          interest.windowCount, interest.r)
        }
        if interest.r < 0 {
            return String(format: "The more interesting the playing, the tighter the timing "
                        + "in this take (r = %+.2f over %d windows). That matches the hunch, "
                        + "and one take cannot confirm it.", interest.r, interest.windowCount)
        }
        return String(format: "Busier playing went with looser timing here (r = %+.2f over %d "
                    + "windows) — the opposite of the hunch, and worth checking against the "
                    + "note density row before reading anything into it.",
                      interest.r, interest.windowCount)
    }

    /// What would make a reader over-claim. Every one of these is live in real data.
    private static func caveats(_ windows: [ContentWindow]) -> [String] {
        var notes: [String] = []
        guard !windows.isEmpty else { return notes }

        // 1. Censoring. Spread is computed on matched events only.
        //
        // The direction matters and is easy to get backwards. Off-grid notes are the
        // *worst-placed* ones, so excluding them shrinks the spread of whichever windows lose
        // most — which are the busier ones. Busy windows therefore have their spread
        // understated, and the censoring pushes the measured relationship toward "busier looks
        // tighter". Which way that cuts depends on the sign actually observed, so say it.
        let offGrid = windows.map(\.offGridRate)
        let interest = windows.map(\.content.interest)
        if let interestVsOffGrid = Stats.correlation(interest, offGrid),
           abs(interestVsOffGrid) > 0.4 {
            var note = String(format: "Off-grid rate tracks what you played (r = %+.2f), and "
                            + "spread is measured only on notes that stayed on the grid. "
                            + "Busier windows are scored on a self-selected subset — and since "
                            + "the notes dropped are the worst-placed ones, their spread is "
                            + "understated.", interestVsOffGrid)
            if let observed = Stats.correlation(interest, windows.map(\.spreadMs)) {
                note += observed > 0
                    ? " That bias favours \"busier is tighter\", and the measurement came out "
                    + "the other way, so the effect is at least as large as it looks."
                    : " That bias points the same way as the measured effect, so some of "
                    + "\"busier is tighter\" here may be the censoring rather than the playing."
            }
            notes.append(note)
        }
        if (offGrid.max() ?? 0) > 0.2 {
            notes.append(String(format: "Up to %.0f%% of events in a window fell off the grid. "
                              + "Above roughly 20%% the spread figure for that window is not "
                              + "describing the same playing as the others.",
                                (offGrid.max() ?? 0) * 100))
        }

        // 2. Subdivision. Spread scales with the note values being played.
        if let density = Stats.correlation(windows.map(\.content.eventsPerBeat),
                                           windows.map(\.spreadMs)), abs(density) > 0.4 {
            notes.append(String(format: "Note density correlates with spread (r = %+.2f). "
                              + "Timing spread scales with the subdivision being played, so "
                              + "some of any content effect here is note values rather than "
                              + "musical interest.", density))
        }

        // 3. Arousal. Not separable by this design, ever.
        notes.append("Playing something interesting is both more melodic *and* more engaging. "
                   + "This design cannot separate the two — a real effect here says content "
                   + "matters, not why.")
        return notes
    }
}
