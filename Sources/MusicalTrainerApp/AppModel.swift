import Foundation
import GrooveCore
import SwiftUI
import TrainerKit

@MainActor
final class AppModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case jam, form, groove
        var id: String { rawValue }
        var title: String {
            switch self {
            case .jam: return "Jam"
            case .form: return "Form"
            case .groove: return "Play"
            }
        }
        var symbol: String {
            switch self {
            case .jam: return "waveform"
            case .form: return "square.grid.3x3"
            case .groove: return "play.circle"
            }
        }
        var blurb: String {
            switch self {
            case .jam: return "Play along and measure how you place the beat."
            case .form: return "Mark the top of each phrase without counting."
            case .groove: return "Just the backing. Nothing measured."
            }
        }
    }

    /// Rating comes between the take and the results on purpose: a rating shown after the
    /// numbers would just echo them.
    enum Screen { case setup, running, rating, results, history }

    @Published var screen: Screen = .setup
    @Published var mode: Mode = .jam { didSet { setBars(bars) } }

    @Published var bpm: Double = 100
    @Published private(set) var bars: Int = 32
    @Published var tag: String = ""
    @Published var phraseBars: Int = 8 { didSet { setBars(bars) } }
    @Published var formLevel: FormLevel = .fillAndAccent

    /// Snap the take length to a sensible granularity — and in the form drill to a whole
    /// number of phrases, so the last phrase is never cut off mid-way.
    func setBars(_ value: Int) {
        let granularity = mode == .form ? phraseBars : 4
        let snapped = max(granularity, Int((Double(value) / Double(granularity)).rounded()) * granularity)
        bars = min(192, snapped)
    }

    @Published private(set) var environment: TrainerEngine.Environment?
    @Published private(set) var environmentError: String?
    @Published var errorMessage: String?

    @Published private(set) var jamOutcome: TrainerEngine.JamOutcome?
    @Published private(set) var formOutcome: TrainerEngine.FormOutcome?
    @Published var feelRating: Int?

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
        case .groove: return TrainerEngine.GrooveConfig(bpm: bpm, bars: bars).durationSeconds
        }
    }

    var phraseCount: Int { max(1, bars / max(1, phraseBars)) }

    func start() {
        errorMessage = nil
        jamOutcome = nil
        formOutcome = nil
        feelRating = nil
        screen = .running

        let mode = self.mode
        let jamConfig = TrainerEngine.JamConfig(
            bpm: bpm, bars: bars,
            tag: tag.trimmingCharacters(in: .whitespaces).isEmpty ? nil : tag)
        let formConfig = TrainerEngine.FormConfig(bpm: bpm, bars: bars,
                                                  phraseBars: phraseBars, level: formLevel)
        let grooveConfig = TrainerEngine.GrooveConfig(bpm: bpm, bars: bars)

        // The engine blocks for the length of the take, so it runs off the main thread and
        // the UI stays responsive. `self` is captured strongly: the closure runs once and
        // releases, so there is no cycle, and a weak optional cannot be referenced from
        // concurrently-executing code.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch mode {
                case .jam:
                    let outcome = try TrainerEngine.runJam(jamConfig)
                    Task { @MainActor in self.finish(jam: outcome) }
                case .form:
                    let outcome = try TrainerEngine.runForm(formConfig)
                    Task { @MainActor in self.finish(form: outcome) }
                case .groove:
                    try TrainerEngine.playGroove(grooveConfig)
                    Task { @MainActor in self.screen = .setup }
                }
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

    /// Store the rating and reveal the numbers.
    func submitRating(_ rating: Int?) {
        feelRating = rating
        do {
            if let outcome = jamOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
            if let outcome = formOutcome { try TrainerEngine.save(outcome, feelRating: rating) }
        } catch {
            errorMessage = "Could not save the take: \(error.localizedDescription)"
        }
        screen = .results
    }

    func backToSetup() {
        screen = .setup
        refreshEnvironment()
    }
}
