import GrooveCore
import SwiftUI
import TrainerKit

struct SetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            modePicker
            // Settings plus instructions can exceed a short window, so they scroll while the
            // footer — device status and the Start button — stays put.
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settings
                    instructions
                }
            }
            footer
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Musical Trainer").font(.title2).fontWeight(.semibold)
                Text(model.mode.blurb).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.screen = .history } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $model.mode) {
            ForEach(AppModel.Mode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var settings: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                // Sliders snap through their bindings rather than via `step:`, which draws a
                // tick for every increment — dozens of them across these ranges.
                if model.mode != .tempo {
                    LabeledContent("Tempo") {
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { model.bpm },
                                              set: { model.bpm = $0.rounded() }),
                               in: 60...180)
                        Text("\(Int(model.bpm)) BPM")
                            .monospacedDigit().frame(width: 74, alignment: .trailing)
                    }
                    }
                }

                // The dropout drill's length comes from its own cycle controls below.
                if model.mode != .dropout && model.mode != .tempo {
                    LabeledContent("Length") {
                        HStack(spacing: 12) {
                            Slider(value: Binding(get: { Double(model.bars) },
                                                  set: { model.setBars(Int($0)) }),
                                   in: 8...192)
                            Text("\(model.bars) bars")
                                .monospacedDigit().frame(width: 74, alignment: .trailing)
                        }
                    }
                }

                if model.mode == .form {
                    Divider()
                    LabeledContent("Phrase") {
                        Picker("", selection: $model.phraseBars) {
                            ForEach([4, 8, 16, 32], id: \.self) { Text("\($0) bars").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    LabeledContent("Landmarks") {
                        Picker("", selection: $model.formLevel) {
                            ForEach(FormLevel.allCases, id: \.self) { level in
                                Text("\(level.rawValue) — \(level.label)").tag(level)
                            }
                        }
                        .labelsHidden()
                    }
                    Text(model.formLevel.advice)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.mode == .tempo {
                    Divider()
                    LabeledContent("Targets") {
                        Picker("", selection: Binding(
                            get: { model.tempoTargets },
                            set: { model.tempoTargets = $0 })) {
                            Text("100 only").tag([100.0])
                            Text("76 / 100 / 132").tag([76.0, 100.0, 132.0])
                            Text("60 / 90 / 120 / 150").tag([60.0, 90.0, 120.0, 150.0])
                        }
                        .labelsHidden().frame(width: 200)
                    }
                    LabeledContent("Hold") {
                        Picker("", selection: $model.holdBars) {
                            ForEach([2, 4, 8], id: \.self) { Text("\($0) bars").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    LabeledContent("Rounds") {
                        Picker("", selection: $model.tempoRounds) {
                            ForEach([4, 8, 12, 16], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    Text("Rotating the target trains the mapping from a tempo to a period, "
                       + "rather than memorising one number.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.mode == .dropout {
                    Divider()
                    LabeledContent("With the band") {
                        Picker("", selection: $model.pacedBars) {
                            ForEach([2, 4, 8], id: \.self) { Text("\($0) bars").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    LabeledContent("Alone") {
                        Picker("", selection: $model.silentBars) {
                            ForEach([2, 4, 8, 16], id: \.self) { Text("\($0) bars").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    LabeledContent("Repeats") {
                        Picker("", selection: $model.cycles) {
                            ForEach([4, 6, 8, 12], id: \.self) { Text("\($0)×").tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    Text("Play one note per beat the whole way through, especially when the band "
                       + "drops out — the silences are the measurement.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.mode == .jam {
                    Divider()
                    LabeledContent("Condition") {
                        TextField("relaxed, focused, …", text: $model.tag)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Tag the state you played in, so takes can be pooled and compared.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The same text the console prints — so anyone opening the app knows exactly what the
    /// drill expects without having to be told.
    private var instructions: some View {
        let guide = model.mode.instructions
        return Card {
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    if let env = model.environment {
                        Text(env.outputName).font(.caption).foregroundStyle(.secondary)
                        if let ms = env.calibrationMs, let source = env.calibrationSource {
                            Label("calibrated \(ms.msLabel) — \(source)", systemImage: "checkmark.seal")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            // Not fatal: only the bias is affected, so say exactly that
                            // rather than blocking a practice session.
                            Label("not calibrated — spread and drift are still valid, bias is not",
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if let error = model.environmentError {
                        Label(error, systemImage: "speaker.slash")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(durationLabel(model.estimatedDuration))
                        .font(.title3).monospacedDigit()
                    if model.mode == .form {
                        Text("\(model.phraseCount) phrases").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Wrapped in a closure rather than passed as `action: model.start`, which would
            // strip the @MainActor annotation off the function value.
            Button { model.start() } label: {
                Text(model.mode == .groove ? "Play" : "Start take")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.environment == nil)
            .keyboardShortcut(.return, modifiers: [])
        }
    }
}
