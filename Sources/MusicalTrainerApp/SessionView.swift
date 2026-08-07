import SwiftUI
import TimingCore
import TrainerKit

/// Pick a length, then read what the app proposes and why.
///
/// The reasons are not decoration. A session the app chose but cannot justify is one the
/// player has no way to disagree with — and every rule here is a guess about them that they
/// are better placed to overrule than the rules are.
struct SessionPlanView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tonight's session").font(.title2).fontWeight(.semibold)
                    Text("The app picks the drills from what your last takes measured.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back") { model.leaveSession() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            lengthPicker

            if model.sessionPlan != nil { statePicker }

            if let plan = model.sessionPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(plan.blocks.enumerated()), id: \.offset) { index, block in
                            BlockCard(number: index + 1, block: block)
                        }
                        ForEach(plan.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                footer(plan)
            } else {
                Spacer()
                Text("How long have you got?")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(24)
    }

    private var lengthPicker: some View {
        HStack(spacing: 10) {
            ForEach(AppModel.sessionLengths, id: \.self) { minutes in
                LengthButton(minutes: minutes, selected: model.sessionMinutes == minutes) {
                    model.chooseSessionLength(minutes)
                }
            }
        }
    }

    /// Asked before the plan is committed to. Afterwards it would be a way of excusing a
    /// sitting that went badly, which is a short step from dropping the takes you dislike.
    private var statePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Coming into this").font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $model.sessionState) {
                    ForEach(SessionState.allCases, id: \.self) { state in
                        Text(state.label.capitalized).tag(state)
                    }
                }
                .labelsHidden().frame(width: 160)
            }
            Text(model.sessionState.blurb)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func footer(_ plan: SessionPlan) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let env = model.environment {
                    Text(env.outputName).font(.caption).foregroundStyle(.secondary)
                    if env.calibrationMs == nil {
                        Label("not calibrated — spread and drift are still valid, bias is not",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if let error = model.environmentError {
                    Label(error, systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(durationLabel(plan.estimatedSeconds))
                .font(.title3).monospacedDigit()
            Button { model.beginSession() } label: {
                Text("Start session").frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.environment == nil)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

private struct BlockCard: View {
    let number: Int
    let block: SessionBlock

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(number).").font(.callout).monospacedDigit().foregroundStyle(.tertiary)
                    Text(block.plan.drillName).font(.headline)
                    Text(roleLabel(block.role))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    Text(durationLabel(block.estimatedSeconds))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(block.plan.settingsLabel).font(.callout).foregroundStyle(.secondary)
                Text(block.reason)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The only readable screen inside a session: what is next, why, and how to do it.
struct SessionBriefView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let block = model.sessionBlock {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(block.plan.drillName).font(.title).fontWeight(.semibold)
                                    Spacer()
                                    Text(durationLabel(block.estimatedSeconds))
                                        .font(.title3).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(block.plan.settingsLabel)
                                    .font(.callout).foregroundStyle(.secondary)
                                Text(block.reason)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        InstructionsCard(guide: DrillInstructions.forBlock(block))
                    }
                }
                footer
            }
        }
        .padding(24)
        .confirmationDialog("That block was stopped.",
                            isPresented: $model.sessionStopDecision, titleVisibility: .visible) {
            Button("Skip it and carry on") { model.skipSessionBlock() }
            Button("End the session", role: .destructive) { model.endSession(early: true) }
        } message: {
            Text("The recording was discarded. The blocks you already finished are saved.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let position = model.sessionPosition {
                    Text("Block \(position.index) of \(position.total)")
                        .font(.title2).fontWeight(.semibold)
                }
                Text("\(durationLabel(model.sessionRemainingSeconds)) left, roughly.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("End session") { model.endSession(early: true) }
        }
    }

    private var footer: some View {
        HStack {
            Text("Nothing is measured on screen until the end.")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button { model.startSessionBlock() } label: {
                Text("Start").frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}

/// Every number from the session, all at once, at the end.
struct SessionDebriefView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let summary = model.sessionSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session done").font(.title2).fontWeight(.semibold)
                        Text("\(summary.completedCount) of \(summary.plan.blocks.count) blocks · "
                           + durationLabel(summary.durationSeconds))
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if summary.endedEarly {
                        Label("Ended early — the remaining blocks weren't run.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }

                    ForEach(Array(summary.results.enumerated()), id: \.offset) { _, result in
                        ResultCard(result: result)
                    }

                    Text("Every take is saved with where it sat in the session, so a cold "
                       + "measurement and one taken twenty minutes in can be told apart later.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Done") { model.leaveSession() }
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: [])
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

private struct ResultCard: View {
    let result: SessionRunner.BlockResult

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(result.index + 1).").font(.callout).monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Text(result.block.plan.drillName).font(.headline)
                    Text(roleLabel(result.block.role))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                    if let rating = result.feelRating {
                        Text(String(repeating: "★", count: rating)).foregroundStyle(.tertiary)
                    }
                }
                if result.wasSkipped {
                    Text("Skipped — nothing recorded.").font(.callout).foregroundStyle(.tertiary)
                } else {
                    if let detail = result.outcome?.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if let headline = result.outcome?.headline {
                        Text(headline).font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Warm-up — nothing measured.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

/// The same instruction text the console prints, so a drill can never mean two things.
struct InstructionsCard: View {
    let guide: DrillInstructions

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(guide.goal)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").font(.callout).monospacedDigit()
                                .foregroundStyle(.tertiary)
                            Text(step).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !guide.pitfalls.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(guide.pitfalls, id: \.self) { pitfall in
                            Label(pitfall, systemImage: "xmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


func roleLabel(_ role: BlockRole) -> String {
    switch role {
    case .cold:      return "cold"
    case .warmUp:    return "warm-up"
    case .benchmark: return "benchmark"
    case .training:  return "training"
    case .closing:   return "playing"
    case .experiment: return "experiment"
    // Named for what it is on screen too. A block labelled "training" at a level the player
    // has not earned reads as a promotion, which is the thing the role exists to prevent.
    case .probe:     return "probe"
    }
}

/// A length choice. Two branches rather than a computed `ButtonStyle`, because the two
/// styles are different concrete types and erasing them buys nothing here.
private struct LengthButton: View {
    let minutes: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        if selected {
            Button(action: action) { label }.controlSize(.large).buttonStyle(.borderedProminent)
        } else {
            Button(action: action) { label }.controlSize(.large).buttonStyle(.bordered)
        }
    }

    private var label: some View {
        Text("\(minutes) min").frame(maxWidth: .infinity)
    }
}
