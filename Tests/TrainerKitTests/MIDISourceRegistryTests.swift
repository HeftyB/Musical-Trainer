import XCTest
@testable import TrainerKit

/// The rules about which MIDI sources are connected, and what is remembered about them.
///
/// These used to live inside `MIDIInput.connectSources()`, which talks to CoreMIDI and therefore
/// cannot be reached by any test — `LESSONS.md` shape 1. The connection set being insert-only was
/// found by reading, not by a failing test, because no test could have run (PLAN.md §7.35).
final class MIDISourceRegistryTests: XCTestCase {

    /// The defect itself: a device that returns under the same unique ID must be reconnected.
    ///
    /// Deleting the `connected.remove` in `sourceRemoved` fails this, which is the whole point —
    /// with the set insert-only the keyboard stayed dead until the app was relaunched.
    func testASourceThatComesBackUnderTheSameIdIsConnectedAgain() {
        var registry = MIDISourceRegistry()
        registry.markConnected(77)
        XCTAssertFalse(registry.needsConnecting(77), "already connected, do not connect twice")

        registry.sourceRemoved(77, at: 1_000, name: "LK Mini MIDI")

        XCTAssertTrue(registry.needsConnecting(77),
                      "a source that went away must be reconnected when it returns")
    }

    /// Connecting one source twice delivers every note twice, which the pairing step then
    /// discards — so the guard against it has to survive everything else here.
    func testAConnectedSourceIsNotConnectedTwice() {
        var registry = MIDISourceRegistry()
        registry.markConnected(5)
        registry.markConnected(5)
        XCTAssertEqual(registry.connected, [5])
        XCTAssertFalse(registry.needsConnecting(5))
    }

    /// A unique ID of 0 is CoreMIDI declining to give one, not an identity. Two sources without
    /// an ID are not the same source, so neither may be suppressed by the other.
    func testSourcesWithoutAUniqueIdAreNeverSuppressed() {
        var registry = MIDISourceRegistry()
        registry.markConnected(0)

        XCTAssertTrue(registry.needsConnecting(0), "a missing id is not an identity to match on")
        XCTAssertFalse(registry.connected.contains(0), "and it is not remembered")
    }

    /// A setup change must not drop the connection set: it is not evidence that any particular
    /// source left, and reconnecting everything delivers every event twice.
    func testASetupChangeIsRecordedButForgetsNothing() {
        var registry = MIDISourceRegistry()
        registry.markConnected(9)

        registry.setupChanged(at: 4_242)

        XCTAssertEqual(registry.connected, [9], "a setup change is not a removal")
        XCTAssertFalse(registry.needsConnecting(9))
        XCTAssertEqual(registry.incidents,
                       [MIDIIncident(kind: .setupChanged, hostTime: 4_242, name: nil)])
    }

    /// Incidents belong to the take they happened in, or the next take inherits an explanation
    /// for something that did not happen to it.
    func testIncidentsAreClearedAtTheStartOfATakeButConnectionsAreNot() {
        var registry = MIDISourceRegistry()
        registry.markConnected(3)
        registry.setupChanged(at: 1)
        XCTAssertFalse(registry.isClean)

        registry.beginTake()

        XCTAssertTrue(registry.isClean, "last take's incidents are not this take's")
        XCTAssertEqual(registry.connected, [3],
                       "connections outlive a take — the client and port are never disposed")
    }

    /// Order and host times are the point: an incident has to be placeable against the notes on
    /// either side of it, which is why it carries the same clock they do.
    func testIncidentsKeepTheirOrderAndTheirHostTimes() {
        var registry = MIDISourceRegistry()
        registry.markConnected(1)
        registry.sourceRemoved(1, at: 100, name: "LK Mini MIDI")
        registry.setupChanged(at: 250)

        XCTAssertEqual(registry.incidents, [
            MIDIIncident(kind: .sourceRemoved, hostTime: 100, name: "LK Mini MIDI"),
            MIDIIncident(kind: .setupChanged, hostTime: 250, name: nil),
        ])
    }

    /// A take with nothing wrong reports nothing, so the readout stays silent unless it has
    /// something to say.
    func testAnUneventfulTakeIsClean() {
        var registry = MIDISourceRegistry()
        registry.markConnected(1)
        registry.beginTake()
        XCTAssertTrue(registry.isClean)
        XCTAssertTrue(registry.incidents.isEmpty)
    }
}
