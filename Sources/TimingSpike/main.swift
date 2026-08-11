import Foundation
import TrainerKit

// Musical Trainer — timing spike and calibration tool.
//
//   selftest          verify the analysis maths against synthetic data (no hardware)
//   midimon [seconds] diagnose MIDI delivery — a length watches a whole session
//   validate          M0: full two-path bridge validation with the four pass criteria
//   calibrate         M1: full calibration — loopback + two-path, becomes the reference
//   calibrate quick   M1: loopback only, derives its constant from the reference
//   show              print stored calibration
//
// See PLAN.md §4.2 for the measurement design and §7.1 for M0 results.

// Line-buffer stdout so a redirected or piped run writes as it goes.
//
// C stdio block-buffers when stdout is not a terminal, so `midimon 3000 | tee log` held every
// line in a 4 KB buffer and ^C — SIGINT, which does not flush — threw the lot away. A whole
// session was watched and the log came back **empty**, with the monitor's own header still
// sitting in the buffer, so a working run and a broken one looked identical from the outside
// (`LESSONS.md` shape 16, PLAN.md §7.37).
//
// Global rather than inside `midimon`: every readout here is something somebody may pipe into a
// file, and per-line writes cost nothing at the rate a CLI prints.
setvbuf(stdout, nil, _IOLBF, 0)

let rawArguments = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    Usage: TimingSpike <command>

      selftest          verify the analysis maths (no hardware needed)
      midimon [seconds] diagnose MIDI delivery (default 20). Pass a length to watch
                        a whole session and see whether the keyboard stops sending.
      validate          M0 bridge validation — the four pass criteria
      calibrate         full calibration, becomes the reference device
      calibrate quick   loopback-only calibration for another output device
      calibrate reset   delete all stored calibration
      groove [bpm]      M3: play a synthesized groove + dropout ladder (default 100)
      jam [bpm] [bars] [tag] [rung] [swing]
                        M4: record a take and analyze it (default 100, 32; tag e.g. relaxed).
                        M14: a rung asks for a subdivision and scores against it --
                        quarters, eighths, tripletEighths, sixteenths. Omit it to play free.
                        M15: a swing ratio (1-4) places the offbeat late. 1 is straight,
                        2 is the usual triplet feel. Needs a binary rung.
                        M19: --style <name> plays over a generated backing instead of the
                        fixed one, and --seed <hex> rebuilds an exact piece. A style
                        nobody has played over yet needs --probe as well.
      form [bpm] [bars] [phraseBars] [level]
                        phrase-mark drill: hit a pad at each phrase top, no counting
                        (default 100, 64, 8, level 0; levels 0-3 remove the landmarks)
      offbeat [bpm] [bars] [level]
                        M15: ska and reggae. Play on every offbeat while the downbeat
                        disappears -- levels 0-3 remove the kick, then the backbeat,
                        then everything on a beat. (default 70, 32, 0)
      dropout [bpm] [pacedBars] [silentBars] [cycles] [rung]
                        continuation drill: play a steady note value through the silences.
                        The only drill that yields a clock/motor split. (100, 4, 4, 6,
                        quarters). A rung asks for that note value and scores against it.
      tempo [bpm ...]   M8: produce a tempo unaccompanied and be told what you produced.
                        Pass several to rotate the target (e.g. tempo 76 100 132).
      memory [bpm] [waitBars] [rounds]
                        M11: hear a tempo, wait through the gap, reproduce it. Half the
                        waits are silent and half are filled. (100, 4, 8)
      session [minutes] M9: run a whole planned session end to end (default 30).
      session plan [minutes]
                        print what it would do, and why, without running it
      review [n]        re-analyze the latest saved take, or take n
      review list       list all takes
      review compare [i j]      two takes side by side, with significance
      review experiment         what the A/B experiments have collected
      review tags               pooled summary of every tagged condition
      review conditions <a> <b> pooled comparison of two conditions
      review feel               does your sense of a good take match the measurement?
      review form               form-drill history
      review dropout            clock/motor split over time
      review trend              is anything actually improving?
      review cold               M10: is it warming up, or getting better?
      review content            M12: does what you play change your timing?
      review tempo              tempo-calibration history
      review interval           M14: does tempo change how you play?
      render [bpm] [bars]
                        render each ladder backing to temp/renders as a WAV,
                        so a groove can be judged by ear without a live run
      show              print stored calibration

    Flags, anywhere on the line:

      --probe           record this take as a deliberate look at a setting you have
                        not earned. Stored apart and ignored by everything that
                        decides what to practise next, so trying form level 3 or a
                        rung above your ceiling cannot move a ladder. Applies to
                        jam, form and offbeat.
    """)
}

do {
    // Flags come out first, so `--probe` may sit anywhere on the line and every positional
    // argument below keeps counting from zero. An unknown flag throws rather than being
    // dropped: a mistyped `--porbe` that quietly ran an ordinary take would record it as
    // earned, which is the exact corruption the flag exists to prevent. Parsed **inside** the
    // catch, or the refusal arrives as a Swift crash dump instead of a sentence.
    let (flags, arguments) = try CommandFlags.parse(rawArguments)

    switch arguments.first {
    case "selftest":
        exit(SelfTest.run() ? 0 : 1)

    case "midimon":
        // Default 20 s is a "does the keyboard work" check. A length is what lets it run
        // beside a whole session, which is the only way to tell a source that stopped sending
        // from an app that stopped listening — see PLAN.md §7.36.
        let watchFor = arguments.dropFirst().first.flatMap(Double.init) ?? 20
        MIDIMonitor.run(seconds: min(max(watchFor, 1), 4 * 3600))

    case "validate":
        try Commands.runValidation()

    case "calibrate":
        switch arguments.dropFirst().first {
        case "quick": try Commands.runCalibrate(quick: true)
        case "reset": try Commands.runReset()
        case nil:     try Commands.runCalibrate(quick: false)
        case let sub?: throw SpikeError("Unknown calibrate mode: \(sub). Use quick or reset.")
        }

    case "groove":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        try Commands.runGroove(bpm: bpm)

    case "jam":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let bars = arguments.dropFirst(2).first.flatMap(Int.init) ?? 32
        try Commands.runJam(bpm: bpm, bars: bars, tag: arguments.dropFirst(3).first,
                            rung: arguments.dropFirst(4).first,
                            swing: arguments.dropFirst(5).first, flags: flags)

    case "form":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let bars = arguments.dropFirst(2).first.flatMap(Int.init) ?? 64
        let phrase = arguments.dropFirst(3).first.flatMap(Int.init) ?? 8
        let level = arguments.dropFirst(4).first.flatMap(Int.init) ?? 0
        try Commands.runForm(bpm: bpm, bars: bars, phraseBars: phrase, level: level,
                             flags: flags)

    case "dropout":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let paced = arguments.dropFirst(2).first.flatMap(Int.init) ?? 4
        let silent = arguments.dropFirst(3).first.flatMap(Int.init) ?? 4
        let cycles = arguments.dropFirst(4).first.flatMap(Int.init) ?? 6
        try Commands.runDropout(bpm: bpm, pacedBars: paced, silentBars: silent,
                                cycles: cycles, rung: arguments.dropFirst(5).first)

    case "tempo":
        // Several tempos rotate the target: "tempo 76 100 132".
        let targets = arguments.dropFirst().compactMap(Double.init)
        try Commands.runTempo(targets: targets.isEmpty ? [100] : targets,
                              leadBars: 4, holdBars: 4, rounds: 8)

    case "offbeat":
        // 70 rather than 100, because at 100 the chop sits 300 ms from the beat either side and
        // the feel inverted: the only take there put 23% of its notes off the beat, against 96%
        // at 69. Grounded in those two takes rather than derived — see PLAN.md §7.38, which also
        // says what would falsify it. A faster offbeat is still reachable by asking for one.
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 70
        let bars = arguments.dropFirst(2).first.flatMap(Int.init) ?? 32
        let level = arguments.dropFirst(3).first.flatMap(Int.init) ?? 0
        try Commands.runOffbeat(bpm: bpm, bars: bars, level: level, flags: flags)

    case "session":
        // `session plan [minutes]` prints the choices without committing the evening to them.
        let rest = Array(arguments.dropFirst())
        if rest.first == "plan" {
            Commands.runSessionPlan(targetMinutes: rest.dropFirst().first.flatMap(Int.init) ?? 30)
        } else {
            try Commands.runSession(targetMinutes: rest.first.flatMap(Int.init) ?? 30)
        }

    case "memory":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let wait = arguments.dropFirst(2).first.flatMap(Int.init) ?? 4
        let rounds = arguments.dropFirst(3).first.flatMap(Int.init) ?? 8
        try Commands.runMemory(bpm: bpm, retentionBars: wait, rounds: rounds)

    case "review":
        try Commands.runReview(Array(arguments.dropFirst()))

    case "render":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let bars = arguments.dropFirst(2).first.flatMap(Int.init) ?? 8
        try Commands.runRender(bpm: bpm, bars: bars,
                               into: URL(fileURLWithPath: "temp/renders"), flags: flags)

    case "show":
        try Commands.runShow()

    case nil, "help", "-h", "--help":
        usage()

    case let other?:
        Console.error("Unknown command: \(other)\n")
        usage()
        exit(1)
    }
} catch {
    Console.error("\n\(error.localizedDescription)")
    exit(1)
}
