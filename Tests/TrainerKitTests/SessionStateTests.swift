import XCTest
@testable import TimingCore
@testable import TrainerKit

/// A sitting's declared state, and the ordering that makes it a condition rather than an excuse.
///
/// M15 step 0b. The player slept through most of a session and there was nowhere to say so —
/// single takes carry a `tag`, session takes get role tags instead. Declared **before** the
/// first block it is an ordinary condition and `review tags` already knows how to pool
/// conditions; marked afterwards it would be post-hoc exclusion, one step from dropping the
/// takes you did not like.
final class SessionStateTests: StoreBackedTestCase {

    private func plan() -> SessionPlan {
        SessionPlanner.plan(targetMinutes: 30, from: PlannerInput())
    }

    // MARK: The ordering that is the whole point

    /// The state is fixed at construction and there is no way to set it afterwards. If this
    /// stops compiling because a setter appeared, the guarantee has gone with it.
    func testTheStateIsDeclaredAtTheStartAndCannotBeChangedLater() {
        let runner = SessionRunner(plan: plan(), state: .tired)
        XCTAssertEqual(runner.state, .tired)

        let mirror = Mirror(reflecting: runner)
        XCTAssertTrue(mirror.children.contains { $0.label == "state" },
                      "state is stored on the runner, not passed in at save time")
    }

    // MARK: It reaches every take of the sitting

    func testEveryTakeOfTheSittingCarriesTheState() {
        let p = plan()
        let runner = SessionRunner(plan: p, state: .distracted)

        // Every block of the evening, not just the first: a declaration that reached the
        // benchmark and not the closing jam would pool half a sitting under it.
        for (index, block) in p.blocks.enumerated() {
            let placement = runner.placement(forBlock: block, at: Double(index) * 60)
            XCTAssertEqual(placement.state, "distracted", "block \(index) missed it")
            XCTAssertEqual(placement.sessionId, runner.sessionId)
            XCTAssertEqual(placement.role, block.role.rawValue)
        }
    }

    /// The manifest carries it too: the takes are the measurements, the manifest is the intent,
    /// and "what did I say before this evening" belongs with the intent.
    func testTheManifestCarriesTheStateAsWell() throws {
        let runner = SessionRunner(plan: plan(), state: .stiff)
        _ = try runner.finish(endedEarly: true)

        let record = try XCTUnwrap(SessionStore.loadAllSessions()
            .first { $0.id == runner.sessionId })
        XCTAssertEqual(record.state, "stiff")
    }

    // MARK: Not declared is not the same as declared ordinary

    /// Every take before M15 has no declaration, and folding that into `usual` would erase the
    /// difference between saying nothing and saying nothing was wrong.
    func testARunnerWithNoDeclarationStampsNothingRatherThanUsual() throws {
        let p = plan()
        let runner = SessionRunner(plan: p)
        XCTAssertNil(runner.state)
        XCTAssertNil(runner.placement(forBlock: try XCTUnwrap(p.blocks.first), at: 0).state)
    }

    /// And a take recorded before the field existed still decodes (R6.1).
    func testATakeWithoutTheFieldStillDecodes() throws {
        let stored = TakeFactory.jam()
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(stored)) as? [String: Any])
        var placement = try XCTUnwrap(json["placement"] as? [String: Any])
        placement.removeValue(forKey: "state")
        json["placement"] = placement

        let back = try JSONDecoder().decode(
            JamSession.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.placement?.state)
        XCTAssertEqual(back.placement?.role, stored.placement?.role, "the rest is untouched")
    }

    // MARK: The list itself

    /// `usual` first, because the console picker defaults to the first option and the app's
    /// picker starts there — the unmarked case has to be the one you get by pressing through.
    func testTheUnmarkedCaseIsFirstAndIsNotAClaimAboutBeingWellRested() {
        XCTAssertEqual(SessionState.allCases.first, .usual)
        XCTAssertEqual(SessionState.usual.rawValue, "usual")
    }

    /// A state sharing a name with a tag, an arm or a role would pool two different things into
    /// one condition the first time anybody grouped by name.
    func testNoStateCollidesWithAnExistingTagArmOrRole() {
        let taken = Set(BlockRole.allCases.map(\.rawValue))
            .union(ExperimentLibrary.all.flatMap(\.arms))
            .union([SessionPlanner.benchmarkTag, SessionPlanner.closingTag, "ladder"])

        for state in SessionState.allCases {
            XCTAssertFalse(taken.contains(state.rawValue),
                           "'\(state.rawValue)' is already a tag, arm or role")
        }
    }

    func testEveryStateHasABlurbForThePicker() {
        for state in SessionState.allCases {
            XCTAssertFalse(state.blurb.isEmpty, "\(state.rawValue)")
        }
    }
}
