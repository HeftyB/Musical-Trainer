import Charts
import SwiftUI
import TimingCore
import TrainerKit

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var kind: Kind = .jam

    enum Kind: String, CaseIterable, Identifiable {
        case jam, form, dropout, tempo, memory
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jam: return "Jams"
            case .form: return "Form"
            case .dropout: return "Alone"
            case .tempo: return "Tempo"
            case .memory: return "Recall"
            }
        }
        var drill: TrainerEngine.DrillKind {
            switch self {
            case .jam: return .jam
            case .form: return .form
            case .dropout: return .dropout
            case .tempo: return .tempo
            case .memory: return .memory
            }
        }
        /// What the trend line means, so a rising line is never read the wrong way.
        var trendTitle: String {
            switch self {
            case .jam: return "Spread over time"
            case .form: return "On-form rate over time"
            case .dropout: return "Tempo bias over time"
            case .tempo: return "Tempo accuracy over time"
            case .memory: return "Interference cost over time"
            }
        }
        /// Which way is better, and — for the form drill — that this is one of two axes.
        ///
        /// The chart can follow one number and the form drill has two peers, so it says which one
        /// it is drawing rather than letting "the form number" mean whichever is plotted. The
        /// other axis is fitted in the card below, with an interval, which is where the question
        /// "is this improving" is actually answered.
        var trendNote: String {
            switch self {
            case .jam: return "Lower is tighter. One line per comparable group."
            case .form: return "Higher is better. This is the spatial axis — knowing which bar the "
                             + "phrase turns on. The temporal one, landing cleanly, is fitted below."
            // The line is **signed** — above the rule you played fast alone, below it slow — and
            // the fit beneath the chart is on the distance from zero. Saying so is the point: a
            // line descending through zero is improving until it crosses and worsening after,
            // while its own slope never changes sign. The signed value is worth keeping because
            // rushing and dragging are different faults with different work behind them, and
            // taking the absolute value throws that away before the player ever sees it.
            case .dropout: return "Closer to the line is a truer internal tempo — above it you "
                                + "played fast alone, below it slow. The fit below is on the "
                                + "distance from zero, so it does not care which."
            case .tempo: return "Lower is more accurate."
            case .memory: return "Lower means the period survives a filled gap."
            }
        }

        /// Whether zero is the target, and so worth drawing.
        ///
        /// Only where the metric is signed and the goal is to sit on it. A spread or an error
        /// percentage cannot be negative, so a rule at zero would be a line along the axis.
        var marksZero: Bool { self == .dropout }
    }

    /// What this screen shows, loaded once per drill rather than rebuilt while drawing.
    ///
    /// It used to be a computed property, so every readout on the screen re-derived it and every
    /// re-derivation re-analysed the whole corpus from raw taps — about 180 analyses and four
    /// decodes of the store, on the main thread, per visit. That is the History lag (§7.54). The
    /// work is unchanged; where it happens is not.
    @State private var payload: TrainerEngine.HistoryPayload?
    @State private var isLoading = false

    private func load(_ kind: Kind) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = TrainerEngine.historyPayload(for: kind.drill)
            DispatchQueue.main.async {
                payload = loaded
                isLoading = false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("History").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { model.backToSetup() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let payload, !payload.entries.isEmpty {
                let entries = payload.entries
                // Chart, fitted trends and the take list all scroll together — the trend
                // cards vary in height with how many groups the takes fall into.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        let chartable = payload.chart
                        if !chartable.entries.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(kind.trendTitle).font(.headline)
                                    Text(kind.trendNote)
                                        .font(.caption).foregroundStyle(.secondary)
                                    // **One line per comparable group, not one through all of
                                    // them.** `HistoryEntry.group` is the title of the trend
                                    // series each take contributes to, so the line a reader
                                    // follows here is the line fitted in the card below it.
                                    //
                                    // It used to be a single series over every take of a drill.
                                    // For jams that put an offbeat take's 48.4 ms spread — the
                                    // widest on record and a different task — on one line with
                                    // 21 free jams, beside a swung take, at four tempos and two
                                    // backings. §7.24 step 8 retracted a verdict built the same
                                    // way, and §7.27 retracted two more; the cards were split for
                                    // exactly that reason while the picture above them was not
                                    // (`LESSONS.md` shape 19).
                                    Chart(chartable.entries) { entry in
                                        if kind.marksZero {
                                            RuleMark(y: .value("On tempo", 0))
                                                .foregroundStyle(.secondary.opacity(0.5))
                                        }
                                        LineMark(x: .value("Take", entry.date),
                                                 y: .value(entry.metricLabel, entry.metric),
                                                 series: .value("Group", entry.group))
                                        .foregroundStyle(by: .value("Group", entry.group))
                                        PointMark(x: .value("Take", entry.date),
                                                  y: .value(entry.metricLabel, entry.metric))
                                        .foregroundStyle(by: .value("Group", entry.group))
                                    }
                                    .chartLegend(position: .bottom, alignment: .leading)
                                    .frame(height: 190)

                                    // R3.3: what is missing is said, not silently absent. Every
                                    // one of these takes is in the list further down.
                                    if chartable.omittedTakes > 0 {
                                        Text("\(chartable.omittedTakes) take(s) in "
                                           + "\(chartable.omittedGroups) group(s) of fewer than "
                                           + "\(TrendAnalysis.minimumPoints) are not drawn — a "
                                           + "line through one or two takes is not a trend. They "
                                           + "are all in the list below.")
                                            .font(.caption).foregroundStyle(.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        // The fitted trends carry the same confound warnings the console prints —
                        // without them the app would show a slope where the console refuses to.
                        ForEach(Array(payload.trends.enumerated()),
                                id: \.offset) { _, series in TrendCard(series: series) }

                        WarmUpCard(report: payload.warmUp)

                        // The experiment readout, on the surface where sessions are actually
                        // run. It lived only in the console until now (§7.20 finding 9), which
                        // for M13 would have meant a milestone whose whole output the player
                        // never saw where they practise.
                        ForEach(payload.experiments, id: \.design.name) {
                            ExperimentCard(result: $0)
                        }

                        ForEach(entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(entry.title).fontWeight(.medium)
                                    Spacer()
                                    if let rating = entry.feelRating {
                                        Text(String(repeating: "★", count: rating))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                                Text(entry.headline).font(.caption).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                            Divider()
                        }
                    }
                }
            } else {
                Spacer()
                // The empty state and the loading state are different sentences. A history that
                // takes two seconds to analyse must not read as a history with nothing in it.
                Text(isLoading ? "Reading your history…" : "Nothing here yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(24)
        .task(id: kind) { load(kind) }
    }
}

/// One fitted trend group: the slope per take with its 95% interval, and any reason the
/// group isn't comparable in the first place.
private struct TrendCard: View {
    let series: TrendSeries

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(series.title).font(.headline)
                    Text(series.takeCountLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }

                ForEach(series.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(Array(series.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        Text(row.label)
                            .font(.callout).frame(width: 120, alignment: .leading)
                        if let fit = row.fit {
                            Text(String(format: "%+.2f/take", fit.slope))
                                .font(.callout).monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            Text(String(format: "[%+.2f, %+.2f]", fit.low, fit.high))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .trailing)
                            Text(word(fit.verdict))
                                .font(.callout).foregroundStyle(colour(fit.verdict))
                        } else {
                            Text("\(row.values.count) usable point(s) — need \(TrendAnalysis.minimumPoints)")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }

                Text("Slope is change per take with a 95% interval. \"Flat\" means the interval "
                   + "includes zero — usually the honest answer at this many takes.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func word(_ verdict: TrendVerdict) -> String {
        switch verdict {
        case .improving: return "improving"
        case .worsening: return "worsening"
        case .flat:      return "flat"
        }
    }

    private func colour(_ verdict: TrendVerdict) -> Color {
        switch verdict {
        case .improving: return .green
        case .worsening: return .orange
        case .flat:      return .secondary
        }
    }
}

/// M10. Improvement inside one evening is warming up; improvement in the *cold* take across
/// evenings is learning. Only the second survives a night's sleep, and the single slope in the
/// card above cannot tell them apart because it confounds when in the evening a take was
/// played with which evening it was.
private struct WarmUpCard: View {
    let report: WarmUpReport

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Warming up, or getting better?").font(.headline)
                    Text("\(report.takeCount) takes · \(report.sessionCount) sitting(s)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                row("within a sitting", report.withinSession, unit: "/min")
                row("cold, per sitting", report.betweenSessions, unit: "/sitting")

                Text(report.headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(report.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ fit: TrendFit?, unit: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.callout).frame(width: 140, alignment: .leading)
            if let fit {
                Text(String(format: "%+.3f%@", fit.slope, unit))
                    .font(.callout).monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
                Text(String(format: "[%+.3f, %+.3f]", fit.low, fit.high))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .trailing)
                Text(word(fit.verdict)).font(.callout).foregroundStyle(colour(fit.verdict))
            } else {
                Text("not enough data").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func word(_ verdict: TrendVerdict) -> String {
        switch verdict {
        case .improving: return "improving"
        case .worsening: return "worsening"
        case .flat:      return "flat"
        }
    }

    private func colour(_ verdict: TrendVerdict) -> Color {
        switch verdict {
        case .improving: return .green
        case .worsening: return .orange
        case .flat:      return .secondary
        }
    }
}

/// One experiment: what each arm has collected, and what may be said about it.
///
/// Mirrors `review experiment` line for line. R3.4 says both surfaces warn identically, and an
/// experiment readout that was blunter on one of them would be the same defect as a drill whose
/// instructions differ by surface.
private struct ExperimentCard: View {
    let result: ExperimentResult

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.design.name).font(.headline)
                    Text("\(result.design.metric.label) · \(result.design.takesPerArm) per arm")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(result.design.question)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(result.arms, id: \.arm) { arm in
                    HStack(spacing: 12) {
                        Text(arm.arm).frame(width: 90, alignment: .leading)
                        Text("\(arm.scored)/\(result.design.takesPerArm)")
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                        Text(arm.mean.map { String(format: "%+.2f", $0) } ?? "—")
                            .monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text(arm.betweenTakeSD.map { String(format: "± %.2f", $0) } ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                        // Mirrors the console exactly (R3.4). A covariate, never scored: for an
                        // instruction-only experiment the arms differ in density by design.
                        Text(arm.meanNotesPerBeat.map { String(format: "%.2f/beat", $0) } ?? "—")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.callout)
                }

                // No number appears here until the experiment has its preregistered takes. A
                // running tally on screen would bias the takes still to come, in a project whose
                // first principle is that watching the number changes the playing.
                if case .collecting = result.verdict {
                    Text(result.headline).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let d = result.difference {
                        Text(String(format: "%+.2f [%+.2f, %+.2f]", d.point, d.low, d.high))
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(d.excludesZero ? .primary : .secondary)
                    }
                    Text(result.headline).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(result.notes, id: \.self) { note in
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
