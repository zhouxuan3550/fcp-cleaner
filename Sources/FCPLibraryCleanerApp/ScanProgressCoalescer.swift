import Foundation
import FCPLibraryCleanerCore

/// Coalesces scanner progress callbacks so the main actor receives at most one
/// update per minimum interval; when several callbacks land inside the window,
/// only the newest buffered value is forwarded later.
///
/// The tail of a suppressed burst is deliberately dropped rather than flushed:
/// scans finish by swapping in their result view, and cancels are independent
/// of this path, so no extra timer task is warranted.
final class ScanProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ScanProgress?
    private var lastForwardedAt = ContinuousClock.now - Duration.seconds(3600)
    private let minimumInterval: Duration

    init(minimumInterval: Duration = .milliseconds(100)) {
        self.minimumInterval = minimumInterval
    }

    /// Returns nil while still inside the throttle window (value is buffered),
    /// or the progress to forward once the interval has elapsed.
    func consume(_ progress: ScanProgress) -> ScanProgress? {
        lock.lock()
        defer { lock.unlock() }
        guard ContinuousClock.now - lastForwardedAt >= minimumInterval else {
            pending = progress
            return nil
        }
        lastForwardedAt = .now
        pending = nil
        return progress
    }
}
