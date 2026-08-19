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

    /// What happened during the take just run, in the order it happened.
    ///
    /// Empty is the normal case and means the connection was uneventful — **not** that nothing
    /// could have gone wrong unobserved. Before the notify block existed this was unanswerable
    /// in principle: a keyboard leaving mid-take produced no note-ons, no note-offs and no
    /// record, which is why two hangs left nothing but the player's description (§7.34, §7.35).
    ///
    /// The capture's own incident is merged here rather than reported separately, so the surfaces
    /// have one list to render and one place a new kind can appear. **The two locks are taken in
    /// sequence and never nested**, which is why the overflow is counted inside `Capture` and
    /// turned into an incident at read time instead of being handed to the registry from inside the
    /// delivery thread's critical section.
    var incidents: [MIDIIncident] {
        var all = withRegistry { $0.incidents }
        if let overflow = captureOverflowIncident { all.append(overflow) }
        return all.sorted { $0.hostTime < $1.hostTime }
    }

    private var captureOverflowIncident: MIDIIncident? {
        withCapture { capture -> MIDIIncident? in
            guard capture.dropped > 0 else { return nil }
            return MIDIIncident(kind: .captureFull(dropped: capture.dropped),
                                hostTime: capture.firstDropHostTime, name: nil)
        }
    }

    typealias NoteHandler = (_ note: UInt8, _ velocity: UInt8, _ on: Bool, _ channel: UInt8) -> Void

    /// Called on the CoreMIDI delivery thread for every note-on and note-off, for live
    /// monitoring. Keep the handler real-time-safe — it runs on the MIDI thread. `on` is
    /// false for note-offs (and note-ons with velocity 0).
    ///
    /// **Guarded, for the reason the note storage below is.** This is written on the take thread
    /// — `runJam` sets it, `end()` clears it — and read on CoreMIDI's delivery thread, and a
    /// closure property is not a word: assigning one releases the old box while a reader may be
    /// retaining it. The comment under `storage` rejects the unguarded pattern on the grounds
    /// that it is *"a data race under the language model"* which happens to survive x86_64's
    /// total store order; that argument does not even get that far here, because a refcount
    /// underflow is a use-after-free on any architecture.
    ///
    /// The handler is **copied under the lock and called outside it**, which matters twice: a
    /// monitoring handler must never be able to block capture, and holding a strong copy keeps
    /// the `GroovePlayer` it captures alive for the duration of the call even if the take thread
    /// tears down mid-packet.
    var onNoteEvent: NoteHandler? {
        get { withHandlerLock { handler } }
        set { withHandlerLock { handler = newValue } }
    }

    private var handler: NoteHandler?
    private var handlerLock = os_unfair_lock_s()

    private func withHandlerLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&handlerLock)
        defer { os_unfair_lock_unlock(&handlerLock) }
        return body()
    }

    /// Everything CoreMIDI's delivery thread touches. Reachable only through `withCapture`.
    ///
    /// **A struct rather than five properties beside a lock, because proximity is not enforcement.**
    /// The five were correct, adjacent and documented — and `lastNoteOn` was outside the lock for
    /// the life of the project anyway, through a review that fixed the field next to it for exactly
    /// that reason (§7.57, `LESSONS.md` shape 21). What a comment could not hold, the compiler can:
    /// nothing in here is reachable without the lock, and the next field added is guarded by having
    /// been added to it.
    ///
    /// It also removes the second way that defect could be spelled. Admitting a note and storing it
    /// used to be two statements with a lock boundary available to fall between them; `admit` is one
    /// call, so "this note passed the dedup window" and "this note is in the buffer" cannot come
    /// apart.
    ///
    /// Guarded by an unfair lock rather than by the write-data-then-publish-count pattern. That
    /// pattern happens to be safe on x86_64's total store order, but it is a data race under the
    /// language model and would break on Apple Silicon. This is the MIDI delivery thread, not the
    /// audio render thread, so a lock held for a handful of instructions at a few notes per second
    /// is free — see `snapshot` for the one call where that description does not hold.
    ///
    /// Internal rather than private, so `CaptureTests` can hand it a capacity of three. The guard is
    /// not weakened by that: `capture` below stays private, so the only way to reach *this
    /// instance's* state is still `withCapture`. What becomes reachable is the type, and with it the
    /// two paths this project has only ever been able to reason about in prose — the end of the
    /// buffer, and what a take boundary does to the dedup window.
    struct Capture {
        /// Preallocated, so the delivery thread never allocates. Sized by `captureCapacity`.
        let storage: UnsafeMutablePointer<MIDINoteOn>
        let capacity: Int
        private(set) var count = 0

        /// Last note-on time per note number, for duplicate rejection.
        private var lastNoteOn = [UInt64](repeating: 0, count: 128)

        /// Note-ons this take could not record, and when the first one arrived.
        ///
        /// A preallocated buffer has an end, and the code simply stopped writing at it. A take that
        /// overran lost the rest of its playing with no incident, no warning and no difference from
        /// a take where the player stopped — `LESSONS.md` shape 20, the error path discarding
        /// exactly the data that says something went wrong.
        private(set) var dropped = 0
        private(set) var firstDropHostTime: UInt64 = 0

        /// Written out rather than left to the memberwise initializer, which the `private` fields
        /// above make private to `Capture` itself.
        init(storage: UnsafeMutablePointer<MIDINoteOn>, capacity: Int) {
            self.storage = storage
            self.capacity = capacity
        }

        /// Take this note unless it repeats one inside `window`.
        ///
        /// No player retriggers one note in 3 ms, so a repeat inside the window can only be double
        /// delivery. The window is per note number, because a chord is not a double delivery.
        ///
        /// A note arriving past the end of the buffer is **counted** rather than swallowed: numbers
        /// computed from a truncated series are a fact about the buffer rather than about the
        /// player, and a take has to be able to say that happened.
        ///
        /// - Returns: whether the note passed the dedup window, which is **not** the same as
        ///   whether it was stored. The caller sonifies on this, and a note the buffer was too full
        ///   to keep is still a note the player played and should hear. `dropped` is what says
        ///   whether it was kept.
        mutating func admit(_ event: MIDINoteOn, window: UInt64) -> Bool {
            let previous = lastNoteOn[Int(event.note)]
            guard previous == 0 || event.hostTime &- previous > window else { return false }
            lastNoteOn[Int(event.note)] = event.hostTime
            if count < capacity {
                storage[count] = event
                count += 1
            } else {
                if dropped == 0 { firstDropHostTime = event.hostTime }
                dropped += 1
            }
            return true
        }

        /// Forget the previous take. Everything in here is per-take, the dedup window included.
        mutating func beginTake() {
            count = 0
            dropped = 0
            firstDropHostTime = 0
            for i in 0..<lastNoteOn.count { lastNoteOn[i] = 0 }
        }

        /// A copy of what has been captured so far.
        ///
        /// **The one call that holds the lock for longer than a handful of instructions**, which is
        /// worth saying where a reader meets it rather than leaving the claim above to cover a path
        /// it does not describe. It allocates and copies `count` elements — the notes actually
        /// played, not the 32,768 the buffer could hold — so a dense take is tens of kilobytes and
        /// tens of microseconds. That is charged to CoreMIDI's delivery thread, never the render
        /// thread, and it is paid a handful of times per take rather than per packet.
        var snapshot: [MIDINoteOn] { (0..<count).map { storage[$0] } }
    }

    private var capture: Capture
    private var captureLock = os_unfair_lock_s()

    /// The only way to reach capture state. Same shape as `withRegistry` and `withHandlerLock`.
    private func withCapture<T>(_ body: (inout Capture) -> T) -> T {
        os_unfair_lock_lock(&captureLock)
        defer { os_unfair_lock_unlock(&captureLock) }
        return body(&capture)
    }

    private let dedupWindow = HostClock.ticks(seconds: 0.003)

    /// How many note-ons a take may record.
    ///
    /// **Derived from the longest take the engine will run**, rather than picked. `JamConfig`
    /// caps a take at `TrainerEngine.maximumTakeBars` bars of four beats, and this divided by
    /// those beats is how many note-ons per beat the buffer can hold for the whole of one —
    /// `notesPerBeatCovered`, which `CaptureCapacityTests` requires to stay above a dense
    /// keyboard player's rate. Four-note chords on sixteenths is 16 a beat, and this player is a
    /// keyboard player.
    ///
    /// The old 8192 covered barely 4 a beat over a maximum-length take. The cost of the new
    /// number is half a megabyte, held once for the process lifetime.
    static let captureCapacity = 32_768

    /// Note-ons per beat the buffer covers across the longest legal take.
    static var notesPerBeatCovered: Double {
        Double(captureCapacity) / Double(TrainerEngine.maximumTakeBars * 4)
    }

    init(capacity: Int = MIDIInput.captureCapacity) {
        capture = Capture(storage: .allocate(capacity: capacity), capacity: capacity)
    }

    deinit { capture.storage.deallocate() }

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
        // only account of the two hangs is the player's (JOURNAL.md §7.34, §7.35). It cannot
        // make a
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
        withCapture { $0.beginTake() }
        // Last take's incidents are not this take's. Connections deliberately survive — see
        // `MIDISourceRegistry.beginTake`.
        withRegistry { $0.beginTake() }
    }

    /// A snapshot of everything captured so far. Safe to call mid-take.
    ///
    /// Costs an allocation and a copy under the lock — see `Capture.snapshot`. Callers wanting two
    /// things from one take's capture should take one snapshot and ask it twice.
    var events: [MIDINoteOn] { withCapture { $0.snapshot } }

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
        // One locked copy for the whole packet, strong for as long as the calls below take. See
        // `onNoteEvent`: the take thread may clear it at any point, and a handler retained here
        // keeps what it captured alive rather than being torn out from under a call in progress.
        let monitor = onNoteEvent

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
                    let event = MIDINoteOn(hostTime: timeStamp, note: note,
                                           velocity: velocity, channel: channel)
                    // The dedup window and the append are one call, so no lock boundary can fall
                    // between them — see `Capture`.
                    if withCapture({ $0.admit(event, window: dedupWindow) }) {
                        // Outside the lock: monitoring must never be able to block capture.
                        monitor?(note, velocity, true, channel)
                    }
                } else if status == 0x8 || (status == 0x9 && velocity == 0) {
                    monitor?(note, 0, false, channel)
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
