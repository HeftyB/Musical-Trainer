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
