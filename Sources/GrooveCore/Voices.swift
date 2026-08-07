import Foundation

/// A voice **the band** plays, as opposed to `LiveInstrument`, which is the player's own sound.
///
/// Kept as plain identifiers here — `GrooveCore` is pure sequencing logic and knows nothing about
/// how a voice sounds. Named for the band rather than for the kit because M19 gives the band a
/// bass, and harmony after it: an enum called `DrumVoice` with a `bass` case in it would be
/// `LESSONS.md` shape 10 arriving by choice rather than by accident.
public enum BackingVoice: String, CaseIterable, Codable, Equatable {
    case kick, snare, closedHat, openHat, clap, rimshot, tom, crash, ride
    /// The one pitched voice. A hit on it carries a `note`; every other voice ignores one.
    ///
    /// Drums alone cannot make something worth playing over for half an hour — a figure that
    /// locks with the kick is what gives a groove a contour to remember, and a second thing to
    /// place your own playing against (§7.29 step 2).
    case bass

    /// Whether a hit on this voice needs a `note` to mean anything.
    ///
    /// The discriminator lives here rather than as `== .bass` at each call site, so harmony
    /// adding pitched voices later is one case rather than a hunt.
    public var isPitched: Bool { self == .bass }
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
