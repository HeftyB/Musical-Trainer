import Foundation

/// How much the music tells you where you are in the form.
///
/// The ladder runs react → anticipate → generate: first the turn is confirmed as it happens,
/// then you must commit to it unaided, then you must produce the period with no help at all.
public enum FormLevel: Int, CaseIterable, Comparable {
    case fillAndAccent = 0      // fill before the turn, crash on the downbeat
    case fillOnly = 1           // fill warns you; nothing confirms the arrival
    case noFills = 2            // steady groove, no signposts at all
    case dropoutAcross = 3      // silence *across* the phrase boundary

    public static func < (lhs: FormLevel, rhs: FormLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// True when a crash lands exactly on the downbeat being marked, which means a mark can
    /// be a reaction rather than an anticipation — the phase error will say which.
    public var hasArrivalAccent: Bool { self == .fillAndAccent }

    public var label: String {
        switch self {
        case .fillAndAccent: return "fill before the turn + crash on the downbeat"
        case .fillOnly:      return "fill before the turn, no crash"
        case .noFills:       return "no fills — steady groove"
        case .dropoutAcross: return "silence across the phrase boundary"
        }
    }

    public var advice: String {
        switch self {
        case .fillAndAccent:
            return "The fill says the turn is coming; the crash lands on it. Aim to arrive WITH the crash, not after it."
        case .fillOnly:
            return "The fill still warns you, but nothing confirms the arrival. You have to commit."
        case .noFills:
            return "No signposts at all. This is your own clock now."
        case .dropoutAcross:
            return "The band leaves before the turn and returns after it. Feel the corner in silence."
        }
    }
}

public enum FormBacking {
    /// The pattern for one bar of the form drill.
    ///
    /// The invariant that matters: **nothing louder than the groove may land anywhere except
    /// the downbeat being marked.** An earlier version put a crash at the start of the fill
    /// bar, one bar before the target, and players marked the crash — the drill measured
    /// reaction to a misleading cue instead of form sense.
    public static func pattern(bar: Int, phraseBars: Int, level: FormLevel,
                               groove: Pattern) -> Pattern {
        precondition(phraseBars >= 2, "a phrase needs at least two bars")
        let positionInPhrase = ((bar % phraseBars) + phraseBars) % phraseBars
        let isLastBarOfPhrase = positionInPhrase == phraseBars - 1

        switch level {
        case .fillAndAccent:
            if isLastBarOfPhrase { return GrooveLibrary.snareFill }
            // Including bar 0, so the drill opens by demonstrating what a phrase top sounds like.
            if positionInPhrase == 0 { return GrooveLibrary.accented(groove) }
            return groove
        case .fillOnly:
            return isLastBarOfPhrase ? GrooveLibrary.snareFill : groove
        case .noFills:
            return groove
        case .dropoutAcross:
            // Silent for the last two bars of a phrase and the first two of the next, so the
            // turn happens with no band at all. Nothing marks the corner but your own sense
            // of it — which is exactly the skill being trained.
            let nearBoundary = positionInPhrase >= phraseBars - 2 || positionInPhrase < 2
            return nearBoundary ? .silence : groove
        }
    }
}
