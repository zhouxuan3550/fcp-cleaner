import Foundation

/// A lock-backed token lets UI cancellation reach detached filesystem traversal safely.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellationHandlers: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let handlers = Array(cancellationHandlers.values)
        cancellationHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func registerCancellationHandler(_ handler: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        guard !cancelled else { lock.unlock(); handler(); return nil }
        let id = UUID()
        cancellationHandlers[id] = handler
        lock.unlock()
        return id
    }

    func removeCancellationHandler(_ id: UUID?) {
        guard let id else { return }
        lock.lock()
        cancellationHandlers.removeValue(forKey: id)
        lock.unlock()
    }
}
