import Foundation

/// How much of the downbeat the band still states.
///
/// Ska and reggae put the emphasis where the grid says nothing is, and the skill is holding a
/// position you never articulate. Every other drill here anchors on the downbeat; this one takes
/// the anchor away a step at a time, which is the same ladder shape as `DropoutLevel` turned
/// through ninety degrees — that one removes the *band*, this one removes the *downbeat*.
public enum OffbeatLevel: Int, CaseIterable, Comparable {
    /// Kick on 1 and 3, backbeat on 2 and 4. The downbeat is stated plainly.
    case stated = 0
    /// Kick on 1 only. Enough to re-anchor once a bar and no more.
    case barOnly
    /// No kick at all — the backbeat on 2 and 4 is the only thing on a beat.
    case backbeatOnly
    /// Nothing on any beat. The downbeat exists only in the player's head, and the chop is the
    /// only sound in the bar.
    case implied

    public static func < (a: OffbeatLevel, b: OffbeatLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .stated:       return "kick on 1 and 3"
        case .barOnly:      return "kick on 1 only"
        case .backbeatOnly: return "backbeat only"
        case .implied:      return "nothing on the beat"
        }
    }

    /// What the player is up against, in their own terms.
    public var advice: String {
        switch self {
        case .stated:
            return "The kick states the downbeat every other beat. Lock the chop against it."
        case .barOnly:
            return "One kick a bar. Enough to check yourself against, not enough to lean on."
        case .backbeatOnly:
            return "Only the backbeat is on a beat. The downbeat is yours to hold."
        case .implied:
            return "Nothing lands on a beat at all. The only risk left is hearing your own chop "
                 + "as the downbeat — and once that flips, it stays flipped."
        }
    }
}

/// The skank: a chop on every offbeat, and progressively less underneath it.
public enum OffbeatBacking {

    /// Sixteen steps to the bar, four to the beat — so offbeats are steps 2, 6, 10, 14.
    private static let stepsPerBeat = 4
    private static let stepsPerBar = 16

    /// One bar at a level.
    ///
    /// - Parameter bar: absolute bar index, so the re-anchor at the top of a phrase can be
    ///   placed without the caller tracking it.
    /// - Parameter phraseBars: how often the hardest level is allowed a bar-start marker.
    public static func pattern(level: OffbeatLevel, bar: Int, phraseBars: Int = 4) -> Pattern {
        let offbeats = [2, 6, 10, 14]
        var hits = offbeats.map { Hit(voice: .rimshot, step: $0, velocity: 108) }

        switch level {
        case .stated:
            hits += [Hit(voice: .kick, step: 0, velocity: 100),
                     Hit(voice: .kick, step: 8, velocity: 100),
                     Hit(voice: .snare, step: 4, velocity: 100),
                     Hit(voice: .snare, step: 12, velocity: 100)]
        case .barOnly:
            hits += [Hit(voice: .kick, step: 0, velocity: 100),
                     Hit(voice: .snare, step: 4, velocity: 100),
                     Hit(voice: .snare, step: 12, velocity: 100)]
        case .backbeatOnly:
            hits += [Hit(voice: .snare, step: 4, velocity: 100),
                     Hit(voice: .snare, step: 12, velocity: 100)]
        case .implied:
            // A marker at the top of each phrase, and nowhere else.
            //
            // Not a concession. With *nothing* on a beat the player can hear their own chop as
            // the downbeat, and once that flips it stays flipped — every note afterwards is
            // scored against the wrong points and the take measures a phase error that happened
            // in the first bar. A periodic anchor bounds that to one phrase, and it is what a
            // real band does anyway.
            if phraseBars > 0, bar % phraseBars == 0 {
                hits.append(Hit(voice: .kick, step: 0, velocity: 100))
            }
        }
        return Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: stepsPerBeat, hits: hits)
    }

    /// The whole drill as an arrangement, one level throughout.
    public static func backing(level: OffbeatLevel, bars: Int, phraseBars: Int = 4) -> Arrangement {
        let sections = (0..<max(1, bars)).map { bar in
            Section(name: "b\(bar)", pattern: pattern(level: level, bar: bar,
                                                      phraseBars: phraseBars), bars: 1)
        }
        return Arrangement(sections: sections, loop: true)
    }
}
