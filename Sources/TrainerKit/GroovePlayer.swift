import AVFoundation
import Darwin
import Foundation
import GrooveCore

/// Plays a pre-scheduled list of drum hits sample-accurately.
///
/// Same real-time discipline as `AudioIO`: all render-thread state sits behind one pointer,
/// the callback only adds pre-rendered samples, and the whole schedule is fixed before the
/// engine starts. Output only — no capture here.
final class GroovePlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let state: UnsafeMutablePointer<RenderState>

    /// One slot per *sound* the band can make, not per voice: the drums take one each and the
    /// bass takes one per note. The render callback still indexes a flat table, which is what
    /// keeps it free of allocation and branching (R2.3) — pitch changes what is pre-rendered,
    /// never what happens in the callback.
    private let soundCount: Int
    private let soundIndexOf: [SoundKey: Int]

    private struct SoundKey: Hashable {
        let voice: BackingVoice
        let note: Int?
    }
    private let kit: BackingKit
    let outputSampleRate: Double

    /// Sonifies the player's MIDI so they can hear what they play while jamming. Held
    /// strongly by the render block (one retain, no per-callback ARC).
    let instrument: LiveInstrument

    private let capacity: Int

    private struct RenderState {
        var outSampleCounter: Int64 = 0
        var cursor: Int = 0
        var scheduledCount: Int = 0

        var starts: UnsafeMutablePointer<Int64>
        var voiceIndex: UnsafeMutablePointer<Int32>
        var gains: UnsafeMutablePointer<Float>

        // One entry per drum voice: a stable pointer to its rendered one-shot and its length.
        var voiceData: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
        var voiceLen: UnsafeMutablePointer<Int>

        // (mHostTime, bufferStartSample) pairs — the bridge that lets captured MIDI, which
        // arrives in host time, be placed on the groove's output-sample timeline. Same
        // technique as AudioIO; it is what makes a jam measurable.
        var outMapHost: UnsafeMutablePointer<UInt64>
        var outMapSample: UnsafeMutablePointer<Int64>
        var outMapCount: Int = 0
        var outMapCapacity: Int
    }

    // 0.6 leaves headroom so coincident voices (kick + hat on a downbeat) do not stack past
    // 0 dBFS and clip. selftest's "mix stays near the rails" check enforces this.
    init(masterGain: Float = 0.6, capacity: Int = 200_000) throws {
        self.capacity = capacity
        outputSampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard outputSampleRate > 0 else { throw SpikeError("No usable audio output device.") }

        kit = BackingKit(sampleRate: outputSampleRate)
        instrument = LiveInstrument(sampleRate: outputSampleRate)

        var keys: [SoundKey] = BackingVoice.allCases.filter { !$0.isPitched }
            .map { SoundKey(voice: $0, note: nil) }
        keys += BackingKit.bassNotes.map { SoundKey(voice: .bass, note: $0) }
        soundIndexOf = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        soundCount = keys.count

        let voiceData = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: soundCount)
        let voiceLen = UnsafeMutablePointer<Int>.allocate(capacity: soundCount)
        voiceData.initialize(repeating: nil, count: soundCount)
        voiceLen.initialize(repeating: 0, count: soundCount)
        for (key, index) in soundIndexOf {
            let samples = kit.buffer(for: key.voice, note: key.note)
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
            buffer.assign(from: samples, count: samples.count)
            voiceData[index] = buffer
            voiceLen[index] = samples.count
        }

        let mapCapacity = 600_000   // ~1 hour at 256-frame buffers, 44.1 kHz
        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(
            starts: .allocate(capacity: capacity),
            voiceIndex: .allocate(capacity: capacity),
            gains: .allocate(capacity: capacity),
            voiceData: voiceData,
            voiceLen: voiceLen,
            outMapHost: .allocate(capacity: mapCapacity),
            outMapSample: .allocate(capacity: mapCapacity),
            outMapCapacity: mapCapacity))

        _ = masterGain
        self.masterGain = masterGain
        buildGraph()
    }

    private let masterGain: Float

    deinit {
        for i in 0..<soundCount { state.pointee.voiceData[i]?.deallocate() }
        state.pointee.voiceData.deallocate()
        state.pointee.voiceLen.deallocate()
        state.pointee.starts.deallocate()
        state.pointee.voiceIndex.deallocate()
        state.pointee.gains.deallocate()
        state.pointee.outMapHost.deallocate()
        state.pointee.outMapSample.deallocate()
        state.deallocate()
    }

    private func buildGraph() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let s = state
        let inst = instrument
        // Built into a local and then retained: the property exists only to keep the node
        // alive for the engine's lifetime, and going through it here would need an unwrap for
        // a value that cannot be absent on this line.
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, ablPtr in
            GroovePlayer.render(state: s, instrument: inst, timestamp: timestamp,
                                frameCount: frameCount, ablPtr: ablPtr)
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
    }

    /// Load the schedule. Must be called before `run`. Hits are sorted by sample.
    func schedule(_ hits: [ScheduledHit]) {
        precondition(!engine.isRunning, "schedule before starting playback")
        // Resolved and filtered *before* anything is written, because the three parallel arrays
        // are read by index in the render callback: skipping one mid-loop would leave a start
        // time beside whichever sound and gain the previous schedule left there, which is a
        // wrong note played confidently rather than a missing one.
        //
        // A hit drops out only when its sound was never rendered — a bass note outside
        // `BackingKit.bassNotes`. That is a programming error, and silence is the honest
        // response: substituting the nearest pitch would put a wrong note in the music without
        // saying so (§7.29 step 2).
        let resolved: [(hit: ScheduledHit, index: Int)] = hits
            .compactMap { hit in
                let key = SoundKey(voice: hit.voice, note: hit.voice.isPitched ? hit.note : nil)
                return soundIndexOf[key].map { (hit, $0) }
            }
            .sorted { $0.hit.sample < $1.hit.sample }

        let count = min(resolved.count, capacity)
        for i in 0..<count {
            let (hit, index) = resolved[i]
            state.pointee.starts[i] = hit.sample
            state.pointee.voiceIndex[i] = Int32(index)
            state.pointee.gains[i] = Float(hit.velocity) / 127 * masterGain
        }
        state.pointee.scheduledCount = count
        state.pointee.cursor = 0
        state.pointee.outSampleCounter = 0
        state.pointee.outMapCount = 0
    }

    /// Host time of the very first rendered buffer, i.e. output sample 0.
    ///
    /// Safe to read while the engine is running, unlike `outputMapPairs`: entry 0 is written
    /// on the first callback and never touched again, so once the count is non-zero the value
    /// is immutable. Reading the whole map concurrently would be a genuine data race against
    /// the render thread, which cannot take a lock.
    var startHostTime: UInt64? {
        state.pointee.outMapCount > 0 ? state.pointee.outMapHost[0] : nil
    }

    /// (hostTime, sample) pairs captured during playback — feed to a `SampleHostMap` to
    /// convert MIDI host times into groove-sample positions.
    ///
    /// **Read only after the engine has stopped.** The render thread appends to this while
    /// playing.
    var outputMapPairs: [(hostTime: UInt64, sample: Int64)] {
        (0..<state.pointee.outMapCount).map {
            (state.pointee.outMapHost[$0], state.pointee.outMapSample[$0])
        }
    }

    /// Play the schedule for `duration`, reporting fractional progress.
    ///
    /// The wait is paced by an explicit sleep rather than by `RunLoop.run(until:)`, which
    /// returns immediately on a thread with no input sources — true of the background queue
    /// the app runs takes on. The run loop is still serviced so anything that needs it keeps
    /// working; the sleep is what guarantees the loop actually waits.
    /// - Throws: `TakeCancelled` if `cancellation` is raised before the schedule finishes.
    ///   The engine is always torn down first, so audio stops either way.
    func run(forSeconds duration: Double,
             progress: ((Double) -> Void)? = nil,
             cancellation: CancellationFlag? = nil) throws {
        engine.prepare()
        try engine.start()
        let start = Date()
        let deadline = start.addingTimeInterval(duration)
        var stopped = false
        while Date() < deadline {
            if cancellation?.isCancelled == true { stopped = true; break }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            Thread.sleep(forTimeInterval: 0.01)
            progress?(min(1, Date().timeIntervalSince(start) / duration))
        }
        engine.stop()
        if stopped { throw TakeCancelled() }
        progress?(1)
    }

    /// Total duration of the schedule, so callers can play exactly to the end.
    func scheduledDurationSeconds() -> Double {
        let count = state.pointee.scheduledCount
        guard count > 0 else { return 0 }
        let last = state.pointee.starts[count - 1]
        let vi = Int(state.pointee.voiceIndex[count - 1])
        return Double(last + Int64(state.pointee.voiceLen[vi])) / outputSampleRate
    }

    /// Forward a MIDI note event to the live instrument. Safe to call from the CoreMIDI
    /// thread — `enqueue` is lock-free.
    ///
    /// Pads (channel 9, the drum channel) become an unpitched click rather than a synth
    /// note, so a phrase mark sounds like an acknowledgement instead of something you played.
    func noteEvent(note: UInt8, velocity: UInt8, on: Bool, channel: UInt8 = 0) {
        instrument.enqueue(note: note, velocity: velocity, on: on, click: channel == 9)
    }

    private static func render(state s: UnsafeMutablePointer<RenderState>,
                               instrument: LiveInstrument,
                               timestamp: UnsafePointer<AudioTimeStamp>,
                               frameCount: AVAudioFrameCount,
                               ablPtr: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let n = Int(frameCount)
        let bufferStart = s.pointee.outSampleCounter
        let bufferEnd = bufferStart + Int64(n)

        let ts = timestamp.pointee
        if (ts.mFlags.rawValue & AudioTimeStampFlags.hostTimeValid.rawValue) != 0,
           s.pointee.outMapCount < s.pointee.outMapCapacity {
            let i = s.pointee.outMapCount
            s.pointee.outMapHost[i] = ts.mHostTime
            s.pointee.outMapSample[i] = bufferStart
            s.pointee.outMapCount = i + 1
        }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        for buffer in abl { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }

        // Retire hits that have fully finished before this buffer.
        while s.pointee.cursor < s.pointee.scheduledCount {
            let start = s.pointee.starts[s.pointee.cursor]
            let vi = Int(s.pointee.voiceIndex[s.pointee.cursor])
            if start + Int64(s.pointee.voiceLen[vi]) <= bufferStart { s.pointee.cursor += 1 }
            else { break }
        }

        var i = s.pointee.cursor
        while i < s.pointee.scheduledCount, s.pointee.starts[i] < bufferEnd {
            let start = s.pointee.starts[i]
            let vi = Int(s.pointee.voiceIndex[i])
            let len = Int64(s.pointee.voiceLen[vi])
            let end = start + len
            if end > bufferStart, let voice = s.pointee.voiceData[vi] {
                let gain = s.pointee.gains[i]
                let from = max(start, bufferStart)
                let to = min(end, bufferEnd)
                // The buffer pointer is resolved once per buffer rather than once per
                // sample: same result, one branch instead of thousands on the render thread.
                for buffer in abl {
                    guard let raw = buffer.mData else { continue }
                    let data = raw.assumingMemoryBound(to: Float.self)
                    let channels = Int(buffer.mNumberChannels)
                    for absolute in from..<to {
                        let value = voice[Int(absolute - start)] * gain
                        let dst = Int(absolute - bufferStart)
                        for c in 0..<channels { data[dst * channels + c] += value }
                    }
                }
            }
            i += 1
        }

        // Mix the live instrument (mono) into every channel, then soft-clip the master so
        // stacked drum hits and held chords cannot exceed 0 dBFS. tanh is ~linear at low
        // level, so it barely touches the drums and only tames the peaks.
        // `played` is what the instrument actually wrote, which is not always `n`: its scratch
        // buffer is a fixed allocation and a larger request is clamped rather than grown, because
        // growing it would allocate here (R2.3). Mixing `0..<n` against it read past the
        // allocation whenever the engine handed over more than `scratchCapacity` frames.
        let (scratch, played) = instrument.render(frames: n)
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let channels = Int(buffer.mNumberChannels)
            for f in 0..<played {
                let voice = scratch[f]
                for c in 0..<channels {
                    let idx = f * channels + c
                    data[idx] = tanhf(data[idx] + voice)
                }
            }
            // The tail past what the instrument wrote still needs the master soft-clip, or an
            // oversized buffer would leave the drums unlimited on its remainder. Split into two
            // loops rather than branching per sample, for the same reason the drum mix resolves
            // its buffer pointer once.
            for f in played..<n {
                for c in 0..<channels {
                    let idx = f * channels + c
                    data[idx] = tanhf(data[idx])
                }
            }
        }

        s.pointee.outSampleCounter = bufferEnd
        return noErr
    }
}
