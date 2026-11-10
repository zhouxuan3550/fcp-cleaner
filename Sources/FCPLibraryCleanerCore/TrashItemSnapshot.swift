import CryptoKit
import Darwin
import Foundation

/// Fail-closed identity of a Trash item and all its descendants. Only a
/// snapshot matching both before and after a move is eligible for deletion.
public struct TrashItemSnapshot: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let itemCount: UInt64
    public let signature: [UInt64]

    public static func capture(at url: URL) throws -> TrashItemSnapshot {
        do { return try capture(at: url, useBulk: true) }
        catch BulkDirectoryWalker.Failure.unsupported { return try capture(at: url, useBulk: false) }
    }

    /// Exposed to tests so optimized and reference snapshots can be compared.
    static func capture(at url: URL, useBulk: Bool) throws -> TrashItemSnapshot {
        var root = stat()
        guard lstat(url.path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var digest = Accumulator()
        digest.add(path: "", type: UInt32(VDIR.rawValue), inode: UInt64(root.st_ino), size: 0,
                   modifiedSeconds: Int64(root.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(root.st_mtimespec.tv_nsec),
                   changedSeconds: 0, changedNanoseconds: 0, rootMode: UInt32(root.st_mode), rootLinks: UInt64(root.st_nlink))

        if useBulk {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard url.path.withCString({ realpath($0, &buffer) }) != nil,
                  let canonical = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                throw BulkDirectoryWalker.Failure.unsupported
            }
            let prefix = canonical == "/" ? "/" : canonical + "/"
            try BulkDirectoryWalker.walk(url, includeChangeTime: true, stayOnRootDevice: true) { entry in
                let relativeParent: String
                if entry.parentPath == canonical { relativeParent = "" }
                else if entry.parentPath.hasPrefix(prefix) { relativeParent = String(entry.parentPath.dropFirst(prefix.count)) + "/" }
                else { throw CocoaError(.fileReadCorruptFile) }
                guard entry.type == UInt32(VDIR.rawValue) || entry.type == UInt32(VREG.rawValue) || entry.type == UInt32(VLNK.rawValue),
                      let changeSeconds = entry.changeSeconds, let changeNanos = entry.changeNanoseconds else {
                    throw BulkDirectoryWalker.Failure.unsupported
                }
                digest.add(path: relativeParent + entry.name, type: entry.type, inode: entry.fileID,
                           size: entry.type == UInt32(VREG.rawValue) ? entry.logicalSize : 0,
                           modifiedSeconds: entry.modificationSeconds, modifiedNanoseconds: entry.modificationNanoseconds,
                           changedSeconds: changeSeconds, changedNanoseconds: changeNanos)
            }
        } else {
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw CocoaError(.fileReadNoPermission) }
            let prefix = url.standardizedFileURL.path + "/"
            for case let child as URL in enumerator {
                let path = child.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadCorruptFile) }
                var info = stat()
                guard lstat(path, &info) == 0, info.st_dev == root.st_dev else { throw CocoaError(.fileReadUnknown) }
                let type: UInt32
                switch info.st_mode & S_IFMT {
                case S_IFDIR: type = UInt32(VDIR.rawValue)
                case S_IFREG: type = UInt32(VREG.rawValue)
                case S_IFLNK: type = UInt32(VLNK.rawValue)
                default: throw CocoaError(.fileReadUnsupportedScheme)
                }
                digest.add(path: String(path.dropFirst(prefix.count)), type: type, inode: UInt64(info.st_ino),
                           size: type == UInt32(VREG.rawValue) ? Int64(info.st_size) : 0,
                           modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                           changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
            }
            if let enumerationError { throw enumerationError }
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_dev == root.st_dev, after.st_ino == root.st_ino,
              after.st_mtimespec.tv_sec == root.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == root.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == root.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == root.st_ctimespec.tv_nsec else {
            throw CocoaError(.fileReadUnknown)
        }
        return TrashItemSnapshot(device: UInt64(root.st_dev), inode: UInt64(root.st_ino), itemCount: digest.count, signature: digest.signature)
    }

    private struct Accumulator {
        var count: UInt64 = 0
        var signature = [UInt64](repeating: 0, count: 4)

        mutating func add(path: String, type: UInt32, inode: UInt64, size: Int64,
                          modifiedSeconds: Int64, modifiedNanoseconds: Int64,
                          changedSeconds: Int64, changedNanoseconds: Int64,
                          rootMode: UInt32 = 0, rootLinks: UInt64 = 0) {
            var bytes = Data()
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            }
            let name = Array(path.utf8)
            append(UInt64(name.count)); bytes.append(contentsOf: name)
            append(type); append(inode); append(size)
            append(modifiedSeconds); append(modifiedNanoseconds); append(changedSeconds); append(changedNanoseconds)
            append(rootMode); append(rootLinks)
            let hash = Array(SHA256.hash(data: bytes))
            for index in 0..<4 {
                var word: UInt64 = 0
                for byte in hash[(index * 8)..<(index * 8 + 8)] { word = (word << 8) | UInt64(byte) }
                signature[index] &+= word
            }
            count &+= 1
        }
    }
}
