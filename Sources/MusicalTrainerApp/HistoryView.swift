import Charts
import SwiftUI
import TrainerKit

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingForm = false

    private var entries: [TrainerEngine.HistoryEntry] {
        showingForm ? TrainerEngine.formHistory() : TrainerEngine.jamHistory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("History").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { model.backToSetup() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Picker("", selection: $showingForm) {
                Text("Jams").tag(false)
                Text("Form drills").tag(true)
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
                            Text(showingForm ? "On-form rate over time" : "Spread over time")
                                .font(.headline)
                            Text(showingForm ? "Higher is better." : "Lower is tighter.")
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
