import Foundation

/// One take that belongs to an experiment, reduced to the number being compared.
public struct ExperimentTake: Equatable {
    public let arm: String
    /// The metric for this take, already computed by whichever analysis owns it.
    ///
    /// `nil` when the take could not produce one — an unscorable drill, a withheld interference
    /// cost. Kept rather than dropped so attrition can be counted per arm.
    public let value: Double?
    /// Minutes into the sitting, from `SessionPlacement`. The confound axis.
    public let elapsedMinutes: Double?
    /// Which sitting, so an arm concentrated in one evening can be spotted.
    public let sittingId: UUID?
    /// Matched notes per beat this take actually produced. A covariate, never a filter.
    ///
    /// `steady-vs-melodic` asks one arm for one note per beat and the other for a melodic line,
    /// so the arms differ in density **by construction** — that is the condition, not a flaw in
    /// it. Blocking the comparison on it would guarantee a refusal after five evenings, and
    /// normalising the metric by it would divide by the treatment. Reporting it is the third
    /// option and the honest one: a verdict then reads "melodic was looser, and it was also
    /// this much busier", which is a result a reader can interpret rather than one they have to
    /// take on trust. See PLAN.md §7.23.
    public let notesPerBeat: Double?

    public init(arm: String, value: Double?, elapsedMinutes: Double? = nil,
                sittingId: UUID? = nil, notesPerBeat: Double? = nil) {
        self.arm = arm; self.value = value
        self.elapsedMinutes = elapsedMinutes; self.sittingId = sittingId
        self.notesPerBeat = notesPerBeat
    }
}

public struct ArmSummary: Equatable {
    public let arm: String
    /// Takes assigned to this arm, scored or not.
    public let assigned: Int
    /// Takes that produced a number.
    public let scored: Int
    /// Mean of the per-take values. `nil` when nothing scored.
    public let mean: Double?
    /// Spread *between* this arm's takes — the quantity the comparison's uncertainty rests on.
    public let betweenTakeSD: Double?
    /// Mean minutes into the sitting, for the position confound.
    public let meanElapsedMinutes: Double?
    /// Mean matched notes per beat across this arm's scored takes. Reported, never scored.
    public let meanNotesPerBeat: Double?
}

public enum ExperimentVerdict: Equatable {
    /// Below the preregistered target. No comparison is computed at all.
    case collecting(takesRemaining: Int)
    /// At target, and the interval includes zero.
    case noDifferenceFound
    /// At target, and the interval excludes zero. The named arm is the one with the lower
    /// value; whether lower is *better* depends on the metric and is stated separately.
    case difference(lowerArm: String)
    /// Something makes the arms non-comparable regardless of count.
    case unusable(reason: String)
}

public struct ExperimentResult: Equatable {
    public let design: ExperimentDesign
    public let arms: [ArmSummary]
    /// `arms[1] − arms[0]`, on the plain bootstrap over per-take values. Only when at target.
    public let difference: ConfidenceInterval?
    public let verdict: ExperimentVerdict
    /// The smallest difference this many takes could separate from zero, in the metric's units.
    public let minimumDetectableEffect: Double?
    public let headline: String
    /// Everything that would make a reader over-claim.
    public let notes: [String]
}

/// The experiment readout: what the arms measured, and whether it may be read yet.
///
/// **The unit of analysis is the take, not the event.** Each take contributes one number — its
/// spread, its bias, its interference cost — and an arm's value is the mean of its takes'
/// numbers. This is the question §7.20 finding 1 left open, and it is settled here rather than
/// in passing.
///
/// Pooling events instead would have been wrong twice over. A longer take would carry more
/// weight than a short one for no reason anybody chose. Worse, a pooled SD across takes with
/// different placements includes the *between-take bias spread* on top of the within-take
/// spread — over the 5 August jams, whose means sit at −22.6 and −16.1, the pooled figure would
/// report as spread something that is really a difference in where the player sat. Spread is a
/// within-take property; the project's own headline numbers (24.07, 17.37, 22.00) are per-take,
/// and the analysis now matches how the results were always read.
///
/// With the take as the unit, the bootstrap is the plain one over per-take values — independent
/// observations, days apart, with no serial structure for blocks to preserve.
public enum ExperimentAnalysis {

    /// Arms this far apart in mean elapsed time are confounded with position in the sitting.
    ///
    /// Ten minutes, because that is the scale at which this dataset shows fatigue: §7.17 has two
    /// takes identical on every number rated 4 and 1 twenty minutes apart.
    public static let confoundingElapsedGapMinutes = 10.0

    /// A gap this large in scored rate makes the arms non-comparable, exactly as for the recall
    /// drill's retention conditions (§7.20 finding 2). One take in five.
    public static let imbalancedAttritionRate = 0.2

    public static func analyze(design: ExperimentDesign,
                               takes: [ExperimentTake],
                               iterations: Int = 2000,
                               seed: UInt64 = 0x5EED) -> ExperimentResult {
        let arms = design.arms.map { arm -> ArmSummary in
            let mine = takes.filter { $0.arm == arm }
            let values = mine.compactMap(\.value).filter(\.isFinite)
            let elapsed = mine.compactMap(\.elapsedMinutes)
            let density = mine.compactMap(\.notesPerBeat).filter(\.isFinite)
            return ArmSummary(
                arm: arm, assigned: mine.count, scored: values.count,
                mean: values.isEmpty ? nil : Stats.mean(values),
                betweenTakeSD: Stats.finite(Stats.sd(values)),
                meanElapsedMinutes: elapsed.isEmpty ? nil : Stats.mean(elapsed),
                meanNotesPerBeat: density.isEmpty ? nil : Stats.mean(density))
        }

        var notes = caveats(design: design, arms: arms, takes: takes)
        let shortfall = arms.reduce(0) { $0 + max(0, design.takesPerArm - $1.scored) }

        // The stopping rule, before any comparison exists. Computing the difference and then
        // declining to show it would still be optional stopping — the number would be there to
        // be looked at, and this app recomputes after every session.
        guard shortfall == 0 else {
            return ExperimentResult(
                design: design, arms: arms, difference: nil,
                verdict: .collecting(takesRemaining: shortfall),
                minimumDetectableEffect: mde(arms: arms, design: design),
                headline: "\(design.name): collecting. \(shortfall) scored take(s) to go before "
                        + "anything is compared.",
                notes: notes)
        }

        if let reason = blocker(design: design, arms: arms) {
            return ExperimentResult(
                design: design, arms: arms, difference: nil,
                verdict: .unusable(reason: reason),
                minimumDetectableEffect: mde(arms: arms, design: design),
                headline: "\(design.name): at target, but the arms are not comparable. \(reason)",
                notes: notes)
        }

        // Two arms get a difference; more get per-arm figures and an explicit refusal, because a
        // pairwise verdict across three arms is three comparisons wearing one hat.
        guard design.arms.count == 2 else {
            notes.append("This experiment has \(design.arms.count) arms. Each arm's figures are "
                       + "above; a single verdict across more than two would be several "
                       + "comparisons reported as one.")
            return ExperimentResult(
                design: design, arms: arms, difference: nil, verdict: .noDifferenceFound,
                minimumDetectableEffect: mde(arms: arms, design: design),
                headline: "\(design.name): \(design.arms.count) arms at target — read them "
                        + "side by side.", notes: notes)
        }

        let a = takes.filter { $0.arm == design.arms[0] }.compactMap(\.value).filter(\.isFinite)
        let b = takes.filter { $0.arm == design.arms[1] }.compactMap(\.value).filter(\.isFinite)
        let diff = Bootstrap.plainDifference(b, a, iterations: iterations, seed: seed)

        let verdict: ExperimentVerdict
        if let diff, diff.excludesZero {
            verdict = .difference(lowerArm: diff.point > 0 ? design.arms[0] : design.arms[1])
        } else {
            verdict = .noDifferenceFound
        }
        return ExperimentResult(
            design: design, arms: arms, difference: diff, verdict: verdict,
            minimumDetectableEffect: mde(arms: arms, design: design),
            headline: headline(design: design, arms: arms, diff: diff, verdict: verdict),
            notes: notes)
    }

    // MARK: - Power

    /// The smallest difference this many takes could separate from zero.
    ///
    /// Deliberately *not* a power calculation. It is the half-width of the interval a difference
    /// of means would carry at this between-take spread and this many takes — the point below
    /// which a real effect would still come back as "no difference found". Reporting it as
    /// power at some percentage would imply a design calculation nobody did.
    ///
    /// The between-take SD it rests on is itself estimated from a handful of takes, so it is a
    /// guide to how many more are needed, not a promise.
    public static func mde(arms: [ArmSummary], design: ExperimentDesign) -> Double? {
        let sds = arms.compactMap(\.betweenTakeSD)
        guard !sds.isEmpty, design.takesPerArm > 0 else { return nil }
        let pooled = (sds.reduce(0) { $0 + $1 * $1 } / Double(sds.count)).squareRoot()
        guard pooled.isFinite, pooled > 0 else { return nil }
        return 1.96 * pooled * (2.0 / Double(design.takesPerArm)).squareRoot()
    }

    /// Takes per arm needed to separate an effect of the given size from zero.
    public static func takesNeeded(forEffect effect: Double, arms: [ArmSummary]) -> Int? {
        let sds = arms.compactMap(\.betweenTakeSD)
        guard !sds.isEmpty, effect > 0 else { return nil }
        let pooled = (sds.reduce(0) { $0 + $1 * $1 } / Double(sds.count)).squareRoot()
        guard pooled.isFinite, pooled > 0 else { return nil }
        let n = 2 * Foundation.pow(1.96 * pooled / effect, 2)
        return max(2, Int(n.rounded(.up)))
    }

    // MARK: - What would make a reader over-claim

    /// A reason the arms cannot be compared at all, whatever the counts say.
    private static func blocker(design: ExperimentDesign, arms: [ArmSummary]) -> String? {
        let rates = arms.map { $0.assigned > 0 ? Double($0.scored) / Double($0.assigned) : 0 }
        if let hi = rates.max(), let lo = rates.min(), hi - lo >= imbalancedAttritionRate {
            return "One arm lost more takes to unscorable drills than the other "
                 + "(\(arms.map { "\($0.arm) \($0.scored)/\($0.assigned)" }.joined(separator: ", "))"
                 + "), so the arms are scored on self-selected sets."
        }
        return nil
    }

    private static func caveats(design: ExperimentDesign, arms: [ArmSummary],
                                takes: [ExperimentTake]) -> [String] {
        var notes: [String] = []

        // 1. Position in the sitting. The largest confound this dataset has ever shown.
        let elapsed = arms.compactMap(\.meanElapsedMinutes)
        if elapsed.count == arms.count, let hi = elapsed.max(), let lo = elapsed.min(),
           hi - lo >= confoundingElapsedGapMinutes {
            notes.append(String(format: "The arms did not run at the same point in a sitting — "
                              + "%.0f minutes apart on average. Two takes identical on every "
                              + "number were rated 4 and 1 twenty minutes apart (§7.17), so a "
                              + "difference this design finds could be fatigue.", hi - lo))
        }

        // 2. Concentration in one sitting: an arm played only on a good night is a good night.
        for arm in design.arms {
            let sittings = Set(takes.filter { $0.arm == arm }.compactMap(\.sittingId))
            if sittings.count == 1, takes.filter({ $0.arm == arm }).count > 1 {
                notes.append("Every '\(arm)' take comes from one sitting, so that arm carries "
                           + "whatever else was true of that evening.")
            }
        }

        // 3. Note density, reported rather than blocked on.
        //
        // A difference here is not a defect in the design — for an instruction-only experiment
        // about *what* is played it is the condition arriving in the data. It is stated so a
        // verdict cannot be read as being about content alone when density moved with it.
        let densities = arms.compactMap { arm in arm.meanNotesPerBeat.map { (arm.arm, $0) } }
        if densities.count == arms.count, densities.count >= 2,
           let hi = densities.max(by: { $0.1 < $1.1 }), let lo = densities.min(by: { $0.1 < $1.1 }),
           hi.1 > lo.1 * 1.25 {
            notes.append(String(format: "The arms differ in how densely they were played — "
                              + "%@ at %.2f notes per beat against %@ at %.2f. That is the "
                              + "condition doing its job, not a fault, but any difference found "
                              + "is a difference between two ways of playing that includes the "
                              + "density, and not about content on its own.",
                                hi.0, hi.1, lo.0, lo.1))
        }

        // 4. Tempo as the condition rests on a measured premise, not an obvious one.
        if design.variesTempo {
            notes.append("The arms differ in tempo, so this compares \(design.metric.label) "
                       + "across tempos — which is only sound because this player's scatter was "
                       + "measured to be a fixed number of milliseconds rather than a fixed "
                       + "fraction of the interval (§7.23 step 3b). If that stops holding, the "
                       + "comparison becomes arithmetic rather than skill and this design has "
                       + "to be read again.")
        }

        // 5. The metric has no better direction.
        if design.metric.lowerIsBetter == nil {
            notes.append("\(design.metric.label) has no better direction — it is reported, not "
                       + "scored. Bias is not failure; variance is the skill.")
        }
        return notes
    }

    private static func headline(design: ExperimentDesign, arms: [ArmSummary],
                                 diff: ConfidenceInterval?,
                                 verdict: ExperimentVerdict) -> String {
        guard let diff else {
            return "\(design.name): at target, but no interval could be computed."
        }
        let unit = design.metric == .tempoError ? "%" : ""
        switch verdict {
        case .difference(let lower):
            return String(format: "%@: %@ came out lower on %@ by %.2f%@ [%.2f, %.2f]. "
                        + "A real difference at the preregistered %d takes per arm.",
                          design.name, lower, design.metric.label, abs(diff.point), unit,
                          min(abs(diff.low), abs(diff.high)), max(abs(diff.low), abs(diff.high)),
                          design.takesPerArm)
        default:
            return String(format: "%@: no difference in %@ that %d takes per arm can separate "
                        + "from zero (%+.2f%@ [%+.2f, %+.2f]).",
                          design.name, design.metric.label, design.takesPerArm,
                          diff.point, unit, diff.low, diff.high)
        }
    }
}
