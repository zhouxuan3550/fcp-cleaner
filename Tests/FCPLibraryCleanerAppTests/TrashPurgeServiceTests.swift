import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

struct TrashPurgeServiceTests {
    @Test("only recorded and unchanged direct trash children are removed")
    func boundedDeletion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func make(_ parent: URL, _ name: String) throws -> CleanupHistoryFile {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: url.appendingPathComponent("file"))
            return CleanupHistoryFile(originalURL: base.appendingPathComponent("original-" + name),
                                      trashURL: url, snapshot: try TrashItemSnapshot.capture(at: url))
        }
        let valid = try make(trash, "valid")
        let changed = try make(trash, "changed")
        let unrecorded = try make(trash, "unrecorded")
        let wrongRoot = try make(outside, "outside")
        let legacy = try make(trash, "legacy")
        let oldRecord = CleanupHistoryFile(originalURL: legacy.originalURL, trashURL: legacy.trashURL)
        try Data("modified".utf8).write(to: changed.trashURL.appendingPathComponent("file"))

        let result = TrashPurgeService.purge([valid, changed, wrongRoot, oldRecord], trashRoot: { _ in trash })
        #expect(result.removed == [valid])
        #expect(result.failedCount == 3)
        #expect(!FileManager.default.fileExists(atPath: valid.trashURL.path))
        for item in [changed, unrecorded, wrongRoot, legacy] {
            #expect(FileManager.default.fileExists(atPath: item.trashURL.path))
        }
    }

    @Test("optional physical volume uses its actual Trash location")
    func actualVolumeTrash() throws {
        guard let volume = ProcessInfo.processInfo.environment["FCP_PURGE_TEST_VOLUME"] else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let base = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("FCP-Cleaner-Test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("fixture".utf8).write(to: base.appendingPathComponent("file"))
        let before = try TrashItemSnapshot.capture(at: base)
        var resultURL: NSURL?
        try FileManager.default.trashItem(at: base, resultingItemURL: &resultURL)
        let trashURL = try #require(resultURL as URL?)
        defer { try? FileManager.default.removeItem(at: trashURL) }
        #expect(before == (try TrashItemSnapshot.capture(at: trashURL)))
        let item = CleanupHistoryFile(originalURL: base, trashURL: trashURL, snapshot: before)
        let result = TrashPurgeService.purge([item])
        #expect(result.removed == [item])
        #expect(result.failedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: trashURL.path))
    }

    @Test("replacing a recorded path during validation never deletes the replacement")
    func replacementRace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let saved = root.appendingPathComponent("saved", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("old".utf8).write(to: target.appendingPathComponent("old"))
        let item = CleanupHistoryFile(originalURL: target, trashURL: target, snapshot: try TrashItemSnapshot.capture(at: target))
        let result = TrashPurgeService.purge([item], trashRoot: { _ in root }, afterValidation: { _ in
            try FileManager.default.moveItem(at: target, to: saved)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data("replacement".utf8).write(to: target.appendingPathComponent("new"))
        })
        #expect(result.removed.isEmpty)
        #expect(result.failedCount == 1)
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("old").path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
    }

    @Test("a failed removal with an occupied original name relocates the staged item and keeps its journal")
    func relocationKeepsStagedItemAndJournal() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = trash.appendingPathComponent("item", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: url.appendingPathComponent("file"))
        let item = CleanupHistoryFile(originalURL: base.appendingPathComponent("original"),
                                      trashURL: url, snapshot: try TrashItemSnapshot.capture(at: url))
        let journalURL = base.appendingPathComponent("TrashPurgeJournal.json")

        let result = TrashPurgeService.purge([item], trashRoot: { _ in trash }, journalURL: journalURL,
                                             performRemoval: { original, _ in
            // Occupy the vacated name exactly as a racing writer would, then fail.
            try FileManager.default.createDirectory(at: original.trashURL, withIntermediateDirectories: false)
            try Data("rival".utf8).write(to: original.trashURL.appendingPathComponent("rival"))
            throw CocoaError(.fileWriteUnknown)
        })

        let staged = try #require(result.relocated[item])
        #expect(result.removed.isEmpty)
        #expect(result.failedCount == 1)
        #expect(staged.deletingLastPathComponent() == trash)
        #expect(staged.lastPathComponent.hasPrefix("FCP Cleaner 验证中 "))
        #expect(try Data(contentsOf: staged.appendingPathComponent("file")) == Data("original".utf8))
        // The replacement at the recorded path survives, and the journal still
        // points at the staged location so a later run can repair history.
        #expect(try Data(contentsOf: item.trashURL.appendingPathComponent("rival")) == Data("rival".utf8))
        let journal = try JSONDecoder().decode(TrashPurgeJournal.self, from: Data(contentsOf: journalURL))
        #expect(journal.item == item)
        #expect(journal.stagedURL == staged)
    }

    @Test("a pending relocation stops the run and abandons the remaining items unattempted")
    func pendingRelocationAbandonsRemainingItems() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let trash = base.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func make(_ name: String) throws -> CleanupHistoryFile {
            let url = trash.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("content".utf8).write(to: url.appendingPathComponent("file"))
            return CleanupHistoryFile(originalURL: base.appendingPathComponent("original-" + name),
                                      trashURL: url, snapshot: try TrashItemSnapshot.capture(at: url))
        }
        let first = try make("first")
        let second = try make("second")
        let third = try make("third")
        var attempted: [CleanupHistoryFile] = []

        let result = TrashPurgeService.purge([first, second, third], trashRoot: { _ in trash },
                                             performRemoval: { item, _ in
            attempted.append(item)
            // Only the first item relocates; its pending relocation must stop the run.
            try FileManager.default.createDirectory(at: item.trashURL, withIntermediateDirectories: false)
            throw CocoaError(.fileWriteUnknown)
        })

        #expect(attempted == [first])
        #expect(result.removed.isEmpty)
        #expect(result.failedCount == 3)
        #expect(result.relocated.count == 1)
        #expect(result.relocated[first] != nil)
        for item in [first, second, third] {
            #expect(FileManager.default.fileExists(atPath: item.trashURL.path))
        }
    }
}
