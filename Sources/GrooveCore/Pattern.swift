import Foundation

/// One bar of drum programming on a fixed step grid.
///
/// The whole engine uses one grid resolution — 16 steps per bar, 4 per beat (sixteenth
/// notes in 4/4) by default — so every bar is the same number of samples long and the
/// sequencer's sample math stays trivial index arithmetic. Patterns differ only in which
/// steps fire, never in resolution.
public struct Pattern: Equatable {
    public let stepsPerBar: Int
    public let stepsPerBeat: Int
    public let hits: [Hit]

    public var beatsPerBar: Int { stepsPerBar / stepsPerBeat }

    public init(stepsPerBar: Int = 16, stepsPerBeat: Int = 4, hits: [Hit]) {
        precondition(stepsPerBar > 0 && stepsPerBeat > 0, "steps must be positive")
        precondition(stepsPerBar % stepsPerBeat == 0, "stepsPerBar must be a whole number of beats")
        self.stepsPerBar = stepsPerBar
        self.stepsPerBeat = stepsPerBeat
        self.hits = hits
    }

    /// Build a pattern from a compact per-voice step list.
    public static func make(stepsPerBar: Int = 16, stepsPerBeat: Int = 4,
                            _ lines: [DrumVoice: [Int]], velocity: Int = 100) -> Pattern {
        let hits = lines.flatMap { voice, steps in
            steps.map { Hit(voice: voice, step: $0, velocity: velocity) }
        }
        return Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat, hits: hits)
    }

    public static let silence = Pattern(hits: [])
}

/// A run of bars playing one pattern, optionally with a different pattern on the final bar
/// (a fill). Sections are how a long jam gets sectional contrast instead of hypnotic
/// sameness — see PLAN.md §6.
public struct Section: Equatable {
    public let name: String
    public let pattern: Pattern
    public let bars: Int
    /// Played instead of `pattern` on the last bar of the section.
    public let fill: Pattern?

    public init(name: String, pattern: Pattern, bars: Int, fill: Pattern? = nil) {
        precondition(bars >= 1, "a section needs at least one bar")
        self.name = name
        self.pattern = pattern
        self.bars = bars
        self.fill = fill
    }
}

/// An ordered set of sections. Resolves an absolute bar index to the pattern that plays.
public struct Arrangement: Equatable {
    public let sections: [Section]
    public let loop: Bool

    public init(sections: [Section], loop: Bool = true) {
        precondition(!sections.isEmpty, "an arrangement needs at least one section")
        // One grid resolution across the whole arrangement keeps bar lengths uniform.
        let first = sections[0].pattern
        for section in sections {
            precondition(section.pattern.stepsPerBar == first.stepsPerBar
                      && section.pattern.stepsPerBeat == first.stepsPerBeat,
                         "all patterns in an arrangement must share the step grid")
        }
        self.sections = sections
        self.loop = loop
    }

    public var stepsPerBar: Int { sections[0].pattern.stepsPerBar }
    public var stepsPerBeat: Int { sections[0].pattern.stepsPerBeat }
    public var totalBars: Int { sections.reduce(0) { $0 + $1.bars } }

    /// The pattern to play at an absolute bar index, honoring section boundaries, fills,
    /// and looping.
    public func pattern(atBar bar: Int) -> Pattern {
        guard bar >= 0 else { return .silence }
        var index = bar
        if loop { index = bar % totalBars }
        else if index >= totalBars { return .silence }

        var cursor = 0
        for section in sections {
            if index < cursor + section.bars {
                let isLastBar = index == cursor + section.bars - 1
                if isLastBar, let fill = section.fill { return fill }
                return section.pattern
            }
            cursor += section.bars
        }
        return .silence
    }
}
