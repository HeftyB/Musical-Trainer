import Darwin
import Foundation

/// A small polyphonic synth that sonifies the Launchkey in real time so you can hear what
/// you play while jamming. Warm and simple — a normalized sine-plus-harmonics tone through
/// an ADSR envelope, no filters to go harsh.
///
/// Real-time discipline, like everything else on the audio thread: all state is in
/// pointer-allocated buffers, `render` never allocates or locks, and note events cross from
/// the CoreMIDI thread through a single-producer/single-consumer lock-free ring.
final class LiveInstrument {
    private struct Voice {
        var active = false
        var note: Int32 = -1
        var phase: Double = 0
        var phaseInc: Double = 0
        var env: Float = 0
        var stage: Int32 = -1        // 0 attack · 1 decay · 2 sustain · 3 release
        var relInc: Float = 0        // release slope, fixed at note-off for a steady tail
        var velGain: Float = 0
        var age: UInt64 = 0          // for voice stealing
        /// 0 = pitched tone, 1 = percussive click. A click is a one-shot: it ignores
        /// note-off and decays on its own.
        var kind: Int32 = 0
        var noise: UInt64 = 0x9E3779B97F4A7C15
        var noisePrev: Float = 0
    }

    private let fs: Double
    private let maxVoices = 16
    private let voices: UnsafeMutablePointer<Voice>

    // SPSC ring of note events. Producer = CoreMIDI thread, consumer = audio thread.
    private let evCapacity = 512
    private let evCodes: UnsafeMutablePointer<Int32>
    private let head: UnsafeMutablePointer<Int>   // consumer-owned
    private let tail: UnsafeMutablePointer<Int>   // producer-owned

    private let scratchCapacity = 8192
    private let scratch: UnsafeMutablePointer<Float>

    private var ageCounter: UInt64 = 0            // consumer-only

    // Envelope timing and level.
    private let attackInc: Float
    private let decayInc: Float
    private let sustain: Float = 0.72
    private let releaseTime: Float = 0.22
    private let gain: Float

    private let toneNorm = Float(1.0 / 1.45)      // keeps a single voice's peak near 1
    /// Per-sample decay for the click voice — ~25 ms to inaudible.
    private let clickDecay: Float

    init(sampleRate: Double, gain: Float = 0.5) {
        fs = sampleRate
        self.gain = gain
        attackInc = Float(1.0 / (0.006 * sampleRate))
        decayInc = (1 - sustain) / Float(0.10 * sampleRate)
        clickDecay = Float(exp(-1.0 / (0.008 * sampleRate)))

        voices = .allocate(capacity: maxVoices)
        voices.initialize(repeating: Voice(), count: maxVoices)
        evCodes = .allocate(capacity: evCapacity)
        evCodes.initialize(repeating: 0, count: evCapacity)
        head = .allocate(capacity: 1); head.initialize(to: 0)
        tail = .allocate(capacity: 1); tail.initialize(to: 0)
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        voices.deallocate(); evCodes.deallocate()
        head.deallocate(); tail.deallocate(); scratch.deallocate()
    }

    // MARK: - Producer (CoreMIDI thread)

    /// Enqueue a note event. Lock-free; drops the event if the ring is momentarily full
    /// (would take hundreds of keypresses between two render calls — it won't happen).
    func enqueue(note: UInt8, velocity: UInt8, on: Bool, click: Bool = false) {
        let t = tail.pointee
        let next = (t + 1) % evCapacity
        if next == head.pointee { return }
        // Pack into one word so a single index publish makes it visible. On x86_64's strong
        // memory model the prior data store is not reordered past the tail update below.
        evCodes[t] = (click ? 1 << 17 : 0) | (on ? 1 << 16 : 0) | (Int32(note) << 8) | Int32(velocity)
        tail.pointee = next
    }

    // MARK: - Consumer (audio thread)

    /// Render `frames` of mono instrument audio, returning a pointer to the internal buffer.
    /// Drains pending note events first, then synthesizes.
    func render(frames: Int) -> UnsafePointer<Float> {
        let n = min(frames, scratchCapacity)

        while head.pointee != tail.pointee {
            let code = evCodes[head.pointee]
            let click = (code & (1 << 17)) != 0
            let on = (code & (1 << 16)) != 0
            let note = (code >> 8) & 0x7F
            let velocity = code & 0x7F
            if click {
                if on { triggerClick(velocity: velocity) }   // one-shot; note-off ignored
            } else if on {
                trigger(note: note, velocity: velocity)
            } else {
                release(note: note)
            }
            head.pointee = (head.pointee + 1) % evCapacity
        }

        for i in 0..<n { scratch[i] = 0 }

        for vi in 0..<maxVoices where voices[vi].active {
            var v = voices[vi]
            let inc = v.phaseInc
            for i in 0..<n {
                if v.kind == 1 {
                    // Percussive click: high-passed noise under a fixed exponential decay.
                    v.noise = v.noise &* 6364136223846793005 &+ 1442695040888963407
                    let white = Float(Int32(truncatingIfNeeded: v.noise >> 32)) / Float(Int32.max)
                    let hp = white - v.noisePrev
                    v.noisePrev = white
                    scratch[i] += hp * v.env * v.velGain * gain
                    v.env *= clickDecay
                    if v.env < 0.0005 { v.active = false; break }
                    continue
                }
                switch v.stage {
                case 0: v.env += attackInc; if v.env >= 1 { v.env = 1; v.stage = 1 }
                case 1: v.env -= decayInc;  if v.env <= sustain { v.env = sustain; v.stage = 2 }
                case 3: v.env -= v.relInc;  if v.env <= 0 { v.env = 0; v.active = false }
                default: break
                }
                let p = v.phase
                let tone = sin(p) + 0.3 * sin(2 * p) + 0.15 * sin(3 * p)
                scratch[i] += Float(tone) * toneNorm * v.env * v.velGain * gain
                v.phase += inc
                if v.phase > 2 * .pi { v.phase -= 2 * .pi }
                if !v.active { break }
            }
            voices[vi] = v
        }
        return UnsafePointer(scratch)
    }

    // MARK: - Voice management (consumer thread only)

    private func trigger(note: Int32, velocity: Int32) {
        let slot = freeVoiceSlot()
        let freq = 440.0 * pow(2.0, (Double(note) - 69) / 12)
        ageCounter += 1
        voices[slot] = Voice(active: true, note: note, phase: 0,
                             phaseInc: 2 * .pi * freq / fs,
                             env: 0, stage: 0, relInc: 0,
                             velGain: Float(velocity) / 127, age: ageCounter)
    }

    /// A short percussive tick, used to confirm a phrase mark registered. Deliberately
    /// unpitched so it reads as "noted" rather than as part of what you're playing.
    private func triggerClick(velocity: Int32) {
        let slot = freeVoiceSlot()
        ageCounter += 1
        var v = Voice()
        v.active = true; v.kind = 1; v.env = 1
        v.velGain = 0.5 + 0.5 * Float(velocity) / 127
        v.age = ageCounter
        v.noise = 0x2545F4914F6CDD1D &+ ageCounter
        voices[slot] = v
    }

    private func release(note: Int32) {
        for vi in 0..<maxVoices where voices[vi].active && voices[vi].note == note && voices[vi].stage != 3 {
            voices[vi].stage = 3
            voices[vi].relInc = max(voices[vi].env, 0.0001) / (releaseTime * Float(fs))
        }
    }

    /// An idle slot if there is one, otherwise steal the oldest voice.
    private func freeVoiceSlot() -> Int {
        var oldest = 0
        var oldestAge = UInt64.max
        for vi in 0..<maxVoices {
            if !voices[vi].active { return vi }
            if voices[vi].age < oldestAge { oldestAge = voices[vi].age; oldest = vi }
        }
        return oldest
    }
}
