import Foundation
import FCPLibraryCleanerCore
import Darwin

struct TrashPurgeOutcome: Sendable {
    let removed: Set<CleanupHistoryFile>
    let failedCount: Int
    /// A failed operation may have to leave its item at a new Trash path if
    /// another process occupied the original name while it was being checked.
    let relocated: [CleanupHistoryFile: URL]
    /// Change in free space on affected volumes, not an exact attribution.
    let availableSpaceChange: Int64?
}

enum TrashPurgeService {
    static func purge(_ items: [CleanupHistoryFile]) -> TrashPurgeOutcome {
        purge(items, trashRoot: { item in
            try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                        appropriateFor: item.trashURL, create: false)
        }, journalURL: TrashPurgeJournal.defaultURL)
    }

    /// The injectable root permits testing against disposable fixtures without
    /// touching a real Trash directory.
    static func purge(_ items: [CleanupHistoryFile], trashRoot: (CleanupHistoryFile) throws -> URL,
                      journalURL: URL? = nil,
                      afterValidation: (CleanupHistoryFile) throws -> Void = { _ in }) -> TrashPurgeOutcome {
        let fileManager = FileManager.default
        var removed = Set<CleanupHistoryFile>()
        var failures = 0
        var relocated: [CleanupHistoryFile: URL] = [:]
        var availableDelta: Int64 = 0
        var measured = false
        for (itemIndex, item) in items.enumerated() {
            do {
                guard let snapshot = item.snapshot else { throw CocoaError(.fileReadNoPermission) }
                let root = try trashRoot(item).standardizedFileURL.resolvingSymlinksInPath()
                let path = item.trashURL.standardizedFileURL
                // Only direct children of the system-provided Trash location
                // are eligible; never follow a replacement root symlink.
                guard path.deletingLastPathComponent().resolvingSymlinksInPath() == root,
                      try TrashItemSnapshot.capture(at: path) == snapshot else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try afterValidation(item)
                let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
                defer { close(directory) }
                // An exclusive, same-directory rename prevents a replacement
                // at the recorded path from being deleted. Recheck after the
                // move and return a changed item to its original name.
                let stagingName = "FCP Cleaner 验证中 " + UUID().uuidString
                let staged = root.appendingPathComponent(stagingName, isDirectory: true)
                if let journalURL {
                    guard let volumeUUID = try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try TrashPurgeJournal(item: item, stagedURL: staged, volumeUUID: volumeUUID).save(to: journalURL)
                }
                guard renameatx_np(directory, path.lastPathComponent, directory, stagingName, UInt32(RENAME_EXCL)) == 0 else {
                    if let journalURL { TrashPurgeJournal.clear(at: journalURL) }
                    throw CocoaError(.fileWriteUnknown)
                }
                let before = availableCapacity(at: root)
                do {
                    guard try TrashItemSnapshot.capture(at: staged) == snapshot else { throw CocoaError(.fileReadCorruptFile) }
                    try fileManager.removeItem(at: staged)
                } catch {
                    if renameatx_np(directory, stagingName, directory, path.lastPathComponent, UInt32(RENAME_EXCL)) != 0,
                       fileManager.fileExists(atPath: staged.path) {
                        relocated[item] = staged
                    } else if let journalURL {
                        TrashPurgeJournal.clear(at: journalURL)
                    }
                    throw error
                }
                if let journalURL { TrashPurgeJournal.clear(at: journalURL) }
                let after = availableCapacity(at: root)
                if let before, let after {
                    availableDelta += Int64(after) - Int64(before)
                    measured = true
                }
                removed.insert(item)
            } catch {
                failures += 1
                // Preserve a pending relocation journal until history records
                // the staged location; do not overwrite it with another item.
                if !relocated.isEmpty {
                    failures += items.count - itemIndex - 1
                    break
                }
            }
        }
        return TrashPurgeOutcome(removed: removed, failedCount: failures, relocated: relocated,
                                 availableSpaceChange: measured ? availableDelta : nil)
    }

    private static func availableCapacity(at root: URL) -> Int64? {
        // statfs performs a fresh query each time, unlike cached URL resources.
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { return nil }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow, bytes <= UInt64(Int64.max) else { return nil }
        return Int64(bytes)
    }
}
