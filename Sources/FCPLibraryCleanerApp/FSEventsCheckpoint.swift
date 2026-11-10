import CoreServices
import Darwin
import Foundation
import FCPLibraryCleanerCore

/// A checkpoint is captured before a scan so changes during the scan are replayed.
struct FSEventsCheckpoint: Codable, Equatable, Sendable {
    struct Root: Codable, Equatable, Sendable {
        let canonicalPath: String
        let relativePath: String
        let volumeUUID: String
        let inode: UInt64
        let eventID: UInt64
    }

    let roots: [Root]

    static func capture(libraryURL: URL) -> FSEventsCheckpoint? {
        let eventID = FSEventsGetCurrentEventId()
        guard eventID != 0, eventID != UInt64.max else { return nil }
        let link = libraryURL.appendingPathComponent(FCPStructureRules.cacheLinkName)
        var linkInfo = stat()
        let linkExists = lstat(link.path, &linkInfo) == 0
        if !linkExists && errno != ENOENT { return nil }
        let external = FCPStructureRules.externalCacheRoot(for: libraryURL)
        if linkExists && external == nil {
            // A self-reference or a link within the bundle is already covered
            // by the library root. A broken or non-link entry is not.
            guard linkInfo.st_mode & S_IFMT == S_IFLNK,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
            let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
                .standardizedFileURL.resolvingSymlinksInPath()
            let library = libraryURL.standardizedFileURL.resolvingSymlinksInPath()
            var target = stat()
            guard (resolved == library || resolved.path.hasPrefix(library.path + "/")),
                  stat(resolved.path, &target) == 0, target.st_mode & S_IFMT == S_IFDIR else { return nil }
        }
        let paths = [libraryURL] + (external.map { [$0] } ?? [])
        var roots: [Root] = []
        for path in paths {
            guard let root = makeRoot(path: path, eventID: eventID) else { return nil }
            roots.append(root)
        }
        return FSEventsCheckpoint(roots: roots.sorted { $0.canonicalPath < $1.canonicalPath })
    }

    /// Devices may receive a new dev_t after remounting; the journal UUID and
    /// root identity are the persistent comparison keys.
    func hasSameRoots(as current: FSEventsCheckpoint) -> Bool {
        guard roots.count == current.roots.count else { return false }
        return zip(roots, current.roots).allSatisfy { old, new in
            old.canonicalPath == new.canonicalPath && old.relativePath == new.relativePath &&
                old.volumeUUID == new.volumeUUID && old.inode == new.inode &&
                old.eventID != 0 && old.eventID != UInt64.max && old.eventID <= new.eventID
        }
    }

    static func supports(local: Bool, filesystem: String) -> Bool {
        local && (filesystem == "apfs" || filesystem == "hfs")
    }

    private static func makeRoot(path: URL, eventID: UInt64) -> Root? {
        var fs = statfs()
        var file = stat()
        guard statfs(path.path, &fs) == 0,
              stat(path.path, &file) == 0, (file.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let format = withUnsafeBytes(of: &fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard supports(local: fs.f_flags & UInt32(MNT_LOCAL) != 0, filesystem: format),
              let uuid = FSEventsCopyUUIDForDevice(file.st_dev),
              let uuidString = CFUUIDCreateString(nil, uuid) else { return nil }
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard path.path.withCString({ realpath($0, &canonical) }) != nil,
              let canonicalPath = String(bytes: canonical.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8),
              let relativePath = volumeRelativePath(path.path) else { return nil }
        return Root(canonicalPath: canonicalPath, relativePath: relativePath,
                    volumeUUID: uuidString as String, inode: file.st_ino, eventID: eventID)
    }

    private static func volumeRelativePath(_ path: String) -> String? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = UInt32(ATTR_CMNEXT_RELPATH)
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 64)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &attributes, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw in
            let length = Int(raw.loadUnaligned(as: UInt32.self))
            guard length >= 32, length <= raw.count else { return nil }
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & UInt32(ATTR_CMNEXT_RELPATH) != 0 else { return nil }
            let reference = 24
            let start = reference + Int(raw.loadUnaligned(fromByteOffset: reference, as: Int32.self))
            let count = Int(raw.loadUnaligned(fromByteOffset: reference + 4, as: UInt32.self))
            guard count > 0, start >= 32, start <= length, count <= length - start,
                  raw[start + count - 1] == 0,
                  let relative = String(bytes: raw[start..<(start + count - 1)], encoding: .utf8),
                  relative.hasPrefix("/") else { return nil }
            return relative
        }
    }
}
