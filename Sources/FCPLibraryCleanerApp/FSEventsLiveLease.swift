import CoreServices
import Darwin
import Foundation

/// Keeps all library/cache streams alive after historical replay. An event
/// delivered late after HistoryDone still invalidates the displayed cache.
final class FSEventsLiveLease: @unchecked Sendable {
    // Match the app's maximum simultaneous library scans while bounding the
    // number of workers that could be held by an unresponsive daemon.
    private static let gate = DispatchSemaphore(value: 3)
    private let queue = DispatchQueue(label: "com.fcpcleaner.fsevents-live")
    private var streams: [FSEventStreamRef] = []
    private var states: [FSEventsReplayState] = []

    private init() { }

    deinit {
        for stream in streams { FSEventStreamStop(stream); FSEventStreamInvalidate(stream) }
        queue.sync { }
        for stream in streams { FSEventStreamRelease(stream) }
        withExtendedLifetime(states) { }
    }

    static func open(checkpoint: FSEventsCheckpoint, libraryURL: URL,
                     onChange: @escaping @Sendable () -> Void) async -> FSEventsLiveLease? {
        await withCheckedContinuation { continuation in
            guard gate.wait(timeout: .now()) == .success else {
                continuation.resume(returning: nil)
                return
            }
            let result = OpenResult(continuation)
            DispatchQueue.global(qos: .utility).async {
                defer { gate.signal() }
                result.finish(openSynchronously(checkpoint: checkpoint, libraryURL: libraryURL, onChange: onChange))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { result.finish(nil) }
        }
    }

    private static func openSynchronously(checkpoint: FSEventsCheckpoint, libraryURL: URL,
                                          onChange: @escaping @Sendable () -> Void) -> FSEventsLiveLease? {
        guard let before = FSEventsCheckpoint.capture(libraryURL: libraryURL), checkpoint.hasSameRoots(as: before) else { return nil }
        let lease = FSEventsLiveLease()
        for root in checkpoint.roots {
            var file = stat()
            guard stat(root.canonicalPath, &file) == 0 else { return nil }
            let state = FSEventsReplayState(onChange: onChange)
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(state).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, _, flags, _ in
                guard let info else { return }
                Unmanaged<FSEventsReplayState>.fromOpaque(info).takeUnretainedValue().receive(flags, count: count)
            }
            guard let stream = FSEventStreamCreateRelativeToDevice(nil, callback, &context, file.st_dev,
                    [root.relativePath] as CFArray, root.eventID, 0.01,
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else { return nil }
            lease.states.append(state)
            lease.streams.append(stream)
            FSEventStreamSetDispatchQueue(stream, lease.queue)
            guard FSEventStreamStart(stream) else { return nil }
        }
        for state in lease.states {
            guard state.wake.wait(timeout: .now() + 3) == .success, state.result == .unchanged else { return nil }
        }
        for stream in lease.streams { FSEventStreamFlushSync(stream) }
        lease.queue.sync { }
        guard lease.states.allSatisfy({ $0.result == .unchanged }),
              let after = FSEventsCheckpoint.capture(libraryURL: libraryURL), checkpoint.hasSameRoots(as: after) else { return nil }
        return lease
    }
}

private final class OpenResult: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<FSEventsLiveLease?, Never>
    init(_ continuation: CheckedContinuation<FSEventsLiveLease?, Never>) { self.continuation = continuation }
    func finish(_ lease: FSEventsLiveLease?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(returning: lease)
    }
}
