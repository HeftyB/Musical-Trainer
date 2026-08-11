import CoreMIDI
import Darwin
import Foundation

/// Diagnostic: opens the same source on BOTH CoreMIDI input APIs at once and reports what
/// each one delivers.
///
/// If the modern UMP port stays silent while the legacy port receives, the fault is in
/// protocol translation and we switch APIs. If both stay silent, nothing is reaching the
/// process and the problem is the device, its mode, or connection.
public enum MIDIMonitor {
    private static var umpCount = 0
    private static var legacyCount = 0

    public static func run(seconds: Double = 20) {
        print("\n\u{001B}[1mMIDI monitor\u{001B}[0m")
        print(String(repeating: "─", count: 60))

        let deviceCount = MIDIGetNumberOfDevices()
        print("\nDevices (\(deviceCount)):")
        for i in 0..<deviceCount {
            let device = MIDIGetDevice(i)
            let offline = intProperty(device, kMIDIPropertyOffline) ?? 0
            print("  [\(i)] \(stringProperty(device, kMIDIPropertyName) ?? "?")"
                + (offline != 0 ? "  \u{001B}[33m(OFFLINE)\u{001B}[0m" : ""))
        }

        let sourceCount = MIDIGetNumberOfSources()
        print("\nSources (\(sourceCount)):")
        guard sourceCount > 0 else {
            print("  \u{001B}[31mNone. macOS sees no MIDI source at all.\u{001B}[0m")
            return
        }
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            print("  [\(i)] \(stringProperty(source, kMIDIPropertyDisplayName) ?? "?")")
        }

        var client = MIDIClientRef()
        guard MIDIClientCreateWithBlock("MIDIMonitor" as CFString, &client, nil) == noErr else {
            print("\n\u{001B}[31mMIDIClientCreateWithBlock failed.\u{001B}[0m")
            return
        }

        // Modern UMP port.
        var umpPort = MIDIPortRef()
        let umpStatus = MIDIInputPortCreateWithProtocol(
            client, "UMP" as CFString, ._1_0, &umpPort
        ) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                let words = Array(packet.words())
                umpCount += 1
                if umpCount <= 12 {
                    let hex = words.map { String(format: "%08X", $0) }.joined(separator: " ")
                    print("  \u{001B}[36m[UMP]\u{001B}[0m ts=\(packet.pointee.timeStamp) words=\(hex)")
                }
            }
        }

        // Legacy MIDIPacketList port — raw MIDI 1.0 bytes, no protocol translation.
        var legacyPort = MIDIPortRef()
        let legacyStatus = MIDIInputPortCreateWithBlock(
            client, "Legacy" as CFString, &legacyPort
        ) { packetList, _ in
            for packet in packetList.unsafeSequence() {
                let bytes = withUnsafeBytes(of: packet.pointee.data) { raw in
                    (0..<Int(packet.pointee.length)).map { raw[$0] }
                }
                legacyCount += 1
                if legacyCount <= 12 {
                    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    print("  \u{001B}[35m[legacy]\u{001B}[0m ts=\(packet.pointee.timeStamp) bytes=\(hex)")
                }
            }
        }

        print("\nPort creation: UMP \(umpStatus == noErr ? "ok" : "FAILED \(umpStatus)"), "
            + "legacy \(legacyStatus == noErr ? "ok" : "FAILED \(legacyStatus)")")

        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let a = MIDIPortConnectSource(umpPort, source, nil)
            let b = MIDIPortConnectSource(legacyPort, source, nil)
            if a != noErr || b != noErr {
                print("  connect source \(i): ump=\(a) legacy=\(b)")
            }
        }

        print("\n\u{001B}[1mPlay some keys now — \(Int(seconds)) seconds.\u{001B}[0m\n")

        // Drive the run loop rather than sleeping, so that any CoreMIDI delivery path
        // depending on it is exercised too.
        //
        // Sliced rather than one blocking wait, so a long watch reports **as it goes**. The
        // whole purpose of a session-length run is finding the moment delivery stops, and
        // neither the summary at the end nor the packet lines above can show a moment — those
        // stop after twelve packets, by design, because a line per note over fifty minutes
        // buries the thing being looked for. The heartbeat is the timeline instead: a silent
        // slice is printed as silent, so the log says when it went quiet (PLAN.md §7.37).
        //
        // Below a minute this is the old "does the keyboard work" check and behaves exactly
        // as it always did.
        let isLongWatch = seconds > 60
        let slice = isLongWatch ? 5.0 : seconds
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var elapsed = 0.0
        var lastUMP = 0
        var lastLegacy = 0

        while elapsed < seconds {
            let step = min(slice, seconds - elapsed)
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            elapsed += step
            guard isLongWatch else { continue }

            let deltaUMP = umpCount - lastUMP
            let deltaLegacy = legacyCount - lastLegacy
            lastUMP = umpCount
            lastLegacy = legacyCount
            let quiet = deltaUMP == 0 && deltaLegacy == 0
            print("  \(clock.string(from: Date()))  +\(deltaUMP) UMP  +\(deltaLegacy) legacy"
                + "  (total \(umpCount) / \(legacyCount))"
                + (quiet ? "  \u{001B}[33m— silent —\u{001B}[0m" : ""))
        }

        print("\nReceived: UMP \(umpCount) packets, legacy \(legacyCount) packets")
        if umpCount == 0 && legacyCount == 0 {
            print("""

            \u{001B}[31mNothing arrived on either API.\u{001B}[0m The problem is upstream of our code:
              • The Launchkey Mini MK2 may be in InControl mode — press the InControl
                button so it goes dark, which returns the keys to plain MIDI.
              • Check it appears in Audio MIDI Setup → MIDI Studio, not greyed out.
              • Quit anything else holding the port exclusively (GarageBand, Ableton).
            """)
        } else if umpCount == 0 {
            print("\n\u{001B}[33mLegacy API works, UMP does not.\u{001B}[0m Switching MIDIInput to the legacy API.")
        } else {
            print("\n\u{001B}[32mUMP delivery works.\u{001B}[0m")
        }

        MIDIPortDispose(umpPort)
        MIDIPortDispose(legacyPort)
        MIDIClientDispose(client)
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var cf: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &cf) == noErr,
              let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func intProperty(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, key, &value) == noErr else { return nil }
        return value
    }
}
