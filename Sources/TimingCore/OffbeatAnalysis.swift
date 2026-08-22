import Foundation

/// Where one asked-for position was actually played, on its own.
///
/// **Never pooled with its neighbours**, and that is `SwingReport`'s precedent rather than a new
/// idea: the swing readout reports the spread of the swung note beside the spread of the notes on
/// the division, because one number over both describes neither. A figure of two notes has the same
/// problem — the feel lives in where the *second* sits relative to the first, and a single spread
/// over the pair hides exactly that.
public struct PhasePlacement: Equatable {
    /// The phase within the beat, in grid steps. 0 is the beat itself.
    public let phase: Int
    public let count: Int
    /// Signed placement of the notes at this phase. Negative is ahead. `nil` below two notes.
    public let placementMs: Double?
    public let spreadMs: Double?
}

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

    /// Each asked-for position on its own, in the order asked.
    public let perPhase: [PhasePlacement]

    /// **Is the whole figure being played, or only part of it?**
    ///
    /// The share the *least-played* asked-for position holds, against an even split. 1.0 is
    /// perfectly even; 0 means one of the asked positions is not being played at all.
    ///
    /// A figure of one position is complete by definition and reads 1.0 — which is why this is
    /// safe to add to the straight skank without changing a number on it.
    ///
    /// **It exists because `offbeatShare` cannot see this.** Asked for two notes after each beat, a
    /// player who plays only the first is 100% off the beat: perfect by every number this report
    /// had before, and playing half the figure. A share over a *set* has to say how the set was
    /// covered, or it is a share of something nobody asked for.
    public let completeness: Double

    /// True when the figure is being played in part rather than whole, and enough notes exist to
    /// say so.
    public let incomplete: Bool

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

    /// Below this evenness the figure is being played in part rather than whole.
    ///
    /// **Provisional, and said so where a reader will meet it** (`LESSONS.md` shape 11). A player
    /// genuinely playing both notes of a bubble produces roughly one of each; a player playing only
    /// the first produces zero on the second. Half of even is a generous line that still catches
    /// "the first note, and the second one sometimes", and no take exists to tune it against — the
    /// figure it is for has not been chosen (§7.56). **What would revise it:** the first bubble
    /// takes on record, read against how the player says the take felt.
    public static let completenessThreshold = 0.5

    /// The phases a straight skank asks for: the "and", alone.
    ///
    /// Here rather than at each call site because it is the *drill's* definition, and it was
    /// written inline as `max(1, subdivisions / 2)` — which is the one figure this family had when
    /// the file was written, and is not the general case.
    public static func skankPhases(on grid: Grid) -> [Int] { [max(1, grid.subdivisions / 2)] }

    /// Analyse a take against the positions it was asked for.
    ///
    /// - Parameter asking: phases within the beat, in grid steps, the player was asked to play.
    ///   `[2]` on a sixteenth grid is the straight skank's chop; `[1, 2]` on a triplet grid is one
    ///   of M16.5's candidate bubbles.
    ///
    /// **No default, deliberately.** Defaulting to the skank's single phase would silently score a
    /// bubble as a skank at any call site that forgot to pass one, and "absent means the common
    /// case" is the trap `LESSONS.md` shape 13 catalogues. Required means the compiler finds every
    /// caller the day a second figure arrives.
    public static func analyze(matched: [MatchedTap], grid: Grid,
                               asking phases: [Int]) -> OffbeatReport {
        // Anything the drill did not ask for and is not the beat is ignored rather than counted
        // against either side. On a sixteenth grid that is the "e" and the "a": neither the beat
        // nor an asked-for point, and letting them flatter either count would make the share a
        // statement about stray notes.
        //
        // **A figure is a set of positions, so the list is deduped before anything counts it.**
        // Matching already went through a `Set` while `asked.count` and `perPhase` read the raw
        // list. The two disagreeing is what let `completeness`, documented 0–1, read 2.0 for
        // `asking: [1, 1]`: ten notes at one position over an "even share" of five. The same
        // split listed one position twice in `perPhase`, and sent a one-position figure down
        // the `asked.count > 1` branch built for two. The list and the set are derived
        // together now, so a later reader cannot reopen the gap by reaching past one for the
        // other (§7.57 item 5).
        //
        // First-occurrence order is kept rather than sorted: `perPhase` is read as a musical
        // sequence, and every figure on record — all of them single-position skanks — reads
        // exactly as before.
        var askedSet = Set<Int>()
        let asked = (phases.isEmpty ? skankPhases(on: grid) : phases)
            .filter { askedSet.insert($0).inserted }
        let offbeat = matched.filter { askedSet.contains(grid.phase(ofIndex: $0.gridIndex)) }
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

        // Each asked position on its own. Pooling them would hide the asymmetry that makes a
        // two-note figure a figure — see `PhasePlacement`.
        let perPhase = asked.map { phase -> PhasePlacement in
            let at = offbeat.filter { grid.phase(ofIndex: $0.gridIndex) == phase }
            return PhasePlacement(
                phase: phase, count: at.count,
                placementMs: at.count > 1 ? Stats.finite(Stats.mean(at.map(\.asynchronyMs))) : nil,
                spreadMs: at.count > 1 ? Stats.finite(Stats.sd(at.map(\.asynchronyMs))) : nil)
        }

        // The least-played asked position against an even split. One position is complete by
        // definition, which is what keeps every skank take on record reading exactly as before.
        let evenShare = Double(offbeat.count) / Double(asked.count)
        let completeness = asked.count <= 1 ? 1
            : (evenShare > 0 ? Double(perPhase.map(\.count).min() ?? 0) / evenShare : 0)
        let incomplete = asked.count > 1 && offbeat.count >= minimumNotes
            && completeness < completenessThreshold

        if incomplete, let thin = perPhase.min(by: { $0.count < $1.count }) {
            notes.append(String(format: "You played %d note(s) at one of the %d positions asked "
                              + "for and %d at another. That is part of the figure rather than a "
                              + "loose version of it — the share above counts every asked position "
                              + "together, so it reads well while half the figure is missing.",
                                thin.count, asked.count,
                                perPhase.map(\.count).max() ?? 0))
        }

        return OffbeatReport(
            onOffbeat: offbeat.count, onDownbeat: downbeat.count, offbeatShare: share,
            placementMs: placement, spreadMs: spread, downbeatSpreadMs: downbeatSpread,
            slipped: slipped, perPhase: perPhase,
            completeness: completeness, incomplete: incomplete,
            headline: headline(scored: scored, share: share, slipped: slipped,
                               placement: placement, spread: spread, incomplete: incomplete),
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
                                 placement: Double?, spread: Double?,
                                 incomplete: Bool) -> String {
        guard scored >= minimumNotes else {
            return "Not enough playing to say — keep the chop going on every offbeat."
        }
        // Said before placement, for the same reason a slipped feel is: a figure played in part is
        // not a loose version of the whole one, and reporting how tightly half of it was placed
        // would answer a question nobody asked.
        if incomplete {
            return "You played part of the figure rather than all of it — one of the positions "
                 + "asked for is carrying most of the notes. The placement below describes what "
                 + "you did play."
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
