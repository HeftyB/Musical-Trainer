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
    ///
    /// **The result is sorted, and that is a correctness fix rather than tidiness.** The input is
    /// a dictionary, and Swift seeds its hashing per process, so `flatMap` over it produced hits
    /// in a different order on every launch. Float addition is not associative, so two hits
    /// landing on one sample summed to a value that differed in its last bit run to run: the
    /// same backing rendered to different bytes twice in a row, against R1.2.2's "identical
    /// inputs produce identical outputs".
    ///
    /// Inaudible, and it made every byte-comparison gate in M19 unreliable — including the one
    /// that said step 1 moved nothing. Found because the bass demo made two overlapping voices
    /// common enough to notice (§7.29 step 2).
    public static func make(stepsPerBar: Int = 16, stepsPerBeat: Int = 4,
                            _ lines: [BackingVoice: [Int]], velocity: Int = 100) -> Pattern {
        let hits = lines
            .flatMap { voice, steps in
                steps.map { Hit(voice: voice, step: $0, velocity: velocity) }
            }
            .sorted { ($0.step, $0.voice.rawValue) < ($1.step, $1.voice.rawValue) }
        return Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat, hits: hits)
    }

    /// A bass figure: steps paired with the note each one sounds.
    ///
    /// Separate from `make` because a drum line is a set of steps and a bass line is a set of
    /// (step, note) pairs — collapsing them into one call would mean every drum pattern carrying
    /// a column of `nil`s.
    public static func bass(stepsPerBar: Int = 16, stepsPerBeat: Int = 4,
                           _ figure: [(step: Int, note: Int)], velocity: Int = 100) -> Pattern {
        Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat,
                hits: figure.map {
                    Hit(voice: .bass, step: $0.step, velocity: velocity, note: $0.note)
                })
    }

    /// The same pattern with extra hits layered on top.
    public func adding(_ extra: [Hit]) -> Pattern {
        Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat, hits: hits + extra)
    }

    public static let silence = Pattern(hits: [])

    /// The one resolution every arrangement plays on: **24 steps to the beat**.
    ///
    /// The lowest common multiple of 2, 3, 4, 6, 8 and 12, so binary and ternary subdivisions
    /// coexist on one grid — a triplet fill can sit inside a straight groove, a 12/8 section can
    /// follow a 4/4 one, and M16.5's triplet skank is a pattern rather than a format change.
    /// `Sequencer` iterates *hits*, never steps, so a finer grid costs nothing to render.
    ///
    /// Patterns are still **authored** at whatever resolution reads naturally — sixteenths for
    /// rock, twelfths for a shuffle — and `Arrangement` lifts them here. Nothing is transcribed
    /// by hand, so nothing is mis-transcribed.
    public static let commonStepsPerBeat = 24

    /// The same pattern, the same hit *times*, expressed on a finer grid.
    ///
    /// Exact by construction: the target must be a whole multiple of this pattern's resolution,
    /// so every step index scales by an integer and no position is ever rounded. A pattern that
    /// cannot be lifted exactly is a programming error rather than something to approximate —
    /// approximating here would move a hit, and a moved hit in the backing is measurement error
    /// attributed to the player.
    public func rescaled(toStepsPerBeat target: Int) -> Pattern {
        guard target != stepsPerBeat else { return self }
        precondition(target % stepsPerBeat == 0,
                     "\(target) steps per beat is not a whole multiple of \(stepsPerBeat)")
        let factor = target / stepsPerBeat
        return Pattern(stepsPerBar: stepsPerBar * factor, stepsPerBeat: target,
                       hits: hits.map {
                           Hit(voice: $0.voice, step: $0.step * factor,
                               velocity: $0.velocity, note: $0.note)
                       })
    }
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

    /// This section with its pattern and fill lifted to a common grid.
    func rescaled(toStepsPerBeat target: Int) -> Section {
        Section(name: name, pattern: pattern.rescaled(toStepsPerBeat: target), bars: bars,
                fill: fill?.rescaled(toStepsPerBeat: target))
    }
}

/// An ordered set of sections. Resolves an absolute bar index to the pattern that plays.
public struct Arrangement: Equatable {
    public let sections: [Section]
    public let loop: Bool

    public init(sections: [Section], loop: Bool = true) {
        precondition(!sections.isEmpty, "an arrangement needs at least one section")
        // Sections used to have to *share* a resolution, which meant a triplet section and a
        // straight one could never appear in the same arrangement — the format's hard limit on
        // musical depth. They are now lifted to `Pattern.commonStepsPerBeat` instead, which is a
        // whole multiple of every resolution anything here is authored at, so the lift is exact
        // and the hit times do not move.
        let lifted = sections.map { $0.rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat) }

        // Bars must still be the same *length*. A section in 3/4 beside one in 4/4 would make
        // the bar index the sequencer walks mean two different things, and every drill counts
        // phrases in bars.
        let beats = lifted[0].pattern.beatsPerBar
        for section in lifted {
            precondition(section.pattern.beatsPerBar == beats,
                         "all sections in an arrangement must have the same beats per bar")
        }
        self.sections = lifted
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
