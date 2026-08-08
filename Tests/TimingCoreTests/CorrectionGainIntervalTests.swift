import XCTest
import TestSupport
@testable import TimingCore

/// An interval on r₁ has to contain r₁, and cover the truth as often as it claims.
///
/// The moving-block bootstrap cannot do either. Every join between two resampled blocks is a pair
/// that was never adjacent, so a fraction ≈ `1/L` of the products are spurious and the resampled
/// statistic is attenuated by about that much — which puts the interval below the point estimate,
/// by more the larger the correlation is.
///
/// It hid for thirty takes because this player's r₁ had never left 0.13–0.50. The take that
/// exposed it reported **r₁ = +0.64 with an interval of [+0.36, +0.63]**, excluding its own point
/// estimate. See PLAN.md §7.32.
final class CorrectionGainIntervalTests: XCTestCase {

    /// AR(1) with the correlation planted by construction, from the project's seeded generator so
    /// the fixture is deterministic (R5.4).
    private func ar1(_ n: Int, rho: Double, rng: inout SplitMix64) -> [Double] {
        func gauss() -> Double {
            let u1 = Double(rng.next() % 1_000_000 + 1) / 1_000_001
            let u2 = Double(rng.next() % 1_000_000) / 1_000_000
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
        var out: [Double] = []
        var v = gauss()
        for _ in 0..<n {
            v = rho * v + (1 - rho * rho).squareRoot() * gauss()
            out.append(v)
        }
        return out
    }

    private func coverage(rho: Double, n: Int, trials: Int = 200) -> Double {
        var rng = SplitMix64(seed: 0x5EED &+ UInt64(n))
        var covered = 0
        for _ in 0..<trials {
            let x = ar1(n, rho: rho, rng: &rng)
            guard let g = Stats.gappyLag1(x, isAdjacent: { _ in true }),
                  let ci = Bootstrap.lag1Interval(r: g.r, pairs: g.pairs) else { continue }
            if ci.low <= rho && rho <= ci.high { covered += 1 }
        }
        return Double(covered) / Double(trials)
    }

    /// **The property the old method did not have.** A 95% interval must cover the planted value
    /// about 95% of the time, and must keep doing so as the correlation gets large — which is
    /// exactly where the block bootstrap collapsed to 25%.
    func testTheIntervalCoversThePlantedCorrelationAcrossItsWholeRange() {
        for (rho, n) in [(0.15, 122), (0.40, 122), (0.40, 492), (0.64, 122), (0.64, 492)] {
            let c = coverage(rho: rho, n: n)
            XCTAssertGreaterThan(c, 0.88,
                String(format: "rho %.2f, n %d: covered %.0f%% of a nominal 95%%", rho, n, c * 100))
            XCTAssertLessThan(c, 1.0,
                String(format: "rho %.2f, n %d: %.0f%% coverage means the interval is not 95%%, "
                             + "it is everything", rho, n, c * 100))
        }
    }

    /// The defect itself, so reverting the fix fails rather than merely looking different: the
    /// block bootstrap's interval sits below the estimate it is supposed to bound.
    func testTheBlockBootstrapIntervalFallsBelowTheEstimateItBounds() throws {
        var rng = SplitMix64(seed: 99)
        let x = ar1(122, rho: 0.7, rng: &rng)
        let point = try XCTUnwrap(Stats.autocorrelation(x, lag: 1))
        let bootstrapped = try XCTUnwrap(Bootstrap.interval(x, statistic: Bootstrap.lag1Stat))

        XCTAssertLessThan(bootstrapped.high, point,
            String(format: "the block bootstrap should attenuate: point %.3f, interval "
                         + "[%.3f, %.3f]", point, bootstrapped.low, bootstrapped.high))

        let honest = try XCTUnwrap(Bootstrap.lag1Interval(r: point, pairs: x.count - 1))
        XCTAssertLessThanOrEqual(honest.low, point)
        XCTAssertGreaterThanOrEqual(honest.high, point)
    }

    /// An interval around nothing is not an interval. `nil` in, `nil` out — and too few pairs to
    /// support one is the same answer (R3.3.1).
    func testNoEstimateAndTooFewPairsBothWithhold() {
        XCTAssertNil(Bootstrap.lag1Interval(r: nil, pairs: 400))
        XCTAssertNil(Bootstrap.lag1Interval(r: 0.4, pairs: 7))
        XCTAssertNotNil(Bootstrap.lag1Interval(r: 0.4, pairs: 8))
        XCTAssertNil(Bootstrap.lag1Interval(r: 1.0, pairs: 400),
                     "a perfect correlation has no standard error to speak of")
    }

    /// The interval never claims something outside what r₁ can be.
    func testTheIntervalStaysInsideMinusOneToOne() throws {
        let low = try XCTUnwrap(Bootstrap.lag1Interval(r: -0.97, pairs: 10))
        let high = try XCTUnwrap(Bootstrap.lag1Interval(r: 0.97, pairs: 10))
        XCTAssertGreaterThanOrEqual(low.low, -1)
        XCTAssertLessThanOrEqual(high.high, 1)
    }

    /// **The pairs are the pairs, not the notes.** A take with rests in it has fewer adjacencies
    /// than notes, and using the note count would report an interval narrower than the data
    /// supports — the same overconfidence in a new place (§7.32).
    func testTheIntervalWidensWhenRestsRemovePairs() throws {
        let many = try XCTUnwrap(Bootstrap.lag1Interval(r: 0.4, pairs: 400))
        let few = try XCTUnwrap(Bootstrap.lag1Interval(r: 0.4, pairs: 100))
        XCTAssertGreaterThan(few.high - few.low, many.high - many.low)
    }
}
