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
    private var sourceNode: AVAudioSourceNode!
    private let state: UnsafeMutablePointer<RenderState>

    private let voiceCount = DrumVoice.allCases.count
    private let voiceIndexOf: [DrumVoice: Int]
    private let kit: DrumKit
    let outputSampleRate: Double

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
    }

    // 0.6 leaves headroom so coincident voices (kick + hat on a downbeat) do not stack past
    // 0 dBFS and clip. selftest's "mix stays near the rails" check enforces this.
    init(masterGain: Float = 0.6, capacity: Int = 200_000) throws {
        self.capacity = capacity
        outputSampleRate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard outputSampleRate > 0 else { throw SpikeError("No usable audio output device.") }

        kit = DrumKit(sampleRate: outputSampleRate)
        voiceIndexOf = Dictionary(uniqueKeysWithValues:
            DrumVoice.allCases.enumerated().map { ($1, $0) })

        let voiceData = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: voiceCount)
        let voiceLen = UnsafeMutablePointer<Int>.allocate(capacity: voiceCount)
        voiceData.initialize(repeating: nil, count: voiceCount)
        voiceLen.initialize(repeating: 0, count: voiceCount)
        for (voice, index) in voiceIndexOf {
            let samples = kit.buffer(for: voice)
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
            buffer.assign(from: samples, count: samples.count)
            voiceData[index] = buffer
            voiceLen[index] = samples.count
        }

        state = .allocate(capacity: 1)
        state.initialize(to: RenderState(
            starts: .allocate(capacity: capacity),
            voiceIndex: .allocate(capacity: capacity),
            gains: .allocate(capacity: capacity),
            voiceData: voiceData,
            voiceLen: voiceLen))

        _ = masterGain
        self.masterGain = masterGain
        buildGraph()
    }

    private let masterGain: Float

    deinit {
        for i in 0..<voiceCount { state.pointee.voiceData[i]?.deallocate() }
        state.pointee.voiceData.deallocate()
        state.pointee.voiceLen.deallocate()
        state.pointee.starts.deallocate()
        state.pointee.voiceIndex.deallocate()
        state.pointee.gains.deallocate()
        state.deallocate()
    }

    private func buildGraph() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let s = state
        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, ablPtr in
            GroovePlayer.render(state: s, frameCount: frameCount, ablPtr: ablPtr)
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.outputNode, format: format)
    }

    /// Load the schedule. Must be called before `run`. Hits are sorted by sample.
    func schedule(_ hits: [ScheduledHit]) {
        precondition(!engine.isRunning, "schedule before starting playback")
        let sorted = hits.sorted { $0.sample < $1.sample }
        let count = min(sorted.count, capacity)
        for i in 0..<count {
            let hit = sorted[i]
            state.pointee.starts[i] = hit.sample
            state.pointee.voiceIndex[i] = Int32(voiceIndexOf[hit.voice] ?? 0)
            state.pointee.gains[i] = Float(hit.velocity) / 127 * masterGain
        }
        state.pointee.scheduledCount = count
        state.pointee.cursor = 0
        state.pointee.outSampleCounter = 0
    }

    func run(forSeconds duration: Double) throws {
        engine.prepare()
        try engine.start()
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
        engine.stop()
    }

    /// Total duration of the schedule, so callers can play exactly to the end.
    func scheduledDurationSeconds() -> Double {
        let count = state.pointee.scheduledCount
        guard count > 0 else { return 0 }
        let last = state.pointee.starts[count - 1]
        let vi = Int(state.pointee.voiceIndex[count - 1])
        return Double(last + Int64(state.pointee.voiceLen[vi])) / outputSampleRate
    }

    private static func render(state s: UnsafeMutablePointer<RenderState>,
                               frameCount: AVAudioFrameCount,
                               ablPtr: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let n = Int(frameCount)
        let bufferStart = s.pointee.outSampleCounter
        let bufferEnd = bufferStart + Int64(n)

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
                for absolute in from..<to {
                    let value = voice[Int(absolute - start)] * gain
                    let dst = Int(absolute - bufferStart)
                    for buffer in abl {
                        let channels = Int(buffer.mNumberChannels)
                        let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                        for c in 0..<channels { data[dst * channels + c] += value }
                    }
                }
            }
            i += 1
        }

        s.pointee.outSampleCounter = bufferEnd
        return noErr
    }
}
