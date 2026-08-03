import SwiftUI
import TimingCore

/// The take screen. Deliberately near-blank.
///
/// No numbers, no progress bar, no elapsed time — see PLAN.md §2. Anything readable here
/// recruits exactly the analytical loop this project exists to quiet, and a progress
/// indicator during the form drill would replace the felt sense of the phrase with a visual
/// count. A slow breathing circle is the only thing on screen, and closing your eyes costs
/// you nothing.
struct TakeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var breathing = false

    /// Only the tempo drill shows anything mid-take — see `AppModel.liveRounds`.
    private var liveFeedback: some View {
        VStack(spacing: 8) {
            if model.liveRounds.isEmpty {
                Text("Hold the tempo when the click stops.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(model.liveRounds.suffix(3), id: \.index) { round in
                    if let produced = round.producedBpm, let pct = round.errorPercent {
                        HStack(spacing: 10) {
                            Text("Round \(round.index + 1)")
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.0f", produced)).monospacedDigit()
                            Text(String(format: "%+.1f%%", pct)).monospacedDigit()
                                .foregroundStyle(abs(pct) < 2 ? Color.green : Color.orange)
                        }
                        .font(.title3)
                    } else {
                        Text("Round \(round.index + 1): \(round.unusableReason ?? "not scored")")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 90, alignment: .top)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Circle()
                .fill(
                    RadialGradient(colors: [Color.accentColor.opacity(0.55),
                                            Color.accentColor.opacity(0.05)],
                                   center: .center, startRadius: 4, endRadius: 130)
                )
                .frame(width: 190, height: 190)
                .scaleEffect(breathing ? 1.0 : 0.82)
                .opacity(breathing ? 1.0 : 0.65)
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                           value: breathing)
                .onAppear { breathing = true }

            Text(model.mode == .form ? "Mark each phrase top." : "Play.")
                .font(.title3)
                .foregroundStyle(.secondary)

            if model.mode == .tempo {
                liveFeedback
            } else {
                Text("Eyes closed is fine — nothing here to read.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // A control, not a readout — it shows nothing about how the take is going, so
            // the screen stays eyes-off. Escape and ⌘. are the standard macOS cancels, and
            // both work here so you never have to find the button by sight.
            VStack(spacing: 6) {
                Button(role: .destructive) {
                    model.stopTake()
                } label: {
                    Label(model.isStopping ? "Stopping…" : "Stop and discard",
                          systemImage: "stop.fill")
                        .frame(minWidth: 190)
                }
                .controlSize(.large)
                .disabled(model.isStopping)
                .keyboardShortcut(.escape, modifiers: [])

                Text("esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⌘. as well, the other conventional cancel. Hidden so it doesn't draw a second button.
        .background {
            Button("") { model.stopTake() }
                .keyboardShortcut(".", modifiers: .command)
                .hidden()
        }
    }
}

/// Collected between the take and the results, never after.
///
/// A rating given once the numbers are visible is a rationalisation of them, not an honest
/// read of the experience — and the whole point of storing it is to find out whether the
/// player's own sense of a good take predicts the measurement.
struct RatingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Text("How did that feel?").font(.title2).fontWeight(.semibold)
                Text("Before you see any numbers.").font(.callout).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        model.submitRating(value)
                    } label: {
                        Image(systemName: value <= (hovered ?? 0) ? "star.fill" : "star")
                            .font(.system(size: 30))
                            .foregroundStyle(value <= (hovered ?? 0) ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in hovered = inside ? value : nil }
                }
            }

            HStack(spacing: 14) {
                Text("rough").font(.caption).foregroundStyle(.tertiary)
                Spacer().frame(width: 150)
                Text("in the pocket").font(.caption).foregroundStyle(.tertiary)
            }

            Button("Skip") { model.submitRating(nil) }
                .buttonStyle(.link)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
