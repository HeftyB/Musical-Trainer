import Foundation

/// One phrase mark, decomposed into the two errors that matter.
public struct PhraseMark: Equatable {
    public let time: Double
    /// Which phrase top this mark was aiming at (0-based), by nearest.
    public let phraseIndex: Int
    /// Whole bars away from that phrase top. **This is the form/spatial-awareness error** —
    /// zero means you knew where you were, ±1 means you were a bar out.
    public let formErrorBars: Int
    /// Placement relative to the nearest *bar line*, in ms. Separating this from the form
    /// error is the whole point: landing crisply on the wrong downbeat is a completely
    /// different failure from landing sloppily on the right one.
    public let phaseErrorMs: Double

    public var isOnForm: Bool { formErrorBars == 0 }
}

public struct FormReport: Equatable {
    public let marks: [PhraseMark]
    public let phrasesAvailable: Int
    public let marksPlaced: Int

    public let onFormCount: Int
    public let onFormRate: Double
    /// On-form marks that also landed close to the downbeat. "Right bar" is a generous
    /// criterion — half a bar is 1.2 s at 100 BPM — so this is the number that says you
    /// actually *nailed* the turn rather than merely being in the right neighbourhood.
    public let tightCount: Int
    public let tightToleranceMs: Double
    /// Counts of each whole-bar error, e.g. `[0: 6, 1: 2]` — six on the money, two a bar late.
    public let formErrorHistogram: [Int: Int]
    public let meanAbsFormErrorBars: Double

    /// Placement stats among on-form marks only. Including off-form marks would mix two
    /// different quantities.
    public let phaseErrorMeanMs: Double
    public let phaseErrorSDms: Double

    /// Slope of form error against phrase index, in bars per phrase. Positive means the
    /// error grows as the take goes on — progressively losing the thread, which is a
    /// different problem from jittering around the right answer.
    public let slipBarsPerPhrase: Double?

    /// Phrase tops that got no mark, and phrases that got more than one. Both reveal a
    /// whole-phrase slip that nearest-phrase matching would otherwise hide: a player one
    /// full phrase behind still lands on phrase tops and would look perfect.
    public let missedPhrases: [Int]
    public let duplicatedPhrases: [Int]

    /// When the marks fall on a consistent *sub-multiple* of the phrase — every 4 bars in an
    /// 8-bar phrase, say — this is that period, in bars. Not a failure: the player is feeling
    /// a shorter phrase than the one configured, which is a different thing from losing the
    /// form and deserves to be said rather than scored down.
    public let markedEveryBars: Double?

    public let headline: String
}

public enum FormAnalysis {
    /// Analyze phrase marks against the form.
    ///
    /// - Parameters:
    ///   - markTimes: when the player marked, in seconds on the grid's timeline.
    ///   - grid: the beat grid (supplies tempo and the start of bar 0).
    ///   - beatsPerBar: 4 for 4/4.
    ///   - barsPerPhrase: phrase length, typically 8.
    ///   - totalBars: length of the take, used to count how many phrase tops existed.
    ///   - dedupeSeconds: marks closer together than this are one double-trigger.
    public static func analyze(markTimes: [Double], grid: Grid,
                               beatsPerBar: Int = 4, barsPerPhrase: Int = 8,
                               totalBars: Int, dedupeSeconds: Double = 0.15,
                               tightToleranceBeats: Double = 0.25) -> FormReport {
        let barDuration = grid.beatInterval * Double(beatsPerBar)
        let phraseDuration = barDuration * Double(barsPerPhrase)
        let phrasesAvailable = max(0, totalBars / barsPerPhrase)

        // A phrase mark is a single deliberate hit; anything within a few tens of ms is the
        // same intent double-triggering.
        var deduped: [Double] = []
        for t in markTimes.sorted() where deduped.last.map({ t - $0 > dedupeSeconds }) ?? true {
            deduped.append(t)
        }

        var marks: [PhraseMark] = []
        for t in deduped {
            let barPosition = (t - grid.startTime) / barDuration
            let phraseIndex = Int((barPosition / Double(barsPerPhrase)).rounded())
            let errorBars = barPosition - Double(phraseIndex * barsPerPhrase)
            let formError = Int(errorBars.rounded())
            let phaseErrorMs = (errorBars - Double(formError)) * barDuration * 1000
            marks.append(PhraseMark(time: t, phraseIndex: phraseIndex,
                                    formErrorBars: formError, phaseErrorMs: phaseErrorMs))
        }
        _ = phraseDuration

        let onForm = marks.filter(\.isOnForm)
        var histogram: [Int: Int] = [:]
        for m in marks { histogram[m.formErrorBars, default: 0] += 1 }

        let counts = Dictionary(grouping: marks, by: \.phraseIndex).mapValues(\.count)
        let missed = phrasesAvailable > 0
            ? (0..<phrasesAvailable).filter { counts[$0] == nil }
            : []
        let duplicated = counts.filter { $0.value > 1 }.keys.sorted()

        let slip = Stats.linearFit(x: marks.map { Double($0.phraseIndex) },
                                   y: marks.map { Double($0.formErrorBars) })?.slope

        // What period is the player actually marking? A steady half-phrase rhythm scores
        // badly against 8-bar phrases while being a perfectly consistent 4-bar feel.
        var markedEvery: Double?
        if deduped.count >= 4 {
            var gaps: [Double] = []
            for i in 1..<deduped.count { gaps.append((deduped[i] - deduped[i - 1]) / barDuration) }
            let medianGap = Stats.median(gaps)
            // Only claim a period when the marks are actually regular.
            let consistent = gaps.filter { abs($0 - medianGap) <= 0.35 * medianGap }
            if Double(consistent.count) / Double(gaps.count) >= 0.7, medianGap > 0.5 {
                markedEvery = medianGap
            }
        }

        let phaseErrors = onForm.map(\.phaseErrorMs)
        let onFormRate = marks.isEmpty ? 0 : Double(onForm.count) / Double(marks.count)
        let tightToleranceMs = tightToleranceBeats * grid.beatInterval * 1000
        let tight = onForm.filter { abs($0.phaseErrorMs) <= tightToleranceMs }.count

        return FormReport(
            marks: marks,
            phrasesAvailable: phrasesAvailable,
            marksPlaced: marks.count,
            onFormCount: onForm.count,
            onFormRate: onFormRate,
            tightCount: tight,
            tightToleranceMs: tightToleranceMs,
            formErrorHistogram: histogram,
            meanAbsFormErrorBars: marks.isEmpty ? 0
                : Stats.mean(marks.map { Double(abs($0.formErrorBars)) }),
            phaseErrorMeanMs: phaseErrors.isEmpty ? .nan : Stats.mean(phaseErrors),
            phaseErrorSDms: phaseErrors.count > 1 ? Stats.sd(phaseErrors) : .nan,
            slipBarsPerPhrase: slip,
            missedPhrases: missed,
            duplicatedPhrases: duplicated,
            markedEveryBars: markedEvery,
            headline: Self.headline(marks: marks, onFormRate: onFormRate, slip: slip,
                                    missed: missed.count, phrases: phrasesAvailable,
                                    phaseSD: phaseErrors.count > 1 ? Stats.sd(phaseErrors) : .nan,
                                    markedEvery: markedEvery, phraseBars: barsPerPhrase))
    }

    private static func headline(marks: [PhraseMark], onFormRate: Double, slip: Double?,
                                 missed: Int, phrases: Int, phaseSD: Double,
                                 markedEvery: Double?, phraseBars: Int) -> String {
        guard marks.count >= 3 else {
            return "Not enough marks to judge — hit the pad once at the top of each phrase."
        }
        // Say this before anything else: a steady shorter period is a consistent feel, not a
        // lost one, and scoring it as failure would be actively misleading.
        if let markedEvery, abs(markedEvery - Double(phraseBars)) > 1 {
            return String(format: "You marked a steady %.0f-bar phrase, not the %d-bar one set here. "
                        + "That is a consistent feel — either set the phrase to %.0f bars or "
                        + "listen for the longer arc.", markedEvery, phraseBars, markedEvery)
        }
        // A steady slip is the most useful thing to say: it means the pulse period itself is
        // off, not that attention lapsed.
        if let slip, abs(slip) > 0.25 {
            return slip > 0
                ? "You're slipping later each phrase — the form is stretching out from under you."
                : "You're slipping earlier each phrase — you're turning the corner too soon."
        }
        if onFormRate >= 0.99 {
            return phaseSD.isNaN || phaseSD > 60
                ? "You landed every phrase on the right bar. The map is solid; the placement is loose."
                : "Every phrase on the right bar, and placed cleanly. That's real form awareness."
        }
        if onFormRate >= 0.7 {
            return "Mostly on the form — you know roughly where you are, with occasional slips."
        }
        if missed > phrases / 3 {
            return "A lot of phrases went unmarked — the thread is getting lost rather than misplaced."
        }
        return "The form is slipping — you're often a bar or more from the phrase top."
    }
}
