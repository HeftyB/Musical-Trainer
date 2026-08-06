import Foundation

public struct OffbeatReport: Equatable {
    /// Notes that landed on an offbeat — the ones the drill asked for.
    public let onOffbeat: Int
    /// Notes that landed on a beat. **Not sloppiness — a different failure.**
    public let onDownbeat: Int
    /// Share of matched notes that were where they were asked for, 0–1.
    public let offbeatShare: Double

    /// Signed placement of the offbeat notes. Negative is ahead.
    public let placementMs: Double?
    /// Spread of the offbeat notes — the precision figure.
    public let spreadMs: Double?
    /// Spread of whatever landed on the beat, for comparison. Usually nil, and that is the
    /// healthy case.
    public let downbeatSpreadMs: Double?

    /// True when enough of the playing drifted onto the beat to call the feel lost.
    public let slipped: Bool
    public let headline: String
    public let notes: [String]
}

/// Placing notes where the grid says nothing is.
///
/// Ska and reggae put the emphasis on the offbeat, and the skill is holding a position that is
/// never articulated — every other drill in this app anchors on the downbeat. **The grid is
/// straight**: an offbeat is at half the beat, exactly where it always was, so this is a drill
/// rather than a feel (§7.24 step 1). What changes is which points the player is asked to hit
/// and how much the band states underneath.
///
/// **Two failures, kept apart, and that separation is the whole design.** A player can be a
/// little early or late on the offbeat — ordinary placement error, in milliseconds. Or they can
/// *slip onto the beat*, which is not a worse version of the same thing: the feel has inverted
/// and every note afterwards is right on a grid point, just the wrong one. Pooling those would
/// report a lost feel as excellent placement, since a slipped player lands dead on the beat.
///
/// This is `FormAnalysis`'s split in a new place — whole bars off the phrase versus milliseconds
/// off the bar line — and for the same reason: landing crisply in the wrong place and landing
/// sloppily in the right one need different work.
public enum OffbeatAnalysis {

    /// Below this share on the offbeat, the feel has gone rather than merely wobbled.
    ///
    /// Two thirds, because a player holding the feel puts essentially everything on the offbeat —
    /// the drill asks for nothing else — while a player who has flipped puts essentially
    /// everything on the beat. The middle is where they are oscillating, and that is worth
    /// naming as its own state rather than scoring as poor placement.
    public static let slipThreshold = 2.0 / 3

    /// Fewer than this and there is no placement to report.
    public static let minimumNotes = 12

    public static func analyze(matched: [MatchedTap], grid: Grid) -> OffbeatReport {
        // Odd phases are the offbeats. On a sixteenth grid that is the "e" and "a" as well as
        // the "and", which is correct: the drill asks for the and, and anything landing on a
        // sixteenth is neither the beat nor the offbeat and should not flatter either count.
        let half = grid.subdivisions / 2
        let offbeat = matched.filter { grid.phase(ofIndex: $0.gridIndex) == max(1, half) }
        let downbeat = matched.filter { grid.phase(ofIndex: $0.gridIndex) == 0 }

        let scored = offbeat.count + downbeat.count
        let share = scored > 0 ? Double(offbeat.count) / Double(scored) : 0
        let slipped = scored >= minimumNotes && share < slipThreshold

        let placement = offbeat.count > 1 ? Stats.finite(Stats.mean(offbeat.map(\.asynchronyMs))) : nil
        let spread = offbeat.count > 1 ? Stats.finite(Stats.sd(offbeat.map(\.asynchronyMs))) : nil
        let downbeatSpread = downbeat.count > 1
            ? Stats.finite(Stats.sd(downbeat.map(\.asynchronyMs))) : nil

        var notes: [String] = []
        if scored < minimumNotes {
            notes.append("\(scored) note(s) landed on a beat or an offbeat — \(minimumNotes) are "
                       + "needed before placement means anything.")
        }
        if slipped {
            notes.append(String(format: "%.0f%% of your notes landed on the beat rather than "
                              + "between them. That is the feel inverting rather than loose "
                              + "placement: a slipped player is dead on a grid point, just the "
                              + "wrong one, so the millisecond figures below describe whichever "
                              + "notes stayed put and not the take.",
                                (1 - share) * 100))
        }
        // Placement on the offbeat is worth comparing against placement on the beat when both
        // exist, because a player who is tight on the beat and loose off it has a feel problem
        // rather than a timing one.
        if let spread, let downbeatSpread, downbeatSpread > 0, spread > downbeatSpread * 1.4 {
            notes.append(String(format: "The notes you put on the beat were tighter than the ones "
                              + "you put between them — %.1f ms against %.1f. The pulse is "
                              + "there; the offbeat is what needs the work.",
                                downbeatSpread, spread))
        }

        return OffbeatReport(
            onOffbeat: offbeat.count, onDownbeat: downbeat.count, offbeatShare: share,
            placementMs: placement, spreadMs: spread, downbeatSpreadMs: downbeatSpread,
            slipped: slipped,
            headline: headline(scored: scored, share: share, slipped: slipped,
                               placement: placement, spread: spread),
            notes: notes)
    }

    /// The next level up, once this one is held. Nothing is earned by a slipped take.
    ///
    /// Deliberately strict: the drill's whole point is the level where the downbeat is gone, and
    /// arriving there before the level below is solid means measuring a flip rather than a
    /// placement.
    ///
    /// Takes and returns an `Int` rather than the level enum, which lives in `GrooveCore` —
    /// the two pure modules stay independent (R1.1.3), the same boundary `notesPerBeat` crosses.
    public static func suggestedLevel(current: Int, highest: Int, report: OffbeatReport,
                                      spreadCeilingMs: Double) -> Int {
        guard !report.slipped, report.offbeatShare > 0.9,
              let spread = report.spreadMs, spread <= spreadCeilingMs else { return current }
        return min(current + 1, highest)
    }

    private static func headline(scored: Int, share: Double, slipped: Bool,
                                 placement: Double?, spread: Double?) -> String {
        guard scored >= minimumNotes else {
            return "Not enough playing to say — keep the chop going on every offbeat."
        }
        if slipped {
            return "You slipped onto the beat. The chop went where the pulse is instead of "
                 + "between, which is the failure this drill exists to catch."
        }
        guard let spread else { return "You held the offbeat." }
        let placementWord = placement.map {
            $0 < -8 ? ", sitting ahead of it" : $0 > 8 ? ", sitting behind it" : ""
        } ?? ""
        return String(format: "You held the offbeat and placed it to %.1f ms%@.",
                      spread, placementWord)
    }
}
