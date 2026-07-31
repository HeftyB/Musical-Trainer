import Foundation

/// One played note, already reduced to the shared timeline.
///
/// TimingCore is deliberately ignorant of where `time` came from. Upstream it is
/// `(midiHostTime − calibrationConstant)` mapped to seconds — but the analysis neither
/// knows nor cares, which is exactly what keeps it pure and testable.
public struct Tap: Equatable {
    /// Seconds on the shared, calibrated timeline.
    public let time: Double
    /// MIDI velocity 0–127, when known. Needed only for velocity/timing coupling.
    public let velocity: Int?

    public init(time: Double, velocity: Int? = nil) {
        self.time = time
        self.velocity = velocity
    }
}

/// A tap successfully associated with a grid point.
public struct MatchedTap: Equatable {
    public let tap: Tap
    public let gridIndex: Int
    /// Signed timing error in milliseconds: negative = ahead of the beat (rushing),
    /// positive = behind it (dragging). This sign convention is load-bearing; the whole
    /// app's language of "rush" and "drag" depends on it.
    public let asynchronyMs: Double

    public init(tap: Tap, gridIndex: Int, asynchronyMs: Double) {
        self.tap = tap
        self.gridIndex = gridIndex
        self.asynchronyMs = asynchronyMs
    }
}

/// The outcome of aligning a performance to a grid.
public struct MatchResult: Equatable {
    public let matched: [MatchedTap]
    /// Taps that fell outside the capture window of any grid point — a note between beats,
    /// or a stray double-trigger. Excluded from asynchrony statistics so they cannot
    /// corrupt them (see PLAN.md §5.3).
    public let extraTaps: [Tap]
    /// Grid points that no tap landed near — dropped notes. Reported, never folded into
    /// the asynchrony numbers.
    public let missedIndices: [Int]

    public var matchedCount: Int { matched.count }
    public var asynchroniesMs: [Double] { matched.map(\.asynchronyMs) }
}
