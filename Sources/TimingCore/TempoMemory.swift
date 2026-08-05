import Foundation

/// What filled the gap between hearing a tempo and reproducing it.
public enum RetentionCondition: String, Codable, Equatable {
    /// Nothing. The control.
    case silent
    /// An aperiodic distractor — sound that occupies the timing system without offering a
    /// period to latch onto.
    case filled
}

public struct MemoryRound: Equatable {
    public let index: Int
    public let targetBpm: Double
    public let condition: RetentionCondition
    /// The gap between the reference ending and the cue to reproduce.
    public let retentionStart: Double
    public let retentionEnd: Double
    /// The unaccompanied stretch where the player produces the tempo.
    public let reproduceStart: Double
    public let reproduceEnd: Double

    public init(index: Int, targetBpm: Double, condition: RetentionCondition,
                retentionStart: Double, retentionEnd: Double,
                reproduceStart: Double, reproduceEnd: Double) {
        self.index = index; self.targetBpm = targetBpm; self.condition = condition
        self.retentionStart = retentionStart; self.retentionEnd = retentionEnd
        self.reproduceStart = reproduceStart; self.reproduceEnd = reproduceEnd
    }

    public var retentionSeconds: Double { retentionEnd - retentionStart }
}

public struct MemoryRoundResult: Equatable {
    public let index: Int
    public let targetBpm: Double
    public let condition: RetentionCondition
    public let retentionSeconds: Double
    public let producedBpm: Double?
    public let errorPercent: Double?
    public let noteCount: Int
    /// Notes played during the wait. Anything more than a stray means the player kept the
    /// pulse running instead of storing it — a different task, and not this one.
    public let notesDuringRetention: Int
    public let isUsable: Bool
    public let unusableReason: String?
}

/// How many rounds a condition kept, and how many it lost to the failure mode that differs
/// *between* conditions.
///
/// Attrition that is not equal across the two conditions is the artefact that produced this
/// drill's first finding and then forced its retraction (PLAN.md §7.17, §7.19). Three of eight
/// silent waits were played through against one of eight filled, so the silent rounds that
/// survived were a self-selected subset, and the "interference hurts" result was measuring the
/// selection. Counting the losses into a single total, as this used to, hides exactly that.
public struct RetentionAttrition: Equatable {
    public let condition: RetentionCondition
    public let rounds: Int
    public let scored: Int
    /// Rounds lost to playing through the wait — the condition-dependent one. An empty gap
    /// invites you to carry on; a distractor interrupts.
    public let playedThrough: Int
    /// Rounds lost for any other reason: too few notes, mixed note values. Not obviously
    /// condition-dependent, so it does not feed the imbalance test.
    public let otherwiseUnusable: Int

    public var playedThroughRate: Double {
        rounds > 0 ? Double(playedThrough) / Double(rounds) : 0
    }
}

public struct TempoMemoryReport: Equatable {
    public let rounds: [MemoryRoundResult]
    public let usableCount: Int

    public let silentMeanAbsErrorPercent: Double?
    public let filledMeanAbsErrorPercent: Double?
    /// filled − silent, in percentage points. Positive means the distractor cost you accuracy.
    ///
    /// **nil when `attritionIsImbalanced`**, not merely flagged. Withholding it here rather
    /// than asking each caller to check the flag is deliberate: three separate places derive
    /// this — the report, the history chart, and the planner's input — and a value that is
    /// only safe when every one of them remembers a precondition is a value that gets plotted
    /// wrong eventually. That is the same failure as the cached summary fields in §7.12.
    public let interferenceCost: Double?
    /// Bootstrap interval on that cost. nil when there are too few scored rounds per
    /// condition to say anything, which is most of the time early on.
    public let interferenceInterval: ConfidenceInterval?

    /// Per condition, so differential loss is visible rather than summed away.
    public let attrition: [RetentionAttrition]
    /// True when the two conditions lost materially different numbers of rounds to playing
    /// through the wait, which makes them non-comparable.
    public let attritionIsImbalanced: Bool

    public let headline: String
    public let notes: [String]
}

/// Is the period *stored*, or only held by keeping it running?
///
/// The continuation drill asks whether a pulse survives while you keep producing it. This asks
/// whether it survives when you stop — and specifically whether it survives having something
/// else in the gap. The two conditions are the experiment: a period maintained by active
/// attention should hold through silence and fall apart against a distractor, because the
/// distractor competes for exactly the resource doing the holding. A stored period should not
/// care what was in the gap.
///
/// For this player that is not an abstract question. "If my brain is out of the picture the
/// flow is easy" (PLAN.md §1) predicts a real interference cost, and this is the first thing
/// in the app that can put a number on it.
public enum TempoMemoryAnalysis {

    /// A stray note or two during the wait is a slip. More than this and the round is not
    /// measuring memory.
    public static let retentionNoteAllowance = 2
    /// Below this many scored rounds in a condition, the comparison is not worth an interval.
    public static let minimumRoundsPerCondition = 3

    /// A gap this large between the conditions' played-through *rates* makes them
    /// non-comparable. One round in five.
    ///
    /// A rate and not a count, which is not the obvious choice and the stored takes are the
    /// reason. §7.17 reports 3 silent against 1 filled — but that is the two takes of that
    /// evening pooled, and within each take the gap is a single round (1 against 0, then 2
    /// against 1). A count threshold of 2 would have passed both of the takes whose cost
    /// §7.19 had to retract, while flagging a later one. At four rounds per condition a single
    /// lost round is 25 points of attrition, and that is what has to trip it.
    public static let imbalancedAttritionRate = 0.2

    /// Next retention length, from the measured clock SD.
    ///
    /// Driven by clock stability rather than by this drill's own accuracy, because that is
    /// what it trains: how long a stored period stays put. A tight clock can hold longer; a
    /// loose one gets a shorter gap so the rounds stay scorable at all. Adaptation is between
    /// sessions — changing it mid-take would give rounds of different lengths and make the two
    /// conditions incomparable, which is the one thing this drill cannot afford.
    public static func suggestedRetentionBars(current: Int, clockSDms: Double?) -> Int {
        guard let clock = clockSDms, clock.isFinite else { return current }
        if clock < 10 { return min(16, current * 2) }    // tight — hold it longer
        if clock > 18 { return max(2, current / 2) }     // loose — shorten so rounds stay usable
        return current
    }

    public static func analyze(taps: [Tap], rounds: [MemoryRound],
                               iterations: Int = 2000,
                               seed: UInt64 = 0x3EE1) -> TempoMemoryReport {
        // Per-round scoring is the tempo drill's, not a second copy of it. Those rules — the
        // five-note floor, the isochrony gate, normalising steady subdivision — were each
        // added to fix a real wrong number (PLAN.md §7.8), and a parallel implementation here
        // would be a second place for them to be wrong.
        let scored = TempoCalibrationAnalysis.analyze(
            taps: taps,
            rounds: rounds.map { TempoRound(index: $0.index, targetBpm: $0.targetBpm,
                                            holdStart: $0.reproduceStart,
                                            holdEnd: $0.reproduceEnd) })

        var results: [MemoryRoundResult] = []
        for (round, base) in zip(rounds, scored.rounds) {
            let duringRetention = taps.filter {
                $0.time >= round.retentionStart && $0.time < round.retentionEnd
            }.count

            // Playing through the wait turns this into the continuation drill: the period was
            // never let go of, so nothing about *storing* it was tested.
            let keptPlaying = duringRetention > retentionNoteAllowance
            let usable = base.isUsable && !keptPlaying
            let reason = keptPlaying
                ? "\(duringRetention) notes during the wait — the pulse was never let go"
                : base.unusableReason

            results.append(MemoryRoundResult(
                index: round.index, targetBpm: round.targetBpm, condition: round.condition,
                retentionSeconds: round.retentionSeconds,
                producedBpm: usable ? base.producedBpm : nil,
                errorPercent: usable ? base.errorPercent : nil,
                noteCount: base.noteCount, notesDuringRetention: duringRetention,
                isUsable: usable, unusableReason: usable ? nil : reason))
        }

        let silent = results.filter { $0.condition == .silent && $0.isUsable }
            .compactMap { $0.errorPercent.map(abs) }
        let filled = results.filter { $0.condition == .filled && $0.isUsable }
            .compactMap { $0.errorPercent.map(abs) }

        let attrition = [RetentionCondition.silent, .filled].map { condition -> RetentionAttrition in
            let inCondition = results.filter { $0.condition == condition }
            // Counted from `notesDuringRetention`, not by matching the reason string: prose is
            // one rewording away from silently reporting no attrition at all.
            let playedThrough = inCondition.filter {
                $0.notesDuringRetention > retentionNoteAllowance
            }.count
            let scored = inCondition.filter(\.isUsable).count
            return RetentionAttrition(condition: condition, rounds: inCondition.count,
                                      scored: scored, playedThrough: playedThrough,
                                      otherwiseUnusable: inCondition.count - scored - playedThrough)
        }
        let silentLost = attrition[0].playedThrough, filledLost = attrition[1].playedThrough
        let imbalanced = abs(attrition[0].playedThroughRate - attrition[1].playedThroughRate)
            >= imbalancedAttritionRate

        var notes: [String] = []
        if silentLost + filledLost > 0 {
            notes.append("\(silentLost + filledLost) round(s) had playing during the wait — "
                       + "\(silentLost) silent, \(filledLost) filled. Stop completely when the "
                       + "groove stops; holding the tempo by playing it is the continuation "
                       + "drill, not this one.")
        }
        if imbalanced { notes.append(attritionNote(silentLost: silentLost, filledLost: filledLost)) }

        let cost = (silent.isEmpty || filled.isEmpty || imbalanced)
            ? nil : mean(filled) - mean(silent)
        var interval: ConfidenceInterval?
        if cost != nil, silent.count >= minimumRoundsPerCondition,
           filled.count >= minimumRoundsPerCondition {
            interval = differenceInterval(filled, silent, iterations: iterations, seed: seed)
        } else if cost != nil {
            notes.append("Only \(silent.count) silent and \(filled.count) filled round(s) scored — "
                       + "\(minimumRoundsPerCondition) of each before the difference means "
                       + "anything.")
        }

        return TempoMemoryReport(
            rounds: results, usableCount: results.filter(\.isUsable).count,
            silentMeanAbsErrorPercent: silent.isEmpty ? nil : mean(silent),
            filledMeanAbsErrorPercent: filled.isEmpty ? nil : mean(filled),
            interferenceCost: cost, interferenceInterval: interval,
            attrition: attrition, attritionIsImbalanced: imbalanced,
            headline: headline(silent: silent, filled: filled, interval: interval,
                               attritionIsImbalanced: imbalanced),
            notes: notes)
    }

    /// Names the imbalance *and which way it pushes the cost*.
    ///
    /// A caveat that does not state its direction is not a finding — the lesson of the content
    /// analysis's censoring warning (§7.19), which was corrected for exactly this reason.
    ///
    /// The direction argument: a round survives when the player managed to stop, and stopping
    /// is easiest when the period is already sitting securely. The surviving rounds of
    /// whichever condition lost more are therefore its easier ones, and its error is
    /// understated. Cost is `filled − silent`, so understating silent pushes the cost up and
    /// understating filled pushes it down.
    private static func attritionNote(silentLost: Int, filledLost: Int) -> String {
        let silentHeavier = silentLost > filledLost
        let heavier = silentHeavier ? "silent" : "filled"
        let lighter = silentHeavier ? "filled" : "silent"
        let direction = silentHeavier ? "overstates the cost" : "understates the cost"
        return "The conditions did not lose the same number of rounds: \(silentLost) silent "
             + "against \(filledLost) filled, played through rather than held. A round survives "
             + "when you managed to stop, and stopping is easiest when the period is already "
             + "sitting securely — so the \(heavier) rounds that scored are the easier ones and "
             + "their error is understated against \(lighter). That \(direction). This is the "
             + "artefact that produced this drill's first result and then reversed it, so the "
             + "two conditions are not comparable in this take."
    }

    /// Interval on the difference of means between two independent sets of rounds.
    ///
    /// A plain resample, not the moving-block one `Bootstrap` uses for asynchrony series:
    /// rounds are separate trials minutes apart, not a serially-correlated stream, so there
    /// is no short-range structure for blocks to preserve.
    private static func differenceInterval(_ a: [Double], _ b: [Double],
                                           iterations: Int, seed: UInt64) -> ConfidenceInterval? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var rng = SplitMix64(seed: seed)
        var deltas: [Double] = []
        deltas.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var sa = 0.0, sb = 0.0
            for _ in a.indices { sa += a[Int(rng.next() % UInt64(a.count))] }
            for _ in b.indices { sb += b[Int(rng.next() % UInt64(b.count))] }
            deltas.append(sa / Double(a.count) - sb / Double(b.count))
        }
        return ConfidenceInterval(point: mean(a) - mean(b),
                                  low: Stats.percentile(deltas, 0.025),
                                  high: Stats.percentile(deltas, 0.975),
                                  level: 0.95)
    }

    private static func headline(silent: [Double], filled: [Double],
                                 interval: ConfidenceInterval?,
                                 attritionIsImbalanced: Bool) -> String {
        guard !silent.isEmpty || !filled.isEmpty else {
            return "No round could be scored — stop playing through the wait, then give one "
                 + "steady note per beat after the cue."
        }
        // Before any cost is quoted. The two sets are not describing the same task when one
        // condition kept its easy rounds and the other did not, and a cost stated here is the
        // one this drill has already had to retract.
        if attritionIsImbalanced, !silent.isEmpty, !filled.isEmpty {
            return String(format: "Silent gap %.1f%% off, filled gap %.1f%% off — but the two "
                        + "conditions lost different numbers of rounds to playing through the "
                        + "wait, so they are not scored on comparable sets. No interference "
                        + "cost can be read from this take.", mean(silent), mean(filled))
        }
        guard let interval else {
            if silent.isEmpty || filled.isEmpty {
                let which = silent.isEmpty ? "silent" : "filled"
                return "Only one condition scored — no \(which) rounds came through, so there is "
                     + "nothing to compare yet."
            }
            return String(format: "Silent gap %.1f%% off, filled gap %.1f%% off. Too few rounds "
                        + "to say whether the difference is real.", mean(silent), mean(filled))
        }

        let cost = interval.point
        if !interval.excludesZero {
            return String(format: "The distractor costs you nothing measurable — %.1f%% off after "
                        + "silence, %.1f%% after interference. Within noise, so the period looks "
                        + "held rather than rehearsed.", mean(silent), mean(filled))
        }
        if cost > 0 {
            return String(format: "Interference costs you %.1f points of accuracy (%.1f%% off "
                        + "after silence, %.1f%% after the distractor). The period is being held "
                        + "by attention rather than stored — which is exactly what makes it "
                        + "collapse when something else needs the attention.",
                          cost, mean(silent), mean(filled))
        }
        return String(format: "You were %.1f points *more* accurate after the distractor "
                    + "(%.1f%% against %.1f%%). Odd, and worth repeating — an empty gap may be "
                    + "inviting you to count through it.",
                      -cost, mean(filled), mean(silent))
    }

    private static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count)
    }
}
