import Foundation
import Testing
@testable import FCPLibraryCleanerCore

/// 确认弹窗按条目勾选后的计划裁剪：只允许缩小范围，绝不放大或换库。
struct CleanupPlanFilteringTests {
    private func makeItem(url: URL, category: CacheCategory, size: Int64) -> CacheItem {
        CacheItem(
            url: url,
            category: category,
            allocatedSize: size,
            logicalSize: size,
            confidence: .confirmed,
            ruleID: "event.render-files",
            storage: .library,
            fingerprint: FileFingerprint(
                allocatedSize: size,
                logicalSize: size,
                entryCount: 3,
                contentsSignature: UInt64(abs(url.hashValue))
            )
        )
    }

    private func makePlan() throws -> CleanupPlan {
        let libraryURL = URL(fileURLWithPath: "/tmp/fcpc-filter-lib/Lib.fcpbundle")
        let database = CoreDataSnapshot(url: libraryURL.appendingPathComponent("CurrentVersion.flexolibrary"), size: 1, modificationTime: 0)
        let scanResult = LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: 1_000,
            totalLogicalSize: 1_000,
            coreDataSnapshots: [database],
            cacheItems: [
                makeItem(url: libraryURL.appendingPathComponent("Event1/Render Files"), category: .renderFiles, size: 300),
                makeItem(url: libraryURL.appendingPathComponent("Event2/Render Files"), category: .renderFiles, size: 200),
                makeItem(url: libraryURL.appendingPathComponent("Shared Render Files"), category: .renderFiles, size: 500),
            ],
            observedCacheItems: [],
            protectedItems: [],
            issues: []
        )
        return try CleanupPlan(scanResult: scanResult, categories: Set(CacheCategory.cleanableCases))
    }

    @Test("filtering keeps only selected entries and preserves library context")
    func keepsSelection() throws {
        let plan = try makePlan()
        let kept = Set([plan.entries[0].item.url, plan.entries[2].item.url])

        let filtered = plan.filtering(keeping: kept)

        #expect(filtered.entries.map(\.item.url) == [plan.entries[0].item.url, plan.entries[2].item.url])
        #expect(filtered.spaceToFree == 800)
        #expect(filtered.libraryURL == plan.libraryURL)
        #expect(filtered.coreDataSnapshots == plan.coreDataSnapshots)
    }

    @Test("filtering with everything kept equals the original plan; nothing kept yields an empty plan")
    func boundaryCases() throws {
        let plan = try makePlan()
        let all = Set(plan.entries.map(\.item.url))

        let unchanged = plan.filtering(keeping: all)
        #expect(unchanged.entries.count == plan.entries.count)
        #expect(unchanged.spaceToFree == plan.spaceToFree)

        let empty = plan.filtering(keeping: [])
        #expect(empty.entries.isEmpty)
        #expect(empty.spaceToFree == 0)
        #expect(empty.libraryURL == plan.libraryURL)
    }

    @Test("filtering never adds entries outside the source plan")
    func neverExpands() throws {
        let plan = try makePlan()
        let foreign = Set([URL(fileURLWithPath: "/tmp/somewhere-else/Render Files")])

        let filtered = plan.filtering(keeping: foreign)
        #expect(filtered.entries.isEmpty)
    }
}
