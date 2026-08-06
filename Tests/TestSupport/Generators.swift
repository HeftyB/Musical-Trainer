import Foundation
import TimingCore

/// Synthetic performances with known properties, shared by every test target.
///
/// One generator, not one per test file. Before this existed there were four — `SeededRNG` and
/// `Generators` here, a `gaussianSeries` in `BootstrapTests`, a round layout in
/// `TempoMemoryTests`, an LCG in `SelfTest` — which meant a pathology added in one place
/// reached exactly one drill. See PLAN.md §7.22.
///
/// This is a plain target rather than a test target so all the test suites can import it, and it
/// depends only on `TimingCore` so it builds on Linux alongside the pure modules. Builders for
/// *stored* takes deliberately do not live here: those types are `internal` to `TrainerKit`, and
/// making them public to share a test helper would be a real API commitment bought for a
/// convenience. That boundary is forced by visibility, not chosen.

/// Deterministic Gaussian source so every test is reproducible run to run (R1.2.1).
public struct SeededRNG {
    private var state: UInt64
    public init(seed: UInt64 = 0x9E3779B97F4A7C15) { state = seed }

    public mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }

    public mutating func gaussian(mean: Double = 0, sd: Double = 1) -> Double {
        guard sd > 0 else { return mean }
        let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
        return mean + sd * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}

public enum Generators {
    /// A Wing–Kristofferson process with known clock and motor variances.
    ///
    /// Onset k = Σ clock intervals so far + a fresh motor delay. The interval series this
    /// produces has variance σ²_clock + 2σ²_motor and lag-1 autocovariance −σ²_motor by
    /// construction, so a correct decomposition must recover the inputs.
    public static func wkTapTimes(count: Int, beatMs: Double,
                                  clockSD: Double, motorSD: Double,
                                  rng: inout SeededRNG) -> [Double] {
        var times: [Double] = []
        var clockSum = 0.0
        for _ in 0..<count {
            let motor = rng.gaussian(sd: motorSD)
            times.append((clockSum + motor) / 1000)          // ms → s
            clockSum += rng.gaussian(mean: beatMs, sd: clockSD)
        }
        return times
    }

    /// Taps on the grid with a fixed bias and independent jitter.
    public static func tapsOnGrid(grid: Grid, beats: Int, biasMs: Double, jitterMs: Double,
                                  rng: inout SeededRNG) -> [Tap] {
        (0..<beats).map { k in
            let async = (biasMs + rng.gaussian(sd: jitterMs)) / 1000
            return Tap(time: grid.time(ofIndex: k) + async)
        }
    }

    /// A serially independent Gaussian series — the plain case, for statistics that do not care
    /// about grid position.
    public static func series(n: Int, mean: Double, sd: Double, seed: UInt64) -> [Double] {
        var rng = SeededRNG(seed: seed)
        return (0..<n).map { _ in rng.gaussian(mean: mean, sd: sd) }
    }
}

/// What kind of player to simulate.
///
/// Every field is a quantity the analysis reports back, so a test can plant a value and check
/// that the pipeline recovers it — and a pathology added here reaches every drill at once.
public struct Performance {
    public var beats: Int
    /// Negative is ahead of the beat, which is the normal direction for this player.
    public var biasMs: Double
    public var spreadMs: Double
    /// Tempo drift while playing, in ms per beat.
    public var driftMsPerBeat: Double
    /// Fraction of notes pushed outside the matching window entirely.
    public var offGridRate: Double
    /// Notes per event: 1 is a single line, 3 is chordal.
    public var chordSize: Int
    /// Which subdivision within the beat the player aims at. 0 is the downbeat, and on an
    /// eighths grid 1 is the offbeat — the position the skank holds and the band never plays.
    public var beatPhase: Int
    /// Fraction of notes that land on the downbeat instead of `beatPhase`.
    ///
    /// **Not a worse version of poor placement.** A slipped player is dead on a grid point, just
    /// the wrong one, so this has to be generated as its own failure rather than as extra
    /// spread — which is the separation `OffbeatAnalysis` exists to make.
    public var slipRate: Double
    public var seed: UInt64

    public init(beats: Int = 128, biasMs: Double = -12, spreadMs: Double = 14,
                driftMsPerBeat: Double = 0, offGridRate: Double = 0,
                chordSize: Int = 1, beatPhase: Int = 0, slipRate: Double = 0,
                seed: UInt64 = 0xBEEF) {
        self.beatPhase = beatPhase; self.slipRate = slipRate
        self.beats = beats; self.biasMs = biasMs; self.spreadMs = spreadMs
        self.driftMsPerBeat = driftMsPerBeat; self.offGridRate = offGridRate
        self.chordSize = chordSize; self.seed = seed
    }

    public static let steady = Performance()
    /// Nothing played at all — the case that destroyed a take in a live session.
    public static let silent = Performance(beats: 0, biasMs: 0, spreadMs: 0)
    public static let oneNote = Performance(beats: 1, biasMs: 0, spreadMs: 0)

    /// A skank held: one chop per beat, on the offbeat, and almost nothing on the beat.
    ///
    /// Use with an eighths grid. The few notes that do land on the beat are what makes this the
    /// dangerous case rather than the clean one — `SwingAnalysis` reads "off the division"
    /// against "on it", so the *better* the feel is held the more confidently it reports a swing
    /// ratio for a player who is not dividing anything (§7.24 step 8).
    public static let skank = Performance(beats: 128, biasMs: -12, spreadMs: 14,
                                          beatPhase: 1, slipRate: 0.03)
    /// A skank lost: most of the chop has drifted onto the beat, which is where the feel
    /// inverts. Matches the first offbeat take ever recorded — 26 notes off the beat, 86 on it.
    public static let slippedSkank = Performance(beats: 128, biasMs: -12, spreadMs: 14,
                                                 beatPhase: 1, slipRate: 0.77)

    /// Every pathology worth generating, named so a failure says which one broke.
    public static let pathologies: [(name: String, performance: Performance)] = [
        ("nothing played", .silent),
        ("a single note", .oneNote),
        ("everything off the grid", Performance(beats: 64, biasMs: 0, spreadMs: 2, offGridRate: 1)),
        ("wild spread", Performance(beats: 64, biasMs: 0, spreadMs: 400)),
        ("block chords only", Performance(beats: 64, spreadMs: 8, chordSize: 4)),
        ("running away", Performance(beats: 64, biasMs: 0, spreadMs: 6, driftMsPerBeat: 8)),
    ]

    /// Note-on times against a grid, with the planted bias, spread and drift applied.
    public func taps(grid: Grid) -> [Tap] {
        guard beats > 0 else { return [] }
        var rng = SeededRNG(seed: seed)
        var out: [Tap] = []
        for beat in 0..<beats {
            // `slipRate > 0` first so a straight performance draws nothing here: adding an
            // unconditional draw would shift the whole sequence and silently change the taps
            // every existing test plants.
            let slipped = slipRate > 0 && rng.uniform() < slipRate
            let index = beat * grid.subdivisions + (slipped ? 0 : beatPhase)
            let target = grid.time(ofIndex: index)
            var offset = (biasMs + driftMsPerBeat * Double(beat)) / 1000
            offset += rng.gaussian(sd: spreadMs) / 1000
            // An off-grid note lands beyond the matching window and counts as an extra.
            // Beyond the window at this point — asked of the grid, because under a feel the
            // spacing differs from point to point.
            if rng.uniform() < offGridRate {
                offset += grid.gap(around: index) * 0.45
            }
            for voice in 0..<Swift.max(1, chordSize) {
                out.append(Tap(time: target + offset + Double(voice) * 0.004,
                               velocity: 80, note: 60 + voice * 4))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
