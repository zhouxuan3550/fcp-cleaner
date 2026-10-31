import Foundation
import Testing
@testable import FCPLibraryCleanerCore

/// 指纹是移入废纸篓前的最后一道安全闸门：预检靠它判断"扫描后目录有没有变"。
/// 这里锁定它的三条性质，保证以后为性能改写遍历实现时不会悄悄削弱安全性。
struct FingerprintIntegrityTests {
    private let fileManager = FileManager.default

    /// 未改动时，同一目录重复指纹必须逐位一致（否则清理会被误判为 fileChanged）。
    @Test("an untouched directory fingerprints identically across repeated passes")
    func stableWhenUnchanged() throws {
        let root = try makeDirectory(tree: ["a.mov": 4096, "b.mov": 8192, "nested/c.mov": 2048])
        defer { try? fileManager.removeItem(at: root) }

        let first = try CleanupPlan.fingerprint(for: root)
        let second = try CleanupPlan.fingerprint(for: root)

        #expect(first == second)
        #expect(first.entryCount == 3)
        #expect(first.logicalSize == 4096 + 8192 + 2048)
        #expect(first.allocatedSize >= first.logicalSize)
    }

    /// 内容变了但路径和字节数都没变：仍然必须被发现。
    @Test("rewritten bytes change the fingerprint even at identical size and path")
    func detectsRewrittenContent() throws {
        let root = try makeDirectory(tree: ["a.mov": 4096])
        defer { try? fileManager.removeItem(at: root) }

        let before = try CleanupPlan.fingerprint(for: root)
        let target = root.appendingPathComponent("a.mov")
        #expect(throws: Never.self) { try fileManager.removeItem(at: target) }
        try Data(repeating: 0xFF, count: 4096).write(to: target)

        #expect(try CleanupPlan.fingerprint(for: root) != before)
    }

    /// 同一个文件被原地换成另一个 inode，且刻意把 mtime 钉回原值：
    /// 只有文件身份标识能抓到它。这条专门守住身份分量（fileIdentifier，即 st_ino）的取值改动。
    @Test("a same-size replacement with a restored mtime is still detected")
    func detectsReplacedFileIdentity() throws {
        let root = try makeDirectory(tree: ["a.mov": 4096])
        defer { try? fileManager.removeItem(at: root) }

        let target = root.appendingPathComponent("a.mov")
        let originalDate = (try fileManager.attributesOfItem(atPath: target.path))[.modificationDate] as? Date ?? Date()
        let before = try CleanupPlan.fingerprint(for: root)

        // 原子替换（临时文件 + 改名）必然产生新 inode；再把修改时间精确还原，
        // 让 mtime 和 size 都不暴露变化，只剩文件身份能暴露替换。
        // 必须用 .atomic：非原子重写是原地截断、不换 inode，同尺寸 + 恢复 mtime
        // 之后不存在任何可观测差异，指纹不可能检出。
        try Data(repeating: 0x5A, count: 4096).write(to: target, options: .atomic)
        try fileManager.setAttributes(
            [.modificationDate: originalDate, .creationDate: originalDate],
            ofItemAtPath: target.path
        )

        let after = try CleanupPlan.fingerprint(for: root)
        #expect(after.logicalSize == before.logicalSize)
        #expect(after != before)
    }

    /// 符号链接不计入体积，也不应被跟随遍历。
    @Test("symlinks are skipped rather than counted or followed")
    func ignoresSymlinks() throws {
        let root = try makeDirectory(tree: ["real.mov": 4096])
        defer { try? fileManager.removeItem(at: root) }
        let outside = try makeDirectory(tree: ["big.mov": 1_000_000])
        defer { try? fileManager.removeItem(at: outside) }

        let base = try CleanupPlan.fingerprint(for: root)
        try fileManager.createSymbolicLink(
            atPath: root.appendingPathComponent("link.mov").path,
            withDestinationPath: outside.appendingPathComponent("big.mov").path
        )
        try fileManager.createSymbolicLink(
            atPath: root.appendingPathComponent("loop").path,
            withDestinationPath: outside.path
        )

        let withLinks = try CleanupPlan.fingerprint(for: root)
        #expect(withLinks == base)
        #expect(withLinks.entryCount == 1)
    }

    private func makeDirectory(tree: [String: Int]) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("fcp-fingerprint-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for (relative, byteCount) in tree {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(count: byteCount).write(to: url)
        }
        return root
    }
}
