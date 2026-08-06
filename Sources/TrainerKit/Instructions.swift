import Foundation
import TimingCore

/// What each drill asks of the player, written so someone who has never seen the app knows
/// exactly what to do.
///
/// Both front ends read from here. Instructions that live in two places drift, and a drill
/// whose printed instructions disagree with its on-screen ones will quietly produce data that
/// means two different things — the form drill already lost two takes to an instruction
/// ambiguity (PLAN.md §6.1).
public struct DrillInstructions {
    /// One line: what this drill is for.
    public let goal: String
    /// Exactly what to do, in order.
    public let steps: [String]
    /// The mistakes that invalidate the measurement, not just make the score worse.
    public let pitfalls: [String]
    /// What the drill reports back.
    public let measures: String

    public static let jam = DrillInstructions(
        goal: "Measures how accurately you place notes against a beat you can hear.",
        steps: [
            "A two-bar count-in plays, then a drum groove starts.",
            "Play along for the whole take — chords, single notes, a riff, whatever you like.",
            "Aim every note at a beat or an off-beat, not somewhere between them.",
            "Keep playing to the end. There is nothing to read on screen while you play.",
        ],
        pitfalls: [
            "Don't play free or rubato — notes that don't aim at the grid are counted as off-grid and discarded.",
            "Don't stop and start. Steady, continuous playing gives the most usable notes.",
        ],
        measures: "Whether you sit ahead of or behind the beat, how much you scatter around it, "
                + "and whether you correct each error or let it drift.")

    /// The jam's instructions **for a prescribed rung**.
    ///
    /// A rung changes the task, so it has to change the text (R3.6). Nothing else in the drill
    /// tells the player they are being asked for eighths — the backing makes the division
    /// audible but does not *ask* for it, and a player who hears sixteenth hats and keeps
    /// playing quarters has produced a perfectly good free jam scored against a grid four times
    /// finer than the one they were aiming at.
    ///
    /// `nil` returns the plain jam text unchanged, which is what the benchmark and both
    /// experiment blocks must keep getting (R3.5).
    public static func jam(rung: IntervalRung?, feel: Feel = .straight) -> DrillInstructions {
        guard let rung else { return jam }
        if !feel.isStraight, feel.applies(toSubdivisions: rung.subdivisions) {
            return swung(rung: rung, feel: feel)
        }
        let each: String
        switch rung {
        case .quarters:       each = "one note on every beat"
        case .eighths:        each = "two notes to the beat, evenly"
        case .tripletEighths: each = "three notes to the beat, evenly — a triplet feel"
        case .sixteenths:     each = "four notes to the beat, evenly"
        }
        return DrillInstructions(
            goal: "Measures how accurately you place \(rung.label) against a beat you can hear. "
                + "The rung is the task: the gap between your notes is what is being trained.",
            steps: [
                "A two-bar count-in plays, then a groove whose hi-hat marks \(rung.label).",
                "Play \(each), continuously, for the whole take.",
                "Lock to the hat. It is playing the division you are being asked for.",
                "Any pitch. Only when you play is measured, and there is nothing to read.",
            ],
            pitfalls: [
                "Don't drop back to a sparser division when it gets hard — the take is scored "
                + "against \(rung.label), so notes at a coarser division land off-grid and are "
                + "discarded rather than counted as late.",
                "Don't switch between divisions mid-take. Two note values in one take means no "
                + "single interval describes what was played.",
                "Don't play free or rubato. Notes that aren't aiming at the grid are discarded.",
            ],
            measures: "Where you sit against the beat and how much you scatter around it, at "
                    + "this rung — and the scatter is in milliseconds, which is what compares "
                    + "across rungs for you.")
    }

    /// A swung rung asks for something the straight text actively contradicts.
    ///
    /// The straight instructions say "aim every note at a beat or an off-beat" and warn against
    /// playing between them — which is precisely what a swung offbeat does. Handing a swung take
    /// the straight text would tell the player their own task is a mistake. §7.17 and §6.1 both
    /// cost takes to instructions describing something other than what was running (R3.6).
    private static func swung(rung: IntervalRung, feel: Feel) -> DrillInstructions {
        let unit = rung.subdivisions == 2 ? "the beat" : "each eighth"
        return DrillInstructions(
            goal: "Measures how you place a **swung** division — where the offbeat sits, and how "
                + "consistently you put it there. The hat is swinging with you.",
            steps: [
                "A two-bar count-in plays swung, then a groove whose hi-hat swings \(unit).",
                "Play along in \(rung.label), letting the offbeat fall late the way the hat does.",
                "Lock to the hat. Do not try to place the offbeat by arithmetic — it is a feel, "
                + "and the band is playing it for you.",
                "Any pitch. Only when you play is measured, and there is nothing to read.",
            ],
            pitfalls: [
                "Don't straighten up when it gets hard. The take is scored against the swing, so "
                + "an even offbeat lands off-grid and is discarded rather than counted early.",
                "Don't chase the ratio. Where you naturally put the offbeat is the measurement, "
                + "and the report says how far it sat from what was asked.",
                "Don't play free or rubato — notes that aren't aiming at the grid are discarded.",
            ],
            measures: "Where you put the swung note and how tightly, in milliseconds, beside the "
                    + "same figure for the notes on the division. The ratio you actually played "
                    + "is reported too, derived from that placement.")
    }

    /// The jam's instructions **for a given experiment arm**.
    ///
    /// This is the sharpest case of R3.6 in the project so far. For `steady-vs-melodic` the two
    /// arms play the same backing at the same tempo for the same length: **the instruction text
    /// is the entire independent variable.** Text that described the wrong arm would not merely
    /// confuse the player, it would silently swap the conditions and the experiment would
    /// measure nothing while looking like it worked.
    ///
    /// Static text has already cost this project two takes and a live session (§6.1, §7.17),
    /// and in both cases it was only *describing* something that had moved. Here it would be
    /// the thing itself.
    ///
    /// An unknown arm returns the plain jam instructions rather than guessing, so a design
    /// whose arms are renamed degrades to an ordinary take instead of a mislabelled one.
    public static func jam(arm: String?) -> DrillInstructions {
        switch arm {
        case "steady":
            return DrillInstructions(
                goal: "Same take as the benchmark, played deliberately plainly. Half of an "
                    + "experiment: does what you play change how tightly you play it?",
                steps: [
                    "A two-bar count-in plays, then the usual groove starts.",
                    "Play one note per beat, straight through — no melody, no chords, no fills.",
                    "Stay on one note if you like. Dullness is the condition, not a failure.",
                    "Keep going to the end. Nothing to read on screen while you play.",
                ],
                pitfalls: [
                    "Don't drift into playing a line — that is the other arm, and the two takes "
                    + "have to differ only in this.",
                    "Don't compensate by concentrating harder than usual. Play it as you would.",
                ],
                measures: "The same numbers as any jam. The comparison is against the melodic "
                        + "takes, and only once both arms have enough.")
        case "melodic":
            return DrillInstructions(
                goal: "Same take as the benchmark, played as actual music. Half of an "
                    + "experiment: does what you play change how tightly you play it?",
                steps: [
                    "A two-bar count-in plays, then the usual groove starts.",
                    "Play a real line — a melody, a riff, something with shape and dynamics.",
                    "Aim every note at a beat or an off-beat, as always.",
                    "Keep going to the end. Nothing to read on screen while you play.",
                ],
                pitfalls: [
                    "Don't lapse into one repeated note — that is the other arm.",
                    "Don't play so free that the notes stop aiming at the grid; off-grid notes "
                    + "are discarded and the two arms would then be scored on different sets.",
                ],
                measures: "The same numbers as any jam. The comparison is against the steady "
                        + "takes, and only once both arms have enough.")
        case "slow", "fast":
            // **The text is not the condition here — the tempo is.** For `steady-vs-melodic`
            // the instruction *is* the independent variable, so wrong text would swap the arms
            // silently. Here the tempo differs whatever this says, and the text's job is only
            // to stop the player treating an unfamiliar tempo as a cue to do something else.
            // The take has to stay ordinary free playing or it is measuring two things.
            let faster = arm == "fast"
            return DrillInstructions(
                goal: "An ordinary jam at \(faster ? "a faster" : "a slower") tempo than usual. "
                    + "Half of an experiment on whether tempo changes where you sit against the "
                    + "beat — your own account is that slow tempos make you rush.",
                steps: [
                    "A two-bar count-in plays, then the usual groove, at \(faster ? "a quicker" : "a slower") tempo.",
                    "Play exactly as you would at any tempo — chords, a line, whatever you like.",
                    "Aim every note at a beat or an off-beat, as always.",
                    "Keep going to the end. Nothing to read on screen while you play.",
                ],
                pitfalls: [
                    "Don't play busier or sparser because of the tempo. Note density is the "
                    + "other arm's business, not this one's — the tempo is meant to be the only "
                    + "difference.",
                    "Don't correct toward the click if it feels off. Where you naturally sit is "
                    + "the measurement.",
                ],
                measures: "Where you sit against the beat, in milliseconds. Placement is "
                        + "reported and never scored — sitting ahead of the beat is normal, and "
                        + "the question is whether the tempo moves it.")
        case "relaxed":
            return DrillInstructions(
                goal: "Play without trying. Half of an experiment on what focusing does to your "
                    + "timing — the project's oldest untested claim.",
                steps: [
                    "A two-bar count-in plays, then the usual groove starts.",
                    "Play whatever you like, and deliberately do not concentrate on the beat.",
                    "Let it run. If your attention wanders, that is the condition working.",
                ],
                pitfalls: [
                    "Don't check yourself against the click. Noticing you have drifted and "
                    + "correcting is the other arm.",
                ],
                measures: "Correction gain — whether you let placement drift or chase each beat.")
        case "focused":
            return DrillInstructions(
                goal: "Play trying hard to be accurate. The other half of the focus experiment.",
                steps: [
                    "A two-bar count-in plays, then the usual groove starts.",
                    "Concentrate on placing every note exactly on the beat.",
                    "Keep that effort up for the whole take, even when it stops feeling good.",
                ],
                pitfalls: [
                    "Don't relax into it when it gets tiring — that is the other arm.",
                ],
                measures: "Correction gain. The prediction is that this arm chases the click and "
                        + "the relaxed one does not; nobody has ever measured it.")
        default:
            return jam
        }
    }

    /// The form drill's instructions **depend on the level**, because the landmarks it
    /// describes are exactly what the ladder takes away.
    ///
    /// This was a live bug, and the second one of its kind. A level-2 session printed "a drum
    /// fill warns you that a phrase is about to end" over a backing with no fills in it, so the
    /// player was told to wait for a cue that would never arrive. §6.1 already records two
    /// takes lost to an instruction ambiguity; static text for a drill whose whole design is
    /// removing cues was the same mistake wearing a different hat.
    public static func form(level: Int = 0) -> DrillInstructions {
        let cue: String
        let target: String
        var pitfalls = [
            "Don't count bars. If you lose your place, wait and catch the next phrase.",
            "Use a pad, not a key — keys are treated as ordinary playing.",
        ]

        switch level {
        case 0:
            cue = "A drum fill warns you that a phrase is about to end, and a crash lands on the downbeat itself."
            target = "Hit ANY PAD once on that downbeat — aim to arrive WITH the crash, not after it."
            pitfalls.insert("Don't hit the pad during the fill. The fill is the warning; the "
                          + "target is the beat right after it.", at: 0)
        case 1:
            cue = "A drum fill warns you that a phrase is about to end. Nothing confirms the arrival."
            target = "Hit ANY PAD once on the downbeat where the groove restarts after the fill."
            pitfalls.insert("Don't hit the pad during the fill. The fill is the warning; the "
                          + "target is the beat right after it.", at: 0)
        case 3:
            cue = "The band drops out before each phrase ends and returns after the turn. Nothing marks the corner."
            target = "Hit ANY PAD once where you feel the new phrase begins, in the silence."
            pitfalls.insert("Don't wait for the band to come back — the downbeat you are "
                          + "marking happens while it is still silent.", at: 0)
        default:
            cue = "The groove runs straight through with NO fills and no signposts of any kind."
            target = "Hit ANY PAD once where you feel each new phrase begins."
            pitfalls.insert("Don't wait for a cue — at this level there isn't one. Commit to "
                          + "where you feel the phrase turns.", at: 0)
        }

        return DrillInstructions(
            goal: "Measures whether you know where you are in the music without counting.",
            steps: [
                "A drum groove plays in phrases — 8 bars each by default.",
                cue,
                target,
                "Play whatever you like on the keys between marks, or nothing at all.",
            ],
            pitfalls: pitfalls,
            measures: "How many phrase tops you found on the correct bar, and how close to the "
                    + "downbeat you landed.")
    }

    /// The continuation drill's instructions **for the note value being asked for**.
    ///
    /// The text has said "ONE NOTE PER BEAT" since M6 while the analysis inferred the note value
    /// from what was played. Now that the drill can ask for something else, the words and the
    /// analysis are driven by the same parameter — which is R3.6, and the reason `nil` still
    /// yields the quarter-note text unchanged rather than something vaguer.
    public static func dropout(rung: IntervalRung?) -> DrillInstructions {
        guard let rung, rung != .quarters else { return dropout }
        let each: String
        switch rung {
        case .eighths:        each = "TWO NOTES PER BEAT"
        case .tripletEighths: each = "THREE NOTES PER BEAT"
        case .sixteenths:     each = "FOUR NOTES PER BEAT"
        case .quarters:       each = "ONE NOTE PER BEAT"
        }
        return DrillInstructions(
            goal: "Measures whether your unsteadiness comes from your sense of time or from "
                + "your hands — at \(rung.label) rather than at the beat.",
            steps: [
                "The drums play for a few bars, then stop completely, then come back with a crash.",
                "Play exactly \(each) — steady \(rung.label) — from start to finish.",
                "Keep going through the silence at the same speed. The silence is the measurement.",
                "Any note works. Pitch is irrelevant; only when you play matters.",
            ],
            pitfalls: [
                "Don't drop back to a coarser note value when it gets hard. The drill was set at "
                + "\(rung.label), and a silence at a different one cannot be scored against it.",
                "Don't stop or pause during the silence — that is the only part being measured.",
                "Don't speed up to 'catch' the band when it returns. Hold your pulse and let it "
                + "land where it lands.",
            ],
            measures: "The tempo you hold unaccompanied at this note value, and — when the "
                    + "playing is steady enough — whether the wobble comes from your internal "
                    + "pulse or your hands.")
    }

    public static let dropout = DrillInstructions(
        goal: "Measures whether your unsteadiness comes from your sense of time or from your hands.",
        steps: [
            "The drums play for a few bars, then stop completely, then come back with a crash.",
            "Play exactly ONE NOTE PER BEAT — steady quarter notes — from start to finish.",
            "Keep going through the silence at the same speed. The silence is the measurement.",
            "Any note works. Pitch is irrelevant; only when you play matters.",
        ],
        pitfalls: [
            "Don't subdivide. Adding eighth notes makes a silence unusable and it gets discarded.",
            "Don't stop or pause during the silence — that is the only part being measured.",
            "Don't speed up to 'catch' the band when it returns. Hold your pulse and let it land where it lands.",
        ],
        measures: "The tempo you hold unaccompanied, and — when the playing is steady enough — "
                + "whether the wobble comes from your internal pulse or your hands.")

    /// The tempo drill's instructions for the note value being asked for. See `dropout(rung:)`.
    public static func tempo(rung: IntervalRung?) -> DrillInstructions {
        guard let rung, rung != .quarters else { return tempo }
        let each: String
        switch rung {
        case .eighths:        each = "TWO NOTES PER BEAT"
        case .tripletEighths: each = "THREE NOTES PER BEAT"
        case .sixteenths:     each = "FOUR NOTES PER BEAT"
        case .quarters:       each = "ONE NOTE PER BEAT"
        }
        return DrillInstructions(
            goal: "Trains your sense of a specific tempo by telling you what you actually "
                + "produced — held in \(rung.label).",
            steps: [
                "The click counts a few bars at the target tempo.",
                "When it stops, keep playing \(each) at that same tempo.",
                "After each round you are told the tempo you produced and how far off it was.",
                "The click returns at the correct tempo — use it to correct, then go again.",
            ],
            pitfalls: [
                "Don't change note value mid-round. The round was set at \(rung.label), and one "
                + "played at another cannot be scored against it.",
                "Don't try to count seconds. Feel the tempo and let your hands keep it.",
                "Don't stop early in the silence; the round needs several notes to measure.",
            ],
            measures: "The tempo you produce unaccompanied each round, and whether your accuracy "
                    + "improves across the session.")
    }

    public static let tempo = DrillInstructions(
        goal: "Trains your sense of a specific tempo by telling you what you actually produced.",
        steps: [
            "The click counts a few bars at the target tempo.",
            "When it stops, keep playing ONE NOTE PER BEAT at that same tempo.",
            "After each round you are told the tempo you produced and how far off it was.",
            "The click returns at the correct tempo — use it to correct, then go again.",
        ],
        pitfalls: [
            "Don't subdivide or double up — one note per beat, or the round can't be scored.",
            "Don't try to count seconds. Feel the tempo and let your hands keep it.",
            "Don't stop early in the silence; the round needs several beats to measure.",
        ],
        measures: "The tempo you produce unaccompanied each round, and whether your accuracy "
                + "improves across the session.")

    public static let memory = DrillInstructions(
        goal: "Measures whether you can store a tempo, or only hold one by keeping it going.",
        steps: [
            "The groove plays for a few bars. Play along and let the tempo settle in.",
            "A snare fill in the last bar warns you the groove is about to stop.",
            "When it stops, STOP PLAYING and wait. Some waits are silent, some are filled "
                + "with scattered percussion.",
            "A crash and kick together mark the end of the wait. From there, play ONE NOTE "
                + "PER BEAT at the tempo you heard.",
            "The groove returns at the right tempo, and the next round begins.",
        ],
        pitfalls: [
            "Don't keep playing during the wait — that keeps the pulse running, which is the "
                + "Alone drill, not this one. The round is discarded.",
            "Don't try to follow the scattered percussion. It is deliberately unrelated to "
                + "the tempo and following it will pull you off.",
            "Don't count through the wait. If counting is what holds the tempo, the filled "
                + "waits will show it — that is the finding, not a failure.",
        ],
        measures: "How accurately you reproduce the tempo after an empty wait against a "
                + "filled one. A gap between the two means the period is being held by "
                + "attention rather than stored.")

    public static let groove = DrillInstructions(
        goal: "Just the backing track. Nothing is recorded or measured.",
        steps: [
            "A drum groove plays for the length you chose.",
            "Play whatever you want over it.",
        ],
        pitfalls: [],
        measures: "Nothing — this is for warming up or playing for its own sake.")

    /// Plain-text rendering for the console.
    public func consoleText(bold: String = "", reset: String = "", dim: String = "") -> String {
        var lines = ["\(dim)\(goal)\(reset)", ""]
        lines += steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        if !pitfalls.isEmpty {
            lines += ["", "  \(bold)Avoid:\(reset)"]
            lines += pitfalls.map { "    • \($0)" }
        }
        lines += ["", "  \(dim)Reports: \(measures)\(reset)"]
        return lines.joined(separator: "\n")
    }
}

public extension DrillInstructions {
    /// The instructions for a planned block, **from the block rather than its plan**.
    ///
    /// Taking the plan alone was the bug this replaced: the plan knows the drill and its
    /// settings, and knows nothing about the experiment arm — so an instruction-only condition
    /// would have shown the generic jam text on both surfaces and run neither arm while
    /// recording one. R3.6 is that instructions come from the configuration that will actually
    /// run, and for an experiment the arm *is* part of that configuration.
    ///
    /// One mapping, not one per surface. The console and the app each had their own copy, which
    /// is precisely how a drill comes to mean two different things depending on where it was
    /// started (§7.11).
    static func forBlock(_ block: SessionBlock) -> DrillInstructions {
        switch block.plan {
        case .groove:      return .groove
        case .jam(let p):
            // The arm wins when there is one. An experiment take runs at the benchmark's locked
            // settings and never carries a rung (R3.5), so the two cannot both be set — and if
            // a future design ever does both, the arm is the independent variable and losing it
            // would swap the conditions, which is the worse failure of the two.
            if let arm = block.experiment?.arm { return .jam(arm: arm) }
            return .jam(rung: p.rung, feel: p.feel)
        case .form(let p): return .form(level: p.level)
        case .dropout(let p): return .dropout(rung: p.rung)
        case .tempo(let p):   return .tempo(rung: p.rung)
        case .memory:      return .memory
        }
    }
}
