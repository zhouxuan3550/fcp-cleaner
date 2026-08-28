import CoreServices
import Foundation

/// 监听工作目录变更：发现新的 .fcpbundle 后防抖触发一次自动发现。
/// 只读监听目录结构，绝不追踪用户媒体内容，也绝不自动清理。
@MainActor
final class WorkDirectoryMonitor {
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var debounceTask: Task<Void, Never>?
    private weak var store: LibraryStore?

    init(store: LibraryStore) {
        self.store = store
    }

    func updateWatched(paths: [String]) {
        guard paths != watchedPaths else { return }
        stop()
        guard !paths.isEmpty else { return }
        watchedPaths = paths

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorkDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            monitor.scheduleDiscovery()
        }
        let pathsToWatch = watchedPaths as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// 5 秒防抖：挂载风暴或批量拷贝只触发一次发现。
    private func scheduleDiscovery() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            store.discoverLibraries()
        }
    }

    func stop() {
        debounceTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
}
