import XCTest
@testable import TimingCore
@testable import TrainerKit

/// Flags, parsed where a test can reach them.
///
/// Every drill command opens an audio device and waits, so nothing that goes through one can be
/// tested — which is why argument handling lives in functions like this one and never inside the
/// command (§7.22, and §7.24 step 5 where a real take was started from a shell to check an
/// argument). See PLAN.md §7.26.
final class CommandFlagTests: XCTestCase {

    private func parse(_ line: String) throws -> (flags: CommandFlags, positional: [String]) {
        try CommandFlags.parse(line.split(separator: " ").map(String.init))
    }

    func testNoFlagsLeavesEveryArgumentInPlace() throws {
        let result = try parse("form 100 64 8 3")
        XCTAssertFalse(result.flags.isProbe)
        XCTAssertEqual(result.positional, ["form", "100", "64", "8", "3"])
    }

    func testAFlagIsRemovedFromThePositionalArguments() throws {
        let result = try parse("form 100 64 8 3 --probe")
        XCTAssertTrue(result.flags.isProbe)
        XCTAssertEqual(result.positional, ["form", "100", "64", "8", "3"],
                       "positional arguments keep counting from zero, or every default below "
                     + "them shifts")
    }

    /// The reason flags are extracted first rather than read off the tail.
    func testAFlagMaySitAnywhereOnTheLine() throws {
        for line in ["--probe form 100 64 8 3",
                     "form --probe 100 64 8 3",
                     "form 100 64 --probe 8 3",
                     "form 100 64 8 3 --probe"] {
            let result = try parse(line)
            XCTAssertTrue(result.flags.isProbe, line)
            XCTAssertEqual(result.positional, ["form", "100", "64", "8", "3"], line)
        }
    }

    /// A dropped flag is worse than a rejected one: the take still runs, and is recorded as a
    /// setting the player earned. That is the corruption `--probe` exists to prevent, arriving
    /// through a typo.
    func testAnUnknownFlagIsRefusedRatherThanIgnored() {
        XCTAssertThrowsError(try parse("form 100 64 8 3 --porbe")) { error in
            XCTAssertTrue("\(error)".contains("--porbe"), "\(error)")
            XCTAssertTrue("\(error)".contains("--probe"), "and says what is accepted: \(error)")
        }
    }

    func testNegativeNumbersAreNotMistakenForFlags() throws {
        let result = try parse("jam 100 32 relaxed eighths -1")
        XCTAssertEqual(result.positional.last, "-1")
        XCTAssertFalse(result.flags.isProbe)
    }
}

/// A probe is stored, and nothing that decides what to practise next reads one.
final class ProbeTakeTests: StoreBackedTestCase {

    /// Four marks over eight phrases, so the earned takes leave phrases unmarked and the
    /// promotion gate holds them at level 2. A perfect fixture would be promoted on its merits
    /// and the probe would prove nothing.
    func testAProbeFormTakeDoesNotMoveTheLadder() throws {
        assertStoreIsRedirected()
        for day in 0..<3 {
            try SessionStore.save(TakeFactory.form(marks: 4, level: 2, dayOffset: day))
        }
        try SessionStore.save(TakeFactory.form(marks: 4, level: 3, dayOffset: 3, wasProbe: true))

        let block = try XCTUnwrap(firstFormBlock(TrainerEngine.planSession(targetMinutes: 30)))
        XCTAssertEqual(block.level, 2,
                       "the ladder is where it was earned, not where it was probed — without "
                     + "this the next session plans level 3 and says to stay there until it is "
                     + "above 90%")
    }

    func testAnOrdinaryLevelThreeTakeStillMovesIt() throws {
        assertStoreIsRedirected()
        for day in 0..<3 {
            try SessionStore.save(TakeFactory.form(marks: 4, level: 2, dayOffset: day))
        }
        try SessionStore.save(TakeFactory.form(marks: 4, level: 3, dayOffset: 3))

        let block = try XCTUnwrap(firstFormBlock(TrainerEngine.planSession(targetMinutes: 30)))
        XCTAssertEqual(block.level, 3,
                       "a take the player was not flagged out of is evidence like any other — "
                     + "the flag is the whole distinction")
    }

    func testAProbeSurvivesStorageAndIsMarkedInTheHistory() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.form(level: 3, wasProbe: true))
        let loaded = try XCTUnwrap(SessionStore.loadAllForm().first)
        XCTAssertEqual(loaded.wasProbe, true)
    }

    func testAnOrdinaryTakeStoresNothingRatherThanFalse() throws {
        assertStoreIsRedirected()
        try SessionStore.save(TakeFactory.form(level: 2))
        let loaded = try XCTUnwrap(SessionStore.loadAllForm().first)
        XCTAssertNil(loaded.wasProbe,
                     "absent means an ordinary take, which every take recorded before the flag "
                   + "existed was — so nothing on record moves")
    }

    private func firstFormBlock(_ plan: SessionPlan) -> FormPlan? {
        for block in plan.blocks {
            if case .form(let p) = block.plan { return p }
        }
        return nil
    }
}
