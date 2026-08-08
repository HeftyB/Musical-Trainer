import Foundation

/// The band's bass, one short note at a time.
///
/// **Rhythmic, not harmonic** (§7.29 step 2). It plays a root and a fifth locking with the kick,
/// which is what gives a groove a contour worth remembering; keys, progressions and voice leading
/// are M25's problem and deliberately not this one's.
///
/// Built to sit *under* the player rather than beside them. The fundamental carries the pitch,
/// a second partial gives it definition on a laptop speaker where the fundamental is barely
/// reproduced at all, and the whole thing decays inside a beat so it reads as a pulse rather
/// than a pad. A sustaining bass would mask the player's own low notes and blur the very
/// downbeat the drill is asking them to feel.
enum BassSynth {

    /// Seconds a note rings. Short on purpose: long enough to have pitch, short enough that two
    /// eighths never overlap into mud at any tempo this app reaches.
    private static let decay = 0.34

    static func frequency(ofNote note: Int) -> Double {
        440 * pow(2, (Double(note) - 69) / 12)
    }

    static func render(note: Int, sampleRate fs: Double) -> [Float] {
        let f0 = frequency(ofNote: note)
        let count = Int(decay * 1.6 * fs)
        var out = [Float](repeating: 0, count: count)

        var phase = 0.0
        var phase2 = 0.0
        let step = 2 * .pi * f0 / fs
        let step2 = 2 * .pi * f0 * 2 / fs

        for i in 0..<count {
            let t = Double(i) / fs
            // Two envelopes: the body, and a faster one on the octave so the attack has
            // definition and the tail is pure fundamental rather than buzz.
            let body = exp(-t / decay)
            let bite = exp(-t / (decay * 0.18))

            var sample = sin(phase) * body + sin(phase2) * bite * 0.35
            phase += step
            phase2 += step2

            // Six milliseconds of pluck: a fast linear fade on a third partial, which is what
            // makes a bass note *land* rather than fade in. The same idea as the kick's beater
            // attack, pitched rather than noisy so it does not read as a click track.
            if t < 0.006 {
                sample += sin(phase * 3) * (1 - t / 0.006) * 0.25
            }

            // 0.40 rather than anything louder, and the number came from the render's own clipping
            // check rather than from taste: at 0.9 the demo peaked at 1.14 and clipped 127
            // samples, because the bass lands *with* the kick by design and the two stack. A
            // clipped groove is heard as bad playing rather than as a bad gain.
            out[i] = DrumSynth.saturateBass(Float(sample) * 0.40)
        }
        // **The worst truncation in the kit, and the one nothing had measured.** The buffer is
        // `decay * 1.6` long against an `exp(-t / decay)` envelope, so it ended at `exp(-1.6)` —
        // 20.2% of peak, against the kick's 4.1% — and stepped straight to zero from there. It
        // never appeared in §7.29 step 6b's table of clicking voices because `render` writes one
        // file per *non-pitched* voice, so the diagnostic that found the kick had the loudest
        // offender filtered out of it (PLAN.md §7.31 finding 1).
        //
        // Lengthening the buffer instead would need 2.4 s to reach −60 dB and would turn the note
        // into a pad, which is exactly what the comment above says it must not be.
        return DrumSynth.fadedOut(out, sampleRate: fs)
    }
}
