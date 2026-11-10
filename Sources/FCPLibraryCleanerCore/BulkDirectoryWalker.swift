import Darwin
import Foundation

/// Reads directory entries in batches without following symbolic links.
/// Unsupported attributes are reported to the caller rather than guessed.
enum BulkDirectoryWalker {
    struct Entry {
        let parentPath: String
        let name: String
        let type: UInt32
        let fileID: UInt64
        let modificationTime: TimeInterval
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64?
        let changeNanoseconds: Int64?
        let totalAllocatedSize: Int64
        let allocatedSize: Int64
        let logicalSize: Int64
        let privateSize: Int64?
        let linkCount: UInt32?
    }

    enum Failure: Error {
        case unsupported
        case unreadable(String)
    }

    static func walk(_ root: URL, includePrivateSize: Bool = false, includeChangeTime: Bool = false, stayOnRootDevice: Bool = false, shouldDescend: (Entry) -> Bool = { _ in true }, visit: (Entry) throws -> Void) throws {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unreadable("open root: \(errno)") }
        defer { close(fd) }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0 else { throw Failure.unreadable("stat root") }
        var pathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &pathBytes) == 0,
              let path = String(bytes: pathBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
            throw Failure.unsupported
        }
        try walkDirectory(fd: fd, path: path, depth: 0, includePrivateSize: includePrivateSize, includeChangeTime: includeChangeTime, rootDevice: stayOnRootDevice ? rootInfo.st_dev : nil, shouldDescend: shouldDescend, visit: visit)
    }

    private static func walkDirectory(fd: Int32, path: String, depth: Int, includePrivateSize: Bool, includeChangeTime: Bool, rootDevice: dev_t?, shouldDescend: (Entry) -> Bool, visit: (Entry) throws -> Void) throws {
        guard depth < 1024 else { throw Failure.unreadable("depth") }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        var common = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME) |
            UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FILEID)
        if includeChangeTime { common |= UInt32(ATTR_CMN_CHGTIME) }
        let file = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH | ATTR_FILE_DATAALLOCSIZE)
        attributes.commonattr = common
        attributes.fileattr = file
        if includePrivateSize {
            attributes.fileattr |= UInt32(ATTR_FILE_LINKCOUNT)
            attributes.forkattr = UInt32(ATTR_CMNEXT_PRIVATESIZE)
        }
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                let options = UInt64(FSOPT_PACK_INVAL_ATTRS | (includePrivateSize ? FSOPT_ATTR_CMN_EXTENDED : 0))
                return getattrlistbulk(fd, &attributes, raw.baseAddress, raw.count, options)
            }
            if count == 0 { return }
            guard count > 0 else {
                if errno == ENOTSUP || errno == EINVAL { throw Failure.unsupported }
                throw Failure.unreadable("getattrlistbulk: \(errno)")
            }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                for _ in 0..<count {
                    let commonShift = includeChangeTime ? MemoryLayout<timespec>.size : 0
                    guard offset + 64 + commonShift <= raw.count else { throw Failure.unreadable("buffer") }
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length >= 64 + commonShift, length <= raw.count - offset else { throw Failure.unreadable("length: \(length)") }
                    let returned = raw.loadUnaligned(fromByteOffset: offset + 4, as: attribute_set_t.self)
                    let error = raw.loadUnaligned(fromByteOffset: offset + 24, as: UInt32.self)
                    guard error == 0 else { throw Failure.unreadable("entry: \(error)") }
                    guard returned.commonattr & common == common else { throw Failure.unsupported }
                    let referenceOffset = offset + 28
                    let nameOffset = Int(raw.loadUnaligned(fromByteOffset: referenceOffset, as: Int32.self))
                    let nameLength = Int(raw.loadUnaligned(fromByteOffset: referenceOffset + 4, as: UInt32.self))
                    let nameStart = referenceOffset + nameOffset
                    guard nameLength > 0, nameStart >= offset + 64 + commonShift, nameStart <= offset + length,
                          nameLength <= offset + length - nameStart,
                          raw[nameStart + nameLength - 1] == 0,
                          let name = String(bytes: raw[nameStart..<(nameStart + nameLength - 1)], encoding: .utf8),
                          !name.isEmpty, !name.contains("/") else { throw Failure.unsupported }
                    let type = raw.loadUnaligned(fromByteOffset: offset + 36, as: UInt32.self)
                    let modified = raw.loadUnaligned(fromByteOffset: offset + 40, as: timespec.self)
                    let changed = includeChangeTime ? raw.loadUnaligned(fromByteOffset: offset + 56, as: timespec.self) : nil
                    let fileID = raw.loadUnaligned(fromByteOffset: offset + 56 + commonShift, as: UInt64.self)
                    var allocated: Int64 = 0
                    var totalAllocated: Int64 = 0
                    var logical: Int64 = 0
                    var privateSize: Int64?
                    var linkCount: UInt32?
                    if type != UInt32(VDIR.rawValue) && type != UInt32(VLNK.rawValue) {
                        guard returned.fileattr & file == file else { throw Failure.unsupported }
                        let shift = includePrivateSize ? 4 : 0
                        guard length >= 88 + shift + commonShift, nameStart >= offset + 88 + shift + commonShift else { throw Failure.unreadable("file attributes") }
                        if includePrivateSize, returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT) != 0 {
                            linkCount = raw.loadUnaligned(fromByteOffset: offset + 64 + commonShift, as: UInt32.self)
                        }
                        totalAllocated = raw.loadUnaligned(fromByteOffset: offset + 64 + shift + commonShift, as: Int64.self)
                        logical = raw.loadUnaligned(fromByteOffset: offset + 72 + shift + commonShift, as: Int64.self)
                        allocated = raw.loadUnaligned(fromByteOffset: offset + 80 + shift + commonShift, as: Int64.self)
                        if includePrivateSize, returned.forkattr & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                            guard length >= 96 + shift + commonShift, nameStart >= offset + 96 + shift + commonShift else { throw Failure.unreadable("private size") }
                            let value = raw.loadUnaligned(fromByteOffset: offset + 88 + shift + commonShift, as: Int64.self)
                            guard value >= 0 else { throw Failure.unreadable("private size") }
                            privateSize = value
                        }
                    }
                    let modificationTime = Double(modified.tv_sec - 978_307_200) + Double(modified.tv_nsec) / 1_000_000_000
                    let entry = Entry(parentPath: path, name: name, type: type, fileID: fileID,
                                      modificationTime: modificationTime,
                                      modificationSeconds: Int64(modified.tv_sec), modificationNanoseconds: Int64(modified.tv_nsec),
                                      changeSeconds: changed.map { Int64($0.tv_sec) }, changeNanoseconds: changed.map { Int64($0.tv_nsec) },
                                      totalAllocatedSize: totalAllocated, allocatedSize: allocated, logicalSize: logical,
                                      privateSize: privateSize, linkCount: linkCount)
                    try visit(entry)
                    if type == UInt32(VDIR.rawValue) && shouldDescend(entry) {
                        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                        guard child >= 0 else { throw Failure.unreadable("openat \(name): \(errno)") }
                        defer { close(child) }
                        var childStat = stat()
                        guard fstat(child, &childStat) == 0, childStat.st_ino == fileID,
                              rootDevice == nil || childStat.st_dev == rootDevice else {
                            throw Failure.unreadable("directory changed during traversal")
                        }
                        let childPath = path == "/" ? path + name : path + "/" + name
                        try walkDirectory(fd: child, path: childPath, depth: depth + 1, includePrivateSize: includePrivateSize, includeChangeTime: includeChangeTime, rootDevice: rootDevice, shouldDescend: shouldDescend, visit: visit)
                    }
                    offset += length
                }
            }
        }
    }
}
