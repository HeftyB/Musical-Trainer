import Foundation

/// The band's organ, one short stab at a time — the skank family's own voice.
///
/// **Built because a placement decision was being made through the wrong timbre.** M16.5's two
/// candidate bubbles were auditioned on the rimshot, and the player's verdict came back *"I was
/// trying to imagine it with an organ sound to identify the bubble"* (§7.55). Asking someone to
/// hear past the sound is the audition equivalent of printing a verdict with a caveat under it.
///
/// **Additive, because that is what the instrument is.** A tonewheel organ sums near-sinusoidal
/// partials at drawbar ratios; there is no filter and no oscillator sync to model. Sub-octave,
/// fundamental, the fifth above, the octave and two upper partials give the hollow, slightly
/// nasal tone a bubble is played with, and no third — the interval that would commit the band to
/// a key quality lives in `BubbleBacking`'s voicing, not in the timbre.
///
/// **Flat while it sounds, and short.** A Hammond does not decay: it is on, then off. What makes
/// a bubble a bubble is the *articulation* rather than the envelope shape, so this is a fast
/// attack, a level body and a fast release — with the whole note kept under the gap between two
/// bubble notes at the tempos the drill runs, or the figure turns to mud before it is played over.
enum OrganSynth {

    /// Seconds a stab sounds, before the shared release fade.
    ///
    /// **Bounded by the figure, not by taste.** The tightest gap in the family is the sixteenth
    /// bubble's quarter-beat — 214 ms at 70 BPM and 150 ms at 100 — so a note appreciably longer
    /// than this would run into its own neighbour at the top of the drill's range.
    /// `OrganStabTests` holds that against `BubbleFeel`'s own geometry rather than against a
    /// number written here twice.
    static let bodySeconds = 0.115

    /// Drawbar ratios and their weights, relative to the 8' fundamental.
    ///
    /// The classic bubble registration is bright and hollow: plenty of upper partials, and the
    /// 5⅓' fifth that gives a tonewheel organ its characteristic edge. Deliberately no partial at
    /// 5 — the major third — so the voice states no key of its own.
    private static let drawbars: [(ratio: Double, level: Double)] = [
        (0.5, 0.30),    // 16'  sub-octave, body
        (1.0, 1.00),    // 8'   fundamental
        (1.5, 0.55),    // 5⅓'  the fifth — the tonewheel edge
        (2.0, 0.70),    // 4'   octave
        (3.0, 0.30),    // 2⅔'
        (4.0, 0.18),    // 2'
    ]

    static func frequency(ofNote note: Int) -> Double {
        440 * pow(2, (Double(note) - 69) / 12)
    }

    static func render(note: Int, sampleRate fs: Double) -> [Float] {
        let f0 = frequency(ofNote: note)
        let count = Int(bodySeconds * fs)
        var out = [Float](repeating: 0, count: count)

        // Normalised so the registration's own weights do not decide the level. Changing a
        // drawbar should change the tone and not the volume, which is the only way a later
        // adjustment can be judged by ear.
        let sum = drawbars.reduce(0) { $0 + $1.level }
        var phases = [Double](repeating: 0, count: drawbars.count)
        let steps = drawbars.map { 2 * .pi * f0 * $0.ratio / fs }

        let attack = 0.004
        let release = 0.020

        for i in 0..<count {
            let t = Double(i) / fs
            var sample = 0.0
            for (index, bar) in drawbars.enumerated() {
                sample += sin(phases[index]) * bar.level
                phases[index] += steps[index]
            }
            sample /= sum

            // Flat between the two, which is the whole character of the instrument.
            let envelope: Double
            if t < attack {
                envelope = t / attack
            } else if t > bodySeconds - release {
                envelope = max(0, (bodySeconds - t) / release)
            } else {
                envelope = 1
            }

            // Key click: the contact bounce a tonewheel organ makes as the busbar closes. Two
            // milliseconds of broadband edge, and it is most of what makes a stab read as an
            // organ rather than as a sine pad — the same role the bass's pluck plays.
            var click = 0.0
            if t < 0.002 {
                click = sin(phases[1] * 7) * (1 - t / 0.002) * 0.22
            }

            out[i] = DrumSynth.saturateBass(Float((sample * envelope + click) * 0.42))
        }
        // Every one-shot ends on the shared release fade, so nothing steps to zero mid-decay —
        // the defect §7.31 finding 1 exists for, and the reason `raw` is private in `DrumSynth`.
        return DrumSynth.fadedOut(out, sampleRate: fs)
    }
}
