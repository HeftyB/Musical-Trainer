import Foundation

/// The tempo-memory drill: hear a tempo, wait, reproduce it.
///
/// The continuation drill (`DropoutDrill`) asks whether a pulse *survives* while you keep
/// producing it. This asks something different and harder: whether the period is **stored**
/// at all, or only maintained by keeping it running. The player stops playing entirely
/// through the retention interval, then starts again from nothing.
///
/// That distinction is the point for this player. "If my brain is out of the picture the flow
/// is easy" (PLAN.md §1) predicts a specific result: a period held by active attention should
/// survive silence and collapse when something else fills the gap, because the distractor
/// competes for exactly the resource doing the holding. A period that is genuinely stored
/// should not care. Alternating silent and filled retention intervals is what separates them.
public enum TempoMemoryDrill {

    public struct Round: Equatable {
        /// The click plays and the player plays along, entraining.
        public let referenceBars: Int
        /// Nothing is played by the player. Either silence or an aperiodic distractor.
        public let retentionBars: Int
        /// A single cue marks the start; the player produces the tempo alone.
        public let reproduceBars: Int

        public init(referenceBars: Int = 4, retentionBars: Int = 4, reproduceBars: Int = 4) {
            precondition(referenceBars >= 1 && retentionBars >= 1 && reproduceBars >= 1,
                         "each phase needs at least one bar")
            self.referenceBars = referenceBars
            self.retentionBars = retentionBars
            self.reproduceBars = reproduceBars
        }

        public var totalBars: Int { referenceBars + retentionBars + reproduceBars }
    }

    /// Whether the retention interval is filled with a distractor.
    ///
    /// Alternates, starting silent. Silent is the control and the easier case, so the first
    /// round of a session is never the hard one — and alternating keeps the two conditions
    /// balanced across the session rather than confounded with fatigue. Proper counterbalancing
    /// is M12's job; this is enough to make the contrast interpretable.
    public static func isFilled(round: Int) -> Bool { round % 2 == 1 }

    /// The last bar of the reference section, which carries a fill warning the silence is
    /// coming.
    ///
    /// Without it the groove simply stops and the player is caught out — reported after the
    /// first live run of the drill. A fill is the idiomatic way to say "something changes
    /// next", and it costs nothing analytically: it lands while the groove is still playing,
    /// so the tempo it carries is tempo the player already has. Nothing is given away.
    ///
    /// It also makes the round's shape learnable. With the fill always in the same place and
    /// the retention length fixed for a session, the player can start anticipating the
    /// re-entry rather than waiting to be told — which is the point of the drill.
    public static func isWarningBar(bar: Int, referenceBars: Int) -> Bool {
        referenceBars > 1 && bar == referenceBars - 1
    }

    /// What plays in a given bar of the reference section.
    ///
    /// The fill **adds to** the groove rather than replacing it, the same invariant the form
    /// drill enforces (PLAN.md §6.1): a fill that leaves a hole where the pulse should be
    /// makes the player re-find the beat, which is the opposite of what is being trained.
    public static func referencePattern(bar: Int, referenceBars: Int, groove: Pattern) -> Pattern {
        guard isWarningBar(bar: bar, referenceBars: referenceBars) else { return groove }
        return groove.adding(GrooveLibrary.snareFill.hits.filter { $0.voice == .snare })
    }
}

// The next retention length is chosen from the measured clock SD, which makes it a question
// about what the numbers mean rather than about what plays — so it lives with the analysis,
// in `TempoMemoryAnalysis.suggestedRetentionBars`. GrooveCore stays free of TimingCore.
