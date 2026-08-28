import Foundation
import Testing
@testable import FCPLibraryCleanerApp

@MainActor
struct LibraryStoreStateMachineTests {
    @Test("appearance mode maps to NSAppearance overrides")
    func appearanceMapping() {
        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
    }

    @Test("batch selection ignores libraries below the minimum threshold")
    func batchSelectionRejectsBelowThreshold() {
        let store = LibraryStore.shared
        let before = store.batchSelectedIDs

        // 无扫描结果、体积为零的裸记录必须被拒收——不依赖任何文件系统。
        let bare = LibraryRecord(url: URL(fileURLWithPath: "/tmp/never-scanned.fcpbundle"))
        store.toggleBatchSelection(bare)
        #expect(store.batchSelectedIDs == before)

        store.toggleBatchSelection(bare)
        #expect(store.batchSelectedIDs == before)
    }
}
