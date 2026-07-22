import CoreAudio
import Foundation

enum AudioDevices {
    struct Info {
        let id: AudioDeviceID
        let name: String
        let sampleRate: Double
        let transport: String
        let isBluetooth: Bool
        /// Reported hardware latency in frames. Treated as advisory only — these values
        /// are frequently incomplete, which is why we measure empirically instead.
        let reportedLatencyFrames: UInt32
        let safetyOffsetFrames: UInt32
        let bufferFrameSize: UInt32
    }

    static func defaultDevice(input: Bool) -> Info? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != 0 else { return nil }
        _ = selector
        return info(for: deviceID, input: input)
    }

    static func info(for id: AudioDeviceID, input: Bool) -> Info {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let transport = property(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32.self) ?? 0
        return Info(
            id: id,
            name: stringProperty(id, kAudioObjectPropertyName) ?? "(unknown)",
            sampleRate: property(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Double.self) ?? 0,
            transport: fourCC(transport),
            isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                      || transport == kAudioDeviceTransportTypeBluetoothLE,
            reportedLatencyFrames: property(id, kAudioDevicePropertyLatency, scope, UInt32.self) ?? 0,
            safetyOffsetFrames: property(id, kAudioDevicePropertySafetyOffset, scope, UInt32.self) ?? 0,
            bufferFrameSize: property(id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, UInt32.self) ?? 0)
    }

    /// Request a smaller hardware buffer. Best-effort: the device may clamp or refuse,
    /// and the spike works fine either way — it only changes latency, not correctness.
    @discardableResult
    static func setBufferFrameSize(_ frames: UInt32, on id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = frames
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func property<T>(_ id: AudioDeviceID,
                                    _ selector: AudioObjectPropertySelector,
                                    _ scope: AudioObjectPropertyScope,
                                    _ type: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, out) == noErr else { return nil }
        return out.pointee
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii) ?? "????"
        return s.trimmingCharacters(in: .whitespaces)
    }
}
