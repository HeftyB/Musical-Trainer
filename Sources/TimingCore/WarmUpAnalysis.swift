import Foundation

/// One take, reduced to what the cold-versus-warm question needs.
public struct SessionedTake: Equatable {
    /// Which sitting this take belongs to, chronological and 0-based.
    public let sessionIndex: Int
    /// Minutes from the start of that sitting.
    public let elapsedMinutes: Double
    /// True when this take was the session's controlled cold probe — same drill, same
    /// parameters, before any warm-up. A merely *first* take is not the same thing and the
    /// report says which it had.
    public let isColdProbe: Bool
    public let value: Double

    public init(sessionIndex: Int, elapsedMinutes: Double, isColdProbe: Bool, value: Double) {
        self.sessionIndex = sessionIndex; self.elapsedMinutes = elapsedMinutes
        self.isColdProbe = isColdProbe; self.value = value
    }
}

public enum WarmUpVerdict: Equatable {
    /// Too few sittings to separate the two effects at all.
    case notEnoughData
    /// The metric improves inside a sitting but the cold start does not move across days:
    /// you are warming up, not learning.
    case warmUpOnly
    /// Cold starts improve across days — the gain is still there before you have played
    /// anything, which is what learning looks like.
    case learning
    /// Cold starts are getting *worse* across days. Separable, and a finding — the opposite
    /// of one, but not the same thing as nothing.
    case coldSlipping
    /// Both effects are real and separable.
    case both
    /// Neither slope excludes zero.
    case neither
}

public struct WarmUpReport: Equatable {
    public let sessionCount: Int
    public let takeCount: Int

    /// Change in the metric per minute *inside* a sitting, estimated from within-sitting
    /// variation only. nil when no sitting has two takes far enough apart to fit.
    public let withinSession: TrendFit?
    /// Change in each sitting's cold value, across sittings.
    public let betweenSessions: TrendFit?
    /// True when every sitting's cold value came from a controlled cold probe rather than
    /// from whichever take happened to be first.
    public let coldIsControlled: Bool

    public let verdict: WarmUpVerdict
    /// What the numbers do and do not support, in plain words.
    public let headline: String
    public let notes: [String]
}

/// Does the improvement survive a night's sleep?
///
/// The first tempo data fell −4.7% → −0.3% inside a single sitting (PLAN §7.13), and nothing
/// in the app could say whether that was learning or dust shaking off. Those need completely
/// different responses — one means practise is working, the other means the first ten minutes
/// of every session are wasted measurement — and fitting one slope across all takes cannot
/// tell them apart, because it confounds *when in the evening* a take was played with *which
/// evening* it was.
public enum WarmUpAnalysis {
    /// Below this, the between-sitting slope is not worth fitting.
    public static let minimumSessions = 3
    /// A sitting needs takes at least this far apart to say anything about warming up.
    public static let minimumSpanMinutes: Double = 4

    public static func analyze(_ takes: [SessionedTake],
                               lowerIsBetter: Bool,
                               iterations: Int = 2000,
                               seed: UInt64 = 0xC01D) -> WarmUpReport {
        let usable = takes.filter { $0.value.isFinite && $0.elapsedMinutes.isFinite }
        let sessions = Dictionary(grouping: usable, by: \.sessionIndex)
            .sorted { $0.key < $1.key }
            .map(\.value)

        var notes: [String] = []
        let within = withinSessionFit(sessions, lowerIsBetter: lowerIsBetter,
                                      iterations: iterations, seed: seed, notes: &notes)
        let (between, coldControlled) = betweenSessionFit(sessions, lowerIsBetter: lowerIsBetter,
                                                          notes: &notes)

        let verdict = decide(within: within, between: between, sessionCount: sessions.count,
                             notes: &notes)
        return WarmUpReport(
            sessionCount: sessions.count, takeCount: usable.count,
            withinSession: within, betweenSessions: between,
            coldIsControlled: coldControlled,
            verdict: verdict, headline: headline(for: verdict, coldIsControlled: coldControlled),
            notes: notes)
    }

    // MARK: - Within a sitting

    /// Slope of the metric against minutes elapsed, using **within-sitting variation only**.
    ///
    /// Each sitting is centred on its own means before pooling, so a sitting that was simply
    /// a good day cannot contribute to the warm-up slope — exactly the same reason
    /// `DropoutAnalysis` centres each silence on its own mean before pooling for
    /// Wing–Kristofferson. Without it, between-sitting differences leak into the estimate of
    /// the within-sitting effect, which is the specific confusion this whole analysis exists
    /// to remove.
    ///
    /// The interval comes from resampling **whole sittings**, not takes. Takes inside one
    /// evening are correlated; resampling them individually would treat six takes from one
    /// night as six independent observations and report a confident wrong interval.
    private static func withinSessionFit(_ sessions: [[SessionedTake]],
                                         lowerIsBetter: Bool,
                                         iterations: Int,
                                         seed: UInt64,
                                         notes: inout [String]) -> TrendFit? {
        let contributing = sessions.filter { session in
            guard session.count >= 2 else { return false }
            let elapsed = session.map(\.elapsedMinutes)
            guard let first = elapsed.min(), let last = elapsed.max() else { return false }
            return (last - first) >= minimumSpanMinutes
        }
        guard contributing.count >= 2 else {
            if contributing.count == 1 {
                notes.append("Only one sitting has takes spread far enough apart to show a "
                           + "warm-up curve. One evening cannot separate warming up from "
                           + "having had a good night.")
            }
            return nil
        }

        guard let observed = centredSlope(contributing) else { return nil }

        var rng = SplitMix64(seed: seed)
        var slopes: [Double] = []
        slopes.reserveCapacity(iterations)
        for _ in 0..<iterations {
            var resampled: [[SessionedTake]] = []
            resampled.reserveCapacity(contributing.count)
            for _ in 0..<contributing.count {
                resampled.append(contributing[Int(rng.next() % UInt64(contributing.count))])
            }
            if let slope = centredSlope(resampled) { slopes.append(slope) }
        }
        guard !slopes.isEmpty else { return nil }
        return fit(slope: observed, slopes: slopes, points: contributing.count,
                   lowerIsBetter: lowerIsBetter)
    }

    /// Pool every sitting's takes with both axes centred on that sitting's own means, then
    /// fit one line through the pool.
    private static func centredSlope(_ sessions: [[SessionedTake]]) -> Double? {
        var x: [Double] = [], y: [Double] = []
        for session in sessions {
            let meanElapsed = mean(session.map(\.elapsedMinutes))
            let meanValue = mean(session.map(\.value))
            for take in session {
                x.append(take.elapsedMinutes - meanElapsed)
                y.append(take.value - meanValue)
            }
        }
        return Stats.linearFit(x: x, y: y)?.slope
    }

    // MARK: - Across sittings

    /// Slope of each sitting's cold value against sitting number.
    private static func betweenSessionFit(_ sessions: [[SessionedTake]],
                                          lowerIsBetter: Bool,
                                          notes: inout [String]) -> (TrendFit?, Bool) {
        var coldValues: [Double] = []
        var allControlled = !sessions.isEmpty
        for session in sessions {
            // The controlled probe if there is one; otherwise whatever was played first, which
            // is a proxy and is flagged as such.
            if let probe = session.first(where: \.isColdProbe) {
                coldValues.append(probe.value)
            } else if let first = session.min(by: { $0.elapsedMinutes < $1.elapsedMinutes }) {
                coldValues.append(first.value)
                allControlled = false
            }
        }

        guard coldValues.count >= minimumSessions else {
            notes.append("\(coldValues.count) sitting(s) on record — \(minimumSessions) are needed "
                       + "before a cold-start trend means anything.")
            return (nil, allControlled)
        }
        if !allControlled {
            notes.append("Some cold values are just the first take of a sitting rather than a "
                       + "controlled cold probe, so they differ in drill and settings as well as "
                       + "in temperature. Treat the cold trend as indicative until every sitting "
                       + "was started from the session builder.")
        }
        return (TrendAnalysis.fit(coldValues, lowerIsBetter: lowerIsBetter), allControlled)
    }

    // MARK: - Verdict

    private static func decide(within: TrendFit?, between: TrendFit?,
                               sessionCount: Int, notes: inout [String]) -> WarmUpVerdict {
        guard sessionCount >= minimumSessions else { return .notEnoughData }
        let warmingUp = within?.verdict == .improving
        let learning = between?.verdict == .improving

        if within?.verdict == .worsening {
            notes.append("The metric gets *worse* across a sitting, which is fatigue rather than "
                       + "warm-up. Worth knowing before adding length to a session.")
        }
        switch (warmingUp, learning) {
        case (true, true):   return .both
        case (true, false):  return .warmUpOnly
        case (false, true):  return .learning
        case (false, false):
            // A cold start that is reliably getting *worse* is separable and is a result.
            // Folding it into "neither" said "nothing to see" directly underneath a row
            // reading "worsening" with an interval that excludes zero — a contradiction the
            // first real session put on screen.
            if between?.verdict == .worsening { return .coldSlipping }
            return between == nil && within == nil ? .notEnoughData : .neither
        }
    }

    private static func headline(for verdict: WarmUpVerdict, coldIsControlled: Bool) -> String {
        switch verdict {
        case .notEnoughData:
            return "Not enough sittings yet to tell warming up apart from getting better."
        case .warmUpOnly:
            return "This is warm-up, not learning. You improve inside a session, but you start "
                 + "each one where you started the last — the first few minutes are the cost of "
                 + "entry, not wasted."
        case .learning:
            return "This is learning. Your cold start is better than it used to be, which is the "
                 + "gain that survived a night's sleep."
        case .coldSlipping:
            return "Your cold start is getting worse from sitting to sitting. Whatever you gain "
                 + "inside a session is not surviving to the next one — worth looking at the gap "
                 + "between sessions rather than what happens inside them."
        case .both:
            return "Both: you warm up within a session *and* your cold start has improved across "
                 + "them. The second is the one that counts."
        case .neither:
            return "Neither effect is separable from noise yet — no warm-up curve inside a "
                 + "sitting, and no movement in the cold start across them."
        }
    }

    // MARK: - Helpers

    private static func fit(slope: Double, slopes: [Double], points: Int,
                            lowerIsBetter: Bool) -> TrendFit {
        let low = Stats.percentile(slopes, 0.025)
        let high = Stats.percentile(slopes, 0.975)
        let real = (low > 0 && high > 0) || (low < 0 && high < 0)
        let improving = lowerIsBetter ? slope < 0 : slope > 0
        return TrendFit(slope: slope, low: low, high: high, pointCount: points,
                        verdict: !real ? .flat : improving ? .improving : .worsening)
    }

    private static func mean(_ x: [Double]) -> Double {
        x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count)
    }

    // MARK: - Grouping takes into sittings

    /// Split chronological take times into sittings wherever there is a gap.
    ///
    /// For takes recorded before sessions existed there is no stored session identity, but
    /// the timestamps still carry it: an evening's practice is a run of takes minutes apart,
    /// and the next sitting is hours or days later. Recovering that makes the whole existing
    /// history usable for the within-sitting question rather than starting from zero.
    ///
    /// - Parameter times: seconds since any fixed epoch, ascending.
    /// - Returns: a 0-based sitting index per take.
    public static func inferSessions(times: [Double], gapMinutes: Double = 45) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(times.count)
        var session = 0
        for (i, time) in times.enumerated() {
            if i > 0, time - times[i - 1] > gapMinutes * 60 { session += 1 }
            indices.append(session)
        }
        return indices
    }
}
