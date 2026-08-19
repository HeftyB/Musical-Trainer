import Foundation

/// A voice **the band** plays, as opposed to `LiveInstrument`, which is the player's own sound.
///
/// Kept as plain identifiers here — `GrooveCore` is pure sequencing logic and knows nothing about
/// how a voice sounds. Named for the band rather than for the kit because M19 gives the band a
/// bass, and harmony after it: an enum called `DrumVoice` with a `bass` case in it would be
/// `LESSONS.md` shape 10 arriving by choice rather than by accident.
public enum BackingVoice: String, CaseIterable, Codable, Equatable {
    case kick, snare, closedHat, openHat, clap, rimshot, tom, crash, ride
    // Hand percussion and the quieter articulations. Added in M19 because a kit of nine voices
    // could build a groove and could not build an *identity*: every style came out sounding
    // like the same electronic kit playing different steps (§7.29 step 6).
    case tambourine, shaker, cowbell, sidestick
    /// The one pitched voice. A hit on it carries a `note`; every other voice ignores one.
    ///
    /// Drums alone cannot make something worth playing over for half an hour — a figure that
    /// locks with the kick is what gives a groove a contour to remember, and a second thing to
    /// place your own playing against (§7.29 step 2).
    case bass
    /// The skank family's own voice, and the second pitched one.
    ///
    /// Added for M16.5: the organ bubble was being auditioned on a rimshot, and a player asked to
    /// imagine past the timbre is not judging the figure (§7.55). It carries a `note` like the
    /// bass, and unlike the bass it plays *above* the player rather than under them.
    case organ

    /// Voices that can carry the pulse — the thing a listener counts along to.
    ///
    /// **At most one of these keeps time at once.** Two is not a fuller sound, it is two
    /// drummers: a ride and a hat playing the same rhythm reads as a bell ringing over a hat
    /// rather than as either, which is what the first `motown` and `half-time` did and what an
    /// ear caught immediately. `Style` refuses it.
    public static let timekeepers: Set<BackingVoice> = [.closedHat, .ride, .tambourine, .shaker]

    /// Whether a hit on this voice needs a `note` to mean anything.
    ///
    /// The discriminator lives here rather than as `== .bass` at each call site, so harmony
    /// adding pitched voices later is one case rather than a hunt.
    public var isPitched: Bool { self == .bass || self == .organ }

    /// Voices that are **one physical instrument in different states**, listed so that the
    /// earlier one wins when both land on a step.
    ///
    /// A hi-hat cannot be open and closed at the same instant. The open hat on the "and" of four
    /// *replaces* the closed one — the foot lifts, the stick hits — and layering the two instead
    /// stacks a 45 ms "tss" onto a 1.2-second wash, which is not a louder hat, it is two hats.
    /// `driving` did it on step 14 from intensity 2 and `syncopated` on steps 6 and 14 at
    /// intensity 3 (JOURNAL.md §7.31 finding 2).
    ///
    /// **Distinct from `timekeepers`, which is why `doubledTimekeepers` could not see this.** That
    /// rule is about two *pulses* — a ride and a hat playing one rhythm — and it deliberately
    /// ignores a voice with fewer than three hits a bar so an occasional colour is not forbidden.
    /// An open hat is exactly that occasional colour, and it is still a physical impossibility.
    /// One rule is about doubling a pulse, the other about doubling an instrument.
    ///
    /// **Resolved rather than forbidden**, and the distinction matters: "eighths on the hat, and
    /// this one is open" is the natural way to write the figure, and the alternative is punching a
    /// hole in the hat layer that would have to open and close with the intensity — which the
    /// layer format cannot express, since the open hat enters at a higher intensity than the hat
    /// line it would displace.
    ///
    /// The snare drum is the obvious next group — `snare`, `sidestick` and `rimshot` are one drum
    /// struck three ways — and it is deliberately **not** here yet, because which articulation
    /// wins is a musical decision nobody has had to make: no authored style plays two of them on
    /// one step. Adding it is a row in this table, not a change to anything that reads it.
    public static let articulationGroups: [[BackingVoice]] = [[.openHat, .closedHat]]

    /// Which group this voice belongs to and how it ranks inside it — lower wins.
    /// `nil` for a voice that is its own instrument, which is most of them.
    static func articulation(of voice: BackingVoice) -> (group: Int, rank: Int)? {
        for (group, voices) in articulationGroups.enumerated() {
            if let rank = voices.firstIndex(of: voice) { return (group, rank) }
        }
        return nil
    }

    /// The same hits with each instrument reduced to one articulation per step.
    ///
    /// Order-preserving: it only ever removes, so a sorted input stays sorted — which
    /// `Style.pattern` depends on, because merged hit order decides float summation order in the
    /// mix and an unsorted merge renders to different bytes run to run (§7.29 step 2).
    static func resolvingArticulations(_ hits: [Hit]) -> [Hit] {
        // Nothing to do for the overwhelmingly common case, and it keeps the allocation off a
        // path every bar of every style goes through.
        guard hits.contains(where: { articulation(of: $0.voice) != nil }) else { return hits }

        var best: [String: Int] = [:]          // "step:group" → winning rank
        for hit in hits {
            guard let (group, rank) = articulation(of: hit.voice) else { continue }
            let key = "\(hit.step):\(group)"
            best[key] = min(best[key] ?? rank, rank)
        }
        return hits.filter { hit in
            guard let (group, rank) = articulation(of: hit.voice) else { return true }
            return best["\(hit.step):\(group)"] == rank
        }
    }
}

/// One hit at a step within a bar.
public struct Hit: Equatable {
    public let voice: BackingVoice
    /// Step index within the bar, 0-based.
    public let step: Int
    /// MIDI-style velocity, 1–127.
    public let velocity: Int
    /// MIDI note number for a pitched voice; `nil` for a drum, which has one sound.
    ///
    /// **Per hit rather than per pattern, and that is the framework harmony needs.** M19's bass
    /// is rhythmic only — root and fifth — because key, progression and voice leading are a
    /// different problem from rhythm and get their own milestone (M25). What that milestone must
    /// not have to do is change the shape of a hit: a chord is several hits at one step with
    /// different notes, and this already expresses it.
    public let note: Int?

    public init(voice: BackingVoice, step: Int, velocity: Int = 100, note: Int? = nil) {
        self.voice = voice
        self.step = step
        self.velocity = velocity
        self.note = note
    }
}
