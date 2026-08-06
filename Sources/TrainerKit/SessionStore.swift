import Foundation
import TimingCore

/// Where a take sat inside a planned practice session.
///
/// Optional on every take type: a take started from the drill menu belongs to no session, and
/// every take recorded before M9 decodes with this absent.
///
/// Recording it is the whole reason M9 touches storage before it touches anything else.
/// "Was this the cold take or the fifth one of the evening?" cannot be answered after the
/// fact from a bare timestamp, and it is exactly the question M10 (cold vs warm) and M16
/// (within-session vs between-session) are built to ask. A take recorded without this is a
/// take those milestones can never use.
public struct SessionPlacement: Codable, Equatable {
    public let sessionId: UUID
    /// 0-based position in the plan as it actually ran.
    public let blockIndex: Int
    /// What the block was for — see `BlockRole`. Stored as its raw string so a future role
    /// never makes an old take undecodable.
    public let role: String
    /// Seconds from the start of the session to the start of this take. The warm-up axis:
    /// a cold measurement and one taken 25 minutes in are not the same measurement, and
    /// differencing timestamps would fold in however long was spent on the rating screen.
    public let elapsedSeconds: Double
    /// How the player said they felt before the sitting began — see `SessionState`.
    ///
    /// Raw string, like `role`, so a state added later never orphans a recorded take. Copied
    /// onto every take of the sitting rather than left in the manifest alone, so pooling by it
    /// needs no join — the same reasoning that puts `role` here.
    ///
    /// `nil` means **not declared**, which is every take before M15 and any surface that does
    /// not ask. It does *not* mean `usual`: the picker defaults to `usual` so a declared
    /// ordinary evening is recorded as one, and folding the two together would erase the
    /// difference between saying nothing and saying nothing was wrong.
    public let state: String?

    public init(sessionId: UUID, blockIndex: Int, role: String, elapsedSeconds: Double,
                state: String? = nil) {
        self.sessionId = sessionId; self.blockIndex = blockIndex
        self.role = role; self.elapsedSeconds = elapsedSeconds
        self.state = state
    }
}

/// A stored take that can check its own internal consistency.
///
/// `Codable` proves the fields are present and correctly typed. It cannot prove that several
/// parallel arrays describing the same rounds are the same length — a file where they disagree
/// decodes cleanly and then traps on the first index out of range. A crash while reading
/// history is precisely the failure R6.4 exists to prevent, and it would take the app down
/// rather than reporting anything.
///
/// Types carrying parallel arrays implement this; everything else takes the default. An invalid
/// file is treated as unreadable, so it surfaces through `unreadableFiles()` and `review list`
/// with a name attached instead of as a stack trace.
protocol StoredTake: Decodable {
    var isStructurallyValid: Bool { get }
}

extension StoredTake {
    var isStructurallyValid: Bool { true }
}

/// A recorded jam, persisted to disk.
///
/// Stores the raw taps and grid parameters, not just the summary, so the M5 review can
/// re-analyze and plot a session without the player having to record it again. The summary
/// fields are duplicated for cheap listing.
struct JamSession: Codable, StoredTake {
    let date: Date
    let bpm: Double
    let device: String
    let calibrationConstantMs: Double?
    let calibrationSource: String?
    let grooveName: String
    let bars: Int
    /// The grid this take was **analysed** on, so the review rebuilds what it was scored on.
    let subdivisions: Int
    /// The subdivision the player was **asked to produce**, when one was prescribed.
    ///
    /// Distinct from `subdivisions` even though they are equal whenever a rung was set: that one
    /// is a property of the analysis and this is a property of the task. Free playing has a grid
    /// and no rung, which is every take before M14 — so `nil` here means "no rung", never
    /// "quarters", and `IntervalObservation.subdivisions` reads 1 for those because the task was
    /// the beat. A raw string rather than the enum for the same reason as
    /// `ExperimentAssignment.arm`: adding a rung must never orphan a recorded take.
    let rung: String?
    /// The long-to-short swing ratio the take was played at. `nil` is straight.
    ///
    /// Unlike `rung`, where `nil` means *no rung was prescribed* and emphatically not quarters,
    /// `nil` here really does mean straight: a ratio of 1 **is** straight, the identity of the
    /// arithmetic rather than a separate case, and every take recorded before M15 was played
    /// against an even grid. So an absent value reads as straight without inventing anything.
    /// See `Feel`.
    let swingRatio: Double?
    /// The offbeat drill's level, when this take was one. `nil` for every ordinary jam.
    let offbeatLevel: Int?

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
    // Optional because these are NaN whenever too little was matched to compute them, and
    // JSONEncoder throws on a non-finite Double — which loses the whole take. See
    // `Stats.finite`. Older takes stored a number and still decode.
    let meanAsynchronyMs: Double?
    let sdAsynchronyMs: Double?
    let lag1Autocorrelation: Double?
    let driftMsPerBeat: Double?
    let headline: String

    let placement: SessionPlacement?
    /// Which experiment and arm, when this take was played as part of one. Written since M13;
    /// nothing reads it yet. See `ExperimentAssignment`.
    let experiment: ExperimentAssignment?

    // Every note-on in the window, before chord clustering: pitch, velocity, time.
    //
    // `tapTimes` above is the *clustered* series — a chord is one rhythmic event, which is
    // right for timing and useless for asking what was played. Optional so every take
    // recorded before this existed still decodes; nothing analyses them yet. They are stored
    // now because the question "does playing something interesting change my timing?" can
    // only ever be asked of takes that recorded what was played, and a take recorded without
    // pitch is lost to it for good. Same reasoning as `SessionPlacement`.
    let rawTimes: [Double]?
    let rawNotes: [Int?]?
    let rawVelocities: [Int?]?

    /// Rebuild the taps and grid for re-analysis in the review.
    func reconstruct() -> (taps: [Tap], grid: Grid) {
        let taps = zip(tapTimes, tapVelocities).map { Tap(time: $0, velocity: $1) }
        return (taps, Grid(startTime: gridStartTime, bpm: bpm, subdivisions: subdivisions))
    }

    /// This take under the *current* analysis.
    ///
    /// Every caller must go through here rather than reading the cached summary fields.
    /// Chord clustering arrived after the first two takes were recorded, and their stored
    /// numbers are pre-clustering: take 1 has a stored SD of 16.7 ms against 18.3 ms
    /// recomputed. A history chart or trend line fed from the cache plots a value no current
    /// analysis produces, and fits a slope through the difference.
    func report() -> TimingReport {
        let (taps, grid) = reconstruct()
        return TimingAnalysis.analyze(taps: taps, grid: grid)
    }

    var asynchroniesMs: [Double] { report().asynchroniesMs }

    /// Matched notes per beat — how densely this take was actually played.
    ///
    /// Recomputed like everything else (R3.1), and matched notes rather than raw ones so it
    /// counts rhythmic events: a chord is one note here, which is what "density" has to mean
    /// for a keyboard player. `nil` when the take has no length to divide by.
    var notesPerBeat: Double? {
        let beats = Double(bars * 4)
        guard beats > 0 else { return nil }
        return Double(report().matchedCount) / beats
    }

    /// The feel this take was played against — straight unless a ratio was stored.
    var feel: Feel { swingRatio.flatMap { Feel(swingRatio: $0) } ?? .straight }

    /// This take's offbeat report, when it was an offbeat drill.
    func offbeatReport() -> OffbeatReport? {
        guard offbeatLevel != nil else { return nil }
        return OffbeatAnalysis.analyze(matched: report().matched, grid: reconstruct().grid)
    }

    /// Notes per beat the player was **asked** to produce: the rung, or 1 for free playing.
    ///
    /// Free playing prescribes nothing, so the task is the beat — which is also what the notes
    /// bear out, since 82.4% of every matched note on record sits a beat from the last (§7.23
    /// step 3b). It is emphatically *not* `subdivisions`: those takes were scored on a
    /// sixteenth grid, and calling that a 150 ms task would describe an interval nobody played.
    var taskSubdivisions: Int { rung.flatMap { IntervalRung(rawValue: $0)?.subdivisions } ?? 1 }

    /// This take's notes keyed by the interval they were produced at.
    ///
    /// Straight off the one report, so the clustering and matching that produced every other
    /// number produced these too.
    func producedNotes() -> [ProducedNote] {
        ProducedIntervalAnalysis.notes(from: report().matched, grid: reconstruct().grid)
    }

    /// Every note-on, for content analysis. Empty for takes recorded before pitch was stored;
    /// callers must say so rather than reporting an empty result as a finding.
    var playedNotes: [PlayedNote] {
        guard let times = rawTimes else { return [] }
        let notes = rawNotes ?? Array(repeating: nil, count: times.count)
        let velocities = rawVelocities ?? Array(repeating: nil, count: times.count)
        guard notes.count == times.count, velocities.count == times.count else { return [] }
        return times.indices.map {
            PlayedNote(time: times[$0], note: notes[$0], velocity: velocities[$0])
        }
    }

    var hasPitchData: Bool { !(rawTimes?.isEmpty ?? true) }

    /// What was played against how it was timed, within this take.
    func contentReport() -> ContentReport {
        let (taps, grid) = reconstruct()
        let events = TapClustering.collapse(taps, windowSeconds: 0.035)
        return MusicalContentAnalysis.analyze(rawNotes: playedNotes, events: events, grid: grid,
                                              totalBars: bars)
    }
}

/// A recorded form drill. Kept separate from `JamSession` because it measures a different
/// thing — where you are in the music, not how you place a beat — and pooling the two would
/// be meaningless.
struct FormSession: Codable, StoredTake {
    let date: Date
    let bpm: Double
    let bars: Int
    let phraseBars: Int
    let level: Int
    let feelRating: Int?

    let gridStartTime: Double
    /// The grid the marks were scored against. Optional: takes recorded before the field
    /// existed were all scored at 4, and `report()` falls back to that rather than guessing.
    let subdivisions: Int?
    let markTimes: [Double]

    let phrasesAvailable: Int
    let marksPlaced: Int
    let onFormCount: Int
    let tightCount: Int
    // Optional for the reason in `JamSession` above: no marks, or one, and these are NaN.
    let meanAbsFormErrorBars: Double?
    let phaseErrorMeanMs: Double?
    let phaseErrorSDms: Double?
    let slipBarsPerPhrase: Double?
    let missedPhrases: [Int]
    let headline: String

    let placement: SessionPlacement?
    /// Which experiment and arm, when this take was played as part of one. Written since M13;
    /// nothing reads it yet. See `ExperimentAssignment`.
    let experiment: ExperimentAssignment?

    /// Re-analyse from the stored marks, like the other drills, so an analysis fix reaches
    /// takes recorded before it. Everything the analysis needs is stored: tempo, grid origin,
    /// phrase length and take length. The summary above is a cache — this is the answer.
    func report() -> FormReport {
        FormAnalysis.analyze(markTimes: markTimes,
                             grid: Grid(startTime: gridStartTime, bpm: bpm,
                                        subdivisions: subdivisions ?? 4),
                             beatsPerBar: 4, barsPerPhrase: phraseBars, totalBars: bars)
    }
}

/// A recorded continuation drill. Separate again: it is the only session type that yields a
/// clock/motor split, because it is the only one with unpaced playing in it.
struct DropoutSession: Codable, StoredTake {
    let date: Date
    let bpm: Double
    let pacedBars: Int
    let silentBars: Int
    let cycles: Int
    let feelRating: Int?

    let gridStartTime: Double
    /// The grid the silences were scored against. Optional for the reason in `FormSession`;
    /// every take recorded before the field existed was quarter notes.
    let subdivisions: Int?
    let tapTimes: [Double]

    // Cached summary, as above — `reconstruct()` is the source of truth.
    // Optional for the reason in `JamSession` above: too few usable trials and these are NaN.
    let pacedSDms: Double?
    let unpacedIntervalSDms: Double?
    let clockSDms: Double?
    let motorSDms: Double?
    let modelHolds: Bool
    let reentryErrorMeanMs: Double?
    let reentryErrorSDms: Double?
    let headline: String

    // Cached summaries. Optional so sessions written before these existed still decode —
    // and unnecessary anyway, because `reconstruct()` can recompute everything from the
    // raw taps below.
    let tempoBiasBpm: Double?
    let playedBpm: Double?
    let splitIsReliable: Bool?
    let discardedTrials: Int?

    let placement: SessionPlacement?
    /// Which experiment and arm, when this take was played as part of one. Written since M13;
    /// nothing reads it yet. See `ExperimentAssignment`.
    let experiment: ExperimentAssignment?
    /// The note value the player was **asked** to hold through the silences.
    ///
    /// `nil` on every take recorded before M14, where the analysis inferred it from what was
    /// played. The inference is kept for those; it is the *snapping* inside it that changed.
    let rung: String?
    /// The long-to-short swing ratio the take was played at. `nil` is straight.
    ///
    /// Unlike `rung`, where `nil` means *no rung was prescribed* and emphatically not quarters,
    /// `nil` here really does mean straight: a ratio of 1 **is** straight, it is the identity of
    /// the arithmetic rather than a separate case, and every take recorded before M15 was played
    /// against an even grid. So an absent value can be read as straight without inventing
    /// anything. See `Feel`.
    let swingRatio: Double?

    /// This take under the current analysis, with the note value it was asked for.
    ///
    /// Every caller goes through here rather than pairing `reconstruct()` with an `analyze`
    /// call of its own. Seven call sites did the latter, which meant seven places to remember
    /// to pass the rung — and the one that forgot would silently re-infer the note value and
    /// disagree with the take's own report. That is R3.1's cached-summary defect wearing the
    /// shape of a duplicated pipeline.
    func report() -> DropoutReport {
        let (taps, grid, sections) = reconstruct()
        return DropoutAnalysis.analyze(taps: taps, grid: grid, sections: sections,
                                       notesPerBeat: askedNotesPerBeat)
    }

    /// Notes per beat asked for, or `nil` when nothing was prescribed and the analysis infers.
    var askedNotesPerBeat: Int? { rung.flatMap { IntervalRung(rawValue: $0)?.subdivisions } }

    /// The feel this take was played against — straight unless a ratio was stored.
    var feel: Feel { swingRatio.flatMap { Feel(swingRatio: $0) } ?? .straight }

    /// Rebuild the inputs to the analysis, so a stored drill can be re-analysed with the
    /// current logic. The stored summary is only a cache; this is the source of truth.
    ///
    /// Everything needed is here — tempo, cycle shape, grid origin, and every tap — which is
    /// what lets an analysis fix (say, discarding silences that weren't one note per beat)
    /// apply retroactively to takes recorded before the fix existed.
    func reconstruct() -> (taps: [Tap], grid: Grid, sections: [DropoutSection]) {
        let grid = Grid(startTime: gridStartTime, bpm: bpm, subdivisions: subdivisions ?? 1)
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

/// A recorded tempo-calibration session.
struct TempoSession: Codable, StoredTake {
    let date: Date
    let targets: [Double]
    let leadBars: Int
    let holdBars: Int
    let rounds: Int
    let feelRating: Int?

    let tapTimes: [Double]
    // The hold windows are stored rather than recomputed: with rotating targets each round
    // has its own tempo, so the timeline can't be rebuilt from a single BPM.
    let roundTargets: [Double]
    let roundHoldStarts: [Double]
    let roundHoldEnds: [Double]

    // Cached summary, written at save time. Nothing reads it back — every view recomputes
    // from `taps` and `roundWindows` so analysis fixes reach old sessions. Kept because it
    // makes the stored JSON readable; treat it as a snapshot, not the current answer.
    let usableCount: Int
    let meanErrorPercent: Double?
    let meanAbsErrorPercent: Double?
    let improvementPerRound: Double?
    let headline: String

    let placement: SessionPlacement?
    /// Which experiment and arm, when this take was played as part of one. Written since M13;
    /// nothing reads it yet. See `ExperimentAssignment`.
    let experiment: ExperimentAssignment?
    /// The note value asked for during each hold. `nil` on every take recorded before M14.
    let rung: String?

    var taps: [Tap] { tapTimes.map { Tap(time: $0) } }

    /// This take under the current analysis, with the note value it was asked for.
    ///
    /// One place, for the reason `DropoutSession.report()` gives: five call sites recomputed
    /// this by hand, and the rung has to reach every one of them or a take disagrees with its
    /// own report depending on which readout asked.
    func report() -> TempoCalibrationReport {
        TempoCalibrationAnalysis.analyze(taps: taps, rounds: roundWindows,
                                         notesPerBeat: askedNotesPerBeat)
    }

    var askedNotesPerBeat: Int? { rung.flatMap { IntervalRung(rawValue: $0)?.subdivisions } }

    /// Three arrays describe the same rounds. `roundWindows` uses `zip`, which does not trap
    /// on a mismatch — it silently truncates to the shortest, so a malformed file would report
    /// a take with fewer rounds than were played and look entirely plausible.
    var isStructurallyValid: Bool {
        roundHoldStarts.count == roundTargets.count && roundHoldEnds.count == roundTargets.count
    }

    var roundWindows: [TempoRound] {
        zip(roundTargets.indices, zip(roundTargets, zip(roundHoldStarts, roundHoldEnds))).map {
            TempoRound(index: $0.0, targetBpm: $0.1.0,
                       holdStart: $0.1.1.0, holdEnd: $0.1.1.1)
        }
    }
}

/// A recorded tempo-memory drill. Separate again, because it is the only drill with an
/// experimental *condition* in it — the two retention types are the measurement, and pooling
/// them with anything else would throw away the contrast.
struct MemorySession: Codable, StoredTake {
    let date: Date
    let bpm: Double
    let referenceBars: Int
    let retentionBars: Int
    let reproduceBars: Int
    let rounds: Int
    let feelRating: Int?

    let tapTimes: [Double]
    // The round windows are stored rather than recomputed: which rounds were filled is part
    // of the design, and rebuilding it from a rule would silently change old takes if the
    // alternation ever changed.
    let roundConditions: [String]
    let roundRetentionStarts: [Double]
    let roundRetentionEnds: [Double]
    let roundReproduceStarts: [Double]
    let roundReproduceEnds: [Double]

    // Cached summary, as everywhere else: written for legibility, never read back.
    let usableCount: Int
    let silentMeanAbsErrorPercent: Double?
    let filledMeanAbsErrorPercent: Double?
    let interferenceCost: Double?
    let headline: String

    let placement: SessionPlacement?
    /// Which experiment and arm, when this take was played as part of one. Written since M13;
    /// nothing reads it yet. See `ExperimentAssignment`.
    let experiment: ExperimentAssignment?

    var taps: [Tap] { tapTimes.map { Tap(time: $0) } }

    /// Five arrays describe the same rounds, so they must be the same length. A file where
    /// they disagree would trap on the first index out of range.
    var isStructurallyValid: Bool {
        let n = roundConditions.count
        return roundRetentionStarts.count == n && roundRetentionEnds.count == n
            && roundReproduceStarts.count == n && roundReproduceEnds.count == n
    }

    var roundWindows: [MemoryRound] {
        // Belt and braces: such a file never loads, and if one reaches here it yields no
        // rounds rather than crashing.
        guard isStructurallyValid else { return [] }
        return roundConditions.indices.map { i in
            MemoryRound(index: i, targetBpm: bpm,
                        condition: RetentionCondition(rawValue: roundConditions[i]) ?? .silent,
                        retentionStart: roundRetentionStarts[i],
                        retentionEnd: roundRetentionEnds[i],
                        reproduceStart: roundReproduceStarts[i],
                        reproduceEnd: roundReproduceEnds[i])
        }
    }
}

enum SessionStore {
    /// Redirects storage somewhere else. **Tests only, and nil in every other context.**
    ///
    /// The real directory holds primary data that R6.2 says must never be deleted or rewritten,
    /// and a test suite that saves takes has to save them somewhere else — a suite that could
    /// scribble on the player's practice history would be a worse defect than any it caught.
    /// `check.sh` fails if anything outside `Tests/` assigns this.
    static var directoryOverride: URL?

    static var directory: URL {
        let base = directoryOverride ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicalTrainer/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func save(_ session: JamSession) throws -> URL {
        let url = uniqueURL(prefix: "jam-", date: session.date)
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
        let url = uniqueURL(prefix: "form-", date: session.date)
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
        let url = uniqueURL(prefix: "dropout-", date: session.date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAllDropout() -> [DropoutSession] {
        load(prefix: "dropout-", as: DropoutSession.self).sorted { $0.date < $1.date }
    }

    @discardableResult
    static func save(_ session: TempoSession) throws -> URL {
        let url = uniqueURL(prefix: "tempo-", date: session.date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAllTempo() -> [TempoSession] {
        load(prefix: "tempo-", as: TempoSession.self).sorted { $0.date < $1.date }
    }

    @discardableResult
    static func save(_ session: MemorySession) throws -> URL {
        let url = uniqueURL(prefix: "memory-", date: session.date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url, options: .atomic)
        return url
    }

    static func loadAllMemory() -> [MemorySession] {
        load(prefix: "memory-", as: MemorySession.self).sorted { $0.date < $1.date }
    }

    @discardableResult
    static func save(_ record: TrainingSessionRecord) throws -> URL {
        let url = uniqueURL(prefix: "session-", date: record.date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    static func loadAllSessions() -> [TrainingSessionRecord] {
        load(prefix: "session-", as: TrainingSessionRecord.self).sorted { $0.date < $1.date }
    }

    /// A path for this take, made unique if one with the same timestamp already exists.
    ///
    /// The name is derived from the take's own date, so two takes finishing in the same second
    /// resolved to the same file and the second silently overwrote the first. R6.2 says a
    /// stored take is never rewritten, and "two drills cannot finish in the same second" is the
    /// kind of assumption that turns out to be wrong once. The test suite hit it on its first
    /// run, saving several synthetic takes that shared a date.
    private static func uniqueURL(prefix: String, date: Date) -> URL {
        let stamp = ISO8601DateFormatter.filenameFormatter.string(from: date)
        var url = directory.appendingPathComponent("\(prefix)\(stamp).json")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(prefix)\(stamp)-\(attempt).json")
            attempt += 1
        }
        return url
    }

    /// Every stored file that no longer decodes, across **every** take type.
    ///
    /// R6.1 says every take ever recorded must continue to decode, "verified by running
    /// `review list`" — and that verification did not exist. `load` writes a note to stderr and
    /// returns whatever survived, so the command exited 0 and `check.sh` printed PASS however
    /// much history had been orphaned. `review list` also loads only jams, so a schema change
    /// to any of the other five types could never have been caught by it at all.
    ///
    /// This is deliberately separate from loading: an integrity check that runs as a side
    /// effect of reading is one a caller can forget to look at.
    static func unreadableFiles() -> [URL] {
        var bad = unreadable(prefix: "jam-", as: JamSession.self)
        bad += unreadable(prefix: "form-", as: FormSession.self)
        bad += unreadable(prefix: "dropout-", as: DropoutSession.self)
        bad += unreadable(prefix: "tempo-", as: TempoSession.self)
        bad += unreadable(prefix: "memory-", as: MemorySession.self)
        bad += unreadable(prefix: "session-", as: TrainingSessionRecord.self)
        return bad.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func unreadable<T: StoredTake>(prefix: String, as type: T.Type) -> [URL] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return storedFiles(prefix: prefix).filter { url in
            guard let data = try? Data(contentsOf: url),
                  let value = try? decoder.decode(T.self, from: data) else { return true }
            return !value.isStructurallyValid
        }
    }

    /// Files on disk carrying a given prefix, in name order.
    private static func storedFiles(prefix: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(prefix)
        }
    }

    /// Decode every file with the given name prefix. The prefix keeps jam and form takes
    /// apart, so neither can be silently decoded as the other.
    private static func load<T: StoredTake>(prefix: String, as type: T.Type) -> [T] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let candidates = storedFiles(prefix: prefix)
        let decoded = candidates.compactMap { url -> T? in
            guard let data = try? Data(contentsOf: url),
                  let value = try? decoder.decode(T.self, from: data),
                  value.isStructurallyValid else { return nil }
            return value
        }
        // Silently dropping unreadable sessions is how a schema change quietly erases
        // history. Say so instead.
        if decoded.count < candidates.count {
            let note = "Note: \(candidates.count - decoded.count) '\(prefix)' session(s) "
                     + "could not be read (older format).\n"
            FileHandle.standardError.write(Data(note.utf8))
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
