import Foundation
import Testing
@testable import FCPLibraryCleanerApp

@MainActor
struct VolumeHotPlugTests {
    /// 挂载/卸载联动只作用于该卷上的记录，全程不做真实文件系统探测。
    @Test("unmount keeps the record and flags it offline; mount re-queues an incremental scan")
    func unmountAndRemountLifecycle() {
        let store = LibraryStore.shared
        let volumeRoot = "/tmp/fcpc-hotplug-test-vol"
        let record = LibraryRecord(url: URL(fileURLWithPath: volumeRoot + "/项目.fcpbundle"))
        store.libraries.append(record)
        defer { store.remove([record]) }

        store.handleVolumeUnmount(volumeURL: URL(fileURLWithPath: volumeRoot))
        #expect(record.accessReport?.mounted == false)
        // 记录保留，lastKnownCleanableSize 兜底不被清除
        #expect(store.libraries.contains { $0.id == record.id })

        store.handleVolumeMount(volumeURL: URL(fileURLWithPath: volumeRoot))
        // 挂载后诊断态让位给后台复核，记录入队增量扫描
        #expect(record.accessReport == nil)
        #expect(record.isQueued || record.isScanning)

        // 其他卷不受影响
        let untouched = LibraryRecord(url: URL(fileURLWithPath: "/tmp/fcpc-hotplug-other-vol/别的.fcpbundle"))
        store.libraries.append(untouched)
        store.handleVolumeUnmount(volumeURL: URL(fileURLWithPath: volumeRoot))
        #expect(untouched.accessReport == nil)
        store.remove([untouched])
    }
}
