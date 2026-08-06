import XCTest
@testable import GrooveCore

/// M15 step 6: the skank, and the downbeat disappearing out from under it.
final class OffbeatBackingTests: XCTestCase {

    private let offbeatSteps = [2, 6, 10, 14]

    /// The chop is the constant. Every level plays it, or the drill has nothing to hold on to.
    func testEveryLevelChopsOnEveryOffbeat() {
        for level in OffbeatLevel.allCases {
            for bar in 0..<8 {
                let pattern = OffbeatBacking.pattern(level: level, bar: bar)
                let chops = pattern.hits.filter { $0.voice == .rimshot }.map(\.step).sorted()
                XCTAssertEqual(chops, offbeatSteps, "\(level.label), bar \(bar)")
            }
        }
    }

    /// The ladder only ever removes. If a level put something back the difficulty would not be
    /// monotonic, and "ready for the next one" would stop meaning anything.
    func testEachLevelStatesNoMoreOfTheBeatThanTheOneBefore() {
        var previous: Int?
        for level in OffbeatLevel.allCases {
            let onBeat = OffbeatBacking.pattern(level: level, bar: 1).hits
                .filter { $0.step % 4 == 0 }.count
            if let previous {
                XCTAssertLessThanOrEqual(onBeat, previous, "\(level.label) put something back")
            }
            previous = onBeat
        }
    }

    func testTheHardestLevelPutsNothingOnABeatExceptThePhraseTop() {
        // Inside a phrase: nothing but the chop.
        for bar in [1, 2, 3, 5] {
            let hits = OffbeatBacking.pattern(level: .implied, bar: bar).hits
            XCTAssertTrue(hits.allSatisfy { $0.voice == .rimshot }, "bar \(bar): \(hits)")
        }
        // At the top of a phrase, one marker and nothing else.
        for bar in [0, 4, 8] {
            let onBeat = OffbeatBacking.pattern(level: .implied, bar: bar).hits
                .filter { $0.voice != .rimshot }
            XCTAssertEqual(onBeat.count, 1, "bar \(bar)")
            XCTAssertEqual(onBeat.first?.step, 0)
        }
    }

    /// **The marker is not a concession.** With nothing on a beat the player can hear their own
    /// chop as the downbeat, and once that flips every note afterwards is scored against the
    /// wrong points — the take then measures a phase error that happened in bar one. A periodic
    /// anchor bounds that to a single phrase.
    func testThePhraseMarkerCanBeTurnedOffButIsOnByDefault() {
        XCTAssertFalse(OffbeatBacking.pattern(level: .implied, bar: 0).hits
                        .allSatisfy { $0.voice == .rimshot })
        XCTAssertTrue(OffbeatBacking.pattern(level: .implied, bar: 0, phraseBars: 0).hits
                        .allSatisfy { $0.voice == .rimshot })
    }

    func testTheEasiestLevelStatesTheBeatPlainly() {
        let hits = OffbeatBacking.pattern(level: .stated, bar: 0).hits
        XCTAssertEqual(hits.filter { $0.voice == .kick }.map(\.step).sorted(), [0, 8])
        XCTAssertEqual(hits.filter { $0.voice == .snare }.map(\.step).sorted(), [4, 12])
    }

    /// Four beats to the bar at every level, or the analysis grid and the band disagree about
    /// where a bar ends.
    func testEveryLevelIsFourBeatsToTheBar() {
        for level in OffbeatLevel.allCases {
            XCTAssertEqual(OffbeatBacking.pattern(level: level, bar: 0).beatsPerBar, 4,
                           level.label)
        }
    }

    /// The chop lands exactly on the half-beat in seconds, which is what the analysis scores it
    /// against. Step indices prove nothing on their own.
    func testTheChopLandsOnTheHalfBeatInSeconds() {
        let sequencer = Sequencer(bpm: 100, sampleRate: 44_100)
        let pattern = OffbeatBacking.pattern(level: .implied, bar: 0, phraseBars: 0)
        let times = sequencer.schedule(pattern: pattern, bar: 0)
            .map { Double($0.sample) / 44_100 }.sorted()

        XCTAssertEqual(times.count, 4)
        for (got, want) in zip(times, [0.3, 0.9, 1.5, 2.1]) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }
    }

    func testABackingRunsForAsManyBarsAsAsked() {
        let backing = OffbeatBacking.backing(level: .backbeatOnly, bars: 16)
        XCTAssertEqual(backing.totalBars, 16)
        XCTAssertEqual(backing.stepsPerBeat, 4)
    }
}
