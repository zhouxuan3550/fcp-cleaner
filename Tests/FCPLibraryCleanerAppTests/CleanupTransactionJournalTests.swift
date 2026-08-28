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
        let snapshot = CoreDataSnapshot(url: libraryURL.appendingPathComponent("CurrentVersion.flexolibrary"), size: 10, modificationTime: 1)
        let result = LibraryScanResult(
            libraryURL: libraryURL,
            totalAllocatedSize: 50,
            totalLogicalSize: 50,
            coreDataSnapshots: [snapshot],
            cacheItems: [
                CacheItem(
                    url: libraryURL.appendingPathComponent("Render Files"),
                    category: .renderFiles,
                    allocatedSize: 50,
                    logicalSize: 50,
                    confidence: .confirmed,
                    ruleID: "test.renderFiles",
                    storage: .library,
                    fingerprint: FileFingerprint(allocatedSize: 50, logicalSize: 50, entryCount: 1, contentsSignature: 3)
                )
            ],
            observedCacheItems: [],
            protectedItems: [],
            issues: []
        )
        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
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
}
