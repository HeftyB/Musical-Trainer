import Foundation
@testable import TrainerKit

/// One `BackingKit` per sample rate, for the whole test target.
///
/// **Building a kit is now the most expensive thing a test can do.** Fifty-two buffers, each run
/// through the room's comb network, in a debug build: about twenty seconds. Four suites were each
/// building their own — some more than once — and `swift test` went from 145 seconds to 246 when the
/// room landed (§7.65), with 210 of those in the four suites that touch a kit.
///
/// That matters beyond patience. `check.sh --fast` runs on every commit through the pre-commit hook,
/// and a gate slow enough to be worth skipping is a gate that gets skipped — `LESSONS.md` shape 21,
/// arriving by way of the clock rather than by way of an unenforced rule.
///
/// A kit is immutable once built and carries no per-test state, so sharing one is free. Rates are
/// cached rather than fixed because the fingerprint's whole argument is that the same synthesis at
/// two rates is one kit, and a test has to be able to build both.
enum TestKit {
    private static var cache: [Double: BackingKit] = [:]

    static func at(_ sampleRate: Double = 44_100) -> BackingKit {
        if let hit = cache[sampleRate] { return hit }
        let kit = BackingKit(sampleRate: sampleRate)
        cache[sampleRate] = kit
        return kit
    }
}
