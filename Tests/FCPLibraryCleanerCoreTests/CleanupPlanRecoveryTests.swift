import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct CleanupPlanRecoveryTests {
    /// 事务中断后，重建计划只保留"仍在磁盘且未记录完成"的条目。
    @Test("recovery keeps only entries still on disk and not recorded as trashed")
    func planForPendingEntriesFiltersCorrectly() throws {
        let libraryURL = URL(fileURLWithPath: "/Volumes/RAID/项目.fcpbundle")
        let snapshot = CoreDataSnapshot(url: libraryURL.appendingPathComponent("CurrentVersion.flexolibrary"), size: 10, modificationTime: 1)
        let result = LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: 300,
            totalLogicalSize: 300,
            coreDataSnapshots: [snapshot],
            cacheItems: [
                cacheItem(url: libraryURL.appendingPathComponent("Render Files"), category: .renderFiles, size: 100),
                cacheItem(url: libraryURL.appendingPathComponent("Proxy Media"), category: .proxyMedia, size: 120),
                cacheItem(url: libraryURL.appendingPathComponent("Optimized Media"), category: .optimizedMedia, size: 80),
            ],
            observedCacheItems: [],
            protectedItems: [],
            issues: []
        )
        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))

        // Render Files 已移入废纸篓（历史有记录）；Proxy Media 执行中断后仍在磁盘；Optimized Media 已被用户手动删除
        let onDisk: Set<URL> = [
            libraryURL.appendingPathComponent("Proxy Media"),
            libraryURL.appendingPathComponent("Render Files"),
        ]
        let completed: Set<URL> = [libraryURL.appendingPathComponent("Render Files")]

        let rebuilt = plan.planForPendingEntries(
            exists: { onDisk.contains($0) },
            isCompleted: { completed.contains($0) }
        )
        #expect(rebuilt != nil)
        #expect(rebuilt?.entries.map(\.item.url) == [libraryURL.appendingPathComponent("Proxy Media")])
        #expect(rebuilt?.spaceToFree == 120)
        #expect(rebuilt?.coreDataSnapshots == plan.coreDataSnapshots)

        // 全部完成或消失：无需重建
        #expect(plan.planForPendingEntries(exists: { _ in false }, isCompleted: { _ in false }) == nil)
        #expect(plan.planForPendingEntries(exists: { _ in true }, isCompleted: { _ in true }) == nil)
    }

    private func cacheItem(url: URL, category: CacheCategory, size: Int64) -> CacheItem {
        CacheItem(
            url: url,
            category: category,
            allocatedSize: size,
            logicalSize: size,
            confidence: .confirmed,
            ruleID: "test.\(category.rawValue)",
            storage: .library,
            fingerprint: FileFingerprint(allocatedSize: size, logicalSize: size, entryCount: 1, contentsSignature: 7)
        )
    }
}
