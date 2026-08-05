import Foundation

/// Writes a mono 16-bit PCM WAV, so a backing can be heard without a live run.
///
/// The gap this closes: backings have no tests beyond pattern structure, and whether a groove is
/// actually playable-along-to is a judgement nobody can make from a list of step indices. Before
/// this, hearing one meant booking a session and sitting at the machine. Rendering is offline and
/// needs no hardware, so a new backing can be auditioned the moment it is written.
///
/// Deliberately hand-rolled rather than routed through `AVAudioFile`: the header is 44 bytes of
/// well-specified layout, and this way the renderer stays usable from anywhere in `TrainerKit`
/// without dragging AVFoundation into a path that has nothing to do with the audio engine.
enum WaveFile {

    /// Clipping is silent otherwise, and a groove that peaks over the rails would be judged as
    /// "sounds bad" rather than "was rendered too hot".
    static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws -> Int {
        var clipped = 0
        var data = Data()
        var pcm = Data()
        pcm.reserveCapacity(samples.count * 2)
        for sample in samples {
            let limited = Swift.max(-1, Swift.min(1, sample))
            if limited != sample { clipped += 1 }
            let value = Int16(limited * 32_767)
            pcm.append(UInt8(truncatingIfNeeded: value))
            pcm.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            }
        }
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }

        let channels: UInt16 = 1, bitsPerSample: UInt16 = 16
        let rate = UInt32(sampleRate)
        append("RIFF"); append32(UInt32(36 + pcm.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(channels)
        append32(rate)
        append32(rate * UInt32(channels) * UInt32(bitsPerSample / 8))
        append16(channels * bitsPerSample / 8); append16(bitsPerSample)
        append("data"); append32(UInt32(pcm.count))
        data.append(pcm)

        try data.write(to: url, options: .atomic)
        return clipped
    }
}
