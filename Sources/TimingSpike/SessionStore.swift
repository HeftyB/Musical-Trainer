import Foundation
import TimingCore

/// A recorded jam, persisted to disk.
///
/// Stores the raw taps and grid parameters, not just the summary, so the M5 review can
/// re-analyze and plot a session without the player having to record it again. The summary
/// fields are duplicated for cheap listing.
struct JamSession: Codable {
    let date: Date
    let bpm: Double
    let device: String
    let calibrationConstantMs: Double?
    let calibrationSource: String?
    let grooveName: String
    let bars: Int
    let subdivisions: Int

    /// Condition label for this take ("relaxed", "focused", "flow", …), lowercased. Optional
    /// so takes recorded before tagging existed still decode.
    let tag: String?
    /// Self-rated feel, 1–5. Recorded *before* the numbers are shown, so the rating is an
    /// honest read of the experience and not an echo of the measurement. Lets us ask whether
    /// the player's sense of a good take actually predicts good timing.
    let feelRating: Int?

    // Raw material for re-analysis (all on the session's seconds-since-epoch timeline).
    let gridStartTime: Double
    let tapTimes: [Double]
    let tapVelocities: [Int?]

    // Summary snapshot.
    let matchedCount: Int
    let extraCount: Int
    let missedCount: Int
    let meanAsynchronyMs: Double
    let sdAsynchronyMs: Double
    let lag1Autocorrelation: Double?
    let driftMsPerBeat: Double?
    let headline: String

    /// Rebuild the taps and grid for re-analysis in the review.
    func reconstruct() -> (taps: [Tap], grid: Grid) {
        let taps = zip(tapTimes, tapVelocities).map { Tap(time: $0, velocity: $1) }
        return (taps, Grid(startTime: gridStartTime, bpm: bpm, subdivisions: subdivisions))
    }
}

enum SessionStore {
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicalTrainer/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func save(_ session: JamSession) throws -> URL {
        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: session.date)
        let url = directory.appendingPathComponent("jam-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAll() -> [JamSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(JamSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
    }
}

private extension ISO8601DateFormatter {
    /// Colons are illegal in filenames on some volumes; use a compact, sortable stamp.
    static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
