import AVFoundation
import Darwin
import Foundation

/// Where a chirp actually left the output, recorded from inside the render callback.
struct ChirpEmission {
    let index: Int
    /// Absolute output sample index at which the chirp begins.
    let outputSample: Int64
    /// Absolute output sample index of the first frame of the buffer it began in.
    let bufferStartSample: Int64
    /// `AudioTimeStamp.mHostTime` for that buffer.
    let bufferHostTime: UInt64
    /// Offset of the chirp within its buffer. This is the variable check #2 regresses
    /// against — if our host-time arithmetic is wrong, error tracks this.
    let phase: Int
}

/// All render-thread mutable state, held behind a single pointer.
///
/// The render block captures one `UnsafeMutablePointer`, which is a trivial value: no ARC
/// traffic, no allocation, no locking on the audio thread. Everything here is written by
/// exactly one thread and read only after the engine has stopped.
private struct RenderState {
    var outSampleCounter: Int64 = 0
    var chirpCursor: Int = 0
    var emissionCount: Int = 0
    var outMapCount: Int = 0

    var chirp: UnsafeMutablePointer<Float>
    var chirpLength: Int
    var gain: Float

    var scheduled: UnsafeMutablePointer<Int64>
    var scheduledCount: Int

    var emissions: UnsafeMutablePointer<ChirpEmission>
    var emissionCapacity: Int

    var outMapHost: UnsafeMutablePointer<UInt64>
    var outMapSample: UnsafeMutablePointer<Int64>
    var outMapCapacity: Int
}

private struct CaptureState {
    var capture: UnsafeMutablePointer<Float>
    var captureCapacity: Int
    var captureCount: Int = 0

    var inMapHost: UnsafeMutablePointer<UInt64>
    var inMapSample: UnsafeMutablePointer<Int64>
    var inMapCount: Int = 0
    var inMapCapacity: Int
}

final class AudioIO {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sinkNode: AVAudioSinkNode?

    private let renderState: UnsafeMutablePointer<RenderState>
    private let captureState: UnsafeMutablePointer<CaptureState>

    let outputFormat: AVAudioFormat
    let inputFormat: AVAudioFormat
    let chirpSamples: Int
    private let chirpReference: [Float]

    var outputSampleRate: Double { outputFormat.sampleRate }
    var inputSampleRate: Double { inputFormat.sampleRate }
    var chirpKernel: [Float] { chirpReference }

    init(maxCaptureSeconds: Double, chirpDuration: Double = 0.020, gain: Float = 0.6) throws {
        // Touching inputNode instantiates the input HAL; on macOS this is also what
        // triggers the microphone permission prompt.
        inputFormat = engine.inputNode.outputFormat(forBus: 0)
        outputFormat = engine.outputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw SpikeError("""
                No usable audio input. Grant microphone access to your terminal:
                System Settings → Privacy & Security → Microphone.
                """)
        }
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            throw SpikeError("No usable audio output device.")
        }

        chirpReference = Chirp.make(sampleRate: outputFormat.sampleRate, duration: chirpDuration)
        chirpSamples = chirpReference.count

        let emissionCapacity = 4096
        let mapCapacity = 1_000_000
        let scheduledCapacity = 4096
        let captureCapacity = Int(maxCaptureSeconds * inputFormat.sampleRate)

        let chirpBuf = UnsafeMutablePointer<Float>.allocate(capacity: chirpSamples)
        chirpBuf.assign(from: chirpReference, count: chirpSamples)

        renderState = .allocate(capacity: 1)
        renderState.initialize(to: RenderState(
            chirp: chirpBuf,
            chirpLength: chirpSamples,
            gain: gain,
            scheduled: .allocate(capacity: scheduledCapacity),
            scheduledCount: 0,
            emissions: .allocate(capacity: emissionCapacity),
            emissionCapacity: emissionCapacity,
            outMapHost: .allocate(capacity: mapCapacity),
            outMapSample: .allocate(capacity: mapCapacity),
            outMapCapacity: mapCapacity))

        captureState = .allocate(capacity: 1)
        captureState.initialize(to: CaptureState(
            capture: .allocate(capacity: captureCapacity),
            captureCapacity: captureCapacity,
            inMapHost: .allocate(capacity: mapCapacity),
            inMapSample: .allocate(capacity: mapCapacity),
            inMapCapacity: mapCapacity))

        buildGraph()
    }

    deinit {
        renderState.pointee.chirp.deallocate()
        renderState.pointee.scheduled.deallocate()
        renderState.pointee.emissions.deallocate()
        renderState.pointee.outMapHost.deallocate()
        renderState.pointee.outMapSample.deallocate()
        renderState.deallocate()

        captureState.pointee.capture.deallocate()
        captureState.pointee.inMapHost.deallocate()
        captureState.pointee.inMapSample.deallocate()
        captureState.deallocate()
    }

    // MARK: - Graph

    private func buildGraph() {
        let state = renderState
        // Locals, then retained — see the note in `GroovePlayer.buildGraph`.
        let source = AVAudioSourceNode(format: outputFormat) { _, timestamp, frameCount, ablPtr in
            AudioIO.render(state: state, timestamp: timestamp, frameCount: frameCount, ablPtr: ablPtr)
        }

        let capture = captureState
        let sink = AVAudioSinkNode { timestamp, frameCount, ablPtr in
            AudioIO.receive(state: capture, timestamp: timestamp, frameCount: frameCount, ablPtr: ablPtr)
        }

        sourceNode = source
        sinkNode = sink
        engine.attach(source)
        engine.attach(sink)
        engine.connect(source, to: engine.outputNode, format: outputFormat)
        engine.connect(engine.inputNode, to: sink, format: inputFormat)
    }

    private static func render(state: UnsafeMutablePointer<RenderState>,
                               timestamp: UnsafePointer<AudioTimeStamp>,
                               frameCount: AVAudioFrameCount,
                               ablPtr: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let s = state
        let n = Int(frameCount)
        let bufferStart = s.pointee.outSampleCounter
        let ts = timestamp.pointee
        let hostTime = (ts.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue) != 0
            ? ts.mHostTime : 0

        if hostTime != 0, s.pointee.outMapCount < s.pointee.outMapCapacity {
            let i = s.pointee.outMapCount
            s.pointee.outMapHost[i] = hostTime
            s.pointee.outMapSample[i] = bufferStart
            s.pointee.outMapCount = i + 1
        }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        for buffer in abl {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }

        // Walk every scheduled chirp overlapping this buffer. A 20 ms chirp spans several
        // buffers, so the cursor only advances past chirps that have fully finished.
        var i = s.pointee.chirpCursor
        let bufferEnd = bufferStart + Int64(n)
        while i < s.pointee.scheduledCount {
            let start = s.pointee.scheduled[i]
            if start >= bufferEnd { break }
            let end = start + Int64(s.pointee.chirpLength)
            if end <= bufferStart { i += 1; continue }

            if start >= bufferStart, s.pointee.emissionCount < s.pointee.emissionCapacity {
                let e = s.pointee.emissionCount
                s.pointee.emissions[e] = ChirpEmission(
                    index: i,
                    outputSample: start,
                    bufferStartSample: bufferStart,
                    bufferHostTime: hostTime,
                    phase: Int(start - bufferStart))
                s.pointee.emissionCount = e + 1
            }

            let from = max(start, bufferStart)
            let to = min(end, bufferEnd)
            // Resolved once per buffer rather than once per sample.
            for buffer in abl {
                guard let raw = buffer.mData else { continue }
                let data = raw.assumingMemoryBound(to: Float.self)
                // mNumberChannels > 1 means interleaved within this buffer.
                let channels = Int(buffer.mNumberChannels)
                for absolute in from..<to {
                    let dst = Int(absolute - bufferStart)
                    let value = s.pointee.chirp[Int(absolute - start)] * s.pointee.gain
                    for c in 0..<channels { data[dst * channels + c] += value }
                }
            }
            i += 1
        }

        while s.pointee.chirpCursor < s.pointee.scheduledCount,
              s.pointee.scheduled[s.pointee.chirpCursor] + Int64(s.pointee.chirpLength) <= bufferEnd {
            s.pointee.chirpCursor += 1
        }

        s.pointee.outSampleCounter = bufferEnd
        return noErr
    }

    private static func receive(state: UnsafeMutablePointer<CaptureState>,
                                timestamp: UnsafePointer<AudioTimeStamp>,
                                frameCount: AVAudioFrameCount,
                                ablPtr: UnsafePointer<AudioBufferList>) -> OSStatus {
        let s = state
        let n = Int(frameCount)
        let start = s.pointee.captureCount
        guard start + n <= s.pointee.captureCapacity else { return noErr }

        let ts = timestamp.pointee
        if (ts.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue) != 0,
           s.pointee.inMapCount < s.pointee.inMapCapacity {
            let i = s.pointee.inMapCount
            s.pointee.inMapHost[i] = ts.mHostTime
            s.pointee.inMapSample[i] = Int64(start)
            s.pointee.inMapCount = i + 1
        }

        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard let buffer = abl.first, let data = buffer.mData else { return noErr }
        let src = data.assumingMemoryBound(to: Float.self)
        let stride = Int(buffer.mNumberChannels)

        // Channel 0 only. Mono is all onset detection needs.
        for f in 0..<n { s.pointee.capture[start + f] = src[f * stride] }
        s.pointee.captureCount = start + n
        return noErr
    }

    // MARK: - Scheduling

    /// Chirp start positions, in absolute output samples. Scheduled before the engine
    /// starts so the sample counter begins at a known zero — no race, no guesswork.
    func schedule(starts: [Int64]) {
        precondition(!engine.isRunning, "Schedule chirps before starting the engine")
        for (i, s) in starts.enumerated() {
            renderState.pointee.scheduled[i] = s
        }
        renderState.pointee.scheduledCount = starts.count
    }

    func run(forSeconds duration: Double) throws {
        engine.prepare()
        try engine.start()
        // Drive the run loop rather than sleeping the thread, so anything that depends on
        // main-thread run loop servicing keeps working while we record.
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        engine.stop()
    }

    // MARK: - Results

    var emissions: [ChirpEmission] {
        (0..<renderState.pointee.emissionCount).map { renderState.pointee.emissions[$0] }
    }

    var capturedAudio: [Float] {
        let n = captureState.pointee.captureCount
        return Array(UnsafeBufferPointer(start: captureState.pointee.capture, count: n))
    }

    var outputMapPairs: [(hostTime: UInt64, sample: Int64)] {
        (0..<renderState.pointee.outMapCount).map {
            (renderState.pointee.outMapHost[$0], renderState.pointee.outMapSample[$0])
        }
    }

    var inputMapPairs: [(hostTime: UInt64, sample: Int64)] {
        (0..<captureState.pointee.inMapCount).map {
            (captureState.pointee.inMapHost[$0], captureState.pointee.inMapSample[$0])
        }
    }

    /// Host time at which a chirp's first sample reached the DAC.
    ///
    /// This single line is what check #2 exists to falsify: it assumes `mHostTime` refers
    /// to the first frame of the buffer, and that offsets within the buffer convert
    /// linearly at the output sample rate.
    func emissionHostSeconds(_ e: ChirpEmission, epoch: UInt64) -> Double {
        HostClock.interval(from: epoch, to: e.bufferHostTime) + Double(e.phase) / outputSampleRate
    }
}
