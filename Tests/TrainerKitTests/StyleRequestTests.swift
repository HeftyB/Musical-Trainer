import XCTest
@testable import GrooveCore
@testable import TimingCore
@testable import TrainerKit

/// Asking to play over a style, and every way that request is refused.
///
/// **All of it decided before an audio device is opened.** `runJam` opens one and waits, so a
/// refusal decided inside it could only be checked by playing a take through the speakers —
/// `LESSONS.md` shape 1, and §7.22 records a test that did exactly that for two and a half
/// minutes. `Commands.resolveStyle` is the seam, and everything below reaches it.
///
/// See PLAN.md §7.29 step 7.
final class StyleRequestTests: XCTestCase {

    private let clock = Date(timeIntervalSince1970: 1_770_000_000)

    private func flags(style: String? = nil, seed: UInt64? = nil,
                       probe: Bool = false) -> CommandFlags {
        CommandFlags(isProbe: probe, style: style, seed: seed)
    }

    // MARK: - The audition gate

    /// §7.29 step 5's gate, enforced rather than described. **This is the test that changes
    /// behaviour the day a style is approved**, which is the point: nothing may schedule music
    /// nobody has played over.
    func testAnUnauditionedStyleIsRefusedWithoutAProbe() {
        for style in StyleLibrary.all {
            XCTAssertFalse(style.auditioned, "\(style.name) was approved — see PLAN.md §7.29")
            XCTAssertThrowsError(
                try Commands.resolveStyle(flags(style: style.name), rung: nil, now: clock),
                style.name)
        }
    }

    /// And `--probe` is the way through, because auditioning a style *is* a deliberate look at a
    /// setting that was not earned — the exact thing §7.26 built the flag for. The take is stored
    /// and read by nothing that decides what to practise next.
    func testAProbeMayPlayOverAnUnauditionedStyle() throws {
        let identity = try XCTUnwrap(
            Commands.resolveStyle(flags(style: "driving", probe: true), rung: nil, now: clock))
        XCTAssertEqual(identity.style, "driving")
    }

    func testAnUnknownStyleNamesWhatTheLibraryHas() {
        XCTAssertThrowsError(
            try Commands.resolveStyle(flags(style: "motown", probe: true), rung: nil, now: clock)
        ) { error in
            let message = (error as? SpikeError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("driving"), message)
            XCTAssertTrue(message.contains("half-time"), message)
        }
    }

    /// Two backings cannot both play, and the refusal names the two things the player typed
    /// rather than talking about backings — `JamConfig.validate` throws the same refusal a layer
    /// down, and a message about the layer below is a message nobody can act on.
    func testARungAndAStyleAreRefusedTogether() {
        XCTAssertThrowsError(
            try Commands.resolveStyle(flags(style: "driving", probe: true),
                                      rung: .eighths, now: clock))
    }

    func testNoStyleAskedForResolvesToNothing() throws {
        XCTAssertNil(try Commands.resolveStyle(flags(), rung: nil, now: clock))
        XCTAssertNil(try Commands.resolveStyle(flags(), rung: .sixteenths, now: clock))
    }

    // MARK: - The seed

    func testAnExplicitSeedIsUsedExactly() throws {
        let identity = try XCTUnwrap(
            Commands.resolveStyle(flags(style: "pocket", seed: 0x5EED_0001, probe: true),
                                  rung: nil, now: clock))
        XCTAssertEqual(identity.seed, 0x5EED_0001)
        XCTAssertEqual(identity.name, "pocket@000000005eed0001")
    }

    /// A drawn seed has to differ between takes — variety is the whole point of asking for one —
    /// and it has to be **stored**, because a piece nobody can rebuild would make every take
    /// played over it unexplainable (R1.2.2). The name is the storage.
    func testADrawnSeedVariesWithTimeAndStillRoundTrips() throws {
        let first = try XCTUnwrap(
            Commands.resolveStyle(flags(style: "driving", probe: true), rung: nil, now: clock))
        let later = try XCTUnwrap(
            Commands.resolveStyle(flags(style: "driving", probe: true), rung: nil,
                                  now: clock.addingTimeInterval(37)))
        XCTAssertNotEqual(first.seed, later.seed, "two takes an evening apart got one piece")
        XCTAssertEqual(BackingIdentity.parse(first.name), first)
    }

    // MARK: - Flag parsing

    func testStyleAndSeedParseInBothSpellings() throws {
        let spaced = try CommandFlags.parse(["--style", "driving", "--seed", "5eed0001"])
        XCTAssertEqual(spaced.flags.style, "driving")
        XCTAssertEqual(spaced.flags.seed, 0x5EED_0001)

        let inline = try CommandFlags.parse(["--style=Pocket", "--seed=0x00ff"])
        XCTAssertEqual(inline.flags.style, "pocket", "a style name is lower case wherever it came from")
        XCTAssertEqual(inline.flags.seed, 0xFF)
    }

    func testPositionalArgumentsSurviveAValueTakingFlag() throws {
        let parsed = try CommandFlags.parse(["100", "--style", "driving", "64", "--probe"])
        XCTAssertEqual(parsed.positional, ["100", "64"])
        XCTAssertTrue(parsed.flags.isProbe)
        XCTAssertEqual(parsed.flags.style, "driving")
    }

    /// **A flag missing its value must not eat the next flag.** `--style --probe` is a typo, and
    /// swallowing it would run an ordinary take over a style called `--probe` — or worse, an
    /// unprobed one, which is the corruption `--probe` exists to prevent arriving through a typo.
    /// That reasoning is already why an unknown flag is an error rather than ignored.
    func testAFlagMissingItsValueDoesNotSwallowTheNextFlag() {
        XCTAssertThrowsError(try CommandFlags.parse(["--style", "--probe"]))
        XCTAssertThrowsError(try CommandFlags.parse(["--seed"]))
    }

    func testANonHexadecimalSeedIsRefused() {
        // Decimal is refused rather than accepted, or `--seed 10` means two different pieces of
        // music depending on which base the reader assumed. Takes store hex; the flag takes hex.
        XCTAssertThrowsError(try CommandFlags.parse(["--seed", "zzz"]))
        XCTAssertEqual(try CommandFlags.parse(["--seed", "10"]).flags.seed, 16)
    }
}
