import Foundation

/// The continuation drill: the band plays, drops out entirely, and comes back.
///
/// This is the only exercise that can produce a Wing–Kristofferson clock/motor split
/// (PLAN.md §5.2), because that decomposition needs an *unpaced* sequence — the player
/// generating the pulse with no external reference. Everything else in the app measures
/// synchronisation to something; this measures the pulse itself.
public enum DropoutDrill {

    public struct Cycle: Equatable {
        public let pacedBars: Int
        public let silentBars: Int
        public init(pacedBars: Int, silentBars: Int) {
            precondition(pacedBars >= 1 && silentBars >= 1, "each phase needs at least one bar")
            self.pacedBars = pacedBars
            self.silentBars = silentBars
        }
        public var totalBars: Int { pacedBars + silentBars }
    }

    /// Whether the band is playing in a given bar.
    public static func isPaced(bar: Int, cycle: Cycle) -> Bool {
        let position = ((bar % cycle.totalBars) + cycle.totalBars) % cycle.totalBars
        return position < cycle.pacedBars
    }

    /// The pattern for one bar.
    ///
    /// The band returns with a crash on the downbeat — the "slam back" of PLAN.md §6. It is
    /// a musical event rather than a test bell, and it makes a bad re-entry audible to the
    /// player at the instant it happens, which is the entire point of the drill.
    public static func pattern(bar: Int, cycle: Cycle, groove: Pattern) -> Pattern {
        guard isPaced(bar: bar, cycle: cycle) else { return .silence }
        let position = ((bar % cycle.totalBars) + cycle.totalBars) % cycle.totalBars
        // First bar of a paced stretch, and not the very start of the drill.
        if position == 0 && bar >= cycle.totalBars { return GrooveLibrary.accented(groove) }
        return groove
    }

    /// Suggest the next difficulty from measured drift across the silence.
    ///
    /// Adaptation is deliberately *between* sessions, not within one: changing the silence
    /// length mid-take would give trials of different lengths, and pooling those weakens the
    /// very variance estimate the drill exists to produce.
    ///
    /// - Parameter driftMsPerBeat: mean drift measured during the silences.
    public static func suggestedSilentBars(current: Int, driftMsPerBeat: Double?) -> Int {
        guard let drift = driftMsPerBeat else { return current }
        let magnitude = abs(drift)
        if magnitude < 1.5 { return min(16, current * 2) }   // comfortable — go longer
        if magnitude > 5 { return max(2, current / 2) }      // losing it — go shorter
        return current
    }
}
