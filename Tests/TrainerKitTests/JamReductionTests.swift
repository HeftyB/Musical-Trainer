import XCTest
import TestSupport
@testable import TimingCore
@testable import TrainerKit

/// The host-time → seconds reduction, against a map whose answer is arithmetic.
///
/// This is the analysis half of the clock bridge — the piece that turns a `(hostTime, sample)`
/// map and a list of MIDI host times into taps on one timeline, applying the calibration
/// constant. M0's two-path rig validates the bridge against physical reality and needs hardware;
/// nothing checked the arithmetic itself, and a sign error here would bias every asynchrony the
/// app has ever reported while looking entirely plausible.
final class JamReductionTests: XCTestCase {

    private let sampleRate = 44_100.0

    /// A perfectly clock-locked device: sample = rate × seconds, no jitter.
    private func outputMap(epoch: UInt64, seconds: Double,
                           every step: Double = 0.01) -> [(hostTime: UInt64, sample: Int64)] {
        stride(from: 0.0, through: seconds, by: step).map { t in
            (hostTime: epoch &+ HostClock.ticks(seconds: t), sample: Int64(t * sampleRate))
        }
    }

    private func hostTime(_ epoch: UInt64, at seconds: Double) -> UInt64 {
        epoch &+ HostClock.ticks(seconds: seconds)
    }

    func testANoteOnTheBeatReducesToZeroAsynchrony() throws {
        let epoch = HostClock.now()
        let startSample = Int64(2.0 * sampleRate)      // groove starts at t = 2 s
        let endSample = Int64(10.0 * sampleRate)

        // One note exactly on the second beat of a 100 BPM grid: 2.0 + 0.6 s.
        let midi = [(hostTime: hostTime(epoch, at: 2.6), velocity: 90, note: 60)]
        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: outputMap(epoch: epoch, seconds: 12), midi: midi,
            grooveStartSample: startSample, grooveEndSample: endSample,
            bpm: 100, subdivisions: 4, calibrationConstantMs: 0))

        let match = Matching.match(taps: reduced.taps, to: reduced.grid)
        XCTAssertEqual(match.matched.count, 1)
        XCTAssertEqual(try XCTUnwrap(match.matched.first).asynchronyMs, 0, accuracy: 0.5)
    }

    /// The sign of the calibration constant, which is the one thing here that cannot be
    /// eyeballed and would silently bias every take.
    ///
    /// `asynchrony = (midiHostSec − clickEmitSec) − (L_midi + L_out)`: the constant shifts taps
    /// *earlier*, so a note played late by exactly the constant reads as on the beat.
    func testTheCalibrationConstantShiftsTapsEarlier() throws {
        let epoch = HostClock.now()
        let constantMs = 12.0
        let midi = [(hostTime: hostTime(epoch, at: 2.6 + constantMs / 1000),
                     velocity: 90, note: 60)]

        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: outputMap(epoch: epoch, seconds: 12), midi: midi,
            grooveStartSample: Int64(2.0 * sampleRate), grooveEndSample: Int64(10.0 * sampleRate),
            bpm: 100, subdivisions: 4, calibrationConstantMs: constantMs))

        let match = Matching.match(taps: reduced.taps, to: reduced.grid)
        XCTAssertEqual(try XCTUnwrap(match.matched.first).asynchronyMs, 0, accuracy: 0.5,
                       "a note late by exactly the constant must read as on the beat")
    }

    /// The guard band: count-in notes and a final ring-out must not become timing data.
    func testNotesOutsideTheWindowAreDropped() throws {
        let epoch = HostClock.now()
        let midi = [
            (hostTime: hostTime(epoch, at: 0.5), velocity: 90, note: 60),   // count-in
            (hostTime: hostTime(epoch, at: 5.0), velocity: 90, note: 62),   // inside
            (hostTime: hostTime(epoch, at: 11.5), velocity: 90, note: 64),  // after the end
        ]
        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: outputMap(epoch: epoch, seconds: 13), midi: midi,
            grooveStartSample: Int64(2.0 * sampleRate), grooveEndSample: Int64(10.0 * sampleRate),
            bpm: 100, subdivisions: 4, calibrationConstantMs: 0))

        XCTAssertEqual(reduced.taps.count, 1)
        XCTAssertEqual(try XCTUnwrap(reduced.taps.first).note, 62)
    }

    /// The fitted slope *is* the device's true sample rate, so a device running slightly off
    /// nominal must not smear the grid.
    func testAnOffNominalSampleRateIsAbsorbedByTheFit() throws {
        let epoch = HostClock.now()
        let trueRate = 44_144.0                                   // ~0.1% fast
        let map = stride(from: 0.0, through: 12.0, by: 0.01).map { t in
            (hostTime: epoch &+ HostClock.ticks(seconds: t), sample: Int64(t * trueRate))
        }
        let midi = [(hostTime: hostTime(epoch, at: 2.6), velocity: 90, note: 60)]

        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: map, midi: midi,
            grooveStartSample: Int64(2.0 * trueRate), grooveEndSample: Int64(10.0 * trueRate),
            bpm: 100, subdivisions: 4, calibrationConstantMs: 0))

        let match = Matching.match(taps: reduced.taps, to: reduced.grid)
        XCTAssertEqual(try XCTUnwrap(match.matched.first).asynchronyMs, 0, accuracy: 0.5)
    }

    func testAnEmptyOutputMapReducesToNothingRatherThanGuessing() {
        XCTAssertNil(JamAnalysis.reduce(
            outputMap: [], midi: [(hostTime: HostClock.now(), velocity: 90, note: 60)],
            grooveStartSample: 0, grooveEndSample: 1000, bpm: 100, subdivisions: 4,
            calibrationConstantMs: 0))
    }

    /// A planted performance survives the bridge: bias in, bias out.
    func testAPlantedBiasIsRecoveredThroughTheBridge() throws {
        let epoch = HostClock.now()
        let biasMs = -18.0
        let grooveStart = 2.0
        // 32 quarter notes at 100 BPM, each played `biasMs` early.
        let midi = (0..<32).map { beat -> (hostTime: UInt64, velocity: Int, note: Int) in
            let t = grooveStart + Double(beat) * 0.6 + biasMs / 1000
            return (hostTime: hostTime(epoch, at: t), velocity: 80, note: 60)
        }

        let reduced = try XCTUnwrap(JamAnalysis.reduce(
            outputMap: outputMap(epoch: epoch, seconds: 25), midi: midi,
            grooveStartSample: Int64(grooveStart * sampleRate),
            grooveEndSample: Int64(22.0 * sampleRate),
            bpm: 100, subdivisions: 4, calibrationConstantMs: 0))

        let report = TimingAnalysis.analyze(taps: reduced.taps, grid: reduced.grid)
        XCTAssertEqual(report.matchedCount, 32)
        XCTAssertEqual(report.meanAsynchronyMs, biasMs, accuracy: 1.0)
    }
}
