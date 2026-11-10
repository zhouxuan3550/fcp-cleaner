import Darwin
import Foundation

final class TrashPurgeLock: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(for journalURL: URL) -> TrashPurgeLock? {
        let directory = journalURL.deletingLastPathComponent()
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        let lockURL = directory.appendingPathComponent("TrashPurge.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return TrashPurgeLock(fd)
    }
}

/// Single-item journal: written before a temporary rename and removed only
/// after the item is deleted, restored, or its new location is persisted.
struct TrashPurgeJournal: Codable, Sendable, Equatable {
    let item: CleanupHistoryFile
    let stagedURL: URL
    let volumeUUID: String?

    init(item: CleanupHistoryFile, stagedURL: URL, volumeUUID: String? = nil) {
        self.item = item
        self.stagedURL = stagedURL
        self.volumeUUID = volumeUUID
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
            .appendingPathComponent("TrashPurgeJournal.json")
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { try? FileManager.default.removeItem(at: url) }
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        succeeded = true
    }

    static func clear(at url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Never removes content. If the old name is occupied, the staged item
    /// remains in the Trash and its new URL is returned for history repair.
    static func recover(at url: URL) -> TrashPurgeJournal? {
        guard let data = try? Data(contentsOf: url),
              let journal = try? JSONDecoder().decode(TrashPurgeJournal.self, from: data) else { return nil }
        let original = journal.item.trashURL.standardizedFileURL
        let staged = journal.stagedURL.standardizedFileURL
        guard original.deletingLastPathComponent() == staged.deletingLastPathComponent(),
              staged.lastPathComponent.hasPrefix("FCP Cleaner 验证中 ") else { return nil }
        let parent = open(staged.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        // A disconnected or inaccessible disk is not proof the staged item is
        // absent. Keep the journal for a later recovery attempt.
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        if let expected = journal.volumeUUID {
            let current = try? staged.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard current == expected else { return nil }
        }
        var info = stat()
        if fstatat(parent, staged.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { clear(at: url) }
            return nil
        }
        if renameatx_np(parent, staged.lastPathComponent, parent, original.lastPathComponent, UInt32(RENAME_EXCL)) == 0 {
            clear(at: url)
            return nil
        }
        return journal
    }
}
