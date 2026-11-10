import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct TrashItemSnapshotTests {
    @Test("snapshot survives a same-volume rename and detects descendant changes")
    func renameAndChanges() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = source.appendingPathComponent("nested/file")
        try Data("original".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/file")
        let before = try TrashItemSnapshot.capture(at: source)
        #expect(before == (try TrashItemSnapshot.capture(at: source, useBulk: false)))
        #expect(before.itemCount == 4) // root, directory, file and link; the link is not followed
        try FileManager.default.moveItem(at: source, to: target)
        let after = try TrashItemSnapshot.capture(at: target)
        #expect(after == (try TrashItemSnapshot.capture(at: target, useBulk: false)))
        #expect(before == after)
        try Data("changed!".utf8).write(to: target.appendingPathComponent("nested/file"))
        #expect(after != (try TrashItemSnapshot.capture(at: target)))
        try FileManager.default.removeItem(at: target.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(atPath: target.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        #expect(after != (try TrashItemSnapshot.capture(at: target)))
    }

    @Test("a replacement directory is not the same item")
    func replacedRoot() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try TrashItemSnapshot.capture(at: base)
        let moved = base.appendingPathExtension("old")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: base, to: moved)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        #expect(first != (try TrashItemSnapshot.capture(at: base)))
    }

    @Test("optional external volume snapshot agrees with the reference walker")
    func externalSnapshot() throws {
        guard let volume = ProcessInfo.processInfo.environment["FCP_SNAPSHOT_TEST_VOLUME"] else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let root = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("FCP-Cleaner-Snapshot-Test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<512 { try Data("\(index)".utf8).write(to: root.appendingPathComponent("frame-\(index)")) }
        try FileManager.default.linkItem(at: root.appendingPathComponent("frame-1"), to: root.appendingPathComponent("hard-link"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("symbolic-link").path, withDestinationPath: "frame-2")
        let bulk = try TrashItemSnapshot.capture(at: root, useBulk: true)
        #expect(bulk == (try TrashItemSnapshot.capture(at: root, useBulk: false)))
        try Data("updated".utf8).write(to: root.appendingPathComponent("frame-1"))
        #expect(bulk != (try TrashItemSnapshot.capture(at: root)))
    }
}
