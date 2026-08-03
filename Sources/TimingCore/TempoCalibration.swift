import Foundation

/// One round: the click establishes a tempo, then the player holds it alone.
public struct TempoRound: Equatable {
    public let index: Int
    public let targetBpm: Double
    /// Start and end of the unaccompanied stretch, on the session timeline.
    public let holdStart: Double
    public let holdEnd: Double

    public init(index: Int, targetBpm: Double, holdStart: Double, holdEnd: Double) {
        self.index = index
        self.targetBpm = targetBpm
        self.holdStart = holdStart
        self.holdEnd = holdEnd
    }
}

public struct TempoRoundResult: Equatable {
    public let index: Int
    public let targetBpm: Double
    public let producedBpm: Double?
    /// Produced minus target. Negative = you played slower than asked.
    public let errorBpm: Double?
    public let errorPercent: Double?
    public let noteCount: Int
    /// False when the round can't be scored — too few notes, or not one note per beat.
    public let isUsable: Bool
    public let unusableReason: String?
}

public struct TempoCalibrationReport: Equatable {
    public let rounds: [TempoRoundResult]
    public let usableCount: Int

    /// Signed bias across usable rounds, in percent of target. The number the drill trains.
    public let meanErrorPercent: Double?
    /// Absolute error, i.e. accuracy regardless of direction.
    public let meanAbsErrorPercent: Double?
    /// Slope of absolute error against round number. Negative means the feedback loop is
    /// working *within* the session — the point of doing rounds rather than one long take.
    public let improvementPerRound: Double?
    public let headline: String
}

public enum TempoCalibrationAnalysis {

    /// Minimum notes in a hold to score it. Fewer than this and the period estimate is noise.
    private static let minimumNotes = 5

    public static func analyze(taps: [Tap], rounds: [TempoRound]) -> TempoCalibrationReport {
        let sorted = taps.sorted { $0.time < $1.time }
        var results: [TempoRoundResult] = []

        for round in rounds {
            let raw = sorted.filter { $0.time >= round.holdStart && $0.time < round.holdEnd }
            // Collapse accidental double-triggers before scoring — one stray onset otherwise
            // skews the period estimate the whole round rests on.
            let inHold = TapClustering.collapseIsochronous(raw)
            let targetBeat = 60.0 / round.targetBpm

            guard inHold.count >= minimumNotes else {
                results.append(TempoRoundResult(
                    index: round.index, targetBpm: round.targetBpm, producedBpm: nil,
                    errorBpm: nil, errorPercent: nil, noteCount: inHold.count,
                    isUsable: false, unusableReason: "only \(inHold.count) notes"))
                continue
            }

            var intervals: [Double] = []
            for i in 1..<inHold.count { intervals.append(inHold[i].time - inHold[i - 1].time) }
            let median = Stats.median(intervals)

            // Reject a hold that isn't one note per beat. Consistent subdividing is fine and
            // is normalised below; what cannot be scored is a mix of note values, because
            // then no single period describes what was played.
            let odd = intervals.filter { $0 < 0.6 * median || $0 > 1.6 * median }
            guard Double(odd.count) / Double(intervals.count) <= 0.25, median > 0 else {
                results.append(TempoRoundResult(
                    index: round.index, targetBpm: round.targetBpm, producedBpm: nil,
                    errorBpm: nil, errorPercent: nil, noteCount: inHold.count,
                    isUsable: false, unusableReason: "not one note per beat"))
                continue
            }

            // Normalise for steady subdivision so eighths at the right tempo don't read double.
            let notesPerBeat = max(1, (targetBeat / median).rounded())
            let produced = 60.0 / (median * notesPerBeat)
            let error = produced - round.targetBpm

            results.append(TempoRoundResult(
                index: round.index, targetBpm: round.targetBpm, producedBpm: produced,
                errorBpm: error, errorPercent: error / round.targetBpm * 100,
                noteCount: inHold.count, isUsable: true, unusableReason: nil))
        }

        let usable = results.filter(\.isUsable)
        let signed = usable.compactMap(\.errorPercent)
        let absolute = signed.map(abs)

        var improvement: Double?
        if usable.count >= 3 {
            improvement = Stats.linearFit(x: usable.map { Double($0.index) }, y: absolute)?.slope
        }

        return TempoCalibrationReport(
            rounds: results,
            usableCount: usable.count,
            meanErrorPercent: signed.isEmpty ? nil : Stats.mean(signed),
            meanAbsErrorPercent: absolute.isEmpty ? nil : Stats.mean(absolute),
            improvementPerRound: improvement,
            headline: Self.headline(usable: usable.count, total: results.count,
                                    bias: signed.isEmpty ? nil : Stats.mean(signed),
                                    improvement: improvement))
    }

    private static func headline(usable: Int, total: Int, bias: Double?,
                                 improvement: Double?) -> String {
        guard usable > 0 else {
            return "No round could be scored — play one steady note per beat through each silence."
        }
        guard let bias else { return "Rounds recorded." }

        let direction = bias < 0 ? "slow" : "fast"
        let magnitude = abs(bias)
        var text: String

        if magnitude < 1 {
            text = String(format: "Your tempo is accurate — within %.1f%% of target unaccompanied.", magnitude)
        } else {
            text = String(format: "You run about %.0f%% %@ when the click stops.", magnitude, direction)
        }
        // Improvement within a session is the whole reason this is a loop rather than one take.
        if let improvement, usable >= 3 {
            if improvement < -0.3 { text += " You tightened up as the session went on." }
            else if improvement > 0.3 { text += " Your accuracy slipped as the session went on." }
        }
        return text
    }
}
