import Foundation

/// Which experiment a take belongs to, and which arm it was assigned.
///
/// Optional on every take type, so every take recorded before M13 still decodes and a take
/// played outside an experiment carries nothing.
///
/// **Stored before anything reads it**, which is the third time this project has done that and
/// the third time for the same reason (R6.3). `SessionPlacement` was stored before M10 could use
/// it; pitch was stored before M12 existed. A take recorded without its arm is a take the
/// comparison can never use, and no amount of later analysis recovers it — the question has to
/// be answerable about the takes already on disk, not only about the ones played after the
/// analysis is written.
///
/// What it deliberately does not carry is the experiment's *design* — its arms, its target n,
/// its stopping rule. Those belong to the experiment, not to each take, and duplicating them
/// into every file would let two takes disagree about what experiment they were part of.
public struct ExperimentAssignment: Codable, Equatable {
    /// Identifies the run, so two experiments that share a name stay separable.
    public let experimentId: UUID
    /// Stable, human-readable: `steady-vs-melodic`, `relaxed-vs-focused`.
    public let name: String
    /// The arm this take was played under, as its raw string.
    ///
    /// A string rather than an enum for the same reason `SessionPlacement.role` is: adding an
    /// arm to an experiment must never make an already-recorded take undecodable.
    public let arm: String
    /// 0-based position of this take within the experiment, in the order they were run.
    ///
    /// Needed to check that the arms were actually counterbalanced rather than merely intended
    /// to be — §7.17 has two takes identical on every number rated 4 and 1 twenty minutes apart,
    /// so an arm that drifts toward one end of a sitting measures fatigue.
    public let runIndex: Int

    public init(experimentId: UUID, name: String, arm: String, runIndex: Int) {
        self.experimentId = experimentId
        self.name = name
        self.arm = arm
        self.runIndex = runIndex
    }
}
