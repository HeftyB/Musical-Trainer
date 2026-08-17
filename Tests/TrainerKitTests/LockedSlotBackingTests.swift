import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// Generated music may never reach a locked slot.
///
/// R3.5 freezes the cold probe, the benchmark and both experiment arms, and **the failure here is
/// silent**: a benchmark take over a generated backing is a perfectly good take that has quietly
/// left the series it exists to extend, and no readout would say so. The 21 free jams at 100 BPM
/// and the five-point benchmark are the only longitudinal data this project has.
///
/// Three layers, and this file holds two of them — the planner cannot express it
/// (`LadderPlanningTests`), the resolution refuses it whatever the plan says, and the config
/// refuses a pair of backings outright. See PLAN.md §7.29 step 7.
final class LockedSlotBackingTests: XCTestCase {

    private let generated = PlannedBacking(style: "driving", seed: 0x5EED_0001)

    /// **A plan is not trusted.** Even handed a block that explicitly asks for a style, a locked
    /// role plays the fixed backing — because the planner is not the only thing that builds one.
    /// A stored manifest is replayed, and a manifest written by a future version is not something
    /// today's planner controls.
    func testALockedRoleIgnoresAGeneratedBackingEvenWhenThePlanAsksForOne() {
        let plan = JamPlan(bpm: 100, bars: 32, tag: "benchmark", generatedBacking: generated)
        for role in BlockRole.allCases where SessionRunner.lockedToTheFixedBacking(role) {
            let config = SessionRunner.jamConfig(for: plan, role: role)
            XCTAssertNil(config.generatedBacking,
                         "\(role.rawValue) accepted a generated backing")
            XCTAssertEqual(config.backing.name, "jamBacking",
                           "\(role.rawValue) played music no earlier take in its series did")
            XCTAssertEqual(config.backing.arrangement, GrooveLibrary.jamBacking, role.rawValue)
        }
    }

    /// The complement, so the guard is not simply "never": the roles §7.29's slot table calls deep
    /// do carry it through, or the milestone delivers nothing.
    func testAnUnlockedRoleCarriesTheGeneratedBackingThrough() {
        let plan = JamPlan(bpm: 100, bars: 32, tag: nil, generatedBacking: generated)
        for role in BlockRole.allCases where !SessionRunner.lockedToTheFixedBacking(role) {
            let config = SessionRunner.jamConfig(for: plan, role: role)
            XCTAssertEqual(config.generatedBacking,
                           BackingIdentity(style: "driving", seed: 0x5EED_0001), role.rawValue)
            XCTAssertEqual(config.backing.name, "driving@000000005eed0001", role.rawValue)
        }
    }

    /// **Every role is classified, and the split is the one §7.29's slot table sets out.** Written
    /// against `allCases` rather than a list, so a role added later fails here until somebody
    /// decides which side of the line it is on — the compiler catches it in
    /// `lockedToTheFixedBacking`, and this catches a wrong answer.
    func testTheSlotTableIsExactlyWhatIsLocked() {
        let locked = Set(BlockRole.allCases.filter(SessionRunner.lockedToTheFixedBacking))
        XCTAssertEqual(locked, [.cold, .benchmark, .experiment])
        XCTAssertEqual(Set(BlockRole.allCases).subtracting(locked), [.warmUp, .training, .closing])
    }

    /// A take whose music nobody can name is a take whose number nobody can attribute. Refused at
    /// the boundary rather than resolved by precedence, because a silent preference is how the
    /// caller finds out months later (R7.6).
    func testAStyleAndARungCannotBothBeAsked() {
        var config = TrainerEngine.JamConfig(bpm: 100, bars: 32, rung: .eighths)
        config.generatedBacking = BackingIdentity(style: "driving", seed: 1)
        XCTAssertThrowsError(try config.validate())
    }

    func testAStyleAndTheOffbeatDrillCannotBothBeAsked() {
        var config = TrainerEngine.JamConfig(bpm: 100, bars: 32, offbeatLevel: .barOnly)
        config.generatedBacking = BackingIdentity(style: "driving", seed: 1)
        XCTAssertThrowsError(try config.validate())
    }

    /// A manifest naming a style the library no longer has must fall back and **say so through the
    /// name it stores**, not trap and not substitute a neighbour. R6.4: a decode that cannot be
    /// honoured is reported rather than swallowed, and a wrong groove played confidently is worse
    /// than a familiar one. The rename from `motown` to `pocket` already happened once.
    func testAnUnknownStyleFallsBackToTheFixedBackingAndSaysSo() {
        var config = TrainerEngine.JamConfig(bpm: 100, bars: 32)
        config.generatedBacking = BackingIdentity(style: "motown", seed: 1)
        XCTAssertNil(StyleLibrary.named("motown"), "the premise of this test")
        XCTAssertEqual(config.backing.name, "jamBacking")
        XCTAssertEqual(config.backing.arrangement, GrooveLibrary.jamBacking)
    }

    /// The seed is what makes generation permissible rather than reckless (R1.2.2), so the music a
    /// take plays has to be rebuildable from the name it is stored under — for ever, by anything
    /// that can parse it.
    func testTheStoredNameRebuildsExactlyTheMusicThatPlayed() throws {
        for style in StyleLibrary.all {
            var config = TrainerEngine.JamConfig(bpm: 100, bars: 32)
            config.generatedBacking = BackingIdentity(style: style.name, seed: 0xABCD_1234)
            let identity = try XCTUnwrap(BackingIdentity.parse(config.backing.name))
            let rebuilt = StyleArranger.arrangement(
                style: try XCTUnwrap(StyleLibrary.named(identity.style)),
                seed: identity.seed, bars: 32)
            XCTAssertEqual(config.backing.arrangement, rebuilt, style.name)
        }
    }

    /// The library the planner may schedule from, and it is no longer empty (§7.33).
    ///
    /// It was empty by design until 8 August: `Style.auditioned` is a flag nobody who writes a
    /// style can set honestly, so the planner started with nothing and had to cope rather than
    /// reach past the gate. What matters now is the other half of that rule — **the planner sees
    /// `auditioned`, never `all`** — so a style authored tomorrow cannot be scheduled by anything
    /// until somebody says it may be.
    /// **Back to four as of §7.69**, on kits heard across two listening passes. What this asserts is
    /// the *rule* rather than the count: the planner reads `auditioned`, never `all`, so a style
    /// authored tomorrow — or a kit changed under an existing one — cannot be scheduled until
    /// somebody says it may be.
    func testThePlannerSchedulesFromTheApprovedLibraryAndNotTheWholeOne() {
        XCTAssertTrue(StyleLibrary.auditioned.allSatisfy(\.auditioned))
        XCTAssertTrue(StyleLibrary.auditioned.allSatisfy { StyleLibrary.all.contains($0) })

        // The guard the count above cannot give: an unapproved style must not be reachable. With
        // everything approved there is none to test against, so one is made.
        let unheard = Style(name: "unheard", layers: StyleLibrary.all[0].layers,
                            fills: StyleLibrary.all[0].fills, playerVoices: [],
                            density: StyleLibrary.all[0].density)
        XCTAssertFalse(unheard.auditioned, "a style starts unapproved or the flag means nothing")
    }
}
