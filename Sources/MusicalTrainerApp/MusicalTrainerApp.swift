import AppKit
import SwiftUI

/// The window size the app is laid out for: wide enough for the results charts and their
/// axis labels, tall enough that the setup screen's settings and instructions both fit
/// without scrolling.
enum WindowDefaults {
    static let size = CGSize(width: 900, height: 760)
    static let minimum = CGSize(width: 720, height: 560)

    /// Put the key window back to `size`.
    ///
    /// macOS restores the last frame you left a window at, so `defaultSize` only ever applies
    /// to a genuinely new window — which is precisely why this exists. The title bar stays
    /// where it is and the window grows or shrinks downward, the way dragging a corner
    /// behaves, so the window doesn't jump across the screen.
    @MainActor
    static func resetKeyWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: true)
    }
}

@main
struct MusicalTrainerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Musical Trainer") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: WindowDefaults.minimum.width,
                       minHeight: WindowDefaults.minimum.height)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: WindowDefaults.size.width, height: WindowDefaults.size.height)
        .commands {
            CommandGroup(after: .windowSize) {
                Button("Return to Default Size") { WindowDefaults.resetKeyWindow() }
                    .keyboardShortcut("0", modifiers: [.command, .control])
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            switch model.screen {
            case .setup:          SetupView()
            case .running:        TakeView()
            case .rating:         RatingView()
            case .results:        ResultsView()
            case .history:        HistoryView()
            case .sessionPlan:    SessionPlanView()
            case .sessionBrief:   SessionBriefView()
            case .sessionDebrief: SessionDebriefView()
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
