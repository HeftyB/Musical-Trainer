import Foundation

/// The drum voices the synth can produce. Kept as plain identifiers here — GrooveCore is
/// pure sequencing logic and knows nothing about how a voice sounds.
public enum DrumVoice: String, CaseIterable, Codable, Equatable {
    case kick, snare, closedHat, openHat, clap, rimshot, tom, crash, ride
}

/// One drum hit at a step within a bar.
public struct Hit: Equatable {
    public let voice: DrumVoice
    /// Step index within the bar, 0-based.
    public let step: Int
    /// MIDI-style velocity, 1–127.
    public let velocity: Int

    public init(voice: DrumVoice, step: Int, velocity: Int = 100) {
        self.voice = voice
        self.step = step
        self.velocity = velocity
    }
}
