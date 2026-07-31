import Foundation

enum Commands {

    // MARK: - Shared environment check

    struct Environment {
        let output: AudioDevices.Info
        let input: AudioDevices.Info
    }

    /// Resolve and report the audio devices, refusing configurations that cannot be
    /// calibrated. Bluetooth is rejected outright: its latency varies run to run, so no
    /// stored constant can ever be correct.
    static func checkEnvironment(verbose: Bool = true) throws -> Environment {
        guard let output = AudioDevices.defaultDevice(input: false),
              let input = AudioDevices.defaultDevice(input: true) else {
            throw SpikeError("Could not resolve default audio devices.")
        }

        if verbose {
            let source = output.dataSource.map { " — \($0)" } ?? ""
            print("Output: \(output.name)\(source)  @ \(Int(output.sampleRate)) Hz  [\(output.transport)]")
            print("        reported latency \(output.reportedLatencyFrames) frames, "
                + "safety offset \(output.safetyOffsetFrames), buffer \(output.bufferFrameSize)")
            print("Input:  \(input.name)  @ \(Int(input.sampleRate)) Hz  [\(input.transport)]")
            print("        reported latency \(input.reportedLatencyFrames) frames, "
                + "safety offset \(input.safetyOffsetFrames), buffer \(input.bufferFrameSize)")
        }

        if output.isBluetooth || input.isBluetooth {
            throw SpikeError("""
                Bluetooth audio detected. Its latency varies run to run and cannot be
                calibrated away. Switch to built-in or wired devices.
                """)
        }
        if abs(output.sampleRate - input.sampleRate) > 1 {
            Console.warn("""
                input and output run at different sample rates — they are almost certainly
                on independent clocks. Watch the drift figure closely.
                """)
        }

        AudioDevices.setBufferFrameSize(256, on: output.id)
        return Environment(output: output, input: input)
    }

    static func startMIDI() throws -> MIDIInput {
        let midi = MIDIInput()
        try midi.start()
        print("\nMIDI listening on: \(midi.sourceNames.joined(separator: ", "))")
        if !midi.skippedSources.isEmpty {
            print("Ignoring control-surface ports: \(midi.skippedSources.joined(separator: ", "))")
        }
        return midi
    }

    // MARK: - M0 validation rig

    static func runValidation() throws {
        Console.heading("Environment")
        let env = try checkEnvironment()
        let midi = try startMIDI()
        defer { midi.stop() }

        Console.heading("Phase 1 — Round-trip latency")
        Console.prompt("""
            Set output to your INTERNAL SPEAKERS at a comfortable volume, and make sure
            nothing is covering the built-in microphone. This measures output latency + air
            travel + input latency by playing 24 chirps and finding them in the recording.
            """)

        print("Measuring...")
        let loopback = try Procedures.loopback()
        try reportLoopback(loopback)

        Console.heading("Phase 2 — Bridge validation (two-path)")
        Console.prompt("""
            Now the real test. A chirp plays once per second through the speakers.

              • Hit ONE key on the Launchkey, FIRMLY, roughly HALFWAY BETWEEN each pair of
                chirps.
              • Accuracy does not matter — we are not measuring your timing here. The
                strike only needs to be well clear of the chirps so the two can be told
                apart.
              • It must be audible to the microphone, so hit it like you mean it.

            This runs for about 100 seconds.
            """)

        let (result, bufferFrames) = try Procedures.twoPath(midi: midi)
        reportValidation(result, bufferFrames: bufferFrames, deviceName: env.output.identity)
    }

    @discardableResult
    private static func reportLoopback(_ outcome: Procedures.LoopbackOutcome) throws -> LatencyResult {
        let r = outcome.latency
        print("\nChirps emitted:  \(r.chirpsExpected)")
        print("Chirps detected: \(r.chirpsFound)")
        if let measured = outcome.measuredInputClock {
            print(String(format: "Input clock:     %.2f Hz measured vs %.0f Hz nominal",
                         measured, outcome.inputSampleRate))
        }
        guard r.roundTripMs.count >= 8 else {
            throw SpikeError("Too few chirps detected. Raise the volume or move the mic closer.")
        }

        print("\nRound trip:  median \(Console.ms(r.median))   IQR \(Console.ms(r.iqr))   "
            + "SD \(Console.ms(r.sd))")

        if let drift = r.driftFit {
            let perMinute = drift.slope * 60
            let locked = abs(perMinute) < 1.0
            print(String(format: "Clock drift: %.3f ms/min  (r = %.3f)  %@",
                         perMinute, drift.r,
                         locked ? "— devices are clock-locked" : "— DRIFTING"))
            print("\nCheck #3 (no clock drift): \(Console.verdict(locked))")
        }
        return r
    }

    private static func reportValidation(_ result: ValidationResult,
                                         bufferFrames: UInt32,
                                         deviceName: String) {
        Console.heading("Results")
        print("Chirps detected:   \(result.chirpsFound)")
        print("MIDI notes:        \(result.midiNotes)")
        print("Key strikes heard: \(result.thocksDetected)")
        print("Paired beats:      \(result.pairedBeats)"
            + "   (\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched)")

        guard result.pairedBeats >= 20 else {
            Console.error("\nNot enough paired beats to draw conclusions.")
            explainPairingFailure(result)
            return
        }

        print("\nResidual (MIDI path − audio path):")
        print("  median \(Console.ms(result.median))   SD \(Console.ms(result.sd))   "
            + "IQR \(Console.ms(result.iqr))")

        let sdPass = result.sd < 1.0
        print("\nCheck #1 — residual SD < 1 ms:        \(Console.verdict(sdPass))  "
            + "(\(Console.ms(result.sd)))")

        if let fit = result.phaseFit {
            let acrossBuffer = fit.slope * Double(max(bufferFrames, 1))
            let pass = abs(acrossBuffer) < 0.5
            print(String(format: "Check #2 — no buffer-phase dependence: %@  (%.3f ms across a buffer, r = %.3f)",
                         Console.verdict(pass), acrossBuffer, fit.r))
            if !pass {
                Console.error("           The host-time to sample-index conversion is wrong.")
            }
        }
        if let fit = result.timeFit {
            let perMinute = fit.slope * 60
            print(String(format: "Check #3 — no drift over time:        %@  (%.3f ms/min, r = %.3f)",
                         Console.verdict(abs(perMinute) < 1.0), perMinute, fit.r))
        }

        print("\nCheck #4 — calibration constant:      \(Console.ms(result.median))")

        Console.heading("Verdict")
        if sdPass {
            print("The clock bridge is sound. The foundation holds.")
            print("\nStore this as a calibration with:  TimingSpike calibrate")
        } else {
            print("The bridge is not stable enough to build on. Investigate before proceeding.")
        }
    }

    private static func explainPairingFailure(_ result: ValidationResult) {
        if result.midiNotes == 0 {
            print("""

            No MIDI arrived at all — the microphone side is fine, this is the keyboard.
            Diagnose it with:  TimingSpike midimon
            """)
        } else if result.thocksDetected < 20 {
            print("""

            MIDI arrived (\(result.midiNotes) notes) but the microphone heard almost no key
            strikes. Move the mic closer to the keyboard and strike harder.
            """)
        } else {
            print("""

            Both inputs produced data (\(result.midiNotes) notes, \(result.thocksDetected) strikes)
            but they could not be paired. Try a quieter room, or strike closer to halfway
            between chirps.
            """)
        }
    }

    // MARK: - M1 calibration

    static func runReset() throws {
        let url = Calibration.storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No calibration stored — nothing to reset.")
            return
        }
        guard Console.confirm("Delete all stored calibration?") else {
            print("Left unchanged.")
            return
        }
        try FileManager.default.removeItem(at: url)
        print("Calibration cleared.")
    }

    static func runCalibrate(quick: Bool) throws {
        Console.heading(quick ? "Quick calibration (loopback only)" : "Full calibration")
        let env = try checkEnvironment()
        var store = Calibration.load()
        let identity = env.output.identity
        let displayName = env.output.dataSource.map { "\(env.output.name) — \($0)" } ?? env.output.name

        if quick, store.referenceDevice == nil {
            throw SpikeError("""
                No reference calibration exists yet. Run a full calibration first:
                    TimingSpike calibrate
                """)
        }
        if quick, store.devices[identity]?.residualMs != nil {
            Console.warn("this device already has a directly-measured constant. A quick run "
                + "will refresh its loopback figures but keep that constant.")
        }

        print("\nCalibrating output device: \(Console.bold)\(displayName)\(Console.reset)")
        if let existing = store.devices[identity] {
            Console.warn("this device was already calibrated on "
                + "\(existing.measuredAt.formatted(date: .abbreviated, time: .shortened)) — it will be updated.")
        }

        print("""

        The microphone must hear this device. For internal speakers that is automatic; for
        headphones, rest one earcup against the built-in microphone.
        """)
        let centimetres = Console.readDouble(
            "Distance from the sound source to the microphone, in cm", default: 15)
        let airPath = Calibration.airPathMs(centimetres: centimetres)
        print("  → acoustic travel \(Console.ms(airPath, 3))")

        Console.prompt("Ready to measure round-trip latency (about 12 seconds).")
        print("Measuring...")
        let loopback = try Procedures.loopback()
        let latency = try reportLoopback(loopback)

        if latency.sd > 0.5 {
            Console.warn("round-trip SD is \(Console.ms(latency.sd)) — unusually noisy. "
                + "Check for background noise before trusting this.")
        }

        var device = Calibration.Device(
            displayName: displayName,
            roundTripMs: latency.median,
            roundTripSD: latency.sd,
            airPathMs: airPath,
            sampleRate: loopback.outputSampleRate,
            bufferFrames: env.output.bufferFrameSize,
            measuredAt: Date(),
            residualMs: nil,
            residualSD: nil)

        if !quick {
            let midi = try startMIDI()
            defer { midi.stop() }
            store.midiSource = midi.sourceNames.first

            Console.prompt("""
                Now the two-path measurement, which pins down MIDI latency as well.

                  • Hit ONE key, FIRMLY, roughly halfway between each pair of chirps.
                  • Your accuracy is irrelevant; the strike only needs to be clear of the
                    chirps and audible to the microphone.

                About 100 seconds.
                """)

            let (result, bufferFrames) = try Procedures.twoPath(midi: midi)
            print("\nPaired beats: \(result.pairedBeats)"
                + "   (\(result.trimmedBeats) trimmed, \(result.unmatchedNotes) unmatched)")

            guard result.pairedBeats >= 20 else {
                explainPairingFailure(result)
                throw SpikeError("Calibration aborted — not enough paired beats.")
            }
            guard result.sd < 1.0 else {
                throw SpikeError("Residual SD is \(Console.ms(result.sd)), too unstable to "
                               + "store as a calibration. Re-run in a quieter room.")
            }
            _ = bufferFrames

            print("Residual: median \(Console.ms(result.median))   SD \(Console.ms(result.sd))")
            device.residualMs = result.median
            device.residualSD = result.sd
            store.referenceDevice = identity
        }

        store.record(identity: identity, device)
        try store.save()

        Console.heading("Stored")
        printCalibration(store, highlighting: identity)
        print("\n\(Console.dim)\(Calibration.storeURL.path)\(Console.reset)")
    }

    static func runShow() throws {
        let store = Calibration.load()
        Console.heading("Calibration")
        guard !store.devices.isEmpty else {
            print("Nothing stored yet. Run:  TimingSpike calibrate")
            return
        }
        let current = AudioDevices.defaultDevice(input: false)?.identity
        printCalibration(store, highlighting: current)
        print("\n\(Console.dim)\(Calibration.storeURL.path)\(Console.reset)")

        if let current, store.devices[current] == nil {
            print("")
            Console.warn("""
                the current output device (\(current)) has no calibration.
                    TimingSpike calibrate quick
                """)
        }
    }

    private static func printCalibration(_ store: Calibration, highlighting current: String?) {
        if let source = store.midiSource { print("MIDI source: \(source)") }
        if let reference = store.referenceDevice { print("Reference:   \(reference)") }
        print("")

        for identity in store.devices.keys.sorted() {
            guard let device = store.devices[identity] else { continue }
            let marker = identity == current ? "▸ " : "  "
            let emphasis = identity == current ? Console.bold : ""
            let isReference = identity == store.referenceDevice
            print("\(marker)\(emphasis)\(device.displayName)\(Console.reset)"
                + (isReference ? "  \(Console.dim)(reference)\(Console.reset)" : ""))
            print("    round trip   \(Console.ms(device.roundTripMs))  (SD \(Console.ms(device.roundTripSD)))")
            print("    air path     \(Console.ms(device.airPathMs, 3))")

            if let constant = store.constant(for: identity) {
                switch constant.source {
                case .measured:
                    print("    constant     \(Console.bold)\(Console.ms(constant.value))\(Console.reset)"
                        + "  measured directly"
                        + (constant.sd.map { " (SD \(Console.ms($0)))" } ?? ""))
                case .derived(let from):
                    let fromName = store.devices[from]?.displayName ?? from
                    print("    constant     \(Console.bold)\(Console.ms(constant.value))\(Console.reset)"
                        + "  derived from \(fromName)")
                }
            } else {
                print("    constant     \(Console.yellow)unavailable — no reference calibration\(Console.reset)")
            }
            print("    measured     \(device.measuredAt.formatted(date: .abbreviated, time: .shortened))")
        }

        print("""

        \(Console.dim)The constant is L_midi + L_out: subtract it from (midiHostTime −
        clickEmitHostTime) to get true asynchrony.\(Console.reset)
        """)
    }
}
