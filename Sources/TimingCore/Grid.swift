import Foundation

/// The metronomic grid a performance is measured against.
///
/// The grid is defined by index arithmetic, never by accumulating an interval, so it never
/// drifts however long a session runs — the same discipline the audio clock uses. It also
/// extends infinitely in both directions, which matters for dropout drills: when the click
/// falls silent the grid is still defined, so we can measure how far the player has drifted
/// from where the beat *would* have been.
public struct Grid: Equatable {
    /// Timeline position of grid index 0, in seconds.
    public let startTime: Double
    public let bpm: Double
    /// Grid points per beat: 1 = quarter notes, 2 = eighths, 4 = sixteenths, 3 = triplets.
    public let subdivisions: Int

    public init(startTime: Double, bpm: Double, subdivisions: Int = 1) {
        precondition(bpm > 0, "bpm must be positive")
        precondition(subdivisions >= 1, "subdivisions must be at least 1")
        self.startTime = startTime
        self.bpm = bpm
        self.subdivisions = subdivisions
    }

    /// Seconds between adjacent grid points.
    public var interval: Double { 60.0 / bpm / Double(subdivisions) }

    /// Seconds per beat, independent of subdivision.
    public var beatInterval: Double { 60.0 / bpm }

    public func time(ofIndex index: Int) -> Double {
        startTime + Double(index) * interval
    }

    /// Grid index whose time is closest to `time`. May be negative.
    public func nearestIndex(to time: Double) -> Int {
        Int(((time - startTime) / interval).rounded())
    }

    /// Which subdivision within the beat a grid index falls on: 0 is the downbeat.
    /// Uses floored modulo so negative indices classify correctly.
    public func phase(ofIndex index: Int) -> Int {
        ((index % subdivisions) + subdivisions) % subdivisions
    }
}
