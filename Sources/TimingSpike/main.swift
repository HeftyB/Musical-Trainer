import Foundation
import TrainerKit

// Musical Trainer — timing spike and calibration tool.
//
//   selftest          verify the analysis maths against synthetic data (no hardware)
//   midimon           diagnose MIDI delivery
//   validate          M0: full two-path bridge validation with the four pass criteria
//   calibrate         M1: full calibration — loopback + two-path, becomes the reference
//   calibrate quick   M1: loopback only, derives its constant from the reference
//   show              print stored calibration
//
// See PLAN.md §4.2 for the measurement design and §7.1 for M0 results.

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    Usage: TimingSpike <command>

      selftest          verify the analysis maths (no hardware needed)
      midimon           diagnose MIDI delivery
      validate          M0 bridge validation — the four pass criteria
      calibrate         full calibration, becomes the reference device
      calibrate quick   loopback-only calibration for another output device
      calibrate reset   delete all stored calibration
      groove [bpm]      M3: play a synthesized groove + dropout ladder (default 100)
      jam [bpm] [bars] [tag]
                        M4: record a take and analyze it (default 100, 32; tag e.g. relaxed)
      form [bpm] [bars] [phraseBars] [level]
                        phrase-mark drill: hit a pad at each phrase top, no counting
                        (default 100, 64, 8, level 0; levels 0-3 remove the landmarks)
      review [n]        re-analyze the latest saved take, or take n
      review list       list all takes
      review compare [i j]      two takes side by side, with significance
      review tags               pooled summary of every tagged condition
      review conditions <a> <b> pooled comparison of two conditions
      review feel               does your sense of a good take match the measurement?
      show              print stored calibration
    """)
}

do {
    switch arguments.first {
    case "selftest":
        exit(SelfTest.run() ? 0 : 1)

    case "midimon":
        MIDIMonitor.run()

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
        try Commands.runJam(bpm: bpm, bars: bars, tag: arguments.dropFirst(3).first)

    case "form":
        let bpm = arguments.dropFirst().first.flatMap(Double.init) ?? 100
        let bars = arguments.dropFirst(2).first.flatMap(Int.init) ?? 64
        let phrase = arguments.dropFirst(3).first.flatMap(Int.init) ?? 8
        let level = arguments.dropFirst(4).first.flatMap(Int.init) ?? 0
        try Commands.runForm(bpm: bpm, bars: bars, phraseBars: phrase, level: level)

    case "review":
        try Commands.runReview(Array(arguments.dropFirst()))

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
