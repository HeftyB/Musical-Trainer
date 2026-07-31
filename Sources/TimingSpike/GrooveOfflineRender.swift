import Foundation
import GrooveCore

/// Renders a schedule to a flat sample buffer, off the audio thread.
///
/// Mirrors the mixing `GroovePlayer` does in its render callback — add each voice's
/// one-shot at its scheduled sample, scaled by velocity — but returns a plain array so the
/// whole groove pipeline can be verified in `selftest` with no audio hardware.
enum GrooveOfflineRender {
    static func mix(hits: [ScheduledHit], kit: DrumKit, frames: Int, masterGain: Float = 0.6) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        for hit in hits {
            let buffer = kit.buffer(for: hit.voice)
            let gain = Float(hit.velocity) / 127 * masterGain
            let start = Int(hit.sample)
            for k in 0..<buffer.count {
                let index = start + k
                if index < 0 { continue }
                if index >= frames { break }
                out[index] += buffer[k] * gain
            }
        }
        return out
    }
}
