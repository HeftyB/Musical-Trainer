import Foundation

/// How much room a style leaves for whoever is playing over it.
///
/// A judgement made once by the person who wrote the style, because it is the sort of thing that
/// is obvious by ear and invisible in a step list. M21's guitar and M24's voice both need it: a
/// busy backing under an open microphone is unusable, and a vocal drill has to be able to ask for
/// something that leaves the middle clear.
public enum Density: String, CaseIterable, Codable, Equatable {
    /// Beat and backbeat, little else. Room for anything.
    case sparse
    /// A full kit at conversational volume.
    case medium
    /// Sixteenths, ghost notes, a moving bass. Fun to play over, hard to hear a voice through.
    case busy
}

/// One layer of a style: a repeating figure that enters once the music is loud enough for it.
///
/// **Intensity adds and removes layers; it never moves a hit.** That is the whole discipline of
/// M19's variation (§7.29): the backing is the ruler the player is measured against, so what
/// changes between a quiet bar and a loud one is which voices are sounding and how hard, never
/// when they sound. There is no jitter parameter here and there must never be one.
public struct Layer: Equatable {
    /// The figure, one entry per bar, cycling. A one-bar hat and a two-bar bass sit in the same
    /// style and simply repeat at their own lengths.
    public let bars: [Pattern]
    /// The lowest intensity at which this layer plays. A layer at 0 is the style's skeleton.
    public let entersAt: Int

    public init(bars: [Pattern], entersAt: Int = 0) {
        precondition(!bars.isEmpty, "a layer needs at least one bar")
        precondition(entersAt >= 0, "intensity starts at zero")
        self.bars = bars
        self.entersAt = entersAt
    }

    public init(_ pattern: Pattern, entersAt: Int = 0) {
        self.init(bars: [pattern], entersAt: entersAt)
    }
}

/// A style of music the band can play, authored once and played at any intensity.
///
/// Authoring a style is bounded work; the music it can produce is not. §7.29's answer to "lack of
/// depth must never become an issue again" is that a style is a small set of layers plus a fill
/// vocabulary, and everything else — how long a section runs, which fill lands, how the intensity
/// moves — is chosen by the generator in step 4 from a seed that is stored on the take.
public struct Style: Equatable {
    /// Stable, lower-case, and stored: `grooveName` becomes `style@seed`, so it has to survive
    /// being written to a take and read back years later.
    public let name: String
    public let layers: [Layer]
    /// Played instead of the last bar of a phrase. More than one so a turnaround does not become
    /// the metronome the form drill spends its levels removing.
    public let fills: [Pattern]
    /// Voices the player would take if they sat in with this band.
    ///
    /// **M20's hook, and it costs a field now against rewriting every style later.** Drum mode
    /// inverts the roles: the player becomes the drummer and the backing becomes the click, which
    /// means muting exactly these voices and letting them supply them. Deciding it while the
    /// style is being written is easy; inferring it afterwards is guesswork.
    public let playerVoices: Set<BackingVoice>
    public let density: Density

    /// Whether the player has listened to this style and said yes.
    ///
    /// **A flag rather than a promise in a document.** §7.23's rule — do not promote a player
    /// onto something nobody has heard — has been prose since M14, and prose is what a hurried
    /// afternoon ignores. The planner schedules only styles that carry this, so a groove that
    /// has never been through a pair of headphones cannot reach a take by anybody's oversight.
    ///
    /// It is `false` for a newly authored style and stays false until the person who has to play
    /// over it changes it. Nobody who wrote the style can set it honestly: whether a groove is
    /// worth thirty minutes is not a property of its step list.
    public let auditioned: Bool

    /// Intensity runs 0–3 like every other ladder here, so `SessionPlanner` and M17's adaptive
    /// difficulty have one scale to reason about rather than one per drill.
    public static let intensityRange = 0...3

    public init(name: String, layers: [Layer], fills: [Pattern],
                playerVoices: Set<BackingVoice>, density: Density,
                auditioned: Bool = false) {
        precondition(!layers.isEmpty, "a style needs at least one layer")
        precondition(layers.contains { $0.entersAt == 0 },
                     "a style needs a skeleton — something that plays at intensity 0")
        self.name = name
        self.layers = layers
        self.fills = fills
        self.playerVoices = playerVoices
        self.density = density
        self.auditioned = auditioned
    }

    /// Whether the band carries its own bass. Derived rather than declared, so it cannot drift
    /// away from what the layers actually contain.
    public var carriesBass: Bool {
        layers.contains { $0.bars.contains { $0.hits.contains { $0.voice == .bass } } }
    }

    /// The bar this style plays at a given position and intensity.
    ///
    /// Deterministic and total: same arguments, same bar, for ever (R1.2.2). Choosing *which*
    /// bars are fills and how the intensity moves belongs to the generator, not here — this is
    /// the instrument, not the performance.
    public func pattern(atBar bar: Int, intensity: Int) -> Pattern {
        let active = layers.filter { $0.entersAt <= intensity }
        guard !active.isEmpty else { return .silence }

        let lifted = active.map { layer -> Pattern in
            let inLayer = ((bar % layer.bars.count) + layer.bars.count) % layer.bars.count
            return layer.bars[inLayer].rescaled(toStepsPerBeat: Pattern.commonStepsPerBeat)
        }
        // Sorted, because merged hit order decides float summation order in the mix and an
        // unsorted merge would render to different bytes run to run — the defect §7.29 step 2
        // found in `Pattern.make`.
        let hits = lifted.flatMap(\.hits)
            .sorted { ($0.step, $0.voice.rawValue) < ($1.step, $1.voice.rawValue) }
        return Pattern(stepsPerBar: lifted[0].stepsPerBar,
                       stepsPerBeat: lifted[0].stepsPerBeat, hits: hits)
    }
}

public extension Style {
    /// Eight bars of this style at one intensity, with a fill on the last, for auditioning.
    ///
    /// Deliberately not how the generator will build a section — it picks lengths, fills and an
    /// intensity arc from its seed (step 4). This is a fixed window so two listens compare.
    func auditionArrangement(intensity: Int, bars: Int = 8) -> Arrangement {
        Arrangement(sections: (0..<bars).map { bar in
            Section(name: "\(name) \(intensity) bar \(bar)",
                    pattern: pattern(atBar: bar, intensity: intensity), bars: 1,
                    fill: bar == bars - 1 ? fills.first : nil)
        }, loop: true)
    }
}
