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

/// A recorded form drill. Kept separate from `JamSession` because it measures a different
/// thing — where you are in the music, not how you place a beat — and pooling the two would
/// be meaningless.
struct FormSession: Codable {
    let date: Date
    let bpm: Double
    let bars: Int
    let phraseBars: Int
    let level: Int
    let feelRating: Int?

    let gridStartTime: Double
    let markTimes: [Double]

    let phrasesAvailable: Int
    let marksPlaced: Int
    let onFormCount: Int
    let tightCount: Int
    let meanAbsFormErrorBars: Double
    let phaseErrorMeanMs: Double
    let phaseErrorSDms: Double
    let slipBarsPerPhrase: Double?
    let missedPhrases: [Int]
    let headline: String
}

/// A recorded continuation drill. Separate again: it is the only session type that yields a
/// clock/motor split, because it is the only one with unpaced playing in it.
struct DropoutSession: Codable {
    let date: Date
    let bpm: Double
    let pacedBars: Int
    let silentBars: Int
    let cycles: Int
    let feelRating: Int?

    let gridStartTime: Double
    let tapTimes: [Double]

    let pacedSDms: Double
    let unpacedIntervalSDms: Double
    let clockSDms: Double?
    let motorSDms: Double?
    let modelHolds: Bool
    let reentryErrorMeanMs: Double
    let reentryErrorSDms: Double
    let headline: String

    // Cached summaries. Optional so sessions written before these existed still decode —
    // and unnecessary anyway, because `reconstruct()` can recompute everything from the
    // raw taps below.
    let tempoBiasBpm: Double?
    let playedBpm: Double?
    let splitIsReliable: Bool?
    let discardedTrials: Int?

    /// Rebuild the inputs to the analysis, so a stored drill can be re-analysed with the
    /// current logic. The stored summary is only a cache; this is the source of truth.
    ///
    /// Everything needed is here — tempo, cycle shape, grid origin, and every tap — which is
    /// what lets an analysis fix (say, discarding silences that weren't one note per beat)
    /// apply retroactively to takes recorded before the fix existed.
    func reconstruct() -> (taps: [Tap], grid: Grid, sections: [DropoutSection]) {
        let grid = Grid(startTime: gridStartTime, bpm: bpm, subdivisions: 1)
        let barSeconds = grid.beatInterval * 4
        let cycleBars = pacedBars + silentBars
        let totalBars = cycles * cycleBars + pacedBars

        var sections: [DropoutSection] = []
        var bar = 0
        while bar < totalBars {
            let paced = (bar % cycleBars) < pacedBars
            var end = bar
            while end < totalBars, ((end % cycleBars) < pacedBars) == paced { end += 1 }
            sections.append(DropoutSection(startTime: gridStartTime + Double(bar) * barSeconds,
                                           endTime: gridStartTime + Double(end) * barSeconds,
                                           isPaced: paced))
            bar = end
        }
        return (tapTimes.map { Tap(time: $0) }, grid, sections)
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
        load(prefix: "jam-", as: JamSession.self).sorted { $0.date < $1.date }
    }

    @discardableResult
    static func save(_ session: FormSession) throws -> URL {
        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: session.date)
        let url = directory.appendingPathComponent("form-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAllForm() -> [FormSession] {
        load(prefix: "form-", as: FormSession.self).sorted { $0.date < $1.date }
    }

    @discardableResult
    static func save(_ session: DropoutSession) throws -> URL {
        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: session.date)
        let url = directory.appendingPathComponent("dropout-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAllDropout() -> [DropoutSession] {
        load(prefix: "dropout-", as: DropoutSession.self).sorted { $0.date < $1.date }
    }

    /// Decode every file with the given name prefix. The prefix keeps jam and form takes
    /// apart, so neither can be silently decoded as the other.
    private static func load<T: Decodable>(prefix: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []
        let candidates = files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(prefix)
        }
        let decoded = candidates.compactMap { try? decoder.decode(T.self, from: Data(contentsOf: $0)) }
        // Silently dropping unreadable sessions is how a schema change quietly erases
        // history. Say so instead.
        if decoded.count < candidates.count {
            FileHandle.standardError.write(Data(
                "Note: \(candidates.count - decoded.count) '\(prefix)' session(s) could not be read (older format).\n".utf8))
        }
        return decoded
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
