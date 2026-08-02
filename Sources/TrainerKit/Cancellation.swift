import Foundation

/// A thread-safe stop signal for a running take.
///
/// Set from the UI thread, read from the take thread's wait loop. Deliberately *not* read
/// from the audio render callback — taking a lock there would risk a glitch — so audio stops
/// when the wait loop notices and tears the engine down, within a few milliseconds.
public final class CancellationFlag {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// Thrown when a take is stopped early. Carries no data: a take abandoned because something
/// was wrong is not worth analysing, and half a session would quietly pollute the history.
public struct TakeCancelled: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Take stopped." }
}
