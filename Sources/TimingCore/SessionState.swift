import Foundation

/// How the player said they felt **before** the session started.
///
/// Declared up front, never afterwards, and that ordering is the whole design. Marking a
/// sitting once it has gone badly is post-hoc exclusion — the researcher's degree of freedom
/// this project fights everywhere else, and a short step from dropping the takes you dislike.
/// Declared first it is an ordinary condition, and `review tags` already knows how to pool
/// conditions.
///
/// The five are chosen so they predict **different halves of the clock/motor split** rather
/// than different amounts of "off". If `stiff` shows up as motor noise and `distracted` as
/// clock noise, that is a result about mechanism; if they all just widen spread, that is
/// informative too. A list rather than free text because synonyms never pool — "knackered" and
/// "shattered" and "tired" would be three conditions of one take each.
///
/// It is a subjective, minor data point and is treated as one: reported beside a take, never
/// used to weight, exclude or explain one.
public enum SessionState: String, Codable, Equatable, CaseIterable {
    /// Nothing worth noting. The default, and deliberately not a claim to be well rested —
    /// it is the unmarked case, which is what most evenings are.
    case usual
    /// Short on sleep, or late enough that it amounts to the same thing.
    case tired
    /// Keyed up — caffeine, adrenaline, coming in hot off something else.
    case amped
    /// Present but with attention elsewhere. §5.1's founding prediction lives on this axis.
    case distracted
    /// Cold hands, or days since the last time. Physical rather than attentional.
    case stiff

    public var label: String { rawValue }

    /// One line for the picker, in the player's terms rather than the axis it probes.
    public var blurb: String {
        switch self {
        case .usual:      return "An ordinary evening — nothing worth flagging."
        case .tired:      return "Short on sleep, or up late."
        case .amped:      return "Keyed up, restless, running hot."
        case .distracted: return "Here, but thinking about something else."
        case .stiff:      return "Cold hands, or it has been a few days."
        }
    }
}
