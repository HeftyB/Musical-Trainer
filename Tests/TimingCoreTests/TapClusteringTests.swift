import XCTest
@testable import TimingCore

final class TapClusteringTests: XCTestCase {
    func testCollapsesAChordToOneEvent() {
        // Four notes struck within 8 ms — one chord.
        let chord = [0.0, 0.003, 0.006, 0.008].map { Tap(time: 1.0 + $0, velocity: 90) }
        let events = TapClustering.collapse(chord, windowSeconds: 0.035)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].time, 1.0 + (0.0 + 0.003 + 0.006 + 0.008) / 4, accuracy: 1e-9)
    }

    func testKeepsLoudestVelocity() {
        let chord = [Tap(time: 1.0, velocity: 60), Tap(time: 1.004, velocity: 110),
                     Tap(time: 1.007, velocity: 80)]
        let events = TapClustering.collapse(chord, windowSeconds: 0.035)
        XCTAssertEqual(events.first?.velocity, 110)
    }

    func testDoesNotMergeDistinctNotes() {
        // Eighth notes at 120 BPM are 250 ms apart — never merged.
        let run = (0..<8).map { Tap(time: Double($0) * 0.25) }
        XCTAssertEqual(TapClustering.collapse(run, windowSeconds: 0.035).count, 8)
    }

    func testArpeggioDoesNotChainIntoOneEvent() {
        // Notes 25 ms apart: each is within a window of the previous, but anchoring on the
        // group start caps a group at one window, so this becomes several events, not one.
        let arp = (0..<10).map { Tap(time: Double($0) * 0.025) }
        let events = TapClustering.collapse(arp, windowSeconds: 0.035)
        XCTAssertGreaterThan(events.count, 1)
        XCTAssertLessThan(events.count, arp.count)
    }

    func testChordDoesNotPolluteAsynchronyStats() {
        // A player dead on the beat, but every beat is a 4-note block chord spread over 6 ms.
        let grid = Grid(startTime: 0, bpm: 120, subdivisions: 1)
        var taps: [Tap] = []
        for k in 0..<32 {
            let base = grid.time(ofIndex: k)
            for offset in [0.0, 0.002, 0.004, 0.006] { taps.append(Tap(time: base + offset)) }
        }
        // Without clustering, three of four chord tones become "between beats."
        let raw = TimingAnalysis.analyze(taps: taps, grid: grid, chordWindowMs: 0)
        XCTAssertGreaterThan(raw.extraCount, 80)

        // With clustering, one event per beat and a clean, near-zero asynchrony.
        let clustered = TimingAnalysis.analyze(taps: taps, grid: grid, chordWindowMs: 35)
        XCTAssertEqual(clustered.matchedCount, 32)
        XCTAssertEqual(clustered.extraCount, 0)
        XCTAssertEqual(clustered.meanAsynchronyMs, 3.0, accuracy: 1.0)  // mean of 0..6 ms
    }
}
