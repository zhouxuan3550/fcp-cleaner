import Foundation
import Testing
@testable import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct CleanupTransactionJournalTests {
    @Test("journal round-trips the confirmed plans and clears atomically")
    func saveLoadClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpc-journal-\(UUID().uuidString)", isDirectory: true)
        let journal = CleanupTransactionJournal(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(journal.load() == nil)

        let libraryURL = URL(fileURLWithPath: "/Volumes/RAID/项目.fcpbundle")
        let plan = try makePlan(libraryURL: libraryURL)
        let startedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

        journal.save(CleanupTransaction(startedAt: startedAt, plans: [plan]))
        let loaded = journal.load()
        #expect(loaded?.startedAt == startedAt)
        #expect(loaded?.plans.count == 1)
        #expect(loaded?.plans.first?.libraryURL == libraryURL)
        #expect(loaded?.plans.first?.spaceToFree == 50)

        journal.clear()
        #expect(journal.load() == nil)
    }

    @Test("finishing one recovered library preserves the other interrupted plans")
    func finishOnePlanPreservesOthers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpc-journal-multi-\(UUID().uuidString)", isDirectory: true)
        let journal = CleanupTransactionJournal(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = URL(fileURLWithPath: "/Volumes/RAID/第一库.fcpbundle")
        let secondURL = URL(fileURLWithPath: "/Volumes/RAID/第二库.fcpbundle")
        journal.begin(plans: [try makePlan(libraryURL: firstURL), try makePlan(libraryURL: secondURL)])

        journal.finish(libraryURLs: [firstURL])
        #expect(journal.load()?.plans.map(\.libraryURL) == [secondURL])

        journal.finish(libraryURLs: [secondURL])
        #expect(journal.load() == nil)
    }

    private func makePlan(libraryURL: URL) throws -> CleanupPlan {
        let snapshot = CoreDataSnapshot(
            url: libraryURL.appendingPathComponent("CurrentVersion.flexolibrary"),
            size: 10,
            modificationTime: 1
        )
        let result = LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: 50,
            totalLogicalSize: 50,
            coreDataSnapshots: [snapshot],
            cacheItems: [CacheItem(
                url: libraryURL.appendingPathComponent("Render Files"),
                category: .renderFiles,
                allocatedSize: 50,
                logicalSize: 50,
                confidence: .confirmed,
                ruleID: "test.renderFiles",
                storage: .library,
                fingerprint: FileFingerprint(allocatedSize: 50, logicalSize: 50, entryCount: 1, contentsSignature: 3)
            )],
            observedCacheItems: [],
            protectedItems: [],
            issues: []
        )
        return try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
    }
}
