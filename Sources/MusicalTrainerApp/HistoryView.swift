import Charts
import SwiftUI
import TrainerKit

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var kind: Kind = .jam

    enum Kind: String, CaseIterable, Identifiable {
        case jam, form, dropout, tempo
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jam: return "Jams"
            case .form: return "Form"
            case .dropout: return "Alone"
            case .tempo: return "Tempo"
            }
        }
        /// What the trend line means, so a rising line is never read the wrong way.
        var trendTitle: String {
            switch self {
            case .jam: return "Spread over time"
            case .form: return "On-form rate over time"
            case .dropout: return "Tempo bias over time"
            case .tempo: return "Tempo accuracy over time"
            }
        }
        var trendNote: String {
            switch self {
            case .jam: return "Lower is tighter."
            case .form: return "Higher is better."
            case .dropout: return "Closer to zero is a truer internal tempo."
            case .tempo: return "Lower is more accurate."
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

                List(entries.reversed()) { entry in
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
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
    }
}
