import Foundation

/// The two measurement procedures, shared by the M0 validation rig and M1 calibration.
enum Procedures {
    static let chirpDuration = 0.020

    struct LoopbackOutcome {
        let latency: LatencyResult
        let inputSampleRate: Double
        let outputSampleRate: Double
        /// Sample rate recovered from the host-time fit. Compared against nominal, this is
        /// a direct read on whether input and output really share a clock.
        let measuredInputClock: Double?
    }

    /// Play chirps, find them in the recording. Yields round-trip latency:
    /// output residual + acoustic travel + input residual.
    static func loopback(chirps: Int = 24, interval: Double = 0.4) throws -> LoopbackOutcome {
        let io = try AudioIO(maxCaptureSeconds: Double(chirps) * interval + 8,
                             chirpDuration: chirpDuration)
        let intervalSamples = Int(interval * io.outputSampleRate)
        let leadIn = Int(1.0 * io.outputSampleRate)
        io.schedule(starts: (0..<chirps).map { Int64(leadIn + $0 * intervalSamples) })

        try io.run(forSeconds: 1.0 + Double(chirps) * interval + 1.0)

        let emissions = io.emissions
        guard let epoch = emissions.first?.bufferHostTime else {
            throw SpikeError("No chirps were emitted — the audio engine produced no output.")
        }

        var inputMap = SampleHostMap()
        inputMap.build(pairs: io.inputMapPairs, epoch: epoch)

        let latency = Analysis.measureLatency(
            capture: io.capturedAudio,
            emitHostSeconds: emissions.map { io.emissionHostSeconds($0, epoch: epoch) },
            inputMap: inputMap,
            inputSampleRate: io.inputSampleRate,
            chirpDuration: chirpDuration,
            beatSeconds: interval)

        return LoopbackOutcome(latency: latency,
                               inputSampleRate: io.inputSampleRate,
                               outputSampleRate: io.outputSampleRate,
                               measuredInputClock: inputMap.measuredSampleRate)
    }

    /// The two-path measurement. Yields the residual `L_midi + L_out` for whatever output
    /// device is active — which is exactly the calibration constant.
    static func twoPath(midi: MIDIInput,
                        beats: Int = 100,
                        beatSeconds: Double = 1.0) throws -> (result: ValidationResult, bufferFrames: UInt32) {
        let io = try AudioIO(maxCaptureSeconds: Double(beats) * beatSeconds + 10,
                             chirpDuration: chirpDuration)
        let beatSamples = Int(beatSeconds * io.outputSampleRate)
        let leadIn = Int(2.0 * io.outputSampleRate)
        io.schedule(starts: (0..<beats).map { Int64(leadIn + $0 * beatSamples) })

        midi.reset()
        print("Recording — start playing.")
        try io.run(forSeconds: 2.0 + Double(beats) * beatSeconds + 1.5)

        let emissions = io.emissions
        guard let epoch = emissions.first?.bufferHostTime else {
            throw SpikeError("No chirps were emitted.")
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

        let bufferFrames = AudioDevices.defaultDevice(input: false)?.bufferFrameSize ?? 512
        return (result, bufferFrames)
    }
}
