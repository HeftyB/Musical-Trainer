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
        /// Samples this voice has sounded without being released. A voice whose note-off never
        /// arrives is released on its own once this passes the ceiling — see `maxSustainSamples`.
        var heldSamples: Int = 0
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

    /// How long any one voice may sound before it releases itself, in seconds.
    ///
    /// `release(note:)` was the only way out of a sounding voice, so a note whose note-off never
    /// arrived rang until the engine stopped. That is not hypothetical: the instrument hung twice,
    /// on 8 and 10 August 2026, one tone sustaining while the keyboard went silent underneath it
    /// (JOURNAL.md §7.34, §7.35). This ceiling does not fix the cause — which is still not
    /// established — it converts "for ever" into "a few seconds" whatever the cause turns out to
    /// be.
    ///
    /// **8 seconds, and the bound that matters is the lower one.** A whole bar at 40 BPM, the
    /// slowest tempo any drill accepts, is 6.0 s, so a bar held at the slowest tempo the app
    /// offers still rings in full. `MaxSustainTests` asserts both ends; the lower assertion is
    /// the one that stops this being tightened into something that cuts off real playing.
    ///
    /// **It cannot move a measured number.** Everything analysed is derived from note *onsets* —
    /// `MIDINoteOn`, `tapTimes`, the raw note-ons — and nothing anywhere reads a note's duration.
    /// So the worst this can do is shorten what the player hears, never what the take reports.
    static let maxSustainSeconds = 8.0
    private let maxSustainSamples: Int

    init(sampleRate: Double, gain: Float = 0.5) {
        fs = sampleRate
        self.gain = gain
        attackInc = Float(1.0 / (0.006 * sampleRate))
        decayInc = (1 - sustain) / Float(0.10 * sampleRate)
        clickDecay = Float(exp(-1.0 / (0.008 * sampleRate)))
        maxSustainSamples = Int(LiveInstrument.maxSustainSeconds * sampleRate)

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

    /// Render up to `frames` of mono instrument audio, returning the internal buffer **and how
    /// many frames of it are valid**. Drains pending note events first, then synthesizes.
    ///
    /// The count is returned rather than assumed because `frames` is clamped to the scratch
    /// buffer rather than growing it — growing it would allocate on the render thread (R2.3).
    /// Reading `samples` past `count` is reading memory this never wrote, which is what the
    /// caller did while the count was implicit: `GroovePlayer.render` mixed the full
    /// `frameCount` against a buffer clamped at `scratchCapacity`. Latent only because nothing
    /// sets `maximumFramesToRender` and AVAudioEngine's default is 4096, but a device or
    /// configuration handing over a larger buffer would have read past the allocation. Making
    /// the count part of the return type is what stops the mistake being writable again.
    func render(frames: Int) -> (samples: UnsafePointer<Float>, count: Int) {
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
                // A voice that never receives its note-off releases itself. Checked before the
                // envelope so the ceiling is the elapsed sounding time, not the time spent in
                // any one stage, and it uses the same slope `release(note:)` sets so a voice
                // that times out is indistinguishable from one that was let go.
                if v.stage != 3 {
                    v.heldSamples += 1
                    if v.heldSamples >= maxSustainSamples {
                        v.stage = 3
                        v.relInc = max(v.env, 0.0001) / (releaseTime * Float(fs))
                    }
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
        return (UnsafePointer(scratch), n)
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
