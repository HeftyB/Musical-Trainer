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

/// What an experiment compares, and which way counts as better.
public enum ExperimentMetric: String, Codable, Equatable, CaseIterable {
    /// SD of asynchrony. The skill (§2), and the default for anything jam-shaped.
    case spread
    /// Mean asynchrony. Reported, never scored — bias is not failure.
    case bias
    /// Lag-1 autocorrelation toward zero: the autonomous timekeeper of §5.1.
    case correctionGain
    /// filled − silent, in points, from the recall drill.
    case interferenceCost
    /// Unaccompanied tempo error, in percent.
    case tempoError

    public var label: String {
        switch self {
        case .spread:           return "spread"
        case .bias:             return "bias"
        case .correctionGain:   return "correction gain"
        case .interferenceCost: return "interference cost"
        case .tempoError:       return "tempo error"
        }
    }

    /// Whether a smaller number is an improvement.
    ///
    /// `bias` is deliberately absent from any "better" reading: playing ahead of the beat is
    /// normal and variance is the skill, so an experiment that scored bias down would teach the
    /// wrong lesson (§2). It can be *compared* and reported; it is not a direction.
    public var lowerIsBetter: Bool? {
        switch self {
        case .spread, .interferenceCost, .tempoError: return true
        case .correctionGain:                         return true   // toward zero, |r₁|
        case .bias:                                   return nil
        }
    }
}

/// One experimental question, declared in full **before** any take is played.
///
/// Preregistration is the mechanism here, not a flourish. The app re-runs its analysis after
/// every session, which is textbook optional stopping, and optional stopping plus a bootstrap
/// eventually manufactures a "real change" out of nothing. Fixing the metric, the arms and the
/// target n up front is what makes the eventual comparison mean anything.
public struct ExperimentDesign: Equatable {
    public let id: UUID
    /// Stable, lowercase, hyphenated: `steady-vs-melodic`.
    public let name: String
    /// The question in the player's terms, shown with the plan.
    public let question: String
    /// Two or more distinct arms, in the order they were declared.
    public let arms: [String]
    public let metric: ExperimentMetric
    /// Takes required **in every arm** before any verdict is computed.
    public let takesPerArm: Int

    /// Fails rather than silently repairing a design that cannot answer anything.
    public init?(id: UUID = UUID(), name: String, question: String,
                 arms: [String], metric: ExperimentMetric, takesPerArm: Int) {
        guard arms.count >= 2, Set(arms).count == arms.count, !arms.contains(where: \.isEmpty),
              takesPerArm >= 2, !name.isEmpty else { return nil }
        self.id = id; self.name = name; self.question = question
        self.arms = arms; self.metric = metric; self.takesPerArm = takesPerArm
    }

    /// Takes needed in total before the question can be answered at all.
    public var totalTakesNeeded: Int { arms.count * takesPerArm }
}

/// Where an experiment has got to, and what it is allowed to say.
public struct ExperimentProgress: Equatable {
    public let design: ExperimentDesign
    /// Takes completed per arm, in the design's arm order.
    public let takesPerArm: [Int]
    /// Total takes completed, which is also the next take's `runIndex`.
    public let runIndex: Int
    /// Takes still needed before any verdict may be computed.
    public let takesRemaining: Int
    /// The arm the next take should be played under.
    public let nextArm: String
    /// **The stopping rule.** False until every arm has reached the preregistered target.
    public let hasPower: Bool
    public let headline: String
}

/// Assignment and the stopping rule. The analysis itself is step 3.
public enum ExperimentSchedule {

    /// Which arm the next take belongs to.
    ///
    /// Balanced by construction: the arm with the fewest completed takes wins, so the arms can
    /// never drift more than one take apart. Ties are broken by a seeded draw, which is what
    /// makes it *counterbalanced* rather than merely balanced — with two arms the first take of
    /// an experiment is a coin flip and every later one alternates, so the arm that goes first
    /// is not always the same.
    ///
    /// That matters more here than the balance does. §7.17 records two takes identical on every
    /// number rated 4 and 1 twenty minutes apart, so an arm that always ran first would carry
    /// the whole of the freshness difference and report it as a condition effect.
    public static func nextArm(design: ExperimentDesign, completed: [String]) -> String {
        var counts = [Int](repeating: 0, count: design.arms.count)
        for arm in completed {
            if let index = design.arms.firstIndex(of: arm) { counts[index] += 1 }
        }
        let fewest = counts.min() ?? 0
        let candidates = design.arms.indices.filter { counts[$0] == fewest }

        // Seeded from the design's own id and how many takes have been run, so the choice is
        // reproducible from stored data (R1.2.2) and still differs between experiments.
        //
        // Deliberately *not* `id.hashValue`: Swift seeds its hasher per process, so that would
        // give a different schedule on every launch while looking perfectly deterministic.
        var rng = SplitMix64(seed: seed(for: design.id) &+ UInt64(completed.count))
        let pick = candidates[Int(rng.next() % UInt64(candidates.count))]
        return design.arms[pick]
    }

    /// A stable 64-bit seed from a UUID's bytes.
    private static func seed(for id: UUID) -> UInt64 {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                     b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        return bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3      // FNV-1a
        }
    }

    /// What the experiment may say, given the takes it has.
    ///
    /// **No verdict below the preregistered n**, and `hasPower` is the only gate on that. The
    /// point is not statistical fastidiousness: the app recomputes after every session, so
    /// without a fixed stopping point it is running the comparison dozens of times and keeping
    /// whichever answer it likes. The player is also not shown a running tally, because a score
    /// on screen would bias the takes still to come — in a project whose first principle is
    /// that watching the number changes the playing.
    public static func progress(design: ExperimentDesign,
                                completed: [String]) -> ExperimentProgress {
        var counts = [Int](repeating: 0, count: design.arms.count)
        for arm in completed {
            if let index = design.arms.firstIndex(of: arm) { counts[index] += 1 }
        }
        let shortfall = counts.reduce(0) { $0 + max(0, design.takesPerArm - $1) }
        let hasPower = counts.allSatisfy { $0 >= design.takesPerArm }
        let next = nextArm(design: design, completed: completed)

        let headline: String
        if hasPower {
            headline = "\(design.name): \(completed.count) takes in, "
                     + "\(design.takesPerArm) per arm as planned. Ready to read."
        } else if completed.isEmpty {
            headline = "\(design.name): not started. \(design.totalTakesNeeded) takes needed — "
                     + "\(design.takesPerArm) in each of \(design.arms.count) arms."
        } else {
            headline = "\(design.name): collecting. \(shortfall) take(s) to go, "
                     + "next one \(next). No verdict until every arm has "
                     + "\(design.takesPerArm)."
        }
        return ExperimentProgress(design: design, takesPerArm: counts,
                                  runIndex: completed.count, takesRemaining: shortfall,
                                  nextArm: next, hasPower: hasPower, headline: headline)
    }

    /// The assignment to stamp on the next take.
    public static func assignment(design: ExperimentDesign,
                                  completed: [String]) -> ExperimentAssignment {
        ExperimentAssignment(experimentId: design.id, name: design.name,
                             arm: nextArm(design: design, completed: completed),
                             runIndex: completed.count)
    }
}

/// The experiments this project actually runs.
///
/// Declared here with **fixed ids**, because the schedule is seeded from the id: a fresh UUID
/// each launch would reshuffle the arms of an experiment already half collected.
///
/// One is active at a time. Running two at once would put two instruction-only conditions on the
/// same evening, and the player cannot play a take steady *and* melodic — arms of different
/// experiments would silently become arms of one.
public enum ExperimentLibrary {

    /// §7.19's open question: M12 found busier playing went with looser timing *within* a take,
    /// but the hunch is about the **mode** of a whole take, which within-take correlation cannot
    /// test. Two takes at the locked benchmark settings, differing only in what the player is
    /// asked to play.
    public static let steadyVsMelodic = ExperimentDesign(
        id: UUID(uuidString: "E0000001-0000-4000-8000-000000000001") ?? UUID(),
        name: "steady-vs-melodic",
        question: "Does playing a melody change how tightly you play it?",
        arms: ["steady", "melodic"],
        metric: .spread,
        takesPerArm: 5)

    /// §5.1's founding prediction — that trying to focus drives r₁ sharply negative — has never
    /// been tested, and it is the claim the whole project rests on.
    public static let relaxedVsFocused = ExperimentDesign(
        id: UUID(uuidString: "E0000002-0000-4000-8000-000000000002") ?? UUID(),
        name: "relaxed-vs-focused",
        question: "What does trying to focus do to your correction gain?",
        arms: ["relaxed", "focused"],
        metric: .correctionGain,
        takesPerArm: 5)

    public static var all: [ExperimentDesign] { [steadyVsMelodic, relaxedVsFocused].compactMap { $0 } }

    /// The one to run, given what each has already collected: the first that is not finished.
    ///
    /// Order is priority. `steady-vs-melodic` goes first because M12 is blocked on it and the
    /// data to interpret is already half gathered.
    public static func active(progressByName: [String: Bool]) -> ExperimentDesign? {
        all.first { progressByName[$0.name] != true }
    }
}
