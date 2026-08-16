import Foundation

/// **One list of what makes two takes a different task**, and the only copy of it.
///
/// §7.28 named this as a single list and it was never in a single place: the rules lived as private
/// types inside `TrainerEngine`, in the module that talks to CoreAudio, on the side of the boundary
/// `swift test` cannot reach on Linux. Three defects have been about this list — §7.24 step 8 pooled
/// an offbeat take with 21 free jams, §7.48 drew one chart line through groups the cards refused to
/// pool, and §7.52 fed every skank to the planner as an ordinary jam — and none of the three was
/// reachable by a test that runs in CI.
///
/// So it moves here, unchanged. R1.1.1: anything analysable belongs in a pure module, and *"are
/// these two takes the same task"* is the most analysable question in the project. It is also M17's
/// step 0 — one progression model needs one vocabulary for what a task is, and this is that
/// vocabulary (§7.59).
///
/// **What did not come with it, and why.** `BackingIdentity` and `OffbeatLevel` live in `GrooveCore`,
/// which this module depends on in neither direction (R1.1.3). Two consequences, both deliberate:
/// a groove name is parsed into a `BackingGroup` by the caller, and the offbeat level's *name* is
/// supplied to `title(offbeatLevelName:)` rather than looked up here. The level *number* is an axis
/// and lives here; what that number is called is the backing module's word. `OffbeatAnalysis
/// .suggestedLevel` already crosses this boundary the same way, taking an `Int` for the same reason.

/// Which band played, for the purpose of fitting a line through a series.
///
/// **The split is fixed against generated, and the generated side keys on the style rather than the
/// seed.** `BackingIdentity.parse` draws exactly that line — a name without an `@` is a fixed
/// backing, which is every take recorded before M19 — so this is not a new concept and needs no
/// schema change.
///
/// Three ways to do it and this is the third. Keying on the full groove name makes every seed a
/// group of one, and `TrendAnalysis.minimumPoints` is 3, so the 21-take free-jam series — the
/// longest in the project — would vanish along with the fixed group worth keeping. Excluding
/// generated takes keeps the history and throws away every future training take, which is where most
/// playing happens. This keeps the old series intact and lets `driving` accumulate its own across
/// sittings.
///
/// **Every fixed backing is one bucket, deliberately.** `basicRock` and `jamBacking` pool together
/// exactly as they always did, with the same warning naming the mix. Splitting them would be a
/// defensible readout and a different one, and re-scoring the project's headline series while
/// building something else is how a finding gets attributed to the wrong cause.
///
/// Whether two seeds of one style pool honestly is argued in §7.29 step 7 and **not measured**. §9
/// open question 10 carries it, and the group says so out loud rather than implying it is settled.
public enum BackingGroup: Hashable, Comparable {
    /// Every take recorded before M19, whichever fixed groove it played.
    case fixed
    /// A generated backing, keyed on the style. Two seeds land here together.
    case style(String)

    /// Empty for `fixed`, so every title this project has ever printed is unchanged.
    public var label: String {
        switch self {
        case .fixed: return ""
        case .style(let name): return ", \(name)"
        }
    }

    public static func < (a: BackingGroup, b: BackingGroup) -> Bool {
        switch (a, b) {
        case (.fixed, .fixed):              return false
        case (.fixed, .style):              return true
        case (.style, .fixed):              return false
        case (.style(let x), .style(let y)): return x < y
        }
    }
}

/// Which kit played, for the purpose of fitting a line through a series.
///
/// **A kit change is a backing change and a backing change is a task change**, and until §7.61 the
/// kit was the one axis on that list nothing keyed on. It had already moved twice under the corpus —
/// a bass on 6 August, then accented timekeepers and a fade over every one-shot on 7 August, the
/// last removing a truncation click an ear had named. Every one of those takes kept its groove name,
/// so the longest series in the project spans them as a single line.
///
/// **`nil` and the original fingerprint are the same group, deliberately.** Every take on record
/// predates the field, so treating "unrecorded" as its own group would split the corpus from every
/// take recorded from now on — 104 takes orphaned on a bookkeeping distinction rather than an
/// acoustic one, and the 21-take free-jam series would stop growing the day this merged. The takes
/// either side of it heard the same kit; only one of them wrote down which.
///
/// **The cost of that choice, stated:** the 6 and 7 August changes are inside `.original` and this
/// does not separate them. They are recoverable — a take carries its date and those changes are
/// commits with dates — but recovering them needs the historical kits rendered and fingerprinted,
/// which is archaeology nobody has done. §7.62 records the method. What this axis is *for* is the
/// change that has not happened yet, where a fingerprint exists on both sides.
public enum KitGroup: Hashable, Comparable {
    /// The kit every take on record was played over.
    case original
    /// A kit that differs from it, keyed by fingerprint.
    case changed(String)

    /// `BackingKit.fingerprint` as it stood on 15 August 2026, before M26 changed a voice.
    ///
    /// **A historical constant, which is why pinning it cannot rot.** A "current version" number
    /// would be a rule somebody has to remember to bump — `LESSONS.md` shape 21 — but this one
    /// describes a kit that already existed and can never need updating. `KitFingerprintTests`
    /// asserts the live kit still matches it, so **the first change to any voice fails that test**,
    /// which is how whoever changes it finds out that the grouping needs a decision.
    public static let originalFingerprint = "227944508dd5"

    /// The kit after M26 item 1 gave every drum voice velocity layers (§7.63, §7.64).
    ///
    /// **Edited once, before it had ever been played over.** The rule on `known` is append-never-
    /// edit, and it protects kits that *takes were recorded against* — correcting one of those would
    /// re-label takes that heard something else. This value moved while the branch was still open:
    /// the listening test said the first tuning was inaudible, the retune changed every voice, and no
    /// take had been recorded over either. A row nobody's data points at is a draft, not history.
    ///
    /// The distinction is worth keeping sharp, because it is the only circumstance in which editing
    /// this list is safe: **the kit must never have reached a stored take.** After that, append.
    public static let velocityLayeredFingerprint = "ebb01fc6aed0"

    /// Every kit this project has shipped, oldest first.
    ///
    /// **Appended to, never edited.** Each row describes a kit that existed and that takes were
    /// played over, so correcting one would re-label takes that heard something else. A kit missing
    /// from this list still groups correctly — it just prints its digest instead of a name.
    public static let known: [(fingerprint: String, name: String)] = [
        (originalFingerprint, "original"),
        (velocityLayeredFingerprint, "velocity layers"),
    ]

    public init(fingerprint: String?) {
        guard let fingerprint, fingerprint != Self.originalFingerprint else {
            self = .original
            return
        }
        self = .changed(fingerprint)
    }

    /// Empty for `original`, so every title this project has ever printed is unchanged.
    ///
    /// Six characters of the digest is enough to tell two kits apart in a readout and short enough
    /// to sit in a heading. Nobody is looking one up by name; they are asking whether two lines are
    /// the same band.
    public var label: String {
        switch self {
        case .original:
            return ""
        case .changed(let fingerprint):
            // A named kit reads as a kit; an unnamed one still has to be distinguishable, so it
            // prints enough digest to tell two apart in a heading.
            let name = Self.known.first { $0.fingerprint == fingerprint }?.name
            return ", kit \(name ?? String(fingerprint.prefix(6)))"
        }
    }

    public static func < (a: KitGroup, b: KitGroup) -> Bool {
        switch (a, b) {
        case (.original, .original):            return false
        case (.original, .changed):             return true
        case (.changed, .original):             return false
        case (.changed(let x), .changed(let y)): return x < y
        }
    }
}

/// A group of jams comparable enough to fit one line through.
///
/// Six axes, each of which arrived because a line fitted across it was measuring the change rather
/// than the player.
public struct JamTask: Hashable, Comparable {
    public let bpm: Int

    /// **The stored raw value, not an `IntervalRung`**, and that is load-bearing rather than lazy.
    /// Decoding to the enum would fold every unrecognised string into `nil` — which is *free
    /// playing*, the largest and oldest group in the corpus. A rung this build does not know about
    /// would silently join the series the project reads its progress from. As a string it groups on
    /// its own and says so, which is the honest failure.
    public let rung: String?

    /// Which band, at the resolution a trend can honestly use.
    ///
    /// A fourth confound axis beside tempo, rung, feel and the offbeat level, and it arrives for the
    /// reason the others did: §7.24 step 8 and §7.27 between them retracted three verdicts that were
    /// the *task* changing rather than the player. Naming a confound is the floor and separating it
    /// is the fix (R3.4 against R3.5, `LESSONS.md` shape 19) — and the closing jam rotating its style
    /// between sittings would otherwise put a new backing into this group every evening, with the
    /// warning growing an entry each time.
    public let backing: BackingGroup

    /// Feel joins tempo and rung as a confound axis: a swung take and a straight one at the same
    /// tempo and rung are different tasks, and a line fitted across the change would be measuring
    /// the change.
    public let swingRatio: Double?

    /// So does the offbeat drill, and it is the sharpest case of the five.
    ///
    /// An offbeat take stores no rung and no swing, so without this it keys identically to a free
    /// jam and lands in the group the project reads its progress from. The first one ever recorded
    /// did exactly that: a 48.4 ms spread — by a wide margin the worst take on record, and a
    /// different task — fitted into "Jams at 100 BPM" alongside 21 free jams, with only a
    /// mixed-backings warning to name it (§7.24 step 8).
    public let offbeatLevel: Int?

    /// Which kit the band played on. See `KitGroup`.
    public let kit: KitGroup

    public init(bpm: Int, rung: String?, backing: BackingGroup,
                swingRatio: Double?, offbeatLevel: Int?, kit: KitGroup) {
        self.bpm = bpm
        self.rung = rung
        self.backing = backing
        self.swingRatio = swingRatio
        self.offbeatLevel = offbeatLevel
        self.kit = kit
    }

    /// The one name for this group.
    ///
    /// **Read by the trend card and by the history chart**, so the two cannot draw different groups
    /// under one heading. The chart used to plot a single line through every take of a drill while
    /// the cards beneath it split the same takes four ways and warned about the confounds — a reader
    /// who sees one line has been shown one line (`LESSONS.md` shape 19).
    ///
    /// - Parameter offbeatLevelName: what the backing module calls a level. Injected rather than
    ///   looked up, because `OffbeatLevel` is `GrooveCore`'s and this module depends on nothing.
    ///   Returning `nil` drops the clause, which is what an unrecognised level should do.
    public func title(offbeatLevelName: (Int) -> String?) -> String {
        let rungPart = rung.flatMap { IntervalRung(rawValue: $0)?.label }.map { ", \($0)" } ?? ""
        let feelPart = swingRatio.flatMap { Feel(swingRatio: $0) }.map { ", \($0.label)" } ?? ""
        let offbeatPart = offbeatLevel.flatMap { level in
            offbeatLevelName(level).map { ", offbeat level \(level) — \($0)" }
        } ?? ""
        return "Jams at \(bpm) BPM" + rungPart + feelPart + offbeatPart + backing.label + kit.label
    }

    /// Absent values sort where they always did: an absent rung before every named one, straight
    /// before swung, and no offbeat level before level 0. Changing any of these reorders every
    /// readout that lists groups.
    public static func < (a: JamTask, b: JamTask) -> Bool {
        if a.bpm != b.bpm { return a.bpm < b.bpm }
        if (a.rung ?? "") != (b.rung ?? "") { return (a.rung ?? "") < (b.rung ?? "") }
        if (a.swingRatio ?? 1) != (b.swingRatio ?? 1) {
            return (a.swingRatio ?? 1) < (b.swingRatio ?? 1)
        }
        if (a.offbeatLevel ?? -1) != (b.offbeatLevel ?? -1) {
            return (a.offbeatLevel ?? -1) < (b.offbeatLevel ?? -1)
        }
        if a.backing != b.backing { return a.backing < b.backing }
        return a.kit < b.kit
    }
}

/// Silence length **and** rung: both change the task. A longer silence is harder, and a rung changes
/// the note value being sustained, which is §7.23 trap 3 inside this drill.
///
/// **Here an absent rung really does mean quarters**, and that is the opposite of the rule for jams.
/// The two are decided by what the player was told, not by the field: a jam with no rung says *play
/// what you like*, which is a different task from quarters, while `DrillInstructions.dropout(rung:)`
/// returns the *same text* for `nil` and for `.quarters` — "Play exactly ONE NOTE PER BEAT" — because
/// this drill has demanded one note per beat in words since M6. Grouping them apart would split one
/// task in two on a distinction the player was never shown (`LESSONS.md` shape 13, and §7.24 step 1
/// for the jam side).
public struct ContinuationTask: Hashable, Comparable {
    public let silentBars: Int
    public let rung: IntervalRung
    /// The band drops out in this drill, but it is playing either side of every silence — so a
    /// changed kit changes what is being held against, exactly as it does for a jam.
    public let kit: KitGroup

    public init(silentBars: Int, rung: String?, kit: KitGroup) {
        self.silentBars = silentBars
        self.rung = rung.flatMap(IntervalRung.init(rawValue:)) ?? .quarters
        self.kit = kit
    }

    /// One name, read by the card and the chart alike. See `JamTask.title`.
    public var title: String {
        "Continuation drill — \(silentBars)-bar silences, \(rung.label)\(kit.label)"
    }

    public static func < (a: ContinuationTask, b: ContinuationTask) -> Bool {
        if a.silentBars != b.silentBars { return a.silentBars < b.silentBars }
        if a.rung != b.rung { return a.rung.rawValue < b.rung.rawValue }
        return a.kit < b.kit
    }
}

/// Level and phrase length. The level is a *ladder* — it is meant to rise — so a line fitted across
/// it measures the promotion rather than the player, and on-form rate falling as the landmarks are
/// removed is the drill working rather than the player getting worse.
public struct FormTask: Hashable, Comparable {
    public let level: Int
    public let phraseBars: Int
    /// The fills and the crash are the landmarks this drill removes rung by rung, so which kit
    /// plays them is part of the task rather than decoration.
    public let kit: KitGroup

    public init(level: Int, phraseBars: Int, kit: KitGroup) {
        self.level = level
        self.phraseBars = phraseBars
        self.kit = kit
    }

    /// One name, read by the card and the chart alike. See `JamTask.title`.
    public var title: String {
        "Form drill — level \(level), \(phraseBars)-bar phrases\(kit.label)"
    }

    public static func < (a: FormTask, b: FormTask) -> Bool {
        if a.level != b.level { return a.level < b.level }
        if a.phraseBars != b.phraseBars { return a.phraseBars < b.phraseBars }
        return a.kit < b.kit
    }
}
