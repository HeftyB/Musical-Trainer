import XCTest
import TestSupport
@testable import TimingCore

/// Comparing correction gains across takes, by methods that are valid for r₁.
///
/// §7.32 withheld r₁ from `review compare` and `review conditions` rather than bound it with the
/// block bootstrap, which attenuates it — and in the pooled case attenuates it *twice*, because
/// `resamplePool` concatenates a block-resampled series per take and so adds a spurious adjacency
/// at every take boundary. These are the replacements it queued.
final class CorrectionGainAcrossTakesTests: XCTestCase {

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

    // MARK: - Two takes

    /// **The property that matters for a verdict**: two takes drawn from the *same* correlation
    /// must be called "within noise" about as often as the level says, or "real change" means
    /// nothing. The block bootstrap could not do this — it attenuates each side by an amount that
    /// depends on that take's own length, so two equal takes of different lengths differ by
    /// construction.
    func testTakesFromOneCorrelationAreCalledWithinNoise() {
        var rng = SplitMix64(seed: 4242)
        var falsePositives = 0
        let trials = 200
        for _ in 0..<trials {
            // Deliberately different lengths: that is what broke the old method.
            let a = ar1(120, rho: 0.4, rng: &rng)
            let b = ar1(480, rho: 0.4, rng: &rng)
            guard let ga = Stats.gappyLag1(a, isAdjacent: { _ in true }),
                  let gb = Stats.gappyLag1(b, isAdjacent: { _ in true }),
                  let d = Bootstrap.lag1Difference(a: ga.r, pairsA: ga.pairs,
                                                   b: gb.r, pairsB: gb.pairs) else {
                return XCTFail("no interval for two ordinary takes")
            }
            if d.excludesZero { falsePositives += 1 }
        }
        let rate = Double(falsePositives) / Double(trials)
        XCTAssertLessThan(rate, 0.12,
            String(format: "%.0f%% of equal pairs called a real change; a 95%% interval should "
                         + "call about 5%%", rate * 100))
    }

    /// And it has to find a difference that is really there, or "within noise" is just silence.
    func testAGenuineDifferenceIsFound() throws {
        var rng = SplitMix64(seed: 7)
        let a = ar1(400, rho: 0.10, rng: &rng)
        let b = ar1(400, rho: 0.60, rng: &rng)
        let ga = try XCTUnwrap(Stats.gappyLag1(a, isAdjacent: { _ in true }))
        let gb = try XCTUnwrap(Stats.gappyLag1(b, isAdjacent: { _ in true }))
        let d = try XCTUnwrap(Bootstrap.lag1Difference(a: ga.r, pairsA: ga.pairs,
                                                       b: gb.r, pairsB: gb.pairs))
        XCTAssertTrue(d.excludesZero, "0.10 against 0.60 is not noise: \(d)")
        XCTAssertEqual(d.point, 0.5, accuracy: 0.15)
    }

    /// The sign is load-bearing — `b − a`, the change from the earlier take to the later, matching
    /// every other row of `review compare`.
    func testTheDifferenceRunsFromAToB() throws {
        let d = try XCTUnwrap(Bootstrap.lag1Difference(a: 0.2, pairsA: 200, b: 0.5, pairsB: 200))
        XCTAssertEqual(d.point, 0.3, accuracy: 1e-9)
    }

    /// A comparison against a take that has no correction gain is not a smaller comparison, it is
    /// no comparison (R3.3.1).
    func testAMissingSideWithholdsTheWholeDifference() {
        XCTAssertNil(Bootstrap.lag1Difference(a: nil, pairsA: 200, b: 0.4, pairsB: 200))
        XCTAssertNil(Bootstrap.lag1Difference(a: 0.4, pairsA: 200, b: nil, pairsB: 200))
        XCTAssertNil(Bootstrap.lag1Difference(a: 0.4, pairsA: 7, b: 0.4, pairsB: 200))
    }

    /// Fewer pairs on either side must widen the interval, because a take with rests in it
    /// supports less than its note count suggests (§7.32).
    func testFewerPairsWidenTheDifference() throws {
        let wide = try XCTUnwrap(Bootstrap.lag1Difference(a: 0.3, pairsA: 40, b: 0.4, pairsB: 40))
        let tight = try XCTUnwrap(Bootstrap.lag1Difference(a: 0.3, pairsA: 400, b: 0.4, pairsB: 400))
        XCTAssertGreaterThan(wide.high - wide.low, tight.high - tight.low)
    }

    // MARK: - Pooled across takes

    /// **The unit is the take.** Between-take variation is most of the variation, which is the
    /// whole finding of §7.20 — so the takes are what get resampled, not the notes inside them.
    func testThePooledIntervalWidensWithBetweenTakeSpread() throws {
        let agreeing = try XCTUnwrap(Bootstrap.pooledLag1Interval([0.30, 0.31, 0.29, 0.30]))
        let scattered = try XCTUnwrap(Bootstrap.pooledLag1Interval([0.05, 0.55, 0.10, 0.50]))
        XCTAssertEqual(agreeing.point, 0.30, accuracy: 0.01)
        XCTAssertEqual(scattered.point, 0.30, accuracy: 0.01)
        XCTAssertGreaterThan(scattered.high - scattered.low, (agreeing.high - agreeing.low) * 3,
                             "identical means, and only the agreement differs — the interval has "
                           + "to see that or it is blind to what varies most")
    }

    /// A condition of one take gets no interval, which is R3.2.1 and the defect §7.20 finding 1
    /// removed: the only variation inside a single take is within-take variation.
    func testOneTakeGetsNoInterval() {
        XCTAssertNil(Bootstrap.pooledLag1Interval([0.4]))
        XCTAssertNil(Bootstrap.pooledLag1Interval([]))
        XCTAssertNotNil(Bootstrap.pooledLag1Interval([0.4, 0.3]))
    }

    /// Deterministic, like every other bootstrap here (R1.2.1): the same takes give the same
    /// interval, or "real change" is a coin flip.
    func testThePooledIntervalIsSeeded() throws {
        let values = [0.1, 0.4, 0.25, 0.5, 0.2]
        let first = try XCTUnwrap(Bootstrap.pooledLag1Interval(values))
        let second = try XCTUnwrap(Bootstrap.pooledLag1Interval(values))
        XCTAssertEqual(first.low, second.low)
        XCTAssertEqual(first.high, second.high)
    }
}
