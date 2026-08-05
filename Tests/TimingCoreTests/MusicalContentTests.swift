import XCTest
@testable import TimingCore

final class MusicalContentTests: XCTestCase {

    private let beat = 0.6      // 100 BPM

    private func notes(_ spec: [(Double, Int)], velocity: Int = 80) -> [PlayedNote] {
        spec.map { PlayedNote(time: $0.0, note: $0.1, velocity: velocity) }
    }

    /// One repeated note, one per beat, over `beats` beats.
    private func metronomic(beats: Int, note: Int = 60, velocity: Int = 80) -> [PlayedNote] {
        (0..<beats).map { PlayedNote(time: Double($0) * beat, note: note, velocity: velocity) }
    }

    // MARK: - Measures

    /// The floor case the whole milestone is contrasted against: one note, one per beat,
    /// same velocity. Every content measure should read as flat as it is.
    func testARepeatedNoteScoresAsMinimallyInteresting() {
        let m = MusicalContentAnalysis.measures(of: metronomic(beats: 16), overBeats: 16)

        XCTAssertEqual(m.noteCount, 16)
        XCTAssertEqual(m.eventsPerBeat, 1, accuracy: 1e-9)
        XCTAssertEqual(m.pitchClassCount, 1)
        XCTAssertEqual(m.pitchEntropyBits, 0, accuracy: 1e-9)
        XCTAssertEqual(m.meanIntervalSemitones, 0, accuracy: 1e-9)
        XCTAssertEqual(m.contourReversalRate, 0, accuracy: 1e-9)
        XCTAssertEqual(m.meanChordSize, 1, accuracy: 1e-9)
        XCTAssertEqual(m.velocitySD, 0, accuracy: 1e-9)
        XCTAssertLessThan(m.interest, 0.05)
    }

    func testAMelodyScoresFarAboveARepeatedNote() {
        // An up-and-down line over an octave, with dynamics.
        let line = [60, 64, 67, 72, 67, 64, 62, 65, 69, 72, 69, 65]
        let melody = line.enumerated().map {
            PlayedNote(time: Double($0.offset) * beat, note: $0.element,
                       velocity: 60 + ($0.offset % 4) * 15)
        }
        let m = MusicalContentAnalysis.measures(of: melody, overBeats: 12)
        let flat = MusicalContentAnalysis.measures(of: metronomic(beats: 12), overBeats: 12)

        XCTAssertGreaterThan(m.pitchEntropyBits, 2)
        XCTAssertGreaterThan(m.meanIntervalSemitones, 2)
        XCTAssertGreaterThan(m.contourReversalRate, 0.1)
        XCTAssertGreaterThan(m.velocitySD, 5)
        XCTAssertGreaterThan(m.interest, flat.interest + 0.4)
    }

    /// A chord is one rhythmic event, not three melodic steps. Counting every note of a
    /// block chord as a melodic move would report comping as wild melodic activity.
    func testAChordIsOneEventAndNotThreeMelodicSteps() {
        let chords = (0..<8).flatMap { bar -> [PlayedNote] in
            let t = Double(bar) * beat
            return [PlayedNote(time: t, note: 60, velocity: 80),
                    PlayedNote(time: t + 0.004, note: 64, velocity: 80),
                    PlayedNote(time: t + 0.009, note: 67, velocity: 80)]
        }
        let m = MusicalContentAnalysis.measures(of: chords, overBeats: 8)

        XCTAssertEqual(m.noteCount, 24)
        XCTAssertEqual(m.eventsPerBeat, 1, accuracy: 1e-9, "eight chords over eight beats")
        XCTAssertEqual(m.meanChordSize, 3, accuracy: 1e-9)
        XCTAssertEqual(m.meanIntervalSemitones, 0, accuracy: 1e-9,
                       "the top line never moves, so there is no melodic step")
    }

    /// A scale runs in one direction; a shaped line turns around. The measure has to tell
    /// them apart, otherwise "melodic" just means "fast".
    func testContourDistinguishesAScaleFromAShapedLine() {
        var scaleSpec: [(Double, Int)] = []
        var zigzagSpec: [(Double, Int)] = []
        for i in 0..<12 {
            let t = Double(i) * beat
            scaleSpec.append((t, 60 + i))
            zigzagSpec.append((t, i % 2 == 0 ? 60 : 65))
        }
        let scale = notes(scaleSpec)
        let zigzag = notes(zigzagSpec)

        XCTAssertEqual(MusicalContentAnalysis.measures(of: scale, overBeats: 12)
                        .contourReversalRate, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(MusicalContentAnalysis.measures(of: zigzag, overBeats: 12)
                        .contourReversalRate, 0.9)
    }

    func testEntropyRisesWithPitchVariety() {
        let one = MusicalContentAnalysis.measures(of: metronomic(beats: 12), overBeats: 12)
        var twoSpec: [(Double, Int)] = []
        var manySpec: [(Double, Int)] = []
        for i in 0..<12 {
            let t = Double(i) * beat
            twoSpec.append((t, i % 2 == 0 ? 60 : 67))
            manySpec.append((t, 60 + i))
        }
        let two = MusicalContentAnalysis.measures(of: notes(twoSpec), overBeats: 12)
        let many = MusicalContentAnalysis.measures(of: notes(manySpec), overBeats: 12)

        XCTAssertEqual(one.pitchEntropyBits, 0, accuracy: 1e-9)
        XCTAssertEqual(two.pitchEntropyBits, 1, accuracy: 1e-9, "two equally used classes = 1 bit")
        XCTAssertGreaterThan(many.pitchEntropyBits, 3)
    }

    // MARK: - Windows and correlation

    /// Build a take whose windows differ in content and in timing scatter, and check the
    /// relationship is recovered with the right sign.
    private func take(windowSpecs: [(interesting: Bool, jitterMs: Double)])
        -> (raw: [PlayedNote], events: [Tap], grid: Grid) {
        var rng = SplitMix64(seed: 99)
        var raw: [PlayedNote] = []
        var events: [Tap] = []
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 1)
        let line = [60, 64, 67, 72, 69, 65, 62, 67]

        for (w, spec) in windowSpecs.enumerated() {
            for b in 0..<32 {                       // 8 bars × 4 beats
                let index = w * 32 + b
                let u = Double(rng.next() >> 11) / Double(1 << 53) - 0.5
                let t = Double(index) * beat + u * 2 * spec.jitterMs / 1000
                let note = spec.interesting ? line[b % line.count] : 60
                let velocity = spec.interesting ? 60 + (b % 4) * 15 : 80
                raw.append(PlayedNote(time: t, note: note, velocity: velocity))
                events.append(Tap(time: t, velocity: velocity, note: note))
            }
        }
        return (raw, events, grid)
    }

    func testInterestingWindowsWithTighterTimingProduceANegativeCorrelation() {
        // Alternating: interesting windows are tight, dull windows are loose.
        let specs = (0..<8).map { (interesting: $0 % 2 == 0, jitterMs: $0 % 2 == 0 ? 6.0 : 26.0) }
        let t = take(windowSpecs: specs)
        let r = MusicalContentAnalysis.analyze(rawNotes: t.raw, events: t.events, grid: t.grid,
                                               totalBars: specs.count * 8)

        XCTAssertEqual(r.windows.count, 8)
        let interest = r.correlations.first { $0.measure == "overall interest" }
        XCTAssertNotNil(interest)
        XCTAssertLessThan(interest!.r, -0.7)
        XCTAssertTrue(r.headline.contains("tighter the timing"))
    }

    func testNoRelationshipIsReportedAsNoRelationship() {
        // Content varies, timing does not.
        let specs = (0..<8).map { (interesting: $0 % 2 == 0, jitterMs: 12.0) }
        let t = take(windowSpecs: specs)
        let r = MusicalContentAnalysis.analyze(rawNotes: t.raw, events: t.events, grid: t.grid,
                                               totalBars: specs.count * 8)

        let interest = r.correlations.first { $0.measure == "overall interest" }!
        XCTAssertLessThan(abs(interest.r), 0.6)
        XCTAssertTrue(r.headline.contains("unrelated") || r.headline.contains("looser"))
    }

    func testTooFewWindowsRefusesToCorrelate() {
        let t = take(windowSpecs: [(true, 6), (false, 20)])
        let r = MusicalContentAnalysis.analyze(rawNotes: t.raw, events: t.events, grid: t.grid,
                                               totalBars: 16)

        XCTAssertTrue(r.correlations.isEmpty)
        XCTAssertTrue(r.headline.contains("Not enough of this take"))
    }

    func testAnEmptyTakeSaysSo() {
        let r = MusicalContentAnalysis.analyze(rawNotes: [], events: [],
                                               grid: Grid(startTime: 0, bpm: 100, subdivisions: 1),
                                               totalBars: 64)
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertTrue(r.headline.contains("Nothing was played"))
    }

    /// A tail shorter than a window is not a window (PLAN.md §7.20 finding 3).
    ///
    /// The count used to round up, so the last window of every take ran past the end of the
    /// take and was still divided by a full window's worth of beats. Every take's final window
    /// therefore reported a density lower than it played — and density is the confound the
    /// whole report is written around.
    func testATailShorterThanAWindowIsDroppedRatherThanScoredAsSparse() {
        let specs = (0..<8).map { _ in (interesting: false, jitterMs: 6.0) }
        let t = take(windowSpecs: specs)
        var raw = t.raw, events = t.events
        for b in 0..<16 {                      // four more bars of the same steady playing
            let time = Double(8 * 32 + b) * beat
            raw.append(PlayedNote(time: time, note: 60, velocity: 80))
            events.append(Tap(time: time, velocity: 80, note: 60))
        }

        let r = MusicalContentAnalysis.analyze(rawNotes: raw, events: events, grid: t.grid,
                                               totalBars: 68)

        XCTAssertEqual(r.windows.count, 8, "a 4-bar tail is not a ninth window")
        // One note per beat throughout. Rounding up produced a ninth window holding four bars
        // of playing divided by eight bars of beats — half the density of the other eight, and
        // it entered the correlation as though the player had thinned out at the end.
        // (Not an exact equality: a note within jitter of a boundary lands either side of it.)
        let densities = r.windows.map(\.content.eventsPerBeat)
        XCTAssertGreaterThan(densities.min() ?? 0, 0.9)
    }

    /// Length comes from the configuration, not from the last note — the same invariant that
    /// §7.12 had to establish for take duration, one layer up. A player who stops a bar early
    /// must not lose a window that really was complete.
    func testStoppingEarlyDoesNotCostAWholeWindow() {
        let specs = (0..<8).map { _ in (interesting: false, jitterMs: 6.0) }
        let t = take(windowSpecs: specs)
        // Drop the last two beats: the player stopped just short of the end.
        let raw = Array(t.raw.dropLast(2)), events = Array(t.events.dropLast(2))

        let r = MusicalContentAnalysis.analyze(rawNotes: raw, events: events, grid: t.grid,
                                               totalBars: 64)
        XCTAssertEqual(r.windows.count, 8, "the eighth window was played and must be scored")
    }

    func testATakeShorterThanOneWindowSaysSo() {
        let t = take(windowSpecs: [(false, 6.0)])
        let r = MusicalContentAnalysis.analyze(rawNotes: t.raw, events: t.events, grid: t.grid,
                                               totalBars: 4)
        XCTAssertTrue(r.windows.isEmpty)
        XCTAssertTrue(r.headline.contains("shorter than one"), r.headline)
    }

    // MARK: - The traps

    /// The arousal confound cannot be designed away by this measurement, so it is always
    /// stated. A report that quietly dropped it would be claiming more than it can support.
    func testTheArousalConfoundIsAlwaysStated() {
        let specs = (0..<8).map { (interesting: $0 % 2 == 0, jitterMs: $0 % 2 == 0 ? 6.0 : 26.0) }
        let t = take(windowSpecs: specs)
        let r = MusicalContentAnalysis.analyze(rawNotes: t.raw, events: t.events, grid: t.grid,
                                               totalBars: specs.count * 8)
        XCTAssertTrue(r.notes.contains { $0.contains("more melodic *and* more engaging") })
    }

    /// Spread is computed only on notes that matched the grid. When the busier windows are
    /// also the ones losing notes off the grid, their spread describes a self-selected
    /// subset — and saying nothing would let that read as "busy playing is tighter".
    func testCensoringIsNamedWhenOffGridTracksContent() {
        var raw: [PlayedNote] = []
        var events: [Tap] = []
        let grid = Grid(startTime: 0, bpm: 100, subdivisions: 1)
        let line = [60, 64, 67, 72, 69, 65, 62, 67]

        for w in 0..<8 {
            let interesting = w % 2 == 0
            for b in 0..<32 {
                let index = w * 32 + b
                // Interesting windows push a third of their notes well off the beat.
                let offGrid = interesting && b % 3 == 0
                let t = Double(index) * beat + (offGrid ? beat * 0.45 : 0.002)
                let note = interesting ? line[b % line.count] : 60
                let velocity = interesting ? 60 + (b % 4) * 15 : 80
                raw.append(PlayedNote(time: t, note: note, velocity: velocity))
                events.append(Tap(time: t, velocity: velocity, note: note))
            }
        }
        let r = MusicalContentAnalysis.analyze(rawNotes: raw, events: events, grid: grid,
                                               totalBars: 64)

        XCTAssertGreaterThan(r.windows.filter { $0.offGridRate > 0.2 }.count, 0)
        XCTAssertTrue(r.notes.contains { $0.contains("self-selected subset") }
                   || r.notes.contains { $0.contains("fell off the grid") },
                      "censoring must be named: \(r.notes)")
    }
}
