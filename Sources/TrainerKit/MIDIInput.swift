import CoreMIDI
import Darwin
import Foundation
import os

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
    private(set) var sourceNames: [String] = []
    private(set) var skippedSources: [String] = []

    /// Which sources are connected and what has happened to them.
    ///
    /// Guarded because CoreMIDI's notification block runs on its own thread and may mutate this
    /// while a take is connecting sources or reading incidents. Every rule about the contents
    /// lives on the registry, where a test can reach it; the lock is the only part that has to
    /// be here.
    private var registry = MIDISourceRegistry()
    private var registryLock = os_unfair_lock_s()

    private func withRegistry<T>(_ body: (inout MIDISourceRegistry) -> T) -> T {
        os_unfair_lock_lock(&registryLock)
        defer { os_unfair_lock_unlock(&registryLock) }
        return body(&registry)
    }

    /// What happened to the MIDI connection during the take just run, in the order it happened.
    ///
    /// Empty is the normal case and means the connection was uneventful — **not** that nothing
    /// could have gone wrong unobserved. Before the notify block existed this was unanswerable
    /// in principle: a keyboard leaving mid-take produced no note-ons, no note-offs and no
    /// record, which is why two hangs left nothing but the player's description (§7.34, §7.35).
    var incidents: [MIDIIncident] { withRegistry { $0.incidents } }

    /// Called on the CoreMIDI delivery thread for every note-on and note-off, for live
    /// monitoring. Keep the handler real-time-safe — it runs on the MIDI thread. `on` is
    /// false for note-offs (and note-ons with velocity 0).
    var onNoteEvent: ((_ note: UInt8, _ velocity: UInt8, _ on: Bool, _ channel: UInt8) -> Void)?

    /// Last note-on time per note number, for duplicate rejection.
    private var lastNoteOn = [UInt64](repeating: 0, count: 128)
    private let dedupWindow = HostClock.ticks(seconds: 0.003)

    /// Written by CoreMIDI's delivery thread and read from the take thread — including
    /// *during* a take, since the tempo drill scores each round as its silence ends.
    ///
    /// Guarded by an unfair lock rather than relying on the write-data-then-publish-count
    /// pattern. That pattern happens to be safe on x86_64's total store order, but it is a
    /// data race under the language model and would break on Apple Silicon. This is the MIDI
    /// delivery thread, not the audio render thread, so a lock held for a handful of
    /// instructions at a few notes per second is free.
    private var storage: UnsafeMutablePointer<MIDINoteOn>
    private var storageCount = 0
    private var storageLock = os_unfair_lock_s()
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

        // The notify block was `nil` for the life of the project, so the app received no CoreMIDI
        // notifications at all — a keyboard dropping off the bus mid-take was invisible, and the
        // only account of the two hangs is the player's (PLAN.md §7.34, §7.35). It cannot make a
        // hang not happen; it makes the next one leave something behind.
        var status = MIDIClientCreateWithBlock("MusicalTrainer" as CFString, &client) {
            [weak self] notification in
            self?.handle(notification)
        }
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

    /// CoreMIDI telling us the world changed. Runs on CoreMIDI's own thread, not the take
    /// thread and not the render thread, so taking a lock here is fine.
    ///
    /// Only the two messages that can explain a take going silent are acted on. Everything else
    /// — properties changing, IO errors, thru-connection edits — is noise for this purpose, and
    /// recording all of it would bury the signal in a readout nobody then reads.
    private func handle(_ notification: UnsafePointer<MIDINotification>) {
        let now = mach_absolute_time()
        switch notification.pointee.messageID {
        case .msgObjectRemoved:
            // The payload is the larger add/remove struct. Rebinding is safe because the
            // messageID says which struct was sent; reading it for any other message would not be.
            let removal = notification.withMemoryRebound(
                to: MIDIObjectAddRemoveNotification.self, capacity: 1
            ) { $0.pointee }
            guard removal.childType == .source else { return }

            // A departed object usually cannot be queried for its own name, so this is often
            // nil. The unique ID is what matters and it is read the same way.
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(removal.child, kMIDIPropertyUniqueID, &uniqueID)
            let name = Self.name(of: removal.child)
            withRegistry { $0.sourceRemoved(uniqueID, at: now, name: name == "(unnamed)" ? nil : name) }

        case .msgSetupChanged:
            withRegistry { $0.setupChanged(at: now) }

        default:
            break
        }
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
            // Connecting the same source twice would deliver every event twice. The registry
            // owns that rule, and — unlike the set it replaced — it forgets a source that went
            // away, so a keyboard returning under the same unique ID is connected again rather
            // than skipped for the rest of the process's life (§7.35).
            guard withRegistry({ $0.needsConnecting(uniqueID) }) else { continue }
            if MIDIPortConnectSource(port, source, nil) == noErr {
                withRegistry { $0.markConnected(uniqueID) }
            }
        }
    }

    func reset() {
        os_unfair_lock_lock(&storageLock)
        storageCount = 0
        os_unfair_lock_unlock(&storageLock)
        for i in 0..<lastNoteOn.count { lastNoteOn[i] = 0 }
        // Last take's incidents are not this take's. Connections deliberately survive — see
        // `MIDISourceRegistry.beginTake`.
        withRegistry { $0.beginTake() }
    }

    /// A snapshot of everything captured so far. Safe to call mid-take.
    var events: [MIDINoteOn] {
        os_unfair_lock_lock(&storageLock)
        defer { os_unfair_lock_unlock(&storageLock) }
        return (0..<storageCount).map { storage[$0] }
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
                        os_unfair_lock_lock(&storageLock)
                        if storageCount < capacity {
                            storage[storageCount] = MIDINoteOn(hostTime: timeStamp, note: note,
                                                               velocity: velocity, channel: channel)
                            storageCount += 1
                        }
                        os_unfair_lock_unlock(&storageLock)
                        // Outside the lock: monitoring must never be able to block capture.
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
