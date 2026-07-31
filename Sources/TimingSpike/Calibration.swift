import Foundation

/// Persisted per-output-device calibration.
///
/// The quantity every measurement needs is `L_midi + L_out` — MIDI transport latency plus
/// output latency — because asynchrony reduces to
/// `(midiHostTime − clickEmitHostTime) − (L_midi + L_out)`. The two-path procedure
/// (PLAN.md §4.2) measures that sum directly, so the two terms never need separating.
///
/// Measuring it costs ~2 minutes of playing, which is too much to repeat for every pair of
/// headphones. `L_midi` is a property of the keyboard rather than the output device, so one
/// full run establishes a reference and any other device needs only a 15-second loopback:
///
///     C(dev) = C(ref) + (RT(dev) − RT(ref)) + air(ref) − air(dev)
struct Calibration: Codable {
    struct Device: Codable {
        /// Human-readable label. The dictionary key is the device *identity* (name plus
        /// data source); this is what to show.
        var displayName: String
        var roundTripMs: Double
        var roundTripSD: Double
        /// Acoustic travel from this device's transducer to the microphone. Cancels out of
        /// the derivation, so it must be recorded per device rather than assumed.
        var airPathMs: Double
        var sampleRate: Double
        var bufferFrames: UInt32
        var measuredAt: Date
        /// Two-path residual, present only when a full calibration ran on this device.
        /// Always preferred over derivation — it carries no air-path assumption.
        var residualMs: Double?
        var residualSD: Double?
    }

    var devices: [String: Device] = [:]
    /// Device whose full two-path run anchors every derived constant.
    var referenceDevice: String?
    var midiSource: String?
    var updatedAt: Date = Date()

    enum Source {
        case measured           // full two-path run on this device
        case derived(from: String)
    }

    /// Record a device measurement, preserving an existing directly-measured residual.
    ///
    /// This is the guard that makes a quick (loopback-only) calibration safe: it carries
    /// residual=nil, and without this merge it would overwrite and destroy a residual a
    /// full calibration had already established for the same identity. A full calibration
    /// passes its own residual and simply replaces.
    mutating func record(identity: String, _ device: Device) {
        var merged = device
        if merged.residualMs == nil, let existing = devices[identity]?.residualMs {
            merged.residualMs = existing
            merged.residualSD = devices[identity]?.residualSD
        }
        devices[identity] = merged
    }

    /// `L_midi + L_out` in milliseconds for the given output device.
    func constant(for name: String) -> (value: Double, source: Source, sd: Double?)? {
        guard let device = devices[name] else { return nil }

        if let residual = device.residualMs {
            return (residual, .measured, device.residualSD)
        }
        guard let referenceName = referenceDevice,
              let reference = devices[referenceName],
              let referenceResidual = reference.residualMs else { return nil }

        let value = referenceResidual
            + (device.roundTripMs - reference.roundTripMs)
            + reference.airPathMs - device.airPathMs
        return (value, .derived(from: referenceName), reference.residualSD)
    }

    // MARK: - Persistence

    static var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicalTrainer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("calibration.json")
    }

    static func load() -> Calibration {
        guard let data = try? Data(contentsOf: storeURL) else { return Calibration() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Calibration.self, from: data) {
            return decoded
        }
        // A present-but-undecodable file is almost always an older schema. Say so rather
        // than silently starting empty — silent calibration loss is the bug class this
        // whole model exists to avoid. The next save writes a clean current-format file.
        FileHandle.standardError.write(Data(
            "Note: existing calibration is in an older format and will be rewritten on next calibration.\n".utf8))
        return Calibration()
    }

    func save() throws {
        var copy = self
        copy.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(copy).write(to: Self.storeURL, options: .atomic)
    }

    /// Acoustic travel time for a distance in centimetres, at 343 m/s.
    static func airPathMs(centimetres: Double) -> Double { centimetres / 34.3 }
}
