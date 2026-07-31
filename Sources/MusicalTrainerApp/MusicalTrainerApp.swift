import SwiftUI

@main
struct MusicalTrainerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Musical Trainer") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.screen {
            case .setup:   SetupView()
            case .running: TakeView()
            case .rating:  RatingView()
            case .results: ResultsView()
            case .history: HistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.25), value: model.screen)
    }
}

// MARK: - Shared pieces

/// A labelled metric with an optional interpretation underneath.
struct Metric: View {
    let label: String
    let value: String
    var note: String?
    var emphasis: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: emphasis ? 30 : 22, weight: emphasis ? .semibold : .regular,
                              design: .rounded))
                .monospacedDigit()
            if let note {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Double {
    var msLabel: String { isNaN ? "—" : String(format: "%.1f ms", self) }
    var signedMsLabel: String { isNaN ? "—" : String(format: "%+.1f ms", self) }
}

func durationLabel(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total < 60 ? "\(total)s" : String(format: "%d:%02d", total / 60, total % 60)
}
