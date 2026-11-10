import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct LibraryStoreStateMachineTests {
    @Test("partial results reject cancelled, stale and out-of-order callbacks")
    func partialResultsRespectScanLifetime() {
        let record = LibraryRecord(url: URL(fileURLWithPath: "/tmp/partial.fcpbundle"))
        let current = ScanControl()
        let old = ScanControl()
        record.isScanning = true
        record.scanControl = current
        let first = ScanPartialResults(completedDirectories: 1, totalDirectories: 3, allocatedByCategory: [.renderFiles: 10])
        let second = ScanPartialResults(completedDirectories: 2, totalDirectories: 3, allocatedByCategory: [.renderFiles: 20])
        record.acceptPartialResults(second, control: old)
        #expect(record.scanPartialResults == nil)
        record.acceptPartialResults(second, control: current)
        record.acceptPartialResults(first, control: current)
        #expect(record.scanPartialResults == second)
        current.cancel()
        let third = ScanPartialResults(completedDirectories: 3, totalDirectories: 3, allocatedByCategory: [.renderFiles: 30])
        record.acceptPartialResults(third, control: current)
        #expect(record.scanPartialResults == second)
    }

    @Test("late events only invalidate the matching live cache generation")
    func liveCacheGeneration() {
        let record = LibraryRecord(url: URL(fileURLWithPath: "/tmp/live.fcpbundle"))
        let current = UUID()
        record.eventWatchID = current
        #expect(!record.acceptLiveCacheChange(watchID: UUID()))
        #expect(!record.eventRefreshPending)
        record.isScanning = true
        #expect(record.acceptLiveCacheChange(watchID: current))
        #expect(record.eventRefreshPending)
        record.eventRefreshPending = false
        record.eventWatchID = UUID()
        #expect(!record.acceptLiveCacheChange(watchID: current))
        #expect(!record.eventRefreshPending)
    }

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
