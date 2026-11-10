import CoreServices
import Darwin
import Foundation

enum FSEventsHistoryResult: Sendable, Equatable {
    case unchanged
    case changed
    case unavailable
}

final class FSEventsReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var historyDone = false
    private var changed = false
    private var didNotifyChange = false
    let wake = DispatchSemaphore(value: 0)
    private let onChange: (@Sendable () -> Void)?

    init(onChange: (@Sendable () -> Void)? = nil) { self.onChange = onChange }

    func receive(_ flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        lock.lock()
        var sawChange = false
        for index in 0..<count {
            let value = flags[index]
            if value == FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) {
                historyDone = true
            } else {
                // Includes ordinary events, dropped history, wrap, root changes and mounts.
                changed = true
                sawChange = true
            }
        }
        let shouldWake = changed || historyDone
        let shouldNotify = sawChange && historyDone && !didNotifyChange
        if shouldNotify { didNotifyChange = true }
        lock.unlock()
        if shouldWake { wake.signal() }
        if shouldNotify { onChange?() }
    }

    var result: FSEventsHistoryResult {
        lock.lock()
        defer { lock.unlock() }
        return changed ? .changed : (historyDone ? .unchanged : .unavailable)
    }
}

private final class FSEventsProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<FSEventsHistoryResult, Never>
    init(_ continuation: CheckedContinuation<FSEventsHistoryResult, Never>) { self.continuation = continuation }
    func finish(_ result: FSEventsHistoryResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: result)
    }
}

enum FSEventsHistoryProbe {
    // Experimental only: a just-written event can be delivered after
    // HistoryDone and FlushSync. Do not use an unchanged result for cache reuse
    // until that gap has a reliable synchronization barrier.
    // A stalled daemon can block FlushSync; permit at most one such worker.
    private static let gate = DispatchSemaphore(value: 1)

    static func compare(_ checkpoint: FSEventsCheckpoint, libraryURL: URL) async -> FSEventsHistoryResult {
        await withCheckedContinuation { continuation in
            guard gate.wait(timeout: .now()) == .success else {
                continuation.resume(returning: .unavailable)
                return
            }
            let result = FSEventsProbeResult(continuation)
            DispatchQueue.global(qos: .utility).async {
                defer { gate.signal() }
                result.finish(compareSynchronously(checkpoint, libraryURL: libraryURL))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { result.finish(.unavailable) }
        }
    }

    private static func compareSynchronously(_ checkpoint: FSEventsCheckpoint, libraryURL: URL) -> FSEventsHistoryResult {
        guard let before = FSEventsCheckpoint.capture(libraryURL: libraryURL), checkpoint.hasSameRoots(as: before) else { return .unavailable }
        for root in checkpoint.roots {
            let result = replay(root)
            if result != .unchanged { return result }
        }
        guard let after = FSEventsCheckpoint.capture(libraryURL: libraryURL), checkpoint.hasSameRoots(as: after) else { return .unavailable }
        return .unchanged
    }

    private static func replay(_ root: FSEventsCheckpoint.Root) -> FSEventsHistoryResult {
        var file = stat()
        guard stat(root.canonicalPath, &file) == 0 else { return .unavailable }
        let state = FSEventsReplayState()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
            guard let info else { return }
            Unmanaged<FSEventsReplayState>.fromOpaque(info).takeUnretainedValue().receive(flags, count: count)
        }
        let paths = [root.relativePath] as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, file.st_dev, paths, root.eventID, 0.05, flags) else { return .unavailable }
        let queue = DispatchQueue(label: "com.fcpcleaner.fsevents-replay")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return .unavailable
        }
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            queue.sync { }
            FSEventStreamRelease(stream)
            withExtendedLifetime(state) { }
        }
        guard state.wake.wait(timeout: .now() + 3) == .success else { return .unavailable }
        guard state.result == .unchanged else { return state.result }
        FSEventStreamFlushSync(stream)
        queue.sync { }
        return state.result
    }
}
