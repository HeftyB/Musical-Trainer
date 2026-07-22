import AVFoundation
import Foundation

// M0 — timing spike and ground-truth rig.
//
// Validates the mach_absolute_time <-> audio-sample-index bridge that every number this
// project will ever produce depends on. See PLAN.md §4.2 for the algebra and the four
// pass criteria.
//
//   swift run TimingSpike selftest   verify the analysis maths, no hardware needed
//   swift run TimingSpike            run the live rig

let chirpDuration = 0.020

func heading(_ text: String) {
    print("\n\u{001B}[1m\(text)\u{001B}[0m")
    print(String(repeating: "─", count: max(text.count, 40)))
}

func ms(_ value: Double, _ digits: Int = 2) -> String {
    value.isNaN ? "n/a" : String(format: "%.\(digits)f ms", value)
}

func verdict(_ pass: Bool) -> String {
    pass ? "\u{001B}[32mPASS\u{001B}[0m" : "\u{001B}[31mFAIL\u{001B}[0m"
}

func prompt(_ text: String) {
    print("\n\(text)")
    print("Press return when ready... ", terminator: "")
    _ = readLine()
}

if CommandLine.arguments.contains("selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if CommandLine.arguments.contains("midimon") {
    MIDIMonitor.run()
    exit(0)
}

// MARK: - Environment

heading("Environment")

guard let output = AudioDevices.defaultDevice(input: false),
      let input = AudioDevices.defaultDevice(input: true) else {
    print("Could not resolve default audio devices.")
    exit(1)
}

print("Output: \(output.name)  @ \(Int(output.sampleRate)) Hz  [\(output.transport)]")
print("        reported latency \(output.reportedLatencyFrames) frames, "
    + "safety offset \(output.safetyOffsetFrames), buffer \(output.bufferFrameSize)")
print("Input:  \(input.name)  @ \(Int(input.sampleRate)) Hz  [\(input.transport)]")
print("        reported latency \(input.reportedLatencyFrames) frames, "
    + "safety offset \(input.safetyOffsetFrames), buffer \(input.bufferFrameSize)")

if output.isBluetooth || input.isBluetooth {
    print("\n\u{001B}[31mBluetooth audio detected.\u{001B}[0m Latency varies run to run and cannot be")
    print("calibrated away. Switch to built-in or wired devices before measuring.")
    exit(1)
}

if abs(output.sampleRate - input.sampleRate) > 1 {
    print("\n\u{001B}[33mWarning:\u{001B}[0m input and output run at different sample rates.")
    print("They are almost certainly on independent clocks — watch check #3 closely.")
}

AudioDevices.setBufferFrameSize(256, on: output.id)

let midi = MIDIInput()
do {
    try midi.start()
    print("\nMIDI listening on: \(midi.sourceNames.joined(separator: ", "))")
    if !midi.skippedSources.isEmpty {
        print("Ignoring control-surface ports: \(midi.skippedSources.joined(separator: ", "))")
    }
    if !midi.sourceNames.contains(where: { $0.lowercased().contains("launchkey") }) {
        print("\u{001B}[33mNote:\u{001B}[0m no Launchkey found. Any MIDI source will work for the test.")
    }
} catch {
    print("MIDI unavailable: \(error.localizedDescription)")
    exit(1)
}

// MARK: - Phase 1: round-trip latency

heading("Phase 1 — Round-trip latency")

prompt("""
Set output to your INTERNAL SPEAKERS at a comfortable volume, and make sure nothing
is covering the built-in microphone. This measures output latency + air travel + input
latency by playing 24 chirps and finding them in the recording.
""")

let latencyChirps = 24
let latencyInterval = 0.4

do {
    let io = try AudioIO(maxCaptureSeconds: 20, chirpDuration: chirpDuration)
    let intervalSamples = Int(latencyInterval * io.outputSampleRate)
    let leadIn = Int(1.0 * io.outputSampleRate)
    io.schedule(starts: (0..<latencyChirps).map { Int64(leadIn + $0 * intervalSamples) })

    print("Measuring...")
    try io.run(forSeconds: 1.0 + Double(latencyChirps) * latencyInterval + 1.0)

    let emissions = io.emissions
    guard let epoch = emissions.first?.bufferHostTime else {
        print("No chirps were emitted — the audio engine produced no output.")
        exit(1)
    }

    var inputMap = SampleHostMap()
    inputMap.build(pairs: io.inputMapPairs, epoch: epoch)

    let result = Analysis.measureLatency(
        capture: io.capturedAudio,
        emitHostSeconds: emissions.map { io.emissionHostSeconds($0, epoch: epoch) },
        inputMap: inputMap,
        inputSampleRate: io.inputSampleRate,
        chirpDuration: chirpDuration,
        beatSeconds: latencyInterval)

    print("\nChirps emitted:  \(result.chirpsExpected)")
    print("Chirps detected: \(result.chirpsFound)")

    if let measured = inputMap.measuredSampleRate {
        print(String(format: "Input clock:     %.2f Hz measured vs %.0f Hz nominal",
                     measured, io.inputSampleRate))
    }

    guard result.roundTripMs.count >= 8 else {
        print("\n\u{001B}[31mToo few chirps detected.\u{001B}[0m Raise the volume or move the mic closer.")
        exit(1)
    }

    print("\nRound trip:  median \(ms(result.median))   IQR \(ms(result.iqr))   SD \(ms(result.sd))")

    if let drift = result.driftFit {
        let msPerMinute = drift.slope * 60
        let locked = abs(msPerMinute) < 1.0
        print(String(format: "Clock drift: %.3f ms/min  (r = %.3f)  %@",
                     msPerMinute, drift.r, locked ? "— devices are clock-locked" : "— DRIFTING"))
        print("\nCheck #3 (no clock drift): \(verdict(locked))")
    }
} catch {
    print("Phase 1 failed: \(error.localizedDescription)")
    exit(1)
}

// MARK: - Phase 2: two-path bridge validation

heading("Phase 2 — Bridge validation (two-path)")

prompt("""
Now the real test. A chirp plays once per second through the speakers.

  • Hit ONE key on the Launchkey, FIRMLY, roughly HALFWAY BETWEEN each pair of chirps.
  • Accuracy does not matter at all — we are not measuring your timing here. We only
    need each key strike to be well clear of the chirps so the two can be told apart.
  • The strike must be audible to the microphone, so hit it like you mean it.

This runs for about 100 seconds.
""")

let beats = 100
let beatSeconds = 1.0

do {
    let io = try AudioIO(maxCaptureSeconds: Double(beats) * beatSeconds + 10, chirpDuration: chirpDuration)
    let beatSamples = Int(beatSeconds * io.outputSampleRate)
    let leadIn = Int(2.0 * io.outputSampleRate)
    io.schedule(starts: (0..<beats).map { Int64(leadIn + $0 * beatSamples) })

    midi.reset()
    print("Recording — start playing.")
    try io.run(forSeconds: 2.0 + Double(beats) * beatSeconds + 1.5)

    let emissions = io.emissions
    guard let epoch = emissions.first?.bufferHostTime else {
        print("No chirps were emitted.")
        exit(1)
    }

    print("Analysing...")
    let result = Analysis.validateBridge(
        capture: io.capturedAudio,
        emitHostSeconds: emissions.map { io.emissionHostSeconds($0, epoch: epoch) },
        phases: emissions.map { Double($0.phase) },
        noteHostSeconds: midi.events.map { HostClock.interval(from: epoch, to: $0.hostTime) },
        inputSampleRate: io.inputSampleRate,
        chirpDuration: chirpDuration,
        beatSeconds: beatSeconds)

    heading("Results")
    print("Chirps detected:   \(result.chirpsFound) / \(emissions.count)")
    print("MIDI notes:        \(result.midiNotes)")
    print("Key strikes heard: \(result.thocksDetected)")
    print("Paired beats:      \(result.pairedBeats)"
        + "   (\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched)")

    guard result.pairedBeats >= 20 else {
        print("\n\u{001B}[31mNot enough paired beats to draw conclusions.\u{001B}[0m")
        // Name the actual failing path. The two inputs fail for entirely different
        // reasons and conflating them sends you chasing the wrong one.
        if result.midiNotes == 0 {
            print("""

            No MIDI arrived at all — the microphone side is fine, this is the keyboard.
            Diagnose it with:

                ./.build/release/TimingSpike midimon
            """)
        } else if result.thocksDetected < 20 {
            print("""

            MIDI arrived (\(result.midiNotes) notes) but the microphone heard almost no key
            strikes. Move the mic closer to the keyboard and strike harder.
            """)
        } else {
            print("""

            Both inputs produced data (\(result.midiNotes) notes, \(result.thocksDetected) strikes)
            but they could not be paired. Likely too many spurious onsets — try a quieter
            room, or strike closer to halfway between chirps.
            """)
        }
        midi.stop()
        exit(1)
    }

    print("\nResidual (MIDI path − audio path):")
    print("  median \(ms(result.median))   SD \(ms(result.sd))   IQR \(ms(result.iqr))")

    let sdPass = result.sd < 1.0
    print("\nCheck #1 — residual SD < 1 ms:        \(verdict(sdPass))  (\(ms(result.sd)))")

    // Check #2. A correct bridge shows no relationship between error and where the chirp
    // fell inside the audio buffer. Expressed as ms of error across a full buffer, which
    // is the magnitude that would actually matter.
    if let fit = result.phaseFit {
        let acrossBuffer = fit.slope * Double(max(output.bufferFrameSize, 1))
        let pass = abs(acrossBuffer) < 0.5
        print(String(format: "Check #2 — no buffer-phase dependence: %@  (%.3f ms across a buffer, r = %.3f)",
                     verdict(pass), acrossBuffer, fit.r))
        if !pass {
            print("           \u{001B}[31mThe host-time to sample-index conversion is wrong.\u{001B}[0m")
        }
    }

    if let fit = result.timeFit {
        let perMinute = fit.slope * 60
        let pass = abs(perMinute) < 1.0
        print(String(format: "Check #3 — no drift over time:        %@  (%.3f ms/min, r = %.3f)",
                     verdict(pass), perMinute, fit.r))
    }

    print("\nCheck #4 — calibration constant:      \(ms(result.median))")
    print("""
               This is MIDI transport latency plus residual output latency. Its absolute
               value does not matter; it gets subtracted during calibration. What matters
               is that checks #1-#3 show it holds still.
    """)

    heading("Verdict")
    if sdPass {
        print("The clock bridge is sound. The foundation holds — proceed to M1.")
    } else {
        print("The bridge is not stable enough to build on. Investigate before proceeding.")
    }
} catch {
    print("Phase 2 failed: \(error.localizedDescription)")
    midi.stop()
    exit(1)
}

midi.stop()
