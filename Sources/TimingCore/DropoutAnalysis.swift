import Foundation

/// One stretch of the drill, either with the band or without it.
public struct DropoutSection: Equatable {
    public let startTime: Double
    public let endTime: Double
    public let isPaced: Bool

    public init(startTime: Double, endTime: Double, isPaced: Bool) {
        self.startTime = startTime
        self.endTime = endTime
        self.isPaced = isPaced
    }
}

/// One silence and the playing around it.
public struct ContinuationTrial: Equatable {
    public let index: Int
    /// Inter-onset intervals during the silence, ms.
    public let intervalsMs: [Double]
    /// Median interval, ms — the player's beat period for this silence.
    public let medianIntervalMs: Double
    /// True when the player kept to one note per beat. Wing–Kristofferson assumes an
    /// isochronous sequence; a silence with subdivisions or dropped notes in it violates
    /// that outright and must not feed the decomposition.
    public let isIsochronous: Bool
    /// Whether the period *changed* during the silence — accelerating or slowing — as
    /// opposed to simply sitting at the wrong tempo. ms per beat.
    public let withinTrialDriftMsPerBeat: Double?
    /// Asynchrony of the note nearest the downbeat where the band returns, ms.
    public let reentryErrorMs: Double?
    public let noteCount: Int
}

public struct DropoutReport: Equatable {
    public let trials: [ContinuationTrial]
    /// Trials thrown out for not being one note per beat.
    public let discardedTrials: Int

    public let pacedSDms: Double
    /// Spread of intervals within silences, pooled across usable trials.
    public let unpacedIntervalSDms: Double

    public let wingKristofferson: WingKristoffersonResult?
    /// True when the split is worth reading. Wing–Kristofferson puts motor variance at −γ₁,
    /// so a sequence with no negative lag-1 pins it at zero — which is not a measurement of
    /// a human, it is the model hitting its floor. Usually caused by a tempo trend swamping
    /// the alternation motor noise creates.
    public let splitIsReliable: Bool

    /// The tempo actually produced while unaccompanied.
    public let playedBpm: Double?
    /// Played tempo minus target. Negative = you play slower than the click when alone.
    public let tempoBiasBpm: Double?
    /// The same bias as accumulated lateness: ms of slippage per beat.
    public let tempoBiasMsPerBeat: Double?
    /// Mean *within-silence* acceleration, distinct from sitting at a steady wrong tempo.
    public let meanWithinTrialDriftMsPerBeat: Double?

    public let reentryErrorMeanMs: Double
    public let reentryErrorSDms: Double

    public let pacedNoteCount: Int
    public let unpacedNoteCount: Int
    public let headline: String
}

public enum DropoutAnalysis {

    /// Intervals outside this band around the trial median are not "the next beat" — they are
    /// a subdivision or a dropped note.
    private static let isochronyLow = 0.6
    private static let isochronyHigh = 1.6
    /// A trial with more than this fraction of odd intervals is not a continuation sequence.
    private static let maxOddFraction = 0.25

    public static func analyze(taps: [Tap], grid: Grid, sections: [DropoutSection],
                               matchWindowFraction: Double = 0.45) -> DropoutReport {
        let sorted = taps.sorted { $0.time < $1.time }
        let beat = grid.beatInterval

        var pacedAsync: [Double] = []
        var pacedCount = 0
        for section in sections where section.isPaced {
            let inSection = sorted.filter { $0.time >= section.startTime && $0.time < section.endTime }
            pacedCount += inSection.count
            for tap in inSection {
                let beatIndex = ((tap.time - grid.startTime) / beat).rounded()
                let offset = tap.time - (grid.startTime + beatIndex * beat)
                if abs(offset) <= matchWindowFraction * beat { pacedAsync.append(offset * 1000) }
            }
        }

        var trials: [ContinuationTrial] = []
        var unpacedCount = 0
        let unpacedSections = sections.enumerated().filter { !$0.element.isPaced }

        for (order, entry) in unpacedSections.enumerated() {
            let section = entry.element
            let inSection = sorted.filter { $0.time >= section.startTime && $0.time < section.endTime }
            unpacedCount += inSection.count

            var intervals: [Double] = []
            if inSection.count >= 2 {
                for i in 1..<inSection.count {
                    intervals.append((inSection[i].time - inSection[i - 1].time) * 1000)
                }
            }

            let median = intervals.isEmpty ? .nan : Stats.median(intervals)
            var isochronous = false
            if intervals.count >= 3, median > 0 {
                let odd = intervals.filter { $0 < isochronyLow * median || $0 > isochronyHigh * median }
                isochronous = Double(odd.count) / Double(intervals.count) <= maxOddFraction
            }

            // Acceleration *within* the silence: is the period itself changing?
            var withinDrift: Double?
            if isochronous, intervals.count >= 4,
               let fit = Stats.linearFit(x: (0..<intervals.count).map(Double.init), y: intervals) {
                withinDrift = fit.slope
            }

            // Re-entry measured against the known return downbeat, not the nearest beat: a
            // drifted player can be most of a beat away, where nearest-beat matching would
            // flip the sign and report a small error instead of a large one.
            var reentry: Double?
            if let next = sections.dropFirst(entry.offset + 1).first(where: { $0.isPaced }) {
                let target = next.startTime
                if let closest = sorted.min(by: { abs($0.time - target) < abs($1.time - target) }),
                   abs(closest.time - target) <= beat {
                    reentry = (closest.time - target) * 1000
                }
            }

            trials.append(ContinuationTrial(
                index: order, intervalsMs: intervals, medianIntervalMs: median,
                isIsochronous: isochronous, withinTrialDriftMsPerBeat: withinDrift,
                reentryErrorMs: reentry, noteCount: inSection.count))
        }

        let usable = trials.filter(\.isIsochronous)
        let wk = WingKristofferson.decompose(trials: usable.map(\.intervalsMs))

        // A motor estimate at the model's floor is not a measurement of the player.
        var reliable = false
        if let wk, wk.modelHolds, usable.count >= 2, wk.motorSDms > 1.0 { reliable = true }

        let periods = usable.map(\.medianIntervalMs).filter { $0 > 0 }
        var playedBpm: Double?
        var biasBpm: Double?
        var biasMs: Double?
        if !periods.isEmpty {
            let meanPeriod = Stats.mean(periods)
            // A player subdividing consistently — eighths all the way through — is still a
            // valid continuation sequence, but their note period is not their beat period.
            // Without this, steady eighths at the right tempo would read as 200 BPM.
            let notesPerBeat = max(1, (beat * 1000 / meanPeriod).rounded())
            let beatPeriod = meanPeriod * notesPerBeat
            playedBpm = 60_000 / beatPeriod
            biasBpm = playedBpm! - grid.bpm
            biasMs = beatPeriod - beat * 1000
        }

        let withinDrifts = usable.compactMap(\.withinTrialDriftMsPerBeat)
        let allIntervals = usable.flatMap(\.intervalsMs)
        let reentries = trials.compactMap(\.reentryErrorMs)

        return DropoutReport(
            trials: trials,
            discardedTrials: trials.count - usable.count,
            pacedSDms: pacedAsync.count > 1 ? Stats.sd(pacedAsync) : .nan,
            unpacedIntervalSDms: allIntervals.count > 1 ? Stats.sd(allIntervals) : .nan,
            wingKristofferson: wk,
            splitIsReliable: reliable,
            playedBpm: playedBpm,
            tempoBiasBpm: biasBpm,
            tempoBiasMsPerBeat: biasMs,
            meanWithinTrialDriftMsPerBeat: withinDrifts.isEmpty ? nil : Stats.mean(withinDrifts),
            reentryErrorMeanMs: reentries.isEmpty ? .nan : Stats.mean(reentries),
            reentryErrorSDms: reentries.count > 1 ? Stats.sd(reentries) : .nan,
            pacedNoteCount: pacedCount,
            unpacedNoteCount: unpacedCount,
            headline: Self.headline(wk: wk, reliable: reliable, biasBpm: biasBpm,
                                    playedBpm: playedBpm, targetBpm: grid.bpm,
                                    usable: usable.count, unpacedNotes: unpacedCount))
    }

    /// Say the most useful true thing. A systematic tempo bias outranks the clock/motor split
    /// when the split is not trustworthy — and it is the more actionable finding anyway.
    private static func headline(wk: WingKristoffersonResult?, reliable: Bool, biasBpm: Double?,
                                 playedBpm: Double?, targetBpm: Double,
                                 usable: Int, unpacedNotes: Int) -> String {
        guard unpacedNotes >= 12 else {
            return "Not enough playing through the silences — keep one note per beat going when the band drops out."
        }
        if usable == 0 {
            return "None of the silences held one note per beat, so nothing here is measurable. "
                 + "Play steady quarter notes straight through, without subdividing."
        }
        // A systematic tempo bias outranks the split: it is both more reliably measured and
        // more directly actionable than a variance decomposition.
        if let bias = biasBpm, let played = playedBpm, abs(bias) >= 2 {
            let percent = abs(bias) / targetBpm * 100
            let direction = bias < 0 ? "slower" : "faster"
            var text = String(format: "Left alone you settle at %.0f BPM — about %.0f%% %@ than the click.",
                              played, percent, direction)
            if reliable, let wk {
                if wk.clockSDms > wk.motorSDms * 1.6 { text += " Your clock is also the looser half." }
                else if wk.motorSDms > wk.clockSDms * 1.6 { text += " Your hands are the looser half." }
            }
            return text
        }
        if reliable, let wk {
            if wk.clockSDms > wk.motorSDms * 1.6 {
                return "Your internal clock is the looser half — the pulse itself wanders, "
                     + "your hands execute it faithfully."
            }
            if wk.motorSDms > wk.clockSDms * 1.6 {
                return "Your clock is steadier than your hands — the pulse is there, the "
                     + "execution scatters around it."
            }
            return "Clock and hands contribute about equally to the wander."
        }
        return "You held the pulse through the silences, but the clock/motor split isn't reliable yet."
    }
}
