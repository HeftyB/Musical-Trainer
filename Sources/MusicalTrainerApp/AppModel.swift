import Foundation
import GrooveCore
import SwiftUI
import TrainerKit

@MainActor
final class AppModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case jam, form, dropout, tempo, groove
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jam: return "Jam"
            case .form: return "Form"
            case .dropout: return "Alone"
            case .tempo: return "Tempo"
            case .groove: return "Play"
            }
        }
        var symbol: String {
            switch self {
            case .jam: return "waveform"
            case .form: return "square.grid.3x3"
            case .dropout: return "speaker.slash"
            case .tempo: return "metronome"
            case .groove: return "play.circle"
            }
        }
        /// Full instructions, shared with the console so the two can't describe a drill
        /// differently.
        var instructions: DrillInstructions {
            switch self {
            case .jam: return .jam
            case .form: return .form
            case .dropout: return .dropout
            case .tempo: return .tempo
            case .groove: return .groove
            }
        }

        var blurb: String {
            switch self {
            case .jam: return "Play along and measure how you place the beat."
            case .form: return "Mark the top of each phrase without counting."
            case .dropout: return "Hold quarter notes through the silences — is it your clock or your hands?"
            case .tempo: return "Produce a tempo unaccompanied and find out what you actually played."
            case .groove: return "Just the backing. Nothing measured."
            }
        }
    }

    /// Rating comes between the take and the results on purpose: a rating shown after the
    /// numbers would just echo them.
    enum Screen { case setup, running, rating, results, history }

    @Published var screen: Screen = .setup
    @Published var mode: Mode = .jam { didSet { adoptDefaultLength(for: mode) } }

    @Published var bpm: Double = 100
    @Published private(set) var bars: Int = 32
    @Published var tag: String = ""
    @Published var phraseBars: Int = 8 { didSet { setBars(bars) } }
    @Published var formLevel: FormLevel = .fillAndAccent

    // Dropout drill.
    @Published var pacedBars: Int = 4
    @Published var silentBars: Int = 4
    @Published var cycles: Int = 6

    // Tempo calibration.
    @Published var tempoTargets: [Double] = [100]
    @Published var tempoRounds: Int = 8
    @Published var holdBars: Int = 4

    /// Form takes default longer than jams: at 8-bar phrases, 32 bars yields only four
    /// phrases and five marks, which is too few to tell a real slip from noise.
    private let defaultFormBars = 64

    /// Snap the take length to a sensible granularity — and in the form drill to a whole
    /// number of phrases, so the last phrase is never cut off mid-way.
    func setBars(_ value: Int) {
        let granularity = mode == .form ? phraseBars : 4
        let snapped = max(granularity, Int((Double(value) / Double(granularity)).rounded()) * granularity)
        bars = min(192, snapped)
    }

    /// Entering the form drill from a short jam length would silently give an
    /// underpowered take, so bump to the form default the first time.
    private func adoptDefaultLength(for mode: Mode) {
        if mode == .form, bars < defaultFormBars { setBars(defaultFormBars) } else { setBars(bars) }
    }

    @Published private(set) var environment: TrainerEngine.Environment?
    @Published private(set) var environmentError: String?
    @Published var errorMessage: String?

    @Published private(set) var jamOutcome: TrainerEngine.JamOutcome?
    @Published private(set) var formOutcome: TrainerEngine.FormOutcome?
    @Published private(set) var dropoutOutcome: TrainerEngine.DropoutOutcome?
    @Published private(set) var tempoOutcome: TrainerEngine.TempoOutcome?
    @Published var feelRating: Int?

    /// Set while a take is being torn down, so the button can acknowledge the press
    /// immediately rather than appearing to do nothing for a few milliseconds.
    @Published private(set) var isStopping = false
    private var cancellation: CancellationFlag?

    var canStop: Bool { screen == .running }

    /// Abandon the running take. The recording is discarded, not analysed: a take stopped
    /// because something was wrong is not worth measuring, and saving a fragment would
    /// quietly pollute the history and the pooled condition stats.
    func stopTake() {
        guard screen == .running else { return }
        isStopping = true
        cancellation?.cancel()
    }

    init() { refreshEnvironment() }

    func refreshEnvironment() {
        do {
            environment = try TrainerEngine.environment()
            environmentError = nil
        } catch {
            environment = nil
            environmentError = error.localizedDescription
        }
    }

    var estimatedDuration: Double {
        switch mode {
        case .jam:    return TrainerEngine.JamConfig(bpm: bpm, bars: bars).durationSeconds
        case .form:   return TrainerEngine.FormConfig(bpm: bpm, bars: bars, phraseBars: phraseBars,
                                                      level: formLevel).durationSeconds
        case .dropout: return dropoutConfig.durationSeconds
        case .tempo: return tempoConfig.durationSeconds
        case .groove: return TrainerEngine.GrooveConfig(bpm: bpm, bars: bars).durationSeconds
        }
    }

    var phraseCount: Int { max(1, bars / max(1, phraseBars)) }

    var tempoConfig: TrainerEngine.TempoConfig {
        TrainerEngine.TempoConfig(targets: tempoTargets, leadBars: 4,
                                  holdBars: holdBars, rounds: tempoRounds)
    }

    var dropoutConfig: TrainerEngine.DropoutConfig {
        TrainerEngine.DropoutConfig(bpm: bpm, pacedBars: pacedBars,
                                    silentBars: silentBars, cycles: cycles)
    }

    func start() {
        errorMessage = nil
        jamOutcome = nil
        formOutcome = nil
        dropoutOutcome = nil
        tempoOutcome = nil
        feelRating = nil
        isStopping = false
        let flag = CancellationFlag()
        cancellation = flag
        screen = .running

        let mode = self.mode
        let jamConfig = TrainerEngine.JamConfig(
            bpm: bpm, bars: bars,
            tag: tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag)
        let formConfig = TrainerEngine.FormConfig(bpm: bpm, bars: bars,
                                                  phraseBars: phraseBars, level: formLevel)
        let grooveConfig = TrainerEngine.GrooveConfig(bpm: bpm, bars: bars)
        let dropConfig = dropoutConfig
        let tempConfig = tempoConfig

        // The engine blocks for the length of the take, so it runs off the main thread and
        // the UI stays responsive. `self` is captured strongly: the closure runs once and
        // releases, so there is no cycle, and a weak optional cannot be referenced from
        // concurrently-executing code.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch mode {
                case .jam:
                    let outcome = try TrainerEngine.runJam(jamConfig, cancellation: flag)
                    Task { @MainActor in self.finish(jam: outcome) }
                case .form:
                    let outcome = try TrainerEngine.runForm(formConfig, cancellation: flag)
                    Task { @MainActor in self.finish(form: outcome) }
                case .dropout:
                    let outcome = try TrainerEngine.runDropout(dropConfig, cancellation: flag)
                    Task { @MainActor in self.finish(dropout: outcome) }
                case .tempo:
                    let outcome = try TrainerEngine.runTempo(tempConfig, cancellation: flag)
                    Task { @MainActor in self.finish(tempo: outcome) }
                case .groove:
                    try TrainerEngine.playGroove(grooveConfig, cancellation: flag)
                    Task { @MainActor in self.backToSetup() }
                }
            } catch is TakeCancelled {
                // Stopping on purpose is a normal outcome, not a failure to report.
                Task { @MainActor in self.backToSetup() }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    self.errorMessage = message
                    self.screen = .setup
                }
            }
        }
    }

    private func finish(jam outcome: TrainerEngine.JamOutcome) {
        jamOutcome = outcome
        screen = .rating
    }

    private func finish(form outcome: TrainerEngine.FormOutcome) {
        formOutcome = outcome
        screen = .rating
    }

    private func finish(dropout outcome: TrainerEngine.DropoutOutcome) {
        dropoutOutcome = outcome
        screen = .rating
    }

    private func finish(tempo outcome: TrainerEngine.TempoOutcome) {
        tempoOutcome = outcome
        screen = .rating
    }

    /// Store the rating and reveal the numbers.
    func submitRating(_ rating: Int?) {
        feelRating = rating
        do {
            if let outcome = jamOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = formOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = dropoutOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = tempoOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
        } catch {
            errorMessage = "Could not save the take: \(error.localizedDescription)"
        }
        screen = .results
    }

    func backToSetup() {
        isStopping = false
        cancellation = nil
        screen = .setup
        refreshEnvironment()
    }
}
