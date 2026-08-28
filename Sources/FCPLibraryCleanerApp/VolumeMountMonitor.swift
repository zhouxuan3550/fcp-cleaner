import AppKit
import Foundation

/// 监听外置卷挂载/卸载：
/// - 挂载 → 对列表中该卷上的资源库入队增量扫描（有效缓存直接复用），工作目录所在卷重连后触发一次自动发现。
/// - 卸载 → 保留 `LibraryRecord` 与 `lastKnownCleanableSize` 兜底显示，取消该卷排队/运行中的扫描，
///   并联动 `VolumeAccessReport` 显示"已断开"。重连后复用内存中的书签数据自动恢复扫描能力。
/// 卷探测等文件系统操作一律走后台任务，不在主线程做 I/O。
@MainActor
final class VolumeMountMonitor {
    private weak var store: LibraryStore?
    private var observers: [NSObjectProtocol] = []

    init(store: LibraryStore) {
        self.store = store
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.store?.handleVolumeMount(volumeURL: volumeURL)
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.store?.handleVolumeUnmount(volumeURL: volumeURL)
            }
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }
}
