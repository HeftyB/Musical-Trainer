import CoreMIDI
import Darwin
import Foundation

struct MIDINoteOn {
    /// `mach_absolute_time` captured by CoreMIDI at the driver level — the whole reason
    /// we can measure anything. Sub-millisecond, and not subject to our own scheduling.
    let hostTime: UInt64
    let note: UInt8
    let velocity: UInt8
    /// 0-based MIDI channel. The Launchkey puts its keys on channel 0 and its pads on
    /// channel 9 (channel 10, the drum channel), which is what lets the form drill tell a
    /// phrase mark apart from ordinary playing with no configuration.
    let channel: UInt8

    /// True for a pad hit on the drum channel.
    var isPad: Bool { channel == 9 }
}

final class MIDIInput {
    /// One CoreMIDI client for the whole process, created on first use and never disposed.
    ///
    /// `MIDIServer` is an on-demand daemon: when the last client in the *system* goes away it
    /// exits. A long-lived process that disposes its client and later creates another can be
    /// left holding a connection to a server that has since exited, and the next
    /// `MIDIClientCreateWithBlock` fails with paramErr (−50). That is exactly what the app
    /// hit — the first take worked, the user spent a minute on the rating and results
    /// screens while the server exited, and the second take could not open MIDI at all. The
    /// CLI never saw it because each invocation is a fresh process.
    ///
    /// Holding one client for the process lifetime avoids the reconnect path entirely, and
    /// is how CoreMIDI is meant to be used: one client per app, ports as needed.
    static let shared = MIDIInput()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var isConfigured = false
    private var connectedSources = Set<MIDIUniqueID>()
    private(set) var sourceNames: [String] = []
    private(set) var skippedSources: [String] = []

    /// Called on the CoreMIDI delivery thread for every note-on and note-off, for live
    /// monitoring. Keep the handler real-time-safe — it runs on the MIDI thread. `on` is
    /// false for note-offs (and note-ons with velocity 0).
    var onNoteEvent: ((_ note: UInt8, _ velocity: UInt8, _ on: Bool, _ channel: UInt8) -> Void)?

    /// Last note-on time per note number, for duplicate rejection.
    private var lastNoteOn = [UInt64](repeating: 0, count: 128)
    private let dedupWindow = HostClock.ticks(seconds: 0.003)

    /// Written only by CoreMIDI's single delivery thread and read only after `stop()`,
    /// so no locking is required.
    private var storage: UnsafeMutablePointer<MIDINoteOn>
    private var storageCount = 0
    private let capacity: Int

    init(capacity: Int = 8192) {
        self.capacity = capacity
        self.storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    /// The shared input, ready to receive. Safe to call before every take.
    static func started() throws -> MIDIInput {
        try shared.begin()
        return shared
    }

    /// Prepare for a take: open the client and port if needed, pick up any newly attached
    /// devices, and clear anything captured previously.
    func begin() throws {
        try configureIfNeeded()
        connectSources()
        reset()
        guard !sourceNames.isEmpty else {
            if skippedSources.isEmpty {
                throw SpikeError("No MIDI sources found. Is the Launchkey plugged in?")
            }
            throw SpikeError("Only control-surface MIDI ports found: \(skippedSources.joined(separator: ", "))")
        }
    }

    /// Finish a take. The client and port stay open on purpose — see `shared`.
    func end() {
        onNoteEvent = nil
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        var status = MIDIClientCreateWithBlock("MusicalTrainer" as CFString, &client, nil)
        guard status == noErr else {
            throw SpikeError("""
                Could not open CoreMIDI (error \(status)). Unplug and replug the keyboard, or \
                restart the app.
                """)
        }

        status = MIDIInputPortCreateWithProtocol(
            client, "MusicalTrainer In" as CFString, ._1_0, &port
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else {
            MIDIClientDispose(client)
            client = MIDIClientRef()
            throw SpikeError("MIDIInputPortCreateWithProtocol failed: \(status)")
        }
        isConfigured = true
    }

    /// Connect any source we are not already listening to. Re-run before each take so a
    /// keyboard plugged in after launch is picked up without restarting.
    private func connectSources() {
        sourceNames.removeAll()
        skippedSources.removeAll()

        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            let name = Self.name(of: source)
            // Skip control-surface ports. The Launchkey exposes both "LK Mini MIDI" and
            // "LK Mini InControl"; the latter carries DAW-integration traffic and can
            // echo the same note, which would give every beat two note-ons and cause the
            // pairing step to discard it.
            if name.lowercased().contains("incontrol") {
                skippedSources.append(name)
                continue
            }
            sourceNames.append(name)

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            // Connecting the same source twice would deliver every event twice.
            if uniqueID != 0, connectedSources.contains(uniqueID) { continue }
            if MIDIPortConnectSource(port, source, nil) == noErr, uniqueID != 0 {
                connectedSources.insert(uniqueID)
            }
        }
    }

    func reset() {
        storageCount = 0
        for i in 0..<lastNoteOn.count { lastNoteOn[i] = 0 }
    }

    var events: [MIDINoteOn] {
        (0..<storageCount).map { storage[$0] }
    }

    /// Walk the packets in place via CoreMIDI's own sequence helper.
    ///
    /// Do not reach for `eventList.pointee.packet`: loading `.pointee` copies the struct
    /// to the stack, and a pointer taken into that temporary dangles the moment the
    /// expression ends. `unsafeSequence()` iterates the real buffer.
    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        for packet in eventList.unsafeSequence() {
            handle(packet)
        }
    }

    private func handle(_ packet: UnsafePointer<MIDIEventPacket>) {
        // A zero timestamp means "now" in CoreMIDI's contract.
        let timeStamp = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
        let words = Array(packet.words())

        var i = 0
        while i < words.count {
            let word = words[i]
            let messageType = (word >> 28) & 0xF

            if messageType == 0x2 {                       // MIDI 1.0 Channel Voice
                let status = (word >> 20) & 0xF
                let channel = UInt8((word >> 16) & 0xF)
                let note = UInt8((word >> 8) & 0x7F)
                let velocity = UInt8(word & 0x7F)
                // Status 0x9 with velocity 0 is a note-off by convention.
                if status == 0x9, velocity > 0 {
                    // Reject a repeat of the same note within the dedup window. No player
                    // retriggers one note in 3 ms, so this can only be double delivery.
                    let previous = lastNoteOn[Int(note)]
                    if previous == 0 || timeStamp &- previous > dedupWindow {
                        lastNoteOn[Int(note)] = timeStamp
                        if storageCount < capacity {
                            storage[storageCount] = MIDINoteOn(hostTime: timeStamp, note: note,
                                                               velocity: velocity, channel: channel)
                            storageCount += 1
                        }
                        onNoteEvent?(note, velocity, true, channel)
                    }
                } else if status == 0x8 || (status == 0x9 && velocity == 0) {
                    onNoteEvent?(note, 0, false, channel)
                }
            }
            i += Self.wordCount(forMessageType: messageType)
        }
    }

    /// UMP packet sizes by message type, per the MIDI 2.0 spec.
    private static func wordCount(forMessageType t: UInt32) -> Int {
        switch t {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC:                return 3
        default:                      return 4
        }
    }

    private static func name(of object: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &cf) == noErr,
              let name = cf?.takeRetainedValue() else { return "(unnamed)" }
        return name as String
    }
}

public struct SpikeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
