import Darwin
import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct BulkDirectoryWalkerTests {
    @Test("bulk metadata matches Foundation for nested files and does not follow symlinks")
    func matchesFoundation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("中文 空间", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = nested.appendingPathComponent("片段.mov")
        try Data(repeating: 7, count: 12345).write(to: file)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: nested)
        var entries: [BulkDirectoryWalker.Entry] = []
        try BulkDirectoryWalker.walk(root) { entries.append($0) }
        let entry = try #require(entries.first { $0.name == file.lastPathComponent })
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .fileIdentifierKey])
        #expect(entries.filter { $0.name == file.lastPathComponent }.count == 1)
        #expect(entry.logicalSize == Int64(try #require(values.fileSize)))
        #expect(entry.allocatedSize == Int64(try #require(values.fileAllocatedSize)))
        #expect(entry.modificationTime == (try #require(values.contentModificationDate)).timeIntervalSinceReferenceDate)
        #expect(entry.fileID == UInt64(try #require(values.fileIdentifier)))
        let bulk = try CleanupPlan.bulkFingerprint(for: root)
        let reference = try CleanupPlan.foundationFingerprint(for: root)
        #expect(bulk == reference)
    }

    @Test("bulk fingerprint matches reference across multiple batches and sparse files")
    func multipleBatches() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<1800 {
            try Data("\(index)".utf8).write(to: root.appendingPathComponent("frame-\(index).dat"))
        }
        try Data().write(to: root.appendingPathComponent("e\u{0301}-empty.dat"))
        try fm.linkItem(at: root.appendingPathComponent("frame-1.dat"), to: root.appendingPathComponent("hard-link.dat"))
        let sparse = root.appendingPathComponent("sparse.dat")
        _ = fm.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 16 * 1024 * 1024)
        try handle.close()
        #expect(try CleanupPlan.bulkFingerprint(for: root) == CleanupPlan.foundationFingerprint(for: root))
        #expect(try TrashItemSnapshot.capture(at: root, useBulk: true) == TrashItemSnapshot.capture(at: root, useBulk: false))
    }

    @Test("bulk library sizing agrees with Foundation and skips precounted subtrees")
    func directorySizeMatchesReference() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let nested = cache.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data(repeating: 9, count: 2048).write(to: nested.appendingPathComponent("cached"))
        try Data(repeating: 4, count: 3500).write(to: root.appendingPathComponent("original"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: cache)
        let fingerprint = try CleanupPlan.fingerprint(for: cache)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        #expect(cache.path.withCString { realpath($0, &buffer) } != nil)
        let canonical = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let precounted = [canonical: (allocated: fingerprint.allocatedSize, logical: fingerprint.logicalSize, files: fingerprint.entryCount)]
        let bulk = try LibraryScanner.bulkDirectorySize(of: root, control: ScanControl(), preCounted: precounted, onProgress: { _ in })
        let reference = try LibraryScanner.foundationDirectorySize(of: root, fileManager: fm, control: ScanControl(), preCounted: precounted, onProgress: { _ in })
        #expect(bulk == reference)
        #expect(bulk.files == 2)
        #expect(bulk.directories == 1)
        let cancelled = ScanControl()
        cancelled.cancel()
        #expect(throws: CancellationError.self) {
            try LibraryScanner.bulkDirectorySize(of: root, control: cancelled, preCounted: [:], onProgress: { _ in })
        }
    }

    @Test("resource fork allocation matches the Foundation fingerprint")
    func resourceForkMatchesReference() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("forked")
        try Data(repeating: 1, count: 4096).write(to: file)
        let resourceFork = URL(fileURLWithPath: file.path + "/..namedfork/rsrc")
        do {
            try Data(repeating: 2, count: 32768).write(to: resourceFork)
        } catch {
            return // Some filesystems do not support resource forks.
        }
        let bulk = try CleanupPlan.bulkFingerprint(for: root)
        let reference = try CleanupPlan.foundationFingerprint(for: root)
        #expect(bulk == reference)
        #expect(try TrashItemSnapshot.capture(at: root, useBulk: true) == TrashItemSnapshot.capture(at: root, useBulk: false))
        let snapshot = try TrashItemSnapshot.capture(at: root)
        try Data(repeating: 3, count: 32_768).write(to: resourceFork)
        #expect(snapshot != (try TrashItemSnapshot.capture(at: root)))
    }

    @Test("private allocation is read without changing the existing fingerprint")
    func privateAllocationForClone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let fs = withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard fs == "apfs" else { return }
        let original = root.appendingPathComponent("original")
        let cloned = root.appendingPathComponent("clone")
        try Data(repeating: 17, count: 2 * 1024 * 1024).write(to: original)
        #expect(clonefile(original.path, cloned.path, 0) == 0)
        try fm.linkItem(at: original, to: root.appendingPathComponent("hard-link"))
        var entries: [BulkDirectoryWalker.Entry] = []
        try BulkDirectoryWalker.walk(root, includePrivateSize: true) { entries.append($0) }
        let files = entries.filter { $0.name == "original" || $0.name == "clone" }
        #expect(files.count == 2)
        for entry in files {
            let privateSize = try #require(entry.privateSize)
            #expect(privateSize >= 0)
            #expect(privateSize <= entry.totalAllocatedSize)
            #expect(entry.linkCount == (entry.name == "original" ? 2 : 1))
        }
        let measured = try ReclaimableSpaceEstimate.measure(at: root)
        let estimate = try #require(measured)
        let clone = try #require(files.first { $0.name == "clone" })
        #expect(estimate.minimumBytes == clone.privateSize)
        #expect(estimate.maximumBytes >= estimate.minimumBytes)
        #expect(try CleanupPlan.bulkFingerprint(for: root) == CleanupPlan.foundationFingerprint(for: root))
    }

    @Test("unsupported volumes do not report a fabricated estimate")
    func nonAPFSHasNoEstimate() throws {
        var info = statfs()
        guard statfs("/dev", &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let format = withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard format != "apfs" else { return }
        let estimate = try ReclaimableSpaceEstimate.measure(at: URL(fileURLWithPath: "/dev"))
        #expect(estimate == nil)
    }
}
