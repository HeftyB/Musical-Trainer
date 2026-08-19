import Foundation

/// Something that happened to the MIDI connection while a take was running.
///
/// Recorded by the machine, during the take, from a CoreMIDI notification — **not** a judgement
/// made about a take after seeing its numbers. That distinction is the whole reason this is
/// allowed to exist: JOURNAL.md §7.34 rejected a field the player could set afterwards, because a
/// take marked bad in hindsight is post-hoc exclusion however it is worded. An objective event
/// with a host time on it is a different thing, and it is the only way a hang leaves anything
/// behind but a description.
public struct MIDIIncident: Equatable {
    public enum Kind: Equatable {
        /// A source this input was listening to went away.
        case sourceRemoved
        /// The MIDI setup changed — a device added, removed, or reconfigured somewhere.
        case setupChanged
        /// The capture buffer filled and this many note-ons after it were not recorded.
        ///
        /// Not a connection event, and here anyway: it belongs beside the others because it
        /// answers the same question — *what is this take missing, and why* — through the same
        /// list on both surfaces.
        case captureFull(dropped: Int)
    }

    public let kind: Kind
    /// `mach_absolute_time` when it happened, on the same clock as every captured note, so an
    /// incident can be placed against the notes on either side of it.
    public let hostTime: UInt64
    /// The endpoint's display name where one could be read. Absent is normal for a removal —
    /// a departed object often cannot be queried for its own name.
    public let name: String?

    /// Internal on purpose (R4.5): only the capture path creates one. Both front ends read
    /// incidents and render `MIDIIncidentReport`; neither has any business making one up.
    init(kind: Kind, hostTime: UInt64, name: String?) {
        self.kind = kind; self.hostTime = hostTime; self.name = name
    }
}

/// What a take's incidents amount to, in the words both surfaces use.
///
/// **One readout, exhaustive over `Kind`.** The console and the app each counted
/// `kind == .sourceRemoved` and called *everything else* a setup change, by subtraction — so a
/// third kind would have been reported under the second's name, silently and on both surfaces, and
/// nothing would have failed to compile. A decision made while printing is a decision no suite can
/// reach (`LESSONS.md` shape 1, and §7.28 extracted `TakeAxis.mixed(in:)` for the same reason).
///
/// The consequence line depends on which kinds occurred, because they do not have the same one: a
/// source that went away means notes were **never delivered**, while a full buffer means they were
/// delivered and **not recorded**. Reporting both as "may be missing playing" would understate the
/// second, which is the take's own numbers being computed over a truncated series.
public struct MIDIIncidentReport: Equatable {
    /// One line per kind that occurred, in a fixed order.
    public let lines: [String]
    /// What it means for this take.
    public let consequence: String

    /// `nil` when nothing happened, so a caller cannot render an empty warning.
    public static func of(_ incidents: [MIDIIncident]) -> MIDIIncidentReport? {
        guard !incidents.isEmpty else { return nil }

        var removals: [MIDIIncident] = []
        var changes = 0
        var dropped = 0
        // Exhaustive on purpose: a kind added later stops compiling here rather than being
        // absorbed into a neighbour's count.
        for incident in incidents {
            switch incident.kind {
            case .sourceRemoved:          removals.append(incident)
            case .setupChanged:           changes += 1
            case .captureFull(let count): dropped += count
            }
        }

        var lines: [String] = []
        if !removals.isEmpty {
            let named = removals.compactMap(\.name).first
            lines.append(count(removals.count, "source removal", "source removals")
                       + (named.map { ", including \($0)" } ?? ""))
        }
        if changes > 0 { lines.append(count(changes, "setup change", "setup changes")) }
        if dropped > 0 {
            lines.append(count(dropped, "note not recorded", "notes not recorded")
                       + " — the capture buffer was full")
        }

        var consequence = ""
        if !removals.isEmpty || changes > 0 {
            consequence = "Notes played while a source was gone were never delivered, so this "
                        + "take may be missing playing that happened. "
        }
        if dropped > 0 {
            consequence += "Notes after the buffer filled were played and heard but not stored, "
                         + "so every number for this take is computed over a truncated take. "
        }
        return MIDIIncidentReport(
            lines: lines,
            consequence: consequence + "Nothing has been excluded — this is a record, not a "
                       + "verdict.")
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}

/// Which MIDI sources are connected, and what has happened to them.
///
/// Split out of `MIDIInput` because every decision here used to sit inside functions that talk to
/// CoreMIDI, where no test can reach them — `LESSONS.md` shape 1, whose six instances are all
/// logic that shipped untested because the only path to it needed hardware. What is left in
/// `MIDIInput` is the CoreMIDI conversation; what is here is every rule about it.
///
/// Deliberately over `Int32` rather than `MIDIUniqueID`. They are the same type — `MIDIUniqueID`
/// is a typealias — but spelling it this way means neither this file nor its tests import
/// CoreMIDI, so the rules can be exercised on any machine.
struct MIDISourceRegistry {

    /// Unique IDs currently believed to be connected.
    private(set) var connected: Set<Int32> = []

    /// What has happened since `beginTake`. Ordered as it arrived.
    private(set) var incidents: [MIDIIncident] = []

    init() {}

    // MARK: - Connecting

    /// Whether a source still needs connecting.
    ///
    /// A unique ID of 0 means CoreMIDI would not give us one, which is not an identity — two
    /// such sources are not the same source. They are always connected and never remembered,
    /// because remembering an identity that is not unique would suppress a real second device.
    func needsConnecting(_ uniqueID: Int32) -> Bool {
        uniqueID == 0 || !connected.contains(uniqueID)
    }

    /// Record a successful connection. A zero ID is not remembered — see `needsConnecting`.
    mutating func markConnected(_ uniqueID: Int32) {
        guard uniqueID != 0 else { return }
        connected.insert(uniqueID)
    }

    // MARK: - Losing a source

    /// Forget a source that went away, so the next take reconnects it.
    ///
    /// **This is the defect this type exists for.** The set was insert-only, so a keyboard that
    /// dropped off the bus and returned under the same unique ID — which CoreMIDI preserves per
    /// device — was skipped by every later connect attempt and stayed dead until the app was
    /// relaunched. Being *told* the device left is worth nothing while the reconnect path
    /// refuses to run (JOURNAL.md §7.35).
    mutating func sourceRemoved(_ uniqueID: Int32, at hostTime: UInt64, name: String?) {
        connected.remove(uniqueID)
        incidents.append(MIDIIncident(kind: .sourceRemoved, hostTime: hostTime, name: name))
    }

    /// The setup changed in some way CoreMIDI did not attribute to one object.
    ///
    /// Nothing is forgotten here: a setup change is not evidence that any particular source went
    /// away, and dropping the whole set would reconnect sources already connected, which delivers
    /// every event twice. It is recorded because it is the coarser signal, and on a take that
    /// went wrong the coarse signal may be all there is.
    mutating func setupChanged(at hostTime: UInt64) {
        incidents.append(MIDIIncident(kind: .setupChanged, hostTime: hostTime, name: nil))
    }

    // MARK: - Take boundaries

    /// Start a take: clear what happened during the previous one.
    ///
    /// Connections are **not** cleared. They outlive a take by design — the CoreMIDI client and
    /// port are held for the process lifetime, and dropping the set here would reconnect every
    /// source before every take, which is exactly the double delivery `needsConnecting` exists
    /// to prevent.
    mutating func beginTake() {
        incidents.removeAll()
    }

    /// Whether anything happened worth telling the player about.
    var isClean: Bool { incidents.isEmpty }
}
