import XCTest
@testable import TrainerKit

/// The capture buffer's own rules, tested directly for the first time.
///
/// `CaptureLossTests` states that the overflow *"cannot be provoked without CoreMIDI delivering tens
/// of thousands of packets"*, and that was true for as long as this logic lived inside a private
/// method on the class that talks to CoreMIDI. §7.58 moved it into `MIDIInput.Capture` so the lock
/// would hold it by construction rather than by comment, and a struct carrying a pointer and a count
/// can simply be handed a capacity of three.
///
/// So what is exercised here is the pair of paths this project has only ever been able to argue
/// about in prose: **what happens at the end of the buffer** (`LESSONS.md` shape 20, the error path
/// discarding exactly the observation that says something went wrong) and **what a take boundary
/// does to the dedup window** (§7.57, where clearing it raced the thread that reads it).
///
/// The window is a parameter rather than `HostClock.ticks(seconds: 0.003)`, so these are arithmetic
/// about host times rather than assertions about the machine's clock.
final class CaptureTests: XCTestCase {

    private var allocated: [UnsafeMutablePointer<MIDINoteOn>] = []

    override func tearDown() {
        allocated.forEach { $0.deallocate() }
        allocated = []
        super.tearDown()
    }

    private func capture(capacity: Int) -> MIDIInput.Capture {
        let storage = UnsafeMutablePointer<MIDINoteOn>.allocate(capacity: capacity)
        allocated.append(storage)
        return MIDIInput.Capture(storage: storage, capacity: capacity)
    }

    private func note(_ number: UInt8, at hostTime: UInt64) -> MIDINoteOn {
        MIDINoteOn(hostTime: hostTime, note: number, velocity: 64, channel: 0)
    }

    // MARK: The dedup window

    func testARepeatOfOneNoteInsideTheWindowIsRejected() {
        var c = capture(capacity: 8)
        XCTAssertTrue(c.admit(note(60, at: 1_000), window: 100))
        XCTAssertFalse(c.admit(note(60, at: 1_050), window: 100))
        XCTAssertEqual(c.count, 1, "double delivery must not become two beats")
    }

    /// The boundary is exclusive: exactly one window later is still a repeat.
    func testTheSameNoteOutsideTheWindowIsTaken() {
        var c = capture(capacity: 8)
        XCTAssertTrue(c.admit(note(60, at: 1_000), window: 100))
        XCTAssertFalse(c.admit(note(60, at: 1_100), window: 100), "exactly the window is not past it")
        XCTAssertTrue(c.admit(note(60, at: 1_101), window: 100))
        XCTAssertEqual(c.count, 2)
    }

    /// A chord is not a double delivery, and this player is a keyboard player.
    func testTheWindowIsPerNoteNumber() {
        var c = capture(capacity: 8)
        XCTAssertTrue(c.admit(note(60, at: 1_000), window: 100))
        XCTAssertTrue(c.admit(note(64, at: 1_001), window: 100))
        XCTAssertTrue(c.admit(note(67, at: 1_002), window: 100))
        XCTAssertEqual(c.count, 3, "three notes of one chord, not one note delivered three times")
    }

    // MARK: The take boundary — §7.57's defect, now a rule rather than a race

    func testBeginTakeClearsTheDedupWindow() {
        var c = capture(capacity: 8)
        XCTAssertTrue(c.admit(note(60, at: 1_000), window: 100))
        c.beginTake()
        XCTAssertTrue(c.admit(note(60, at: 1_050), window: 100),
                      "the same note early in a take is not a repeat of one in the take before")
        XCTAssertEqual(c.count, 1)
    }

    func testBeginTakeForgetsThePreviousTakesNotesAndItsLosses() {
        var c = capture(capacity: 2)
        _ = c.admit(note(60, at: 1_000), window: 10)
        _ = c.admit(note(62, at: 2_000), window: 10)
        _ = c.admit(note(64, at: 3_000), window: 10)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.dropped, 1)

        c.beginTake()
        XCTAssertEqual(c.count, 0)
        XCTAssertEqual(c.dropped, 0)
        XCTAssertEqual(c.firstDropHostTime, 0)
        XCTAssertTrue(c.snapshot.isEmpty, "last take's playing is not this take's")
    }

    // MARK: The end of the buffer

    func testNotesPastCapacityAreCountedRatherThanSwallowed() {
        var c = capture(capacity: 3)
        for i in 0..<10 {
            _ = c.admit(note(UInt8(60 + i), at: UInt64(1_000 * (i + 1))), window: 10)
        }
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.dropped, 7,
                       "shape 20: a truncated take has to be able to say it was truncated")
    }

    /// When the loss started, not when it last continued — the first drop is the diagnostic one.
    func testTheKeptDropTimeIsTheFirstOne() {
        var c = capture(capacity: 1)
        _ = c.admit(note(60, at: 1_000), window: 10)
        _ = c.admit(note(62, at: 2_000), window: 10)
        _ = c.admit(note(64, at: 3_000), window: 10)
        XCTAssertEqual(c.dropped, 2)
        XCTAssertEqual(c.firstDropHostTime, 2_000)
    }

    /// The return value is about the dedup window, not about storage. A note the buffer had no room
    /// for is still a note the player played, and the live instrument has to sound it.
    func testANotePastCapacityStillSounds() {
        var c = capture(capacity: 1)
        XCTAssertTrue(c.admit(note(60, at: 1_000), window: 10))
        XCTAssertTrue(c.admit(note(62, at: 2_000), window: 10),
                      "a full buffer must not silence the keyboard")
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.dropped, 1)
    }

    // MARK: The snapshot

    func testTheSnapshotIsWhatWasStoredInTheOrderItArrived() {
        var c = capture(capacity: 8)
        _ = c.admit(note(60, at: 1_000), window: 10)
        _ = c.admit(note(64, at: 2_000), window: 10)
        _ = c.admit(note(67, at: 3_000), window: 10)

        let snapshot = c.snapshot
        XCTAssertEqual(snapshot.map(\.note), [60, 64, 67])
        XCTAssertEqual(snapshot.map(\.hostTime), [1_000, 2_000, 3_000])
    }
}
