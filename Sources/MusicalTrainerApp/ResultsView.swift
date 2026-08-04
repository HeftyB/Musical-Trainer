import Charts
import SwiftUI
import TimingCore
import TrainerKit

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let outcome = model.jamOutcome {
                    JamResults(outcome: outcome)
                } else if let outcome = model.formOutcome {
                    FormResults(outcome: outcome)
                } else if let outcome = model.dropoutOutcome {
                    DropoutResults(outcome: outcome)
                } else if let outcome = model.tempoOutcome {
                    TempoResults(outcome: outcome)
                } else if let outcome = model.memoryOutcome {
                    MemoryResults(outcome: outcome)
                }

                HStack {
                    Button("Done") { model.backToSetup() }
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Again") { model.start() }
                        .controlSize(.large)
                    Spacer()
                    Button { model.screen = .history } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Jam

private struct JamResults: View {
    let outcome: TrainerEngine.JamOutcome
    private var report: TimingReport { outcome.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(outcome.notesCaptured) notes → \(outcome.eventCount) events · "
               + "\(report.matchedCount) on the grid")
                .font(.callout).foregroundStyle(.secondary)

            Card {
                HStack(alignment: .top, spacing: 24) {
                    Metric(label: outcome.report.meanAsynchronyMs < 0 ? "Rushing" : "Dragging",
                           value: report.meanAsynchronyMs.signedMsLabel,
                           note: outcome.environment.isCalibrated ? "bias" : "uncalibrated",
                           emphasis: true)
                    Metric(label: "Spread", value: report.sdAsynchronyMs.msLabel,
                           note: precisionWord(report.sdAsynchronyMs), emphasis: true)
                    if let r = report.lag1Autocorrelation {
                        Metric(label: "Correction", value: String(format: "%+.2f", r),
                               note: correctionWord(r), emphasis: true)
                    }
                }
            }

            if report.asynchroniesMs.count > 3 {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Placement over the take").font(.headline)
                        Text("Each dot is one note. Above the line is late, below is early.")
                            .font(.caption).foregroundStyle(.secondary)
                        Chart {
                            RuleMark(y: .value("On the beat", 0))
                                .foregroundStyle(.secondary.opacity(0.5))
                            ForEach(Array(report.asynchroniesMs.enumerated()), id: \.offset) { index, value in
                                PointMark(x: .value("Event", index), y: .value("Error", value))
                                    .foregroundStyle(abs(value) <= 15 ? Color.accentColor : Color.orange)
                                    .symbolSize(28)
                            }
                        }
                        .chartYAxisLabel("ms")
                        .chartXAxisLabel("event")
                        .frame(height: 190)
                    }
                }
            }

            if let drift = report.driftMsPerBeat, let bpmError = report.effectiveBpmError {
                Card {
                    Metric(label: "Tempo drift",
                           value: String(format: "%+.2f ms/beat", drift),
                           note: String(format: "≈ %+.1f BPM over the take", bpmError))
                }
            }
        }
    }

    private func precisionWord(_ sd: Double) -> String {
        switch sd {
        case ..<8: return "tight"
        case ..<15: return "solid"
        case ..<25: return "loose"
        default: return "wide"
        }
    }

    private func correctionWord(_ r: Double) -> String {
        if r < -0.3 { return "chasing the click" }
        if r > 0.3 { return "drifting, uncorrected" }
        return "autonomous pulse"
    }
}

// MARK: - Tempo calibration

private struct TempoResults: View {
    let outcome: TrainerEngine.TempoOutcome
    private var report: TempoCalibrationReport { outcome.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(report.usableCount)/\(report.rounds.count) rounds scored")
                .font(.callout).foregroundStyle(.secondary)

            summary
            roundChart
            roundList
        }
    }

    private var summary: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                if let bias = report.meanErrorPercent {
                    Metric(label: "Bias", value: String(format: "%+.1f%%", bias),
                           note: bias < 0 ? "you run slow" : "you run fast", emphasis: true)
                }
                if let accuracy = report.meanAbsErrorPercent {
                    Metric(label: "Accuracy", value: String(format: "%.1f%%", accuracy),
                           note: "average error", emphasis: true)
                }
                if let slope = report.improvementPerRound {
                    Metric(label: "Trend", value: String(format: "%+.2f%%", slope),
                           note: slope < -0.3 ? "tightening" : slope > 0.3 ? "loosening" : "steady",
                           emphasis: true)
                }
            }
        }
    }

    @ViewBuilder
    private var roundChart: some View {
        let scored = report.rounds.filter { $0.isUsable }
        if scored.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Round by round").font(.headline)
                    Text("How far off you were each time. The line is dead on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart {
                        RuleMark(y: .value("On target", 0))
                            .foregroundStyle(.secondary.opacity(0.6))
                        ForEach(scored, id: \.index) { round in
                            BarMark(x: .value("Round", round.index + 1),
                                    y: .value("Error %", round.errorPercent ?? 0))
                                .foregroundStyle(abs(round.errorPercent ?? 0) < 2
                                                 ? Color.accentColor : Color.orange)
                        }
                    }
                    .chartYAxisLabel("error (%)")
                    .chartXAxisLabel("round")
                    .frame(height: 160)
                }
            }
        }
    }

    private var roundList: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.rounds, id: \.index) { round in
                    HStack {
                        Text("Round \(round.index + 1)").frame(width: 90, alignment: .leading)
                        Text("\(Int(round.targetBpm)) BPM").foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        if round.isUsable, let produced = round.producedBpm, let pct = round.errorPercent {
                            Text(String(format: "%.1f", produced)).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Text(String(format: "%+.1f%%", pct)).monospacedDigit()
                                .foregroundStyle(abs(pct) < 2 ? Color.green : Color.orange)
                                .frame(width: 70, alignment: .trailing)
                        } else {
                            Text(round.unusableReason ?? "not scored")
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Dropout

private struct DropoutResults: View {
    let outcome: TrainerEngine.DropoutOutcome
    private var report: DropoutReport { outcome.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(outcome.notesPlayed) notes · \(report.unpacedNoteCount) played alone across "
               + "\(report.trials.count - report.discardedTrials)/\(report.trials.count) usable silences")
                .font(.callout).foregroundStyle(.secondary)

            if report.discardedTrials > 0 { discardedNotice }
            tempoCard
            splitSection
            perSilenceChart
            suggestion
        }
    }

    private var discardedNotice: some View {
        Card {
            Label("\(report.discardedTrials) silence(s) discarded — they weren't one note per "
                + "beat. Keep to steady quarters, no subdividing.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tempo leads: it is the most reliably measured quantity here and the most actionable.
    private var tempoCard: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                if let played = report.playedBpm, let bias = report.tempoBiasBpm {
                    Metric(label: "Tempo alone", value: String(format: "%.0f BPM", played),
                           note: String(format: "%+.0f vs the click", bias), emphasis: true)
                }
                if !report.unpacedIntervalSDms.isNaN {
                    Metric(label: "Beat to beat", value: report.unpacedIntervalSDms.msLabel,
                           note: "spread while alone", emphasis: true)
                }
                if !report.reentryErrorMeanMs.isNaN {
                    Metric(label: "Re-entry", value: report.reentryErrorMeanMs.signedMsLabel,
                           note: "when the band returned", emphasis: true)
                }
            }
        }
    }

    @ViewBuilder
    private var splitSection: some View {
        if let wk = report.wingKristofferson, report.splitIsReliable {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        Metric(label: "Clock", value: wk.clockSDms.msLabel,
                               note: "the pulse in your head", emphasis: true)
                        Metric(label: "Motor", value: wk.motorSDms.msLabel,
                               note: "your hands executing it", emphasis: true)
                    }
                    Chart {
                        BarMark(x: .value("ms", wk.clockSDms), y: .value("Source", "Clock"))
                            .foregroundStyle(Color.accentColor)
                        BarMark(x: .value("ms", wk.motorSDms), y: .value("Source", "Motor"))
                            .foregroundStyle(Color.orange)
                    }
                    .chartXAxisLabel("standard deviation (ms)")
                    .frame(height: 90)
                    Text("From \(wk.intervalCount) intervals. Whichever is larger is where the work is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Card {
                Label("The clock/motor split isn't trustworthy from this take. It needs several "
                    + "silences of steady quarter notes with no systematic speed change — a motor "
                    + "estimate near zero means the model hit its floor rather than measuring you.",
                      systemImage: "questionmark.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var perSilenceChart: some View {
        let usable = report.trials.filter { $0.isIsochronous && $0.medianIntervalMs > 0 }
        if usable.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tempo in each silence").font(.headline)
                    Text("The line is the click's tempo. Below it means you settled slower.")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart {
                        RuleMark(y: .value("Click", outcome.config.bpm))
                            .foregroundStyle(.secondary.opacity(0.6))
                        ForEach(usable, id: \.index) { trial in
                            let bpm = 60_000 / trial.medianIntervalMs
                            PointMark(x: .value("Silence", trial.index + 1),
                                      y: .value("BPM", bpm))
                                .foregroundStyle(abs(bpm - outcome.config.bpm) < 2
                                                 ? Color.accentColor : Color.orange)
                                .symbolSize(90)
                        }
                    }
                    .chartYAxisLabel("BPM")
                    .chartXAxisLabel("silence")
                    .frame(height: 160)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestion: some View {
        if outcome.suggestedSilentBars != outcome.config.silentBars {
            let longer = outcome.suggestedSilentBars > outcome.config.silentBars
            Card {
                Label(longer
                      ? "You held that comfortably — try \(outcome.suggestedSilentBars) bars alone next."
                      : "That was slipping away — try \(outcome.suggestedSilentBars) bars alone next.",
                      systemImage: longer ? "arrow.up.circle" : "arrow.down.circle")
                    .font(.callout)
            }
        }
    }
}

// MARK: - Form

private struct FormResults: View {
    let outcome: TrainerEngine.FormOutcome
    private var report: FormReport { outcome.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(report.phrasesAvailable) phrases · \(report.marksPlaced) marks · "
               + "level \(outcome.config.level.rawValue)")
                .font(.callout).foregroundStyle(.secondary)

            Card {
                HStack(alignment: .top, spacing: 24) {
                    Metric(label: "On the right bar",
                           value: "\(report.onFormCount)/\(report.marksPlaced)",
                           note: "form sense", emphasis: true)
                    Metric(label: "Nailed it",
                           value: "\(report.tightCount)/\(report.marksPlaced)",
                           note: "within \(Int(report.tightToleranceMs)) ms", emphasis: true)
                    if !report.phaseErrorMeanMs.isNaN {
                        Metric(label: "Placement",
                               value: report.phaseErrorMeanMs.signedMsLabel,
                               note: reactionNote, emphasis: true)
                    }
                }
            }

            if !report.marks.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Every mark").font(.headline)
                        Text("Bars away from the phrase top. On the line is dead right.")
                            .font(.caption).foregroundStyle(.secondary)
                        Chart {
                            RuleMark(y: .value("Phrase top", 0))
                                .foregroundStyle(.secondary.opacity(0.5))
                            ForEach(Array(report.marks.enumerated()), id: \.offset) { _, mark in
                                PointMark(x: .value("Phrase", mark.phraseIndex),
                                          y: .value("Bars off", mark.formErrorBars))
                                    .foregroundStyle(mark.isOnForm ? Color.accentColor : Color.orange)
                                    .symbolSize(90)
                            }
                        }
                        .chartYAxisLabel("bars off")
                        .chartXAxisLabel("phrase")
                        .frame(height: 170)
                    }
                }
            }

            if !report.missedPhrases.isEmpty || !report.duplicatedPhrases.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        if !report.missedPhrases.isEmpty {
                            Label("Unmarked phrases: "
                                  + report.missedPhrases.map(String.init).joined(separator: ", "),
                                  systemImage: "questionmark.circle")
                                .font(.callout)
                        }
                        if !report.duplicatedPhrases.isEmpty {
                            Label("Marked twice: "
                                  + report.duplicatedPhrases.map(String.init).joined(separator: ", "),
                                  systemImage: "plus.circle")
                                .font(.callout)
                        }
                        Text("Extra or missing marks can mean the thread slipped by a whole phrase — "
                           + "landing on phrase tops alone would still look perfect.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let slip = report.slipBarsPerPhrase, abs(slip) > 0.05 {
                Card {
                    Metric(label: "Slip", value: String(format: "%+.2f bars per phrase", slip),
                           note: slip > 0 ? "the form stretches out as you go"
                                          : "you turn the corner early")
                }
            }
        }
    }

    /// At level 0 a crash lands on the marked downbeat, so a consistently late mark means
    /// the cue is being reacted to rather than anticipated.
    private var reactionNote: String? {
        guard outcome.config.level.hasArrivalAccent else { return "from the bar line" }
        return report.phaseErrorMeanMs > 120 ? "reacting to the crash" : "arriving with it"
    }
}


// MARK: - Recall (tempo memory)

private struct MemoryResults: View {
    let outcome: TrainerEngine.MemoryOutcome
    private var report: TempoMemoryReport { outcome.report }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(report.headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(report.usableCount)/\(report.rounds.count) rounds scored · "
               + "\(outcome.config.retentionBars)-bar wait")
                .font(.callout).foregroundStyle(.secondary)

            summary
            comparisonChart
            roundList

            ForEach(report.notes, id: \.self) { note in
                Card {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if outcome.suggestedRetentionBars != outcome.config.retentionBars {
                let longer = outcome.suggestedRetentionBars > outcome.config.retentionBars
                Card {
                    Label(longer
                          ? "Your clock is steady enough for a longer gap — try \(outcome.suggestedRetentionBars) bars next."
                          : "Try a shorter \(outcome.suggestedRetentionBars)-bar wait so more rounds come through.",
                          systemImage: longer ? "arrow.up.circle" : "arrow.down.circle")
                        .font(.callout)
                }
            }
        }
    }

    private var summary: some View {
        Card {
            HStack(alignment: .top, spacing: 24) {
                if let silent = report.silentMeanAbsErrorPercent {
                    Metric(label: "After silence", value: String(format: "%.1f%%", silent),
                           note: "nothing in the gap", emphasis: true)
                }
                if let filled = report.filledMeanAbsErrorPercent {
                    Metric(label: "After interference", value: String(format: "%.1f%%", filled),
                           note: "distractor in the gap", emphasis: true)
                }
                if let cost = report.interferenceCost {
                    Metric(label: "Cost", value: String(format: "%+.1f", cost),
                           note: report.interferenceInterval.map {
                               $0.excludesZero ? "real" : "within noise" } ?? "too few rounds",
                           emphasis: true)
                }
            }
        }
    }

    @ViewBuilder
    private var comparisonChart: some View {
        let scored = report.rounds.filter(\.isUsable)
        if scored.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Every round").font(.headline)
                    Text("How far off you were. Blue waits were silent, orange ones were filled.")
                        .font(.caption).foregroundStyle(.secondary)
                    Chart {
                        RuleMark(y: .value("On target", 0))
                            .foregroundStyle(.secondary.opacity(0.6))
                        ForEach(scored, id: \.index) { round in
                            BarMark(x: .value("Round", round.index + 1),
                                    y: .value("Error %", round.errorPercent ?? 0))
                                .foregroundStyle(round.condition == .silent
                                                 ? Color.accentColor : Color.orange)
                        }
                    }
                    .chartYAxisLabel("error (%)")
                    .chartXAxisLabel("round")
                    .frame(height: 160)
                }
            }
        }
    }

    private var roundList: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.rounds, id: \.index) { round in
                    HStack {
                        Text("Round \(round.index + 1)").frame(width: 90, alignment: .leading)
                        Text(round.condition == .silent ? "silent" : "filled")
                            .foregroundStyle(round.condition == .silent ? Color.accentColor : Color.orange)
                            .frame(width: 70, alignment: .leading)
                        if round.isUsable, let produced = round.producedBpm,
                           let pct = round.errorPercent {
                            Text(String(format: "%.1f", produced)).monospacedDigit()
                                .frame(width: 70, alignment: .trailing)
                            Text(String(format: "%+.1f%%", pct)).monospacedDigit()
                                .foregroundStyle(abs(pct) < 2 ? Color.green : Color.orange)
                                .frame(width: 70, alignment: .trailing)
                        } else {
                            Text(round.unusableReason ?? "not scored").foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .font(.callout)
                }
            }
        }
    }
}
