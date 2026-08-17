import Foundation

/// Why no two hits of one voice come out at exactly the same level.
///
/// **Every hit is byte-identical to the last, which no acoustic instrument is** — §7.30 item 4, and
/// the thing that survives after velocity layers and a room have done their work. A drummer playing
/// eight hi-hats does not play eight identical hi-hats, and a listener hears the difference as a
/// machine long before they could say why.
///
/// ### What varies, and what deliberately does not
///
/// **Level only.** Not timing: the backing is the ruler this project measures the player against
/// (R2.2), and a band that moved would put its own jitter into every number. Not the layer either —
/// jitter that crossed a velocity boundary would change the *accent* the pattern wrote, and the
/// accents are the groove. What is left is the honest one: a hit that lands a little softer.
///
/// **Timbral round-robin was measured and deferred**, not skipped for lack of ambition. Rendering a
/// second set of variants costs a room pass per layer per voice — 18 seconds of kit build in a debug
/// build, against a 167-second suite that runs on every commit (§7.66). Level variation costs
/// nothing and buys most of the effect; a variant set buys the rest and needs the render chain to
/// get cheaper first.
///
/// ### Why a hash rather than a round-robin
///
/// **A cycle whose length divides the bar makes the machine quality worse, not better.** Patterns
/// here are 16 steps to the bar, so four variants would put the same one on every downbeat and the
/// same one on every backbeat — a pattern *in* the variation, exactly aligned to the pattern it was
/// supposed to break up. Two variants alternate, which is more audible still.
///
/// A hash of the hit's index has no period short of the mixer's own, so nothing lines up with
/// anything. It is also seedless and stateless: the same arrangement produces the same audio on
/// every run and every machine, which R1.2.2 requires and which a running RNG could not promise once
/// hits are sorted or filtered.
public enum Variation {

    /// The most a hit is pulled down, as a fraction of its level.
    ///
    /// **Attenuation only, never boost**, so nothing is louder than the mix that already shipped and
    /// the clipping guarantee needs no re-checking — the same reasoning as capping a velocity layer
    /// rather than matching it (§7.64). The cost is that the band sits about 0.8 dB lower on average
    /// than it did, which is below the level a listener notices and well inside the headroom.
    ///
    /// 0.17 is roughly 1.6 dB at the extreme. Enough that repeated hits stop being copies, small
    /// enough that it never reads as an accent the pattern did not write.
    public static let depth = 0.17

    /// How much of its level this hit keeps, in 0…1.
    ///
    /// - Parameter occurrence: which hit of this voice it is, counting from the start of the piece.
    ///   Per voice rather than across the whole schedule, so adding a cowbell does not re-roll every
    ///   hi-hat — a piece should not change because something else was added to it.
    public static func gainScale(voice: BackingVoice, occurrence: Int) -> Double {
        1 - depth * unitInterval(voice: voice, occurrence: occurrence)
    }

    /// The scale for every hit in a piece, in the order given.
    ///
    /// **Here rather than in the player**, which is where it started and where no test could reach
    /// it: `GroovePlayer.schedule` runs behind an audio device (`LESSONS.md` shape 1, the most
    /// common shape in this project). The per-voice counting is the part with a decision in it, so
    /// it is the part that has to be reachable.
    ///
    /// - Parameter hits: in the order they will be heard. Occurrence is counted per voice, so
    ///   adding a cowbell does not re-roll every hi-hat — a piece must not change because something
    ///   else was added to it.
    public static func gainScales(for hits: [ScheduledHit]) -> [Double] {
        var occurrences: [BackingVoice: Int] = [:]
        return hits.map { hit in
            let occurrence = occurrences[hit.voice, default: 0]
            occurrences[hit.voice] = occurrence + 1
            return gainScale(voice: hit.voice, occurrence: occurrence)
        }
    }

    /// A well-mixed value in 0..<1 from the voice and the index.
    ///
    /// SplitMix64's finaliser, which is what `SplitMix64` in `TimingCore` uses to turn a counter into
    /// a stream — written out here because the two pure modules do not depend on each other (R1.1.3)
    /// and this needs no generator state, only the mix.
    static func unitInterval(voice: BackingVoice, occurrence: Int) -> Double {
        var z = UInt64(bitPattern: Int64(occurrence))
        // A per-voice constant, so two voices hit on the same step do not vary together — which
        // would read as one accent rather than as two instruments.
        z &+= voiceSalt(voice)
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        z = z ^ (z >> 31)
        // The top 53 bits, which is every bit a Double can hold without rounding.
        return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Derived from the voice's name rather than from a table, so a voice added later gets its own
    /// stream without anybody having to remember to give it one.
    static func voiceSalt(_ voice: BackingVoice) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in voice.rawValue.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x1000_0000_01b3
        }
        return hash
    }
}
