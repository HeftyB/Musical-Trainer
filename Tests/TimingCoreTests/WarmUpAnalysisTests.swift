import XCTest
@testable import TimingCore

final class WarmUpAnalysisTests: XCTestCase {

    /// Build a sitting: `count` takes spaced `spacing` minutes apart, starting at `start` and
    /// changing by `perMinute` as the evening goes on.
    private func sitting(_ index: Int, start: Double, perMinute: Double,
                         count: Int = 4, spacing: Double = 6,
                         noise: Double = 0, seed: UInt64 = 1) -> [SessionedTake] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { i in
            let elapsed = Double(i) * spacing
            let jitter = noise == 0 ? 0
                : (Double(rng.next() >> 11) / Double(1 << 53) - 0.5) * 2 * noise
            return SessionedTake(sessionIndex: index, elapsedMinutes: elapsed,
                                 isColdProbe: i == 0,
                                 value: start + perMinute * elapsed + jitter)
        }
    }

    // MARK: - The question the milestone exists for

    /// Improvement inside every sitting, but every sitting starts in the same place. That is
    /// warming up, and calling it progress is the mistake M10 exists to prevent.
    func testImprovingWithinEverySittingButNeverColdIsWarmUpOnly() {
        let takes = (0..<5).flatMap { sitting($0, start: 5, perMinute: -0.2, noise: 0.1,
                                              seed: UInt64(10 + $0)) }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)

        XCTAssertEqual(report.verdict, .warmUpOnly)
        XCTAssertEqual(report.withinSession?.verdict, .improving)
        XCTAssertEqual(report.betweenSessions?.verdict, .flat)
        XCTAssertTrue(report.headline.contains("warm-up, not learning"))
    }

    /// The cold start itself comes down across days: the gain survived a night's sleep.
    func testFallingColdStartsAreLearning() {
        let takes = (0..<5).flatMap { session in
            sitting(session, start: 5 - Double(session) * 0.6, perMinute: 0,
                    noise: 0.05, seed: UInt64(20 + session))
        }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)

        XCTAssertEqual(report.verdict, .learning)
        XCTAssertEqual(report.betweenSessions?.verdict, .improving)
        XCTAssertTrue(report.headline.contains("learning"))
    }

    func testBothEffectsAreSeparatedWhenBothArePresent() {
        let takes = (0..<6).flatMap { session in
            sitting(session, start: 6 - Double(session) * 0.5, perMinute: -0.15,
                    noise: 0.05, seed: UInt64(30 + session))
        }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)

        XCTAssertEqual(report.verdict, .both)
        XCTAssertEqual(report.withinSession?.verdict, .improving)
        XCTAssertEqual(report.betweenSessions?.verdict, .improving)
    }

    func testPureNoiseConcludesNeither() {
        let takes = (0..<5).flatMap { sitting($0, start: 5, perMinute: 0, noise: 1.5,
                                              seed: UInt64(40 + $0)) }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)
        XCTAssertEqual(report.verdict, .neither)
    }

    // MARK: - Why the estimator is built the way it is

    /// A sitting that was simply a good day must not become evidence of warming up.
    ///
    /// Every sitting here is dead flat internally; the sittings merely differ from each other,
    /// and they happen to get better as the weeks go by. A naive fit of value against elapsed
    /// minutes across the pooled takes would find a slope where there is none, because later
    /// sittings are both better *and* arbitrarily positioned in the evening. Centring each
    /// sitting on its own means is what stops that.
    func testBetweenSittingDifferencesDoNotLeakIntoTheWarmUpSlope() {
        var takes: [SessionedTake] = []
        for session in 0..<6 {
            // Flat within the evening, but each evening starts later and lower.
            let offset = Double(session) * 3
            for i in 0..<4 {
                takes.append(SessionedTake(sessionIndex: session,
                                           elapsedMinutes: offset + Double(i) * 6,
                                           isColdProbe: i == 0,
                                           value: 8 - Double(session) * 0.7))
            }
        }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)
        XCTAssertEqual(report.withinSession?.slope ?? .nan, 0, accuracy: 1e-9,
                       "a flat evening must contribute no warm-up slope")
        XCTAssertEqual(report.verdict, .learning)
    }

    /// One evening cannot separate warming up from having had a good night, however many
    /// takes it contains.
    func testASingleSittingCannotSupportAWarmUpSlope() {
        let report = WarmUpAnalysis.analyze(sitting(0, start: 5, perMinute: -0.3, count: 8),
                                            lowerIsBetter: true)
        XCTAssertNil(report.withinSession)
        XCTAssertEqual(report.verdict, .notEnoughData)
        XCTAssertTrue(report.notes.contains { $0.contains("Only one sitting") })
    }

    func testTakesCrammedIntoAFewMinutesSaySayNothingAboutWarmingUp() {
        // Four takes inside two minutes: no span to fit a warm-up curve through.
        let takes = (0..<4).flatMap { sitting($0, start: 5, perMinute: -0.2,
                                              count: 3, spacing: 0.6) }
        XCTAssertNil(WarmUpAnalysis.analyze(takes, lowerIsBetter: true).withinSession)
    }

    func testTooFewSittingsRefusesToConclude() {
        let takes = (0..<2).flatMap { sitting($0, start: 5, perMinute: -0.3) }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)
        XCTAssertEqual(report.verdict, .notEnoughData)
        XCTAssertNil(report.betweenSessions)
        XCTAssertTrue(report.notes.contains { $0.contains("sitting(s) on record") })
    }

    /// Getting worse across an evening is fatigue, and it should be said rather than folded
    /// into "no warm-up effect".
    func testDecliningAcrossAnEveningIsNamedAsFatigue() {
        let takes = (0..<5).flatMap { sitting($0, start: 5, perMinute: 0.25, noise: 0.1,
                                              seed: UInt64(50 + $0)) }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)
        XCTAssertEqual(report.withinSession?.verdict, .worsening)
        XCTAssertTrue(report.notes.contains { $0.contains("fatigue") })
    }

    /// A first take is not a cold probe: it differs in drill and settings as well as in
    /// temperature, and the report has to say so rather than quietly equating them.
    func testInferredColdValuesAreFlaggedAsNotControlled() {
        let takes = (0..<4).flatMap { session in
            sitting(session, start: 5, perMinute: -0.1, seed: UInt64(60 + session))
                .map { SessionedTake(sessionIndex: $0.sessionIndex,
                                     elapsedMinutes: $0.elapsedMinutes,
                                     isColdProbe: false, value: $0.value) }
        }
        let report = WarmUpAnalysis.analyze(takes, lowerIsBetter: true)
        XCTAssertFalse(report.coldIsControlled)
        XCTAssertTrue(report.notes.contains { $0.contains("controlled cold probe") })
    }

    func testDirectionFollowsTheMetric() {
        // On-form rate: higher is better, so a rising cold value is progress.
        let takes = (0..<5).flatMap { session in
            sitting(session, start: 0.4 + Double(session) * 0.06, perMinute: 0,
                    noise: 0.01, seed: UInt64(70 + session))
        }
        XCTAssertEqual(WarmUpAnalysis.analyze(takes, lowerIsBetter: false).verdict, .learning)
        XCTAssertEqual(WarmUpAnalysis.analyze(takes, lowerIsBetter: true).betweenSessions?.verdict,
                       .worsening)
    }

    // MARK: - Recovering sittings from timestamps

    func testSittingsAreRecoveredFromGapsInTheTimestamps() {
        let minute = 60.0
        // Three takes minutes apart, then a two-hour gap, then two more.
        let times = [0, 8 * minute, 20 * minute, 20 * minute + 7200, 20 * minute + 7500]
        XCTAssertEqual(WarmUpAnalysis.inferSessions(times: times), [0, 0, 0, 1, 1])
    }

    func testASingleTakeIsASittingOfOne() {
        XCTAssertEqual(WarmUpAnalysis.inferSessions(times: [0]), [0])
        XCTAssertEqual(WarmUpAnalysis.inferSessions(times: []), [])
    }
}
