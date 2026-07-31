import XCTest
@testable import TimingCore

final class FormAnalysisTests: XCTestCase {
    // 100 BPM, 4/4 → beat 0.6 s, bar 2.4 s, 8-bar phrase 19.2 s.
    private let grid = Grid(startTime: 0, bpm: 100, subdivisions: 4)
    private let barDuration = 2.4
    private let barsPerPhrase = 8
    private let totalBars = 64          // 8 phrases

    private func markAtPhrase(_ p: Int, offsetBars: Double = 0) -> Double {
        Double(p * barsPerPhrase) * barDuration + offsetBars * barDuration
    }

    private func analyze(_ times: [Double]) -> FormReport {
        FormAnalysis.analyze(markTimes: times, grid: grid, beatsPerBar: 4,
                             barsPerPhrase: barsPerPhrase, totalBars: totalBars)
    }

    func testPerfectFormAwareness() {
        let report = analyze((0..<8).map { markAtPhrase($0) })
        XCTAssertEqual(report.marksPlaced, 8)
        XCTAssertEqual(report.onFormCount, 8)
        XCTAssertEqual(report.onFormRate, 1.0, accuracy: 1e-9)
        XCTAssertTrue(report.missedPhrases.isEmpty)
        XCTAssertEqual(report.phaseErrorMeanMs, 0, accuracy: 1e-6)
    }

    /// The core decomposition: landing crisply on the *wrong* bar is a form error with a
    /// near-zero phase error, not a big timing error.
    func testWholeBarErrorIsFormNotPhase() {
        let report = analyze([markAtPhrase(0), markAtPhrase(1, offsetBars: 1)])
        XCTAssertEqual(report.marks[1].formErrorBars, 1)
        XCTAssertEqual(report.marks[1].phaseErrorMs, 0, accuracy: 1e-6)
        XCTAssertFalse(report.marks[1].isOnForm)
    }

    /// Conversely, sloppy placement on the right bar is a phase error with no form error.
    func testSloppyPlacementIsPhaseNotForm() {
        // 80 ms late — well under half a bar, so it stays on the same bar line.
        let report = analyze([markAtPhrase(0), markAtPhrase(1) + 0.080])
        XCTAssertEqual(report.marks[1].formErrorBars, 0)
        XCTAssertEqual(report.marks[1].phaseErrorMs, 80, accuracy: 1.0)
        XCTAssertTrue(report.marks[1].isOnForm)
    }

    func testProgressiveSlipIsDetected() {
        // Drifting a bar later every couple of phrases.
        let times = (0..<8).map { markAtPhrase($0, offsetBars: Double($0) * 0.5) }
        let report = analyze(times)
        XCTAssertNotNil(report.slipBarsPerPhrase)
        XCTAssertGreaterThan(report.slipBarsPerPhrase!, 0.25)
        XCTAssertTrue(report.headline.lowercased().contains("slipping later"))
    }

    /// A player a whole phrase behind still lands on phrase tops. Nearest-phrase matching
    /// would score that perfect, so unmarked phrases must expose it.
    func testWholePhraseSlipShowsAsMissedPhrases() {
        let report = analyze((0..<7).map { markAtPhrase($0 + 1) })   // never marks phrase 0
        XCTAssertEqual(report.onFormRate, 1.0, accuracy: 1e-9)       // every mark is "on form"
        XCTAssertEqual(report.missedPhrases, [0])                    // but a phrase went unmarked
    }

    func testDoubleTriggerIsCollapsed() {
        let report = analyze([markAtPhrase(0), markAtPhrase(0) + 0.02, markAtPhrase(1)])
        XCTAssertEqual(report.marksPlaced, 2)
        XCTAssertTrue(report.duplicatedPhrases.isEmpty)
    }

    func testEarlyMarkIsNegativeFormError() {
        let report = analyze([markAtPhrase(0), markAtPhrase(2, offsetBars: -1)])
        XCTAssertEqual(report.marks[1].formErrorBars, -1)
    }

    func testSparseInputGivesHonestHeadline() {
        XCTAssertTrue(analyze([markAtPhrase(0)]).headline.lowercased().contains("not enough"))
    }
}
