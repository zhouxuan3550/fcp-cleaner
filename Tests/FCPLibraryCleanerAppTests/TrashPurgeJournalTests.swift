import Foundation
import Testing
@testable import FCPLibraryCleanerApp

struct TrashPurgeJournalTests {
    @Test("interrupted rename restores the recorded name")
    func restoresStagedItem() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old", isDirectory: true)
        let stage = base.appendingPathComponent("FCP Cleaner 验证中 test", isDirectory: true)
        let journalURL = base.appendingPathComponent("journal.json")
        let item = CleanupHistoryFile(originalURL: old, trashURL: old)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try TrashPurgeJournal(item: item, stagedURL: stage).save(to: journalURL)
        #expect(TrashPurgeJournal.recover(at: journalURL) == nil)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("occupied original name leaves staged item for history repair")
    func occupiedName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old", isDirectory: true)
        let stage = base.appendingPathComponent("FCP Cleaner 验证中 test", isDirectory: true)
        let journalURL = base.appendingPathComponent("journal.json")
        let item = CleanupHistoryFile(originalURL: old, trashURL: old)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try TrashPurgeJournal(item: item, stagedURL: stage).save(to: journalURL)
        let recovered = try #require(TrashPurgeJournal.recover(at: journalURL))
        #expect(recovered.stagedURL == stage)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: stage.path))
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        #expect(throws: (any Error).self) { try TrashPurgeJournal(item: item, stagedURL: stage).save(to: journalURL) }
    }

    @Test("offline parent retains its recovery journal")
    func unavailableParent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let absent = base.appendingPathComponent("offline")
        let old = absent.appendingPathComponent("old")
        let stage = absent.appendingPathComponent("FCP Cleaner 验证中 test")
        let journalURL = base.appendingPathComponent("journal.json")
        let item = CleanupHistoryFile(originalURL: old, trashURL: old)
        try TrashPurgeJournal(item: item, stagedURL: stage).save(to: journalURL)
        #expect(TrashPurgeJournal.recover(at: journalURL) == nil)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        #expect(TrashPurgeJournal.recover(at: journalURL) == nil)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("a replacement volume does not consume the pending journal")
    func wrongVolume() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("old")
        let stage = base.appendingPathComponent("FCP Cleaner 验证中 test")
        let journalURL = base.appendingPathComponent("journal.json")
        let item = CleanupHistoryFile(originalURL: old, trashURL: old)
        try TrashPurgeJournal(item: item, stagedURL: stage, volumeUUID: UUID().uuidString).save(to: journalURL)
        #expect(TrashPurgeJournal.recover(at: journalURL) == nil)
        #expect(FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("another process cannot recover while a purge owns the journal")
    func exclusiveLock() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let journal = base.appendingPathComponent("journal.json")
        var lock = TrashPurgeLock.acquire(for: journal)
        #expect(lock != nil)
        #expect(TrashPurgeLock.acquire(for: journal) == nil)
        withExtendedLifetime(lock) { }
        // Releasing the descriptor releases the lock even after an app crash.
        lock = nil
        #expect(TrashPurgeLock.acquire(for: journal) != nil)
    }
}
