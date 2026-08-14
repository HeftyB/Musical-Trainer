import Foundation

/// Which subdivision the organ bubble's pair of notes sits on.
///
/// **The musical premise M16.5 rests on, and it is not settled.** PLAN.md §7.13 assumed the bubble
/// rests on the beat and plays the second and third of each beat's triplet. That is one of two
/// characterisations a working player would recognise, and the measurement follows entirely from
/// which one is right — so both are built, rendered, and decided by ear before anything is scored
/// against either (PLAN.md §7.55).
///
/// What they have in common is the part that makes this the skank family: **nothing on the beat,
/// two notes after it.** What differs is the grid those two notes land on, and that is audible in
/// a way an argument is not.
public enum BubbleFeel: String, CaseIterable {
    /// The 2nd and 3rd of each beat's triplet. Steps 1 and 2 of 3.
    case triplet
    /// The "and" and the "a" — the 3rd and 4th sixteenth of each beat. Steps 2 and 3 of 4.
    case sixteenth

    /// Steps per beat this feel is authored at. `Arrangement` lifts both to the common grid, so a
    /// triplet figure and a straight one can sit in one piece of music (§7.29 step 1).
    public var stepsPerBeat: Int {
        switch self {
        case .triplet:   return 3
        case .sixteenth: return 4
        }
    }

    /// Which steps within a beat the bubble plays. **Never step 0** — resting on the beat is what
    /// makes this a skank rather than a groove.
    public var playedSteps: [Int] {
        switch self {
        case .triplet:   return [1, 2]
        case .sixteenth: return [2, 3]
        }
    }

    public var label: String {
        switch self {
        case .triplet:   return "triplet — the 2nd and 3rd of each beat"
        case .sixteenth: return "sixteenth — the \"and\" and the \"a\""
        }
    }

    /// How close the **nearest** note of the figure comes to a beat, as a fraction of one.
    ///
    /// §7.38's argument generalised, and the generalisation is the whole point: a note has to land
    /// at a point whose neighbours nobody is playing, and the difficulty is set by the *tightest*
    /// such point rather than by the first one. Measured to the nearest beat in either direction —
    /// the last note of a bubble is close to the beat that follows it, not the one it came from.
    ///
    /// | | closest approach |
    /// |---|---|
    /// | Straight skank — the "and" | **1/2** beat |
    /// | Triplet bubble | **1/3** beat |
    /// | Sixteenth bubble | **1/4** beat |
    ///
    /// So the two candidates are not two spellings of one figure. They sit at different distances
    /// from the thing that must not be hit, and by §7.38 that makes them different tasks at the
    /// same tempo.
    public var closestApproachFraction: Double {
        playedSteps.map { step -> Double in
            let position = Double(step) / Double(stepsPerBeat)
            return min(position, 1 - position)
        }.min() ?? 0.5
    }

    /// Milliseconds from the nearest beat to the tightest note of the figure, at a given tempo.
    ///
    /// The quantity §7.38 identified as what actually changes with tempo in this family, so the
    /// offbeat drill's 70 BPM default does not transfer to either candidate by itself — it was
    /// settled on a take at 69 BPM against one at 100, for a figure whose closest approach is half
    /// a beat.
    public func closestApproachMs(atBpm bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return 60_000 / bpm * closestApproachFraction
    }

    /// **Whether this figure contains the straight skank's chop.**
    ///
    /// The sixteenth bubble does: its first note is the "and", exactly where the chop sits, and the
    /// "a" is added after it. The triplet bubble does not — both of its notes are positions this
    /// player has never been asked to hold.
    ///
    /// That is the difference that decides what M16.5 measures. One candidate extends a skill with
    /// five takes and a 100% hold behind it; the other asks for a position the corpus has nothing
    /// on (PLAN.md §7.55).
    public var containsTheStraightChop: Bool {
        playedSteps.contains { Double($0) / Double(stepsPerBeat) == 0.5 }
    }
}

/// The organ bubble: two notes after each beat, and progressively less underneath them.
///
/// Deliberately built on `OffbeatLevel` rather than a ladder of its own. The straight skank and the
/// bubble differ in *what the player plays*, not in what the band takes away — and §7.13's argument
/// for the whole family is that "hold a position the band never plays" generalises. A second,
/// parallel ladder would be two names for one idea, which is `LESSONS.md` shape 10 waiting to
/// happen.
public enum BubbleBacking {

    /// One bar of the bubble at a level.
    ///
    /// - Parameter bar: absolute bar index, so the phrase-top re-anchor at the hardest level can
    ///   be placed without the caller tracking it.
    /// The notes a bubble stab sounds — **root and fifth, no third**.
    ///
    /// The same restraint the bass is built under (§7.29 step 2): a third commits the band to a
    /// key quality, and keys and progressions belong to M25. Whether a bubble needs one to read as
    /// a bubble at all is an open question for an ear, not an argument (§7.56).
    public static let voicing = [64, 71]      // E4, B4

    public static func pattern(feel: BubbleFeel, level: OffbeatLevel, bar: Int,
                               phraseBars: Int = 4) -> Pattern {
        let perBeat = feel.stepsPerBeat
        let stepsPerBar = perBeat * 4

        // The band plays the figure the player is being asked for, exactly as the straight skank
        // states its chop. What the ladder removes is the *downbeat*, never the bubble.
        //
        // **On the organ**, which is the point of §7.56: the first audition of these two figures
        // ran on a rimshot and came back "I was trying to imagine it with an organ sound to
        // identify the bubble". A figure judged through a stand-in timbre is a figure judged with
        // a caveat attached.
        var hits: [Hit] = (0..<4).flatMap { beat -> [Hit] in
            feel.playedSteps.flatMap { step -> [Hit] in
                // The second of the pair leans, which is what stops two identical hits reading as
                // a machine — the same rule the styles are held to: no layer at one velocity.
                let velocity = step == feel.playedSteps[0] ? 104 : 112
                return voicing.map { note in
                    Hit(voice: .organ, step: beat * perBeat + step, velocity: velocity, note: note)
                }
            }
        }

        // The downbeat ladder, in the same terms as the straight skank so the two are comparable
        // at a given level. Beats land on multiples of `perBeat`, which is the only thing that
        // changes between the two feels.
        let beat: (Int) -> Int = { $0 * perBeat }
        switch level {
        case .stated:
            hits += [Hit(voice: .kick, step: beat(0), velocity: 100),
                     Hit(voice: .kick, step: beat(2), velocity: 100),
                     Hit(voice: .snare, step: beat(1), velocity: 100),
                     Hit(voice: .snare, step: beat(3), velocity: 100)]
        case .barOnly:
            hits += [Hit(voice: .kick, step: beat(0), velocity: 100),
                     Hit(voice: .snare, step: beat(1), velocity: 100),
                     Hit(voice: .snare, step: beat(3), velocity: 100)]
        case .backbeatOnly:
            hits += [Hit(voice: .snare, step: beat(1), velocity: 100),
                     Hit(voice: .snare, step: beat(3), velocity: 100)]
        case .implied:
            // See `OffbeatBacking`: with nothing on a beat the player can hear their own figure as
            // the downbeat, and once that flips every later note is scored against the wrong
            // points. A marker once a phrase bounds that to one phrase.
            if phraseBars > 0, bar % phraseBars == 0 {
                hits.append(Hit(voice: .kick, step: beat(0), velocity: 100))
            }
        }
        return Pattern(stepsPerBar: stepsPerBar, stepsPerBeat: perBeat, hits: hits)
    }

    public static func backing(feel: BubbleFeel, level: OffbeatLevel, bars: Int,
                               phraseBars: Int = 4) -> Arrangement {
        let sections = (0..<max(1, bars)).map { bar in
            Section(name: "b\(bar)",
                    pattern: pattern(feel: feel, level: level, bar: bar, phraseBars: phraseBars),
                    bars: 1)
        }
        return Arrangement(sections: sections, loop: true)
    }
}
