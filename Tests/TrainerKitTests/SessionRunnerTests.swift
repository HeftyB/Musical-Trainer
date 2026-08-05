import XCTest
@testable import TimingCore
@testable import TrainerKit

/// The sequencing half of a session: what ran, what was skipped, and what the manifest says.
///
/// `runCurrent` needs audio and stays live-run-only (R5.6). Everything around it does not, and
/// it is where a session's *record* comes from — §7.20 finding 11 turned on a destroyed take
/// being indistinguishable from a declined one in exactly this manifest.
final class SessionRunnerTests: StoreBackedTestCase {

    private func plan(minutes: Int = 20) -> SessionPlan {
        SessionPlanner.plan(targetMinutes: minutes, from: PlannerInput())
    }

    func testAFreshRunnerStartsAtTheFirstBlock() {
        let p = plan()
        let runner = SessionRunner(plan: p)
        XCTAssertEqual(runner.index, 0)
        XCTAssertFalse(runner.isFinished)
        XCTAssertEqual(runner.remainingCount, p.blocks.count)
        XCTAssertEqual(runner.currentBlock?.role, p.blocks.first?.role)
    }

    func testSkippingAdvancesAndRecordsTheBlockAsSkipped() {
        let runner = SessionRunner(plan: plan())
        let first = runner.currentBlock
        runner.skip()

        XCTAssertEqual(runner.index, 1)
        XCTAssertEqual(runner.results.count, 1)
        let result = runner.results.first
        XCTAssertEqual(result?.wasSkipped, true)
        XCTAssertNil(result?.outcome)
        XCTAssertEqual(result?.block.role, first?.role)
    }

    func testAnUnmeasuredBlockIsCompletedButCarriesNoNumbers() throws {
        let runner = SessionRunner(plan: plan())
        try runner.complete(.unmeasured, feelRating: nil)

        let result = try XCTUnwrap(runner.results.first)
        XCTAssertFalse(result.wasSkipped)
        XCTAssertEqual(result.outcome?.isMeasured, false)
        XCTAssertNil(result.outcome?.headline)
        XCTAssertNil(result.outcome?.detail)
    }

    func testRunningToTheEndFinishesTheSession() {
        let p = plan()
        let runner = SessionRunner(plan: p)
        for _ in p.blocks { runner.skip() }

        XCTAssertTrue(runner.isFinished)
        XCTAssertNil(runner.currentBlock)
        XCTAssertEqual(runner.remainingCount, 0)
        XCTAssertEqual(runner.remainingSeconds, 0, accuracy: 1e-9)
    }

    func testRemainingTimeFallsAsBlocksAreConsumed() {
        let runner = SessionRunner(plan: plan())
        let before = runner.remainingSeconds
        runner.skip()
        XCTAssertLessThan(runner.remainingSeconds, before)
    }

    /// The manifest carries the intent — what the planner chose and what did not happen — while
    /// the takes carry the measurements. Without it a session where two drills were abandoned
    /// looks identical to one that was planned short.
    func testTheManifestRecordsWhatWasSkipped() throws {
        assertStoreIsRedirected()
        let p = plan()
        let runner = SessionRunner(plan: p)
        runner.skip()
        try runner.complete(.unmeasured, feelRating: nil)
        for _ in 2..<p.blocks.count { runner.skip() }

        let summary = try runner.finish(endedEarly: false)
        XCTAssertEqual(summary.results.count, p.blocks.count)
        XCTAssertEqual(summary.skippedCount, p.blocks.count - 1)
        XCTAssertEqual(summary.completedCount, 1)
        // The warm-up is completed but unmeasured, so nothing is left to debrief.
        XCTAssertTrue(summary.measuredResults.isEmpty)

        let stored = try XCTUnwrap(SessionStore.loadAllSessions().first)
        XCTAssertEqual(stored.blocks.count, p.blocks.count)
        XCTAssertEqual(stored.blocks.first?.skipped, true)
        XCTAssertEqual(stored.blocks.map(\.role), p.blocks.map(\.role.rawValue))
        XCTAssertEqual(stored.targetMinutes, p.targetMinutes)
        XCTAssertEqual(stored.planNotes, p.notes)
    }

    func testEveryPlannedSessionLandsNearItsTarget() {
        // The plan preview promises a length, so the arithmetic behind it has to agree with the
        // blocks it actually chose. Twenty per cent either way is the tolerance the closing
        // jam's snapping to whole phrases can produce.
        for minutes in [20, 30, 45] {
            let p = plan(minutes: minutes)
            let target = Double(minutes) * 60
            XCTAssertEqual(p.estimatedSeconds, target, accuracy: target * 0.2,
                           "a \(minutes)-minute session estimated \(p.estimatedSeconds / 60) min")
            XCTAssertEqual(SessionRunner(plan: p).remainingSeconds, p.estimatedSeconds,
                           accuracy: 1e-6, "the runner and the plan must agree on the length")
        }
    }
}
