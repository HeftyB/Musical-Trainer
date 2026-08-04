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
        var trendNote: String {
            switch self {
            case .jam: return "Lower is tighter."
            case .form: return "Higher is better."
            case .dropout: return "Closer to zero is a truer internal tempo."
            case .tempo: return "Lower is more accurate."
            case .memory: return "Lower means the period survives a filled gap."
            }
        }
    }

    private var entries: [TrainerEngine.HistoryEntry] {
        switch kind {
        case .jam: return TrainerEngine.jamHistory()
        case .form: return TrainerEngine.formHistory()
        // A drill whose split came out unreliable has no clock number to plot.
        case .dropout: return TrainerEngine.dropoutHistory().filter { $0.metric.isFinite }
        case .tempo: return TrainerEngine.tempoHistory().filter { $0.metric.isFinite }
        case .memory: return TrainerEngine.memoryHistory().filter { $0.metric.isFinite }
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

            let entries = entries
            if entries.isEmpty {
                Spacer()
                Text("Nothing here yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                // Chart, fitted trends and the take list all scroll together — the trend
                // cards vary in height with how many groups the takes fall into.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if entries.count > 2 {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(kind.trendTitle).font(.headline)
                                    Text(kind.trendNote)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Chart(entries) { entry in
                                        LineMark(x: .value("Take", entry.date),
                                                 y: .value(entry.metricLabel, entry.metric))
                                        PointMark(x: .value("Take", entry.date),
                                                  y: .value(entry.metricLabel, entry.metric))
                                    }
                                    .frame(height: 150)
                                }
                            }
                        }

                        // That chart draws one line through every take, which is only honest
                        // if the takes are comparable. The fitted trends below are grouped and
                        // carry the same confound warnings the console prints — without them
                        // the app would show a slope where the console refuses to.
                        ForEach(Array(TrainerEngine.trends(for: kind.drill).enumerated()),
                                id: \.offset) { _, series in TrendCard(series: series) }

                        WarmUpCard(report: TrainerEngine.warmUpReport(for: kind.drill))

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
            }
        }
        .padding(24)
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
                    Text("\(series.takeCount) takes")
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
