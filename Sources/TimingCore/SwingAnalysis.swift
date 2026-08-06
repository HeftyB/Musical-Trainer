import Foundation

/// What a take says about how the player divides the beat.
public struct SwingReport: Equatable {
    /// The ratio the take was scored against — the feel it was asked for.
    public let askedRatio: Double
    /// Where the swung note actually landed, as a fraction of its pair's span. 0.5 is even.
    public let producedPhase: Double?
    /// `producedPhase` expressed as a long-to-short ratio. **Derived, never measured.**
    public let producedRatio: Double?
    /// Interval on the produced ratio, obtained by transforming the interval on the phase.
    public let producedRatioInterval: ConfidenceInterval?

    /// Spread of the notes that land *on* the division points — the beat, or the straight
    /// members of each pair.
    public let downbeatSpreadMs: Double?
    /// Spread of the swung notes. **This is the consistency figure**, and it is in the same
    /// units as the line above so the two can be read against each other.
    public let offbeatSpreadMs: Double?

    public let downbeatCount: Int
    public let offbeatCount: Int

    /// False when the rung has no binary pair to swing — triplets, or an undivided beat.
    public let ratioIsMeaningful: Bool
    /// What is being divided: the beat at eighths, an eighth at sixteenths.
    ///
    /// Named because the same analysis on a finer grid answers a different question, and the
    /// headline would otherwise say "the beat" while measuring swung sixteenths. Every take on
    /// record is scored at sixteenths, so this is the difference between asking whether he
    /// swings his eighths and asking whether he swings inside them.
    public let dividedUnit: String

    public let headline: String
    public let notes: [String]
}

/// Swing, measured as placement rather than as a ratio of intervals.
///
/// §7.13 wanted *"consistency of that ratio ... in the same way SD rather than bias is the skill
/// for straight time"*. The instinct is right and **the unit is wrong**, which §7.24 sets out in
/// full: `r = φ/(1−φ)` gives `dr/dφ = 1/(1−φ)²`, running from 4 at straight to 16 at a ratio of
/// 3. Identical physical steadiness reports as a ratio spread that quadruples across the useful
/// range, so a player who tightened up while swinging harder would look worse.
///
/// So the primary measurements here are **phase and spread in milliseconds** — linear in what
/// the hands do, in the same units as every other spread this app reports, and directly
/// comparable to the *downbeat's* spread in the same take. The ratio is reported because it is
/// the word players use, derived from the mean phase, with an interval obtained by transforming
/// the phase interval through a monotonic function. It is never itself a spread.
public enum SwingAnalysis {

    /// Below this many swung notes there is no placement to speak of.
    public static let minimumOffbeats = 24

    /// Off-division notes must be at least this share of the on-division ones before they
    /// describe a *division* rather than an ornament.
    ///
    /// A player genuinely dividing the unit produces roughly one off-division note per on-,
    /// so the true figure is near 1. This was found by running the readout over real takes:
    /// a free jam with **12 notes off the division against 117 on it** happily reported
    /// "you swing each eighth 1.4:1" with an interval excluding even — a confident number about
    /// a feel, computed from twelve incidental grace notes. The count guard alone did not catch
    /// it, because twelve is enough notes for a bootstrap and nowhere near enough to be a feel.
    public static let minimumOffbeatShare = 0.5

    /// A produced phase this far from even counts as swinging rather than as scatter.
    ///
    /// 0.53 is a 1.13:1 ratio. Below that the "swing" is inside the noise of a player whose
    /// spread is 20 ms against a 300 ms pair, and calling it a feel would be reading intent into
    /// rounding.
    public static let audibleSwingPhase = 0.53

    public static func analyze(matched: [MatchedTap], grid: Grid,
                               iterations: Int = 2000,
                               seed: UInt64 = 0x5171) -> SwingReport {
        let subdivisions = grid.subdivisions
        let meaningful = subdivisions > 1 && subdivisions & (subdivisions - 1) == 0

        // Odd phases are the swung members of each binary pair — the same split `Feel.phases`
        // makes when it shifts them, so the two cannot disagree about which notes moved.
        let onDivision = matched.filter { grid.phase(ofIndex: $0.gridIndex) % 2 == 0 }
        let swung = matched.filter { grid.phase(ofIndex: $0.gridIndex) % 2 == 1 }

        let downbeatSpread = onDivision.count > 1
            ? Stats.finite(Stats.sd(onDivision.map(\.asynchronyMs))) : nil
        let offbeatSpread = swung.count > 1
            ? Stats.finite(Stats.sd(swung.map(\.asynchronyMs))) : nil

        var phase: Double?
        var ratio: Double?
        var ratioInterval: ConfidenceInterval?
        var notes: [String] = []

        let share = onDivision.isEmpty ? 0 : Double(swung.count) / Double(onDivision.count)
        let isDividing = swung.count >= minimumOffbeats && share >= minimumOffbeatShare

        if meaningful, isDividing {
            // A swung note's produced phase is where the feel expected it plus however far it
            // actually landed from there, as a fraction of the *pair's* span rather than the
            // beat's — at sixteenths a pair is half a beat.
            let pairSpanMs = grid.beatInterval * 1000 / Double(subdivisions / 2)
            let asynchronies = swung.map(\.asynchronyMs)
            let expected = grid.feel.offbeatPhase
            let produced = expected + Stats.mean(asynchronies) / pairSpanMs
            phase = produced
            ratio = ratioFor(phase: produced)

            // Moving-block, because asynchronies within a take are serially correlated — that
            // correlation is the r₁ this project reports (R3.2). The interval is taken on the
            // phase and then transformed: `φ/(1−φ)` is monotonic, so the endpoints map straight
            // across, and bootstrapping the ratio directly would resample a quantity whose
            // scale changes across its own range.
            if let async = Bootstrap.interval(asynchronies, statistic: Stats.mean,
                                              iterations: iterations, seed: seed) {
                let lowPhase = expected + async.low / pairSpanMs
                let highPhase = expected + async.high / pairSpanMs
                if let low = ratioFor(phase: lowPhase), let high = ratioFor(phase: highPhase),
                   let point = ratio {
                    ratioInterval = ConfidenceInterval(point: point, low: low, high: high,
                                                       level: async.level)
                }
            }
        } else if !meaningful {
            notes.append("A \(subdivisions)-per-beat grid has no binary pair to swing, so there "
                       + "is no ratio to report. Triplets are the division swing borrows from.")
        } else if swung.count < minimumOffbeats {
            notes.append("\(swung.count) note(s) landed off the division — \(minimumOffbeats) "
                       + "are needed before their placement means anything.")
        } else {
            notes.append(String(format: "Only %.0f%% as many notes landed off the division as on "
                              + "it (%d against %d). That is ornament rather than a division, "
                              + "and a ratio read off it would describe a handful of passing "
                              + "notes as a feel.",
                                share * 100, swung.count, onDivision.count))
        }

        notes.append(contentsOf: caveats(downbeat: downbeatSpread, offbeat: offbeatSpread,
                                         askedRatio: grid.feel.swingRatio, produced: ratio))

        return SwingReport(
            askedRatio: grid.feel.swingRatio, producedPhase: phase, producedRatio: ratio,
            producedRatioInterval: ratioInterval,
            downbeatSpreadMs: downbeatSpread, offbeatSpreadMs: offbeatSpread,
            downbeatCount: onDivision.count, offbeatCount: swung.count,
            ratioIsMeaningful: meaningful, dividedUnit: Self.dividedUnit(subdivisions),
            headline: headline(unit: Self.dividedUnit(subdivisions), phase: phase, ratio: ratio,
                               downbeat: downbeatSpread, offbeat: offbeatSpread),
            notes: notes)
    }

    static func dividedUnit(_ subdivisions: Int) -> String {
        switch subdivisions {
        case 2:  return "the beat"
        case 4:  return "each eighth"
        case 8:  return "each sixteenth"
        default: return "the beat"
        }
    }

    /// `φ/(1−φ)`, refusing the ends where the ratio runs away from any playable value.
    static func ratioFor(phase: Double) -> Double? {
        guard phase > 0.05, phase < 0.95 else { return nil }
        return phase / (1 - phase)
    }

    private static func caveats(downbeat: Double?, offbeat: Double?,
                                askedRatio: Double, produced: Double?) -> [String] {
        var notes: [String] = []

        // The comparison the whole design is arranged to make possible.
        if let downbeat, let offbeat, downbeat > 0 {
            if offbeat > downbeat * 1.3 {
                notes.append(String(format: "The swung note scatters more than the beat does — "
                                  + "%.1f ms against %.1f. The pulse is steadier than the "
                                  + "placement inside it.", offbeat, downbeat))
            } else if downbeat > offbeat * 1.3 {
                notes.append(String(format: "The swung note is placed more tightly than the beat "
                                  + "itself — %.1f ms against %.1f, which is unusual and worth "
                                  + "a second take before believing.", offbeat, downbeat))
            }
        }

        // Spread is reported in milliseconds and never as a spread of ratios, and the reason
        // belongs next to the number rather than only in PLAN.
        notes.append("Consistency is the swung note's spread in milliseconds, not the spread of "
                   + "a ratio. A ratio's sensitivity to placement grows steeply as the swing "
                   + "deepens, so the same steadiness would report as a worse number the harder "
                   + "you swung.")

        if let produced, abs(produced - askedRatio) > 0.25 {
            notes.append(String(format: "Asked for %.2g:1 and played about %.2g:1. The take is "
                              + "still scored against what it asked for, so that gap shows up "
                              + "in the swung note's placement rather than being absorbed.",
                                askedRatio, produced))
        }
        return notes
    }

    private static func headline(unit: String, phase: Double?, ratio: Double?,
                                 downbeat: Double?, offbeat: Double?) -> String {
        guard let phase, let ratio else {
            return "Not enough off-division playing to say how you divide \(unit)."
        }
        guard let offbeat else {
            return String(format: "You divide %@ about %.2g:1.", unit, ratio)
        }
        if phase < audibleSwingPhase {
            return String(format: "You divide %@ straight — %.2g:1, within noise of even — and "
                        + "place it to %.1f ms.", unit, ratio, offbeat)
        }
        return String(format: "You swing %@ about %.2g:1, and place the swung note to %.1f ms%@.",
                      unit, ratio, offbeat,
                      downbeat.map { String(format: " against %.1f on the division", $0) } ?? "")
    }
}
