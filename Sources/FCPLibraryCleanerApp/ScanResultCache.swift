import Foundation
import FCPLibraryCleanerCore
import OSLog

struct ScanResultCache: Sendable {
    private static let signposter = OSSignposter(subsystem: "com.fcplibrarycleaner", category: "scan-cache")
    /// 缓存条目格式版本。改动 Core 模型结构时 +1：旧缓存因缺少新键解码失败，
    /// 自动触发完整重扫——把"隐式解码崩溃"变成显式的版本门槛。
    /// v4：指纹身份分量从 documentIdentifier（macOS 26+ 返回 nil，恒 0）
    /// 换成 fileIdentifier（st_ino）；旧缓存指纹与新算法必然失配，必须重扫。
    /// v5：扫描时附带 APFS 空间估算；旧结果需重扫以获取范围。
    private static let schemaVersion = 5

    private struct Entry: Codable, Sendable {
        let schemaVersion: Int
        let token: LibraryChangeToken
        let result: LibraryScanResult
        let checkpoint: FSEventsCheckpoint?
    }

    struct LiveResult: Sendable {
        let result: LibraryScanResult
        let lease: FSEventsLiveLease
    }

    func loadWithLiveEvents(libraryURL: URL, control: ScanControl,
                            onChange: @escaping @Sendable () -> Void) async -> LiveResult? {
        let interval = Self.signposter.beginInterval("IncrementalLiveCache")
        defer { Self.signposter.endInterval("IncrementalLiveCache", interval) }
        guard let entry = await load(libraryURL: libraryURL), entry.schemaVersion == Self.schemaVersion,
              let checkpoint = entry.checkpoint, !control.isCancelled,
              let lease = await FSEventsLiveLease.open(checkpoint: checkpoint, libraryURL: libraryURL, onChange: onChange),
              !control.isCancelled else { return nil }
        return LiveResult(result: entry.result, lease: lease)
    }

    func loadIfCurrent(libraryURL: URL, control: ScanControl = ScanControl()) async -> LibraryScanResult? {
        let interval = Self.signposter.beginInterval("IncrementalFingerprintValidation")
        defer { Self.signposter.endInterval("IncrementalFingerprintValidation", interval) }
        guard let entry = await load(libraryURL: libraryURL),
              entry.schemaVersion == Self.schemaVersion else { return nil }
        // Capture before the full fingerprint so subsequent changes cannot be
        // hidden by upgrading a legacy entry after validation.
        let checkpoint = await Task.detached(priority: .utility) {
            FSEventsCheckpoint.capture(libraryURL: libraryURL)
        }.value
        guard !control.isCancelled,
              let currentToken = try? await LibraryScanner().changeToken(libraryURL: libraryURL, control: control),
              !control.isCancelled, currentToken == entry.token else { return nil }
        if let checkpoint { await save(entry.result, checkpoint: checkpoint) }
        guard !control.isCancelled else { return nil }
        return entry.result
    }

    func save(_ result: LibraryScanResult, checkpoint: FSEventsCheckpoint? = nil) async {
        let token: LibraryChangeToken?
        if let precomputed = result.changeToken {
            token = precomputed
        } else {
            token = try? await LibraryScanner().changeToken(libraryURL: result.libraryURL)
        }
        guard let token else { return }
        let entry = Entry(
            schemaVersion: Self.schemaVersion,
            token: token,
            result: result,
            checkpoint: checkpoint
        )
        let destination = cacheURL(for: result.libraryURL)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(entry)
                try data.write(to: destination, options: .atomic)
            } catch {
                // A cache write failure must never block scanning or cleanup.
            }
        }.value
    }

    private func load(libraryURL: URL) async -> Entry? {
        let source = cacheURL(for: libraryURL)
        let legacySource = source.deletingPathExtension().appendingPathExtension("json")
        return await Task.detached(priority: .utility) {
            if let data = try? Data(contentsOf: source),
               let entry = try? PropertyListDecoder().decode(Entry.self, from: data) {
                return entry
            }
            guard let data = try? Data(contentsOf: legacySource) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }.value
    }

    /// 资源库从列表移除后同步删除其缓存文件，避免 Caches 目录随时间累积孤儿条目。
    func removeCache(for libraryURL: URL) async {
        let source = cacheURL(for: libraryURL)
        let legacySource = source.deletingPathExtension().appendingPathExtension("json")
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: legacySource)
        }.value
    }

    /// 启动时清扫：删除不再对应任何现役资源库的缓存文件（改路径/换盘的历史遗留）。
    /// 纯文件名比对，不触碰任何现役条目。
    func prune(keeping libraryURLs: [URL]) async {
        let keep = Set(libraryURLs.map { stableKey($0.standardizedFileURL.path) })
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
            .appendingPathComponent("ScanResults", isDirectory: true)
        await Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            for file in files where ["json", "plist"].contains(file.pathExtension) {
                if !keep.contains(file.deletingPathExtension().lastPathComponent) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }.value
    }

    private func cacheURL(for libraryURL: URL) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
            .appendingPathComponent("ScanResults", isDirectory: true)
        return root.appendingPathComponent(stableKey(libraryURL.standardizedFileURL.path) + ".plist")
    }

    private func stableKey(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
